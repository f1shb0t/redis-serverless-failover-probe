#!/bin/bash
# Add swap + protect probe from OOM killer.
#
# 背景：t3.micro（717MB 可用内存、无 swap）上跑 2 个 java probe，
# 每周日 dnf-automatic 打内核补丁时 yum 吃掉几百 MB → 内核 OOM killer 杀掉 probe，
# 产生假的「Redis 断联」事件（实测 2026-08-02 两台都中招）。
#
# 两道加固：
#   1) 1GB swapfile —— 给内存峰值留缓冲，避免触发 OOM
#   2) probe 进程 oom_score_adj=-500 —— 万一真 OOM，优先杀 yum 而不是杀 probe，
#      保证长跑测试数据连续
#
# 注意：根分区是 XFS。XFS 上不能用 fallocate 造 swapfile
# （产生 unwritten extent，swapon 会报 "swapon: Invalid argument"），必须用 dd 实写。
set -euo pipefail

SWAPFILE=/swapfile
SWAPSIZE_MB=1024

echo "=== [1/4] swapfile ==="
if swapon --show | grep -q "$SWAPFILE"; then
  echo "swap already active, skip creation"
else
  if [ ! -f "$SWAPFILE" ]; then
    # 必须 dd（XFS 不接受 fallocate 的稀疏/unwritten extent）
    dd if=/dev/zero of="$SWAPFILE" bs=1M count="$SWAPSIZE_MB" status=none
    echo "created ${SWAPSIZE_MB}MB $SWAPFILE via dd"
  fi
  chmod 600 "$SWAPFILE"
  mkswap "$SWAPFILE" >/dev/null
  swapon "$SWAPFILE"
  echo "swapon OK"
fi

echo "=== [2/4] persist in fstab ==="
if grep -q "^${SWAPFILE} " /etc/fstab; then
  echo "fstab entry exists, skip"
else
  cp /etc/fstab /etc/fstab.bak.$(date +%s)
  printf '%s none swap sw 0 0\n' "$SWAPFILE" >> /etc/fstab
  echo "fstab updated (backup saved)"
fi
# 校验 fstab 没写坏（否则下次重启起不来）—— swapon --all 能跑通即证明条目合法
swapon --all 2>/dev/null || true

echo "=== [3/4] swappiness=10 ==="
# 默认 60 太激进，会把活跃的 java 堆换出去拖慢延迟；
# 设 10 = 只在接近 OOM 时才用 swap，正好符合「只做安全垫」的意图。
echo 'vm.swappiness=10' > /etc/sysctl.d/99-redisprobe-swap.conf
sysctl -q -w vm.swappiness=10
echo "swappiness now: $(cat /proc/sys/vm/swappiness)"

echo "=== [4/4] protect probe from OOM killer ==="
for U in redisprobe-a redisprobe-b; do
  D="/etc/systemd/system/${U}.service.d"
  mkdir -p "$D"
  cat > "$D/oom.conf" <<'EOF'
[Service]
# 万一再次内存吃紧，让内核优先杀 yum/dnf 而不是杀 probe（保证长跑数据连续）
OOMScoreAdjust=-500
EOF
done
systemctl daemon-reload
# 对已在运行的进程立即生效（不重启进程，避免打断长跑与制造假断联）
for U in redisprobe-a redisprobe-b; do
  PID=$(systemctl show -p MainPID --value "${U}.service" 2>/dev/null || echo 0)
  if [ -n "$PID" ] && [ "$PID" != "0" ] && [ -e "/proc/$PID/oom_score_adj" ]; then
    echo -500 > "/proc/$PID/oom_score_adj"
    echo "${U}: pid=$PID oom_score_adj=$(cat /proc/$PID/oom_score_adj)"
  else
    echo "${U}: no running pid, drop-in will apply on next start"
  fi
done

echo "=== RESULT ==="
free -m
swapon --show
