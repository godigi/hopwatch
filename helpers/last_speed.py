#!/usr/bin/env python3
"""The newest stored speed test for one network, as one tab-separated line.

`--monitor` never runs a speed test (it would saturate the link it is
meant to watch), so the activity grid's Streaming row used to read "Speed
unknown" even minutes after a full check had measured 65/52 Mbps. This
reads that measurement back from the run store the full check already
appends to — read-only, as the monitor's contract requires — so the live
sample can say "65 Mbps · measured 29m ago" instead.

Scoped to ONE network on purpose: a speed measured on the hotel's Wi-Fi
says nothing about the flat's. Records are matched with history.py's own
`group_key`, the same identity every other store reader uses, so a run
recorded before lib/netid.sh existed still lands on the right network.

Output: `<down_mbps>\t<up_mbps>\t<epoch_seconds>` — up may be empty — or
nothing at all when there is no usable measurement. No verdict is made
here; whether the figure is too old to use is the sample builder's call,
against THRESH_MON_SPEED_STALE_S.

Usage: last_speed.py --history PATH --network ID
"""

from __future__ import annotations

import argparse
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import history  # noqa: E402  (sibling module; path set above)

_MARKER = '"down_mbps"'


def _epoch(ts) -> int | None:
    if not isinstance(ts, str):
        return None
    try:
        parsed = datetime.fromisoformat(ts[:-1] + "+00:00" if ts.endswith("Z") else ts)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return int(parsed.timestamp())


def _speed_of(rec: dict):
    speed = rec.get("speedtest")
    if not isinstance(speed, dict):
        return None
    down = speed.get("down_mbps")
    if not isinstance(down, (int, float)) or isinstance(down, bool) or down <= 0:
        return None
    up = speed.get("up_mbps")
    up = up if isinstance(up, (int, float)) and not isinstance(up, bool) else None
    return float(down), up


def newest(paths, network: str):
    """(down, up, epoch) of the newest speed test recorded on `network`."""
    import json
    target = history.canonical_network_id(network)
    if not target:
        return None
    best = None
    for path in paths:
        if not path.is_file():
            continue
        try:
            handle = path.open(encoding="utf-8", errors="replace")
        except OSError:
            continue
        with handle:
            for line in handle:
                # A cheap prefilter: most stored runs carry no speed test,
                # and parsing the whole store every slow tier is waste.
                if _MARKER not in line:
                    continue
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(rec, dict) or history.is_redacted(rec):
                    continue
                found = _speed_of(rec)
                at = _epoch(rec.get("timestamp"))
                if found is None or at is None:
                    continue
                if history.group_key(rec)[0] != target:
                    continue
                if best is None or at > best[2]:
                    best = (found[0], found[1], at)
    return best


def main() -> int:
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("--history", type=Path, required=True)
    ap.add_argument("--network", default="")
    args = ap.parse_args()
    stem = str(args.history)
    archive = Path(stem[:-6] + "-archive.jsonl" if stem.endswith(".jsonl")
                   else stem + "-archive.jsonl")
    # The live file first: it holds the newest runs, so the archive is only
    # worth reading when the live file has none for this network.
    for paths in ([args.history], [archive]):
        best = newest(paths, args.network)
        if best:
            down, up, at = best
            sys.stdout.write(f"{down:g}\t{'' if up is None else format(up, 'g')}\t{at}\n")
            return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
