#!/usr/bin/env bats
#
# "What should work here" — the suitability section of the text report.
# Renders the same `suitability` array --json emits (helpers/suitability.py),
# so these tests only pin the text rendering: the section exists, all five
# activities appear, and every verdict carries either a fired rule or a
# stated reason nothing was measured. The verdict logic itself belongs to
# helpers/suitability.py and tests/test_suitability.bats, not here.

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  NETDIAG="$REPO/bin/hopwatch"
}

headline_fixture() {
  JSON_MODE=0 QUIET=0 QUICK=0 EXPERT=0 LOG=/dev/null
  . "$REPO/lib/thresholds.sh"
  . "$REPO/lib/common.sh"
  . "$REPO/lib/globals.sh"
  . "$REPO/lib/speedtest.sh"
  . "$REPO/lib/headline.sh"
  FOCUS=ping NO_SPEED=1 NO_BUFFERBLOAT=1
  GATEWAY=192.168.1.1 GW_LOSS=0 GW_LATENCY=2
}

@test "output: healthy ping-only Internet row reports observed reachability" {
  headline_fixture
  PUBLIC_CHECKED=0 PUBLIC_OK=0 INET_LOSS=0 INET_LOSS_ALT=0
  run headline_run
  [ "$status" -eq 0 ]
  [[ "$output" != *unreachable* ]]
  [[ "$output" == *"reachable"* ]]
}

@test "output: an unrun Internet check stays unmeasured" {
  headline_fixture
  PUBLIC_CHECKED=0 PUBLIC_OK=0 INET_LOSS="" INET_LOSS_ALT=""
  run headline_run
  [ "$status" -eq 0 ]
  [[ "$output" != *unreachable* ]]
  [[ "$output" == *"not measured"* ]]
}

@test "output: reachable Internet without public metadata has an honest label" {
  headline_fixture
  PUBLIC_CHECKED=1 PUBLIC_OK=1
  run headline_run
  [ "$status" -eq 0 ]
  [[ "$output" == *"reachable"* ]]
  [[ "$output" != *"Internet      ?"* ]]
}

@test "output: the text report has a suitability section" {
  run "$NETDIAG" --quick
  [ "$status" -le 2 ]
  stripped=$(printf '%s' "$output" | sed $'s/\x1b\\[[0-9;]*[mK]//g')
  printf '%s' "$stripped" | grep -q "What should work here"
  printf '%s' "$stripped" | grep -q "Video & voice calls"
  printf '%s' "$stripped" | grep -q "Ordinary browsing"
}

@test "output: the section shows all five activities" {
  run "$NETDIAG" --quick
  [ "$status" -le 2 ]
  stripped=$(printf '%s' "$output" | sed $'s/\x1b\\[[0-9;]*[mK]//g')
  for label in "Video & voice calls" "Streaming" "Gaming" "VPN & remote access" "Ordinary browsing"; do
    printf '%s' "$stripped" | grep -q "$label" || { echo "missing: $label"; return 1; }
  done
}

@test "output: a verdict always carries its reason" {
  # Either a rule cited or an explanation of what was not measured. A bare
  # verdict with no evidence is the thing acceptance criterion 8 forbids.
  run "$NETDIAG" --quick
  [ "$status" -le 2 ]
  stripped=$(printf '%s' "$output" | sed $'s/\x1b\\[[0-9;]*[mK]//g')
  printf '%s' "$stripped" | grep -qE "because [A-Z]|didn't run|not measured"
}

@test "output: the suitability section prints before the Diagnosis section" {
  # "leads with what should work" is the whole point — a reader should not
  # have to scroll past the rule-by-rule paragraphs to reach the answer.
  run "$NETDIAG" --quick
  [ "$status" -le 2 ]
  stripped=$(printf '%s' "$output" | sed $'s/\x1b\\[[0-9;]*[mK]//g')
  local suit_line found_line
  suit_line=$(printf '%s\n' "$stripped" | grep -n "What should work here" | head -1 | cut -d: -f1)
  found_line=$(printf '%s\n' "$stripped" | grep -n "What we found" | head -1 | cut -d: -f1)
  [ -n "$suit_line" ]
  [ -n "$found_line" ]
  [ "$suit_line" -lt "$found_line" ]
}

@test "output: the section is unaffected by --json" {
  run "$NETDIAG" --quick --json
  [ "$status" -le 2 ]
  [[ "$output" != *"What should work here"* ]] || return 1
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert isinstance(d.get('suitability'), list) and len(d['suitability']) == 5, d.get('suitability')
"
}
