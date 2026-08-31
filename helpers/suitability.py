#!/usr/bin/env python3
"""Project fired diagnosis rules onto "will the thing I'm about to do work?"

`netdiag --json` answers, precisely, one question per rule: is this
metric within its threshold. That is the right question for an expert
reading a report card, and the wrong one for someone who just joined
hotel WiFi and wants to know whether their video call is going to hold.
This module is the layer between the two: it takes the rule IDs the
engine already fired plus a note of which measurement families this run
actually probed, and turns them into five answers — calls, streaming,
gaming, VPN, browsing — each either "good", "degraded", "broken", or
"unmeasured".

── Why this reads no metric, ever ─────────────────────────────────────────
CLAUDE.md names four things that already judge this network:
`lib/diagnosis.sh` (one verdict per scan), `lib/monitor.sh` (one every
few seconds), `helpers/history.py` (one per metric, per stored run, in
`--show`'s comparison, and one per network in `--history`'s `judged`
block) and `helpers/summary.py` (one per metric, per network, over a
window). The last two share `helpers/judgement.py`'s one pair-table
specifically so they cannot disagree with each other. A fifth judge that
read, say, `bufferbloat_gw_ms` for itself and compared it to its own
idea of "too slow for a call" would inevitably drift from
`lib/thresholds.sh`'s idea of the same cutoff — not through carelessness,
just through being maintained on a different day by someone reading a
different file. The day it drifted, this module would render a green
"Calls: fine" row directly above a red B1 paragraph explaining that
calls are currently unusable, on the same screen, from the same run.

So `project()` reads only two things: the list of rule IDs
`lib/diagnosis.sh` (or `lib/monitor.sh`) already decided should fire,
and a set of measurement-family names naming what this run actually
probed. Nothing here re-derives a verdict from a number — the whole
verdict is "which rules, if any, named this activity, and how badly."
`tests/test_suitability.bats` enforces this with an AST walk over this
file's own source: a numeric literal on either side of a comparison
operator fails the build. Treat that as a design invariant this file
exists to hold, not a lint rule it happens to pass.

── Why "unmeasured" is a verdict, not a missing row ───────────────────────
`--quick` skips the bufferbloat probe, the speed test, the internet
packet-loss probe and the path-MTU probe outright — `bin/netdiag:559`
refuses `--mtu-only --quick` in as many words, precisely because
`--quick` already skips the MTU probe on its own. That leaves four of
these five activities un-probeable on a quick run: no rule *can* fire
for "calls" if the loss and bufferbloat checks that would catch a fault
never ran. Silently calling that "good" would turn "we did not look"
into "nothing is wrong" — the one lie this module exists to avoid
telling. So a clean verdict is only ever "good" when nothing fired *and*
every measurement family that activity depends on actually ran this
time; otherwise it is "unmeasured", with a plain-English sentence naming
what was skipped, so the reader knows to re-run a full check rather than
pack their bags on the strength of a quick one.

A fired rule always outranks "unmeasured", deliberately: a connection
that N1 says has no network at all is down whether or not the deeper
probes got a chance to run. Absence of evidence only earns "unmeasured"
when there is also no evidence of a fault.
"""

from __future__ import annotations

import os
import sys

try:
    from rules_catalog import RULES
except ImportError:
    # Direct execution, or an import context where this file's own
    # directory (where rules_catalog.py lives beside it) isn't already on
    # sys.path — add it once and retry, rather than require every caller
    # to know this module has a sibling.
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from rules_catalog import RULES

# Display order, and also the order of concern: a reader scanning top to
# bottom meets the activity that breaks first for a traveler (a call)
# before the one that tolerates the most (browsing).
ACTIVITY_ORDER: tuple[str, ...] = ("calls", "streaming", "gaming", "vpn", "browsing")

LABELS: dict[str, str] = {
    "calls": "Video & voice calls",
    "streaming": "Streaming",
    "gaming": "Gaming",
    "vpn": "VPN & remote access",
    "browsing": "Ordinary browsing",
}

# The measurement families each activity needs to have been probed
# before a "nothing fired" result is honestly reportable as "good"
# rather than "we didn't check". Not every rule that can affect an
# activity is represented here — a rule that fires always speaks for
# itself, regardless of what ran — this table only governs the fallback
# when nothing did.
#
# calls / gaming: both are latency-sensitive in real time, so both rest
# on the bufferbloat and packet-loss probes — the checks that catch a
# router or ISP that goes sluggish or lossy under load, which is exactly
# what wrecks a call or a match while a bare ping still looks fine.
#
# streaming: throughput-bound rather than latency-bound — a player
# buffers ahead, so the number that actually predicts whether it holds
# is the speed test.
#
# vpn: the two failure modes that are otherwise invisible. A path-MTU
# black hole (M1) hangs a tunnel silently with no other symptom, and the
# path checks are what would have caught a double-NAT or a proxy sitting
# in the way of it — the kind of fault a clean ping and a clean speed
# test both miss entirely.
#
# browsing: nothing extra. An ordinary page load survives the load and
# loss levels that make a call stutter, so browsing is judged "good"
# whenever no rule fired for it at all, measured or not — and any
# fault severe enough to break browsing outright (no network, DNS down,
# the internet unreachable) fires a rule regardless of which optional
# probes ran.
DEPENDS_ON: dict[str, tuple[str, ...]] = {
    "calls": ("bufferbloat", "loss"),
    "streaming": ("speed",),
    "gaming": ("bufferbloat", "loss"),
    "vpn": ("mtu", "path"),
    "browsing": (),
}

# Prose names for the measurement families in DEPENDS_ON, for the
# "didn't run" sentence. Qualitative on purpose, matching
# rules_catalog.py's own rule: no dBm, no ms, no percent — this names
# what was skipped, not how far past a threshold anything landed.
FAMILY_LABELS: dict[str, str] = {
    "bufferbloat": "latency under load",
    "loss": "the packet-loss probe",
    "speed": "the speed test",
    "mtu": "the packet-size (MTU) probe",
    "path": "the path checks",
}

# Worst-last, so "the worst level seen" is a table lookup (max() by table
# position) rather than a comparison of numbers. "good" only ever comes
# from finding nothing, never from ranking against something.
_LEVEL_ORDER: tuple[str, ...] = ("good", "degraded", "broken")

# rule id -> its impacts map, built once at import time so project() does
# a dict lookup per fired id rather than a linear scan of RULES per call.
# Rules with no "impacts" key (most info-severity rules, VPN-1, TCP-1,
# ICMP-1, and the like) land here with an empty map, which is
# indistinguishable from "fired but touches none of these five
# activities" — exactly what they mean.
_IMPACTS_BY_RULE: dict[str, dict[str, str]] = {
    rule["id"]: rule.get("impacts", {}) for rule in RULES
}


def _worst(levels) -> str:
    """The most severe of an iterable of impact levels, ranked by table
    position in _LEVEL_ORDER — never by comparing numbers. Empty input is
    "good": the absence of any impact is what "good" means.
    """
    return max(levels, key=_LEVEL_ORDER.index, default="good")


def _english_list(items) -> str:
    """"a" / "a and b" / "a, b and c" — a plain-language list, built
    without ever comparing a length against a literal (see the module
    docstring on why this file avoids that shape entirely).
    """
    items = list(items)
    if not items:
        return ""
    head, *rest = items
    if not rest:
        return head
    *middle, last = rest
    return ", ".join([head, *middle]) + f" and {last}"


def project(fired, measured):
    """Turn fired rule IDs and probed measurement families into five
    per-activity verdicts.

    `fired` — an iterable of rule IDs the engine already decided should
    fire this run (`lib/diagnosis.sh` or `lib/monitor.sh`'s output — this
    function does not care which). IDs this catalog doesn't recognise are
    ignored rather than raising: a consumer holding a rule from a newer
    netdiag should lose that one row's nuance, not the whole report.

    `measured` — a set of measurement-family names (see DEPENDS_ON /
    FAMILY_LABELS) naming what this run actually probed, used only to
    decide whether a clean "nothing fired" result is honestly "good" or
    should be reported as "unmeasured" instead.

    Returns a list of dicts, one per activity in ACTIVITY_ORDER, each
    with keys: activity, label, verdict ("good" / "degraded" / "broken" /
    "unmeasured"), because (the fired rule IDs responsible, [] unless
    verdict is "degraded" or "broken"), and unmeasured_reason (a sentence
    naming what wasn't run, or None for every other verdict).
    """
    fired_ids = list(fired)
    measured_set = set(measured)

    results = []
    for activity in ACTIVITY_ORDER:
        hits = []  # (rule_id, level) pairs actually touching this activity
        for rule_id in fired_ids:
            impacts = _IMPACTS_BY_RULE.get(rule_id)
            if not impacts:
                continue
            level = impacts.get(activity)
            if level is None:
                continue
            hits.append((rule_id, level))

        if hits:
            verdict = _worst(level for _, level in hits)
            because = [rule_id for rule_id, _ in hits]
            unmeasured_reason = None
        else:
            because = []
            missing = [fam for fam in DEPENDS_ON[activity] if fam not in measured_set]
            if missing:
                verdict = "unmeasured"
                missing_prose = _english_list(FAMILY_LABELS[fam] for fam in missing)
                unmeasured_reason = f"This check didn't run {missing_prose}."
            else:
                verdict = "good"
                unmeasured_reason = None

        results.append({
            "activity": activity,
            "label": LABELS[activity],
            "verdict": verdict,
            "because": because,
            "unmeasured_reason": unmeasured_reason,
        })

    return results
