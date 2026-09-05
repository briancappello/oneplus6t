#!/usr/bin/env python3
"""Summarise one shutdown-trace capture directory (see shutdown-trace.sh).

    ./droidian/shutdown-trace-report.py logs/shutdown-trace/<stamp>

Every source carries the kernel's monotonic clock, so they merge into one
timeline: the journal until journald dies, the watcher until systemd-shutdown
kills it, the ramoops console until the kernel restarts. The report says how
long each phase took, what was in D state and where, what the kernel's hung
task detector saw, and where the silent gaps are.
"""
import os
import re
import sys
from collections import Counter

TS = re.compile(r"\[ *([0-9]+\.[0-9]+)\]")
WATCH = re.compile(r"shutdown-trace\[([0-9.]+)\] (.*)")


def read(d, name):
    p = os.path.join(d, name)
    if not os.path.exists(p):
        return []
    with open(p, "rb") as f:
        return f.read().decode("utf-8", "replace").splitlines()


def stamped(lines, src):
    out = []
    for l in lines:
        m = TS.match(l)
        if m:
            out.append((float(m.group(1)), src, l[m.end():].strip()))
    return out


def main(d):
    journal = read(d, "journal.log")
    watch = read(d, "watch.log")
    # pstore archive if the zones survived a boot, else the ramdump read-out.
    console = read(d, "console-ramoops-0") or read(d, "console.txt")
    pmsg = read(d, "pmsg-ramoops-0") or read(d, "pmsg.txt")
    pre = dict(kv.split("=", 1) for l in read(d, "pre-reboot.txt") for kv in l.replace("pre-reboot: ", "").split() if "=" in kv)
    pon = " ".join(read(d, "next-boot-pon"))

    j = stamped(journal, "journal")
    starts = [t for t, _, m in j if "System is rebooting" in m or "System is powering down" in m]
    if not starts:
        print("no shutdown marker in journal.log"); return 1
    t0 = starts[-1]
    j = [e for e in j if e[0] >= t0 - 1]

    w = []
    for l in watch + pmsg:
        m = WATCH.search(l)
        if m:
            w.append((float(m.group(1)), "watch", m.group(2)))
    w = sorted(set(w))
    c = [e for e in stamped(console, "kernel") if e[0] >= t0 - 1]

    print(f"== shutdown-trace {os.path.basename(d)}")
    print(f"   pre-reboot: {pre}")
    print(f"   next-boot PON: {pon or 'unknown'}   ramoops console: {'PRESENT' if console else 'absent'}   pmsg: {'PRESENT' if pmsg else 'absent'}")
    print()
    print("== durations (s from 'System is rebooting')")
    print(f"   host, reboot request -> kernel restart : {pre.get('host_shutdown_s', '?')}")
    print(f"   journal survived                       : {j[-1][0] - t0:6.1f}")
    if w:
        print(f"   watcher survived                       : {w[-1][0] - t0:6.1f}")
    if c:
        print(f"   ramoops console, last kernel line      : {c[-1][0] - t0:6.1f}   ({c[-1][2][:80]})")
    print()

    print("== milestones")
    marks = [
        ("journal", r"Stopped user@\d+\.service"), ("journal", r"Stopped lxc@android\.service"),
        ("journal", r"Stopped lxc\.service"), ("journal", r"Journal stopped"),
        ("kernel", r"systemd-shutdown\[1\]: (Sending SIGTERM|Sending SIGKILL|Unmounting|Remounting|All filesystems|Detaching loop|Syncing|Rebooting|Powering)"),
        ("kernel", r"hung_task|blocked for more than"), ("kernel", r"subsys-restart|shutdown ack|Port halt|AFTER_SHUTDOWN"),
        ("kernel", r"reboot: |Restarting system|PON |qpnp_pon"),
    ]
    for src, pat in marks:
        rx = re.compile(pat)
        hits = [e for e in (j if src == "journal" else c) if rx.search(e[2])]
        for t, _, m in hits[:6]:
            print(f"   {t - t0:7.1f}  {src:7}  {m[:110]}")
        if len(hits) > 6:
            print(f"            ... {len(hits) - 6} more '{pat[:30]}'")
    print()

    if w:
        print("== watcher: D-state tasks (snapshots seen x comm:stack)")
        dc = Counter()
        pid1 = 0
        for _, _, m in w:
            if "pid1 did not answer" in m:
                pid1 += 1
            for tok in re.findall(r"D:(\S+)", m):
                dc[tok] += 1
        for tok, n in dc.most_common(15):
            print(f"   {n:4}x  {tok[:140]}")
        if pid1:
            print(f"   PID 1 did not answer list-jobs within 2s: {pid1} snapshots")
        print()
        print("== watcher: stop jobs over time")
        last = None
        for t, _, m in w:
            jobs = m.split("|")[0].strip() if m.startswith("jobs:") else m
            if jobs != last:
                print(f"   {t - t0:7.1f}  {jobs[:150]}")
                last = jobs
        print()

    hung = [i for i, l in enumerate(console) if "blocked for more than" in l]
    if hung:
        print("== kernel hung task reports")
        for i in hung[:8]:
            print("   " + console[i][:120])
            for l in console[i + 1:i + 12]:
                if "Call trace" in l or re.search(r"\] +[a-z_]+\+0x", l):
                    print("      " + l.split("]", 1)[-1].strip()[:100])
        print()

    print("== silent gaps > 3s in the merged timeline")
    allev = sorted(j + w + c)
    prev = None
    for e in allev:
        if prev and e[0] - prev[0] > 3:
            print(f"   {prev[0] - t0:7.1f} -> {e[0] - t0:7.1f}  ({e[0] - prev[0]:5.1f}s)")
            print(f"        before: [{prev[1]}] {prev[2][:100]}")
            print(f"        after : [{e[1]}] {e[2][:100]}")
        prev = e
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
