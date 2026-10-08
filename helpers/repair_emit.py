#!/usr/bin/env python3
"""Write the two JSON documents `hopwatch --repair` produces.

Called from lib/repairs.sh with everything already resolved in bash and
passed through NETDIAG_REPAIR_* environment variables — the same handshake
every other helper here uses, because bash cannot escape a string into JSON
safely. Nothing is hand-assembled into a JSON literal in the shell.

  result            print the --json result object on stdout:
                    {"id","ok","dry_run","ran":[...],"message"}
  journal PATH      append one `repair` line to the event journal at PATH.
                    The caller has already checked that the file exists;
                    this never creates it.

The journal line is shaped like the monitor's (helpers/monitor_sample.py):
`t`, `network`, `kind`, `from`, `to`, `summary`. `kind` is `repair` — a
kind helpers/events.py reads for the timeline and never pairs into a fault
episode, because a repair is something the user did, not something that
went wrong. `network` is null: the repair CLI is not a monitor and does not
know which network it ran on, and a journal reader folds a null-network
line onto its neighbours (events.fold_identity).
"""

from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timezone

RS = "\x1e"


def _env(name: str) -> str:
    return os.environ.get(f"NETDIAG_REPAIR_{name}", "")


def _ran() -> list[str]:
    return [line for line in _env("RAN").split("\n") if line]


def _params() -> dict[str, str]:
    out = {}
    for kv in _env("PARAMS").split(RS) if _env("PARAMS") else []:
        key, sep, value = kv.partition("=")
        if sep and key:
            out[key] = value
    return out


def result() -> dict:
    return {
        "id": _env("ID"),
        "ok": _env("OK") == "1",
        "dry_run": _env("DRY") == "1",
        "ran": _ran(),
        "message": _env("MESSAGE"),
    }


def journal_line() -> dict:
    ok = _env("OK") == "1"
    return {
        "t": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "seq": None,
        "network": None,
        "network_label": None,
        "kind": "repair",
        "field": "repair",
        "from": None,
        "to": _env("ID"),
        "summary": _env("MESSAGE"),
        "ok": ok,
        "params": _params(),
    }


def main() -> int:
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    if mode == "result":
        json.dump(result(), sys.stdout, separators=(",", ":"))
        sys.stdout.write("\n")
        return 0
    if mode == "journal" and len(sys.argv) > 2:
        path = sys.argv[2]
        if not os.path.isfile(path):
            return 0
        try:
            with open(path, "a", encoding="utf-8") as handle:
                handle.write(json.dumps(journal_line(), separators=(",", ":"),
                                        default=str) + "\n")
        except OSError:
            return 1
        return 0
    print("repair_emit.py: usage: repair_emit.py result | journal PATH",
          file=sys.stderr)
    return 3


if __name__ == "__main__":
    sys.exit(main())
