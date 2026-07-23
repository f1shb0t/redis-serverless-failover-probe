import redis.clients.jedis.DefaultJedisClientConfig;
import redis.clients.jedis.HostAndPort;
import redis.clients.jedis.Jedis;
import redis.clients.jedis.JedisClientConfig;
import redis.clients.jedis.JedisPool;
import redis.clients.jedis.JedisPoolConfig;
import redis.clients.jedis.exceptions.JedisException;

import java.io.FileWriter;
import java.io.PrintWriter;
import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Redis Serverless failover probe.
 * Each process targets ONE Redis endpoint.
 * - 10 writes + 10 reads per second
 * - bounded key space (1000 keys, TTL 300s, small values) => no runaway growth
 * - records latency (p50/p99), success/fail counts, and disconnect events (duration+recovery)
 * - writes metrics to a rolling log file, consumed by a daily reporter
 *
 * Args:
 *   0: redisHost
 *   1: redisPort
 *   2: redisName (e.g. test1)
 *   3: logFile path
 */
public class RedisProbe {
    static final int KEY_SPACE = 1000;
    static final int TTL_SECONDS = 300;
    static final int OPS_PER_TICK = 10; // 10 writes + 10 reads each second
    static final DateTimeFormatter TS = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'").withZone(ZoneOffset.UTC);

    // rolling latency samples (reservoir kept small)
    static final ConcurrentLinkedQueue<Long> writeLat = new ConcurrentLinkedQueue<>();
    static final ConcurrentLinkedQueue<Long> readLat = new ConcurrentLinkedQueue<>();

    static final AtomicLong writeOk = new AtomicLong();
    static final AtomicLong writeFail = new AtomicLong();
    static final AtomicLong readOk = new AtomicLong();
    static final AtomicLong readFail = new AtomicLong();

    static final AtomicBoolean connected = new AtomicBoolean(true);
    static volatile long disconnectStart = 0;
    static final List<long[]> disconnectEvents = new ArrayList<>(); // {startEpochMs, endEpochMs}
    static final AtomicLong disconnectCount = new AtomicLong();

    public static void main(String[] args) throws Exception {
        String host = args[0];
        int port = Integer.parseInt(args[1]);
        String name = args[2];
        String logFile = args[3];

        JedisPoolConfig pc = new JedisPoolConfig();
        pc.setMaxTotal(8);
        pc.setMaxIdle(4);
        pc.setMinIdle(1);
        pc.setTestOnBorrow(true);
        pc.setMaxWaitMillis(2000);
        // Serverless enforces TLS; connect with SSL on 6379 via client config
        JedisClientConfig cfg = DefaultJedisClientConfig.builder()
                .ssl(true)
                .connectionTimeoutMillis(2000)
                .socketTimeoutMillis(2000)
                .build();
        JedisPool pool = new JedisPool(pc, new HostAndPort(host, port), cfg);

        String instanceId = getInstanceId();
        String privateIp = getMeta("local-ipv4");
        String publicIp = getMeta("public-ipv4");

        log(logFile, String.format("START probe name=%s host=%s port=%d ec2=%s privIp=%s pubIp=%s ts=%s",
                name, host, port, instanceId, privateIp, publicIp, TS.format(Instant.now())));

        int tick = 0;
        while (true) {
            long tickStart = System.currentTimeMillis();
            boolean anyOk = false;
            for (int i = 0; i < OPS_PER_TICK; i++) {
                int k = (tick * OPS_PER_TICK + i) % KEY_SPACE;
                String key = name + ":k:" + k;
                String val = "v" + (tickStart % 100000) + "-" + i; // small value
                // WRITE
                long t0 = System.nanoTime();
                try (Jedis j = pool.getResource()) {
                    j.setex(key, TTL_SECONDS, val);
                    long us = (System.nanoTime() - t0) / 1000;
                    sample(writeLat, us);
                    writeOk.incrementAndGet();
                    anyOk = true;
                } catch (JedisException e) {
                    writeFail.incrementAndGet();
                    markDisconnect();
                }
                // READ
                long t1 = System.nanoTime();
                try (Jedis j = pool.getResource()) {
                    j.get(key);
                    long us = (System.nanoTime() - t1) / 1000;
                    sample(readLat, us);
                    readOk.incrementAndGet();
                    anyOk = true;
                } catch (JedisException e) {
                    readFail.incrementAndGet();
                    markDisconnect();
                }
            }
            if (anyOk) markConnected(logFile);

            tick++;
            // flush a metrics snapshot every 60 ticks (~1 min)
            if (tick % 60 == 0) {
                flushMetrics(logFile, name, host, port, instanceId, privateIp, publicIp);
            }
            long elapsed = System.currentTimeMillis() - tickStart;
            long sleep = 1000 - elapsed;
            if (sleep > 0) Thread.sleep(sleep);
        }
    }

    static void markDisconnect() {
        if (connected.compareAndSet(true, false)) {
            disconnectStart = System.currentTimeMillis();
            disconnectCount.incrementAndGet();
        }
    }

    static void markConnected(String logFile) {
        if (connected.compareAndSet(false, true)) {
            long end = System.currentTimeMillis();
            long dur = end - disconnectStart;
            synchronized (disconnectEvents) {
                disconnectEvents.add(new long[]{disconnectStart, end});
            }
            log(logFile, String.format("DISCONNECT_RECOVERED start=%s end=%s durationMs=%d",
                    TS.format(Instant.ofEpochMilli(disconnectStart)), TS.format(Instant.ofEpochMilli(end)), dur));
        }
    }

    static void sample(ConcurrentLinkedQueue<Long> q, long v) {
        q.add(v);
        // cap reservoir to keep memory bounded
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
            "wP50us=%d wP99us=%d rP50us=%d rP99us=%d disconnects=%d",
            TS.format(Instant.now()), name, ec2, pubIp, host, port,
            writeOk.get(), writeFail.get(), readOk.get(), readFail.get(),
            pct(ws,50), pct(ws,99), pct(rs,50), pct(rs,99), disconnectCount.get());
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
            // IMDSv2
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
