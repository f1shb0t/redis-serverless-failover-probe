#!/bin/bash
# Daily reporter: summarize probe logs for the two probes on this EC2 and push to Feishu webhook.
# Runs at 09:30 Beijing time (= 01:30 UTC) via cron.
set -euo pipefail

WEBHOOK="https://open.feishu.cn/open-apis/bot/v2/hook/108bd68c-3aa0-4b43-b161-2589acbc9d6b"
LOGDIR="/opt/redisprobe/logs"

# ---- IMDSv2 token (reused below) ----
IMDS_TOKEN=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 300' || true)
imds() { curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" "http://169.254.169.254/latest/meta-data/$1" 2>/dev/null || echo unknown; }
EC2_ID=$(imds instance-id)
PUB_IP=$(imds public-ipv4)

# ---- Deterministic stagger (no collisions) ----
# 10 台 cron 都在 01:30:00 同秒触发，随机 jitter 仍偶发同窗口撞飞书限流。
# 改为按实例编号确定性错峰：probe 编号 N -> 延迟 (N-1)*30 秒。
# 10 台 -> 0/30/60/.../270s，两两间隔 30s，绝不同秒并发。
# 编号来自本地文件 /opt/redisprobe/probe_index（分发时写入，零依赖零权限）。
IDX=""
if [ -f /opt/redisprobe/probe_index ]; then
  IDX=$(tr -cd '0-9' < /opt/redisprobe/probe_index)
fi
if [ -n "$IDX" ]; then
  DELAY=$(( (IDX - 1) * 30 ))
else
  # 兜底：文件缺失时用私有IP末段做确定性散列（0~285s，步长约30s）
  LASTOCT=$(imds local-ipv4 | awk -F. '{print $4}')
  if echo "$LASTOCT" | grep -qE '^[0-9]+$'; then
    DELAY=$(( (LASTOCT % 10) * 30 ))
  else
    DELAY=$(( RANDOM % 90 ))
  fi
fi
sleep "$DELAY"

# Build summary for each probe log on this box
SUMMARY=""
for LOG in "$LOGDIR"/*.log; do
  [ -e "$LOG" ] || continue
  PNAME=$(basename "$LOG" .log)
  # skip cron's own report.log (not a probe log)
  case "$PNAME" in report) continue;; esac
  # last METRICS line = cumulative totals
  LAST=$(grep "^METRICS" "$LOG" | tail -1 || true)
  # disconnect events in last 24h
  DISC_LINES=$(grep "^DISCONNECT_RECOVERED" "$LOG" | tail -10 || true)

  # parse fields from LAST
  getf() { echo "$LAST" | tr ' ' '\n' | grep "^$1=" | cut -d= -f2 || echo "-"; }
  WOK=$(getf writeOk); WFAIL=$(getf writeFail); ROK=$(getf readOk); RFAIL=$(getf readFail)
  WP50=$(getf wP50us); WP99=$(getf wP99us); RP50=$(getf rP50us); RP99=$(getf rP99us)
  HOST=$(getf host); DC=$(getf disconnects)

  SUMMARY="${SUMMARY}\n▶ Redis [${PNAME}] (${HOST})\n"
  SUMMARY="${SUMMARY}  写: 成功 ${WOK} / 失败 ${WFAIL}  |  读: 成功 ${ROK} / 失败 ${RFAIL}\n"
  SUMMARY="${SUMMARY}  写延迟 p50/p99: ${WP50}/${WP99} µs  |  读延迟 p50/p99: ${RP50}/${RP99} µs\n"
  SUMMARY="${SUMMARY}  断联次数: ${DC:-0}\n"
  if [ -n "$DISC_LINES" ]; then
    SUMMARY="${SUMMARY}  最近断联事件:\n"
    while IFS= read -r ln; do
      st=$(echo "$ln" | tr ' ' '\n' | grep '^start=' | cut -d= -f2)
      en=$(echo "$ln" | tr ' ' '\n' | grep '^end=' | cut -d= -f2)
      du=$(echo "$ln" | tr ' ' '\n' | grep '^durationMs=' | cut -d= -f2)
      SUMMARY="${SUMMARY}    - ${st} → ${en}  (${du} ms)\n"
    done <<< "$DISC_LINES"
  fi
done

DATE=$(date -u +"%Y-%m-%d %H:%M UTC")
TEXT="【Redis Serverless 长跑日报】\n实例: ${EC2_ID} (${PUB_IP})\n时间: ${DATE}\n${SUMMARY}"

# Build JSON safely via python (handles quoting/escaping).
# NOTE: 不能用 unicode_escape，它会把 UTF-8 中文按 Latin-1 曲解成乱码。
# 只需把字面 \n 还原为真实换行，并 ensure_ascii=False 保留 UTF-8。
PAYLOAD=$(python3 -c '
import json, sys
text = sys.argv[1].replace("\\n", "\n")
print(json.dumps({"msg_type":"text","content":{"text":text}}, ensure_ascii=False))
' "$TEXT")

# ---- Send with retry on Feishu rate-limit ----
# 即便错峰后仍偶发限流，则退避重试兜底。检测 code 11232 / 9499 / "too many"。
send_report() {
  local attempt=1 max=4 resp
  while [ "$attempt" -le "$max" ]; do
    resp=$(curl -s -X POST "$WEBHOOK" -H "Content-Type: application/json; charset=utf-8" --data-binary "$PAYLOAD")
    echo "attempt ${attempt}: ${resp}"
    # 成功判定：code:0
    if echo "$resp" | grep -q '"code":0'; then
      echo "report sent OK at $(date -u) (attempt ${attempt})"
      return 0
    fi
    # 限流判定：退避后重试
    if echo "$resp" | grep -qE '11232|9499|too many|frequency limited'; then
      local backoff=$(( 10 + RANDOM % 21 ))   # 10~30s 随机退避
      echo "rate-limited, retrying in ${backoff}s ..."
      sleep "$backoff"
      attempt=$(( attempt + 1 ))
      continue
    fi
    # 其他错误：不重试，直接报
    echo "report FAILED (non-retryable) at $(date -u): ${resp}"
    return 1
  done
  echo "report FAILED after ${max} attempts at $(date -u)"
  return 1
}
send_report
