#!/usr/bin/env bats
# The rules -> activities projection. Pure Python, exercised directly:
# every case here is about the mapping, not about a probe, so nothing in
# this file runs bin/netdiag.

setup() {
  HELPERS="${BATS_TEST_DIRNAME}/../helpers"
  export HELPERS
}

@test "suitability: no rules fired and everything measured is five goods" {
  run python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["HELPERS"])
from suitability import project
out = project(fired=[], measured={"bufferbloat", "loss", "speed", "mtu", "path"})
assert [e["activity"] for e in out] == ["calls", "streaming", "gaming", "vpn", "browsing"], out
assert all(e["verdict"] == "good" for e in out), out
assert all(e["because"] == [] for e in out), out
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "suitability: worst impact wins across rules" {
  run python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["HELPERS"])
from suitability import project
# G3 degrades calls; B1 breaks them. Broken must win.
out = {e["activity"]: e for e in project(
    fired=["G3", "B1"],
    measured={"bufferbloat", "loss", "speed", "mtu", "path"})}
assert out["calls"]["verdict"] == "broken", out["calls"]
assert set(out["calls"]["because"]) == {"G3", "B1"}, out["calls"]
assert out["browsing"]["verdict"] == "good", out["browsing"]
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "suitability: an unmeasured activity says so, with a reason" {
  run python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["HELPERS"])
from suitability import project
# A quick check measures neither bufferbloat nor loss, so calls cannot
# be judged. Browsing depends on nothing extra and still can.
out = {e["activity"]: e for e in project(fired=[], measured={"path"})}
assert out["calls"]["verdict"] == "unmeasured", out["calls"]
assert out["calls"]["unmeasured_reason"], "no reason given"
assert out["browsing"]["verdict"] == "good", out["browsing"]
assert out["browsing"]["unmeasured_reason"] is None, out["browsing"]
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "suitability: a fired rule outranks not having measured" {
  run python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["HELPERS"])
from suitability import project
# N1 breaks everything and fires at any depth. A connection that is down
# is down whether or not the deep probes ran.
out = {e["activity"]: e for e in project(fired=["N1"], measured=set())}
assert all(e["verdict"] == "broken" for e in out.values()), out
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "suitability: an unknown rule id is ignored, not fatal" {
  run python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["HELPERS"])
from suitability import project
# A consumer may hold a rule from a newer netdiag. Losing one row's
# nuance beats losing the whole report.
out = {e["activity"]: e for e in project(
    fired=["ZZ-99"], measured={"bufferbloat", "loss", "speed", "mtu", "path"})}
assert all(e["verdict"] == "good" for e in out.values()), out
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "suitability: every activity in the catalog's impacts table is projected" {
  # The two vocabularies must not drift: a sixth activity added to
  # rules_catalog.ACTIVITIES without a row here would silently never
  # appear in a report.
  run python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["HELPERS"])
from rules_catalog import ACTIVITIES
from suitability import ACTIVITY_ORDER, LABELS, DEPENDS_ON
assert set(ACTIVITY_ORDER) == set(ACTIVITIES), (sorted(ACTIVITY_ORDER), sorted(ACTIVITIES))
assert set(LABELS) == set(ACTIVITIES), sorted(LABELS)
assert set(DEPENDS_ON) == set(ACTIVITIES), sorted(DEPENDS_ON)
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "suitability: contains no numeric comparison" {
  # The whole point of deriving from fired rules: this file judges no
  # number, so it cannot become a fifth thing that disagrees with
  # lib/thresholds.sh. A comparison against a numeric literal here is a
  # design violation, not a style one.
  run python3 - <<'PY'
import ast, os
src = open(os.path.join(os.environ["HELPERS"], "suitability.py")).read()
bad = []
for node in ast.walk(ast.parse(src)):
    if isinstance(node, ast.Compare):
        for operand in [node.left, *node.comparators]:
            if isinstance(operand, ast.Constant) and isinstance(
                    operand.value, (int, float)) and not isinstance(
                    operand.value, bool):
                bad.append(ast.unparse(node))
assert not bad, f"numeric comparison in suitability.py: {bad}"
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}
