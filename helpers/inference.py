#!/usr/bin/env python3
"""Per-monitor-sample presentation judgements: suitability, hops, headline.

This is the layer between `lib/monitor.sh`'s verdicts (rule IDs judged
against lib/thresholds.sh) and everything a *program* reading
`netdiag --monitor` wants to render: which everyday activities the rules
name, which hop of the route carries the fault, and what the status hero
should say. The GUI used to compute all three itself from its own private
cutoffs — calls broken at a file-only 8% loss, a hop warning the CLI's own
rules had declined to make, a green pill over a red headline. CLAUDE.md's
rule — "the GUI holds no diagnostic logic" — was written on paper and
violated in Swift.

The design follows helpers/suitability.py exactly, and reuses it:

  * Verdicts come from rules. `suitability.py`'s `project()` maps fired
    rule IDs onto per-activity levels through the catalog's `impacts`
    tables. Nothing here re-derives a verdict from a number: the levels
    are the rules', already decided against lib/thresholds.sh by
    `_mon_rules`. Only the dependency table differs — the monitor never
    runs the bufferbloat, speed or MTU probes DEPENDS_ON expects, so its
    "did we measure it?" question uses the families the sample itself
    carries: the two ping legs, DNS, TCP and the web canary.
  * Metric lines carry figures, never judgements. "3% loss · 9 ms jitter"
    is a rendering of the numbers the sample already holds. The invariant
    the plan states and the tests check: an activity's label must never
    contradict its own metric line — an unmeasured verdict renders no
    metric, and every good/degraded/broken verdict renders one.
  * Every cutoff this file compares against arrives by environment
    variable, exported by lib/monitor.sh from lib/thresholds.sh (see
    REQUIRED_THRESHOLDS). A missing variable is a refusal, not a default
    — the same discipline helpers/history.py applies to THRESH_COMPARE_*,
    for the same reason: a stale default still renders a plausible
    verdict, which is the worst way for a threshold to drift.

`hops` exists for the same reason: the route card's mac/router/internet
state used to be Swift's own heuristic over raw figures. It is now one
judgement, computed here where the thresholds are, and rendered verbatim.
"""

from __future__ import annotations

import os
import sys

try:
    from rules_catalog import RULES
    from suitability import ACTIVITY_ORDER, IMPACTS_BY_RULE, _english_list, _worst
except ImportError:
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    try:
        from rules_catalog import RULES
        from suitability import ACTIVITY_ORDER, IMPACTS_BY_RULE, _english_list, _worst
    except Exception:
        # A broken catalog sibling must not kill the stream: build()
        # will refuse loudly for whatever calls it directly, and
        # monitor_sample.py's guard degrades to no blocks.
        RULES = None
        ACTIVITY_ORDER = None
        IMPACTS_BY_RULE = None
        _english_list = None
        _worst = None

# ── Environment thresholds ────────────────────────────────────────────────
# Names match lib/thresholds.sh verbatim. lib/monitor.sh sources that file
# and exports exactly these when it calls helpers/monitor_sample.py, which
# imports this module.

REQUIRED_THRESHOLDS: tuple[str, ...] = (
    "LOSS_WARN_PCT",
    "LOSS_CRIT_PCT",
    "THRESH_GW_LOSS_CRIT_PCT",
    "THRESH_LATENCY_JITTER_WARN_MS",
    "THRESH_INTERNET_LATENCY_WARN_MS",
    "THRESH_INTERNET_LATENCY_CRIT_MS",
    "THRESH_DNS_LATENCY_WARN_MS",
    "THRESH_GW_RTT_WARN_MS",
    "THRESH_WIFI_RSSI_EXCELLENT_DBM",
    "THRESH_WIFI_RSSI_G1_DBM",
    "THRESH_WIFI_RSSI_WEAK_DBM",
)


def _fail(message: str):
    print(f"inference.py: {message}", file=sys.stderr)
    print("inference.py: thresholds come from lib/thresholds.sh via the "
          "environment; export them (see REQUIRED_THRESHOLDS in "
          "helpers/inference.py) or skip these blocks.",
          file=sys.stderr)
    sys.exit(3)


def _threshold(name: str) -> float:
    v = os.environ.get(name)
    if not v:
        _fail(f"required threshold {name} is not set")
    try:
        return float(v)
    except ValueError:
        _fail(f"threshold {name} is not a number: {v!r}")


# The threshold set for one invocation, resolved lazily (in build(), not
# at import time) — deliberately one object rather than bare names so the
# file's entire dependency on the environment is visible in one place.
_T = None


def _resolve_thresholds():
    global _T
    class _T: pass
    _T_new = _T()
    _T_new.loss_warn = _threshold("LOSS_WARN_PCT")
    _T_new.loss_crit = _threshold("LOSS_CRIT_PCT")
    _T_new.gw_loss_crit = _threshold("THRESH_GW_LOSS_CRIT_PCT")
    _T_new.jitter_warn = _threshold("THRESH_LATENCY_JITTER_WARN_MS")
    _T_new.latency_warn = _threshold("THRESH_INTERNET_LATENCY_WARN_MS")
    _T_new.latency_crit = _threshold("THRESH_INTERNET_LATENCY_CRIT_MS")
    _T_new.dns_warn = _threshold("THRESH_DNS_LATENCY_WARN_MS")
    _T_new.gw_rtt_warn = _threshold("THRESH_GW_RTT_WARN_MS")
    _T_new.rssi_excellent = _threshold("THRESH_WIFI_RSSI_EXCELLENT_DBM")
    _T_new.rssi_good = _threshold("THRESH_WIFI_RSSI_G1_DBM")
    _T_new.rssi_weak = _threshold("THRESH_WIFI_RSSI_WEAK_DBM")
    _T = _T_new


_RULES_BY_ID = {r["id"]: r for r in RULES}


def _rule_category(rule_id: str) -> str:
    return (_RULES_BY_ID.get(rule_id) or {}).get("category", "")


def _rule_title(rule_id: str) -> str:
    return (_RULES_BY_ID.get(rule_id) or {}).get("title", rule_id)


def _num(v):
    """A float, or None — where None means "not measured", never zero."""
    if v is None:
        return None
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


# ── Figure formatting ─────────────────────────────────────────────────────
# Renderers of numbers the sample already carries. No cutoff logic here:
# their only comparison is against zero, and their purpose is to make sure
# a metric line holds what the sample knows rather than dropping it.

def _fmt_pct(x) -> str:
    return f"{x:g}%"


def _fmt_ms(x) -> str:
    return f"{x:.0f} ms"


def _join(*parts) -> str:
    return " · ".join(p for p in parts if p)


# ── Suitability labels ────────────────────────────────────────────────────
# ONE label per (activity, level). A label chosen per trigger-rule is a
# verdict phrase re-derived per branch — the shape the CLI-only policy
# forbids. The set is fixed here so the invariant test can check every
# row's label against this very table.

ACTIVITY_SHORT: dict[str, str] = {
    "calls": "Calls",
    "streaming": "Streaming",
    "gaming": "Gaming",
    "vpn": "VPN",
    "browsing": "Browsing",
}

LABELS_BY_LEVEL: dict[tuple[str, str], str] = {
    ("calls", "good"): "Clear audio",
    ("calls", "degraded"): "May cut out",
    ("calls", "broken"): "Breaking up",
    ("streaming", "good"): "HD ready",
    ("streaming", "degraded"): "SD quality",
    ("streaming", "broken"): "Buffering",
    ("gaming", "good"): "Responsive",
    ("gaming", "degraded"): "Lag likely",
    ("gaming", "broken"): "Unplayable",
    ("vpn", "good"): "Connected",
    ("vpn", "degraded"): "At risk",
    ("vpn", "broken"): "Blocked",
    ("browsing", "good"): "Fast",
    ("browsing", "degraded"): "Slow",
    ("browsing", "broken"): "Pages fail",
}

# The one sentence behind each level — the row's detail text.
DETAILS_BY_LEVEL: dict[tuple[str, str], str] = {
    ("calls", "good"): "Low loss and low jitter for clear voice and video.",
    ("calls", "degraded"): "Conditions may cause words to drop or video to stutter.",
    ("calls", "broken"): "Call audio is failing and video is unusable.",
    ("streaming", "good"): "No loss reading; the speed test did not run live.",
    ("streaming", "degraded"): "Video may downgrade or buffer.",
    ("streaming", "broken"): "Playback stalls and buffers rather than playing.",
    ("gaming", "good"): "Latency and stability are comfortable for fast games.",
    ("gaming", "degraded"): "Lag or desync may affect fast multiplayer games.",
    ("gaming", "broken"): "Multiplayer games disconnect or rubberband constantly.",
    ("vpn", "good"): "An active tunnel is connected and routing.",
    ("vpn", "degraded"): "Topology or packet handling may disturb tunnels.",
    ("vpn", "broken"): "Tunnels cannot form or fail mid-session.",
    ("browsing", "good"): "DNS answers quickly and pages load fast.",
    ("browsing", "degraded"): "Pages load slower than usual.",
    ("browsing", "broken"): "Websites cannot load.",
}

UNMEASURED_LABELS: dict[str, str] = {
    "calls": "Not measured",
    "streaming": "Speed unknown",
    "gaming": "Not measured",
    "vpn": "Needs a full check",
    "browsing": "Not measured",
}

# The monitor's own dependency table. The monitor never runs the
# bufferbloat/MTU/speed probes a scan runs, so its honest "did we look?"
# families are the ones the sample carries: the two ping legs (loss and
# latency), TCP for browsing, the speed test the monitor does not run.
MONITOR_DEPENDS_ON: dict[str, tuple[str, ...]] = {
    "calls": ("loss", "latency"),
    "streaming": ("speed",),
    "gaming": ("loss", "latency"),
    "vpn": ("mtu",),
    "browsing": ("tcp",),
}

MONITOR_FAMILY_LABELS: dict[str, str] = {
    "loss": "the packet-loss probe",
    "latency": "the latency probe",
    "speed": "the speed test",
    "mtu": "the packet-size (MTU) probe",
    "path": "the path checks",
    "tcp": "the TCP probe",
}


def _measured_families(m) -> set:
    """Which families this sample actually produced readings for.

    Presence of a figure is measurement; None never is — including the
    tri-state probes: dns_ok/tcp_ok None is absence, not failure, and
    absence must not license a "good".
    """
    fams = set()
    if _num(m.get("gw_loss")) is not None or _num(m.get("inet_loss")) is not None:
        fams.add("loss")
    if _num(m.get("inet_rtt")) is not None:
        fams.add("latency")
    if m.get("dns_ok") is not None:
        fams.add("dns")
    if m.get("tcp_ok") is not None:
        fams.add("tcp")
    if m.get("web_ok") is not None:
        fams.add("web")
    return fams


def _metric_line(activity: str, m) -> str:
    """The figure line backing this activity's label, or "" when the
    sample carries nothing to show.

    Renders what is known, never a word a verdict could contradict. A
    rule-caused verdict with no usable figure falls back to the fired
    rules' catalog titles — authored CLI-side, rendered verbatim.
    """
    link_up = m.get("link_up", True)
    loss = _num(m.get("inet_loss"))
    rtt = _num(m.get("inet_rtt"))
    gw_rtt = _num(m.get("gw_rtt"))
    gw_jit = _num(m.get("gw_jitter"))
    dns_ok = m.get("dns_ok")
    dns_ms = _num(m.get("dns_ms"))
    tcp_ok = m.get("tcp_ok")
    web_fail = m.get("web_fail_kind")

    if not link_up:
        return "No link"

    if activity == "calls":
        loss_part = None
        if loss is not None:
            loss_part = _fmt_pct(loss) + " loss"
        jit = _num(m.get("inet_jitter"))
        jit_part = f"{jit:.0f} ms jitter" if jit is not None else None
        return _join(loss_part, jit_part)

    if activity == "gaming":
        if m.get("icmp_filtered"):
            return "Ping blocked · TCP ok"
        rtt_part = _fmt_ms(rtt) if rtt is not None else None
        loss_part = (_fmt_pct(loss) + " loss") if loss not in (None, 0) else None
        return _join(rtt_part, loss_part)

    if activity == "streaming":
        # No speed test travels with a monitor sample; loss is what the
        # stream can honestly say about video right now.
        if loss is not None and loss != 0:
            return _fmt_pct(loss) + " loss"
        return "Clean link" if loss is not None else ""

    if activity == "vpn":
        if m.get("vpn_active"):
            name = m.get("vpn_name") or "tunnel"
            return f"Tunnel active ({name})"
        return ""

    if activity == "browsing":
        parts = []
        if dns_ms is not None:
            parts.append(f"{dns_ms:.0f} ms DNS")
        if dns_ok is False:
            parts.append("lookup failing")
        if tcp_ok is False:
            parts.append("TCP refusing")
        elif tcp_ok:
            parts.append("TCP 443 ok")
        return _join(*parts) or ("" if web_fail is None else f"Requests {web_fail}")
    return ""


def _rules_touching(activity: str, fired) -> list:
    hits = []
    for rid in fired:
        impacts = IMPACTS_BY_RULE.get(rid)
        if isinstance(impacts, dict) and activity in impacts:
            hits.append((rid, impacts[activity]))
    return hits


def _suitability(fired, m) -> list:
    """Per-activity verdict, label, metric and because-block: the same
    projection suitability.project() makes, over the monitor's families."""
    measured = _measured_families(m)
    rows = []
    for activity in ACTIVITY_ORDER:
        hits = _rules_touching(activity, fired)
        # Special case, stated rather than hidden: an active tunnel IS an
        # answer to "will a VPN work here" — the user is on one. Interior
        # topology quality is what the full check's path/MTU probes test
        # (its unmeasured stance otherwise), and that stays unmeasured.
        if not hits and activity == "vpn" and m.get("vpn_active"):
            verdict, because, reason = "good", [], None
        elif hits:
            verdict = _worst(level for _, level in hits)
            because = [rid for rid, _ in hits]
            reason = None
        else:
            because = []
            missing = [f for f in MONITOR_DEPENDS_ON[activity] if f not in measured]
            if missing:
                verdict = "unmeasured"
                missing_prose = _english_list(MONITOR_FAMILY_LABELS[f] for f in missing)
                reason = f"The live monitor doesn't run {missing_prose}."
            else:
                verdict = "good"
                reason = None

        if verdict == "unmeasured":
            label = UNMEASURED_LABELS.get(activity, "Not measured")
            metric = ""
        else:
            label = LABELS_BY_LEVEL[(activity, verdict)]
            metric = _metric_line(activity, m) if verdict != "unmeasured" else ""
            if not metric and because:
                metric = ", ".join(_rule_title(rid) for rid in because)
        rows.append({
            "activity": activity,
            "label": label,
            "verdict": verdict,
            "metric": metric,
            "because": because,
            "unmeasured_reason": reason,
        })
    return rows


# ── Hops ──────────────────────────────────────────────────────────────────
# Three hops, each a state and a one-sentence reason. The cross-checks are
# the pair RouteWarningResolver.swift used to carry as inline literals; the
# numbers they ride on are now THRESH_GW_RTT_WARN_MS and
# THRESH_LATENCY_JITTER_WARN_MS from the environment.

def _router_hop(m) -> dict:
    fired = m.get("rules") or []
    rule_warns = [rid for rid in fired
                  if _rule_category(rid) == "router" and rid != "TCP-1"]
    gw_rtt = _num(m.get("gw_rtt"))
    gw_jit = _num(m.get("gw_jitter"))
    inet_rtt = _num(m.get("inet_rtt"))
    inet_jit = _num(m.get("inet_jitter"))

    if rule_warns:
        return {"warn": True,
                "detail": ", ".join(_rule_title(r) for r in rule_warns)}

    # A router that answers slower than the whole round trip to the
    # internet is CPU reply delay, not link latency — so the claim needs
    # the internet leg not to contradict it (unmeasured doesn't).
    if gw_rtt is not None and gw_rtt >= _T.gw_rtt_warn \
       and (inet_rtt is None or inet_rtt >= _T.gw_rtt_warn):
        return {"warn": True, "detail": f"{gw_rtt:.0f} ms latency to router"}

    if gw_jit is not None and gw_jit >= _T.jitter_warn \
       and (inet_jit is None or inet_jit >= _T.jitter_warn):
        return {"warn": True, "detail": f"±{gw_jit:.0f} ms jitter"}

    return {"warn": False, "detail": ""}


def _internet_hop(m) -> dict:
    fired = m.get("rules") or []
    rule_warns = [rid for rid in fired
                  if _rule_category(rid) in ("internet", "dns")
                  and rid != "ICMP-1"]
    link_up = m.get("link_up", True)
    measured = _measured_families(m)
    loss = _num(m.get("inet_loss"))
    rtt = _num(m.get("inet_rtt"))
    jit = _num(m.get("inet_jitter"))

    if not link_up:
        return {"warn": True, "detail": "No internet"}

    if not rule_warns and m.get("icmp_filtered"):
        # TCP-1 holds: pings are being filtered, connections are fine.
        return {"warn": False, "detail": "Ping blocked · TCP ok"}

    if rule_warns:
        # One figure-phrase per rule where a rule maps one-to-one onto a
        # figure; the catalog title otherwise.
        phrases = []
        for rid in rule_warns:
            if rid in ("P1", "P2", "N1b"):
                phrases.append("Unreachable")
            elif rid in ("L1", "L2") and loss is not None:
                phrases.append(_fmt_pct(loss) + " loss")
            elif rid == "LA-1" and rtt is not None:
                phrases.append(f"{rtt:.0f} ms latency")
            elif rid == "LA-2" and jit is not None:
                phrases.append(f"±{jit:.0f} ms jitter")
            elif rid.startswith("TCP-2"):
                succ = _num(m.get("web_succ_pct"))
                phrases.append(f"{succ:.0f}% connect success"
                               if succ is not None else _rule_title(rid))
            elif rid == "D1":
                phrases.append("DNS failing")
            elif rid == "BR-1":
                phrases.append("Browser desync")
            elif rid == "CP-1":
                phrases.append("Sign-in page")
            else:
                phrases.append(_rule_title(rid))
        return {"warn": True, "detail": " · ".join(phrases)}

    if "loss" not in measured and "web" not in measured:
        return {"warn": False, "detail": "Not measured yet"}

    detail = []
    if loss is not None:
        detail.append("0% packet loss" if loss == 0 else _fmt_pct(loss) + " loss")
    elif rtt is not None:
        detail.append(_fmt_ms(rtt))
    return {"warn": False, "detail": _join(*detail)}


def _roamed(m) -> bool:
    """The Mac roamed access points this same cycle: the BSSID swapped
    under one unchanged SSID. This is the same-cycle shape of the GUI's
    hasRecentRoam; longer grace windows wait for the staleness phase of
    the plan."""
    ssid = m.get("ssid")
    prev_ssid = m.get("prev_ssid")
    bssid = m.get("bssid")
    prev_bssid = m.get("prev_bssid")
    if not ssid or not bssid or not prev_bssid:
        return False
    if prev_ssid is not None and ssid != prev_ssid:
        return False
    return bssid != prev_bssid


def _mac_hop(m) -> dict:
    link_up = m.get("link_up", True)
    if not link_up:
        return {"laggy": False, "detail": "No link", "good": False}
    if not m.get("is_wifi", False):
        return {"laggy": False, "detail": "Wired", "good": True}

    rssi = m.get("rssi")
    if rssi is None:
        word = "No signal reading"
    elif rssi >= _T.rssi_excellent:
        word = "Excellent"
    elif rssi >= _T.rssi_good:
        word = "Good"
    elif rssi >= _T.rssi_weak:
        word = "Fair"
    else:
        word = "Weak"

    fired = m.get("rules") or []
    gw_rule_fired = any(_rule_category(rid) in ("router", "wifi") for rid in fired)
    router = _router_hop(m)
    laggy = bool(gw_rule_fired or router.get("warn"))
    detail = f"{word} (laggy)" if laggy else word
    if _roamed(m):
        detail += " · roamed"
    return {"laggy": laggy, "detail": detail, "good": not laggy}


# ── Headline ──────────────────────────────────────────────────────────────
# The status hero's degraded voice. `None` when every grid activity is
# good — the healthy card's copy stays presentation, and stays the GUI's.

GRID_ACTIVITIES: tuple[str, ...] = ("calls", "gaming", "streaming", "browsing")


def _headline(rows) -> dict | None:
    by_activity = {r["activity"]: r for r in rows}
    broken = [a for a in GRID_ACTIVITIES
              if by_activity.get(a, {}).get("verdict") == "broken"]
    degraded = [a for a in GRID_ACTIVITIES
                if by_activity.get(a, {}).get("verdict") == "degraded"]
    if not broken and not degraded:
        return None

    affected = broken or degraded
    names = _english_list(ACTIVITY_SHORT[a] for a in affected)
    text = f"Unusable for {names}" if broken else f"Limited for {names}"

    parts = []
    for a in affected:
        row = by_activity[a]
        metric = (row.get("metric") or "").replace(" · ", ", ")
        parts.append(f"{ACTIVITY_SHORT[a]}: {metric or row['label']}")
    return {
        "text": text,
        "subtitle": " · ".join(parts),
        "critical": bool(broken),
    }


# ── Entry point ───────────────────────────────────────────────────────────

def build(state: dict) -> dict:
    """The three blocks for one monitor sample, in sample-ready shape.

    `state` is the sample's own figures and flags, already decoded by
    helpers/monitor_sample.py out of the NETDIAG_MON_* environment:
    rules, per-leg loss/rtt/jitter figures or None, rssi, dns/tcp/web
    tri-states, vpn name and flag, link_up/is_wifi, and the previous
    sample's BSSID for the roam note.
    """
    global _T
    if ACTIVITY_ORDER is None:
        raise RuntimeError("the rules catalog is unavailable")
    if _T is None:
        _resolve_thresholds()
    rows = _suitability(state.get("rules") or [], state)
    return {
        "suitability": rows,
        "hops": {
            "mac": _mac_hop(state),
            "router": _router_hop(state),
            "internet": _internet_hop(state),
        },
        "headline": _headline(rows),
    }
