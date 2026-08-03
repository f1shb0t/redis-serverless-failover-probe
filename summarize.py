#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Summarize redisprobe logs for the daily Feishu report.

Why this exists
---------------
v1 的 bash 报表直接读最后一条 METRICS 行的 disconnects= 字段，
而那个计数器是 JVM 进程内的 AtomicLong —— 进程一重启（OOM kill / 机器重启）就归零，
但 DISCONNECT_RECOVERED 事件行是落盘的、永久保留。
结果就是「断联次数: 0」却列出了断联事件，自相矛盾。

这里改为：
  * 所有计数一律从日志文件重新统计（跨进程重启做真累计：按 START 分段，段末 METRICS 求和）
  * 断联次数 = 日志中 DISCONNECT_RECOVERED 行数（累计 / 近 24h 分开给）
  * 额外报告进程重启次数、当前段运行时长
  * 自动归因：断联时刻若落在本机 OOM kill / 重启 ±180s 内，标注为本机原因，而非 Redis 侧

Output: report text on stdout.
"""
import glob
import os
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone

LOGDIR = os.environ.get("PROBE_LOGDIR", "/opt/redisprobe/logs")
NOW = datetime.now(timezone.utc)
CUT24 = NOW - timedelta(hours=24)
CUT_ATTR = NOW - timedelta(days=7)  # 归因回溯窗口（比展示窗口长，老事件也能标注原因）
NEAR_SECONDS = 180  # 断联时刻与本机事件的关联窗口


def parse_ts(s):
    """2026-08-02T02:40:45Z -> aware datetime"""
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


# ---------- host-level events (OOM / reboot) ----------
def sh(cmd):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=20)
        return r.stdout
    except Exception:
        return ""


def host_events():
    """Return (oom_list, boot_list) of aware datetimes within last 24h (+ details)."""
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
            proc = ""      # 解析到非进程名的噪声（例如日志里回显的正则本身），丢弃
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


def attribute(dt):
    """给断联事件加归因标签"""
    if dt is None:
        return ""
    for odt, proc in OOMS:
        if abs((dt - odt).total_seconds()) <= NEAR_SECONDS:
            return "  [本机 OOM kill%s，非 Redis 侧]" % (" -> " + proc if proc else "")
    for bdt in BOOTS:
        if abs((dt - bdt).total_seconds()) <= NEAR_SECONDS:
            return "  [本机重启前后，非 Redis 侧]"
    return ""


# ---------- per-probe summary ----------
blocks = []
warn_lines = []

for path in sorted(glob.glob(os.path.join(LOGDIR, "*.log"))):
    name = os.path.basename(path)[:-4]
    if name == "report":  # cron 自己的输出，不是 probe 日志
        continue

    segments = []       # 每个 START..(下一个 START) 段的段末 METRICS
    cur_metrics = None
    starts = []         # 每次进程启动的时间
    discs = []          # 断联事件

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

    wok, wfail = total("writeOk"), total("writeFail")
    rok, rfail = total("readOk"), total("readFail")

    disc_total = len(discs)
    disc_24h = 0
    ev_lines = []
    for d in discs:
        st = parse_ts(d.get("start", ""))
        if st and st >= CUT24:
            disc_24h += 1
        # 展示最近的事件（不限 24h，但优先近的）
        ev_lines.append((st, "    - %s → %s  (%s ms)%s" % (
            d.get("start", "?"), d.get("end", "?"), d.get("durationMs", "?"),
            attribute(st))))
    ev_lines = ev_lines[-5:]

    restarts = max(0, len(starts) - 1)
    restarts_24h = sum(1 for s in starts if s >= CUT24)
    seg_uptime = ""
    if starts:
        seg_uptime = human_dur((NOW - starts[-1]).total_seconds())

    b = []
    b.append("\n▶ Redis [%s] (%s)" % (name, host))
    b.append("  写: 成功 %d / 失败 %d  |  读: 成功 %d / 失败 %d  (跨重启累计)" % (wok, wfail, rok, rfail))
    b.append("  写延迟 p50/p99: %s/%s µs  |  读延迟 p50/p99: %s/%s µs  (当前进程滚动窗口)" % (
        last.get("wP50us", "-"), last.get("wP99us", "-"),
        last.get("rP50us", "-"), last.get("rP99us", "-")))
    b.append("  断联次数: 累计 %d 次 / 近24h %d 次" % (disc_total, disc_24h))
    b.append("  进程重启: 累计 %d 次 / 近24h %d 次  |  当前进程已跑 %s" % (
        restarts, restarts_24h, seg_uptime or "-"))
    if ev_lines:
        b.append("  最近断联事件:")
        for _, ln in ev_lines:
            b.append(ln)
    else:
        b.append("  最近断联事件: 无")
    blocks.append("\n".join(b))

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

print("".join(blocks) + ("\n" + "\n".join(host_block) if host_block else ""))
