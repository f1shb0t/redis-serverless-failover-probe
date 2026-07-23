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
