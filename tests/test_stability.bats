#!/usr/bin/env bats
#
# Two-stage clearing for the monitor's rule verdicts (lib/stability.sh).
#
# Stage 1 — a fired rule stays fired until its condition has been clean for
# THRESH_MON_CLEAR_HOLD_S, however many cycles that is at the current
# cadence. Stage 2 — after it clears, the link is "recovering" until it has
# been clean for THRESH_MON_UNSTABLE_WINDOW_S. Both are CLI-side decisions;
# these tests drive the pure functions with a synthetic clock.
#
# Observed on the live network (2026-10-06): LA-2 warned in 5 of 69 samples
# across three episodes of 1, 3 and 1 samples — the rule fired after two
# consecutive cycles and cleared on the first miss.

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  JSON_MODE=0 QUIET=0 QUICK=0 EXPERT=0 REDACT=0 LOG=/dev/null
  NETDIAG_VERSION="test"
  # shellcheck source=../lib/thresholds.sh
  . "$REPO/lib/thresholds.sh"
  # shellcheck source=../lib/common.sh
  . "$REPO/lib/common.sh"
  # shellcheck source=../lib/globals.sh
  . "$REPO/lib/globals.sh"
  # shellcheck source=../lib/netid.sh
  . "$REPO/lib/netid.sh"
  # shellcheck source=../lib/monitor.sh
  . "$REPO/lib/monitor.sh"
  reset_state
}

reset_state() {
  MON_LINK_UP=1 MON_IFACE_TYPE=wifi MON_GATEWAY=192.168.1.1
  MON_GW_LOSS=0 MON_GW_RTT=3 MON_INET_LOSS="" MON_INET_LOSS_ALT="" MON_INET_RTT=""
  MON_INET_JITTER="" MON_GW_JITTER=""
  MON_GW_HIST="" MON_INET_HIST="" MON_INET_HIST_ALT=""
  MON_WIFI_RSSI="" MON_WIFI_SNR=""
  MON_DNS_OK=1 MON_TCP_OK=1 MON_PUBLIC_OK=1 MON_CAPTIVE=0
  MON_WEB_OK="" MON_MEASUREMENT_STATE="unknown"
  MON_VPN_ACTIVE=0 MON_ICMP_FILTERED=0 MON_DEGRADED=0
  MON_GW_LOSS_STREAK=0 MON_INET_LOSS_STREAK=0
  MON_TCP_HIST="" MON_TCP2_REFUSED_PCT="" MON_WEB_HIST="" MON_WEB_SUCC_PCT=""
  MON_VERDICT_LA2_STREAK=0 MON_VERDICT_LA1_STREAK=0 MON_VERDICT_LA1W_STREAK=0
  MON_VERDICT_P2_STREAK=0 MON_VERDICT_L1_STREAK=0
  MON_VERDICT_TCP2_STREAK=0 MON_VERDICT_TCP2W_STREAK=0
  MON_NETWORK_ID="wifi:ssid=Home"
  _mon_stability_reset
  MON_STAB_NETWORK=""
  _mon_stability_network "$MON_NETWORK_ID"
}

# One monitor cycle at synthetic time $1: rules, then the hold layer.
cycle() {
  _mon_rules
  _mon_stability_apply "$1"
}

jitter_cycle() { MON_INET_JITTER="$2"; cycle "$1"; }

has_rule() { [[ " $MON_RULES " == *" $1 "* ]]; }

# Fire LA-2 (two consecutive jittery cycles) ending at time $1.
fire_la2() {
  jitter_cycle $(($1 - 10)) 80
  jitter_cycle "$1" 80
  has_rule LA-2
}

# ── Stage 1: a fired rule holds until it has been clean long enough ──────

@test "onset is not delayed: LA-2 fires on the second jittery cycle, hold or no hold" {
  jitter_cycle 1000 80
  ! has_rule LA-2
  jitter_cycle 1010 80
  has_rule LA-2
  [ "$MON_SEVERITY" = "warn" ]
}

@test "stage 1: one clean cycle no longer clears a fired rule" {
  fire_la2 1010
  jitter_cycle 1020 5
  has_rule LA-2
  [ "$MON_SEVERITY" = "warn" ]
  [ "$MON_DEGRADED" -eq 1 ]
}

@test "stage 1: the rule clears once it has been clean for the hold, and not before" {
  fire_la2 1010
  jitter_cycle 1020 5
  jitter_cycle 1030 5
  has_rule LA-2          # last held at 1010: 20 s ago < 30 s
  jitter_cycle 1040 5   # 30 s
  ! has_rule LA-2
}

@test "stage 1 is time-based: a 2 s cadence clears after the same wall-clock hold" {
  fire_la2 1010
  local t
  for t in $(seq 1012 2 1038); do jitter_cycle "$t" 5; done
  has_rule LA-2          # 1012..1038: 26 s clean
  jitter_cycle 1042 5    # 30 s clean
  ! has_rule LA-2
}

@test "stage 1: a re-fire during the hold restarts the clean clock" {
  fire_la2 1010
  jitter_cycle 1020 5
  jitter_cycle 1025 80   # streak 1
  jitter_cycle 1030 80   # the condition holds again: the hold restarts at 1030
  jitter_cycle 1040 5
  jitter_cycle 1055 5
  has_rule LA-2          # 25 s after 1030
  jitter_cycle 1060 5    # 30 s
  ! has_rule LA-2
}

@test "stage 1 holds criticals too, and severity follows the held rule" {
  MON_GW_LOSS=25
  cycle 1000
  has_rule G2
  [ "$MON_SEVERITY" = "critical" ]
  MON_GW_LOSS=0
  cycle 1010
  has_rule G2
  [ "$MON_SEVERITY" = "critical" ]
  cycle 1040
  ! has_rule G2
  [ "$MON_SEVERITY" = "ok" ] || [ "$MON_SEVERITY" = "info" ]
}

@test "info rules are state descriptors, not faults: VPN-1 is never held" {
  MON_VPN_ACTIVE=1
  cycle 1000
  has_rule VPN-1
  MON_VPN_ACTIVE=0
  cycle 1010
  ! has_rule VPN-1
}

@test "N1 (link down) is a fact, not a flap: it clears the cycle the link returns" {
  MON_LINK_UP=0
  cycle 1000
  has_rule N1
  MON_LINK_UP=1
  cycle 1010
  ! has_rule N1
  [ "$MON_STAB_STATE" = "recovering" ]
}

# ── Stage 2: recently unstable ───────────────────────────────────────────

@test "stage 2: after the hold clears the state is recovering, not stable" {
  fire_la2 1010
  local t
  for t in 1020 1030 1040 1050; do jitter_cycle "$t" 5; done
  ! has_rule LA-2
  [ "$MON_STAB_STATE" = "recovering" ]
  # last raw occurrence was 1010 → 40 s ago, spikes counted once
  [ "$MON_STAB_RULES" = "LA-2:warn:0:40:1" ]
  # the severity does NOT become warn: recovering is its own state
  [ "$MON_SEVERITY" = "ok" ]
}

@test "stage 2 ends only after the window of clean time since the last occurrence" {
  fire_la2 1010
  jitter_cycle 1050 5
  jitter_cycle 1309 5
  [ "$MON_STAB_STATE" = "recovering" ]   # 299 s since 1010
  jitter_cycle 1311 5
  [ "$MON_STAB_STATE" = "stable" ]
  [ -z "$MON_STAB_RULES" ]
}

@test "stage 2: a re-fire returns to stage 1 and counts a second spike" {
  fire_la2 1010
  jitter_cycle 1050 5; jitter_cycle 1060 5
  ! has_rule LA-2
  [ "$MON_STAB_STATE" = "recovering" ]
  jitter_cycle 1100 80
  jitter_cycle 1110 80
  has_rule LA-2
  [ "$MON_STAB_STATE" = "unstable" ]
  [[ "$MON_STAB_RULES" == "LA-2:warn:1:0:2" ]]
}

@test "spikes older than the window are forgotten" {
  fire_la2 1010
  jitter_cycle 1050 5
  fire_la2 1400
  [[ "$MON_STAB_RULES" == "LA-2:warn:1:0:1" ]]
}

@test "stage 2 covers criticals: a cleared G2 leaves the link recovering" {
  MON_GW_LOSS=25; cycle 1000
  MON_GW_LOSS=0; cycle 1010; cycle 1040
  ! has_rule G2
  [ "$MON_STAB_STATE" = "recovering" ]
  [[ "$MON_STAB_RULES" == G2:critical:0:* ]]
}

@test "a change of network forgets the old network's instability" {
  fire_la2 1010
  MON_NETWORK_ID="wifi:ssid=Hotel"
  _mon_stability_network "$MON_NETWORK_ID"
  jitter_cycle 1020 5
  ! has_rule LA-2
  [ "$MON_STAB_STATE" = "stable" ]
}

@test "the same network id seen again does not reset the state" {
  fire_la2 1010
  _mon_stability_network "$MON_NETWORK_ID"
  jitter_cycle 1020 5
  has_rule LA-2
}

@test "an empty network id (link down) never resets the state" {
  fire_la2 1010
  _mon_stability_network ""
  jitter_cycle 1020 5
  has_rule LA-2
}

@test "rule ids with a dash round-trip through the state variables (TCP-2)" {
  MON_TCP2_REFUSED_PCT=100
  MON_GW_LOSS=0 MON_INET_LOSS=0
  cycle 1000; cycle 1010
  has_rule TCP-2
  MON_TCP2_REFUSED_PCT=0
  cycle 1020
  has_rule TCP-2
  [ "$MON_TCP2_STATE" != "" ]
}

# ── The thresholds are the only place the numbers live ───────────────────

@test "the hold and window constants exist and the window outlasts the hold" {
  [ -n "$THRESH_MON_CLEAR_HOLD_S" ]
  [ -n "$THRESH_MON_UNSTABLE_WINDOW_S" ]
  [ "$THRESH_MON_UNSTABLE_WINDOW_S" -gt "$THRESH_MON_CLEAR_HOLD_S" ]
}

# ── Which leg a jitter swing starts on ───────────────────────────────────

@test "LA-2 is attributed to the router leg when the gateway RTT is elevated" {
  MON_GW_RTT=40
  fire_la2 1010
  [ "$MON_LA2_LEG" = "router" ]
}

@test "LA-2 is attributed to the router leg when the gateway's own jitter is high" {
  MON_GW_JITTER=45
  fire_la2 1010
  [ "$MON_LA2_LEG" = "router" ]
}

@test "LA-2 with a steady gateway is attributed to the internet" {
  MON_GW_RTT=5 MON_GW_JITTER=3
  fire_la2 1010
  [ "$MON_LA2_LEG" = "internet" ]
}

@test "the attribution is kept while the rule is held and calm samples do not flip it" {
  MON_GW_RTT=40
  fire_la2 1010
  MON_GW_RTT=5
  jitter_cycle 1020 5
  has_rule LA-2
  [ "$MON_LA2_LEG" = "router" ]
}

# ── The burst runs inside the process ────────────────────────────────────

@test "burst: the ok→warn edge begins an investigation burst of the shared duration" {
  MON_PREV_SEVERITY=ok MON_SEVERITY=warn MON_BURST_UNTIL=""
  _mon_burst_consider 1000
  [ "$MON_BURST_KIND" = "investigation" ]
  [ "$MON_BURST_UNTIL" -eq $((1000 + THRESH_MON_BURST_DURATION_S)) ]
}

@test "burst: a sustained fault does not re-trigger it, and a running one is not restarted" {
  MON_PREV_SEVERITY=warn MON_SEVERITY=warn MON_BURST_UNTIL=""
  _mon_burst_consider 1000
  [ -z "$MON_BURST_UNTIL" ]
  MON_PREV_SEVERITY=ok MON_SEVERITY=warn
  _mon_burst_begin latency-test 1000
  _mon_burst_consider 1010
  [ "$MON_BURST_KIND" = "latency-test" ]
  [ "$MON_BURST_UNTIL" -eq $((1000 + THRESH_MON_BURST_DURATION_S)) ]
}

@test "burst: info severity is not an edge" {
  MON_PREV_SEVERITY=ok MON_SEVERITY=info MON_BURST_UNTIL=""
  _mon_burst_consider 1000
  [ -z "$MON_BURST_UNTIL" ]
}

@test "burst: it ends by itself at the deadline and _mon_burst_end is idempotent" {
  _mon_burst_begin latency-test 1000
  _mon_burst_active 1059
  ! _mon_burst_active $((1000 + THRESH_MON_BURST_DURATION_S))
  [ -z "$MON_BURST_UNTIL" ]
  _mon_burst_end
  _mon_burst_end
  [ -z "$MON_BURST_KIND" ]
}

@test "burst: a manual test during an investigation takes over the label and window" {
  MON_PREV_SEVERITY=ok MON_SEVERITY=warn
  _mon_burst_consider 1000
  _mon_burst_begin latency-test 1030
  [ "$MON_BURST_KIND" = "latency-test" ]
  [ "$MON_BURST_UNTIL" -eq $((1030 + THRESH_MON_BURST_DURATION_S)) ]
}

# ── Signals: the no-restart path ─────────────────────────────────────────

@test "SIGURG begins a latency test and SIGWINCH ends it, in the live loop" {
  # Real process, mocked probes: the monitor must change cadence on a
  # signal WITHOUT restarting — same pid, same seq counter, no
  # monitor-started line.
  run bash -c '
    export PATH="'"$PATH"'"
    cd "'"$REPO"'"
    out="$(mktemp)"
    ./bin/hopwatch --monitor --monitor-count 6 --monitor-fast-interval 4 \
      --monitor-degraded-interval 4 --monitor-medium-interval 300 \
      --monitor-slow-interval 300 >"$out" 2>/dev/null &
    pid=$!
    sleep 6
    kill -URG "$pid" 2>/dev/null
    sleep 7
    kill -WINCH "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    cat "$out"; rm -f "$out"
  '
  # Network-dependent: only assert the structural property when samples
  # arrived (CI without a network emits link-down samples, which is fine).
  [ -n "$output" ] || skip "no samples produced"
  printf '%s\n' "$output" | python3 -c '
import json, sys
rows = [json.loads(l) for l in sys.stdin if l.strip()]
assert [r["seq"] for r in rows] == list(range(1, len(rows) + 1)), "restarted: seq reset"
kinds = [(r["status"].get("burst") or {}).get("kind") for r in rows]
assert "latency-test" in kinds, kinds
'
}

# ── Gap detection no longer calls an ordinary burst cycle a gap ──────────

@test "gap: an ordinary 9 s cycle at the 2 s burst cadence is not a gap" {
  run _mon_gap_seconds 9 2
  [ "$output" = "" ]
}

@test "gap: the floor is the tolerance when the factored cadence is smaller" {
  run _mon_gap_seconds "$THRESH_MON_GAP_FLOOR_S" 2
  [ "$output" = "" ]
  run _mon_gap_seconds $((THRESH_MON_GAP_FLOOR_S + 1)) 2
  [ "$output" = "$((THRESH_MON_GAP_FLOOR_S + 1))" ]
}

# ── the last full check's speed (read on the slow tier) ──────────────────

@test "_mon_probe_last_speed reads the store for this network and clears it on a move" {
  MON_HISTORY_STORE="$BATS_TEST_TMPDIR/baseline.jsonl"
  HELPERS_DIR="$REPO/helpers"
  printf '%s\n' '{"timestamp":"2026-10-06T10:00:00Z","network":{"id":"ssid:Home"},"speedtest":{"down_mbps":65.1,"up_mbps":51.9}}' \
    > "$MON_HISTORY_STORE"
  MON_NETWORK_ID="ssid:Home"
  _mon_probe_last_speed
  [ "$MON_SPEED_DOWN" = "65.1" ]
  [ "$MON_SPEED_UP" = "51.9" ]
  [ -n "$MON_SPEED_AT" ]
  MON_NETWORK_ID="ssid:Hotel"
  _mon_probe_last_speed
  [ -z "$MON_SPEED_DOWN" ]
  [ -z "$MON_SPEED_AT" ]
}
