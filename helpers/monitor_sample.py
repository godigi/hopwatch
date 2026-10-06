#!/usr/bin/env python3
"""Emit one `netdiag --monitor` sample as a single compact JSON line.

Called once per cycle from lib/monitor.sh with the sample's state exported
as NETDIAG_MON_* environment variables — the same pattern as
helpers/emit_json.py, and for the same reason: bash cannot escape a string
into JSON safely. An SSID may legally contain a quote, a backslash or a
newline, and a printf-built stream that the GUI parses forever would
eventually meet one. Interpreter startup costs ~50 ms once per cadence;
a malformed line costs the whole session.

The shape is deliberately *smaller* than a full `--json` run and is
documented separately in docs/JSON-SCHEMA.md. It is not a subset by
accident — a monitor sample answers "what is true right now", a run
answers "what is wrong and why".

Conventions match the full schema:
  * null means the probe did not run this cycle (its tier wasn't due, or
    there is no link). It never means "ran and measured zero".
  * `status.rules` are IDs from docs/DIAGNOSIS-RULES.md, evaluated in
    lib/monitor.sh against lib/thresholds.sh. Consumers render them; they
    do not re-derive them.
"""

from __future__ import annotations

import json
import os
import sys
import time
from datetime import datetime, timezone

# The block that turns rules and figures into per-activity, per-hop and
# headline judgements. Loaded lazily inside main(): the module resolves
# its thresholds from the environment at import time, and a caller that
# intentionally runs without them should still get a sample. Any
# exception here (a broken rules_catalog sibling among them) degrades to
# no blocks rather than a dead stream — the same contract the journal
# appends fail-open under.
try:
    import inference
except ImportError:
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    try:
        import inference
    except Exception:
        inference = None
except Exception:
    inference = None

# Lazily resolved rule ID -> catalog title ("G2" -> "Router dropping packets"),
# so a rule-fired/rule-cleared summary speaks the same plain-English name the
# GUI's report card and `--rules-catalog` already use, rather than the bare
# rule ID a user has never seen. Resolved lazily only when a rule transition
# actually occurs, avoiding the ~35 ms overhead of compiling rules_catalog.py
# (under PYTHONDONTWRITEBYTECODE=1) on the 99.9% of cycles where no rule changed.
_RULE_TITLES: dict[str, str] | None = None


def _get_rule_title(rid: str) -> str | None:
    global _RULE_TITLES
    if _RULE_TITLES is None:
        try:
            from rules_catalog import RULES
            _RULE_TITLES = {r["id"]: r["title"] for r in RULES}
        except Exception:
            _RULE_TITLES = {}
    return _RULE_TITLES.get(rid)


def _env(name: str) -> str | None:
    v = os.environ.get(f"NETDIAG_MON_{name}")
    if not v:
        return None
    # Foundation's JSONDecoder drops the whole line on a surrogate escape
    # (e.g. from a non-UTF-8 SSID) — a mojibake character beats a dropped
    # sample.
    return v.encode("utf-8", "replace").decode("utf-8")


def _f(name: str) -> float | None:
    v = _env(name)
    if v is None:
        return None
    try:
        return float(v)
    except ValueError:
        return None


def _i(name: str) -> int | None:
    v = _env(name)
    if v is None:
        return None
    try:
        return int(v)
    except ValueError:
        return None


def _tri(name: str) -> bool | None:
    """Three-valued: "1" true, "0" false, unset/empty None.

    _bool() would be wrong for every probe that can be skipped. Collapsing
    "not measured" to false is what turns a tier that hasn't run yet into
    "the internet is down" — the exact false-critical shape the packet-loss
    predicates in lib/common.sh exist to prevent.
    """
    v = os.environ.get(f"NETDIAG_MON_{name}", "")
    if v == "1":
        return True
    if v == "0":
        return False
    return None


# Shares a person says aloud. The nearest one to the measured ratio is the
# phrase — "most", never "66.7% blocked". Three steps only, deliberately:
# with nine ("about 2 in 3", "about 4 in 5", ...) the sentence changed on
# almost every cycle as the rolling ratio moved, and a headline that
# rewrites itself every two seconds reads as noise; the exact figure is
# in `pct` for anyone who wants it. This is wording for a measurement,
# not a cutoff: whether the ratio matters is decided upstream (TCP-2 in
# lib/monitor.sh, against lib/thresholds.sh) and arrives here as the
# confirmed `state`.
_SPOKEN_SHARES = ((1 / 4, "Some"), (1 / 2, "About half of"), (3 / 4, "Most"))


def build_refused() -> dict:
    """The refused-connect instrument behind TCP-2, with its sentence.

    `state` is the monitor's confirmed TCP-2 verdict ("warn"/"critical",
    else null) and `summary` is written here, in the CLI, only when a
    verdict stands — so a consumer renders `summary` verbatim and never
    composes "blocked" out of one sample's tcp.any_ok. The sentence states
    the measurement; it deliberately names no culprit (the catalog's TCP-2
    entry carries the blame, and it is hedged).
    """
    pct = _f("TCP2_PCT")
    attempts = _i("TCP2_ATTEMPTS")
    state = _env("TCP2_STATE")
    if state not in ("warn", "critical"):
        state = None
    summary = None
    if state == "critical":
        summary = (f"Every one of the last {attempts} test connections was refused"
                   if attempts else "Every new connection is being refused")
    elif state == "warn" and pct is not None:
        _, share = min(_SPOKEN_SHARES, key=lambda s: abs(s[0] - pct / 100.0))
        summary = f"{share} new connections are being refused"
    return {"pct": pct, "attempts": attempts, "state": state, "summary": summary}


def build_tcp() -> list[dict]:
    """NETDIAG_MON_TCP_LINES is one 'host|port|ok|elapsed_ms' per line."""
    raw = _env("TCP_LINES") or ""
    out: list[dict] = []
    for line in raw.splitlines():
        if not line.strip():
            continue
        parts = line.split("|")
        if len(parts) < 3:
            continue
        host, port, ok = parts[0], parts[1], parts[2]
        entry: dict = {
            "host": host,
            "port": int(port) if port.isdigit() else port,
            "ok": ok == "1",
            "elapsed_ms": None,
        }
        if len(parts) > 3 and parts[3]:
            try:
                entry["elapsed_ms"] = float(parts[3])
            except ValueError:
                pass
        out.append(entry)
    return out


def _stability_state() -> dict:
    """lib/stability.sh's stage bookkeeping, decoded from the environment:
    {"state": stable|unstable|recovering, "rules": [{rule, severity,
    active, last_ago_s, spikes}]}. Sentences are inference.py's job."""
    rules = []
    for token in (_env("STABILITY_RULES") or "").split():
        parts = token.split(":")
        if len(parts) != 5:
            continue
        try:
            rules.append({"rule": parts[0], "severity": parts[1],
                          "active": parts[2] == "1",
                          "last_ago_s": int(parts[3]),
                          "spikes": int(parts[4])})
        except ValueError:
            continue
    return {"state": _env("STABILITY_STATE") or "stable", "rules": rules}


def _burst_block() -> dict | None:
    """status.burst — the investigation/latency-test burst the monitor is
    running inside this process, or null. The consumer renders "testing
    latency, 2 s until …" from this and owns no timer of its own."""
    until = _i("BURST_UNTIL")
    if not until:
        return None
    return {
        "active": True,
        "kind": _env("BURST_KIND") or "investigation",
        "interval_s": _i("BURST_INTERVAL_S"),
        "until": datetime.fromtimestamp(until, timezone.utc)
                         .strftime("%Y-%m-%dT%H:%M:%SZ"),
        "remaining_s": max(0, until - int(time.time())),
    }


def _changes() -> list[dict]:
    """Field-level diff against the previous sample (NETDIAG_MON_PREV_*).

    None on either side means "not measured" on that side, and an
    unmeasured→measured transition is not a change — same convention as
    the rest of the stream, where null is absence of measurement.
    Rules are the exception: they are always evaluated, so set
    difference is safe. Summaries are user-facing prose; the GUI
    renders them verbatim (CLAUDE.md: no verdict strings in Swift).

    Invariant this relies on: a field whose null suppresses the diff
    must keep its last known value in the previous-sample snapshot
    (bash side) — otherwise a single link-down sample with empty
    values erases the comparison baseline and interface/SSID changes
    are never reported.
    """
    if _env("HAVE_PREV") != "1":
        return []
    out: list[dict] = []

    def diff(now_key, prev_key, cid, field, phrase):
        now, prev = _env(now_key), _env(prev_key)
        if now is None or prev is None or now == prev:
            return
        out.append({"id": cid, "field": field, "from": prev, "to": now,
                    "summary": phrase(prev, now)})

    vpn_now = _env("VPN_ACTIVE") == "1"
    vpn_prev_raw = _env("PREV_VPN_ACTIVE")
    vpn_prev = vpn_prev_raw == "1"
    if vpn_prev_raw is not None and vpn_now != vpn_prev:
        name = _env("VPN_NAME") or _env("PREV_VPN_NAME")
        suffix = f" ({name})" if name else ""
        out.append({
            "id": "vpn-connected" if vpn_now else "vpn-disconnected",
            "field": "vpn.active",
            "from": "1" if vpn_prev else "0",
            "to": "1" if vpn_now else "0",
            "summary": (f"VPN connected{suffix}" if vpn_now
                        else f"VPN disconnected{suffix}"),
        })
    elif vpn_now and _env("VPN_TYPE") != "utun-route":
        # lib/monitor.sh sets MON_VPN_NAME to the tunnel interface
        # (utun4, utun6, ...) for utun-route VPNs — that's not a name,
        # and it duplicates interface-changed below.
        diff("VPN_NAME", "PREV_VPN_NAME", "vpn-name-changed", "vpn.name",
             lambda a, b: f"VPN changed: {a} → {b}")

    def exit_phrase(a, b):
        if vpn_now and vpn_prev:
            return f"VPN exit moved: {a} → {b}"
        if vpn_now and not vpn_prev:
            # Just connected: "a" was the user's real location, not a
            # prior VPN exit, so don't imply the exit itself moved.
            return f"VPN exit is in {b}"
        return f"Location changed: {a} → {b}"

    diff("PUB_CC", "PREV_PUB_CC", "country-changed", "public.country",
         exit_phrase)
    diff("PUB_IP", "PREV_PUB_IP", "public-ip-changed", "public.ip",
         lambda a, b: "Public IP changed")
    diff("PUB_ISP", "PREV_PUB_ISP", "isp-changed", "public.isp",
         lambda a, b: f"Internet provider changed: {a} → {b}")
    diff("SSID", "PREV_SSID", "wifi-network-changed", "link.ssid",
         lambda a, b: f"Wi-Fi network changed: {a} → {b}")
    if _env("SSID") is not None and _env("SSID") == _env("PREV_SSID"):
        diff("BSSID", "PREV_BSSID", "wifi-roamed", "link.bssid",
             lambda a, b: "Roamed to a different Wi-Fi access point")
    diff("INTERFACE", "PREV_INTERFACE", "interface-changed",
         "link.interface",
         lambda a, b: f"Network interface changed: {a} → {b}")

    rules_now = set((_env("RULES") or "").split())
    rules_prev = set((_env("PREV_RULES") or "").split())
    for rid in sorted(rules_now - rules_prev):
        title = _get_rule_title(rid)
        if rid == "LA-2" and _env("LA2_LEG") == "router" and inference is not None:
            # The same rule, said where the swing starts.
            title = inference.LA2_ROUTER_TITLE
        out.append({"id": "rule-fired", "field": "status.rules",
                    "from": None, "to": rid,
                    "summary": title if title else f"Issue {rid} detected"})
    for rid in sorted(rules_prev - rules_now):
        title = _get_rule_title(rid)
        out.append({"id": "rule-cleared", "field": "status.rules",
                    "from": rid, "to": None,
                    "summary": (f"Resolved: {title}" if title
                                else f"Issue {rid} cleared")})
    return out


def _journal_append(sample: dict, changes: list[dict]) -> None:
    """Append this cycle's transitions to the event journal, if one is set.

    Why transitions and not samples: a sample every five seconds forever is
    a database problem, and the samples are not what anyone asks about.
    "Was the internet down at 03:14, and for how long" is answered by the
    moments something *changed* — and `_changes()` above already computes
    exactly that set, with a user-facing sentence for each, once per cycle.
    Until now it was rendered and discarded.

    Opt-in via NETDIAG_MON_JOURNAL, because `--monitor`'s documented
    contract is a process that writes nothing to disk (lib/monitor.sh's
    header, docs/JSON-SCHEMA.md). A consumer piping the stream into its own
    program still gets that; the flag is what the recorder passes.

    Three kinds of line are written:

      * one per entry in `changes` — the transition itself;
      * a `gap` when the monitor was not looking (sleep, a stall), because
        a window that does not know how much of itself was observed will
        happily report an outage that was a closed lid, or an uptime that
        was nobody watching;
      * `monitor-started` on the first cycle of a process, so a reader can
        tell "no events because nothing happened" from "no events because
        nothing was running".

    Every line carries its own timestamp and network identity rather than
    inheriting them from a header, because this file is appended to by
    successive monitor processes across reboots and is read back by
    timestamp range. It is never rewritten in place.

    A failure here must never take down the stream: the monitor's job is to
    keep reporting, and a full disk or a read-only home directory is not a
    reason to stop watching the network. Errors are swallowed deliberately.
    """
    path = os.environ.get("NETDIAG_MON_JOURNAL")
    if not path:
        return

    base = {
        # The stream calls it `ts`; the journal calls it `t`. Deliberate:
        # a journal line is not a sample and should not look like one to a
        # reader that has both files open.
        "t": sample.get("ts"),
        "seq": sample.get("seq"),
        "network": (sample.get("network") or {}).get("id"),
        "network_label": (sample.get("network") or {}).get("label"),
    }
    lines = []

    if _env("SEQ") == "1":
        lines.append(dict(base, kind="monitor-started",
                          summary="Monitoring started"))

    gap = _i("GAP_S")
    if gap:
        lines.append(dict(base, kind="gap", gap_s=gap,
                          summary=f"Not observed for {gap}s"))

    for change in changes:
        lines.append(dict(base, kind=change.get("id"),
                          field=change.get("field"),
                          **{"from": change.get("from")},
                          to=change.get("to"),
                          summary=change.get("summary")))

    if not lines:
        return

    try:
        with open(path, "a", encoding="utf-8") as handle:
            for line in lines:
                handle.write(json.dumps(line, separators=(",", ":"),
                                        default=str) + "\n")
    except OSError:
        return

    # Trim once per process, not once per sample: a recorder that runs for
    # weeks would otherwise re-read the whole file every ten seconds to
    # answer a question that changes once a month.
    if _env("SEQ") == "1":
        _journal_prune(path)


def _journal_prune(path: str) -> None:
    """Roll the oldest lines into `<journal>-archive.jsonl` past the cap.

    Rolls rather than deletes, for the reason lib/output.sh's prune_history
    gives about the run store: the whole value of this file is depth, the
    first lines to go are always the oldest, and "the retention policy
    quietly ate your history" is the failure the feature exists to prevent.

    No lock, unlike prune_history. That is a real assumption and worth
    stating: the recorder is a singleton, and two monitors journaling to
    one path is a configuration this does not defend against. The cost if
    it happens is duplicated lines, never lost ones — the archive is
    appended before the live file is truncated, so a crash between the two
    duplicates rather than drops, and helpers/events.py dedupes on
    (timestamp, seq, kind) for exactly that reason.
    """
    try:
        keep = int(os.environ.get("NETDIAG_KEEP_EVENTS", "5000"))
    except ValueError:
        keep = 5000
    if keep <= 0:
        return
    try:
        with open(path, encoding="utf-8") as handle:
            lines = handle.readlines()
    except OSError:
        return
    # Same hysteresis as prune_history: trimming the moment the cap is
    # crossed rewrites the file on almost every start for no benefit.
    if len(lines) <= keep + keep // 10:
        return
    head, tail = lines[:-keep], lines[-keep:]
    archive = (path[:-6] if path.endswith(".jsonl") else path) + "-archive.jsonl"
    try:
        with open(archive, "a", encoding="utf-8") as handle:
            handle.writelines(head)
        with open(path, "w", encoding="utf-8") as handle:
            handle.writelines(tail)
    except OSError:
        return


def main() -> None:
    is_wifi = _env("IFACE_TYPE") == "wifi"
    link_up = os.environ.get("NETDIAG_MON_LINK_UP") == "1"
    rules = (_env("RULES") or "").split()
    # Freshness (Phase 1 of the reporting-accuracy plan): the medium tier's
    # DNS/TCP/RSSI answers are carried over between its 60 s refreshes, and
    # past THRESH_MON_STALE_FACTOR × its interval they no longer describe
    # "now" closely enough to present. They go NULL (the sample's
    # convention for "not measured"), never merely old — a consumer that
    # cannot see the age must not be handed a number it cannot age-check.
    # The flag is computed by lib/monitor.sh every cycle in production; an
    # unset flag (a test, or a stream from before this change) defaults
    # fresh so the nulling is a property of the declared policy, not of a
    # missing field.
    medium_fresh = _tri("MEDIUM_FRESH")
    if medium_fresh is None:
        medium_fresh = True
    sample = {
        # Fallback exists only for standalone/test invocation; it must
        # track NETDIAG_MON_SCHEMA in lib/monitor.sh.
        "schema": _i("SCHEMA") or 2,
        "version": _env("VERSION"),
        "ts": _env("TS"),
        "seq": _i("SEQ") or 0,
        # Seconds lost between this sample and the previous one, when
        # that exceeded the scheduled cadence by THRESH_MON_GAP_FACTOR;
        # null on an ordinary cycle.
        #
        # This is what a laptop lid closing looks like from the stream:
        # two samples eight hours apart, both reporting a healthy link,
        # and nothing in between. Without this field a consumer cannot
        # tell that silence from a dead network — so an overnight sleep
        # reads as an overnight outage. The monitor deliberately stays
        # dumb about *why* (sleep, SIGSTOP, a stalled probe); it reports
        # only that it was not looking, and for how long.
        "gap_s": _i("GAP_S"),
        # Which tiers actually refreshed this cycle. Everything outside
        # this list is carried over from an earlier sample, which a
        # consumer plotting a series needs to know before it draws a point.
        "refreshed": (_env("REFRESHED") or "").split(),
        # Per-tier data age in seconds, for the same reason `refreshed`
        # exists but phrased the way a consumer actually reads it: the fast
        # tier is refreshed every cycle, so it never has an age worth
        # reporting; medium and slow carry data between refreshes, and
        # age_s says how far back the number a consumer is reading comes
        # from. null until the tier's first run — age 0 is a measurement,
        # not the absence of one.
        "age_s": {
            "fast": _i("FAST_AGE_S"),
            "medium": _i("MEDIUM_AGE_S"),
            "slow": _i("SLOW_AGE_S"),
        },
        "link": {
            "up": link_up,
            "interface": _env("INTERFACE"),
            "type": _env("IFACE_TYPE"),
            "ip": _env("LOCAL_IP"),
            "gateway": _env("GATEWAY"),
            "gateway_mac": _env("GW_MAC"),
            "ssid": _env("SSID"),
            "bssid": _env("BSSID"),
        },
        # Byte-identical to what a full run records, because lib/monitor.sh
        # calls lib/netid.sh rather than reimplementing precedence. This is
        # the join key between a live sample and the charted history.
        "network": {
            "id": _env("NETWORK_ID"),
            "label": _env("NETWORK_LABEL"),
            # The canonical history group key for the same network
            # (netid_run's NETWORK_GROUP — the key --history groups by),
            # so a consumer joins onto history without re-deriving
            # grouping rules. Nullable: an older CLI emits nothing here
            # and the consumer falls back to `id`.
            "group_id": _env("NETWORK_GROUP"),
        },
        "vpn": {
            "active": os.environ.get("NETDIAG_MON_VPN_ACTIVE") == "1",
            "type": _env("VPN_TYPE"),
            "name": _env("VPN_NAME"),
        },
        "gateway": {
            "loss_pct": _f("GW_LOSS"),
            "rtt_avg_ms": _f("GW_RTT"),
            "rtt_jitter_ms": _f("GW_JITTER"),
        },
        "internet": {
            "loss_pct": _f("INET_LOSS"),
            # The second, independent target (see the full run's
            # internet_latency block, JSON-SCHEMA.md): L1 escalates only
            # when both targets agree, so a consumer auditing the verdict
            # needs the other leg's number, not just the primary's.
            "loss_pct_alt": _f("INET_LOSS_ALT"),
            "rtt_avg_ms": _f("INET_RTT"),
            "rtt_jitter_ms": _f("INET_JITTER"),
        },
        "jitter_ms": _f("INET_JITTER") if _f("INET_JITTER") is not None else _f("GW_JITTER"),
        "wifi": ({
            "rssi": _i("WIFI_RSSI"),
            "noise": _i("WIFI_NOISE"),
            "snr": _i("WIFI_SNR"),
            "channel": _env("WIFI_CHAN"),
        } if is_wifi and medium_fresh else
            (None if not is_wifi else {
                "rssi": None,
                "noise": None,
                "snr": None,
                "channel": None,
            })),
        "dns": ({
            "ok": _tri("DNS_OK"),
            "resolver": _env("DNS_RESOLVER"),
            "elapsed_ms": _f("DNS_MS"),
        } if medium_fresh else {
            "ok": None,
            "resolver": None,
            "elapsed_ms": None,
        }),
        "tcp": ({
            "any_ok": _tri("TCP_OK"),
            "targets": build_tcp(),
            "refused": build_refused(),
        } if medium_fresh else {
            "any_ok": None,
            "targets": [],
            "refused": build_refused(),
        }),
        # The fast HTTPS canary, one level deeper than the bare ok flag:
        # fail_kind names HOW the newest request failed (curl's exit class:
        # refused / timeout / dns / error) when it did, and success_pct is
        # the rolling connect-success ratio over the same window the loss
        # legs accumulate — a single refused probe reads differently from a
        # modem that refuses everything. ok follows the same tri-state
        # convention as dns.ok/tcp.any_ok: null is "the canary has not run",
        # not a failure.
        "web": {
            "ok": _tri("WEB_OK"),
            "fail_kind": _env("WEB_FAIL_KIND"),
            "success_pct": _f("WEB_SUCC_PCT"),
        },
        "public": {
            "ok": _tri("PUBLIC_OK"),
            "ip": _env("PUB_IP"),
            "isp": _env("PUB_ISP"),
            "asn": _env("PUB_ASN"),
            "city": _env("PUB_CITY"),
            "country": _env("PUB_CC"),
            "country_iso": _env("PUB_CC_ISO"),
            "captive_portal": _tri("CAPTIVE"),
            # The geo figures are last-KNOWN when the fetch is failing
            # (or a network change has not yet been verified by a fresh
            # one): never blanked by a failed attempt, but labelled.
            # False (or None on a stream older than this field) means
            # the geo block was fetched and verified.
            "stale": _tri("PUB_STALE"),
        },
        "status": {
            "severity": _env("SEVERITY") or "ok",
            "rules": rules,
            # Health severity and measurement availability are separate. A
            # sample can have no diagnosis rule while its router/internet
            # probes failed to produce a reading; consumers must not render
            # that as an all-clear.
            "measurement": _env("MEASUREMENT_STATE") or "unknown",
            # TCP-1 holding is the global suppressor for every loss alert.
            # Surfaced as its own boolean so a consumer doesn't have to
            # string-match the rules array to find it.
            "icmp_filtered": os.environ.get("NETDIAG_MON_ICMP_FILTERED") == "1",
            "degraded": os.environ.get("NETDIAG_MON_DEGRADED") == "1",
            # Paused by SIGUSR1 — probing is suspended, so every
            # measurement in this sample is stale by definition. A
            # consumer must not plot it or alert on it.
            "paused": os.environ.get("NETDIAG_MON_PAUSED") == "1",
            "cadence_s": _i("CADENCE_S"),
            # The burst this process is running, or null (see
            # _burst_block). Owned here, not by the consumer: a restart
            # to change cadence discarded the rolling state the warning
            # it was investigating lived in.
            "burst": _burst_block(),
            # Two-stage clearing (lib/stability.sh). `severity` and
            # `rules` are the HELD view; this says whether the link is
            # stable, unstable now, or recovering from a rule that has
            # cleared but has not yet been quiet for the stability window.
            # Overwritten with the CLI's sentences when inference runs.
            "stability": dict(_stability_state(), window_s=None,
                              last_ago_s=None, summary=None),
        },
    }

    changes = _changes()
    if changes:
        sample["changes"] = changes

    # ── Presentation blocks (Phase 3 of the reporting plan) ────────────
    # suitability: one row per activity — verdict from the fired rules'
    # impacts, a label and a figure line ("3% loss · 9 ms jitter") that
    # can never contradict it. hops: mac/router/internet state + reason,
    # judged from the same thresholds the rules fired on. headline: the
    # degraded status hero's copy. All three are computed by
    # helpers/inference.py from lib/thresholds.sh values exported into
    # the environment — the GUI renders them and re-derives nothing.
    #
    # A missing or malformed threshold set prints one stderr warning and
    # omits the blocks rather than killing the sample: the stream's
    # contract is to keep reporting even when an appendage fails (the
    # same shape _journal_append applies). Consumers render their own
    # neutral fallbacks for absent blocks, none of which judge.
    if inference is not None:
        roam_state = {
            "rules": rules,
            "link_up": link_up,
            "is_wifi": is_wifi,
            "rssi": _i("WIFI_RSSI"),
            "gw_loss": _f("GW_LOSS"),
            "gw_rtt": _f("GW_RTT"),
            "gw_jitter": _f("GW_JITTER"),
            "inet_loss": _f("INET_LOSS"),
            "inet_loss_alt": _f("INET_LOSS_ALT"),
            "inet_rtt": _f("INET_RTT"),
            "inet_jitter": _f("INET_JITTER"),
            "dns_ok": _tri("DNS_OK"),
            "dns_ms": _f("DNS_MS"),
            "tcp_ok": _tri("TCP_OK"),
            "web_ok": _tri("WEB_OK"),
            "web_fail_kind": _env("WEB_FAIL_KIND"),
            "web_succ_pct": _f("WEB_SUCC_PCT"),
            "stability": _stability_state(),
            "la2_leg": _env("LA2_LEG"),
            "vpn_active": sample["vpn"]["active"],
            "vpn_name": _env("VPN_NAME"),
            "icmp_filtered": sample["status"]["icmp_filtered"],
            "ssid": _env("SSID"),
            "prev_ssid": _env("PREV_SSID"),
            "bssid": _env("BSSID"),
            "prev_bssid": _env("PREV_BSSID"),
        }
        try:
            blocks = inference.build(roam_state)
        except SystemExit:
            print("monitor_sample.py: inference refused (thresholds "
                  "missing?) — omitting suitability/hops/headline",
                  file=sys.stderr)
        except Exception as exc:
            print(f"monitor_sample.py: inference failed ({exc}) — omitting "
                  "suitability/hops/headline", file=sys.stderr)
        else:
            sample["status"]["stability"] = blocks["stability"]
            sample["suitability"] = blocks["suitability"]
            sample["hops"] = blocks["hops"]
            sample["headline"] = blocks["headline"]

    _journal_append(sample, changes)

    json.dump(sample, sys.stdout, separators=(",", ":"), default=str)
    sys.stdout.write("\n")
    # Flush per sample: this is a stream, and a consumer that has to wait
    # for a 4 KB pipe buffer to fill sees a status indicator that lags
    # reality by minutes.
    sys.stdout.flush()


if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:
        # The reader went away (the app quit, or `| head -5` closed the
        # pipe). Exit non-zero without a traceback so monitor_run's loop
        # sees it and stops cleanly instead of spinning against a dead fd.
        try:
            sys.stdout.close()
        except BrokenPipeError:
            pass
        sys.exit(1)
