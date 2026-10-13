#!/usr/bin/env python3
"""Generate a synthetic HOME for re-capturing the README screenshots.

Why this exists
---------------
`HopwatchGUI --gallery[=DIR]` renders the app's real SwiftUI views against
real on-disk state: the CLI's run store (`$HOME/hopwatch/baseline.jsonl`,
read through `hopwatch --history`), the app's event journal
(`$HOME/Library/Application Support/<bundle id>/events.json`) and its
preferences. Pointed at a developer's real HOME, the pictures show that
person's Wi-Fi names, addresses and travel history. docs/assets/*.png are
published in a public repository, so they must never be captured that way.

This script writes a made-up HOME instead. Everything in it is invented:

  * network names are generic ("Home Wi-Fi", "Office", "Coffee Shop", ...)
  * LAN addresses are RFC 1918, public addresses are drawn from the
    documentation ranges (203.0.113.0/24, 198.51.100.0/24, 192.0.2.0/24,
    2001:db8::/32), ASNs from the documentation range AS64496-64511
  * MAC addresses are locally administered (02:00:00:00:xx:xx)
  * ISPs are "Example ..." placeholders, and no city is recorded

PRIVACY RULE: never copy, sample or "lightly anonymise" anything from a real
~/hopwatch, ~/net-diag or ~/Library. Add data here by inventing it.

Usage
-----
    python3 scripts/gallery-fixture.py /tmp/hw-fixture-home

    # An isolated copy of the app: its own bundle id means its own (empty)
    # UserDefaults, so none of the real app's preferences can reach a picture.
    rm -rf /tmp/hw-app && mkdir /tmp/hw-app && cp -R gui/build/Hopwatch.app /tmp/hw-app/
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.godigi.hopwatch.gallery" \\
        /tmp/hw-app/Hopwatch.app/Contents/Info.plist
    codesign --force --deep -s - /tmp/hw-app/Hopwatch.app

    H=/tmp/hw-fixture-home
    CFFIXED_USER_HOME=$H HOME=$H /tmp/hw-app/Hopwatch.app/Contents/MacOS/HopwatchGUI \\
        --gallery=/tmp/hw-gallery -locationBannerDismissed YES -hasOnboarded YES

Two traps, both of which render the real machine's data if missed:

  * NSHomeDirectory(), Application Support and the bundled CLI's $HOME all
    ignore the HOME variable and resolve the real home from the user
    database. CFFIXED_USER_HOME is what redirects them.
  * UserDefaults are read from the real preferences domain regardless of
    either variable (cfprefsd), so a copy of the bundle with another id is
    used, and the two settings the pictures need are passed as arguments.

The gallery prints "state: N events, M networks" first; this fixture is 5
networks and 56 events, so anything else means the real home leaked in.
Delete /tmp/hw-gallery's `home-full-*` files; docs/assets does not use them.

Timestamps are relative to "now" (override with --now for a reproducible
store), so regenerate immediately before capturing: the newest run is a few
minutes old, which is what keeps the app from labelling its data stale.
The output directory is replaced if it already exists, but only if it is
empty or looks like a previous fixture (it holds a `.hopwatch-gallery-fixture`
marker); anything else is refused so the script cannot be aimed at a real HOME.
"""

from __future__ import annotations

import argparse
import json
import random
import shutil
import sys
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

MARKER = ".hopwatch-gallery-fixture"
VERSION = "1.16.2"
DEFAULT_BUNDLE_ID = "com.godigi.hopwatch.gallery"

# Seconds between the Unix epoch and Foundation's reference date (2001-01-01).
# events.json is written by a default JSONEncoder, which stores a Date as a
# bare Double of seconds since that reference date.
REFERENCE_DATE_OFFSET = 978307200


# ── The invented networks ───────────────────────────────────────────────

NETWORKS = {
    "home": dict(
        label="Home Wi-Fi", mac="02:00:00:00:01:01", bssid="02:00:00:00:01:11",
        gw="192.168.1.1", ip="192.168.1.42", isp="Example Broadband",
        asn="AS64496", pub="203.0.113.17", dns="192.168.1.1",
        chan="149 (5 GHz, 80 MHz)", band="5GHz", chan_n="149", rssi=-52, noise=-93,
        gw_rtt=3.1, inet_rtt=14.2, down=480.0, up=92.0, tx=1201,
        neighbours=3, ipv6="2001:db8:1::42"),
    "office": dict(
        label="Office", mac="02:00:00:00:02:01", bssid="02:00:00:00:02:11",
        gw="10.20.0.1", ip="10.20.0.87", isp="Example Business Fiber",
        asn="AS64497", pub="198.51.100.24", dns="10.20.0.2",
        chan="44 (5 GHz, 80 MHz)", band="5GHz", chan_n="44", rssi=-58, noise=-92,
        gw_rtt=2.2, inet_rtt=9.4, down=890.0, up=640.0, tx=866,
        neighbours=8, ipv6=None),
    "coffee": dict(
        label="Coffee Shop", mac="02:00:00:00:03:01", bssid="02:00:00:00:03:11",
        gw="192.168.0.1", ip="192.168.0.113", isp="Sample Cable",
        asn="AS64498", pub="192.0.2.55", dns="192.168.0.1",
        chan="6 (2.4 GHz, 20 MHz)", band="2GHz", chan_n="6", rssi=-63, noise=-90,
        gw_rtt=6.8, inet_rtt=27.5, down=42.0, up=9.5, tx=144,
        neighbours=11, ipv6=None),
    "airport": dict(
        label="Airport Wi-Fi", mac="02:00:00:00:04:01", bssid="02:00:00:00:04:11",
        gw="172.16.0.1", ip="172.16.12.208", isp="Placeholder Telecom",
        asn="AS64499", pub="198.51.100.200", dns="172.16.0.1",
        chan="36 (5 GHz, 40 MHz)", band="5GHz", chan_n="36", rssi=-67, noise=-91,
        gw_rtt=9.5, inet_rtt=38.0, down=21.0, up=5.5, tx=240,
        neighbours=14, ipv6=None),
    "hotel": dict(
        label="Hotel Guest", mac="02:00:00:00:05:01", bssid="02:00:00:00:05:11",
        gw="10.0.50.1", ip="10.0.50.77", isp="Sample Cable",
        asn="AS64498", pub="203.0.113.140", dns="10.0.50.1",
        chan="11 (2.4 GHz, 20 MHz)", band="2GHz", chan_n="11", rssi=-60, noise=-91,
        gw_rtt=5.4, inet_rtt=24.0, down=58.0, up=14.0, tx=216,
        neighbours=9, ipv6=None),
}

# Diagnosis prose, in the CLI's own register. Titles and general wording follow
# lib/rules catalog (`hopwatch --rules-catalog`); nothing here names a person
# or place.
DIAG = {
    "WS-1": ("warn",
             "Your WiFi channel is crowded ({n} neighbouring networks). If "
             "performance is inconsistent, choose a less busy channel or let "
             "the router select one automatically."),
    "G3": ("warn",
           "A small share of packets to your router are going missing. This "
           "is not your internet provider; your internet service itself looks "
           "fine from here. Moving closer to the router or reducing Wi-Fi "
           "congestion usually helps."),
    "L2": ("warn",
           "Some traffic is being lost on the way out to the internet even "
           "though the router itself is clean. That is enough to cause an "
           "occasional stutter or stall, but not enough to break the "
           "connection. It points past your front door, at the line or the "
           "ISP."),
    "D3": ("warn",
           "Your configured DNS server takes a long time to answer name "
           "lookups, so every new website or link pauses before it begins "
           "loading. Restarting your router or enabling Encrypted DNS in "
           "your browser clears the delay."),
    "W1": ("warn",
           "Your wireless signal is weak enough to cause retransmissions, "
           "latency spikes and dropouts. Moving closer to the router or "
           "switching to a nearer access point usually helps."),
    "B1": ("warn",
           "Your router delays latency-sensitive traffic during heavy "
           "simultaneous downloads or uploads, which makes calls and games "
           "feel laggy. Pausing heavy background transfers during calls helps."),
    "W6": ("info",
           "Your Mac is connected to the slower 2.4 GHz band even though a "
           "faster 5 GHz band on the same network may be available. "
           "Reconnecting prompts macOS to join the faster one."),
    "SP-1": ("info",
             "Your download speed is about as fast as this Wi-Fi connection "
             "can physically carry, so the measured number is the ceiling of "
             "your wireless link rather than of your internet plan."),
}

# Rule titles as the event journal phrases them (the monitor copies the
# catalog title into the event summary).
RULE_TITLE = {
    "G3": "Minor packet loss to router",
    "L2": "Moderate internet packet loss",
    "D3": "DNS server sluggish",
    "WS-1": "WiFi channel is congested",
    "W1": "Weak WiFi signal",
}

ACTIVITIES = [
    ("calls", "Video & voice calls"),
    ("streaming", "Streaming"),
    ("gaming", "Gaming"),
    ("vpn", "VPN & remote access"),
    ("browsing", "Ordinary browsing"),
]


def iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def network_id(n: dict) -> str:
    # The record format netid_run writes once macOS discloses the SSID.
    return f"wifi:ssid={n['label']},mac={n['mac']}"


# ── One stored run ──────────────────────────────────────────────────────

def make_record(rng: random.Random, when: datetime, key: str, mode: str,
                faults: tuple[str, ...] = (), degrade: float = 0.0) -> dict:
    """A record shaped like `hopwatch --json` output (docs/JSON-SCHEMA.md).

    `faults` are rule ids to fire in this run; `degrade` scales latency/loss
    noise so a flagged run also reads worse in the charts.
    """
    n = NETWORKS[key]
    full = mode == "full"

    def jit(base: float, spread: float) -> float:
        return round(max(0.3, base * (1 + rng.uniform(-spread, spread))), 3)

    gw_loss = 0.0
    inet_loss = 0.0
    gw_rtt = jit(n["gw_rtt"] * (1 + degrade), 0.18)
    inet_rtt = jit(n["inet_rtt"] * (1 + degrade * 0.8), 0.12)
    rssi = n["rssi"] + rng.randint(-3, 3) - (6 if "W1" in faults else 0)
    if "G3" in faults:
        gw_loss = rng.choice([4.0, 6.0, 8.0, 10.0])
    if "L2" in faults:
        inet_loss = rng.choice([4.0, 6.0, 8.0])

    diagnosis = []
    for rid in faults:
        sev, text = DIAG[rid]
        diagnosis.append({"severity": sev, "rule": rid,
                          "summary": text.format(n=n["neighbours"])})
    if key == "coffee" and full:
        diagnosis.append({"severity": "info", "rule": "W6",
                          "summary": DIAG["W6"][1]})
    worst = ("critical" if any(d["severity"] == "critical" for d in diagnosis)
             else "warn" if any(d["severity"] == "warn" for d in diagnosis)
             else "info" if diagnosis else None)
    root_cause = next((d["summary"] for d in diagnosis
                       if d["severity"] == "warn"), None)

    bb = {"idle_gw_rtt_ms": None, "loaded_gw_rtt_ms": None,
          "idle_inet_rtt_ms": None, "loaded_inet_rtt_ms": None,
          "gw_delta_ms": None, "inet_delta_ms": None,
          "gw_grade": None, "inet_grade": None}
    speed = None
    mtu = {"effective": None, "path_size": None}
    if full:
        gw_d = round(rng.uniform(0.5, 4.0) * (1 + degrade * 6), 1)
        inet_d = round(rng.uniform(1.0, 9.0) * (1 + degrade * 6), 1)
        grade = lambda d: "A" if d < 15 else "B" if d < 40 else "C"  # noqa: E731
        bb = {"idle_gw_rtt_ms": gw_rtt, "loaded_gw_rtt_ms": round(gw_rtt + gw_d, 3),
              "idle_inet_rtt_ms": inet_rtt, "loaded_inet_rtt_ms": round(inet_rtt + inet_d, 3),
              "gw_delta_ms": gw_d, "inet_delta_ms": inet_d,
              "gw_grade": grade(gw_d), "inet_grade": grade(inet_d)}
        speed = {"down_mbps": jit(n["down"], 0.12), "up_mbps": jit(n["up"], 0.12),
                 "latency_ms": jit(n["inet_rtt"] * 0.4, 0.2),
                 "jitter_ms": round(rng.uniform(0.3, 2.0), 3),
                 "server": "Example Speedtest Server"}
        mtu = {"effective": 1500, "path_size": 1472}

    hops = []
    hop_ips = [n["gw"], "100.64.0.1", "203.0.113.1", "198.51.100.1", "192.0.2.1", "1.1.1.1"]
    acc = 0.0
    for i, ip in enumerate(hop_ips, 1):
        acc += n["inet_rtt"] / len(hop_ips) * rng.uniform(0.7, 1.3)
        hops.append({"n": i, "ip": ip, "responded": True, "rtt_ms": round(acc, 3)})

    def rec_dns(resolver, name, answer):
        return {"resolver": resolver, "name": name, "answer": answer, "ok": True}

    rec = {
        "version": VERSION,
        "timestamp": iso(when),
        "run_mode": mode,
        "run_id": None,
        "interface": {
            "name": "en0", "ip": n["ip"], "gateway": n["gw"],
            "gateway_mac": n["mac"], "type": "wifi", "link_status": "active",
            "link_up": True, "self_assigned_ip": False, "link_mbps": None,
            "link_max_mbps": None, "duplex": None, "service": "Wi-Fi",
            "metered": False, "metered_certain": False,
            "dhcp_router": n["gw"],
        },
        "network": {"id": network_id(n), "label": n["label"]},
        "wifi": {
            "ssid": n["label"], "bssid": n["bssid"], "security": "WPA2_PSK",
            "rssi": rssi, "noise": n["noise"], "snr": rssi - n["noise"],
            "channel": n["chan"], "phy": "802.11ax", "tx_rate": n["tx"],
            "privileged": False, "name_hidden": False, "ssid_source": "corewlan",
        },
        "gateway": {"ip": n["gw"], "loss_pct": gw_loss, "rtt_avg_ms": gw_rtt,
                    "rtt_jitter_ms": jit(0.9, 0.5)},
        "internet_latency": {
            "target": "1.1.1.1", "rtt_avg_ms": inet_rtt,
            "rtt_jitter_ms": jit(1.8, 0.5), "loss_pct": inet_loss,
            "target_alt": "8.8.8.8", "rtt_avg_ms_alt": round(inet_rtt * 1.06, 3),
            "loss_pct_alt": inet_loss,
        },
        "public": {"ip": n["pub"], "asn": n["asn"], "isp": n["isp"],
                   "city": None, "country": "United States",
                   "country_iso": "US", "captive_portal": False},
        "dns": [rec_dns(r, name, ans)
                for name, ans in (("apple.com", "17.253.144.10"),
                                  ("cloudflare.com", "104.16.132.229"))
                for r in (n["dns"], "1.1.1.1", "8.8.8.8")],
        "traceroute": {"target": "1.1.1.1", "hops": hops},
        "per_hop": [{"n": h["n"], "ip": h["ip"], "responded": True,
                     "loss_pct": 0.0, "avg_ms": h["rtt_ms"]} for h in hops] if full else [],
        "bufferbloat": bb,
        "mtu": mtu,
        "ipv6": {
            "available": bool(n["ipv6"]), "global_addr": n["ipv6"],
            "gateway": "fe80::1" if n["ipv6"] else None,
            "ping_loss_pct": 0.0 if n["ipv6"] else None,
            "aaaa_ok": bool(n["ipv6"]), "trace_hops": None,
            "tcp_v6_ok": bool(n["ipv6"]), "only": False, "clat": False,
        },
        "vpn": {"active": False, "type": None, "name": None},
        "tcp_reach": [
            {"host": h, "port": p, "ok": True,
             "elapsed_ms": round(n["inet_rtt"] * rng.uniform(1.0, 1.6), 1)}
            for h, p in (("1.1.1.1", 443), ("8.8.8.8", 443),
                         ("github.com", 443), ("apple.com", 443))
        ],
        "path_actors": {"split_tunnel": False, "split_tunnel_interfaces": [],
                        "proxy": False, "proxy_detail": None,
                        "network_filters": []},
        "availability": {"window_hours": 24, "outages": 0, "downtime_s": 0,
                         "longest_outage_s": 0, "short_drops": 0,
                         "unobserved_pct": 0},
        "traffic": {"sampled_s": 2.0, "down_mbps": 0.31, "up_mbps": 0.04,
                    "top_processes": [
                        {"name": "Safari", "down_mbps": 0.2, "up_mbps": 0.02},
                        {"name": "Mail", "down_mbps": 0.06, "up_mbps": 0.01}]},
        "watcher": {"state": "ok", "program": None, "interval_s": 900,
                    "last_exit": 0, "last_run_age_s": 120,
                    "installed_age_s": 1209600, "path_blocked": False},
        "wifi_scan": ({"current_channel": n["chan_n"], "current_band": n["band"],
                       "neighbour_count": n["neighbours"] + 4,
                       "current_channel_neighbours": n["neighbours"]}
                      if full else None),
        "wifi_disconnects": {"window_hours": 1, "count": 0, "events": []},
        "speedtest": speed,
        "ntp": {"drift_seconds": round(rng.uniform(0.005, 0.06), 6),
                "using_network_time": True, "server": "time.example.net"},
        "duplicate_ips": [],
        "dhcp": {"server": n["gw"],
                 "lease_start": when.strftime("%m/%d/%Y %H:%M:%S"),
                 "lease_end": (when + timedelta(hours=24)).strftime("%m/%d/%Y %H:%M:%S"),
                 "time_remaining_s": 82800, "dns_servers": n["dns"]},
        "mtr": None,
        "wan": {"load_balancing": {"distinct_asns": [n["asn"]],
                                   "distinct_ips": [n["pub"]], "active": False},
                "double_nat": {"detected": False, "rfc1918_chain": [n["gw"]],
                               "home_chain": [], "home_count": 0,
                               "isp_transit_chain": [], "isp_transit_count": 0},
                "upnp": {"state": "enabled", "device": "Example Router",
                         "url": None, "tested_via": "nat-pmp"}},
        "hosts_file": {"custom_count": 0, "suspicious_redirects": []},
        "timings": {"total_s": 71.4 if full else 6.2, "budget_s": 30.0 if full else 8.0,
                    "over_budget": full, "phases": {}},
        "baseline": {"compared_runs": 10, "network_id": network_id(n),
                     "skipped_other_networks": 0, "regressions": []},
        "diagnosis": diagnosis,
        "most_likely_root_cause": root_cause,
        "netdiag_extras": {"arp_gw_incomplete": False,
                           "network_changed_mid_run": False, "target": None,
                           "target_ping": None, "target_traceroute": None},
        "suitability": suitability(faults),
    }
    del worst  # severity is derived by the CLI from `diagnosis`, not stored
    return rec


def suitability(faults: tuple[str, ...]) -> list[dict]:
    degraded = {"calls": {"G3", "L2", "W1", "B1"}, "streaming": {"L2", "W1"},
                "gaming": {"G3", "L2", "B1", "W1"}, "vpn": {"G3", "L2", "W1"},
                "browsing": {"D3"}}
    out = []
    for act, label in ACTIVITIES:
        because = [f for f in faults if f in degraded[act]]
        out.append({"activity": act, "label": label,
                    "verdict": "degraded" if because else "good",
                    "because": because, "unmeasured_reason": None})
    return out


# ── The story: where the Mac was, hour by hour, for two weeks ───────────

def schedule(now: datetime) -> list[tuple[datetime, str, str, tuple[str, ...], float]]:
    """(when, network, mode, faults, degrade) for every stored run, oldest first."""
    rng = random.Random(20261013)
    runs = []

    def add(dt, key, mode, faults=(), degrade=0.0):
        runs.append((dt, key, mode, tuple(faults), degrade))

    day0 = (now - timedelta(days=14)).replace(hour=0, minute=0, second=0, microsecond=0)
    fault_days = {
        12: ("home", 20, ("L2",), 0.5),
        10: ("office", 12, ("D3",), 0.4),
        6: ("airport", 12, ("D3",), 0.6),
        4: ("home", 16, ("G3",), 0.7),
        3: ("home", 20, ("G3",), 0.8),
        1: ("home", 8, ("WS-1",), 0.15),
    }
    for d in range(14, -1, -1):
        day = day0 + timedelta(days=14 - d)
        weekday = day.weekday() < 5
        slots = [8, 12, 16, 20, 23] if d else [8, 12, 16]
        for h in slots:
            minute = rng.randint(2, 50)
            when = day + timedelta(hours=h, minutes=minute)
            if when > now - timedelta(minutes=25):
                continue
            if d == 9:
                key = "home" if h == 8 else "airport"
            elif d == 8:
                key = "hotel" if h in (20, 23, 8) else "coffee"
            elif d == 7:
                key = "coffee" if h in (12, 16) else "hotel"
            elif d == 6:
                key = "hotel" if h == 8 else "airport"
            elif d == 5 and h == 8:
                key = "airport"
            elif day.weekday() in (0, 1, 3) and 10 <= h <= 17:
                key = "office"
            elif d in (4, 2) and h == 12 and not weekday:
                key = "coffee"
            else:
                key = "home"
            mode = "quick"
            if h in (8, 20) and rng.random() < 0.5:
                mode = "full"
            faults, degrade = (), 0.0
            fd = fault_days.get(d)
            if fd and fd[0] == key and h == fd[1]:
                faults, degrade = fd[2], fd[3]
            add(when, key, mode, faults, degrade)
    # A first full check on every place the Mac turned up in.
    seen = set()
    for i, (dt, key, mode, f, dg) in enumerate(runs):
        if key not in seen:
            seen.add(key)
            runs[i] = (dt, key, "full", f, dg)
    # Home, today: a full check shortly before "now", then a quick one.
    add(now - timedelta(hours=3, minutes=40), "home", "full")
    add(now - timedelta(minutes=11), "home", "quick")
    runs.sort(key=lambda r: r[0])
    return runs


# ── The event journal ───────────────────────────────────────────────────

def make_events(now: datetime, runs: list) -> list[dict]:
    """events.json: newest first, as EventStore keeps it.

    Network moves and fault episodes are derived from the stored runs so the
    two stores tell one story; a few extras (public-IP changes, a VPN session,
    roams, alerts) are placed by hand.
    """
    nid = {k: network_id(v) for k, v in NETWORKS.items()}
    ev: list[dict] = []

    def add(when: datetime, kind: str, summary: str, net: str | None,
            rule: str | None = None):
        ev.append({"id": str(uuid.uuid4()).upper(),
                   "date": when.timestamp() - REFERENCE_DATE_OFFSET,
                   "kind": kind, "summary": summary, "ruleID": rule,
                   "network": net, "continuesPrevious": False})

    def episode(start: datetime, minutes: float, rule: str, net: str):
        add(start, "rule-fired", RULE_TITLE[rule], net, rule)
        add(start + timedelta(minutes=minutes), "rule-cleared",
            RULE_TITLE[rule], net, rule)

    add(runs[0][0] - timedelta(minutes=30), "monitor-started",
        "Monitoring started", nid[runs[0][1]])
    prev = runs[0]
    for run in runs[1:]:
        when, key, _mode, faults, _deg = run
        if key != prev[1]:
            a, b = NETWORKS[prev[1]]["label"], NETWORKS[key]["label"]
            add(when - timedelta(minutes=7), "wifi-network-changed",
                f"Wi-Fi network changed: {a} \u2192 {b}", nid[key])
        for i, rule in enumerate(faults):
            mins = {"G3": 3.0, "L2": 6.0, "D3": 11.0, "WS-1": 9.0}.get(rule, 4.0)
            episode(when - timedelta(minutes=20 + 9 * i), mins, rule, nid[key])
            if rule in ("L2", "G3"):
                add(when - timedelta(minutes=19 + 9 * i), "alert",
                    "Internet connection degraded" if rule == "L2"
                    else "Connection is unstable", nid[key])
        prev = run

    # Hand-placed extras.
    day = timedelta(days=1)
    hr = timedelta(hours=1)
    add(now - 11 * day - 3 * hr, "public-ip-changed", "Public IP changed", nid["home"])
    add(now - 2 * day - 6 * hr, "public-ip-changed", "Public IP changed", nid["home"])
    add(now - 2 * hr, "public-ip-changed", "Public IP changed", nid["home"])
    add(now - 5 * hr, "monitor-started", "Monitoring started", nid["home"])
    office_days = sorted({r[0].date() for r in runs if r[1] == "office"})
    if office_days:
        d0 = datetime.combine(office_days[1 if len(office_days) > 1 else 0],
                              datetime.min.time(), tzinfo=timezone.utc)
        add(d0 + timedelta(hours=9, minutes=4), "vpn-connected",
            "VPN connected (Work VPN)", nid["office"])
        add(d0 + timedelta(hours=16, minutes=48), "vpn-disconnected",
            "VPN disconnected (Work VPN)", nid["office"])
    add(now - 40 * timedelta(minutes=1), "wifi-roamed",
        "Roamed to a different Wi-Fi access point", nid["home"])
    for k, mins in enumerate((2, 4, 2)):
        episode(now - 3 * day - (5 - 2 * k) * hr, mins, "G3", nid["home"])
    add(now - 3 * day - 3 * hr, "alert", "Connection is unstable", nid["home"])
    episode(now - 14 * hr, 5, "L2", nid["home"])
    add(now - 14 * hr + timedelta(minutes=1), "alert",
        "Internet connection degraded", nid["home"])
    episode(now - 6 * hr, 1.5, "G3", nid["home"])
    ev.sort(key=lambda e: -e["date"])
    return ev


# ── Writing it out ──────────────────────────────────────────────────────

def write_home(home: Path, now: datetime, bundle_id: str) -> dict:
    rng = random.Random(20261013)
    runs = schedule(now)
    store = home / "hopwatch"
    store.mkdir(parents=True)
    with open(store / "baseline.jsonl", "w", encoding="utf-8") as fh:
        for when, key, mode, faults, degrade in runs:
            rec = make_record(rng, when, key, mode, faults, degrade)
            fh.write(json.dumps(rec, separators=(",", ":"), ensure_ascii=False) + "\n")

    support = home / "Library" / "Application Support" / bundle_id
    support.mkdir(parents=True)
    events = make_events(now, runs)
    (support / "events.json").write_text(json.dumps(events), encoding="utf-8")
    return {"runs": len(runs), "events": len(events),
            "networks": sorted({r[1] for r in runs})}


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description="Write a synthetic HOME (run store and event journal) for `HopwatchGUI --gallery` screenshots. "
                    "Everything in it is invented; see the file header.")
    ap.add_argument("home", help="directory to create, e.g. /tmp/hw-fixture-home")
    ap.add_argument("--now", help="ISO-8601 UTC instant to treat as 'now' "
                                  "(default: the current time)")
    ap.add_argument("--bundle-id", default=DEFAULT_BUNDLE_ID,
                    help="bundle id of the app copy that will read the "
                         f"fixture (default: {DEFAULT_BUNDLE_ID})")
    args = ap.parse_args(argv)

    now = (datetime.fromisoformat(args.now.replace("Z", "+00:00")).astimezone(timezone.utc)
           if args.now else datetime.now(timezone.utc).replace(microsecond=0))
    home = Path(args.home).expanduser().resolve()
    if home == Path.home().resolve() or home == Path("/"):
        print("refusing to write into the real home directory", file=sys.stderr)
        return 3
    if home.exists():
        if any(home.iterdir()) and not (home / MARKER).exists():
            print(f"refusing to replace {home}: not empty and not a previous "
                  f"fixture (no {MARKER})", file=sys.stderr)
            return 3
        shutil.rmtree(home)
    home.mkdir(parents=True)
    (home / MARKER).write_text("synthetic data; safe to delete\n")
    info = write_home(home, now, args.bundle_id)
    print(f"{home}: {info['runs']} runs on {len(info['networks'])} networks, "
          f"{info['events']} events")
    return 0


if __name__ == "__main__":
    sys.exit(main())
