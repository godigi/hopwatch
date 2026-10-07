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

Five honest cases the pairing has to survive:

  * **Still open at the end of the window** — `ongoing: true`, and the
    duration is measured to the last event seen, not to now: the recorder
    may have stopped an hour ago and reporting "ongoing for 4 hours" would
    be inventing observation that never happened.
  * **A monitor restart while open** — the recorder died, was killed, or
    the Mac rebooted. Whatever happened to that fault in between was not
    observed, so the episode is closed at the restart with
    `duration_is_lower_bound: true` rather than silently spanning the gap.
  * **...unless the same fault re-fires straight after it** — see below.
  * **A gap while open** — a sleep or a stall. The episode keeps running
    (the fault plausibly did too) but records `unobserved_s`, so a reader
    can tell a four-hour outage from a four-hour closed lid.
  * **A clear with no fire before it** — the fault began before the window
    (or before the recorder existed). Reported with `started: null`,
    `duration_s: null` and `start_unobserved: true`: an end with no
    beginning is still an end, and dropping it would omit exactly the
    fault someone asking "was it down last night?" is asking about.

## A restart is a blind spot, not necessarily an end

The app restarts the monitor routinely (a cadence change, and starting and
ending its 60-second investigation burst), and each restart writes
`monitor-started`. A fresh monitor's first sample is only a baseline, so a
fault that is still going is re-reported a few samples later as a brand new
`rule-fired`. Read literally, one continuous 40-minute router fault came out
as a dozen episodes of 10-69 s, every one "ended by monitor-restart".

A fresh monitor now says what it found: each rule already firing in its
first sample is journaled as a `rule-fired` marked `already_firing`
(`_rules_at_start` in helpers/monitor_sample.py). A fault that simply
carries on across a restart therefore re-appears at the restart itself, and
the reader joins it to the episode the restart closed. With no episode to
join, it is an episode with `start_unobserved`: first seen then, begun
earlier. Journals written before that carry no such line, and are read the
older way, below.

So an episode closed by a restart stays a *candidate* for a short while. If
the same rule fires again on the same network within
THRESH_EV_RESTART_BRIDGE_S of the latest restart, the two are one episode:
it keeps its first start, its duration spans both, and the time from the
restart to the re-fire is added to `unobserved_s` — nobody saw that stretch,
the same way nobody sees a `gap` — with `restarts_bridged` counting how many
restarts were stepped over. How the merged episode *ends* is however its
last segment ended: cleared, still open, or (with `duration_is_lower_bound`)
another restart nothing followed. If nothing re-fires in the window it stays
exactly what it was: closed at the restart, as a lower bound.

An old journal can also end such a candidate with a `rule-cleared` that has
no fire before it. The fresh monitor was carrying the rule from its first
sample, which was never written down; the clear is the end of the fault the
restart closed, so they are one episode rather than a restart-ended episode
and an end with no beginning.

The window is a cutoff, so it is in lib/thresholds.sh and arrives through
the environment, with no default here (see `require_env_int`), like every
other cutoff a helper reads. It is *not* a verdict. It answers "how long
does a freshly started monitor take to report a fault that was already
there?", never "was that outage acceptable?"; this file still judges
nothing. Two limits are deliberate:

  * Only a restart-closed episode can be continued. A rule the monitor saw
    *clear* before the restart is over, and a fire after it is a new fault.
  * A restart that arrives more than the window after the previous one ends
    the candidate. A monitor that ran that long without reporting the rule
    was observing, not blind, and silence from it is evidence the fault
    stopped. One replaced inside the window never had a second sample to
    report with, and is no evidence either way.

## Repairs

`hopwatch --repair=ID` appends a `repair` line (helpers/repair_emit.py) to an
existing journal when a repair actually runs: what the user did, and whether
it worked. It is an event like any other (counted in `by_kind`, listed in
`events`) and nothing more. Episodes pair only `rule-fired` with
`rule-cleared`, so a repair never opens, closes or extends one: a repair is
not a fault and does not end one, the monitor clearing the rule does.

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
import os
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

# The one definition of what a network id means — which forms are strong
# (a router MAC), which weak (an SSID, a bare gateway address), and that no
# id at all is "do not decide", never "a new network". gui/.../
# NetworkIdentity.swift ports the same rule.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from history import canonical_network_id  # noqa: E402

SCHEMA_EVENTS = 1


ENV_BRIDGE = "THRESH_EV_RESTART_BRIDGE_S"
ENV_IDENTITY_HOLD = "THRESH_MON_IDENTITY_HOLD_S"


def require_env_int(name):
    """One cutoff from lib/thresholds.sh, or a loud refusal, exit 3.

    No default on purpose, for the reason helpers/history.py gives: a
    default would be a second home for a number that has exactly one, and
    a stale copy still produces a plausible-looking episode count.
    """
    raw = os.environ.get(name, "").strip()
    if not raw:
        print(f"events.py: {name} is not set. It is defined in "
              f"lib/thresholds.sh and exported by bin/hopwatch before this "
              f"helper runs.", file=sys.stderr)
        sys.exit(3)
    try:
        return int(raw)
    except ValueError:
        print(f"events.py: {name}={raw!r} is not a whole number. It is "
              f"defined in lib/thresholds.sh.", file=sys.stderr)
        sys.exit(3)


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


def fold_identity(rows, hold_s):
    """Give each journal line its network, spelled the way its neighbours do.

    The monitor used to derive the id afresh every cycle, and the two things
    it is derived from go quiet while a router struggles: with no default
    route there is no id at all (`"network": null`), and with no ARP entry
    yet the id is a bare gateway address. One physical network was therefore
    journaled as its MAC id, then null, then `wifi:gw=…`, then the MAC id
    again. Episodes are keyed on (network, rule), so a fault that fired under
    one spelling and cleared under another never paired: the fire stayed open
    until the next restart or the next fire of the same rule, and the clear
    stood alone as an end with no beginning. The monitor now holds the id
    (see `_mon_hold_gw_mac`), but journals already written are full of it.

    The rule is the one history.py and NetworkIdentity.fold already apply to
    the same forms: a weak or absent id is not a network of its own, it is
    the strong id it sits beside.

      * A weak line between two sightings of the *same* MAC id is that
        network's, and so is a line with a sighting on only one side (the
        journal begins or ends inside the stretch, or a long gap cuts the
        other side off) when it carries no id at all. A weak line between
        two *different* MAC ids is left alone: the Mac changed networks
        somewhere in that stretch and which side each line is on is not
        something the journal records.
      * A bare gateway address or SSID with a sighting on one side only is
        folded onto that MAC only if the pairing has been seen between two
        sightings elsewhere in the journal, and only if exactly one MAC has
        claimed it. 192.168.1.1 is every third home network; guessing would
        merge two of them.
      * A `gap` of `hold_s` or more is a break, and nothing folds across it:
        a Mac that slept and woke elsewhere has no claim on where it was.

    The original value stays on the line as `network_journaled`, so nothing
    is rewritten silently. Rows are changed in place.
    """
    n = len(rows)
    canon = [canonical_network_id(r.get("network")) for r in rows]

    def strong(i):
        return canon[i] is not None and canon[i].startswith("mac:")

    def breaks(i):
        return (rows[i].get("kind") == "gap"
                and (rows[i].get("gap_s") or 0) >= hold_s)

    # Nearest strong line before / after each line, with no break between.
    prev_strong = [None] * n
    last = None
    for i in range(n):
        if breaks(i):
            last = None
        if strong(i):
            last = i
        prev_strong[i] = last
    next_strong = [None] * n
    last = None
    for i in range(n - 1, -1, -1):
        next_strong[i] = last
        if breaks(i):
            last = None
        elif strong(i):
            last = i

    # Which MAC groups each weak id has been seen inside, and the raw id and
    # label to write for a group.
    claims: dict[str, set] = {}
    spelling: dict[str, tuple] = {}
    target: dict[int, int] = {}
    deferred = []
    for i in range(n):
        if strong(i):
            spelling[canon[i]] = (rows[i].get("network"),
                                  rows[i].get("network_label"))
            continue
        before, after = prev_strong[i], next_strong[i]
        if before is not None and after is not None:
            if canon[before] == canon[after]:
                target[i] = before
                if canon[i] is not None:
                    claims.setdefault(canon[i], set()).add(canon[before])
        elif canon[i] is None and (before is not None or after is not None):
            target[i] = before if before is not None else after
        elif canon[i] is not None and (before is not None or after is not None):
            deferred.append(i)

    for i, j in target.items():
        _refile(rows[i], rows[j].get("network"), rows[j].get("network_label"))
    for i in deferred:
        owners = claims.get(canon[i], set())
        if len(owners) == 1:
            raw, label = spelling[next(iter(owners))]
            _refile(rows[i], raw, label)
    return rows


def _refile(row, network, label):
    row["network_journaled"] = row.get("network")
    row["network"] = network
    row["network_label"] = label


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


def episodes(rows, bridge_s):
    """Pair rule-fired with the next rule-cleared for the same rule.

    Keyed on (network, rule) rather than rule alone: the same fault on two
    networks is two episodes, and a laptop that moves between them would
    otherwise have one network's clear close the other's fault.

    `bridge_s` is how long after a restart the same rule may re-fire and
    still be the episode it interrupted; see the module docstring.
    """
    open_eps: dict[tuple, dict] = {}
    # Episodes closed by a restart that might yet turn out to be continued.
    # Each holds the episode, when the restart that closed it happened
    # (`blind_from`, where the unobserved stretch starts) and the latest
    # restart seen since (`anchor`, which the window is measured from).
    # Anything that stops being a candidate is moved to `done` as it was.
    candidates: dict[tuple, dict] = {}
    done: list[dict] = []

    def close(key, at, reason, lower_bound=False, file=True):
        ep = open_eps.pop(key, None)
        if ep is None:
            return None
        ep["ended"] = at.strftime("%Y-%m-%dT%H:%M:%SZ") if at else None
        if at and ep["_started_at"]:
            ep["duration_s"] = int((at - ep["_started_at"]).total_seconds())
        ep["ended_by"] = reason
        # An episode found already in progress has a measured duration that
        # starts where the monitor first saw it, not where it began.
        if lower_bound or ep.get("start_unobserved"):
            ep["duration_is_lower_bound"] = True
        if file:
            done.append(ep)
        return ep

    def stop_bridging(key):
        done.append(candidates.pop(key)["ep"])

    def reopen(key, at):
        """Take a restart-closed candidate back: the fault carried on."""
        cand = candidates.pop(key)
        ep = cand["ep"]
        for field in ("ended", "ended_by", "duration_is_lower_bound"):
            ep.pop(field, None)
        ep["duration_s"] = None
        ep["ongoing"] = True
        ep["unobserved_s"] += int((at - cand["blind_from"]).total_seconds())
        ep["restarts_bridged"] = ep.get("restarts_bridged", 0) + cand["restarts"]
        open_eps[key] = ep

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
            cand = candidates.get(key)
            if cand is not None:
                if at and (at - cand["anchor"]).total_seconds() <= bridge_s:
                    # The same fault, seen again by a monitor that was
                    # still warming up (or reporting it in its first
                    # sample, with `already_firing`). Reopen the episode
                    # the restart closed rather than starting a second
                    # one, and count everything from that restart to now
                    # as unobserved: no process saw this stretch of it.
                    reopen(key, at)
                    continue
                stop_bridging(key)
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
            if row.get("already_firing"):
                # The monitor's first sample found it firing and no earlier
                # process left an episode open to continue. `started` is
                # then the first moment it is *known* to have been true,
                # and `start_unobserved` says it began earlier.
                open_eps[key]["start_unobserved"] = True
        elif kind == "rule-cleared" and row.get("from"):
            key = (network, row["from"])
            if key in candidates and at:
                # A monitor can only report a clear for a rule that was
                # firing in a sample of its own. The fire was never
                # journaled — in this process's first sample, before it
                # wrote those down — so this is the end of the fault the
                # restart closed, not a new fault that began and ended
                # unseen. Without this the one fault showed up twice: once
                # closed at the restart, once as a clear with no beginning.
                # No window applies: the rule was in the first sample of the
                # process whose start is the candidate's latest restart.
                reopen(key, at)
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
            #
            # Not final yet, though: it stays a candidate to be continued
            # if the same rule re-fires inside the window. Candidates this
            # restart finds already waiting are kept only if the previous
            # restart was itself within the window — a monitor replaced
            # that fast never had a second sample to report with.
            for key in list(candidates):
                cand = candidates[key]
                if at and (at - cand["anchor"]).total_seconds() <= bridge_s:
                    cand["anchor"] = at
                    cand["restarts"] += 1
                else:
                    stop_bridging(key)
            for key in list(open_eps):
                open_eps[key]["ongoing"] = False
                # Held back from `done` until the window has had its say.
                ep = close(key, at, "monitor-restart", lower_bound=True,
                           file=at is None)
                if at:
                    candidates[key] = {"ep": ep, "blind_from": at,
                                       "anchor": at, "restarts": 1}
        elif kind == "gap":
            # Only open episodes take a gap. A candidate's blind stretch is
            # already counted whole, from its restart to its re-fire.
            gap = row.get("gap_s") or 0
            for ep in open_eps.values():
                ep["unobserved_s"] += gap

    # Whatever is still open ran to the end of what was recorded. Measure
    # it to the last event, never to now: the recorder may have stopped.
    last_at = rows[-1]["_at"] if rows else None
    for key in list(open_eps):
        close(key, last_at, "still-open")
    # Nothing re-fired in time, or the record ended first: closed at the
    # restart, as a lower bound, exactly as it was filed.
    for key in list(candidates):
        stop_bridging(key)

    for ep in done:
        ep.pop("_started_at", None)
    # An unknown start sorts first: it began at or before the earliest
    # start there is, which is the only thing known about it. Sorting it by
    # its end instead would place it among episodes whose starts are known
    # and imply one for it.
    done.sort(key=lambda e: (e.get("started") or ""))
    return done


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
    args = ap.parse_args()

    bridge_s = require_env_int(ENV_BRIDGE)
    hold_s = require_env_int(ENV_IDENTITY_HOLD)

    archive = args.archive
    if archive is None:
        stem = str(args.journal)
        archive = Path(stem[:-6] + "-archive.jsonl" if stem.endswith(".jsonl")
                       else stem + "-archive.jsonl")

    # Before the window is cut, so a line at the window's edge can still see
    # the sighting just outside it.
    rows = fold_identity(load([archive, args.journal]), hold_s)
    kept, start, end = in_window(rows, args.hours)

    by_kind: dict[str, int] = {}
    for row in kept:
        kind = row.get("kind") or "unknown"
        by_kind[kind] = by_kind.get(kind, 0) + 1

    out = {
        "schema": SCHEMA_EVENTS,
        "version": args.version,
        "window_hours": args.hours,
        "from": start.strftime("%Y-%m-%dT%H:%M:%SZ") if start else None,
        "to": end.strftime("%Y-%m-%dT%H:%M:%SZ") if end else None,
        "counts": {"events": len(kept), "by_kind": by_kind},
        "observation": observation(kept, start, end),
        "episodes": episodes(kept, bridge_s),
        "events": [{k: v for k, v in row.items() if k != "_at"}
                   for row in kept],
    }
    json.dump(out, sys.stdout, separators=(",", ":"), default=str)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
