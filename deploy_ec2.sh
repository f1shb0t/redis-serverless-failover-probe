#!/bin/bash
# Orchestrator: launch 10 t3.micro Rocky9 EC2s in the public subnet,
# each running 2 probe processes against 2 Redis serverless endpoints.
#
# Prereq: all 20 Redis serverless caches must be `available`.
# Usage: ./deploy_ec2.sh
set -euo pipefail

REGION="us-east-1"
AMI="ami-07f1ef003bc5de2b1"          # Rocky 9.8 official (owner 792107900819)
TYPE="t3.micro"
KEY="IAD-keypair"
SG="sg-0eb3345a02b867177"            # SSH-ALL
SUBNET="subnet-075bd6ca78e696342"    # public subnet (IGW route)
REDIS_PORT=6379
NPROBES=20
NEC2=10

HERE="$(cd "$(dirname "$0")" && pwd)"
PROBE_SRC="$HERE/RedisProbe.java"
REPORT_SRC="$HERE/daily_report.sh"
TEMPLATE="$HERE/userdata.template.sh"

# 1. collect endpoints test1..test20 (must be available)
declare -A EP
for i in $(seq 1 $NPROBES); do
  name="LW-EC-serverless-test${i}"
  addr=$(aws elasticache describe-serverless-caches --serverless-cache-name "$name" --region "$REGION" \
          --query 'ServerlessCaches[0].Endpoint.Address' --output text 2>/dev/null || echo None)
  if [ "$addr" = "None" ] || [ -z "$addr" ]; then
    echo "ERROR: ${name} endpoint not ready (addr=$addr). Aborting."; exit 1
  fi
  EP[$i]="$addr"
done
echo "All 20 endpoints resolved."

# 2. launch 10 EC2s, each mapped to (2i-1, 2i)
for e in $(seq 1 $NEC2); do
  a=$(( (e-1)*2 + 1 ))
  b=$(( (e-1)*2 + 2 ))
  aName="test${a}"; bName="test${b}"
  aHost="${EP[$a]}"; bHost="${EP[$b]}"

  # build userdata by injecting sources + hosts
  ud=$(mktemp)
  cp "$TEMPLATE" "$ud"
  # inject sources via python to avoid sed escaping hell
  python3 - "$ud" "$PROBE_SRC" "$REPORT_SRC" "$aHost" "$aName" "$bHost" "$bName" <<'PY'
import sys
ud, probe, report, aHost, aName, bHost, bName = sys.argv[1:8]
t = open(ud).read()
t = t.replace("__PROBE_SOURCE__", open(probe).read())
t = t.replace("__REPORT_SOURCE__", open(report).read())
t = t.replace("__REDIS_A_HOST__", aHost).replace("__REDIS_A_NAME__", aName)
t = t.replace("__REDIS_B_HOST__", bHost).replace("__REDIS_B_NAME__", bName)
open(ud,"w").write(t)
PY

  iid=$(aws ec2 run-instances --region "$REGION" \
    --image-id "$AMI" --instance-type "$TYPE" --key-name "$KEY" \
    --security-group-ids "$SG" --subnet-id "$SUBNET" \
    --associate-public-ip-address \
    --user-data "file://$ud" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=redis-probe-${e}},{Key=Project,Value=redis-failover-test}]" \
    --query 'Instances[0].InstanceId' --output text)
  echo "EC2-${e} ${iid} -> ${aName}(${aHost}) , ${bName}(${bHost})"
  rm -f "$ud"
done

echo "=== launched. waiting for public IPs ==="
sleep 20
aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Project,Values=redis-failover-test" "Name=instance-state-name,Values=pending,running" \
  --query 'Reservations[].Instances[].{Name:Tags[?Key==`Name`]|[0].Value,Id:InstanceId,PubIp:PublicIpAddress,State:State.Name}' \
  --output table
