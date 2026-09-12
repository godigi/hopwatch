#!/usr/bin/env python3
"""Emit `netdiag --rules-catalog` as a single JSON object.

Every rule the diagnosis engine (`lib/diagnosis.sh`, `lib/wan.sh`,
`lib/output.sh`) and the live monitor (`lib/monitor.sh::_mon_rules`) can
emit gets one entry here: a title, a category, a descriptive severity, a
scope, plain-English prose, and an anchor into
`docs/DIAGNOSIS-RULES.md`.

This exists because CLAUDE.md draws a hard line: "The GUI holds no
diagnostic logic. gui/ renders what the CLI decides: rule IDs come from
status.rules, prose comes from diagnosis[].summary verbatim." The GUI has
had nothing to show next to a rule-ID chip except the ID itself — this
catalog is the plain-English layer that belongs in the CLI instead of
being reinvented in Swift.

Two things this is emphatically not:
  * Not per-incident prose. `blurb` describes what a rule means in
    general — what it means, what usually causes it, what helps. The
    text a user reads about *this run's* fault is, and remains,
    `diagnosis[].summary`, generated fresh each run with this run's own
    numbers baked in. Reusing that text here would go stale the moment
    either drifts, so the wording below is adapted from —
    not copied from — docs/DIAGNOSIS-RULES.md's prose, and says nothing
    docs/DIAGNOSIS-RULES.md doesn't already say.
  * Not a judge. Nothing here reads lib/thresholds.sh and nothing here
    contains a numeric cutoff — blurbs stay qualitative ("weak signal",
    "drifted noticeably") and point at `doc` for the actual number. Same
    split JSON-SCHEMA.md draws everywhere else between a measurement and
    a verdict.

Called once from bin/netdiag's --rules-catalog mode with the running
version already resolved in bash and passed through
NETDIAG_RULES_VERSION — the same handshake shape capabilities.py uses for
NETDIAG_CAP_VERSION, kept as its own variable because this helper answers
a narrower question (what does each rule mean) than --capabilities does
(what can this install do).

── The metrics glossary ──────────────────────────────────────────────────
`metrics` is a second, sibling array on the same document: not one entry
per diagnosis rule but one entry per *jargon term* the report card shows —
"router", "MTU", "jitter" — explaining what the word means in plain
English, for the reader who has never heard it before. It lives here
rather than in a standalone `helpers/glossary.py` because it answers the
same question `rules` does ("what does this word on screen mean?") for the
same consumer (a `questionmark.circle` hint in `RunReportView`), and a
second CLI mode would just be a second round trip and a second cache file
for something this small. `SCHEMA_RULES_CATALOG` bumped 1 → 2 for the
addition, 2 → 3 for the optional per-rule `also` category, and 3 → 4 for
an optional per-metric `why_absent` plus 16 new metrics entries (the
`--history` metric keys and the live monitor's chart measurements) — all
additive only, per this schema's own promise in docs/JSON-SCHEMA.md, so a
build that reads only `rules`, or only `category`, keeps working
unchanged.

Like `blurb`, `help` stays qualitative: no dBm, no ms, no percent. A
number belongs in lib/thresholds.sh and nowhere else, and a glossary entry
answers "what is this thing" rather than "is this reading good".
"""

from __future__ import annotations

import json
import os
import sys

# This file's own schema: the shape of the --rules-catalog document.
# v1 → v2: added the sibling `metrics` glossary array.
# v2 → v3: added the optional per-rule `also` category (see CATEGORIES).
# v3 → v4: added the optional per-metric `why_absent` field, plus 16 new
# `metrics` entries — the 13 `--history` metric keys and 3 for the live
# monitor's chart measurements.
# v4 → v5: added the optional per-rule `impacts` map (see ACTIVITIES /
# IMPACT_LEVELS) — which activities a fired rule breaks or degrades, for
# helpers/suitability.py to project without re-judging any metric itself.
SCHEMA_RULES_CATALOG = 5

# The measurement family each rule judges — the GUI tints a report-card
# row by this, not by severity, so a "varies"-severity rule like B1 still
# lands on one specific row.
CATEGORIES = frozenset({
    "router", "internet", "dns", "wifi", "load", "mtu", "speed", "clock",
    "ipv6", "vpn", "lan", "dhcp", "topology", "baseline",
    # The one category that is not a property of the network: netdiag
    # judging its own background watcher. It earns a category rather than
    # borrowing `baseline` because borrowing would tint the Speed row —
    # putting a red mark on a throughput number because a launchd agent
    # is broken, which is the same class of mistake as G1's green dot
    # beside "35% loss", only pointed the other way.
    "netdiag",
    # How this network has behaved over time, judged from the event
    # journal rather than from anything this run measured. Its own family
    # because it is the only one whose evidence predates the run.
    "availability",
    # Not a property of the path either: what this Mac itself was putting
    # on the link while the path was being measured. It is its own family
    # because it qualifies the load and speed rows without being a
    # judgement about either — tagging it `load` would tint the Under-load
    # row whenever a backup ran, which is the opposite of what it means.
    "traffic",
})

# `category` names the measurement a rule is ABOUT — the row whose number
# the rule is passing judgement on. It does not name the suspected cause.
#
# That distinction is not pedantry; getting it backwards is what produced
# a green dot beside "35% loss". G1 ("gateway packet loss with weak
# Wi-Fi") was filed under `wifi` because the Wi-Fi signal is its *cause*,
# so the Router row — the row carrying the 35% — was left untinted while
# the red mark landed on a Wi-Fi row that had no number in it at all.
#
# A handful of rules genuinely are about two measurements at once, and
# for those `also` names the second one. Both rows tint. `category` stays
# the primary — the number the rule is chiefly judging — so a consumer
# that only reads `category` (any build predating this field) keeps the
# behaviour it had, which is why this is additive rather than a change of
# `category` to a list.
#
# One secondary, not a list: no rule today is about three measurements,
# and a list invites the temptation to tag a rule with everything it
# vaguely touches, which puts the tint back everywhere and means nothing.
# If a third is ever genuinely needed, widen it then.

# "varies" covers the handful of rules that grade by magnitude — the same
# add_diag call site chooses warn or critical depending on how far past
# the threshold the measurement landed (B1, B2, M1, NT-1 below). The
# per-incident severity always arrives in diagnosis[].severity anyway;
# this field is descriptive, not authoritative.
SEVERITIES = frozenset({"info", "warn", "critical", "varies"})

# scan    — lib/diagnosis.sh / lib/wan.sh / lib/output.sh only.
# monitor — lib/monitor.sh::_mon_rules only (CP-1: there is no scan-mode
#           reading of a captive portal for it to mirror).
# both    — evaluated in both places, on whichever inputs that mode has.
SCOPES = frozenset({"scan", "monitor", "both"})

# The activities `helpers/suitability.py` projects rules onto. Five, and
# closed: a sixth means a new row on every report card and in the arrival
# card, which is a product decision, not a data one.
ACTIVITIES = frozenset({"calls", "streaming", "gaming", "vpn", "browsing"})

# ── Where the line between the two levels sits ────────────────────────
# `broken` means the activity cannot function at all right now.
# `degraded` means it functions, but unreliably or badly.
#
# Two consequences worth stating, because getting them wrong is how this
# table turns into a scaremonger:
#
#   * An **intermittent** fault is never `broken`. A flapping link (AV-2)
#     does end the call you are on, but the next one connects; `broken`
#     renders as "won't hold up", which reads as "do not bother trying".
#   * A **historical** fault is never `broken` either. AV-1 counts
#     outages over the last day, and the rest of a report describes the
#     link as it is at this instant. A red "video calls: won't hold up"
#     on a connection that is fine right now, because of last night, is a
#     claim the run has not established.
#
# The one that caught this: NAT-1 was `gaming: broken` because its own
# prose says double NAT "breaks games". It does not — it breaks *inbound*
# reach, and a game that connects outbound to a matchmaking server plays
# fine, just with Strict NAT and worse matchmaking. What double NAT truly
# breaks is port-forwarding-dependent (Plex, Steam in-home streaming,
# doorbells), and none of those has a row here.
#
# How badly a rule hits an activity. Deliberately two levels, not three:
# "good" is the absence of any impact, and a third middle grade would be a
# judgement about magnitude — which lives in diagnosis[].severity, decided
# against lib/thresholds.sh, and must not be re-decided here.
IMPACT_LEVELS = frozenset({"degraded", "broken"})

# Who can actually apply the fix. `nobody` is for the rules whose honest
# advice is "there is nothing to do" — a real answer, and better than
# inventing an action to fill a required field.
FIX_TARGETS = frozenset({"you", "your_router", "your_isp",
                         "network_operator", "nobody"})

# The two targets where the advice genuinely changes depending on whether
# the equipment is yours. `you` (something on this Mac) and `your_isp`
# (a phone call either way) read the same in a hotel as at home.
FIX_TARGETS_NEEDING_AWAY = frozenset({"your_router", "network_operator"})

# One entry per rule the engine can emit. Order follows
# docs/DIAGNOSIS-RULES.md's own reading order rather than rule-ID sort,
# except that a rule's variants sit beside it (N1b after N1, DI-2 after
# DI-1) even where the doc parted them — grouping siblings beats strict
# parity for a reader looking one rule up.
#
# UP-1 is deliberately absent: docs/DIAGNOSIS-RULES.md documents it as
# reserved (the Report card already shows UPnP state directly; no
# add_diag call exists anywhere for it) — see tests/test_rules_catalog.bats
# for the explicit exclusion this drives.
RULES: list[dict[str, object]] = [
    {
        "id": "N1",
        "title": "No network connection at all",
        "category": "router",
        "severity": "critical",
        "scope": "both",
        "blurb": (
            "Nothing is joined: no WiFi network is associated and no "
            "ethernet cable is carrying a link. Nothing else can be "
            "diagnosed until basic connectivity exists. Turn WiFi on and "
            "pick a network, or check that the ethernet cable is seated "
            "at both ends."
        ),
        "doc": "DIAGNOSIS-RULES.md#n1--no-network-at-all",
        "impacts": {"calls": "broken", "streaming": "broken", "gaming": "broken",
                    "vpn": "broken", "browsing": "broken"},
        "fix": (
            "Turn WiFi on and pick a network, or check that the ethernet "
            "cable is seated at both ends. Nothing else can be diagnosed "
            "until basic connectivity exists."
        ),
        "fix_target": "you",
    },
    {
        "id": "N1b",
        "title": "Internet unreachable (focused run)",
        "category": "internet",
        "severity": "critical",
        "scope": "scan",
        "blurb": (
            "A focused run (like an MTU-only check) skips the full gateway "
            "test, so this rule catches an outage that would otherwise "
            "slip through unreported: your Mac has a router, but nothing "
            "on the public internet answered. Re-run a full scan to find "
            "out whether the problem is the router, the ISP, or DNS."
        ),
        "doc": "DIAGNOSIS-RULES.md#n1b--router-present-nothing-public-responds",
        "impacts": {"calls": "broken", "streaming": "broken", "gaming": "broken",
                    "vpn": "broken", "browsing": "broken"},
        "fix": (
            "Re-run netdiag as a full scan instead of a focused one — it "
            "will show whether the fault is your router, your ISP, or DNS."
        ),
        "fix_target": "you",
    },
    {
        "id": "N1c",
        "title": "Joined to a network with no route out",
        "category": "router",
        "severity": "critical",
        "scope": "scan",
        "blurb": (
            "Your Mac is associated and holds an address from this "
            "network, but the network has given it no route to the "
            "internet. Hotel, airport, café and office WiFi usually "
            "withhold one until you open a browser and pass a sign-in or "
            "terms page. Failing that, the network handed out an address "
            "without a working route, which only its owner can fix."
        ),
        "doc": "DIAGNOSIS-RULES.md#n1c--joined-with-no-route-out",
        "impacts": {"calls": "broken", "streaming": "broken", "gaming": "broken",
                    "vpn": "broken", "browsing": "broken"},
        "fix": (
            "Open a browser and try to load any page — most captive "
            "portals show a sign-in or terms screen the moment you do, and "
            "accepting it restores the route out. If nothing appears, the "
            "network itself has no working route, and only whoever runs "
            "it can fix that."
        ),
        "fix_target": "you",
    },
    {
        "id": "W1",
        "title": "Weak WiFi signal",
        "category": "wifi",
        "severity": "warn",
        "scope": "scan",
        "blurb": (
            "Your wireless signal is weak enough to cause retransmissions, "
            "latency spikes, and dropouts. Moving closer to the router or "
            "switching to a nearer access point or band usually helps."
        ),
        "doc": "DIAGNOSIS-RULES.md#w1--weak-wifi-signal",
        "impacts": {"calls": "degraded", "streaming": "degraded",
                    "gaming": "degraded", "vpn": "degraded"},
        "fix": (
            "Move closer to the router, or move the router away from "
            "walls, metal and other radios. If neither is possible, a "
            "mesh node or a wired connection is the durable answer."
        ),
        "fix_target": "you",
    },
    {
        "id": "W2",
        "title": "Low WiFi signal-to-noise ratio",
        "category": "wifi",
        "severity": "warn",
        "scope": "scan",
        "blurb": (
            "Interference is competing with your wireless signal. A less "
            "crowded channel or moving the router away from other radio "
            "sources can improve it."
        ),
        "doc": "DIAGNOSIS-RULES.md#w2--low-wifi-snr",
        "impacts": {"calls": "degraded", "streaming": "degraded",
                    "gaming": "degraded", "vpn": "degraded"},
        "fix": (
            "Log into the router's admin page and switch to a less "
            "crowded WiFi channel, or move the router itself away from "
            "other radios and reflective metal surfaces."
        ),
        "fix_away": (
            "Ask whoever runs this network to try a different WiFi "
            "channel — interference is stepping on the signal here. If "
            "that's not on offer, moving away from likely interference "
            "sources, or joining a 5 GHz network if one is available, "
            "often helps in the meantime."
        ),
        "fix_target": "your_router",
    },
    {
        "id": "W3",
        "title": "Associated with distant access point (sticky AP)",
        "category": "wifi",
        "severity": "info",
        "scope": "scan",
        "blurb": (
            "Your Mac is connected to a distant access point on this network "
            "while a much stronger access point is available. Reconnecting "
            "usually prompts macOS to choose the nearer one."
        ),
        "doc": "DIAGNOSIS-RULES.md#w3--associated-with-distant-access-point-sticky-ap",
        "impacts": {
            "calls": "degraded",
            "streaming": "degraded",
            "gaming": "degraded",
            "vpn": "degraded",
        },
        "fix": (
            "Toggle Wi-Fi off and back on to force macOS to associate with "
            "the closer access point."
        ),
        "fix_target": "you",
    },
    {
        "id": "W4",
        "title": "Wi-Fi transmit rate collapsed",
        "category": "wifi",
        "severity": "warn",
        "scope": "scan",
        "blurb": (
            "Your Wi-Fi signal reads strong but the negotiated transmit "
            "rate has collapsed due to interference or multipath obstacles, "
            "severely limiting throughput. Moving closer to the access "
            "point or switching bands helps restore full link speed."
        ),
        "doc": "DIAGNOSIS-RULES.md#w4--wi-fi-transmit-rate-collapsed",
        "impacts": {
            "calls": "degraded",
            "streaming": "degraded",
            "gaming": "degraded",
            "vpn": "degraded",
            "browsing": "degraded",
        },
        "fix": (
            "Move closer to your router or access point, avoid thick walls "
            "or metal obstructions, or switch to the 5 GHz or 6 GHz band."
        ),
        "fix_target": "you",
    },
    {
        "id": "W5",
        "title": "Asymmetric Wi-Fi link (return path loss)",
        "category": "wifi",
        "also": "router",
        "severity": "warn",
        "scope": "scan",
        "blurb": (
            "Your Mac hears a strong signal from the router, but the router "
            "struggles to hear your Mac through walls or interference, "
            "causing packet loss on the return path. Moving closer to the "
            "router balances transmission power."
        ),
        "doc": "DIAGNOSIS-RULES.md#w5--asymmetric-wi-fi-link-return-path-loss",
        "impacts": {
            "calls": "degraded",
            "streaming": "degraded",
            "gaming": "degraded",
            "vpn": "degraded",
            "browsing": "degraded",
        },
        "fix": (
            "Move closer to your router or place the router higher up. "
            "Wall-powered routers transmit much louder than battery-powered "
            "laptops, creating an unbalanced connection at range."
        ),
        "fix_target": "you",
    },
    {
        "id": "WS-1",
        "title": "WiFi channel is congested",
        "category": "wifi",
        "severity": "warn",
        "scope": "scan",
        "blurb": (
            "Several neighbouring networks share your current channel. "
            "That contention can make an otherwise strong connection "
            "inconsistent; a less busy channel may help."
        ),
        "doc": "DIAGNOSIS-RULES.md#ws-1--wifi-channel-is-congested",
        # `vpn` included for the same reason W1 and W2 include it: all
        # three are radio-quality rules, and channel contention produces
        # the same jitter and loss a tunnel suffers from. Omitting it here
        # while the other two carry it was an inconsistency, not a
        # judgement that a congested channel spares a VPN.
        "impacts": {"calls": "degraded", "streaming": "degraded",
                    "gaming": "degraded", "vpn": "degraded"},
        "fix": (
            "Log into the router's admin page and switch to a quieter "
            "WiFi channel, or let it choose one automatically — the "
            "congestion eases once you're not sharing a channel with "
            "several neighbours."
        ),
        "fix_away": (
            "Ask whoever runs this network to switch to a quieter WiFi "
            "channel. From a guest position there's little else to do "
            "about it; a wired connection, if one's offered, sidesteps "
            "the congestion entirely."
        ),
        "fix_target": "your_router",
    },
    {
        "id": "G1",
        "title": "Gateway packet loss with weak Wi-Fi",
        # Router first: G1 and G2 report the identical measurement — the
        # share of packets lost between the Mac and the gateway — and
        # differ only in whether a weak signal was there to explain it.
        # G2 is `router`, so G1 must be too, or the same finding tints a
        # different row depending on how well it could be explained.
        # `wifi` stays as the secondary because the radio is the named
        # cause and the Wi-Fi row should say so.
        "category": "router",
        "also": "wifi",
        "severity": "critical",
        "scope": "both",
        "blurb": (
            "Your Mac is losing packets to your router while your Wi-Fi "
            "signal is weak. The wireless link is the problem, not your "
            "router hardware or your internet provider. Moving closer to "
            "the router or switching to a closer access point clears this."
        ),
        "doc": "DIAGNOSIS-RULES.md#g1--gateway-loss--weak-wifi",
        "impacts": {"calls": "degraded", "streaming": "degraded",
                    "gaming": "degraded", "vpn": "degraded", "browsing": "degraded"},
        "fix": (
            "Move closer to the router, or switch to a closer access "
            "point if you have one — the wireless link itself is the "
            "problem here, not the router or your internet service."
        ),
        "fix_target": "you",
    },
    {
        "id": "G2",
        "title": "Router dropping packets",
        "category": "router",
        "severity": "critical",
        "scope": "both",
        "blurb": (
            "Your Mac is losing packets between your Mac and your router "
            "— the connection between your Mac and your router is "
            "severely degraded. A reboot of the router (power off, wait, "
            "then power back on) or moving closer to it clears this in "
            "most cases. On ethernet, check the cable."
        ),
        "doc": "DIAGNOSIS-RULES.md#g2--gateway-loss-with-healthy-wifi",
        "impacts": {"calls": "broken", "streaming": "degraded", "gaming": "broken",
                    "vpn": "degraded", "browsing": "degraded"},
        "fix": (
            "Reboot the router: unplug it, wait ten seconds, plug it back "
            "in. That clears this in most cases. If it comes back within a "
            "day, the router is failing and wants replacing."
        ),
        "fix_away": (
            "Ask whoever runs this network to restart the router — tell "
            "them your Mac is losing packets to it while the Wi-Fi signal "
            "is strong, which is the detail that distinguishes a bad router "
            "from a bad radio."
        ),
        "fix_target": "your_router",
    },
    {
        "id": "G3",
        "title": "Minor packet loss to router",
        "category": "router",
        "severity": "warn",
        "scope": "both",
        "blurb": (
            "A smaller share of packets to your router — the box that "
            "gives you internet in your home — are going missing. This is "
            "not your internet provider; your internet service itself "
            "looks fine from here. Not enough to break the connection "
            "outright, but enough that pages stall and calls occasionally "
            "break up. On WiFi this is usually signal or interference; on "
            "ethernet, suspect the cable or the switch port."
        ),
        "doc": "DIAGNOSIS-RULES.md#g3--gateway-loss-below-the-critical-floor",
        "impacts": {"calls": "degraded", "gaming": "degraded"},
        "fix": (
            "Move closer to the router or switch to a less crowded WiFi "
            "band if you're on wireless. On ethernet, reseat or swap the "
            "cable and check the link isn't stuck at half-duplex. If it "
            "keeps recurring on WiFi, restarting the router is worth "
            "trying too."
        ),
        "fix_target": "you",
    },
    {
        "id": "P1",
        "title": "DNS and internet both down",
        "category": "internet",
        "severity": "critical",
        "scope": "both",
        "blurb": (
            "Your local network works, but neither the wider internet nor "
            "name lookups are responding — most likely a DNS or "
            "upstream ISP outage. Try loading a raw address like "
            "http://1.1.1.1: if that works, DNS is the culprit; if not, "
            "it's the ISP."
        ),
        "doc": "DIAGNOSIS-RULES.md#p1--dns-down-public-unreachable",
        "impacts": {"calls": "broken", "streaming": "broken", "gaming": "broken",
                    "vpn": "broken", "browsing": "broken"},
        "fix": (
            "Try loading a raw address like http://1.1.1.1 in a browser. "
            "If that loads, the problem is DNS — switch to a public "
            "resolver such as Cloudflare or Google. If it doesn't, call "
            "your ISP; this points to an outage on their side."
        ),
        "fix_target": "your_isp",
    },
    {
        "id": "P2",
        "title": "Internet unreachable, DNS fine",
        "category": "internet",
        "severity": "critical",
        "scope": "both",
        "blurb": (
            "Your local network is healthy and DNS is resolving names "
            "fine, but no public site responds — this almost always "
            "means an outage on your ISP's side. Check their status page "
            "or contact support."
        ),
        "doc": "DIAGNOSIS-RULES.md#p2--public-unreachable-dns-up",
        "impacts": {"calls": "broken", "streaming": "broken", "gaming": "broken",
                    "vpn": "broken", "browsing": "broken"},
        "fix": (
            "Check your ISP's status page, or call their support line and "
            "report the outage — DNS is working fine, so the fault sits "
            "entirely on their side of the connection."
        ),
        "fix_target": "your_isp",
    },
    {
        "id": "L1",
        "title": "Severe internet packet loss",
        "category": "internet",
        "severity": "critical",
        "scope": "both",
        "blurb": (
            "A large share of the traffic sent out to the internet is "
            "being dropped, while the router itself answers cleanly — "
            "so the fault sits past your front door, on the line, the "
            "modem, or with the ISP. Expect pages that hang, calls that "
            "freeze, and downloads that stall; a modem reboot is worth "
            "trying before reporting the numbers to your ISP."
        ),
        "doc": "DIAGNOSIS-RULES.md#l1--severe-internet-side-packet-loss",
        "impacts": {"calls": "broken", "streaming": "broken", "gaming": "broken",
                    "vpn": "broken", "browsing": "degraded"},
        "fix": (
            "Reboot the modem once, if you're able to — that occasionally "
            "clears it. If the loss returns, report the figures from this "
            "report to your ISP; that's the number that gets an engineer "
            "sent out, since the router itself is answering cleanly."
        ),
        "fix_target": "your_isp",
    },
    {
        "id": "L2",
        "title": "Moderate internet packet loss",
        "category": "internet",
        "severity": "warn",
        "scope": "both",
        "blurb": (
            "Some traffic is being lost on the way out to the internet "
            "even though the router itself is clean — enough to cause "
            "an occasional stutter or stall, but not enough to break the "
            "connection outright. It's often tied to time-of-day "
            "congestion on the ISP's local segment, so it's worth "
            "re-running when it feels worst."
        ),
        "doc": "DIAGNOSIS-RULES.md#l2--moderate-internet-side-packet-loss",
        "impacts": {"calls": "degraded", "streaming": "degraded",
                    "gaming": "degraded", "vpn": "degraded", "browsing": "degraded"},
        "fix": (
            "Not severe enough to act on by itself, but if it persists, "
            "report the loss to your ISP — it's often tied to time-of-day "
            "congestion on their local segment, so re-running netdiag "
            "when it feels worst helps build the case."
        ),
        "fix_target": "your_isp",
    },
    {
        "id": "ICMP-1",
        "title": "Ping blocked, connection fine",
        "category": "internet",
        "severity": "info",
        "scope": "both",
        "blurb": (
            "Ping to the outside world fails completely, but real traffic "
            "— web pages, DNS, TCP connections — all work fine, "
            "so this isn't an outage. Some ISPs and most corporate or "
            "hotel networks block ping specifically while letting "
            "everything else through; the latency numbers just can't be "
            "measured here."
        ),
        "doc": "DIAGNOSIS-RULES.md#icmp-1--ping-filtered-upstream-real-traffic-fine",
        "fix": (
            "Nothing to do — the connection itself is fine. Ping being "
            "blocked doesn't affect real browsing, calls, or downloads, "
            "and there's no setting on your end that changes how the "
            "path in between treats it."
        ),
        "fix_target": "nobody",
    },
    {
        "id": "D1",
        "title": "DNS resolver flaky",
        "category": "dns",
        "severity": "warn",
        "scope": "both",
        "blurb": (
            "The internet itself is reachable, but some name lookups are "
            "failing, which points at a flaky DNS resolver. Switching to "
            "a public resolver such as Cloudflare's or Google's in your "
            "network settings usually clears it up."
        ),
        "doc": "DIAGNOSIS-RULES.md#d1--partial-dns-internet-reachable",
        "impacts": {"calls": "degraded", "streaming": "degraded", "browsing": "degraded"},
        "fix": (
            "Switch to a public DNS resolver such as Cloudflare or Google "
            "in System Settings → Network → Details → DNS — that usually "
            "clears the flakiness immediately."
        ),
        "fix_target": "you",
    },
    {
        "id": "D2",
        "title": "No name lookups working at all",
        "category": "dns",
        "severity": "warn",
        "scope": "scan",
        "blurb": (
            "Every DNS server your Mac tried failed to answer, and the "
            "wider internet is unreachable too — so this is most likely a "
            "symptom of the connection being down rather than a DNS fault "
            "in its own right. Fix the connection first. If lookups still "
            "fail once it is back, switch your DNS to Cloudflare or "
            "Google in System Settings."
        ),
        "doc": "DIAGNOSIS-RULES.md#d2--no-name-lookups-working-at-all",
        "impacts": {"calls": "broken", "streaming": "broken", "gaming": "broken",
                    "vpn": "broken", "browsing": "broken"},
        "fix": (
            "Fix the connection first — DNS failing alongside everything "
            "else is usually a symptom of that, not a fault of its own. "
            "If lookups still fail once the connection is back, switch to "
            "a public resolver such as Cloudflare or Google in System "
            "Settings → Network → Details → DNS."
        ),
        "fix_target": "you",
    },
    {
        "id": "D3",
        "title": "DNS server sluggish",
        "category": "dns",
        "severity": "warn",
        "scope": "scan",
        "blurb": (
            "Your configured DNS server takes a long time to answer "
            "name lookups, so every new website or link you click pauses "
            "before it begins loading. Switching to a fast public resolver "
            "like Cloudflare's or Google's in your network settings clears "
            "the delay."
        ),
        "doc": "DIAGNOSIS-RULES.md#d3--slow-dns-resolver-latency",
        "impacts": {"calls": "degraded", "streaming": "degraded", "browsing": "degraded"},
        "fix": (
            "Switch to a public resolver such as Cloudflare or Google in "
            "System Settings → Network → Details → DNS — it's usually "
            "noticeably faster than an ISP's default."
        ),
        "fix_target": "you",
    },
    {
        "id": "D4",
        "title": "DNS searches intercepted",
        "category": "dns",
        "severity": "warn",
        "scope": "scan",
        "blurb": (
            "Your DNS server intercepts mistyped website addresses and "
            "redirects them to an advertising or search portal rather than "
            "reporting that the address does not exist. Switching to a "
            "standard public resolver or enabling Encrypted DNS stops "
            "the redirection."
        ),
        "doc": "DIAGNOSIS-RULES.md#d4--dns-hijacking-and-search-redirection",
        "impacts": {"vpn": "degraded", "browsing": "degraded"},
        "fix": (
            "Switch to a public resolver such as Cloudflare or Google, or "
            "turn on Encrypted DNS (DNS-over-HTTPS), in System Settings → "
            "Network → Details → DNS to stop the redirection."
        ),
        "fix_target": "you",
    },
    {
        "id": "EDNS-1",
        "title": "Encrypted DNS profile active",
        "category": "dns",
        "severity": "info",
        "scope": "scan",
        "blurb": (
            "An encrypted DNS profile is installed on this Mac, sending "
            "DNS queries over an encrypted channel rather than unencrypted "
            "UDP. Standard DNS tests in this report were measured against "
            "local and public unencrypted resolvers for diagnostic "
            "baseline comparison, and may not reflect the resolver your "
            "applications actually use."
        ),
        "doc": "DIAGNOSIS-RULES.md#edns-1--encrypted-dns-profile-active",
        "fix": (
            "Nothing to fix — this profile is configured to protect your "
            "DNS privacy. If name resolution fails while this report looks "
            "clean, inspect your profile in System Settings → Privacy & "
            "Security → Profiles."
        ),
        "fix_target": "nobody",
    },
    {
        "id": "B1",
        "title": "Bufferbloat at the router",
        "category": "load",
        "severity": "varies",
        "scope": "scan",
        "blurb": (
            "Your router gets sluggish whenever something is downloading "
            "or uploading heavily, adding noticeable extra delay that "
            "makes calls and games feel laggy or worse. Enabling Smart "
            "Queue Management (SQM) or QoS in the router's admin page "
            "— or replacing it with one that supports it — fixes "
            "the underlying queueing problem."
        ),
        "doc": "DIAGNOSIS-RULES.md#b1--bufferbloat-at-gateway-hop",
        # Load-conditional, so not `broken`. Bufferbloat only bites while
        # the link is saturated — this rule's own summary says calls will
        # glitch "whenever someone's downloading or uploading", and on an
        # idle link the same call is fine. That is the flapping case in a
        # different costume: a fault that comes and goes cannot claim an
        # activity "won't hold up", which a reader takes as a statement
        # about right now.
        "impacts": {"calls": "degraded", "streaming": "degraded",
                    "gaming": "degraded", "vpn": "degraded"},
        "fix": (
            "Turn on Smart Queue Management (SQM) or QoS in the router's "
            "admin page — that fixes the underlying queueing problem "
            "directly. If the router doesn't support it, replacing it "
            "with one that does is the durable fix."
        ),
        "fix_away": (
            "Ask whoever runs this network whether their router supports "
            "Smart Queue Management or QoS, and to enable it. From a "
            "guest position there's little else to do beyond avoiding "
            "heavy uploads or downloads while on a call or in a game."
        ),
        "fix_target": "your_router",
    },
    {
        "id": "B2",
        "title": "Bufferbloat at the ISP",
        "category": "load",
        "severity": "varies",
        "scope": "scan",
        "blurb": (
            "The slowdown under heavy use traces to your ISP's own "
            "equipment rather than your router, adding extra delay under "
            "load that can hurt calls and games. A modem firmware update "
            "can help if you control it; otherwise it's the ISP's "
            "responsibility to fix."
        ),
        "doc": "DIAGNOSIS-RULES.md#b2--bufferbloat-at-isp-hop-only",
        # Load-conditional, so not `broken`. Bufferbloat only bites while
        # the link is saturated — this rule's own summary says calls will
        # glitch "whenever someone's downloading or uploading", and on an
        # idle link the same call is fine. That is the flapping case in a
        # different costume: a fault that comes and goes cannot claim an
        # activity "won't hold up", which a reader takes as a statement
        # about right now.
        "impacts": {"calls": "degraded", "streaming": "degraded",
                    "gaming": "degraded", "vpn": "degraded"},
        "fix": (
            "Call the ISP and ask about firmware updates for their "
            "equipment, or a plan with better latency under load. Quote "
            "the bufferbloat grade from this report — it is the figure "
            "that gets the conversation past the first line of support."
        ),
        "fix_target": "your_isp",
    },
    {
        "id": "M1",
        "title": "Path MTU too small",
        "category": "mtu",
        "severity": "varies",
        "scope": "scan",
        "blurb": (
            "Your network is silently dropping packets above a certain "
            "size, so some websites hang while others load fine — a "
            "classic symptom of an unconfigured VPN, PPPoE, or tunnelled "
            "link. Disconnecting any VPN often clears it; otherwise check "
            "the router's WAN MTU or MSS-clamping setting."
        ),
        "doc": "DIAGNOSIS-RULES.md#m1--path-mtu-below-1500",
        "impacts": {"vpn": "broken", "browsing": "degraded"},
        "fix": (
            "Disconnect any VPN and try again — a misconfigured tunnel is "
            "the most common cause. If the problem persists without one, "
            "the router's WAN MTU or MSS-clamping setting needs "
            "adjusting, which is worth raising with whoever manages it."
        ),
        "fix_target": "you",
    },
    {
        "id": "MT1",
        "title": "First lossy hop found",
        "category": "internet",
        "severity": "warn",
        "scope": "scan",
        "blurb": (
            "One specific hop on the way to the internet is where packet "
            "loss actually starts; hops after it usually just inherit the "
            "problem rather than adding their own. Whoever owns that hop "
            "— your router, your ISP, or a transit network further "
            "along — is the one to investigate."
        ),
        "doc": "DIAGNOSIS-RULES.md#mt1--first-lossy-hop-identified",
        "impacts": {"calls": "degraded", "streaming": "degraded",
                    "gaming": "degraded", "vpn": "degraded"},
        "fix": (
            "If the lossy hop turns out to be your own router, a reboot "
            "is worth trying first. Otherwise, report it to your ISP "
            "along with the hop and the loss figure from this report — a "
            "transit hop beyond your gateway is their responsibility to "
            "chase, and naming the exact hop is what gets it escalated "
            "past the first line of support."
        ),
        "fix_target": "your_isp",
    },
    {
        "id": "V6-1",
        "title": "IPv6 partially broken",
        "category": "ipv6",
        "severity": "warn",
        "scope": "scan",
        "blurb": (
            "Your network has a half-working IPv6 setup: big sites feel "
            "sluggish for the first moment of every page load because "
            "your Mac tries the modern path first, waits for it to fail, "
            "then falls back to the old one. Rebooting the router often "
            "fixes it; if it persists, ask your ISP whether IPv6 is "
            "actually provisioned."
        ),
        "doc": "DIAGNOSIS-RULES.md#v6-1--ipv6-broken-while-ipv4-works",
        "impacts": {"streaming": "degraded", "browsing": "degraded"},
        "fix": (
            "Reboot the router — that clears many half-working IPv6 "
            "setups on its own. If it keeps happening, ask your ISP "
            "whether IPv6 is actually provisioned on your line."
        ),
        "fix_away": (
            "Ask whoever runs this network to restart the router; a "
            "stuck IPv6 setup is often just a router that needs a fresh "
            "start. If that's not on offer, the brief pause on every "
            "page load is safe to live with — nothing on your end needs "
            "changing."
        ),
        "fix_target": "your_router",
    },
    {
        "id": "V6-2",
        "title": "IPv6 DNS resolver unresponsive",
        "category": "ipv6",
        "severity": "warn",
        "scope": "scan",
        "blurb": (
            "Your router provided an IPv6 DNS server address that is not "
            "responding. Websites pause for several seconds before opening "
            "while your Mac waits for the IPv6 lookup to time out before "
            "falling back to IPv4."
        ),
        "doc": "DIAGNOSIS-RULES.md#v6-2--unresponsive-ipv6-dns-resolver",
        "impacts": {"streaming": "degraded", "browsing": "degraded"},
        "fix": (
            "In System Settings → Network → [WiFi/Ethernet] → Details → "
            "TCP/IP, set Configure IPv6 to Link-local Only to stop your "
            "Mac waiting on a broken resolver. Updating the router's "
            "IPv6 DNS settings is the other fix, if you control it."
        ),
        "fix_target": "you",
    },
    {
        "id": "V6-3",
        "title": "This network is IPv6-only, and that is fine",
        "category": "ipv6",
        "severity": "info",
        "scope": "scan",
        "blurb": (
            "This network runs on the modern internet protocol only — "
            "there is no old-style address here, and that is by design "
            "rather than a fault. Normal on some mobile networks, "
            "universities and newer corporate networks. Your Mac "
            "translates automatically so older apps keep working. If a "
            "specific app misbehaves it is likely one that has not been "
            "updated for this kind of network; nothing on your end "
            "needs fixing."
        ),
        "doc": "DIAGNOSIS-RULES.md#v6-3--the-network-is-ipv6-only-by-design",
        "fix": (
            "Nothing to fix — this is a deliberate network design, not a "
            "fault, and your Mac already handles it automatically. If one "
            "particular app misbehaves here, that app is the one that "
            "needs updating, not your network settings."
        ),
        "fix_target": "nobody",
    },
    {
        "id": "VPN-1",
        "title": "VPN carrying your traffic",
        "category": "vpn",
        "severity": "info",
        "scope": "both",
        "blurb": (
            "A VPN is currently carrying your traffic, so everything else "
            "measured in the report — the \"router,\" latency, "
            "traceroute, speed — actually describes the tunnel and "
            "its exit server, not your real network. If something looks "
            "slow, the VPN is as likely a cause as your ISP; disconnect "
            "it and run again for a picture of the underlying connection."
        ),
        "doc": "DIAGNOSIS-RULES.md#vpn-1--vpn-is-carrying-the-default-route",
        "fix": (
            "Nothing to fix — a VPN carrying your traffic is expected, "
            "not a problem. If something in this report looks slow, "
            "disconnecting the VPN and running netdiag again will show "
            "whether the tunnel or the network underneath it is "
            "responsible."
        ),
        "fix_target": "nobody",
    },
    {
        "id": "TCP-1",
        "title": "ICMP blocked, TCP fine",
        "category": "router",
        "severity": "info",
        "scope": "both",
        "blurb": (
            "Real connections work fine — only the ping-style tests "
            "are failing, because something on the path is blocking ICMP "
            "specifically while letting actual traffic through. Common on "
            "hotel WiFi, corporate networks, and some ISPs; the network "
            "is up, and the ping-based loss this check reports can be "
            "ignored."
        ),
        "doc": "DIAGNOSIS-RULES.md#tcp-1--tcp-works-icmp-is-filtered",
        "fix": (
            "Nothing to fix — this is a filtering choice somewhere on "
            "the path, not a fault. Real connections work fine, so the "
            "ping-based loss number this check reports can be safely "
            "ignored."
        ),
        "fix_target": "nobody",
    },

    {
        "id": "WD-1",
        "title": "WiFi flapping / roaming",
        "category": "wifi",
        "severity": "warn",
        "scope": "scan",
        "blurb": (
            "Your WiFi keeps dropping and reconnecting more than "
            "expected. Common causes are weak signal at your desk, a Mac "
            "bouncing between two overlapping access points, or a router "
            "firmware bug — worth checking whether multiple access "
            "points are actually set up as a proper mesh."
        ),
        "doc": "DIAGNOSIS-RULES.md#wd-1--wifi-link-is-flapping",
        "impacts": {"calls": "degraded", "streaming": "degraded",
                    "gaming": "degraded", "vpn": "degraded"},
        "fix": (
            "Move closer to the access point if you can, and if there's "
            "more than one, check they're set up as a proper mesh in the "
            "router's admin page rather than as separate, overlapping "
            "networks. A router firmware update can also settle a "
            "stubborn case."
        ),
        "fix_away": (
            "Ask whoever runs this network whether their access points "
            "are set up as a proper mesh, or whether a firmware update "
            "is overdue — moving closer to the nearest one is something "
            "you can still try yourself in the meantime."
        ),
        "fix_target": "your_router",
    },
    {
        "id": "WI-1",
        "title": "macOS is withholding the network's name",
        "category": "wifi",
        "severity": "info",
        "scope": "scan",
        "blurb": (
            "macOS isn't telling netdiag which WiFi network you're on, "
            "so this check is labelled with a generic name instead of "
            "the real one. Nothing is broken, and checks are still "
            "grouped by your router's hardware address rather than by "
            "its name, so nothing is mis-filed — but every unnamed "
            "network looks alike in a list. Granting Location Services "
            "to whatever runs netdiag fixes the name for future checks, "
            "and an app that can already see the name can hand it over "
            "instead."
        ),
        "doc": "DIAGNOSIS-RULES.md#wi-1--macos-is-withholding-the-networks-name",
        "fix": (
            "Grant Location Services access to whatever runs netdiag, in "
            "System Settings → Privacy & Security → Location Services — "
            "that's what lets macOS hand over the real network name on "
            "future checks."
        ),
        "fix_target": "you",
    },
    {
        "id": "DQ-1",
        "title": "This check measured two networks, not one",
        "category": "baseline",
        "severity": "info",
        "scope": "scan",
        "blurb": (
            "Your Mac changed networks while this check was running, so "
            "these numbers describe the switch rather than any one "
            "network — latency, speed and signal were measured on "
            "different connections and cannot be compared with each "
            "other. The run has been left out of the history for both "
            "networks rather than filed under the wrong one. Re-run "
            "once you have settled on a connection."
        ),
        "doc": "DIAGNOSIS-RULES.md#dq-1--the-run-measured-two-networks",
        "fix": (
            "Nothing to fix — re-run once you've settled on one "
            "connection, and the new run will describe just that "
            "network."
        ),
        "fix_target": "nobody",
    },
    {
        "id": "VPN-2",
        "title": "A VPN is carrying part of your traffic",
        "category": "vpn",
        "severity": "info",
        "scope": "scan",
        "blurb": (
            "A VPN tunnel carries some destinations while everything "
            "else goes direct — the normal shape of a work VPN. It "
            "matters because everything in this report was measured on "
            "the direct path: if the sites that feel broken are the "
            "ones behind the VPN, nothing here describes them, and the "
            "tunnel is the place to look."
        ),
        "doc": "DIAGNOSIS-RULES.md#vpn-2--a-split-tunnel-carries-part-of-your-traffic",
        "fix": (
            "Nothing to fix — this is how a split-tunnel VPN is meant to "
            "work. If a site that feels broken is one that goes through "
            "the tunnel, look there instead of at this report, since "
            "everything here was measured on the direct path."
        ),
        "fix_target": "nobody",
    },
    {
        "id": "PX-1",
        "title": "Traffic is configured to go through a proxy",
        "category": "topology",
        "severity": "info",
        "scope": "scan",
        "blurb": (
            "This connection sends traffic through a proxy, and "
            "netdiag's own tests connect directly — so the results "
            "describe the network rather than the path your browser and "
            "apps actually take. If pages fail while this report looks "
            "clean, the proxy, or the rules deciding what goes through "
            "it, is the more likely cause."
        ),
        "doc": "DIAGNOSIS-RULES.md#px-1--a-proxy-or-pac-file-is-configured",
        "impacts": {"calls": "degraded", "gaming": "degraded", "vpn": "degraded"},
        "fix": (
            "If you set this proxy up yourself — on your own router, or "
            "in a profile on this Mac — its rules are the place to look "
            "for the address or site that's failing before assuming the "
            "network itself is at fault."
        ),
        "fix_away": (
            "Ask whoever runs this network whether they operate a proxy "
            "and what it's configured to allow — a guest can't inspect "
            "the rules directly, and that's the more likely explanation "
            "than the connection itself."
        ),
        "fix_target": "network_operator",
    },
    {
        "id": "FW-1",
        "title": "Network filtering software is in the path",
        "category": "topology",
        "severity": "info",
        "scope": "scan",
        "blurb": (
            "Filtering software sits in the path of your traffic — "
            "normal on a managed or security-conscious Mac, and not a "
            "fault in itself. Worth knowing because it can produce "
            "exactly the symptoms this report is for: blocked "
            "connections, stalls, failures on some sites and not "
            "others, none of which would show up as a network problem."
        ),
        "doc": "DIAGNOSIS-RULES.md#fw-1--network-filtering-software-is-in-the-path",
        "impacts": {"calls": "degraded", "gaming": "degraded", "vpn": "degraded"},
        "fix": (
            "If you installed this filtering or security software "
            "yourself, its own settings are the place to see what it's "
            "blocking and why — this is not a network fault."
        ),
        "fix_away": (
            "Ask whoever manages your Mac's security policy about it — "
            "filtering installed by an employer or school can't be "
            "changed from here, but they can tell you what it's "
            "blocking and why."
        ),
        "fix_target": "network_operator",
    },
    {
        "id": "PR-1",
        "title": "iCloud Private Relay active",
        "category": "topology",
        "severity": "info",
        "scope": "scan",
        "blurb": (
            "iCloud Private Relay is active for Safari and Mail, routing "
            "browsing requests through Apple dual-hop proxies rather than "
            "direct. netdiag's tests connect directly to measure your "
            "physical network, so web browsing takes a different path "
            "than the results shown here."
        ),
        "doc": "DIAGNOSIS-RULES.md#pr-1--icloud-private-relay-active",
        "impacts": {"calls": "degraded", "gaming": "degraded", "vpn": "degraded"},
        "fix": (
            "Nothing to fix — this is working as Apple intended to protect "
            "your privacy. If Safari feels slow while this report looks "
            "clean, inspect your iCloud Private Relay settings in System "
            "Settings → Apple Account → iCloud → Private Relay."
        ),
        "fix_target": "nobody",
    },
    {
        "id": "SP-1",
        "title": "WiFi is the speed cap, not your plan",
        "category": "speed",
        "severity": "info",
        "scope": "scan",
        "blurb": (
            "Your download speed is about as fast as this WiFi "
            "connection can physically carry, so the measured number is "
            "the ceiling of your wireless link rather than of your "
            "internet plan — a faster plan would not change it. Plug in "
            "with an ethernet cable, or move closer to the router and "
            "prefer the higher-frequency band, to see what the "
            "connection can really do."
        ),
        "doc": "DIAGNOSIS-RULES.md#sp-1--the-wireless-link-is-the-speed-cap",
        "fix": (
            "Plug in with an ethernet cable, or move closer to the "
            "router and prefer the 5 GHz or 6 GHz band, to see what the "
            "connection can really do — a faster internet plan will not "
            "raise this number on its own."
        ),
        "fix_target": "you",
    },
    {
        "id": "MET-1",
        "title": "Metered connection — data costs money here",
        "category": "topology",
        "severity": "info",
        "scope": "scan",
        "blurb": (
            "You're online through a phone or tethered device, so data "
            "here comes out of a cellular allowance. Everything else in "
            "this report describes that mobile connection rather than a "
            "home network, so advice about routers and cables does not "
            "apply — and the speed test is skipped by default, because "
            "it would spend a large part of your allowance. Pass "
            "--speed to run it anyway."
        ),
        "doc": "DIAGNOSIS-RULES.md#met-1--metered-connection",
        "fix": (
            "Nothing to fix — this is just what a cellular connection "
            "is. Pass --speed if you want the speed test to run anyway, "
            "on purpose, spending part of your allowance."
        ),
        "fix_target": "nobody",
    },
    {
        "id": "NT-1",
        "title": "System clock drifted",
        "category": "clock",
        "severity": "varies",
        "scope": "scan",
        "blurb": (
            "Your Mac's clock has drifted noticeably from real time, and "
            "since secure websites validate certificates against the "
            "system clock, that starts breaking HTTPS connections. "
            "Turning on \"Set date and time automatically\" in System "
            "Settings usually fixes it."
        ),
        "doc": "DIAGNOSIS-RULES.md#nt-1--system-clock-drift--30-s",
        "fix": (
            "Open System Settings → General → Date & Time and turn on "
            "\"Set date and time automatically\" — that keeps the clock "
            "synced going forward, which secure sites need to validate "
            "their certificates."
        ),
        "fix_target": "you",
    },
    {
        "id": "DI-1",
        "title": "Router unreachable at layer 2",
        "category": "lan",
        "severity": "critical",
        "scope": "scan",
        "blurb": (
            "Your Mac can't resolve your router at the hardware (ARP) "
            "layer at all — the connection between them is broken below "
            "IP, so nothing else in this report matters until it's "
            "fixed. Usually a loose cable, a WiFi link that's actually "
            "down, or a bad switch port; check the physical connection "
            "first."
        ),
        "doc": "DIAGNOSIS-RULES.md#di-1--router-unreachable-at-the-hardware-arp-layer",
        "impacts": {"calls": "broken", "streaming": "broken", "gaming": "broken",
                    "vpn": "broken", "browsing": "broken"},
        "fix": (
            "Check the physical connection first: reseat the ethernet "
            "cable at both ends, confirm you're actually joined to "
            "WiFi rather than showing a stale connection, and make "
            "sure the right network is chosen as your active one. "
            "Nothing else here can be trusted until your Mac can reach "
            "the router at all."
        ),
        "fix_target": "you",
    },
    {
        "id": "DI-2",
        "title": "Duplicate IP on the LAN",
        "category": "lan",
        "severity": "critical",
        "scope": "scan",
        "blurb": (
            "Two devices on your network are using the same IP address "
            "and will intermittently steal each other's traffic. This is "
            "usually a manually-set static IP colliding with the "
            "router's DHCP pool, or a second DHCP server on the network "
            "— find and renumber one of the offending devices."
        ),
        "doc": "DIAGNOSIS-RULES.md#di-2--duplicate-ip-on-the-lan",
        "impacts": {"calls": "broken", "streaming": "broken", "gaming": "broken",
                    "vpn": "broken", "browsing": "broken"},
        "fix": (
            "Track down the device using a static IP that collides "
            "with the router's DHCP range — usually something manually "
            "configured — and give it a different address, or check "
            "the router for a second DHCP server on the network."
        ),
        "fix_away": (
            "Ask whoever runs this network to check for a duplicate IP "
            "or a second DHCP server — you have no way to see or "
            "change other devices on a network that isn't yours."
        ),
        "fix_target": "your_router",
    },
    {
        "id": "LAN-1",
        "title": "High active device count on local network",
        "category": "lan",
        "severity": "info",
        "scope": "scan",
        "blurb": (
            "Many active devices were detected on your local network "
            "segment. High device density can cause local wireless channel "
            "contention or switch queueing, explaining sudden bufferbloat "
            "or throughput drops without an internet-side outage."
        ),
        "doc": "DIAGNOSIS-RULES.md#lan-1--high-active-device-count-on-local-network",
        "fix": (
            "Check for high-bandwidth local transfers, backups, or "
            "streaming devices on your network. Consider moving "
            "high-traffic devices to wired ethernet or a dedicated "
            "wireless band to reduce channel contention."
        ),
        "fix_target": "you",
    },
    {
        "id": "ETH-1",
        "title": "Ethernet link slower than the port allows",
        "category": "lan",
        "severity": "warn",
        "scope": "scan",
        "blurb": (
            "Your ethernet connection negotiated a slower speed than the "
            "port is capable of, so no speed test can exceed that "
            "ceiling however fast your internet plan is. A damaged or "
            "low-grade cable is the usual cause — a broken pair drops a "
            "gigabit link to a hundred — followed by a cheap dock or hub "
            "in the path. Try a different cable, and plug straight into "
            "the router if you can."
        ),
        "doc": "DIAGNOSIS-RULES.md#eth-1--ethernet-negotiated-below-the-ports-capability",
        "fix": (
            "Try a different, better-quality ethernet cable, and remove "
            "any dock or hub between your Mac and the router if you "
            "can — a damaged cable or cheap adapter is the usual reason "
            "a link settles below what the port can actually do."
        ),
        "fix_target": "you",
    },
    {
        "id": "ETH-2",
        "title": "Ethernet link stuck on half duplex",
        "category": "lan",
        "severity": "critical",
        "scope": "scan",
        "blurb": (
            "Your ethernet connection can only send or receive at any "
            "one moment, not both, even though the port supports doing "
            "both at once. That causes collisions and heavy packet loss "
            "and looks exactly like a failing router. It is a failed "
            "negotiation, usually because one end is pinned to a fixed "
            "speed instead of automatic."
        ),
        # Collisions and heavy loss, which is why this is graded the same
        # as a router dropping packets rather than as a slow link. ETH-1
        # deliberately carries no impacts by contrast: a link negotiated
        # below the port's ceiling is a cap, not a fault, and 100 Mb is
        # ample for everything in this table — the same reason SP-1
        # ("WiFi is the speed cap") carries none either.
        "impacts": {"calls": "broken", "streaming": "degraded",
                    "gaming": "broken", "vpn": "degraded",
                    "browsing": "degraded"},
        "doc": "DIAGNOSIS-RULES.md#eth-2--ethernet-stuck-on-half-duplex",
        "fix": (
            "Check the port your Mac plugs into — on the router or a "
            "switch — and set it back to automatic negotiation instead "
            "of a fixed speed; that mismatch is almost always what "
            "forces half duplex. Swap the cable too if that alone "
            "doesn't clear it."
        ),
        "fix_away": (
            "Ask whoever runs this network to check the port your Mac "
            "plugs into and set it back to automatic negotiation — a "
            "fixed-speed port on their end is what's forcing this, and "
            "it isn't something you can change from your Mac."
        ),
        "fix_target": "your_router",
    },
    {
        "id": "DH-1",
        "title": "DHCP lease expiring soon",
        "category": "dhcp",
        "severity": "warn",
        "scope": "scan",
        "blurb": (
            "Your Mac's DHCP lease from the router is due to renew "
            "shortly. Renewal normally happens automatically, but if the "
            "router is rebooting or has run out of addresses at that "
            "moment, the network can drop without warning — worth "
            "keeping an eye on."
        ),
        "doc": "DIAGNOSIS-RULES.md#dh-1--dhcp-lease-expires-within-1-hour",
        "fix": (
            "Nothing to do — this normally renews on its own. If the "
            "network happens to drop right as it renews, that's the "
            "connection to look at, not something to change now."
        ),
        "fix_target": "nobody",
    },
    {
        "id": "DH-3",
        "title": "No address handed out — Mac assigned its own",
        "category": "dhcp",
        "severity": "critical",
        "scope": "scan",
        "blurb": (
            "Your Mac is joined to this network but the network never "
            "gave it an address, so it assigned itself a placeholder one "
            "that cannot reach anything. Usually the router's address "
            "service is down, out of addresses, or still starting up "
            "after a reboot. Rejoining the network makes your Mac ask "
            "again; failing that, restart the router."
        ),
        "doc": "DIAGNOSIS-RULES.md#dh-3--self-assigned-address-dhcp-never-answered",
        "impacts": {"calls": "broken", "streaming": "broken", "gaming": "broken",
                    "vpn": "broken", "browsing": "broken"},
        "fix": (
            "Try rejoining the network first — forgetting and rejoining "
            "WiFi, or unplugging and replugging an ethernet cable — "
            "which makes your Mac ask again. If that doesn't get an "
            "address, restart the router: its address service is very "
            "likely down, out of addresses, or still starting up."
        ),
        "fix_away": (
            "Try rejoining the network yourself first — forgetting and "
            "rejoining WiFi, or replugging the cable — since that alone "
            "sometimes gets an address. If it still doesn't, ask "
            "whoever runs this network to restart the router or check "
            "that it hasn't run out of addresses."
        ),
        "fix_target": "your_router",
    },
    {
        "id": "DH-2",
        "title": "DHCP DNS overridden",
        "category": "dhcp",
        "severity": "info",
        "scope": "scan",
        "blurb": (
            "The DNS servers your router handed out over DHCP don't "
            "match what your Mac is actually using — someone (or "
            "some app) manually overrode the resolver. Fine if that was "
            "intentional, such as pointing at a public resolver; worth a "
            "second look if it wasn't."
        ),
        "doc": "DIAGNOSIS-RULES.md#dh-2--dhcp-handed-dns-differs-from-system-resolver",
        "impacts": {"vpn": "degraded", "browsing": "degraded"},
        "fix": (
            "Check for a manually entered DNS server in System Settings "
            "→ Network → [your connection] → Details → DNS — clear it "
            "if you didn't set it on purpose, to go back to what the "
            "router recommends."
        ),
        "fix_target": "you",
    },
    {
        "id": "WAN-1",
        "title": "Multiple ISPs load-balanced",
        "category": "topology",
        "severity": "warn",
        "scope": "scan",
        "blurb": (
            "Outgoing connections from your Mac are landing on more than "
            "one internet provider, which is usually an intentional "
            "multi-WAN router setup. It explains some odd symptoms, like "
            "a service complaining your IP keeps changing or an app "
            "behaving inconsistently between connections."
        ),
        "doc": "DIAGNOSIS-RULES.md#wan-1--outbound-traffic-load-balanced-across-multiple-isps",
        "fix": (
            "Nothing to fix — this is normal for a multi-WAN router "
            "balancing traffic across more than one provider on "
            "purpose. It explains why a service might see your address "
            "change, or an app behave differently between connections."
        ),
        "fix_target": "nobody",
    },
    {
        "id": "WAN-1b",
        "title": "CGNAT IP rotation",
        "category": "topology",
        "severity": "info",
        "scope": "scan",
        "blurb": (
            "You're behind your ISP's shared-address pool: the same "
            "provider is handing your traffic different public IP "
            "addresses over time. Common on cellular and budget "
            "connections and not something you can fix locally, but it "
            "explains why a service might complain that your IP keeps "
            "changing."
        ),
        "doc": "DIAGNOSIS-RULES.md#wan-1b--same-isp-multiple-public-ips-cgnat-round-robin",
        "fix": (
            "Nothing to fix locally — this is how your provider's "
            "shared-address pool works, common on cellular and budget "
            "connections. It explains why a service might complain "
            "that your address keeps changing."
        ),
        "fix_target": "nobody",
    },
    {
        "id": "NAT-1",
        "title": "Double-NAT chain",
        "category": "topology",
        "severity": "warn",
        "scope": "scan",
        "blurb": (
            "More than one router in your home is chained together, each "
            "doing its own network address translation. That breaks "
            "anything that needs an incoming connection to reach a "
            "specific device — games, Plex, Steam in-home streaming, "
            "video doorbells — because the connection gets lost "
            "between the routers. Putting the outer router into bridge "
            "or access-point mode usually fixes it."
        ),
        "doc": "DIAGNOSIS-RULES.md#nat-1--double-nat-detected",
        # Not "broken". Double NAT breaks *inbound* connections — port
        # forwarding, UPnP, hosting — and modern multiplayer runs outbound
        # to matchmaking servers, so it plays. What you get is Strict /
        # Type-3 NAT: slower matchmaking, cannot host, some peers
        # unreachable, party chat flaky. The rule's own prose says it
        # "breaks games", which is loose — the things it truly breaks are
        # the port-forwarding-dependent ones (Plex, Steam in-home
        # streaming, doorbells) and those have no row here.
        "impacts": {"gaming": "degraded", "vpn": "degraded"},
        "fix": (
            "Log into the outer router's admin page and switch it to "
            "\"bridge mode\" or \"access point mode\" so the inner "
            "router handles the network alone — that stops incoming "
            "connections for games, Plex, video doorbells and similar "
            "from getting lost between the two routers."
        ),
        "fix_away": (
            "Ask whoever runs this network whether the outer router "
            "can be switched to bridge or access-point mode — you "
            "won't have admin access to it yourself, but the same fix "
            "applies at their end."
        ),
        "fix_target": "your_router",
    },
    {
        "id": "NAT-1b",
        "title": "ISP-side private routing",
        "category": "topology",
        "severity": "info",
        "scope": "scan",
        "blurb": (
            "Your ISP routes your traffic through their own internal "
            "private network before it reaches the public internet — "
            "a normal part of their infrastructure, not a fault on your "
            "end. It's surfaced because it explains why a traceroute "
            "shows private-network addresses partway along the path."
        ),
        "doc": "DIAGNOSIS-RULES.md#nat-1b--isp-side-private-transit-not-your-double-nat",
        # Same reasoning as NAT-1: inbound reach is what suffers, and a
        # game that connects outbound still plays.
        "impacts": {"gaming": "degraded", "vpn": "degraded"},
        "fix": (
            "Nothing to fix — this is normal for how your ISP built "
            "their own network, not a fault. It only explains why a "
            "traceroute shows private-network addresses partway along "
            "the path; those are your ISP's own infrastructure, not a "
            "misconfigured router of yours."
        ),
        "fix_target": "nobody",
    },
    {
        "id": "BL-1",
        "title": "Metric regressed vs. history",
        "category": "baseline",
        "severity": "warn",
        "scope": "scan",
        "blurb": (
            "One or more measurements from this run are noticeably worse "
            "than what's typical for this specific network, based on its "
            "own recent history. An absolute threshold can miss this kind "
            "of regression when the number still looks fine in isolation. "
            "For some of these metrics the current reading also has to be "
            "bad enough on its own to matter, not merely a large multiple "
            "of an already-tiny typical value, so an imperceptible blip "
            "never raises this by itself. Which metric moved, and by how "
            "much, is named in the diagnosis text."
        ),
        "doc": "DIAGNOSIS-RULES.md#bl-1--a-metric-regressed-against-this-networks-own-history",
        "fix": (
            "Look at which measurement moved and by how much — it's "
            "named in the diagnosis text — and treat that as the thing "
            "to act on. A regression on its own has no separate fix; "
            "whatever specific reading is named is the real target."
        ),
        "fix_target": "you",
    },
    {
        "id": "CP-1",
        "title": "Captive portal blocking access",
        "category": "internet",
        "severity": "varies",
        "scope": "both",
        "blurb": (
            "The check for internet access came back intercepted rather "
            "than answered, which is the signature of a captive portal — "
            "the login or terms page hotel, airport, and coffee-shop WiFi "
            "often require before real internet access works. Open a "
            "browser and complete the portal; nothing else will work "
            "until it's accepted. Critical when nothing is getting "
            "through, a warning when traffic still flows and the portal "
            "is only waiting to cut it off."
        ),
        "doc": "DIAGNOSIS-RULES.md#cp-1--captive-portal-blocking-real-access",
        "impacts": {"calls": "broken", "streaming": "broken", "gaming": "broken",
                    "vpn": "broken", "browsing": "broken"},
        "fix": (
            "Open a browser and load any plain address — the network's "
            "sign-in or terms page should appear. Nothing else will "
            "work until it's accepted, and this applies wherever the "
            "network is."
        ),
        "fix_target": "you",
    },
    {
        "id": "ND-1",
        "title": "Background watcher installed but not running",
        "category": "netdiag",
        "severity": "warn",
        "scope": "scan",
        "blurb": (
            "The launchd agent that records a check in the background is "
            "installed and is not producing runs — because it sits in a "
            "folder macOS keeps background agents out of, because launchd "
            "reports it exiting with an error, or because it has simply "
            "stopped. Nothing about the network is wrong. What is wrong "
            "is the history: the baseline every later report compares "
            "against has a hole in it for as long as this lasts, and the "
            "watcher's own log stays empty either way, which is also what "
            "a healthy idle watcher looks like."
        ),
        "doc": "DIAGNOSIS-RULES.md#nd-1--the-background-watcher-is-installed-and-not-running",
        "fix": (
            "Reinstall it: run \"netdiag --uninstall-watcher\" followed "
            "by \"netdiag --install-watcher\" — the installer now "
            "refuses to put the watcher somewhere macOS won't let it "
            "run, so a clean reinstall clears most causes."
        ),
        "fix_target": "you",
    },
    {
        "id": "AV-1",
        "title": "This connection keeps dropping",
        "category": "availability",
        "severity": "warn",
        "scope": "scan",
        "blurb": (
            "The background recorder saw this connection lose the internet "
            "more than once, or for long enough to matter, within the last "
            "day. Everything else in the report describes the connection "
            "as it is right now, which is a different question — a good "
            "reading now does not undo a bad night. The diagnosis names how "
            "many times, how long in total, and how long the worst one "
            "lasted, and the event log prints the exact times to hand to "
            "whoever runs the line."
        ),
        "doc": "DIAGNOSIS-RULES.md#av-1--this-connection-keeps-dropping",
        # All `degraded`, deliberately, even though the outages this rule
        # counts were total while they lasted. AV-1 describes what this
        # network *has been* like — the rule exists precisely because a
        # snapshot taken at a good moment reports a healthy network
        # truthfully and uselessly. Everything else in a report describes
        # the link as it is right now, and a suitability row is read as a
        # statement about now. "Video calls: won't hold up" on a link that
        # is fine at this instant, because of last night, is a claim this
        # run has not established.
        "impacts": {"calls": "degraded", "streaming": "degraded", "gaming": "degraded",
                    "vpn": "degraded", "browsing": "degraded"},
        "fix": (
            "If this keeps happening, raise it with your ISP and give "
            "them the exact times: run \"netdiag --events\" to print "
            "each drop, since dated evidence gets a technician "
            "escalated much faster than \"my internet is unreliable\"."
        ),
        "fix_target": "your_isp",
    },
    {
        "id": "AV-2",
        "title": "The connection is flapping",
        "category": "availability",
        "severity": "info",
        "scope": "scan",
        "blurb": (
            "Several of this connection's recent drops were short enough "
            "that a check run before one and after it would have found "
            "nothing wrong both times. Brief drops break calls, uploads "
            "and remote sessions while leaving every ordinary test clean, "
            "which is why they go unreported for months. Only the "
            "continuous recorder can see them at all."
        ),
        "doc": "DIAGNOSIS-RULES.md#av-2--the-connection-is-flapping",
        # A short drop does end a call and a match. But it ends *that*
        # one; the next connects. "Won't hold up" reads as "do not bother
        # trying", which is not what an intermittent fault means — and
        # this rule is `info` precisely because the link works between
        # the flaps.
        "impacts": {"calls": "degraded", "gaming": "degraded", "vpn": "degraded"},
        "fix": (
            "If these short drops are actually causing trouble — a "
            "dropped call, a failed upload — run \"netdiag --events\" "
            "to see the exact times, and raise it with your ISP if it "
            "keeps happening. A single scan will never catch this on "
            "its own, so the event log is the only record worth "
            "handing them."
        ),
        "fix_target": "your_isp",
    },
    {
        "id": "TR-1",
        "title": "Your own Mac was using the connection",
        "category": "traffic",
        "severity": "varies",
        "scope": "scan",
        "blurb": (
            "Something on this Mac — a backup, a cloud sync, a download, a "
            "video call — was moving a substantial amount of data while the "
            "check ran, and the busiest process is named in the diagnosis. "
            "Nothing is broken. It matters because every speed and latency "
            "figure in the report was measured alongside that traffic, so "
            "they describe what was left over rather than what the line can "
            "do. A warning rather than a note when a slowness or "
            "under-load verdict also fired, because then it is a competing "
            "explanation for a finding you were about to act on."
        ),
        "doc": "DIAGNOSIS-RULES.md#tr-1--your-own-mac-was-using-the-connection",
        "fix": (
            "Nothing to fix — if you want a clean reading, pause or "
            "stop whatever's transferring (a backup, a sync, a big "
            "download) and run the check again; otherwise nothing here "
            "needs acting on."
        ),
        "fix_target": "nobody",
    },
]


# One entry per jargon term the report card shows. `key` is what a GUI
# looks the entry up by — chosen to match `RunReportView`'s own row
# concepts (`router`, `internet`, `dns`, `wifi_signal`, `bufferbloat`,
# `mtu`, `speed`, `clock`) plus three terms that show up *inside* a row's
# value text rather than as a row of their own (`packet_loss`, `latency`,
# `jitter`) — "3.4 ms · 2% loss" reads as two unexplained numbers without
# them. Order is reading order for a plain listing, not meaningful to a
# lookup.
METRICS: list[dict[str, str]] = [
    {
        "key": "router",
        "label": "Router",
        "help": (
            "The box in your home that gets your other devices onto the "
            "internet — sometimes combined with your modem into one unit. "
            "A problem here means the fault is close to home, not out on "
            "the wider internet."
        ),
    },
    {
        "key": "internet",
        "label": "Internet",
        "help": (
            "The wider internet beyond your own router — your provider's "
            "network and everything past it. A problem measured here "
            "usually sits outside your home, even though your Mac is the "
            "one doing the measuring."
        ),
    },
    {
        "key": "dns",
        "label": "Name lookups (DNS)",
        "help": (
            "Every website name, like example.com, has to be translated "
            "into a numeric address before your Mac can reach it. That "
            "translation is called DNS — when it's slow or failing, sites "
            "feel like they won't even start loading."
        ),
    },
    {
        "key": "wifi_signal",
        "label": "Wi-Fi signal",
        "help": (
            "How strong the wireless connection is between your Mac and "
            "the router. A weak signal causes stalls and dropped "
            "connections even when the rest of your network is healthy."
        ),
    },
    {
        "key": "bufferbloat",
        "label": "Under load",
        "help": (
            "What happens to your connection's responsiveness while it's "
            "busy — for example, while something is uploading or "
            "downloading heavily. A router that gets sluggish under load "
            "can make a video call choppy even though your everyday speed "
            "looks fine."
        ),
    },
    {
        "key": "mtu",
        "label": "Packet size (MTU)",
        "help": (
            "The biggest chunk of data your connection can send in one "
            "piece. If it's smaller than usual, some websites and video "
            "calls can stall or fail to load."
        ),
    },
    {
        "key": "speed",
        "label": "Speed",
        "help": (
            "How fast data actually moves over your connection right now "
            "— download is data coming to you, upload is data you send "
            "out. Neither one measures your everyday latency."
        ),
    },
    {
        "key": "clock",
        "label": "Clock",
        "help": (
            "Your Mac's own sense of the current time. Secure websites "
            "check this against their own certificates, so a clock "
            "that's drifted can make secure connections fail outright."
        ),
    },
    {
        "key": "packet_loss",
        "label": "Packet loss",
        "help": (
            "Small pieces of data, called packets, that were sent but "
            "never arrived. Even a little loss causes stutters in calls "
            "and games; a lot of it makes a connection feel broken."
        ),
    },
    {
        "key": "latency",
        "label": "Latency / ping",
        "help": (
            "How long it takes a single message to make a round trip to "
            "something and back. Lower feels snappier; high latency is "
            "what makes a call feel like it's lagging behind."
        ),
    },
    {
        "key": "jitter",
        "label": "Jitter",
        "help": (
            "How much latency varies from one moment to the next. Even "
            "when the average is fine, big swings in jitter are what "
            "make a call or a game feel unpredictable and stuttery."
        ),
    },

    # ── `--history` metric keys ────────────────────────────────────────
    # One entry per key in helpers/history.py's METRICS table — the exact
    # keys `--history`'s `metric_stats` and `judged.metrics` use, not the
    # generic report-card terms above. `label` matches history's own label
    # for the key verbatim, so a GUI chart title and this glossary entry
    # never say the metric two different ways. `why_absent` is present
    # only where a chart's empty state has a knowable cause — a check mode
    # that skips the metric, or a privilege it needs — migrated from (and
    # replacing) `HistoryView.hint(for:)`'s Swift switch, rephrased
    # neutrally: no UI instructions, since the GUI supplies its own
    # button.
    {
        "key": "gateway_rtt_ms",
        "label": "Gateway RTT",
        "help": (
            "How long it takes a message to make a round trip between "
            "your Mac and your router, averaged across this check's "
            "pings. It's the fastest hop in the report, so even a small "
            "rise here is worth noticing."
        ),
    },
    {
        "key": "gateway_loss_pct",
        "label": "Gateway loss",
        "help": (
            "The share of pings to your router that never got a reply. "
            "Loss this close to home usually points at the router "
            "itself, the cable, or the wireless link, rather than "
            "anything further out on the internet."
        ),
    },
    {
        "key": "gateway_jitter_ms",
        "label": "Gateway jitter",
        "help": (
            "How much the round-trip time to your router varies from "
            "one ping to the next, over this check. Steady jitter this "
            "close to home is what makes calls and games feel choppy "
            "even when the average looks fine."
        ),
    },
    {
        "key": "inet_rtt_ms",
        "label": "Internet RTT",
        "help": (
            "How long it takes a message to reach a site out on the "
            "internet and come back, rather than just your router. It's "
            "naturally higher than the gateway figure — the gap between "
            "the two is roughly how much delay your provider and the "
            "wider internet are adding."
        ),
        "why_absent": (
            "The internet loss probe is skipped by the quick check that "
            "the background watcher runs."
        ),
    },
    {
        "key": "inet_loss_pct",
        "label": "Internet loss",
        "help": (
            "The share of pings sent out to the internet that never got "
            "a reply, measured past your router. Loss here points "
            "further from home — your provider's network or somewhere "
            "beyond it — rather than your own equipment."
        ),
        "why_absent": (
            "The internet loss probe is skipped by the quick check that "
            "the background watcher runs."
        ),
    },
    {
        "key": "wifi_rssi_dbm",
        "label": "WiFi signal",
        "help": (
            "How strong the wireless signal is where your Mac sits, "
            "measured by the radio itself. A weak reading here explains "
            "stalls and dropouts even when everything past the router "
            "looks healthy."
        ),
        "why_absent": (
            "Signal strength is only recorded by a privileged run — "
            "`sudo netdiag` in a terminal."
        ),
    },
    {
        "key": "wifi_snr_db",
        "label": "WiFi SNR",
        "help": (
            "How far your wireless signal sits above the background "
            "radio noise. A shrinking gap here means interference is "
            "crowding out the signal, even when the raw signal strength "
            "alone still looks fine."
        ),
        "why_absent": (
            "Signal strength is only recorded by a privileged run — "
            "`sudo netdiag` in a terminal."
        ),
    },
    {
        "key": "mtu_effective",
        "label": "Path MTU",
        "help": (
            "The largest chunk of data that can travel the full path to "
            "the internet without being broken up. When it drops below "
            "the usual size, some sites and services hang instead of "
            "loading normally."
        ),
        "why_absent": (
            "Path MTU is only measured by a full check — the quick "
            "check and the background watcher both skip it."
        ),
    },
    {
        "key": "bufferbloat_gw_ms",
        "label": "Bufferbloat (router)",
        "help": (
            "How much slower your router answers while your connection "
            "is busy uploading or downloading, compared with when it's "
            "idle. A router that bloats under load is what makes a call "
            "turn choppy the moment someone else starts a big download."
        ),
        "why_absent": (
            "Latency under load is only measured by a full check, and "
            "is skipped entirely while the connection is already "
            "failing."
        ),
    },
    {
        "key": "bufferbloat_inet_ms",
        "label": "Bufferbloat (ISP)",
        "help": (
            "How much slower a reply from out on the internet arrives "
            "while your connection is busy, compared with when it's "
            "idle. When this rises but the router figure doesn't, the "
            "delay is being added by your provider's equipment rather "
            "than your own."
        ),
        "why_absent": (
            "Latency under load is only measured by a full check, and "
            "is skipped entirely while the connection is already "
            "failing."
        ),
    },
    {
        "key": "speed_down_mbps",
        "label": "Download",
        "help": (
            "How fast data arrives from the internet during this "
            "check's speed test — the number that governs how quickly "
            "pages, downloads, and streams arrive."
        ),
        "why_absent": (
            "Speed is only measured by a full check, not a quick one — "
            "though netdiag also runs a full check automatically the "
            "first time you join a new network."
        ),
    },
    {
        "key": "speed_up_mbps",
        "label": "Upload",
        "help": (
            "How fast data leaves your Mac for the internet during this "
            "check's speed test — the number that matters for sending "
            "files, video calls, and backups."
        ),
        "why_absent": (
            "Speed is only measured by a full check, not a quick one — "
            "though netdiag also runs a full check automatically the "
            "first time you join a new network."
        ),
    },
    {
        "key": "ntp_drift_s",
        "label": "Clock drift",
        "help": (
            "How far your Mac's clock had wandered from true time when "
            "this check ran. A clock that drifts too far can start "
            "breaking secure connections, since those rely on the "
            "system clock matching the real time."
        ),
    },

    # ── Live monitor chart measurements ────────────────────────────────
    # Three entries for the measurement methods behind the Live tab's
    # charts (`lib/monitor.sh`, `_mon_*` fast/medium tiers) — not
    # `--history` keys, and not judged by anything. `help` is the
    # chart-subtitle prose a GUI would otherwise author itself.
    {
        "key": "monitor_gateway_rtt",
        "label": "Router round-trip",
        "help": (
            "A small ping to your router, taken every cycle of the "
            "monitor's fast tier — the quickest, most frequent reading "
            "the live view has."
        ),
    },
    {
        "key": "monitor_internet_tcp",
        "label": "Internet (TCP connect)",
        "help": (
            "Time to open a TCP connection to a well-known internet "
            "service, using the fastest of several targets. This is not "
            "a ping, so it can read differently from the ping-based "
            "internet figures shown elsewhere."
        ),
    },
    {
        "key": "monitor_gateway_loss",
        "label": "Router packet loss",
        "help": (
            "The share of recent pings to your router that got no "
            "reply, measured over a rolling window of probes rather "
            "than any single one — so one dropped ping alone will not "
            "move it much."
        ),
    },
]


_FIELDS = frozenset({"id", "title", "category", "severity", "scope", "blurb",
                     "doc", "fix", "fix_target"})
# Optional. See `also`'s note at CATEGORIES for what it means and why
# exactly one is enough, ACTIVITIES / IMPACT_LEVELS above for `impacts`, and
# FIX_TARGETS / FIX_TARGETS_NEEDING_AWAY above for `fix_away`.
_OPTIONAL_FIELDS = frozenset({"also", "impacts", "fix_away"})
_METRIC_FIELDS = frozenset({"key", "label", "help"})
# Optional, and the only optional field a metric has. Present on a metric
# whose absence has a knowable cause (a check mode that skips it, a
# privilege it needs) — see the `--history` metric entries below. A
# metric with no reliably knowable cause (it's either measured or the
# network has never been checked) omits it, same as a rule omits `also`
# when it has no secondary category.
_METRIC_OPTIONAL_FIELDS = frozenset({"why_absent"})


def _validate(rules: list[dict[str, object]]) -> None:
    """Fail loud on a malformed entry rather than ship a silent typo.

    The bats suite re-checks all of this from the emitted JSON too, so
    this exists for the case that matters more: someone runs this helper
    by hand, outside the test suite, and a bad edit to RULES should not
    reach them as a mysteriously wrong report-card tint six months later.
    """
    seen_ids: set[str] = set()
    for r in rules:
        assert set(r) - _OPTIONAL_FIELDS == _FIELDS, (
            f"entry has the wrong field set: {r}"
        )
        for k, v in r.items():
            if k == "impacts":
                continue
            assert isinstance(v, str) and v.strip(), f"{r.get('id')}.{k} is empty"
        if "impacts" in r:
            imp = r["impacts"]
            assert isinstance(imp, dict) and imp, (
                f"{r['id']}: impacts must be a non-empty object — omit the key "
                f"rather than shipping an empty one, so 'no consequence' and "
                f"'not yet classified' stay distinguishable"
            )
            for activity, level in imp.items():
                assert activity in ACTIVITIES, (
                    f"{r['id']}: bad activity {activity!r}"
                )
                assert level in IMPACT_LEVELS, (
                    f"{r['id']}: bad impact level {level!r}"
                )
        assert r["fix_target"] in FIX_TARGETS, (
            f"{r['id']}: bad fix_target {r['fix_target']!r}"
        )
        needs_away = r["fix_target"] in FIX_TARGETS_NEEDING_AWAY
        assert ("fix_away" in r) == needs_away, (
            f"{r['id']}: fix_target={r['fix_target']!r} requires "
            f"{'a' if needs_away else 'no'} fix_away"
        )
        if "fix_away" in r:
            assert r["fix_away"] != r["fix"], (
                f"{r['id']}: fix_away repeats fix — if the advice does not "
                f"change away from home, the target is wrong, not the text"
            )
        assert r["category"] in CATEGORIES, f"{r['id']}: bad category {r['category']!r}"
        if "also" in r:
            assert r["also"] in CATEGORIES, f"{r['id']}: bad also {r['also']!r}"
            assert r["also"] != r["category"], (
                f"{r['id']}: `also` repeats `category` ({r['also']!r})"
            )
        assert r["severity"] in SEVERITIES, f"{r['id']}: bad severity {r['severity']!r}"
        assert r["scope"] in SCOPES, f"{r['id']}: bad scope {r['scope']!r}"
        assert r["id"] not in seen_ids, f"duplicate rule id: {r['id']}"
        seen_ids.add(r["id"])


def _validate_metrics(metrics: list[dict[str, str]]) -> None:
    """Same discipline as `_validate`, for the glossary array."""
    seen_keys: set[str] = set()
    for m in metrics:
        assert set(m) - _METRIC_OPTIONAL_FIELDS == _METRIC_FIELDS, (
            f"entry has the wrong field set: {m}"
        )
        for k, v in m.items():
            assert isinstance(v, str) and v.strip(), f"{m.get('key')}.{k} is empty"
        assert m["key"] not in seen_keys, f"duplicate metric key: {m['key']}"
        seen_keys.add(m["key"])


def main() -> None:
    _validate(RULES)
    _validate_metrics(METRICS)
    doc = {
        "schema": SCHEMA_RULES_CATALOG,
        "version": os.environ.get("NETDIAG_RULES_VERSION") or None,
        "rules": RULES,
        "metrics": METRICS,
    }
    json.dump(doc, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")
    sys.stdout.flush()


if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:
        # One-shot writer like capabilities.py: this only silences the
        # traceback when a consumer closes early (e.g. a `| head -c1`).
        try:
            sys.stdout.close()
        except BrokenPipeError:
            pass
        sys.exit(1)
