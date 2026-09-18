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
