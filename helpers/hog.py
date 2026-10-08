#!/usr/bin/env python3
"""Turn `nettop` snapshots into "which processes are moving data, how fast".

Evidence for rule HOG-1 (docs/DIAGNOSIS-RULES.md). Reads on stdin the output
of

    nettop -P -L N -s S -J bytes_in,bytes_out

and writes a few pipe-separated lines on stdout. Parsing and bookkeeping
only: nothing here decides whether a rate is large. That judgement belongs to
lib/common.sh (hog_judge) reading lib/thresholds.sh, like every other verdict.

    usage: hog.py <interval_seconds> <this_process_pid>

Output:

    M|<snapshots>|<down_total>|<up_total>|<down_excluded>|<up_excluded>
    P|<pid>|<name>|<down_avg>|<down_min>|<up_avg>|<up_min>     (0..12 lines)

All rates are Mb/s. `M` is the only line when fewer than two snapshots were
read (the caller then treats the run as not measured). `total` is everything
that is not Hopwatch's own, *including* processes whose ancestry could not be
read; `excluded` is Hopwatch's own traffic plus those unreadable processes.
`P` lines never include either kind. `avg` is over the whole window, `min` is
the slowest single interval, which is what "sustained" is judged on.

Input format, as seen on macOS 26 (the header and the time column both vary
between runs, so neither is relied on):

    ,bytes_in,bytes_out,
    apsd.377,133700,50712,
    Google Chrome H.7130,14159689,1901746,
    ,bytes_in,bytes_out,
    apsd.377,133700,50712,

Every snapshot after the first is also cumulative, not a delta. A name may
hold spaces and dots, so the pid is what follows the last dot, and the two
counters are taken from the right.

What counts as Hopwatch's own, and why it is not just a list of names: the
monitor is a different process from a full check, and a full check
deliberately saturates the link with `curl` and `speedtest`. A name list
cannot tell that `curl` from the user's own, and `$$` ancestry cannot see a
process this one did not start. So a process is Hopwatch's when

  * it is this process or a descendant of it, or
  * any ancestor is a Hopwatch command line (`hopwatch` or `netdiag`, run
    directly or as the script argument of a shell), which is how a full
    check started by the app, a terminal or the launchd watcher is
    recognised from outside, or
  * its name is one of the probe tools only Hopwatch runs here.

A process that nettop reported but `ps` no longer lists cannot be shown to be
anyone's, so it is neither named nor trusted: it lands in `excluded`.
"""

import os
import re
import subprocess
import sys

# Tools Hopwatch runs that are not otherwise recognised by ancestry (an
# orphan whose parent has gone). `curl` and `python3` are deliberately absent:
# they are ordinary programs the user also runs, and their Hopwatch-spawned
# instances are caught by ancestry. nettop cuts names at 15 characters.
SELF_NAMES = frozenset({
    "hopwatch", "netdiag", "speedtest", "speedtest-cli", "mtr", "mtr-packet",
    "ping", "ping6", "traceroute", "traceroute6", "dig", "sntp", "nettop",
    "gping",
})
HOPWATCH_CLI = frozenset({"hopwatch", "netdiag"})
SHELLS = frozenset({"bash", "zsh", "sh", "dash", "ksh"})

_PROC = re.compile(r"^(?P<name>.*)\.(?P<pid>\d+)$")
_TIME_PREFIX = re.compile(r"^\d{1,2}:\d{2}:\d{2}(?:\.\d+)?,")
_SCRIPT = re.compile(r"^(?:.*?/)?(?:hopwatch|netdiag)(?:\s|$)")
_SHELL_C = re.compile(r"^-[A-Za-z]*c[A-Za-z]*$")
MAX_DEPTH = 40
TOP_PER_DIRECTION = 6


def parse_snapshots(text):
    """List of {pid: (name, bytes_in, bytes_out)}, oldest first."""
    snapshots = []
    current = None
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        if "bytes_in" in line:
            current = {}
            snapshots.append(current)
            continue
        if current is None:
            continue
        line = _TIME_PREFIX.sub("", line, count=1)
        parts = line.rstrip(",").rsplit(",", 2)
        if len(parts) != 3:
            continue
        match = _PROC.match(parts[0].strip())
        if not match:
            continue
        try:
            bytes_in, bytes_out = int(parts[1]), int(parts[2])
        except ValueError:
            continue
        pid = int(match.group("pid"))
        name = match.group("name")
        prev = current.get(pid)
        if prev:
            bytes_in += prev[1]
            bytes_out += prev[2]
        current[pid] = (name, bytes_in, bytes_out)
    return snapshots


def process_table():
    """{pid: (ppid, command)} from one `ps`, or None when it cannot be read."""
    try:
        out = subprocess.run(
            ["ps", "-ax", "-ww", "-o", "pid=,ppid=,command="],
            capture_output=True, text=True, timeout=10, check=False,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    table = {}
    for line in out.splitlines():
        fields = line.split(None, 2)
        if len(fields) < 2 or not (fields[0].isdigit() and fields[1].isdigit()):
            continue
        table[int(fields[0])] = (int(fields[1]), fields[2] if len(fields) > 2 else "")
    return table or None


def is_hopwatch_cli(command):
    """True for `hopwatch ...`, `netdiag ...` and `bash /path/to/hopwatch ...`."""
    tokens = command.split()
    if not tokens:
        return False
    first = os.path.basename(tokens[0])
    if first in HOPWATCH_CLI:
        return True
    if first not in SHELLS:
        return False
    rest = tokens[1:]
    i = 0
    while i < len(rest) and rest[i].startswith("-"):
        if _SHELL_C.match(rest[i]):
            return False  # `bash -c '...'`: the script is a string, not a file
        i += 1
    script = " ".join(rest[i:])
    return bool(_SCRIPT.match(script))


def is_own(pid, name, table, self_pid):
    """Whether this process is Hopwatch's (see the module docstring)."""
    if name.strip().lower() in SELF_NAMES:
        return True
    seen = set()
    current = pid
    for _ in range(MAX_DEPTH):
        if current == self_pid:
            return True
        if current <= 1 or current in seen or current not in table:
            return False
        seen.add(current)
        ppid, command = table[current]
        if is_hopwatch_cli(command):
            return True
        current = ppid
    return False


def mbps(byte_count, seconds):
    if seconds <= 0:
        return 0.0
    return byte_count * 8 / seconds / 1_000_000


def main():
    if len(sys.argv) != 3:
        print("usage: hog.py <interval_seconds> <pid>", file=sys.stderr)
        return 3
    try:
        interval = float(sys.argv[1])
        self_pid = int(sys.argv[2])
    except ValueError:
        print("hog.py: interval must be a number and pid an integer", file=sys.stderr)
        return 3

    snapshots = parse_snapshots(sys.stdin.read())
    count = len(snapshots)
    if count < 2 or interval <= 0:
        print(f"M|{count}|0|0|0|0")
        return 0

    table = process_table()
    pids = set()
    names = {}
    for snap in snapshots:
        for pid, (name, _, _) in snap.items():
            pids.add(pid)
            names[pid] = name

    # Per pid, per interval: (down, up) in Mb/s. An interval where the pid is
    # missing from either end, or where a counter went backwards (a reused
    # pid: the two numbers describe different processes), counts as zero.
    rates = {}
    for pid in pids:
        per_interval = []
        for older, newer in zip(snapshots, snapshots[1:]):
            if pid in older and pid in newer:
                d_in = newer[pid][1] - older[pid][1]
                d_out = newer[pid][2] - older[pid][2]
                if d_in >= 0 and d_out >= 0:
                    per_interval.append((mbps(d_in, interval), mbps(d_out, interval)))
                    continue
            per_interval.append((0.0, 0.0))
        rates[pid] = per_interval

    total = [0.0, 0.0]
    excluded = [0.0, 0.0]
    rows = []
    for pid, per_interval in rates.items():
        down_avg = sum(r[0] for r in per_interval) / len(per_interval)
        up_avg = sum(r[1] for r in per_interval) / len(per_interval)
        if down_avg <= 0 and up_avg <= 0:
            continue
        name = names[pid]
        if table is not None and pid in table and is_own(pid, name, table, self_pid):
            excluded[0] += down_avg
            excluded[1] += up_avg
            continue
        if table is None or pid not in table:
            # Counts toward the total, so it can only make a candidate look
            # less dominant, and toward `excluded`, so it can void a direction.
            if table is not None and name.strip().lower() in SELF_NAMES:
                excluded[0] += down_avg
                excluded[1] += up_avg
                continue
            total[0] += down_avg
            total[1] += up_avg
            excluded[0] += down_avg
            excluded[1] += up_avg
            continue
        total[0] += down_avg
        total[1] += up_avg
        rows.append((
            pid, name, down_avg, min(r[0] for r in per_interval),
            up_avg, min(r[1] for r in per_interval),
        ))

    print("M|%d|%.3f|%.3f|%.3f|%.3f" % (count, total[0], total[1], excluded[0], excluded[1]))
    chosen = {}
    for key in (2, 4):
        for row in sorted(rows, key=lambda r: r[key], reverse=True)[:TOP_PER_DIRECTION]:
            if row[key] > 0:
                chosen[row[0]] = row
    for row in sorted(chosen.values(), key=lambda r: max(r[2], r[4]), reverse=True):
        # `|` is the field separator; a process name containing one is rare
        # but possible, and must not shift the columns.
        print("P|%d|%s|%.3f|%.3f|%.3f|%.3f" % (
            row[0], row[1].replace("|", "_"), row[2], row[3], row[4], row[5]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
