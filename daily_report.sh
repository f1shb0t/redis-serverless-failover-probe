#!/bin/bash
# Daily reporter: summarize probe logs for the two probes on this EC2 and push to Feishu webhook.
# Runs at 09:30 Beijing time (= 01:30 UTC) via cron.
set -euo pipefail

WEBHOOK="https://open.feishu.cn/open-apis/bot/v2/hook/108bd68c-3aa0-4b43-b161-2589acbc9d6b"
LOGDIR="/opt/redisprobe/logs"
EC2_ID=$(curl -s -H "X-aws-ec2-metadata-token: $(curl -s -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')" http://169.254.169.254/latest/meta-data/instance-id || echo unknown)
PUB_IP=$(curl -s -H "X-aws-ec2-metadata-token: $(curl -s -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')" http://169.254.169.254/latest/meta-data/public-ipv4 || echo unknown)

# Build summary for each probe log on this box
SUMMARY=""
for LOG in "$LOGDIR"/*.log; do
  [ -e "$LOG" ] || continue
  NAME=$(basename "$LOG" .log)
  # last METRICS line = cumulative totals
  LAST=$(grep "^METRICS" "$LOG" | tail -1 || true)
  # disconnect events in last 24h
  DISC_COUNT=$(grep -c "^DISCONNECT_RECOVERED" "$LOG" || true)
  DISC_LINES=$(grep "^DISCONNECT_RECOVERED" "$LOG" | tail -10 || true)

  # parse fields from LAST
  getf() { echo "$LAST" | tr ' ' '\n' | grep "^$1=" | cut -d= -f2 || echo "-"; }
  WOK=$(getf writeOk); WFAIL=$(getf writeFail); ROK=$(getf readOk); RFAIL=$(getf readFail)
  WP50=$(getf wP50us); WP99=$(getf wP99us); RP50=$(getf rP50us); RP99=$(getf rP99us)
  HOST=$(getf host); DC=$(getf disconnects)

  SUMMARY="${SUMMARY}\n▶ Redis [${NAME}] (${HOST})\n"
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

# Build JSON safely via python (handles quoting/escaping)
PAYLOAD=$(python3 -c '
import json, sys
text = sys.argv[1].encode().decode("unicode_escape")
print(json.dumps({"msg_type":"text","content":{"text":text}}))
' "$TEXT")

curl -s -X POST "$WEBHOOK" -H "Content-Type: application/json" -d "$PAYLOAD"
echo "report sent at $(date -u)"
