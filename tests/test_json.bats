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
  NETDIAG="$REPO/bin/hopwatch"
  HELPERS="$REPO/helpers"
  export HELPERS
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
sys.path.insert(0, "'"$HELPERS"'")
import rules_catalog
d = json.load(sys.stdin)
by = {e["activity"]: e for e in d["suitability"]}
fired = {x["rule"] for x in d["diagnosis"] if x.get("rule")}
call_rules = {r["id"] for r in rules_catalog.RULES if "calls" in r.get("impacts", {})}
if not (fired & call_rules):
    assert by["calls"]["verdict"] == "unmeasured", by["calls"]
    assert "latency under load" in by["calls"]["unmeasured_reason"], by["calls"]
else:
    assert by["calls"]["verdict"] in {"degraded", "broken"}, by["calls"]
'
}

@test "json: a missing UPnP state is not a measured path family" {
  # measured_families() is called directly, against this file's own rule,
  # because the case cannot be reached through bin/hopwatch: bash always
  # exports WAN_UPNP_STATE, defaulted to "unknown" by lib/globals.sh. A
  # null or empty state only happens when the binary is *not* the caller,
  # which emit_json.py's docstring explicitly supports ("a direct helper
  # invocation should expose missing metadata as null"). Comparing against
  # the literal "unknown" alone counted that absence as a probe.
  run python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["HELPERS"])
from emit_json import measured_families

def families(state):
    return measured_families({"wan": {"upnp": {"state": state}}})

# Three spellings of "the WAN probes did not run" — bash's default, and
# the two a direct invocation produces.
for absent in ("unknown", None, ""):
    assert "path" not in families(absent), repr(absent)
assert "path" not in measured_families({"wan": {"upnp": {}}}), "no state key"
assert "path" not in measured_families({}), "no wan block at all"
# And the two values wan_upnp_run actually sets once it has run.
for probed in ("enabled", "disabled"):
    assert "path" in families(probed), probed
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "json: a run that probed nothing calls the vpn row's path checks unmeasured" {
  # The whole document, end to end, in the mode above: emit_json.py
  # standalone under an empty environment, so nothing was probed. `vpn`
  # depends on the MTU probe *and* the path checks; naming only the first
  # would mean a run that probed no path at all reads "good" as soon as
  # MTU happens to be present, which is the lie helpers/suitability.py
  # exists to prevent. Touches no network.
  local py
  py="$(command -v python3)"
  [ -n "$py" ]
  run env -i "$py" "$REPO/helpers/emit_json.py"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c '
import json, sys
by = {e["activity"]: e for e in json.load(sys.stdin)["suitability"]}
vpn = by["vpn"]
assert vpn["verdict"] == "unmeasured", vpn
assert "path" in (vpn["unmeasured_reason"] or ""), vpn
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

@test "json: emit_json includes lan.arp_active_count when set" {
  local py
  py="$(command -v python3)"
  [ -n "$py" ]
  run env -i NETDIAG_ARP_ACTIVE_COUNT=15 "$py" "$REPO/helpers/emit_json.py"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert "lan" in d, "missing lan block"
assert d["lan"]["arp_active_count"] == 15, d["lan"]
'
}

@test "json: emit_json includes lan.arp_active_count as null when unset" {
  local py
  py="$(command -v python3)"
  [ -n "$py" ]
  run env -i "$py" "$REPO/helpers/emit_json.py"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert "lan" in d, "missing lan block"
assert d["lan"]["arp_active_count"] is None, d["lan"]
'
}

