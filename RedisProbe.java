import redis.clients.jedis.DefaultJedisClientConfig;
import redis.clients.jedis.HostAndPort;
import redis.clients.jedis.Jedis;
import redis.clients.jedis.JedisClientConfig;
import redis.clients.jedis.JedisPool;
import redis.clients.jedis.JedisPoolConfig;
import redis.clients.jedis.exceptions.JedisConnectionException;
import redis.clients.jedis.exceptions.JedisDataException;
import redis.clients.jedis.exceptions.JedisException;

import java.io.FileWriter;
import java.io.PrintWriter;
import java.lang.management.GarbageCollectorMXBean;
import java.lang.management.ManagementFactory;
import java.net.InetAddress;
import java.net.Socket;
import java.net.InetSocketAddress;
import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Redis Serverless failover probe -- v2
 *
 * v2 的目标：准确区分「Redis 侧事件」与「测试客户端自身噪音」，
 * 并且让失败记录立刻落盘（不再依赖 60s 一次的 METRICS 快照，
 * 进程被 SIGKILL 也不丢数据）。
 *
 * v1 的三个问题：
 *  1) 失败计数只存在 JVM 内的 AtomicLong，靠每 60s 的 METRICS 落盘。
 *     被 OOM kill 时最后 <60s 的成败数据全丢 -> test6/test8 显示 0 失败 0 断联，
 *     而实际它们是被杀的那一方。
 *  2) 任何单次 op 异常就立刻 markDisconnect()，同 tick 内任一成功就恢复。
 *     -> 单点抖动被记成「断联」（例如 test7 的 121ms 事件纯属伪影）。
 *  3) catch (JedisException e) 把 e 丢掉，事后无法判断是超时 / DNS / 连接池耗尽。
 *     连接池耗尽是纯客户端问题，却会被算成 Redis 断联。
 *
 * v2 的做法：
 *  * OPFAIL 行即时 append 落盘（含异常归类），计数改由日志行数统计 -> 永不丢
 *  * 断联需连续 FAIL_STREAK_THRESHOLD 次失败才成立；单点抖动记为 TRANSIENT
 *  * 出事瞬间采集三类正交证据并写入日志，实现自动归因：
 *      - 本机健康：watchdog 时钟漂移 / GC 累计暂停增量 / IMDS link-local 可达性
 *      - 网络分层：DNS 解析 + 裸 TCP connect（绕过 Jedis/TLS/连接池）
 *      - 异常归类：遍历完整 cause 链
 *  * SIGTERM shutdown hook 落一次终态 METRICS（优雅重启场景补齐尾部数据）
 *
 * Args:
 *   0: redisHost   1: redisPort   2: redisName   3: logFile
 */
public class RedisProbe {
    static final int KEY_SPACE = 1000;
    static final int TTL_SECONDS = 300;
    static final int OPS_PER_TICK = 10;
    static final DateTimeFormatter TS =
            DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'").withZone(ZoneOffset.UTC);

    /** 连续失败达到该次数才判定为「断联」，低于此值记为 TRANSIENT（单点抖动）。 */
    static final int FAIL_STREAK_THRESHOLD = 3;
    /** watchdog 漂移超过该值 -> 本机/JVM 被冻住（OOM 回收、CPU steal、swap 抖动）。 */
    static final long STALL_DRIFT_MS = 2000;
    /** 相邻两次检查之间 GC 累计暂停增量超过该值 -> 归因 GC。 */
    static final long GC_PAUSE_MS = 1000;
    static final int PROBE_TIMEOUT_MS = 1500;

    static final ConcurrentLinkedQueue<Long> writeLat = new ConcurrentLinkedQueue<>();
    static final ConcurrentLinkedQueue<Long> readLat = new ConcurrentLinkedQueue<>();

    static final AtomicLong writeOk = new AtomicLong();
    static final AtomicLong writeFail = new AtomicLong();
    static final AtomicLong readOk = new AtomicLong();
    static final AtomicLong readFail = new AtomicLong();

    static final AtomicBoolean connected = new AtomicBoolean(true);
    static volatile long disconnectStart = 0;
    static volatile String disconnectVerdict = "";
    static final AtomicLong disconnectCount = new AtomicLong();
    /** 连续失败计数；任何成功即清零。 */
    static final AtomicLong failStreak = new AtomicLong();

    // ---- 本机健康 watchdog ----
    /** 最近一次 watchdog 观测到的时钟漂移（ms）。本机冻住时会飙升。 */
    static volatile long lastDrift = 0;
    /** watchdog 最后一次心跳的时间戳；与 now 的差值也能反映冻结。 */
    static volatile long watchdogBeat = System.currentTimeMillis();
    static volatile long lastGcTotal = 0;

    static String host;
    static int port;
    static String logFile;

    public static void main(String[] args) throws Exception {
        host = args[0];
        port = Integer.parseInt(args[1]);
        String name = args[2];
        logFile = args[3];

        JedisPoolConfig pc = new JedisPoolConfig();
        pc.setMaxTotal(8);
        pc.setMaxIdle(4);
        pc.setMinIdle(1);
        pc.setTestOnBorrow(true);
        pc.setMaxWaitMillis(2000);
        // Serverless 强制 TLS，生产恒为 true。
        // PROBE_SSL=false 仅用于本地对着明文假 Redis 做逻辑自测。
        boolean useSsl = !"false".equalsIgnoreCase(System.getenv("PROBE_SSL"));
        JedisClientConfig cfg = DefaultJedisClientConfig.builder()
                .ssl(useSsl)
                .connectionTimeoutMillis(2000)
                .socketTimeoutMillis(2000)
                .build();
        JedisPool pool = new JedisPool(pc, new HostAndPort(host, port), cfg);

        String instanceId = getInstanceId();
        String privateIp = getMeta("local-ipv4");
        String publicIp = getMeta("public-ipv4");

        log(logFile, String.format("START probe name=%s host=%s port=%d ec2=%s privIp=%s pubIp=%s ts=%s ver=2",
                name, host, port, instanceId, privateIp, publicIp, TS.format(Instant.now())));

        lastGcTotal = gcTotalMs();
        startWatchdog();

        // 优雅停止时补一条终态 METRICS（SIGKILL 场景救不了，但那时 OPFAIL 已逐条落盘）
        final String fName = name, fEc2 = instanceId, fPub = publicIp;
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            log(logFile, "SHUTDOWN signal received ts=" + TS.format(Instant.now()));
            flushMetrics(logFile, fName, host, port, fEc2, privateIp, fPub);
        }));

        int tick = 0;
        while (true) {
            long tickStart = System.currentTimeMillis();
            for (int i = 0; i < OPS_PER_TICK; i++) {
                int k = (tick * OPS_PER_TICK + i) % KEY_SPACE;
                String key = name + ":k:" + k;
                String val = "v" + (tickStart % 100000) + "-" + i;

                long t0 = System.nanoTime();
                try (Jedis j = pool.getResource()) {
                    j.setex(key, TTL_SECONDS, val);
                    sample(writeLat, (System.nanoTime() - t0) / 1000);
                    writeOk.incrementAndGet();
                    onSuccess();
                } catch (Exception e) {
                    writeFail.incrementAndGet();
                    onFailure("write", key, e);
                }

                long t1 = System.nanoTime();
                try (Jedis j = pool.getResource()) {
                    j.get(key);
                    sample(readLat, (System.nanoTime() - t1) / 1000);
                    readOk.incrementAndGet();
                    onSuccess();
                } catch (Exception e) {
                    readFail.incrementAndGet();
                    onFailure("read", key, e);
                }
            }

            tick++;
            if (tick % 60 == 0) {
                flushMetrics(logFile, name, host, port, instanceId, privateIp, publicIp);
            }
            long elapsed = System.currentTimeMillis() - tickStart;
            long sleep = 1000 - elapsed;
            if (sleep > 0) Thread.sleep(sleep);
        }
    }

    // ================= 失败处理与归因 =================

    /**
     * 每次失败都立刻写一行 OPFAIL 落盘 —— 这是 v2 的核心。
     * 计数不再依赖内存里的 AtomicLong，报表改为统计日志行数，进程被 SIGKILL 也不丢。
     */
    static void onFailure(String op, String key, Exception e) {
        long streak = failStreak.incrementAndGet();
        // 取证做了 DNS + TCP，真断联时 20 ops/s 全失败会放大成探测风暴。
        // 只在失败序列首次、以及之后每 EVIDENCE_MIN_INTERVAL_MS 做一次，其余复用上次结论。
        Evidence ev = evidenceThrottled(streak == 1);
        String cls = classify(e);

        log(logFile, String.format(
                "OPFAIL ts=%s op=%s streak=%d exc=%s verdict=%s driftMs=%d gcMs=%d imds=%s dns=%s tcp=%s msg=%s",
                TS.format(Instant.now()), op, streak, cls, ev.verdict,
                ev.driftMs, ev.gcDeltaMs, ev.imdsOk, ev.dnsOk, ev.tcpOk,
                sanitize(rootMessage(e))));

        // 只有连续失败到阈值才算真断联，单点抖动不算
        if (streak >= FAIL_STREAK_THRESHOLD && connected.compareAndSet(true, false)) {
            disconnectStart = System.currentTimeMillis();
            disconnectVerdict = ev.verdict;
            disconnectCount.incrementAndGet();
            log(logFile, String.format("DISCONNECT_START ts=%s verdict=%s exc=%s",
                    TS.format(Instant.ofEpochMilli(disconnectStart)), ev.verdict, cls));
        }
    }

    static void onSuccess() {
        long prev = failStreak.getAndSet(0);
        if (connected.compareAndSet(false, true)) {
            long end = System.currentTimeMillis();
            long dur = end - disconnectStart;
            log(logFile, String.format("DISCONNECT_RECOVERED start=%s end=%s durationMs=%d verdict=%s",
                    TS.format(Instant.ofEpochMilli(disconnectStart)),
                    TS.format(Instant.ofEpochMilli(end)), dur,
                    disconnectVerdict.isEmpty() ? "UNKNOWN" : disconnectVerdict));
        } else if (prev > 0 && prev < FAIL_STREAK_THRESHOLD) {
            // 抖动了但没到断联阈值，单独记账，方便和真断联区分
            log(logFile, String.format("TRANSIENT ts=%s failsBeforeRecover=%d",
                    TS.format(Instant.now()), prev));
        }
    }

    /** 三类正交证据的快照。 */
    static class Evidence {
        long driftMs, gcDeltaMs;
        boolean imdsOk, dnsOk, tcpOk;
        String verdict = "UNKNOWN";
    }

    static final long EVIDENCE_MIN_INTERVAL_MS = 5000;
    static volatile long lastEvidenceAt = 0;
    static volatile Evidence lastEvidence = null;

    /**
     * 取证节流：force=true（失败序列首次）或距上次取证超过 EVIDENCE_MIN_INTERVAL_MS 才真做，
     * 否则复用上次结论，避免断联期间 DNS/TCP 探测风暴。
     */
    static Evidence evidenceThrottled(boolean force) {
        long now = System.currentTimeMillis();
        Evidence cached = lastEvidence;
        if (!force && cached != null && (now - lastEvidenceAt) < EVIDENCE_MIN_INTERVAL_MS) {
            return cached;
        }
        Evidence ev = collectEvidence();
        lastEvidence = ev;
        lastEvidenceAt = now;
        return ev;
    }

    /**
     * 出事瞬间取证并判定。顺序即优先级：先排除本机因素，再看网络分层。
     */
    static Evidence collectEvidence() {
        Evidence ev = new Evidence();
        long now = System.currentTimeMillis();

        // ① 本机是否被冻住：watchdog 漂移 + 心跳陈旧度
        ev.driftMs = Math.max(lastDrift, now - watchdogBeat);
        // ② GC 暂停增量
        long gcNow = gcTotalMs();
        ev.gcDeltaMs = Math.max(0, gcNow - lastGcTotal);
        lastGcTotal = gcNow;

        if (ev.driftMs >= STALL_DRIFT_MS) {
            // 本机已冻住，不必再做网络探测（此时探测本身也会超时，反而误导）
            ev.verdict = "CLIENT_HOST_STALL";
            return ev;
        }
        if (ev.gcDeltaMs >= GC_PAUSE_MS) {
            ev.verdict = "CLIENT_GC_PAUSE";
            return ev;
        }

        // IMDS 是 link-local，正常永不失败；失败即本机/JVM 层面异常
        ev.imdsOk = getMeta("instance-id") != null;
        if (!ev.imdsOk) {
            ev.verdict = "CLIENT_HOST_UNHEALTHY";
            return ev;
        }

        // ③ 网络分层：DNS -> 裸 TCP（绕过 Jedis / TLS / 连接池）
        ev.dnsOk = dnsResolves(host);
        if (!ev.dnsOk) {
            ev.verdict = "CLIENT_DNS_FAIL";
            return ev;
        }
        ev.tcpOk = tcpConnects(host, port);
        ev.verdict = ev.tcpOk ? "REDIS_REACHABLE_BUT_FAILING" : "REDIS_UNREACHABLE";
        return ev;
    }

    /**
     * 遍历完整 cause 链做异常归类。
     *
     * 注意 Jedis 版本差异：JedisExhaustedPoolException 只存在于 Jedis 3.x。
     * 4.4.8 里该类已移除，Pool.getResource() 把 commons-pool2 的异常统一包装成
     * JedisException(msg, cause)，池耗尽时 cause 是 java.util.NoSuchElementException。
     * 这里按真实类型匹配，避免用不存在的类名做字符串比较导致永远命中不到。
     */
    static String classify(Throwable e) {
        for (Throwable t = e; t != null; t = t.getCause()) {
            // 池耗尽 = 纯客户端问题（并发/池配置），必须和 Redis 侧故障分开
            if (t instanceof java.util.NoSuchElementException) return "POOL_EXHAUSTED";
            if (t instanceof java.net.SocketTimeoutException) return "SOCKET_TIMEOUT";
            if (t instanceof java.net.UnknownHostException) return "DNS_UNKNOWN_HOST";
            if (t instanceof java.net.ConnectException) return "TCP_CONNECT_REFUSED";
            if (t instanceof java.net.NoRouteToHostException) return "NO_ROUTE";
            if (t instanceof javax.net.ssl.SSLException) return "TLS_ERROR";
            if (t instanceof JedisDataException) return "SERVER_DATA_ERROR"; // 服务端有回应 => 活着
            if (t instanceof java.io.EOFException) return "EOF_CONN_CLOSED";
            if (t instanceof InterruptedException) return "INTERRUPTED";
        }
        // Jedis 4.x 无论「DNS 无记录」还是「connect 超时/被拒」，都可能只抛一层
        // JedisConnectionException + 同一句 "Failed to connect to any host resolved for DNS name"，
        // 光看异常无法区分。所以这里只标记为「连接建立失败」，
        // 真正的定性交给 collectEvidence() 的独立 DNS/TCP 探测（verdict 字段）。
        String rm = rootMessage(e);
        if (e instanceof JedisConnectionException) {
            if (rm != null && rm.contains("resolved for DNS name")) return "CONN_ESTABLISH_FAIL";
            return "JEDIS_CONN";
        }
        if (e instanceof JedisException) return "JEDIS_OTHER";
        return e.getClass().getSimpleName();
    }

    static String rootMessage(Throwable e) {
        Throwable t = e;
        while (t.getCause() != null) t = t.getCause();
        String m = t.getMessage();
        return (m == null || m.isEmpty()) ? t.getClass().getSimpleName() : m;
    }

    /** 日志是空格分隔的 k=v，值里不能有空格/换行。 */
    static String sanitize(String s) {
        if (s == null) return "-";
        s = s.replaceAll("[\\r\\n\\t ]+", "_");
        return s.length() > 160 ? s.substring(0, 160) : s;
    }

    // ================= 本机健康探测 =================

    /**
     * 独立线程每 500ms 睡一次并测量实际漂移。
     * 本机 OOM 回收 / CPU steal / swap 抖动时，漂移会显著超过预期。
     */
    static void startWatchdog() {
        Thread t = new Thread(() -> {
            while (true) {
                long before = System.currentTimeMillis();
                try {
                    Thread.sleep(500);
                } catch (InterruptedException ie) {
                    return;
                }
                long actual = System.currentTimeMillis() - before;
                lastDrift = Math.max(0, actual - 500);
                watchdogBeat = System.currentTimeMillis();
            }
        }, "host-watchdog");
        t.setDaemon(true);
        t.start();
    }

    static long gcTotalMs() {
        long sum = 0;
        for (GarbageCollectorMXBean b : ManagementFactory.getGarbageCollectorMXBeans()) {
            long c = b.getCollectionTime();
            if (c > 0) sum += c;
        }
        return sum;
    }

    static boolean dnsResolves(String h) {
        try {
            InetAddress.getByName(h);
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    /** 裸 TCP connect，绕过 Jedis / TLS / 连接池，判断 endpoint 本身是否可达。 */
    static boolean tcpConnects(String h, int p) {
        try (Socket s = new Socket()) {
            s.connect(new InetSocketAddress(h, p), PROBE_TIMEOUT_MS);
            return s.isConnected();
        } catch (Exception e) {
            return false;
        }
    }

    // ================= 原有工具方法 =================

    static void sample(ConcurrentLinkedQueue<Long> q, long v) {
        q.add(v);
        while (q.size() > 20000) q.poll();
    }

    static long pct(List<Long> sorted, double p) {
        if (sorted.isEmpty()) return 0;
        int idx = (int) Math.ceil(p / 100.0 * sorted.size()) - 1;
        if (idx < 0) idx = 0;
        if (idx >= sorted.size()) idx = sorted.size() - 1;
        return sorted.get(idx);
    }

    static void flushMetrics(String logFile, String name, String host, int port,
                             String ec2, String privIp, String pubIp) {
        List<Long> ws = new ArrayList<>(writeLat);
        List<Long> rs = new ArrayList<>(readLat);
        ws.sort(Long::compareTo);
        rs.sort(Long::compareTo);
        String line = String.format(
            "METRICS ts=%s name=%s ec2=%s pubIp=%s host=%s:%d writeOk=%d writeFail=%d readOk=%d readFail=%d " +
            "wP50us=%d wP99us=%d rP50us=%d rP99us=%d disconnects=%d driftMs=%d",
            TS.format(Instant.now()), name, ec2, pubIp, host, port,
            writeOk.get(), writeFail.get(), readOk.get(), readFail.get(),
            pct(ws,50), pct(ws,99), pct(rs,50), pct(rs,99), disconnectCount.get(), lastDrift);
        log(logFile, line);
    }

    static synchronized void log(String file, String msg) {
        try (PrintWriter pw = new PrintWriter(new FileWriter(file, true))) {
            pw.println(msg);
        } catch (Exception e) {
            System.err.println("log fail: " + e.getMessage());
        }
        System.out.println(msg);
    }

    static String getInstanceId() { String s = getMeta("instance-id"); return s == null ? "unknown" : s; }

    static String getMeta(String path) {
        try {
            java.net.HttpURLConnection tc = (java.net.HttpURLConnection)
                new java.net.URL("http://169.254.169.254/latest/api/token").openConnection();
            tc.setRequestMethod("PUT");
            tc.setRequestProperty("X-aws-ec2-metadata-token-ttl-seconds", "60");
            tc.setConnectTimeout(500); tc.setReadTimeout(500);
            String token = new String(tc.getInputStream().readAllBytes()).trim();
            java.net.HttpURLConnection c = (java.net.HttpURLConnection)
                new java.net.URL("http://169.254.169.254/latest/meta-data/" + path).openConnection();
            c.setRequestProperty("X-aws-ec2-metadata-token", token);
            c.setConnectTimeout(500); c.setReadTimeout(500);
            return new String(c.getInputStream().readAllBytes()).trim();
        } catch (Exception e) { return null; }
    }
}
