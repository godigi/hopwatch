#!/usr/bin/env python3
"""Read the event journal back: what changed, when, and for how long.

`netdiag --events[=HOURS]` prints one JSON object describing a window of
`~/net-diag/events.jsonl` — the file `--monitor --journal` appends
transitions to.

Why this exists: netdiag could always say what was wrong *now*, and never
what was wrong at 03:14 or for how long. A stored run is a snapshot with
one timestamp; the monitor saw every transition and discarded all of them.
This is the read side of fixing that.

What it does NOT do is judge. There is no "your uptime was bad" here, no
outage classification, no threshold. Episodes are reported with their rule
IDs and durations, and whether a duration is acceptable is a verdict — and
verdicts in this project fire from lib/diagnosis.sh against cutoffs in
lib/thresholds.sh, not from a reader. `AV-1`/`AV-2` are where that will
live; they are deliberately not here.

## Episodes

A rule that fired and later cleared is an *episode* with a duration. They
are paired by (network, rule id), oldest fired to next cleared.

Four honest cases the pairing has to survive:

  * **Still open at the end of the window** — `ongoing: true`, and the
    duration is measured to the last event seen, not to now: the recorder
    may have stopped an hour ago and reporting "ongoing for 4 hours" would
    be inventing observation that never happened.
  * **A monitor restart while open** — the recorder died, was killed, or
    the Mac rebooted. Whatever happened to that fault in between was not
    observed, so the episode is closed at the restart with
    `duration_is_lower_bound: true` rather than silently spanning the gap.
  * **A gap while open** — a sleep or a stall. The episode keeps running
    (the fault plausibly did too) but records `unobserved_s`, so a reader
    can tell a four-hour outage from a four-hour closed lid.
  * **A clear with no fire before it** — the fault began before the window
    (or before the recorder existed). Reported with `started: null`,
    `duration_s: null` and `start_unobserved: true`: an end with no
    beginning is still an end, and dropping it would omit exactly the
    fault someone asking "was it down last night?" is asking about.

## Observation

Every window reports what fraction of itself was actually watched.
`MonitorSeries.swift` refuses to draw a line across a gap because "a
smooth line through a two-minute outage is *reassuring*"; an availability
figure computed over a window the Mac spent asleep tells the same lie with
a number instead of a line.
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

SCHEMA_EVENTS = 1


def _parse_ts(value):
    """A journal timestamp as an aware datetime, or None if unusable.

    Unparseable is not an error: a truncated final line (the recorder
    killed mid-write) should cost one event, not the whole answer.
    """
    if not isinstance(value, str):
        return None
    try:
        if value.endswith("Z"):
            return datetime.fromisoformat(value[:-1] + "+00:00")
        return datetime.fromisoformat(value)
    except (ValueError, TypeError):
        return None


def load(paths):
    """Every readable event line from `paths`, oldest first, deduped.

    Deduped on (t, seq, kind, to) because the archive roll appends before
    it truncates — see `_journal_prune` in helpers/monitor_sample.py. A
    crash between those two steps duplicates lines rather than dropping
    them, which is the safe failure precisely because this dedupes.
    """
    seen = set()
    rows = []
    for path in paths:
        if not path or not Path(path).is_file():
            continue
        try:
            with open(path, encoding="utf-8") as handle:
                for line in handle:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        row = json.loads(line)
                    except ValueError:
                        continue
                    if not isinstance(row, dict):
                        continue
                    key = (row.get("t"), row.get("seq"), row.get("kind"),
                           row.get("to"))
                    if key in seen:
                        continue
                    seen.add(key)
                    row["_at"] = _parse_ts(row.get("t"))
                    rows.append(row)
        except OSError:
            continue
    rows.sort(key=lambda r: (r["_at"] or datetime.min.replace(
        tzinfo=timezone.utc), r.get("seq") or 0))
    return rows


def in_window(rows, hours, now=None):
    """The rows inside the last `hours`, and the window's own bounds.

    `now` is injectable so a test does not depend on the clock — the same
    reason tests/test_summary.bats scopes its assertions to a line.
    """
    if not rows:
        return [], None, None
    now = now or datetime.now(timezone.utc)
    if not hours:
        kept = [r for r in rows if r["_at"]]
        start = kept[0]["_at"] if kept else None
        return kept, start, now
    start = now - timedelta(hours=hours)
    return [r for r in rows if r["_at"] and r["_at"] >= start], start, now


def episodes(rows):
    """Pair rule-fired with the next rule-cleared for the same rule.

    Keyed on (network, rule) rather than rule alone: the same fault on two
    networks is two episodes, and a laptop that moves between them would
    otherwise have one network's clear close the other's fault.
    """
    open_eps: dict[tuple, dict] = {}
    done: list[dict] = []

    def close(key, at, reason, lower_bound=False):
        ep = open_eps.pop(key, None)
        if ep is None:
            return
        ep["ended"] = at.strftime("%Y-%m-%dT%H:%M:%SZ") if at else None
        if at and ep["_started_at"]:
            ep["duration_s"] = int((at - ep["_started_at"]).total_seconds())
        ep["ended_by"] = reason
        if lower_bound:
            ep["duration_is_lower_bound"] = True
        done.append(ep)

    for row in rows:
        kind, at = row.get("kind"), row["_at"]
        network = row.get("network")

        if kind == "rule-fired" and row.get("to"):
            key = (network, row["to"])
            if key in open_eps:
                # Fired twice with no clear between: the recorder restarted
                # and re-observed the same fault. Keep the earlier start,
                # which is the earliest moment it is known to have been true.
                continue
            open_eps[key] = {
                "rule": row["to"],
                "summary": row.get("summary"),
                "network": network,
                "network_label": row.get("network_label"),
                "started": row.get("t"),
                "ended": None,
                "duration_s": None,
                "ongoing": True,
                "unobserved_s": 0,
                "_started_at": at,
            }
        elif kind == "rule-cleared" and row.get("from"):
            key = (network, row["from"])
            if key in open_eps:
                open_eps[key]["ongoing"] = False
                close(key, at, "cleared")
            else:
                # An orphan clear: the fire is not in what was read. Usually
                # because the window cut it off — `--events=24` on a fault
                # that began the previous evening — and sometimes because
                # the recorder was installed mid-fault or the archive rolled.
                #
                # This used to contribute no episode at all, which meant
                # "was the internet down last night, and for how long?" —
                # the question this reader exists to answer — silently
                # omitted the likeliest shape of a yes. The raw row stayed
                # in `events`, which is no help to anything reading
                # `episodes`.
                #
                # An end with no beginning is still an end. It is reported
                # with `started` and `duration_s` null: the start was not
                # observed, so none is claimed and none is derived. Same
                # answer `ActivityEntry.fold` gives the GUI for the same
                # input — a resolved episode with no duration, never a
                # guessed one.
                done.append({
                    "rule": row["from"],
                    "summary": row.get("summary"),
                    "network": network,
                    "network_label": row.get("network_label"),
                    "started": None,
                    "start_unobserved": True,
                    "ended": at.strftime("%Y-%m-%dT%H:%M:%SZ") if at else None,
                    "duration_s": None,
                    "ongoing": False,
                    "unobserved_s": 0,
                    "ended_by": "cleared",
                })
        elif kind == "monitor-started":
            # Everything still open was being watched by a process that is
            # no longer running. Close each at this restart rather than
            # letting it span a period nobody observed.
            for key in list(open_eps):
                open_eps[key]["ongoing"] = False
                close(key, at, "monitor-restart", lower_bound=True)
        elif kind == "gap":
            gap = row.get("gap_s") or 0
            for ep in open_eps.values():
                ep["unobserved_s"] += gap

    # Whatever is still open ran to the end of what was recorded. Measure
    # it to the last event, never to now: the recorder may have stopped.
    last_at = rows[-1]["_at"] if rows else None
    for key in list(open_eps):
        close(key, last_at, "still-open")

    for ep in done:
        ep.pop("_started_at", None)
    # An unknown start sorts first: it began at or before the earliest
    # start there is, which is the only thing known about it. Sorting it by
    # its end instead would place it among episodes whose starts are known
    # and imply one for it.
    done.sort(key=lambda e: (e.get("started") or ""))
    return done


def periods(eps, join_s):
    """Fold episodes into unstable periods: one line per stretch of trouble.

    A link that flaps produces many short episodes of the same rule — on
    the live network 14 of them in an hour, "14 times · 1m19s+ total" —
    and a reader asking "was it unstable?" wants ONE answer, not a list to
    count. Episodes of one rule on one network whose gap (previous end to
    next start) is under `join_s` are the same period. Bounded by that
    distance and nothing else, so an hour of flapping with a ten-minute
    calm in the middle is two periods, not one.

    This is grouping, not judging: `join_s` is lib/thresholds.sh's
    THRESH_MON_UNSTABLE_WINDOW_S, handed in by bin/hopwatch — the same
    figure after which the live monitor stops calling a link "recently
    unstable". With none supplied there is nothing to join on and no
    periods are reported, rather than guessing one here.

    An episode with no observed start (an orphan clear) is never merged:
    its place in time is unknown.
    """
    if not join_s or join_s <= 0:
        return []
    out: list[dict] = []
    by_key: dict[tuple, dict] = {}
    ordered = sorted((e for e in eps if e.get("started")),
                     key=lambda e: e["started"])
    for ep in ordered:
        start = _parse_ts(ep["started"])
        end = _parse_ts(ep.get("ended")) or start
        key = (ep.get("network"), ep["rule"])
        cur = by_key.get(key)
        if cur is not None and start is not None and cur["_end"] is not None \
                and (start - cur["_end"]).total_seconds() < join_s:
            cur["spikes"] += 1
            cur["observed_s"] += ep.get("duration_s") or 0
            cur["unobserved_s"] += ep.get("unobserved_s") or 0
            if end and end > cur["_end"]:
                cur["_end"] = end
            cur["ended"] = ep.get("ended")
            cur["ongoing"] = bool(ep.get("ongoing"))
            cur["duration_is_lower_bound"] = (cur["duration_is_lower_bound"]
                                              or bool(ep.get("duration_is_lower_bound")))
            if ep.get("summary"):
                cur["summary"] = ep["summary"]
            continue
        cur = {
            "rule": ep["rule"],
            "summary": ep.get("summary"),
            "network": ep.get("network"),
            "network_label": ep.get("network_label"),
            "started": ep["started"],
            "ended": ep.get("ended"),
            "ongoing": bool(ep.get("ongoing")),
            "spikes": 1,
            "observed_s": ep.get("duration_s") or 0,
            "unobserved_s": ep.get("unobserved_s") or 0,
            "duration_is_lower_bound": bool(ep.get("duration_is_lower_bound")),
            "_start": start,
            "_end": end,
        }
        by_key[key] = cur
        out.append(cur)
    for per in out:
        a, b = per.pop("_start"), per.pop("_end")
        per["span_s"] = int((b - a).total_seconds()) if a and b else None
    return out


def observation(rows, start, end):
    """How much of the window was actually watched."""
    gaps = [r for r in rows if r.get("kind") == "gap"]
    unobserved = sum(int(r.get("gap_s") or 0) for r in gaps)
    span = int((end - start).total_seconds()) if start and end else None
    fraction = None
    if span and span > 0:
        fraction = round(min(unobserved / span, 1.0), 4)
    return {
        "window_s": span,
        "gap_count": len(gaps),
        "unobserved_s": unobserved,
        "unobserved_fraction": fraction,
        "monitor_starts": sum(1 for r in rows
                              if r.get("kind") == "monitor-started"),
    }


def main() -> int:
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("--journal", type=Path, required=True)
    ap.add_argument("--archive", type=Path, default=None)
    ap.add_argument("--hours", type=float, default=None)
    ap.add_argument("--version", default="")
    ap.add_argument("--join-s", type=float, default=None,
                    help="join distance for `periods` (THRESH_MON_UNSTABLE_WINDOW_S)")
    args = ap.parse_args()

    archive = args.archive
    if archive is None:
        stem = str(args.journal)
        archive = Path(stem[:-6] + "-archive.jsonl" if stem.endswith(".jsonl")
                       else stem + "-archive.jsonl")

    rows = load([archive, args.journal])
    kept, start, end = in_window(rows, args.hours)

    by_kind: dict[str, int] = {}
    for row in kept:
        kind = row.get("kind") or "unknown"
        by_kind[kind] = by_kind.get(kind, 0) + 1

    eps = episodes(kept)
    out = {
        "schema": SCHEMA_EVENTS,
        "version": args.version,
        "window_hours": args.hours,
        "from": start.strftime("%Y-%m-%dT%H:%M:%SZ") if start else None,
        "to": end.strftime("%Y-%m-%dT%H:%M:%SZ") if end else None,
        "counts": {"events": len(kept), "by_kind": by_kind},
        "observation": observation(kept, start, end),
        "episodes": eps,
        "periods": periods(eps, args.join_s),
        "events": [{k: v for k, v in row.items() if k != "_at"}
                   for row in kept],
    }
    json.dump(out, sys.stdout, separators=(",", ":"), default=str)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
