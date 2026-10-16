#!/usr/bin/env bats
#
# lib/thresholds.sh is the single source of truth for every number a
# diagnosis fires on. Three consumers now read it — lib/diagnosis.sh (one
# verdict per scan), lib/monitor.sh (one verdict every few seconds) and
# helpers/history.py (one verdict per stored run, in --show) — and the
# failure mode this file guards is them drifting apart: a menu-bar dot that
# says "unstable" over a report that says "healthy" discredits both, and
# the user has no way to tell which lied.

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  JSON_MODE=0 QUIET=0 QUICK=0 EXPERT=0 REDACT=0 LOG=/dev/null
  # shellcheck source=../lib/thresholds.sh
  . "$REPO/lib/thresholds.sh"
  # shellcheck source=../lib/common.sh
  . "$REPO/lib/common.sh"
  # shellcheck source=../lib/globals.sh
  . "$REPO/lib/globals.sh"
}

# ── The file stands alone ────────────────────────────────────────────────

@test "thresholds.sh sources standalone under set -eu with nothing else loaded" {
  # lib/monitor.sh sources it on its own. If it ever grows a dependency on
  # common.sh or globals.sh, the monitor breaks at spawn time rather than
  # at review time.
  run bash -c "set -eu; . '$REPO/lib/thresholds.sh'; printf '%s' \"\$LOSS_CRIT_PCT\""
  [ "$status" -eq 0 ]
  [ "$output" = "20" ]
}

@test "every threshold a rule reads is defined" {
  for v in LOSS_WARN_PCT LOSS_CRIT_PCT LOSS_PROBE_COUNT LOSS_PROBE_INTERVAL \
           THRESH_GW_LOSS_CRIT_PCT THRESH_ICMP_FILTERED_LOSS_PCT \
           THRESH_ICMP_TOTAL_LOSS_PCT THRESH_WIFI_RSSI_WEAK_DBM \
           THRESH_WIFI_RSSI_G1_DBM THRESH_WIFI_SNR_LOW_DB \
           THRESH_WIFI_CHANNEL_NEIGHBOURS THRESH_WIFI_DISCONNECTS \
           THRESH_WIFI_RSSI_EXCELLENT_DBM THRESH_LATENCY_JITTER_WARN_MS \
           THRESH_IPV6_LOSS_PCT THRESH_MTU_STANDARD THRESH_MTU_CRIT \
           THRESH_MTU_FULL_PATH THRESH_MTU_ETHERNET \
           THRESH_GATEWAY_QUICK_PING_COUNT \
           THRESH_NTP_DRIFT_CRIT_S THRESH_NTP_DRIFT_WARN_S \
           THRESH_DHCP_LEASE_WARN_S THRESH_BUFFERBLOAT_A_MS \
           THRESH_BUFFERBLOAT_B_MS THRESH_BUFFERBLOAT_C_MS \
           THRESH_BUFFERBLOAT_D_MS THRESH_BUFFERBLOAT_SATURATED_DELTA_MS \
           THRESH_BUFFERBLOAT_DL_BYTES THRESH_BUFFERBLOAT_DL_MAX_TIME_SEC \
           THRESH_COMPARE_MIN_SAMPLES \
           THRESH_COMPARE_TAIL_PCTL THRESH_MON_LOSS_CONFIRM_CYCLES \
           THRESH_SPEED_DROP_FACTOR THRESH_SPEED_CONFIRM_RUNS \
           THRESH_BASELINE_GW_RTT_FLOOR_MS \
           THRESH_BASELINE_MIN_RUNS THRESH_BASELINE_WINDOW_RUNS \
           THRESH_BASELINE_RTT_SPIKE_FACTOR THRESH_BASELINE_LOSS_SPIKE_FACTOR \
           THRESH_BASELINE_BUFFERBLOAT_SPIKE_FACTOR THRESH_BASELINE_LAN_SPIKE_FACTOR \
           THRESH_RUN_BUDGET_QUICK_S THRESH_RUN_BUDGET_NO_SPEED_S \
           THRESH_RUN_BUDGET_FULL_S \
           THRESH_MTR_HOP_LOSS_PCT THRESH_WIFI_GOODPUT_CEILING_PCT \
           THRESH_WIFI_EVENTS_STORED THRESH_MON_GAP_FACTOR \
           THRESH_MON_GAP_MIN_S \
           THRESH_WATCHER_INTERVAL_S THRESH_WATCHER_STALE_FACTOR \
           THRESH_AV_WINDOW_HOURS THRESH_AV_OUTAGE_RULES \
           THRESH_AV_OUTAGE_COUNT THRESH_AV_DOWNTIME_S \
           THRESH_AV_FLAP_MAX_S THRESH_AV_FLAP_COUNT \
           THRESH_AV_UNOBSERVED_NOTE_PCT THRESH_EV_RESTART_BRIDGE_S \
           THRESH_TRAFFIC_SAMPLE_S THRESH_TRAFFIC_BUSY_MBPS \
           THRESH_LAN_ACTIVE_DEVICES \
           THRESH_WIFI_STICKY_DELTA_DBM THRESH_WIFI_STICKY_MAX_RSSI \
           THRESH_WIFI_STICKY_CANDIDATE_MIN_RSSI \
           THRESH_WIFI_TX_COLLAPSE_MBPS THRESH_WIFI_COLLAPSE_MIN_RSSI \
           THRESH_WIFI_ASYMMETRIC_MIN_RSSI \
           THRESH_WIFI_SNR_MIN_DB \
           THRESH_WIFI_BAND_5GHZ_MIN_RSSI THRESH_WIFI_BAND_TRAP_MAX_DELTA_DBM \
           THRESH_WIFI_BAND_TRAP_WARN_TX_MBPS \
           THRESH_WIFI_24GHZ_MIN_CHANNEL THRESH_WIFI_24GHZ_MAX_CHANNEL \
           THRESH_DHCP_LEASE_WARN_S \
           THRESH_BUFFERBLOAT_FAST_MBPS THRESH_BUFFERBLOAT_CONSTRAINED_MBPS \
           THRESH_AWDL_BASE_RTT_MAX_MS THRESH_AWDL_SPIKE_RTT_MIN_MS \
           THRESH_AWDL_JITTER_MIN_MS THRESH_SOCK_HOLDER_SHARE_PCT \
           THRESH_MON_CONN_CONFIRM_CYCLES THRESH_CONN_RESOLVERS_TOGETHER \
           THRESH_CONN_HOLDER_MIN_FLOWS \
           THRESH_HOG_GW_RTT_MS THRESH_HOG_JITTER_MS THRESH_HOG_SAMPLE_S \
           THRESH_HOG_SNAPSHOTS THRESH_HOG_MIN_MBPS THRESH_HOG_LINK_SHARE_PCT \
           THRESH_HOG_UNKNOWN_CAPACITY_MBPS THRESH_HOG_DOMINANCE_PCT \
           THRESH_MON_HOG_CONFIRM_CYCLES THRESH_MON_HOG_RECHECK_S \
           THRESH_WIFI_REJOIN_GRACE_S THRESH_MON_PRECURSOR_S \
           THRESH_DHCP_ADDRESS_GRACE_S THRESH_AUTORECONNECT_RETRY_S \
           THRESH_AUTORECONNECT_MAX_RETRIES \
           THRESH_AUTORECONNECT_WEDGED_RSSI_MIN_DBM \
           THRESH_AUTORECONNECT_WEDGED_LOSS_PCT \
           THRESH_AUTORECONNECT_WEDGED_RECOVER_PCT \
           THRESH_AUTORECONNECT_WEDGED_SAMPLES THRESH_MON_CARRY_S \
           THRESH_MON_NETWORK_NAME_MAX_BYTES \
           THRESH_REPAIR_WIFI_REJOIN_WAIT_S THRESH_REPAIR_WIFI_JOIN_TIMEOUT_S \
           THRESH_REPAIR_WIFI_POWER_TIMEOUT_S THRESH_REPAIR_WIFI_SETTLE_S; do
    [ -n "${!v:-}" ] || { echo "undefined threshold: $v"; return 1; }
  done
}

@test "no diagnosis rule carries an inline numeric cutoff" {
  # The regression this catches: someone tightening a rule by editing the
  # literal in diagnosis.sh, leaving monitor.sh on the old value. Matches
  # the comparison operators against a bare number, so prose that happens
  # to contain a digit is not a hit.
  #
  # Zero is excluded deliberately: `-gt 0` on DHCP_TIME_REMAINING_S asks
  # "did we measure anything?", not "is it past a cutoff". Sentinels of
  # that shape are validity guards and belong inline; no policy threshold
  # in this project is 0.
  run grep -nE '(loss_at_least|loss_below) "\$[A-Z_]+" [0-9]+|-lt -?[1-9][0-9]* \]|-ge -?[1-9][0-9]* \]|-gt -?[1-9][0-9]* \]' \
    "$REPO/lib/diagnosis.sh"
  [ "$status" -ne 0 ] || { echo "inline cutoff in diagnosis.sh:"; echo "$output"; return 1; }
}

@test "lib/monitor.sh and lib/repairs.sh carry no inline numeric cutoff either" {
  # The automatic Wi-Fi reconnect decides, unattended, to power-cycle a
  # radio, and it does so in monitor.sh against every number in the
  # "Automatic Wi-Fi reconnect" block of thresholds.sh. The same grep as
  # diagnosis.sh's: a comparison against a bare non-zero number. A loop
  # bound or a sentinel is spelled with a named constant or zero.
  run grep -nE '(loss_at_least|loss_below) "\$[A-Z_]+" [0-9]+|-lt -?[1-9][0-9]* \]|-ge -?[1-9][0-9]* \]|-gt -?[1-9][0-9]* \]' \
    "$REPO/lib/monitor.sh" "$REPO/lib/repairs.sh"
  [ "$status" -ne 0 ] || { echo "inline cutoff:"; echo "$output"; return 1; }
}

@test "the guard would actually catch a cutoff planted in monitor.sh" {
  cp "$REPO/lib/monitor.sh" "$BATS_TEST_TMPDIR/planted_monitor.sh"
  printf '\nif [ "$MON_AR_DHCP_TRIES" -ge 4 ]; then :; fi\n' >> "$BATS_TEST_TMPDIR/planted_monitor.sh"
  run grep -nE '(loss_at_least|loss_below) "\$[A-Z_]+" [0-9]+|-lt -?[1-9][0-9]* \]|-ge -?[1-9][0-9]* \]|-gt -?[1-9][0-9]* \]' \
    "$BATS_TEST_TMPDIR/planted_monitor.sh"
  [ "$status" -eq 0 ]
}

@test "the automatic-reconnect cutoffs are the ones the design relies on" {
  # Not a statement that these are the right numbers; a statement that the
  # relationships the code assumes still hold when someone retunes them.
  # Recovery sits below the trigger, or an episode could never end.
  [ "$THRESH_AUTORECONNECT_WEDGED_RECOVER_PCT" -lt "$THRESH_AUTORECONNECT_WEDGED_LOSS_PCT" ]
  # At least two samples, or "consecutive" means nothing.
  [ "$THRESH_AUTORECONNECT_WEDGED_SAMPLES" -ge 2 ]
  # The carry-over must outlast the longest retry sequence, or a restart
  # mid-sequence forgets it. (It must also outlast a precursor window, or a
  # drop that follows a restart could never be matched to its cause.)
  [ "$THRESH_MON_CARRY_S" -gt "$THRESH_MON_PRECURSOR_S" ]
  [ "$THRESH_MON_CARRY_S" -gt $(( THRESH_DHCP_ADDRESS_GRACE_S + THRESH_AUTORECONNECT_RETRY_S * THRESH_AUTORECONNECT_MAX_RETRIES )) ]
  # A strong-signal floor: never weaker than the weak-signal cutoff.
  [ "$THRESH_AUTORECONNECT_WEDGED_RSSI_MIN_DBM" -ge "$THRESH_WIFI_RSSI_WEAK_DBM" ]
}

@test "helpers/history.py carries no inline numeric cutoff either" {
  # --show judges a stored run against its network's history, so this file
  # is now the third thing in the project that decides whether a number is
  # normal. It reads THRESH_COMPARE_* from the environment; the regression
  # this catches is a cutoff creeping back in as a Python literal, where
  # nothing in lib/thresholds.sh would ever reflect a change to it.
  #
  # Same shape as the bash guard: a comparison operator against a bare
  # number. Zero is excluded for the same reason — `if n > 0` asks "did we
  # measure anything?", not "is this past a cutoff" — and a comparison
  # against a named constant is exactly what this test wants to see.
  run grep -nE '(<=|>=|<|>) *-?[1-9][0-9]*' "$REPO/helpers/history.py"
  [ "$status" -ne 0 ] || { echo "inline cutoff in history.py:"; echo "$output"; return 1; }
}

@test "the guard would actually catch a cutoff planted in history.py" {
  # A grep-based guard is only as good as its pattern, and a pattern that
  # matches nothing passes for the wrong reason. Plant one and prove it.
  cp "$REPO/helpers/history.py" "$BATS_TEST_TMPDIR/planted.py"
  printf '\nif False:\n    pass  # if percentile >= 90:\n' >> "$BATS_TEST_TMPDIR/planted.py"
  run grep -nE '(<=|>=|<|>) *-?[1-9][0-9]*' "$BATS_TEST_TMPDIR/planted.py"
  [ "$status" -eq 0 ]
}

@test "helpers/history.py refuses to judge without the thresholds" {
  # A default in the Python would be a second home for a number that has
  # exactly one, and a stale second copy still produces a plausible
  # verdict — the failure nobody notices.
  printf '{"timestamp":"2026-01-01T00:00:00Z","network":{"id":"wifi:mac=aa:bb:cc:dd:ee:ff"}}\n' \
    > "$BATS_TEST_TMPDIR/baseline.jsonl"
  run env -u THRESH_COMPARE_MIN_SAMPLES -u THRESH_COMPARE_TAIL_PCTL \
    python3 "$REPO/helpers/history.py" --history "$BATS_TEST_TMPDIR/baseline.jsonl" \
    --show 2026-01-01T00:00:00Z
  [ "$status" -eq 3 ]
  [[ "$output" == *"THRESH_COMPARE_MIN_SAMPLES"* ]] || return 1
  [[ "$output" == *"lib/thresholds.sh"* ]] || return 1
}

@test "the comparison tail leaves a middle band" {
  # At 50 or above the two tails meet and every value is simultaneously
  # notable at both ends, so which verdict a run gets would come down to
  # the order the branches happen to be written in.
  [ "$THRESH_COMPARE_TAIL_PCTL" -lt 50 ]
}

# ── The two RSSI cutoffs really are different ────────────────────────────
# W1's -75 and G1's -70 sit four lines apart in diagnosis.sh and mean
# different things: -75 is "your signal is bad enough to complain about",
# -70 is "your signal is bad enough to explain the packets going missing".
# Collapsing them would change which fix the user is told to try.

@test "at 25% gateway loss, G2 fires as critical while G3 stays quiet" {
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  GATEWAY=192.168.1.1 IS_WIFI=1 GW_LOSS=25 PUBLIC_OK=1
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  diagnosis_run >/dev/null
  local rules=" ${DIAG_RULE[*]} "
  [[ "$rules" == *" G2 "* ]] || return 1
  [[ "$rules" != *" G3 "* ]] || return 1
}

@test "at 10% gateway loss, G3 fires as warn while G2 stays quiet" {
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  GATEWAY=192.168.1.1 IS_WIFI=1 GW_LOSS=10 PUBLIC_OK=1
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  diagnosis_run >/dev/null
  local rules=" ${DIAG_RULE[*]} "
  [[ "$rules" == *" G3 "* ]] || return 1
  [[ "$rules" != *" G2 "* ]] || return 1
}

@test "raising a threshold in one place changes the rule that reads it" {
  # Proves the refactor is live wiring and not a parallel set of constants
  # sitting unused next to the original literals.
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  GATEWAY=192.168.1.1 IS_WIFI=1 WIFI_RSSI=-60 PUBLIC_OK=1 GW_LOSS=25
  THRESH_GW_LOSS_CRIT_PCT=90
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  diagnosis_run >/dev/null
  local rules=" ${DIAG_RULE[*]} "
  [[ "$rules" != *" G2 "* ]] || return 1
  [[ "$rules" == *" G3 "* ]] || return 1
}

@test "weak WiFi signal emits W1 even without gateway loss" {
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  GATEWAY=192.168.1.1 IS_WIFI=1 WIFI_RSSI=-76 WIFI_SNR=30
  WIFI_SCAN_CURRENT_CHANNEL_NEIGHBORS=0 PUBLIC_OK=1 PUBLIC_CHECKED=1
  GW_LOSS=0
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  diagnosis_run >/dev/null
  [[ " ${DIAG_RULE[*]} " == *" W1 "* ]] || return 1
}

@test "low WiFi SNR emits W2" {
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  GATEWAY=192.168.1.1 IS_WIFI=1 WIFI_RSSI=-60 WIFI_SNR=19
  WIFI_SCAN_CURRENT_CHANNEL_NEIGHBORS=0 PUBLIC_OK=1 PUBLIC_CHECKED=1
  GW_LOSS=0
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  diagnosis_run >/dev/null
  [[ " ${DIAG_RULE[*]} " == *" W2 "* ]] || return 1
}

@test "a crowded WiFi channel emits WS-1" {
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  GATEWAY=192.168.1.1 IS_WIFI=1 WIFI_RSSI=-60 WIFI_SNR=30
  WIFI_SCAN_CURRENT_CHANNEL_NEIGHBORS=4 PUBLIC_OK=1 PUBLIC_CHECKED=1
  GW_LOSS=0
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  diagnosis_run >/dev/null
  [[ " ${DIAG_RULE[*]} " == *" WS-1 "* ]] || return 1
}

@test "sticky AP emits W3 when candidate is stronger" {
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  GATEWAY=192.168.1.1 IS_WIFI=1 WIFI_MULTI_AP=1 WIFI_SSID="Home"
  WIFI_BSSID="aa:bb:cc:dd:ee:ff" WIFI_RSSI=-78 WIFI_SNR=30
  WIFI_CANDIDATE_SSID="Home" WIFI_CANDIDATE_BSSID="11:22:33:44:55:66"
  WIFI_CANDIDATE_RSSI=-50
  WIFI_SCAN_CURRENT_CHANNEL_NEIGHBORS=0 PUBLIC_OK=1 PUBLIC_CHECKED=1
  GW_LOSS=0
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  diagnosis_run >/dev/null
  [[ " ${DIAG_RULE[*]} " == *" W3 "* ]] || return 1
}

# ── grade_bufferbloat reads the same table ───────────────────────────────

@test "grade_bufferbloat maps the Waveform bands from the shared constants" {
  [ "$(grade_bufferbloat 1)"   = A ]
  [ "$(grade_bufferbloat 20)"  = B ]
  [ "$(grade_bufferbloat 45)"  = C ]
  [ "$(grade_bufferbloat 150)" = D ]
  [ "$(grade_bufferbloat 500)" = F ]
}

@test "grade_bufferbloat boundaries are exclusive at the lower edge" {
  [ "$(grade_bufferbloat "$THRESH_BUFFERBLOAT_A_MS")" = B ]
  [ "$(grade_bufferbloat "$THRESH_BUFFERBLOAT_D_MS")" = F ]
}

@test "helpers/judgement.py carries no inline numeric cutoff either" {
  # judgement.py is the shared pair-table both history.py's judged block
  # and summary.py's judged rows now read, so a cutoff creeping back in
  # here as a Python literal is the single worst place for it: it would
  # silently retune both consumers at once. Same guard, same reasoning as
  # the history.py and summary.py checks above.
  run grep -nE '(<=|>=|<|>) *-?[1-9][0-9]*' "$REPO/helpers/judgement.py"
  [ "$status" -ne 0 ] || { echo "inline cutoff in judgement.py:"; echo "$output"; return 1; }
}

@test "the guard would actually catch a cutoff planted in judgement.py" {
  cp "$REPO/helpers/judgement.py" "$BATS_TEST_TMPDIR/planted_judgement.py"
  printf '\nif False:\n    pass  # if value >= 20:\n' >> "$BATS_TEST_TMPDIR/planted_judgement.py"
  run grep -nE '(<=|>=|<|>) *-?[1-9][0-9]*' "$BATS_TEST_TMPDIR/planted_judgement.py"
  [ "$status" -eq 0 ]
}

@test "helpers/history.py refuses to build judged verdicts without the judging thresholds" {
  # Distinct from "helpers/history.py refuses to judge without the
  # thresholds" above: that test covers THRESH_COMPARE_* (--show's
  # comparison); this one covers the six JUDGED_METRICS cutoffs the plain
  # --history listing's judged block now reads in every mode, main()
  # requires them unconditionally so this is not scoped to --show.
  printf '{"timestamp":"2026-01-01T00:00:00Z","network":{"id":"wifi:mac=aa:bb:cc:dd:ee:ff"}}\n' \
    > "$BATS_TEST_TMPDIR/baseline.jsonl"
  run env THRESH_COMPARE_MIN_SAMPLES="$THRESH_COMPARE_MIN_SAMPLES" \
          THRESH_COMPARE_TAIL_PCTL="$THRESH_COMPARE_TAIL_PCTL" \
      python3 "$REPO/helpers/history.py" --history "$BATS_TEST_TMPDIR/baseline.jsonl"
  [ "$status" -eq 3 ]
  [[ "$output" == *"LOSS_WARN_PCT"* ]] || return 1
  [[ "$output" == *"lib/thresholds.sh"* ]] || return 1
}

@test "helpers/summary.py carries no inline numeric cutoff either" {
  # --summary now judges each metric line, so this file is the fourth
  # thing in the project that decides whether a number is normal. Same
  # guard as the history.py one above, same reasoning: a cutoff creeping
  # back as a Python literal is a number lib/thresholds.sh would never
  # reflect a change to.
  run grep -nE '(<=|>=|<|>) *-?[1-9][0-9]*' "$REPO/helpers/summary.py"
  [ "$status" -ne 0 ] || { echo "inline cutoff in summary.py:"; echo "$output"; return 1; }
}

@test "the guard would actually catch a cutoff planted in summary.py" {
  cp "$REPO/helpers/summary.py" "$BATS_TEST_TMPDIR/planted_summary.py"
  printf '\nif False:\n    pass  # if loss >= 20:\n' >> "$BATS_TEST_TMPDIR/planted_summary.py"
  run grep -nE '(<=|>=|<|>) *-?[1-9][0-9]*' "$BATS_TEST_TMPDIR/planted_summary.py"
  [ "$status" -eq 0 ]
}

@test "helpers/events.py carries no inline numeric cutoff either" {
  # events.py decides whether a restart ended a fault or only interrupted
  # our sight of it, which changes how many episodes a person is told
  # about. It reads THRESH_EV_RESTART_BRIDGE_S from the environment; the
  # regression this catches is that window creeping back in as a literal,
  # where a change to lib/thresholds.sh would never reach it.
  run grep -nE '(<=|>=|<|>) *-?[1-9][0-9]*' "$REPO/helpers/events.py"
  [ "$status" -ne 0 ] || { echo "inline cutoff in events.py:"; echo "$output"; return 1; }
}

@test "helpers/baseline.py carries no inline numeric cutoff either" {
  # BL-1's ratio tests and "enough history" counts were literals in this
  # file (a 3.0 in METRICS, a `>= 3` in three places), so tuning
  # lib/thresholds.sh never reached them. They are THRESH_BASELINE_* now.
  run grep -nE '(<=|>=|<|>) *-?[1-9][0-9]*' "$REPO/helpers/baseline.py"
  [ "$status" -ne 0 ] || { echo "inline cutoff in baseline.py:"; echo "$output"; return 1; }
  # And no numeric factor left in the METRICS table's fourth column.
  run grep -nE '"(spike|drop)", *[0-9]' "$REPO/helpers/baseline.py"
  [ "$status" -ne 0 ] || { echo "literal factor in baseline.py METRICS:"; echo "$output"; return 1; }
}

@test "the guard would actually catch a cutoff planted in baseline.py" {
  cp "$REPO/helpers/baseline.py" "$BATS_TEST_TMPDIR/planted_baseline.py"
  printf '\nif False:\n    pass  # if len(nums) < 3:\n' >> "$BATS_TEST_TMPDIR/planted_baseline.py"
  run grep -nE '(<=|>=|<|>) *-?[1-9][0-9]*' "$BATS_TEST_TMPDIR/planted_baseline.py"
  [ "$status" -eq 0 ]
}

@test "emit_json.py's run-time budget is not a literal" {
  # timings.budget_s was `8.0 if QUICK else 30.0`, stale the day the speed
  # test became default-on. The budgets are THRESH_RUN_BUDGET_* now.
  run grep -nE 'budget[^#]*= *[0-9]|else +[0-9]+\.[0-9]' "$REPO/helpers/emit_json.py"
  [ "$status" -ne 0 ] || { echo "literal budget in emit_json.py:"; echo "$output"; return 1; }
}

@test "the run budgets are ordered quick < no-speed < full" {
  [ "$THRESH_RUN_BUDGET_QUICK_S" -lt "$THRESH_RUN_BUDGET_NO_SPEED_S" ]
  [ "$THRESH_RUN_BUDGET_NO_SPEED_S" -lt "$THRESH_RUN_BUDGET_FULL_S" ]
}

@test "the guard would actually catch a cutoff planted in events.py" {
  cp "$REPO/helpers/events.py" "$BATS_TEST_TMPDIR/planted_events.py"
  printf '\nif False:\n    pass  # if gap_s <= 90:\n' >> "$BATS_TEST_TMPDIR/planted_events.py"
  run grep -nE '(<=|>=|<|>) *-?[1-9][0-9]*' "$BATS_TEST_TMPDIR/planted_events.py"
  [ "$status" -eq 0 ]
}
