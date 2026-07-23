#!/bin/bash
# install_ssm.sh — 批量在 10 台 redis-probe EC2 上安装并启动 SSM Agent
#
# 前提：
#   - 实例已挂带 AmazonSSMManagedInstanceCore 的 instance profile (已确认 ✅)
#   - 本机有 IAD-keypair.pem，且与本脚本同目录（或改 KEY 变量）
#   - SG 允许出站 443（SSM 走 HTTPS 出站，公有子网直连即可）
#
# 用法： ./install_ssm.sh
set -uo pipefail

KEY="${KEY:-./IAD-keypair.pem}"
USER="rocky"
REGION="us-east-1"

# EC2 公网 IP 列表（部署时的映射，见 DEPLOY_MANIFEST.md）
IPS=(
  52.86.124.77     # EC2-1
  3.91.195.140     # EC2-2
  18.208.127.8     # EC2-3
  54.161.225.56    # EC2-4
  54.208.147.40    # EC2-5
  18.205.157.29    # EC2-6
  32.198.4.190     # EC2-7
  34.238.136.242   # EC2-8
  54.165.207.151   # EC2-9
  3.82.126.52      # EC2-10
)

if [ ! -f "$KEY" ]; then
  echo "ERROR: 找不到私钥 $KEY，请把 IAD-keypair.pem 放到当前目录，或用 KEY=/path/to/key.pem ./install_ssm.sh"
  exit 1
fi
chmod 600 "$KEY" 2>/dev/null || true

# Rocky 9 (x86_64) 安装 SSM agent 的远程命令
REMOTE_CMD='
set -e
if systemctl is-active --quiet amazon-ssm-agent; then
  echo "SSM already running"; exit 0
fi
sudo dnf install -y https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/linux_amd64/amazon-ssm-agent.rpm
sudo systemctl enable --now amazon-ssm-agent
sleep 2
sudo systemctl is-active amazon-ssm-agent && echo "SSM installed+started OK"
'

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

for ip in "${IPS[@]}"; do
  echo "======== $ip ========"
  ssh $SSH_OPTS -i "$KEY" "$USER@$ip" "$REMOTE_CMD" 2>&1 | sed "s/^/[$ip] /"
  echo ""
done

echo "=== 全部完成。等 1-2 分钟后用下面命令验证 SSM 上线： ==="
echo "aws ssm describe-instance-information --region $REGION \\"
echo "  --query 'InstanceInformationList[].{Id:InstanceId,Ping:PingStatus,Name:ComputerName}' --output table"
