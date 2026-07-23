# Redis Serverless Failover 长跑探测

针对 AWS ElastiCache **Redis Serverless** 的长期运行 failover / 连接稳定性测试工具集。

## 目标

在 20 台 ElastiCache Serverless（Redis 7.1）上长期跑读写探测，验证长跑状态下是否出现 failover / 断联，并统计：

- 读写成功数 / 失败数
- 读写延迟 **p50 / p99**
- **断联事件**：断联开始、恢复时间、持续时长
- 每天 **09:30（北京时间, UTC+8）** 汇总当日日志推送到飞书机器人

## 架构

```
10 × EC2 (t3.micro, Rocky 9, public subnet)
  └─ 每台跑 2 个独立 Java 进程 (systemd)
       ├─ probe-a → Redis testX
       └─ probe-b → Redis testY
  └─ cron 01:30 UTC (=09:30 北京) → daily_report.sh → 飞书 webhook
```

映射关系：`EC2-N → test(2N-1), test(2N)`，10 台覆盖全部 20 个 Redis。

## 组件

| 文件 | 说明 |
|---|---|
| `RedisProbe.java` | Jedis 4.4.8 探针。每秒 10 写 + 10 读；1000 key 循环 + TTL 300s + 小 value（**防止 serverless 数据跑飞**）；记录延迟/成功失败/断联事件到日志 |
| `daily_report.sh` | 汇总本机两个探针日志，格式化后推送飞书 webhook（含 EC2 实例ID / 公网IP / Redis endpoint / 全部指标） |
| `userdata.template.sh` | EC2 启动脚本模板：装 JDK11 + 拉 Jedis 依赖 + 编译探针 + 起 2 个 systemd 服务 + 配 cron |
| `deploy_ec2.sh` | 编排脚本：解析 20 个 endpoint，一键开 10 台 EC2 并注入 userdata |

## 关键设计

### 防跑飞（数据规模控制）
- Key 空间固定 **1000 个**，循环复用
- 每个 key 带 **TTL 300s**，自动过期
- value 仅几十字节
- 稳态数据量恒定在 ~几 MB 级，绝不膨胀

### TLS
ElastiCache Serverless **强制 TLS**，探针使用 SSL 连接（6379 + TLS）。

### 断联统计
探针捕获 `JedisConnectionException`：
- 首次失败 → 记 `disconnectStart`，`disconnects++`
- 恢复成功 → 记录 `DISCONNECT_RECOVERED start=.. end=.. durationMs=..`

## 部署前提

1. 20 台 ElastiCache Serverless (test1~test20) 全部 `available`
   - ⚠️ 注意：Serverless 依赖 **VPC Interface Endpoint**，账号需有足够 interface endpoint 配额，否则创建会 `create-failed`
2. 公有子网（含 IGW 路由）
3. EC2 key pair、SSH 安全组就绪

## 部署

```bash
./deploy_ec2.sh
```

## 环境参数（us-east-1）

| 项 | 值 |
|---|---|
| AMI | `ami-07f1ef003bc5de2b1` (Rocky 9.8 官方) |
| 实例类型 | t3.micro |
| 公有子网 | subnet-075bd6ca78e696342 |
| SSH 安全组 | sg-0eb3345a02b867177 (SSH-ALL) |
| Redis 安全组 | sg-036b092dfe96e44bb |
| key pair | IAD-keypair |

## 指标日志格式

```
METRICS ts=.. name=test1 ec2=i-.. pubIp=.. host=..:6379 writeOk=.. writeFail=.. readOk=.. readFail=.. wP50us=.. wP99us=.. rP50us=.. rP99us=.. disconnects=..
DISCONNECT_RECOVERED start=.. end=.. durationMs=..
```
