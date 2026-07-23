# Redis Serverless Failover 测试 - 部署清单

部署时间：2026-07-23 04:08 UTC
Region: us-east-1 | AMI: Rocky 9.8 | Type: t3.micro | Key: IAD-keypair | SG: SSH-ALL

## EC2 ↔ Redis 映射（EC2-N → test(2N-1, 2N)）

| EC2 | InstanceId | PubIP | Redis A | Redis B |
|-----|-----------|-------|---------|---------|
| 1 | i-06fa33f68479cfb2b | 52.86.124.77 | test1 | test2 |
| 2 | i-06eb3dff79552d90a | 3.91.195.140 | test3 | test4 |
| 3 | i-0e15a78ca521be3dd | 18.208.127.8 | test5 | test6 |
| 4 | i-0673beeddda873f9b | 54.161.225.56 | test7 | test8 |
| 5 | i-0266fbf10cf58da95 | 54.208.147.40 | test9 | test10 |
| 6 | i-03ef688bd48835e9c | 18.205.157.29 | test11 | test12 |
| 7 | i-0146800d4d320da1e | 32.198.4.190 | test13 | test14 |
| 8 | i-078a6840163a77b2c | 34.238.136.242 | test15 | test16 |
| 9 | i-0b3959e7a7f727ffe | 54.165.207.151 | test17 | test18 |
| 10 | i-0ec28a6811c092e7b | 3.82.126.52 | test19 | test20 |

## 清理命令（测完删）
```bash
# 删 EC2
aws ec2 terminate-instances --region us-east-1 --instance-ids \
  i-06fa33f68479cfb2b i-06eb3dff79552d90a i-0e15a78ca521be3dd i-0673beeddda873f9b \
  i-0266fbf10cf58da95 i-03ef688bd48835e9c i-0146800d4d320da1e i-078a6840163a77b2c \
  i-0b3959e7a7f727ffe i-0ec28a6811c092e7b
# 删 20 台 Redis
for i in $(seq 1 20); do aws elasticache delete-serverless-cache --serverless-cache-name lw-ec-serverless-test${i} --region us-east-1; done
```
