#!/usr/bin/env bats
#
# netdiag --json's `suitability` block — the projection of fired
# diagnosis rules onto "will the thing I'm about to do work?" (see
# helpers/suitability.py's own docstring for the design). These run the
# real binary rather than calling helpers/suitability.py directly
# (test_suitability.bats already covers the pure mapping) because the
# point here is the wiring: that emit_json.py hands project() exactly
# the rules this run's diagnosis fired and exactly the families this
# run actually measured, with nothing lost or invented in between.

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  NETDIAG="$REPO/bin/netdiag"
}

@test "json: a quick run carries five suitability rows" {
  run "$NETDIAG" --quick --json
  [ "$status" -le 2 ]
  printf '%s' "$output" | python3 -c '
import json, sys
d = json.load(sys.stdin)
s = d["suitability"]
order = [e["activity"] for e in s]
assert order == ["calls", "streaming", "gaming", "vpn", "browsing"], order
for e in s:
    assert e["verdict"] in {"good", "degraded", "broken", "unmeasured"}, e
    assert e["label"], e
    assert isinstance(e["because"], list), e
    if e["verdict"] == "unmeasured":
        assert e["unmeasured_reason"], e
    else:
        assert e["unmeasured_reason"] is None, e
'
}

@test "json: a quick run cannot judge calls, and says so" {
  run "$NETDIAG" --quick --json
  [ "$status" -le 2 ]
  printf '%s' "$output" | python3 -c '
import json, sys
d = json.load(sys.stdin)
by = {e["activity"]: e for e in d["suitability"]}
fired = {x["rule"] for x in d["diagnosis"] if x.get("rule")}
breakers = {"N1", "N1b", "N1c", "P1", "P2", "L1", "G2", "CP-1", "D2", "DI-1", "DI-2", "DH-3"}
if not (fired & breakers):
    assert by["calls"]["verdict"] == "unmeasured", by["calls"]
    assert "latency under load" in by["calls"]["unmeasured_reason"], by["calls"]
'
}

@test "json: suitability never contradicts the diagnosis" {
  run "$NETDIAG" --quick --json
  [ "$status" -le 2 ]
  printf '%s' "$output" | python3 -c '
import json, sys
d = json.load(sys.stdin)
fired = {x["rule"] for x in d["diagnosis"] if x.get("rule")}
for e in d["suitability"]:
    # Every rule cited must actually have fired in this run.
    assert set(e["because"]) <= fired, (e, sorted(fired))
    # And a non-good verdict must cite something.
    if e["verdict"] in {"degraded", "broken"}:
        assert e["because"], e
'
}
