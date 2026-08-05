#!/bin/bash
# EC2 userdata for Redis failover probe host (Rocky 9).
# Placeholders __REDIS_A_HOST__ __REDIS_A_NAME__ __REDIS_B_HOST__ __REDIS_B_NAME__ replaced per instance.
set -x
exec > /var/log/probe-bootstrap.log 2>&1

REDIS_A_HOST="__REDIS_A_HOST__"
REDIS_A_NAME="__REDIS_A_NAME__"
REDIS_B_HOST="__REDIS_B_HOST__"
REDIS_B_NAME="__REDIS_B_NAME__"
REDIS_PORT=6379

# --- 1. install jdk11 + tools ---
dnf install -y java-11-openjdk-devel curl unzip cronie
systemctl enable --now crond

# --- 1b. OOM 加固（08-03 事后手动做过，此处回写模板固化）---
# t3.micro 仅 717MB，dnf 自动补丁的内存峰值会触发 global OOM，
# 内核默认挑 RSS 最大的 java(probe) 杀。加 1GB swap + 降低 probe 的 oom_score_adj，
# 让 OOM 优先杀 dnf/yum 而非 probe，避免 probe 被误杀导致假断联。
if ! swapon --show | grep -q /swapfile; then
  fallocate -l 1G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=1024
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
sysctl -w vm.swappiness=10
echo 'vm.swappiness=10' > /etc/sysctl.d/99-swappiness.conf

mkdir -p /opt/redisprobe/lib /opt/redisprobe/logs
cd /opt/redisprobe

# --- 2. fetch Jedis 4.4.8 + deps (commons-pool2, slf4j, gson) from Maven Central ---
BASE=https://repo1.maven.org/maven2
curl -sL -o lib/jedis-4.4.8.jar        $BASE/redis/clients/jedis/4.4.8/jedis-4.4.8.jar
curl -sL -o lib/commons-pool2-2.11.1.jar $BASE/org/apache/commons/commons-pool2/2.11.1/commons-pool2-2.11.1.jar
curl -sL -o lib/slf4j-api-1.7.36.jar   $BASE/org/slf4j/slf4j-api/1.7.36/slf4j-api-1.7.36.jar
curl -sL -o lib/gson-2.10.1.jar        $BASE/com/google/code/gson/gson/2.10.1/gson-2.10.1.jar
curl -sL -o lib/json-20230618.jar      $BASE/org/json/json/20230618/json-20230618.jar
curl -sL -o lib/commons-lang3-3.12.0.jar $BASE/org/apache/commons/commons-lang3/3.12.0/commons-lang3-3.12.0.jar

# --- 3. drop probe source (base64 embedded) ---
cat > /opt/redisprobe/RedisProbe.java <<'JAVA_EOF'
__PROBE_SOURCE__
JAVA_EOF

CP="/opt/redisprobe/lib/*"
javac -cp "$CP" -d /opt/redisprobe /opt/redisprobe/RedisProbe.java

# --- 4. daily report script ---
cat > /opt/redisprobe/daily_report.sh <<'REPORT_EOF'
__REPORT_SOURCE__
REPORT_EOF
chmod +x /opt/redisprobe/daily_report.sh

# --- 5. systemd services (2 probes) ---
cat > /etc/systemd/system/redisprobe-a.service <<EOF
[Unit]
Description=Redis Probe A (${REDIS_A_NAME})
After=network-online.target
[Service]
ExecStart=/usr/bin/java -Xmx256m -cp "/opt/redisprobe:/opt/redisprobe/lib/*" RedisProbe ${REDIS_A_HOST} ${REDIS_PORT} ${REDIS_A_NAME} /opt/redisprobe/logs/${REDIS_A_NAME}.log
Restart=always
RestartSec=5
OOMScoreAdjust=-500
[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/redisprobe-b.service <<EOF
[Unit]
Description=Redis Probe B (${REDIS_B_NAME})
After=network-online.target
[Service]
ExecStart=/usr/bin/java -Xmx256m -cp "/opt/redisprobe:/opt/redisprobe/lib/*" RedisProbe ${REDIS_B_HOST} ${REDIS_PORT} ${REDIS_B_NAME} /opt/redisprobe/logs/${REDIS_B_NAME}.log
Restart=always
RestartSec=5
OOMScoreAdjust=-500
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now redisprobe-a.service
systemctl enable --now redisprobe-b.service

# --- 6. cron: daily report at 01:30 UTC (=09:30 Beijing) ---
echo "30 1 * * * root /opt/redisprobe/daily_report.sh >> /opt/redisprobe/logs/report.log 2>&1" > /etc/cron.d/redisprobe-report
chmod 644 /etc/cron.d/redisprobe-report
systemctl restart crond

echo "BOOTSTRAP DONE $(date -u)"
