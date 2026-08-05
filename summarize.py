#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Summarize redisprobe logs for the daily Feishu report.  -- v2

目标：把「Redis 侧事件」和「测试客户端自身噪音」彻底分开，只让真正的 Redis
问题进入告警视野。

v1 -> v2 的变化
---------------
v1 的读写失败数取自每段最后一条 METRICS 的 writeFail=/readFail=，而 METRICS
每 60s 才落盘一次；进程被 OOM SIGKILL 时最后 <60s 的成败数据全丢，导致被杀的
test6/test8 反而显示「0 失败 0 断联」。

v2 改为：
  * 失败数 = 统计日志里的 OPFAIL 行（probe 在每次失败时即时 append 落盘，
    SIGKILL 也不丢）；成功数仍从 METRICS 取（成功不必逐条落盘，量太大）
  * 每个失败/断联事件都带 probe 在出事瞬间采集的 verdict（本机 watchdog 漂移 /
    GC 暂停 / IMDS 可达性 / DNS / 裸 TCP），不再依赖事后 journalctl 时间相关性猜测
  * 按 verdict 把事件分成 REDIS_* 与 CLIENT_* 两类，分别汇总
  * TRANSIENT（未达连续失败阈值的单点抖动）单独计数，不再污染「断联次数」

verdict 取值
------------
  REDIS_UNREACHABLE          DNS 通但裸 TCP 连不上 -> endpoint 真不可达
  REDIS_REACHABLE_BUT_FAILING TCP 通但命令超时 -> 可达不服务（failover 典型指纹）
  CLIENT_HOST_STALL          watchdog 漂移大 -> 本机冻住（OOM 回收/CPU steal/swap）
  CLIENT_GC_PAUSE            GC 暂停增量大
  CLIENT_HOST_UNHEALTHY      link-local IMDS 都打不通 -> 本机/JVM 异常
  CLIENT_DNS_FAIL            DNS 解析失败

Output: report text on stdout.
"""
import glob
import os
import re
import subprocess
from collections import Counter
from datetime import datetime, timedelta, timezone

LOGDIR = os.environ.get("PROBE_LOGDIR", "/opt/redisprobe/logs")
NOW = datetime.now(timezone.utc)
CUT24 = NOW - timedelta(hours=24)
CUT_ATTR = NOW - timedelta(days=7)
NEAR_SECONDS = 180

# verdict 前缀 -> 是否属于 Redis 侧
REDIS_VERDICTS = ("REDIS_",)
CLIENT_VERDICTS = ("CLIENT_",)

VERDICT_ZH = {
    "REDIS_UNREACHABLE": "Redis 不可达（DNS 通/TCP 不通）",
    "REDIS_REACHABLE_BUT_FAILING": "Redis 可达但不服务（failover 特征）",
    "CLIENT_HOST_STALL": "本机冻住（OOM/CPU steal/swap）",
    "CLIENT_GC_PAUSE": "客户端 GC 暂停",
    "CLIENT_HOST_UNHEALTHY": "本机异常（IMDS 不可达）",
    "CLIENT_DNS_FAIL": "客户端 DNS 失败",
    "UNKNOWN": "未判定",
}


def parse_ts(s):
    try:
        return datetime.strptime(s.strip(), "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except Exception:
        return None


def kv(line):
    d = {}
    for tok in line.split():
        if "=" in tok:
            k, v = tok.split("=", 1)
            d[k] = v
    return d


def human_dur(seconds):
    seconds = int(seconds)
    d, rem = divmod(seconds, 86400)
    h, rem = divmod(rem, 3600)
    m, _ = divmod(rem, 60)
    if d:
        return "%dd %dh" % (d, h)
    if h:
        return "%dh %dm" % (h, m)
    return "%dm" % m


def is_redis(verdict):
    return any(verdict.startswith(p) for p in REDIS_VERDICTS)


def is_client(verdict):
    return any(verdict.startswith(p) for p in CLIENT_VERDICTS)


# ---------- host-level events (OOM / reboot) ----------
def sh(cmd):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=20)
        return r.stdout
    except Exception:
        return ""


def host_events():
    ooms = []
    out = sh(["journalctl", "--utc", "--no-pager", "-o", "short-iso",
              "--since", "7 days ago", "-g", "Out of memory: Killed process"])
    for ln in out.splitlines():
        m = re.match(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})", ln)
        if not m:
            continue
        dt = datetime.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)
        proc = ""
        mp = re.search(r"Killed process\s+\d+\s+\(([^)]+)\)", ln)
        if mp:
            proc = mp.group(1)
        else:
            mp = re.search(r"task=([^,\s]+)", ln)
            if mp:
                proc = mp.group(1)
        if proc and not re.match(r"^[\w.:@+-]+$", proc):
            proc = ""
        if (dt, proc) not in ooms:
            ooms.append((dt, proc))

    boots = []
    out = sh(["journalctl", "--utc", "--no-pager", "--list-boots"])
    for ln in out.splitlines():
        m = re.search(r"(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})", ln)
        if not m:
            continue
        try:
            dt = datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S").replace(tzinfo=timezone.utc)
        except Exception:
            continue
        if dt >= CUT_ATTR:
            boots.append(dt)
    if not boots:
        cur = sh(["uptime", "-s"]).strip()
        if cur:
            try:
                boots.append(datetime.strptime(cur, "%Y-%m-%d %H:%M:%S").replace(tzinfo=timezone.utc))
            except Exception:
                pass
    return ooms, boots


def kernel_ver():
    return sh(["uname", "-r"]).strip() or "-"


OOMS, BOOTS = host_events()


def host_corroborate(dt):
    """
    宿主日志侧证。注意：这只是辅助佐证，主判据是 probe 自己在出事瞬间采集的
    verdict —— 时间相关性会把「同时刻发生的 Redis 故障」误伤成本机问题。
    """
    if dt is None:
        return ""
    for odt, proc in OOMS:
        if abs((dt - odt).total_seconds()) <= NEAR_SECONDS:
            return "  (宿主侧证: OOM kill%s)" % (" -> " + proc if proc else "")
    for bdt in BOOTS:
        if abs((dt - bdt).total_seconds()) <= NEAR_SECONDS:
            return "  (宿主侧证: 本机重启前后)"
    return ""


# ---------- per-probe summary ----------
blocks = []
warn_lines = []
grand_redis_events = 0
grand_client_events = 0

for path in sorted(glob.glob(os.path.join(LOGDIR, "*.log"))):
    name = os.path.basename(path)[:-4]
    if name == "report":
        continue

    segments = []
    cur_metrics = None
    starts = []
    discs = []          # DISCONNECT_RECOVERED
    disc_starts = []    # DISCONNECT_START（可能还没恢复）
    opfails = []        # OPFAIL（即时落盘，永不丢）
    transients = []

    try:
        fh = open(path, "r", errors="replace")
    except OSError as e:
        warn_lines.append("读取 %s 失败: %s" % (path, e))
        continue

    with fh:
        for line in fh:
            if line.startswith("START"):
                if cur_metrics is not None:
                    segments.append(cur_metrics)
                cur_metrics = None
                d = kv(line)
                ts = parse_ts(d.get("ts", ""))
                if ts:
                    starts.append(ts)
            elif line.startswith("METRICS"):
                cur_metrics = kv(line)
            elif line.startswith("DISCONNECT_RECOVERED"):
                discs.append(kv(line))
            elif line.startswith("DISCONNECT_START"):
                disc_starts.append(kv(line))
            elif line.startswith("OPFAIL"):
                opfails.append(kv(line))
            elif line.startswith("TRANSIENT"):
                transients.append(kv(line))
    if cur_metrics is not None:
        segments.append(cur_metrics)

    if not segments:
        warn_lines.append("%s: 没有 METRICS 数据（进程刚起？）" % name)
        continue

    last = segments[-1]
    host = last.get("host", "-")

    def total(field):
        s = 0
        for seg in segments:
            try:
                s += int(seg.get(field, 0))
            except ValueError:
                pass
        return s

    wok, rok = total("writeOk"), total("readOk")

    # --- 失败数改由 OPFAIL 行统计（即时落盘，OOM SIGKILL 也不丢）---
    wfail = sum(1 for d in opfails if d.get("op") == "write")
    rfail = sum(1 for d in opfails if d.get("op") == "read")
    wfail_24h = sum(1 for d in opfails
                    if d.get("op") == "write" and (parse_ts(d.get("ts", "")) or NOW) >= CUT24)
    rfail_24h = sum(1 for d in opfails
                    if d.get("op") == "read" and (parse_ts(d.get("ts", "")) or NOW) >= CUT24)

    # --- 按 verdict 拆分 Redis 侧 / 客户端侧 ---
    fail_by_verdict = Counter(d.get("verdict", "UNKNOWN") for d in opfails)
    redis_fails = sum(n for v, n in fail_by_verdict.items() if is_redis(v))
    client_fails = sum(n for v, n in fail_by_verdict.items() if is_client(v))

    # 断联事件：优先用已恢复的记录，未恢复的 START 也列出来
    recovered_starts = set(d.get("start", "") for d in discs)
    pending = [d for d in disc_starts if d.get("ts", "") not in recovered_starts]

    redis_disc = [d for d in discs if is_redis(d.get("verdict", ""))]
    client_disc = [d for d in discs if is_client(d.get("verdict", ""))]
    disc_24h = sum(1 for d in discs if (parse_ts(d.get("start", "")) or NOW) >= CUT24)
    redis_disc_24h = sum(1 for d in redis_disc if (parse_ts(d.get("start", "")) or NOW) >= CUT24)

    grand_redis_events += len(redis_disc)
    grand_client_events += len(client_disc)

    restarts = max(0, len(starts) - 1)
    restarts_24h = sum(1 for s in starts if s >= CUT24)
    seg_uptime = human_dur((NOW - starts[-1]).total_seconds()) if starts else ""

    b = []
    b.append("\n▶ Redis [%s] (%s)" % (name, host))
    b.append("  写: 成功 %d / 失败 %d  |  读: 成功 %d / 失败 %d  (跨重启累计)" % (wok, wfail, rok, rfail))
    if wfail_24h or rfail_24h:
        b.append("    近24h 失败: 写 %d / 读 %d" % (wfail_24h, rfail_24h))
    b.append("  写延迟 p50/p99: %s/%s µs  |  读延迟 p50/p99: %s/%s µs  (当前进程滚动窗口)" % (
        last.get("wP50us", "-"), last.get("wP99us", "-"),
        last.get("rP50us", "-"), last.get("rP99us", "-")))

    # 核心：Redis 侧 vs 客户端侧
    b.append("  ── 归因拆分 ──")
    b.append("  🔴 Redis 侧: 断联 %d 次(近24h %d) / 失败 op %d 次" % (
        len(redis_disc), redis_disc_24h, redis_fails))
    b.append("  ⚪ 客户端噪音: 断联 %d 次 / 失败 op %d 次 (已排除，非 Redis 问题)" % (
        len(client_disc), client_fails))
    if transients:
        b.append("  · 单点抖动(未达断联阈值): %d 次" % len(transients))
    b.append("  进程重启: 累计 %d 次 / 近24h %d 次  |  当前进程已跑 %s" % (
        restarts, restarts_24h, seg_uptime or "-"))

    # 事件明细：Redis 侧优先完整展示
    if redis_disc:
        b.append("  🔴 Redis 侧断联明细:")
        for d in redis_disc[-5:]:
            st = parse_ts(d.get("start", ""))
            b.append("    - %s → %s  (%s ms)  [%s]%s" % (
                d.get("start", "?"), d.get("end", "?"), d.get("durationMs", "?"),
                VERDICT_ZH.get(d.get("verdict", ""), d.get("verdict", "")),
                host_corroborate(st)))
    if client_disc:
        b.append("  ⚪ 客户端侧断联明细(仅供参考):")
        for d in client_disc[-3:]:
            st = parse_ts(d.get("start", ""))
            b.append("    - %s → %s  (%s ms)  [%s]%s" % (
                d.get("start", "?"), d.get("end", "?"), d.get("durationMs", "?"),
                VERDICT_ZH.get(d.get("verdict", ""), d.get("verdict", "")),
                host_corroborate(st)))
    if pending:
        b.append("  ⚠ 未恢复的断联:")
        for d in pending[-3:]:
            b.append("    - %s 起，至今未恢复  [%s]" % (
                d.get("ts", "?"), VERDICT_ZH.get(d.get("verdict", ""), d.get("verdict", ""))))
    if not redis_disc and not client_disc and not pending:
        b.append("  最近断联事件: 无")

    # 失败异常类型分布（帮助定性）
    if opfails:
        exc_dist = Counter(d.get("exc", "?") for d in opfails).most_common(4)
        b.append("  失败异常类型: %s" % ", ".join("%s×%d" % (k, v) for k, v in exc_dist))

    blocks.append("\n".join(b))

# ---------- 顶部结论 ----------
head = []
if grand_redis_events == 0:
    head.append("✅ 结论: 本机所有 probe 无 Redis 侧断联（客户端噪音已剔除）")
else:
    head.append("🔴 结论: 检测到 %d 次 Redis 侧断联，需关注" % grand_redis_events)
if grand_client_events:
    head.append("   （另有 %d 次客户端侧事件，已归为噪音）" % grand_client_events)

# ---------- host-level warning block ----------
host_block = []
if [x for x in OOMS if x[0] >= CUT24] or [b for b in BOOTS if b >= CUT24]:
    host_block.append("\n⚠ 本机异常（近24h，会误伤 probe，注意区分）:")
    for dt, proc in [x for x in OOMS if x[0] >= CUT24]:
        host_block.append("  - OOM kill: %s  被杀进程: %s" % (
            dt.strftime("%Y-%m-%dT%H:%M:%SZ"), proc or "?"))
    for dt in [b for b in BOOTS if b >= CUT24]:
        host_block.append("  - 重启: %s  当前内核: %s" % (
            dt.strftime("%Y-%m-%dT%H:%M:%SZ"), kernel_ver()))

for w in warn_lines:
    host_block.append("  ! %s" % w)

print("\n".join(head) + "\n" + "".join(blocks)
      + ("\n" + "\n".join(host_block) if host_block else ""))
