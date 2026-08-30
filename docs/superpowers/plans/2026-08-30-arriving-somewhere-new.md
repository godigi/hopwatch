# Arriving Somewhere New — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make joining a network the moment netdiag speaks — with a per-activity verdict, an actionable fix aimed at whoever can actually apply it, and a memory of what this network has been like.

**Architecture:** Two new CLI outputs (`suitability`, projected from which rules fired rather than from any metric; and `fix`/`fix_away`/`fix_target` on catalog rules) plus three GUI surfaces that render CLI output which already exists (`--events` episodes, `--history` medians, the new suitability block). No new thresholds anywhere: `helpers/suitability.py` reads no cutoffs, so `tests/test_thresholds.bats` never grows a fifth guarded file.

**Tech Stack:** bash 5 + Python 3 helpers (CLI), SwiftUI / SwiftPM (GUI), bats-core (CLI tests), the in-app `--verify` harness (Swift tests — `swift test` is a no-op on this toolchain).

**Spec:** `docs/superpowers/specs/2026-08-29-arriving-somewhere-new-design.md`
**Mockups:** `nimbalyst-local/mockups/netdiag-{arrival-card,activity-episodes,suitability-and-fixes}.mockup.html` (gitignored)

---

## File structure

**Phase 1 — CLI (Tasks 1–6)**

| File | Responsibility |
|---|---|
| `helpers/rules_catalog.py` | Gains `impacts`, `fix`, `fix_away`, `fix_target` per rule; `SCHEMA_RULES_CATALOG` 4 → 5; `_validate` learns the new field types |
| `helpers/suitability.py` | **New.** Pure projection: fired rules + measured-metric set → the `suitability` array. Reads no thresholds, imports nothing from `lib/` |
| `helpers/emit_json.py` | Calls `build_suitability()`, inlines the array next to `diagnosis` |
| `lib/output.sh` | Renders the five rows in the human-readable report |
| `tests/test_suitability.bats` | **New.** The projection's own tests |
| `tests/test_rules_catalog.bats` | Gains assertions for the new fields |
| `docs/JSON-SCHEMA.md`, `docs/DIAGNOSIS-RULES.md` | Document the block and the new catalog fields |

**Phase 2 — the arrival moment (Tasks 7–13)**

| File | Responsibility |
|---|---|
| `gui/Sources/NetdiagGUI/Models/RunSnapshot.swift` | Decodes `suitability` |
| `gui/Sources/NetdiagGUI/Models/RulesCatalog.swift` | Decodes `fix`, `fix_away`, `fix_target` |
| `gui/Sources/NetdiagGUI/Views/Components.swift` | **`SuitabilityPanel`** — the five rows, shared by the report and the dropdown |
| `gui/Sources/NetdiagGUI/Views/RunReportView.swift` | Hosts the panel and the per-diagnosis fix box |
| `gui/Sources/NetdiagGUI/Support/Defaults.swift` | `networkOwned: Set<String>` |
| `gui/Sources/NetdiagGUI/Services/HistoryStore.swift` | `isOwned(networkID:)` / `setOwned(_:for:)` |
| `gui/Sources/NetdiagGUI/Views/NetworksView.swift` | The ownership toggle |
| `gui/Sources/NetdiagGUI/Support/ArrivalPolicy.swift` | **New.** Pure: never-seen → full, seen → quick, unsafe → lighter |
| `gui/Sources/NetdiagGUI/Support/StageResolver.swift` | `.arrived` case, ranked below `.alerted` |
| `gui/Sources/NetdiagGUI/Views/DropdownView.swift` | Renders `.arrived` |
| `gui/Sources/NetdiagGUI/Services/NetdiagCoordinator.swift` | Uses `ArrivalPolicy`; owns the arrival snapshot's lifetime |
| `gui/Sources/NetdiagGUI/VerifyMode.swift` | Cases for `ArrivalPolicy` and the new stage ranking |

**Phase 3 — memory (Tasks 14–19)**

| File | Responsibility |
|---|---|
| `gui/Sources/NetdiagGUI/Services/MonitorStream.swift` | Passes `--journal` when the recorder is not installed |
| `gui/Sources/NetdiagGUI/Views/SettingsView.swift` | Journal switch + delete button |
| `gui/Sources/NetdiagGUI/Views/OnboardingView.swift` | Discloses what is recorded and where |
| `gui/Sources/NetdiagGUI/Models/NetworkEpisode.swift` | **New.** `--events` decoding |
| `gui/Sources/NetdiagGUI/Services/EventsStore.swift` | **New.** Runs `--events=HOURS`, caches, exposes episodes |
| `gui/Sources/NetdiagGUI/Views/ActivityView.swift` | Episodes / All-changes segmented control, availability header |

---

## Phase 1 — CLI

### Task 1: `impacts` on catalog rules

**Files:**
- Modify: `helpers/rules_catalog.py:73` (schema), `:144` (RULES type), `:1329` (field sets), `:1343-1367` (`_validate`)
- Test: `tests/test_rules_catalog.bats`

- [ ] **Step 1: Write the failing test**

Append to `tests/test_rules_catalog.bats`:

```bash
@test "rules-catalog: schema is 5" {
  run bash "$BATS_TEST_DIRNAME/../bin/netdiag" --rules-catalog
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["schema"])')" = "5" ]
}

@test "rules-catalog: every impacts entry uses known activities and levels" {
  run bash "$BATS_TEST_DIRNAME/../bin/netdiag" --rules-catalog
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 - <<'PY'
import json, sys
ACTIVITIES = {"calls", "streaming", "gaming", "vpn", "browsing"}
LEVELS = {"degraded", "broken"}
doc = json.load(sys.stdin)
seen = 0
for r in doc["rules"]:
    imp = r.get("impacts")
    if imp is None:
        continue
    seen += 1
    assert isinstance(imp, dict), f"{r['id']}: impacts is not an object"
    assert imp, f"{r['id']}: impacts is empty — omit the key instead"
    for activity, level in imp.items():
        assert activity in ACTIVITIES, f"{r['id']}: bad activity {activity!r}"
        assert level in LEVELS, f"{r['id']}: bad level {level!r}"
assert seen >= 20, f"only {seen} rules carry impacts; expected the fault rules to"
PY
}

@test "rules-catalog: the rules that break everything say so" {
  run bash "$BATS_TEST_DIRNAME/../bin/netdiag" --rules-catalog
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 - <<'PY'
import json, sys
by_id = {r["id"]: r for r in json.load(sys.stdin)["rules"]}
# A dead connection breaks all five.
for rule in ("N1", "P1", "CP-1"):
    imp = by_id[rule].get("impacts") or {}
    assert set(imp) == {"calls", "streaming", "gaming", "vpn", "browsing"}, \
        f"{rule}: expected all five activities, got {sorted(imp)}"
    assert set(imp.values()) == {"broken"}, f"{rule}: expected all broken"
# Bufferbloat is the calls/gaming killer and only degrades streaming.
b1 = by_id["B1"]["impacts"]
assert b1["calls"] == "broken" and b1["gaming"] == "broken"
assert b1["streaming"] == "degraded"
# A clock drift has no activity consequence at all.
assert "impacts" not in by_id["NT-1"], "NT-1 should carry no impacts"
PY
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/test_rules_catalog.bats`
Expected: FAIL — schema is 4, and no rule carries `impacts`.

- [ ] **Step 3: Widen the type and the validator**

In `helpers/rules_catalog.py`, change the schema constant at line 73:

```python
SCHEMA_RULES_CATALOG = 5
```

Change the `RULES` annotation at line 144 — `impacts` is a nested object, so the
values are no longer all strings:

```python
RULES: list[dict[str, object]] = [
```

Next to `SEVERITIES` / `SCOPES` (around line 131), add the two vocabularies:

```python
# The activities `helpers/suitability.py` projects rules onto. Five, and
# closed: a sixth means a new row on every report card and in the arrival
# card, which is a product decision, not a data one.
ACTIVITIES = frozenset({"calls", "streaming", "gaming", "vpn", "browsing"})

# How badly a rule hits an activity. Deliberately two levels, not three:
# "good" is the absence of any impact, and a third middle grade would be a
# judgement about magnitude — which lives in diagnosis[].severity, decided
# against lib/thresholds.sh, and must not be re-decided here.
IMPACT_LEVELS = frozenset({"degraded", "broken"})
```

At line 1332, add `impacts` to the optional set:

```python
_OPTIONAL_FIELDS = frozenset({"also", "impacts"})
```

In `_validate` (line 1343), the `isinstance(v, str)` loop now has a non-string
field to skip. Replace the value loop and add the `impacts` check:

```python
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
```

- [ ] **Step 4: Fill in the `impacts` table**

Add an `"impacts"` key to each rule entry in `RULES` per the table below. Rules
not listed carry no `impacts` key — they have no activity consequence
(`NT-1` clock drift, `DH-1` lease expiry, `WI-1` withheld SSID, `ND-1` watcher
not running, `DQ-1` two-networks-in-one-check, `MET-1` metered, `TR-1` your own
Mac was busy, `V6-3` IPv6-only-and-fine, `VPN-1`/`VPN-2` a VPN is carrying
traffic, `ICMP-1`/`TCP-1` ping blocked but fine, `SP-1` Wi-Fi is the cap,
`WAN-1`/`WAN-1b` multi-ISP, `ETH-1`/`ETH-2` slow/half-duplex ethernet,
`BL-1` regression vs history — that last one is a comparison, and the rule
that caused the regression carries the impact itself).

`b` = `"broken"`, `d` = `"degraded"`, `–` = key absent.

| Rule | calls | streaming | gaming | vpn | browsing |
|---|---|---|---|---|---|
| `N1`, `N1b`, `N1c`, `P1`, `P2`, `D2`, `DH-3`, `DI-1`, `CP-1` | b | b | b | b | b |
| `L1` | b | b | b | b | d |
| `G2` | b | d | b | d | d |
| `L2`, `G1` | d | d | d | d | d |
| `G3` | d | – | d | – | – |
| `W1`, `W2`, `WD-1` | d | d | d | d | – |
| `WS-1` | d | d | d | – | – |
| `B1`, `B2` | b | d | b | d | – |
| `M1` | – | – | – | b | d |
| `MT1` | d | d | d | d | – |
| `D1`, `D3` | d | d | – | – | d |
| `D4` | – | – | – | d | d |
| `V6-1`, `V6-2` | – | d | – | – | d |
| `PX-1`, `FW-1` | d | – | d | d | – |
| `NAT-1`, `NAT-1b` | – | – | b | d | – |
| `DH-2` | – | – | – | d | d |
| `DI-2` | b | b | b | b | b |
| `AV-1` | b | d | b | b | d |
| `AV-2` | b | – | b | d | – |

Written as, for example, inside the `B1` entry:

```python
        "impacts": {"calls": "broken", "streaming": "degraded",
                    "gaming": "broken", "vpn": "degraded"},
```

Note the `vpn` column is `degraded` and never `broken` for `PX-1`, `FW-1`,
`NAT-1` and `NAT-1b`: those rules describe an obstacle in the path, and a path
that blocks one corporate VPN carries another fine. `M1` is the exception —
a path MTU too small to carry an encapsulated packet breaks a tunnel outright.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bats tests/test_rules_catalog.bats`
Expected: PASS, all tests.

Also run the helper directly, since `_validate`'s asserts only fire there:
Run: `NETDIAG_RULES_VERSION=test python3 helpers/rules_catalog.py | python3 -m json.tool > /dev/null && echo OK`
Expected: `OK`

- [ ] **Step 6: Commit**

```bash
git add helpers/rules_catalog.py tests/test_rules_catalog.bats
git commit -m "feat: each rule says which activities it breaks

Catalog schema 4 to 5, adding an optional per-rule impacts map over the
five activities. Nothing reads it yet; helpers/suitability.py is next.
A rule with no activity consequence omits the key rather than carrying
an empty object, so 'no consequence' and 'not classified' stay apart."
```

---

### Task 2: `fix`, `fix_away` and `fix_target` on catalog rules

**Files:**
- Modify: `helpers/rules_catalog.py` (`_FIELDS`, `_OPTIONAL_FIELDS`, `_validate`, every `RULES` entry)
- Test: `tests/test_rules_catalog.bats`

- [ ] **Step 1: Write the failing test**

Append to `tests/test_rules_catalog.bats`:

```bash
@test "rules-catalog: every rule carries a fix with a valid target" {
  run bash "$BATS_TEST_DIRNAME/../bin/netdiag" --rules-catalog
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 - <<'PY'
import json, sys
TARGETS = {"you", "your_router", "your_isp", "network_operator", "nobody"}
for r in json.load(sys.stdin)["rules"]:
    assert "fix" in r, f"{r['id']}: no fix"
    assert "fix_target" in r, f"{r['id']}: no fix_target"
    assert r["fix_target"] in TARGETS, f"{r['id']}: bad target {r['fix_target']!r}"
    assert r["fix"].strip(), f"{r['id']}: empty fix"
PY
}

@test "rules-catalog: fix_away is present exactly where the advice changes" {
  run bash "$BATS_TEST_DIRNAME/../bin/netdiag" --rules-catalog
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 - <<'PY'
import json, sys
NEEDS_AWAY = {"your_router", "network_operator"}
for r in json.load(sys.stdin)["rules"]:
    has = "fix_away" in r
    want = r["fix_target"] in NEEDS_AWAY
    assert has == want, (
        f"{r['id']}: fix_target={r['fix_target']!r} but fix_away "
        f"{'present' if has else 'absent'}"
    )
    if has:
        assert r["fix_away"].strip(), f"{r['id']}: empty fix_away"
        assert r["fix_away"] != r["fix"], f"{r['id']}: fix_away repeats fix"
PY
}

@test "rules-catalog: G2's away advice does not tell a guest to reboot a router" {
  run bash "$BATS_TEST_DIRNAME/../bin/netdiag" --rules-catalog
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 - <<'PY'
import json, sys
g2 = {r["id"]: r for r in json.load(sys.stdin)["rules"]}["G2"]
assert g2["fix_target"] == "your_router"
assert "reboot" in g2["fix"].lower() or "restart" in g2["fix"].lower()
assert "ask" in g2["fix_away"].lower()
PY
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/test_rules_catalog.bats`
Expected: FAIL — "N1: no fix".

- [ ] **Step 3: Extend the field sets and the validator**

In `helpers/rules_catalog.py`, next to `ACTIVITIES` add:

```python
# Who can actually apply the fix. `nobody` is for the rules whose honest
# advice is "there is nothing to do" (V6-3, MET-1, TR-1) — a real answer,
# and better than inventing an action to fill the field.
FIX_TARGETS = frozenset({"you", "your_router", "your_isp",
                         "network_operator", "nobody"})

# The two targets where the advice genuinely changes depending on whether
# the equipment is yours. `you` (something on this Mac) and `your_isp`
# (a phone call either way) read the same in a hotel as at home.
FIX_TARGETS_NEEDING_AWAY = frozenset({"your_router", "network_operator"})
```

At line 1329, `fix` and `fix_target` are required; `fix_away` is optional:

```python
_FIELDS = frozenset({"id", "title", "category", "severity", "scope", "blurb",
                     "doc", "fix", "fix_target"})
_OPTIONAL_FIELDS = frozenset({"also", "impacts", "fix_away"})
```

In `_validate`, after the `impacts` block from Task 1, add:

```python
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
```

- [ ] **Step 4: Write the fix prose**

Add `fix`, `fix_target` (and `fix_away` where required) to all 53 entries. The
source material is already written: most `add_diag` call sites in
`lib/diagnosis.sh` and `lib/wan.sh` end with a "Fix: …" clause. Lift the
*general* advice — no numbers, matching `blurb`'s existing discipline — and
write the away variant for `your_router` / `network_operator` rules.

Worked examples, to fix the register:

```python
    # G2 — "Router dropping packets"
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

    # B1 — "Bufferbloat at the router"
        "fix": (
            "Turn on \"Smart Queue Management\" or \"QoS\" in the router's "
            "admin page. If it has neither setting, replacing the router "
            "with one that does is the only real fix."
        ),
        "fix_away": (
            "Ask whether the network has \"Smart Queue Management\" or "
            "\"QoS\" switched on — without it, one person's download stalls "
            "everyone's calls. Until then, avoid calls while anything large "
            "is downloading."
        ),
        "fix_target": "your_router",

    # B2 — "Bufferbloat at the ISP"
        "fix": (
            "Call the ISP and ask about firmware updates for their "
            "equipment, or a plan with better latency under load. Quote the "
            "bufferbloat grade from this report — it is the number that "
            "gets the conversation past the first line of support."
        ),
        "fix_target": "your_isp",

    # W1 — "Weak WiFi signal"
        "fix": (
            "Move closer to the router, or move the router away from walls, "
            "metal and other radios. If neither is possible, a mesh node or "
            "a wired connection is the durable answer."
        ),
        "fix_target": "you",

    # NT-1 — "System clock drifted"
        "fix": (
            "Open System Settings → General → Date & Time and switch on "
            "\"Set time and date automatically\". A wrong clock breaks "
            "HTTPS, so this is worth doing before anything else in this "
            "report."
        ),
        "fix_target": "you",

    # FW-1 — "Network filtering software in the path"
        "fix": (
            "Normal on a managed network. If a VPN or a remote session will "
            "not connect, this is the first thing to suspect."
        ),
        "fix_away": (
            "Ask whether outbound VPN traffic is permitted — many guest "
            "networks allow it on request, and this is the reason a tunnel "
            "that works everywhere else fails here."
        ),
        "fix_target": "network_operator",

    # V6-3 — "This network is IPv6-only, and that is fine"
        "fix": "Nothing to do — this is a working modern setup, not a fault.",
        "fix_target": "nobody",
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bats tests/test_rules_catalog.bats`
Expected: PASS, all tests.

Run: `NETDIAG_RULES_VERSION=test python3 helpers/rules_catalog.py | python3 -m json.tool > /dev/null && echo OK`
Expected: `OK`

- [ ] **Step 6: Commit**

```bash
git add helpers/rules_catalog.py tests/test_rules_catalog.bats
git commit -m "feat: the fix, lifted out of the paragraph

Every catalog rule now carries fix, fix_target, and — where the advice
genuinely changes when the equipment is not yours — fix_away. add_diag
is untouched: this is general advice about a rule, which is what the
catalog already holds, not a fact about one incident.

'Reboot your router' is sound at home and useless in a hotel. The
target says which of the two a reader is in."
```

---

### Task 3: `helpers/suitability.py` — the projection

**Files:**
- Create: `helpers/suitability.py`
- Test: `tests/test_suitability.bats` (create)

- [ ] **Step 1: Write the failing test**

Create `tests/test_suitability.bats`:

```bash
#!/usr/bin/env bats
# The rules → activities projection. Pure Python, exercised directly:
# every case here is about the mapping, not about a probe, so nothing in
# this file runs bin/netdiag.

setup() {
  HELPERS="$BATS_TEST_DIRNAME/../helpers"
}

@test "suitability: no rules fired and everything measured is five goods" {
  run python3 - <<'PY'
import json, sys, os
sys.path.insert(0, os.environ["HELPERS"])
from suitability import project
out = project(fired=[], measured={"calls", "streaming", "gaming", "vpn", "browsing"})
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
import json, sys, os
sys.path.insert(0, os.environ["HELPERS"])
from suitability import project
# G3 degrades calls; B1 breaks them. Broken must win.
out = {e["activity"]: e for e in project(
    fired=["G3", "B1"],
    measured={"calls", "streaming", "gaming", "vpn", "browsing"})}
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
import sys, os
sys.path.insert(0, os.environ["HELPERS"])
from suitability import project
out = {e["activity"]: e for e in project(fired=[], measured={"browsing"})}
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
import sys, os
sys.path.insert(0, os.environ["HELPERS"])
from suitability import project
# N1 breaks everything, and it fires at any depth. A connection that is
# down is down whether or not the deep probes ran.
out = {e["activity"]: e for e in project(fired=["N1"], measured=set())}
assert all(e["verdict"] == "broken" for e in out.values()), out
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "suitability: an unknown rule id is ignored, not fatal" {
  run python3 - <<'PY'
import sys, os
sys.path.insert(0, os.environ["HELPERS"])
from suitability import project
# A GUI or a script may pass a rule from a newer netdiag. Ignoring it
# beats crashing the whole report.
out = {e["activity"]: e for e in project(
    fired=["ZZ-99"], measured={"calls", "streaming", "gaming", "vpn", "browsing"})}
assert all(e["verdict"] == "good" for e in out.values()), out
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "suitability: contains no numeric cutoff" {
  # The whole point of deriving from fired rules: this file judges no
  # number, so it is not a fifth thing that can disagree with
  # lib/thresholds.sh. A bare integer or float literal here is a design
  # violation, not a style one. Digits inside identifiers, docstrings and
  # comments are fine; a comparison against a literal is not.
  run python3 - <<'PY'
import ast, os, sys
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
```

Export `HELPERS` to the Python subprocesses by adding it to `setup()`:

```bash
setup() {
  HELPERS="$BATS_TEST_DIRNAME/../helpers"
  export HELPERS
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/test_suitability.bats`
Expected: FAIL — `ModuleNotFoundError: No module named 'suitability'`.

- [ ] **Step 3: Write the implementation**

Create `helpers/suitability.py`:

```python
#!/usr/bin/env python3
"""Project the rules that fired onto the activities a person cares about.

`diagnosis[]` answers "what is wrong with this network". This answers the
question a non-expert actually has, which is "will the thing I am about to
do work here" — video calls, streaming, gaming, VPN and remote access, or
ordinary browsing.

── Why this reads no metrics ──────────────────────────────────────────
Four things already judge a network — lib/diagnosis.sh, lib/monitor.sh,
helpers/history.py and helpers/summary.py — and CLAUDE.md exists to stop
them drifting apart, because the day they disagree the app shows a green
dot over a red report. A suitability layer that read bufferbloat_gw_ms for
itself would be a fifth judge, and its first disagreement would be a green
"Calls: fine" row directly above a red B1 paragraph.

So this module contains no cutoff, no threshold and no comparison against
a number. It reads which rules fired — a decision already made, once, in
lib/diagnosis.sh against lib/thresholds.sh — and maps them onto activities
through the `impacts` table in helpers/rules_catalog.py. If no rule fired,
nothing is broken. The contradiction is structurally impossible rather
than merely avoided, and tests/test_suitability.bats fails the build on a
numeric comparison appearing here.

── The three verdicts, and the fourth ─────────────────────────────────
good / degraded / broken come from the worst `impacts` level among the
rules that fired. `unmeasured` is the fourth, and it is a verdict rather
than a hidden row: `--quick` skips bufferbloat, speed, the loss probe and
the MTU probe (bin/netdiag:559 refuses `--mtu-only --quick` in as many
words), so on a quick check four of the five genuinely cannot be judged.
Rendering only the one that can would turn "we did not look" into
"nothing is wrong", which is the failure this project is organised
against.

A fired rule outranks an unmeasured dependency: a connection that is down
is down at any depth.
"""

from __future__ import annotations

try:
    from rules_catalog import RULES
except ImportError:  # pragma: no cover - direct-execution fallback
    import os
    import sys
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from rules_catalog import RULES


# Display order, which is also the order of concern for the person this is
# written for: the two that break a working day first, then the two that
# ruin an evening, then the floor case.
ACTIVITY_ORDER = ("calls", "streaming", "gaming", "vpn", "browsing")

LABELS = {
    "calls": "Video & voice calls",
    "streaming": "Streaming",
    "gaming": "Gaming",
    "vpn": "VPN & remote access",
    "browsing": "Ordinary browsing",
}

# What each activity needs measured before it can be judged clean. These
# are *measurement families*, not metric keys: the caller decides which
# families this run actually produced (see `measured_families` below), so
# the mapping from a null JSON field to a missing family lives in one
# place — helpers/emit_json.py — rather than being spread across this
# table.
DEPENDS_ON = {
    "calls": ("bufferbloat", "loss"),
    "streaming": ("speed",),
    "gaming": ("bufferbloat", "loss"),
    "vpn": ("mtu", "path"),
    "browsing": (),
}

# What to tell someone whose check did not measure a family. Phrased as
# what was not done, never as what might be wrong.
FAMILY_LABELS = {
    "bufferbloat": "latency under load",
    "loss": "the packet-loss probe",
    "speed": "the speed test",
    "mtu": "the packet-size (MTU) probe",
    "path": "the path checks",
}

# "broken" beats "degraded" beats nothing. Ranked rather than compared so
# adding a level later is a table edit, not a rewrite.
_RANK = {"good": 0, "degraded": 1, "broken": 2}
_LEVEL = {rank: level for level, rank in _RANK.items()}

_IMPACTS = {
    rule["id"]: rule.get("impacts") or {}
    for rule in RULES
}


def project(fired, measured):
    """Return the `suitability` array.

    `fired` is the rule IDs this run recorded, in any order. Unknown IDs
    are ignored rather than raising — a consumer may hold a rule from a
    newer netdiag, and losing one row's nuance beats losing the report.

    `measured` is the set of measurement-family names this run produced,
    from `DEPENDS_ON`'s vocabulary. Pass every family for a full check.
    """
    fired = list(fired)
    measured = set(measured)
    out = []
    for activity in ACTIVITY_ORDER:
        worst = 0
        because = []
        for rule in fired:
            level = _IMPACTS.get(rule, {}).get(activity)
            if level is None:
                continue
            because.append(rule)
            worst = max(worst, _RANK[level])

        missing = [f for f in DEPENDS_ON[activity] if f not in measured]
        if worst == 0 and missing:
            # Nothing fired, but we did not look hard enough to say so.
            reason = "This check didn't run " + _join(
                [FAMILY_LABELS[f] for f in missing]) + "."
            out.append({
                "activity": activity,
                "label": LABELS[activity],
                "verdict": "unmeasured",
                "because": [],
                "unmeasured_reason": reason,
            })
            continue

        out.append({
            "activity": activity,
            "label": LABELS[activity],
            "verdict": _LEVEL[worst],
            "because": because,
            "unmeasured_reason": None,
        })
    return out


def _join(parts):
    """'a', 'a and b', 'a, b and c' — an Oxford-comma-free English list."""
    if len(parts) == 1:
        return parts[0]
    return ", ".join(parts[:-1]) + " and " + parts[-1]
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/test_suitability.bats`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add helpers/suitability.py tests/test_suitability.bats
git commit -m "feat: project fired rules onto what you were trying to do

Five activities, judged from which rules fired rather than from a second
reading of the metrics. That is the whole design: a layer that read
bufferbloat_gw_ms for itself would be a fifth judge next to diagnosis.sh,
monitor.sh, history.py and summary.py, and its first disagreement would
be a green 'Calls: fine' row above a red B1 paragraph.

The test suite fails the build on a numeric comparison in this file."
```

---

### Task 4: `suitability` in `--json`

**Files:**
- Modify: `helpers/emit_json.py:638` (document assembly), plus a new `build_suitability()` beside `build_diagnosis()` at `:165`
- Test: `tests/test_json.bats`

- [ ] **Step 1: Write the failing test**

Append to `tests/test_json.bats`:

```bash
@test "json: a quick run carries five suitability rows" {
  run bash "$BATS_TEST_DIRNAME/../bin/netdiag" --quick --json
  [ "$status" -le 2 ]
  printf '%s' "$output" | python3 - <<'PY'
import json, sys
d = json.load(sys.stdin)
s = d["suitability"]
assert [e["activity"] for e in s] == \
    ["calls", "streaming", "gaming", "vpn", "browsing"], s
for e in s:
    assert e["verdict"] in {"good", "degraded", "broken", "unmeasured"}, e
    assert e["label"], e
    assert isinstance(e["because"], list), e
    if e["verdict"] == "unmeasured":
        assert e["unmeasured_reason"], e
    else:
        assert e["unmeasured_reason"] is None, e
PY
}

@test "json: a quick run cannot judge calls, and says so" {
  run bash "$BATS_TEST_DIRNAME/../bin/netdiag" --quick --json
  [ "$status" -le 2 ]
  printf '%s' "$output" | python3 - <<'PY'
import json, sys
d = json.load(sys.stdin)
by = {e["activity"]: e for e in d["suitability"]}
fired = {x["rule"] for x in d["diagnosis"] if x.get("rule")}
# On a healthy quick check nothing has fired that breaks calls, and the
# bufferbloat probe did not run — so the row must be honest about it
# rather than reporting a clean bill of health nobody measured.
if not (fired & {"N1", "N1b", "N1c", "P1", "P2", "L1", "G2", "CP-1"}):
    assert by["calls"]["verdict"] == "unmeasured", by["calls"]
    assert "latency under load" in by["calls"]["unmeasured_reason"], by["calls"]
PY
}

@test "json: suitability never contradicts the diagnosis" {
  run bash "$BATS_TEST_DIRNAME/../bin/netdiag" --quick --json
  [ "$status" -le 2 ]
  printf '%s' "$output" | python3 - <<'PY'
import json, sys
d = json.load(sys.stdin)
fired = {x["rule"] for x in d["diagnosis"] if x.get("rule")}
for e in d["suitability"]:
    # Every rule cited must actually have fired in this run.
    assert set(e["because"]) <= fired, (e, sorted(fired))
    # And a non-good verdict must cite something.
    if e["verdict"] in {"degraded", "broken"}:
        assert e["because"], e
PY
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/test_json.bats`
Expected: FAIL — `KeyError: 'suitability'`.

- [ ] **Step 3: Write the implementation**

In `helpers/emit_json.py`, after `build_diagnosis()` (which ends at line 188),
add:

```python
def measured_families(data: dict) -> set[str]:
    """Which measurement families this run actually produced.

    The rule is the schema's own contract, stated at docs/JSON-SCHEMA.md's
    `internet_latency` row: a field is `null` when its probe did not run,
    never `0` and never `100`. So "did we measure it" is exactly "is the
    value non-null", read here from the document already assembled rather
    than from a second pass over the environment — one source, and it
    cannot drift from what the report shows.
    """
    families: set[str] = set()
    bb = data.get("bufferbloat") or {}
    if bb.get("gateway_delta_ms") is not None or \
            bb.get("internet_delta_ms") is not None:
        families.add("bufferbloat")
    inet = data.get("internet_latency") or {}
    if inet.get("loss_pct") is not None:
        families.add("loss")
    if (data.get("speedtest") or {}).get("down_mbps") is not None:
        families.add("speed")
    if (data.get("mtu") or {}).get("effective") is not None:
        families.add("mtu")
    # "path" is the topology/filtering family — traceroute plus the proxy
    # and filtering probes. Present at every depth that reaches the
    # public internet, which is why `vpn` is judgeable more often than
    # `calls` is.
    if data.get("wan") is not None:
        families.add("path")
    return families


def build_suitability(data: dict) -> list[dict]:
    """The `suitability` array — see helpers/suitability.py's header.

    Takes the assembled document rather than the environment so the fired
    rules it projects are exactly the ones `diagnosis` reports. Reading
    NETDIAG_DIAGNOSIS_LINES a second time would let the two lists drift
    apart on any future change to build_diagnosis's parsing.
    """
    from suitability import project
    fired = [d["rule"] for d in data.get("diagnosis", []) if d.get("rule")]
    return project(fired=fired, measured=measured_families(data))
```

`helpers/` is already on `sys.path` for a helper invoked as
`python3 "$HELPERS_DIR/emit_json.py"`, so the plain `from suitability import
project` resolves. Keep it inside the function so a syntax error in
`suitability.py` cannot stop `--json` from loading at all.

Then, in `main()`, immediately after the `data = { … }` literal closes (line
659, the `}` before `if _bool("REDACT"):`) and *before* the redaction branch,
insert:

```python
    # After the literal, because it reads `data["diagnosis"]`; before
    # redaction, because redaction walks the finished document and there is
    # no reason for this block to be the one thing it never sees. Nothing
    # in `suitability` is identifying — rule IDs and fixed labels — so
    # redact() passes it through unchanged either way.
    data["suitability"] = build_suitability(data)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/test_json.bats`
Expected: PASS.

Confirm the whole document still parses:
Run: `bash bin/netdiag --quick --json | jq -e '.suitability | length == 5' > /dev/null && echo OK`
Expected: `OK`

- [ ] **Step 5: Run the full suite**

Run: `bats tests/`
Expected: PASS. Per the project's own note, bats is fully green — any failure here is a real regression, not a flake.

- [ ] **Step 6: Commit**

```bash
git add helpers/emit_json.py tests/test_json.bats
git commit -m "feat: --json answers what this network is good for

suitability[] sits next to diagnosis[] and is built from it, so the rules
it cites are by construction the rules that fired. measured_families
reads the assembled document rather than the environment for the same
reason: one source, no drift between what the report shows and what the
verdict claims was measured."
```

---

### Task 5: The five rows in the human-readable report

**Files:**
- Modify: `lib/output.sh`
- Test: `tests/test_output.bats`

- [ ] **Step 1: Write the failing test**

Append to `tests/test_output.bats`:

```bash
@test "output: the text report has a suitability section" {
  run bash "$BATS_TEST_DIRNAME/../bin/netdiag" --quick
  [ "$status" -le 2 ]
  stripped=$(printf '%s' "$output" | sed $'s/\x1b\\[[0-9;]*[mK]//g')
  printf '%s' "$stripped" | grep -q "WHAT SHOULD WORK HERE"
  printf '%s' "$stripped" | grep -q "Video & voice calls"
  printf '%s' "$stripped" | grep -q "Ordinary browsing"
}

@test "output: an unmeasured row says what was not run" {
  run bash "$BATS_TEST_DIRNAME/../bin/netdiag" --quick
  [ "$status" -le 2 ]
  stripped=$(printf '%s' "$output" | sed $'s/\x1b\\[[0-9;]*[mK]//g')
  # A quick check never runs the speed test, so streaming cannot be judged.
  printf '%s' "$stripped" | grep -q "not measured"
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/test_output.bats`
Expected: FAIL — no "WHAT SHOULD WORK HERE" in the output.

- [ ] **Step 3: Write the implementation**

`lib/output.sh` already builds the JSON document for the private history
record; reuse that rather than re-deriving. Add a rendering function that
shells out to the same helper the JSON path uses, and call it from the report
body immediately **before** the Diagnosis section (the activity summary is the
headline a non-expert reads; the rule-by-rule detail follows it):

```bash
# ── What this network is good for ────────────────────────────────────────
# Renders helpers/suitability.py's projection. Prints nothing and returns 0
# when the helper fails or python3 is missing: a report that loses one
# section is better than a report that does not print.
#
# Deliberately not a verdict authored here. The labels, the ordering and
# the "not measured" reasons all come out of the helper; this function
# chooses a colour per verdict and nothing else.
output_suitability() {
  local json
  json=$(NETDIAG_DIAGNOSIS_LINES="$(printf '%s\n' "${DIAG_SEV[@]+"${_diag_lines[@]}"}")" \
         true 2>/dev/null; build_suitability_json) || return 0
  [ -n "$json" ] || return 0

  section "WHAT SHOULD WORK HERE"
  printf '%s' "$json" | python3 - <<'PY'
import json, sys
rows = json.load(sys.stdin)
GLYPH = {"good": "OK", "degraded": "!!", "broken": "XX", "unmeasured": "--"}
WORD = {"good": "fine", "degraded": "rough",
        "broken": "won't hold up", "unmeasured": "not measured"}
for r in rows:
    detail = r["unmeasured_reason"] or (
        "because " + ", ".join(r["because"]) if r["because"] else "")
    print(f"  [{GLYPH[r['verdict']]}] {r['label']:<22} {WORD[r['verdict']]}")
    if detail:
        print(f"       {detail}")
PY
}
```

`build_suitability_json` is the one-line bridge to the helper, placed beside
the existing `build_json_private` in the same file so both JSON producers sit
together:

```bash
# The suitability array alone, for the text report. Reuses the same
# document build the --json path uses so the text report and the JSON can
# never disagree about a verdict — the same reason build_json_private
# exists rather than a second hand-rolled record.
build_suitability_json() {
  build_json | python3 -c 'import json,sys; json.dump(json.load(sys.stdin)["suitability"], sys.stdout)'
}
```

Replace the placeholder body of `output_suitability` above with the simple
form once `build_suitability_json` exists — the environment juggling in the
first sketch is unnecessary:

```bash
output_suitability() {
  local json
  json=$(build_suitability_json 2>/dev/null) || return 0
  [ -n "$json" ] || return 0
  section "WHAT SHOULD WORK HERE"
  printf '%s' "$json" | python3 - <<'PY'
import json, sys
rows = json.load(sys.stdin)
GLYPH = {"good": "OK", "degraded": "!!", "broken": "XX", "unmeasured": "--"}
WORD = {"good": "fine", "degraded": "rough",
        "broken": "won't hold up", "unmeasured": "not measured"}
for r in rows:
    detail = r["unmeasured_reason"] or (
        "because " + ", ".join(r["because"]) if r["because"] else "")
    print(f"  [{GLYPH[r['verdict']]}] {r['label']:<22} {WORD[r['verdict']]}")
    if detail:
        print(f"       {detail}")
PY
}
```

Then call it from the report body, on the line immediately before the existing
Diagnosis section call.

Find the existing `section` helper's exact name and signature in `lib/output.sh`
before writing this — the file already has one, and this must use it rather
than printing its own header, so the new section matches every other one.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/test_output.bats`
Expected: PASS.

- [ ] **Step 5: shellcheck**

Run: `shellcheck lib/output.sh`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add lib/output.sh tests/test_output.bats
git commit -m "feat: the text report leads with what should work

Five rows above the diagnosis list, built from the same document the
--json path emits so the two can never disagree. The section prints
nothing rather than failing the run if python3 is unavailable."
```

---

### Task 6: Document it, and re-capture the samples

**Files:**
- Modify: `docs/JSON-SCHEMA.md`, `docs/DIAGNOSIS-RULES.md`, `CHANGELOG.md`
- Modify: `examples/sample-output.txt`, `examples/sample-output.json`

- [ ] **Step 1: Document the `suitability` block**

In `docs/JSON-SCHEMA.md`, add a row to the top-level field table next to
`diagnosis` (line 61):

```markdown
| `suitability` | array | one entry per activity — `activity`, `label`, `verdict` (`good`/`degraded`/`broken`/`unmeasured`), `because` (rule IDs), `unmeasured_reason`. Five entries, in a fixed order, always present. |
```

Then add a prose section after the `diagnosis` discussion:

```markdown
### `suitability` — what this network is good for

Five activities: `calls`, `streaming`, `gaming`, `vpn`, `browsing`, always in
that order, always all five present.

**It is a projection of `diagnosis`, not a second opinion.** The verdict is the
worst `impacts` level among the rules that actually fired, read from the
`impacts` table in `--rules-catalog`. `helpers/suitability.py` contains no
cutoff and no numeric comparison — `tests/test_suitability.bats` fails the
build if one appears — so it is not a fifth judge next to `lib/diagnosis.sh`,
`lib/monitor.sh`, `helpers/history.py` and `helpers/summary.py`, and it cannot
report a healthy activity above a firing rule that breaks it.

`because` lists the rule IDs that decided the verdict, and is a subset of the
rules in `diagnosis[]` by construction. A `good` verdict has an empty
`because`: nothing fired.

`unmeasured` is a verdict, not an omission. `--quick` skips bufferbloat, the
speed test, the loss probe and the MTU probe, so four of the five activities
cannot be judged on a quick check; the rows still appear, with
`unmeasured_reason` naming what was not run. A rule that fired outranks this —
a connection that is down is down at any depth.
```

Document the new `--rules-catalog` fields (`impacts`, `fix`, `fix_away`,
`fix_target`) in that schema's own field list, and bump the stated schema
number from 4 to 5 in its opening paragraph.

- [ ] **Step 2: Document the rule → activity mapping**

In `docs/DIAGNOSIS-RULES.md`, add a short section near the top explaining that
each rule now declares which activities it affects, that the table lives in
`helpers/rules_catalog.py`'s `RULES`, and that `broken` versus `degraded` means
"this will not work" versus "this will be unpleasant" — not a magnitude, which
stays in `diagnosis[].severity`.

- [ ] **Step 3: Re-capture the samples**

Per CLAUDE.md these must be real captures, taken with `--redact`, from stdout —
capturing via `--log` yields an unredacted file that looks like it worked:

```bash
bash bin/netdiag --redact --json > examples/sample-output.json
bash bin/netdiag --redact | sed $'s/\x1b\\[[0-9;]*[mK]//g' > examples/sample-output.txt
```

- [ ] **Step 4: Verify the samples are actually redacted**

Run: `grep -c "$(ipconfig getifaddr en0)" examples/sample-output.json || echo "no local IP leaked"`
Expected: `no local IP leaked`

Run: `jq -e '.suitability | length == 5' examples/sample-output.json > /dev/null && echo OK`
Expected: `OK`

Check by eye that no public IPv6 address or city name appears in either file.
The ISP name is kept by design (`helpers/emit_json.py`'s `_REDACT_ENV`
deliberately excludes it).

- [ ] **Step 5: CHANGELOG**

Add an `### Added` entry under `## [Unreleased]` describing the block, the
catalog fields, and the design decision that suitability adds no thresholds.

- [ ] **Step 6: Commit**

```bash
git add docs/JSON-SCHEMA.md docs/DIAGNOSIS-RULES.md CHANGELOG.md examples/
git commit -m "docs: document suitability and the catalog's fix fields

Samples re-captured with --redact from stdout, per CLAUDE.md — the log
path keeps full detail on purpose and would have produced an unredacted
file that looked correct."
```

---

## Phase 2 — the arrival moment

### Task 7: Decode `suitability` and the new catalog fields

**Files:**
- Modify: `gui/Sources/NetdiagGUI/Models/RunSnapshot.swift`, `gui/Sources/NetdiagGUI/Models/RulesCatalog.swift`
- Test: `gui/Sources/NetdiagGUI/VerifyMode.swift`

- [ ] **Step 1: Write the failing verify case**

Read `VerifyMode.swift`'s existing scenario structure first and follow it. Add a
case that decodes a fixture and asserts the shape:

```swift
// Suitability decodes, including the unmeasured case, and an older CLI
// that emits no `suitability` key at all decodes as an empty array
// rather than failing the whole run — the same lenient stance every
// other optional block in RunSnapshot takes.
check("suitability decodes with unmeasured rows") {
    let json = """
    {"suitability":[
      {"activity":"calls","label":"Video & voice calls","verdict":"unmeasured",
       "because":[],"unmeasured_reason":"This check didn't run latency under load."},
      {"activity":"browsing","label":"Ordinary browsing","verdict":"good",
       "because":[],"unmeasured_reason":null}]}
    """.data(using: .utf8)!
    let rows = try JSONDecoder().decode(SuitabilityEnvelope.self, from: json).suitability
    expect(rows.count == 2)
    expect(rows[0].verdict == .unmeasured)
    expect(rows[0].unmeasuredReason?.isEmpty == false)
    expect(rows[1].verdict == .good)
    expect(rows[1].unmeasuredReason == nil)
}

check("a report with no suitability key decodes as empty") {
    let json = "{}".data(using: .utf8)!
    let rows = try JSONDecoder().decode(SuitabilityEnvelope.self, from: json).suitability
    expect(rows.isEmpty)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd gui && make build && ./.build/debug/NetdiagGUI --verify`
Expected: FAIL — `SuitabilityEnvelope` undefined.

- [ ] **Step 3: Write the model**

Add to `RunSnapshot.swift`:

```swift
/// One activity's verdict, as `helpers/suitability.py` emitted it.
///
/// Nothing here decides anything. The verdict, the label, the reason and
/// the ordering all arrive from the CLI; this type carries them and the
/// views render them. Per CLAUDE.md the GUI holds no diagnostic logic,
/// and "will video calls work here" is the most diagnostic claim in the
/// whole app — so it is authored in exactly one place, and this is not it.
struct SuitabilityRow: Decodable, Sendable, Identifiable, Equatable {
    enum Verdict: String, Decodable, Sendable {
        case good, degraded, broken, unmeasured
    }

    let activity: String
    let label: String
    let verdict: Verdict
    /// Rule IDs that decided this verdict — a subset of the run's
    /// `diagnosis[].rule` by construction. Empty for `good`.
    let because: [String]
    let unmeasuredReason: String?

    var id: String { activity }

    enum CodingKeys: String, CodingKey {
        case activity, label, verdict, because
        case unmeasuredReason = "unmeasured_reason"
    }
}

/// Decoding shim so a fixture — and `VerifyMode` — can exercise the array
/// without constructing a whole `RunSnapshot`.
struct SuitabilityEnvelope: Decodable, Sendable {
    let suitability: [SuitabilityRow]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // An older netdiag emits no `suitability` key. Empty, not a
        // throw: a missing block must degrade one panel, never the run.
        suitability = (try? c.decode([SuitabilityRow].self, forKey: .suitability)) ?? []
    }

    enum CodingKeys: String, CodingKey { case suitability }
}
```

Add `var suitability: [SuitabilityRow] = []` to `RunSnapshot` itself, following
the file's existing lenient-decoding pattern (see `LenientDecoding.swift`) so a
malformed row drops that row rather than the report.

In `RulesCatalog.swift`, add to the rule entry type:

```swift
    /// Advice for when the equipment is yours. Always present from a
    /// schema-5 catalog; optional here because an older bundled CLI has
    /// none, and a nil fix must hide the box rather than show an empty one.
    let fix: String?
    /// Advice for when it is not. Present only on `your_router` and
    /// `network_operator` rules — the two targets where "reboot it"
    /// versus "ask them to reboot it" is a different sentence.
    let fixAway: String?
    /// `you` | `your_router` | `your_isp` | `network_operator` | `nobody`.
    let fixTarget: String?
```

with the matching `CodingKeys` (`fix_away` → `fixAway`, `fix_target` →
`fixTarget`) and `decodeIfPresent` for all three.

- [ ] **Step 4: Run to verify it passes**

Run: `cd gui && make build && ./.build/debug/NetdiagGUI --verify`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add gui/Sources/NetdiagGUI/Models/RunSnapshot.swift \
        gui/Sources/NetdiagGUI/Models/RulesCatalog.swift \
        gui/Sources/NetdiagGUI/VerifyMode.swift
git commit -m "feat(gui): decode suitability rows and catalog fix fields

Both decode leniently: a report from an older bundled CLI has neither,
and a missing block must cost one panel rather than the whole run."
```

---

### Task 8: `SuitabilityPanel`

**Files:**
- Modify: `gui/Sources/NetdiagGUI/Views/Components.swift`
- Modify: `gui/Sources/NetdiagGUI/Views/RunReportView.swift`

- [ ] **Step 1: Write the view**

Add to `Components.swift` — shared, because the report and the dropdown's
arrival card must render a verdict identically or the app contradicts itself
between two surfaces the user sees seconds apart (the same reason
`SignalScale.cellContent` and `AlertStageCard` are shared):

```swift
/// The five activity rows. Renders `SuitabilityRow` and composes no
/// sentence of its own: `label`, the reason and the ordering are all the
/// CLI's. The only thing decided here is which colour and glyph a verdict
/// draws — the same latitude Theme gives every other severity.
struct SuitabilityPanel: View {
    let rows: [SuitabilityRow]
    /// Compact drops the per-row reason line — the dropdown is 360pt wide
    /// and the arrival card has a fix and a memory line under it.
    var compact: Bool = false

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("What should work here")
                    .font(.headline)
                    .padding(.bottom, Theme.Spacing.sm)
                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                        Image(systemName: symbol(row.verdict))
                            .foregroundStyle(tint(row.verdict))
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.label)
                            if !compact, let detail = detail(row) {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: Theme.Spacing.sm)
                        Text(word(row.verdict))
                            .font(.callout.weight(.medium))
                            .foregroundStyle(tint(row.verdict))
                    }
                    .padding(.vertical, 4)
                    if row.id != rows.last?.id { Divider() }
                }
            }
        }
    }

    /// The reason under a row: the CLI's own sentence when a measurement
    /// was skipped, and otherwise the rule IDs that decided it — never a
    /// sentence composed here about what is wrong.
    private func detail(_ row: SuitabilityRow) -> String? {
        if let reason = row.unmeasuredReason { return reason }
        guard !row.because.isEmpty else { return nil }
        return "because " + row.because.sorted().joined(separator: ", ")
    }

    // Colour is never the only signal — the four symbols differ in shape
    // too, the same rule MenuBarLabel.dot follows.
    private func symbol(_ v: SuitabilityRow.Verdict) -> String {
        switch v {
        case .good:       return "checkmark.circle.fill"
        case .degraded:   return "exclamationmark.triangle.fill"
        case .broken:     return "xmark.octagon.fill"
        case .unmeasured: return "minus.circle"
        }
    }

    private func tint(_ v: SuitabilityRow.Verdict) -> Color {
        switch v {
        case .good:       return .green
        case .degraded:   return .orange
        case .broken:     return .red
        case .unmeasured: return .secondary
        }
    }

    private func word(_ v: SuitabilityRow.Verdict) -> String {
        switch v {
        case .good:       return "Fine"
        case .degraded:   return "Rough"
        case .broken:     return "Won't hold up"
        case .unmeasured: return "Not measured"
        }
    }
}
```

The four words are category labels for a verdict the CLI already made — the
same latitude `AlertDefinition.title` takes ("two or three words naming which
of twelve things happened; that is navigation, not diagnosis"). They must not
grow into sentences about the network.

- [ ] **Step 2: Mount it in the report**

In `RunReportView.swift`, render `SuitabilityPanel(rows: snapshot.suitability)`
inside a `.cardStyle()` container immediately above the existing diagnosis
list. Above, not below: the activity summary is what a non-expert reads, and
the rule-by-rule detail is the expert's follow-up.

- [ ] **Step 3: Build and look at it**

Run: `cd gui && make build && ./.build/debug/NetdiagGUI --verify`
Expected: PASS.

Then run the app against a real check and confirm the panel appears with five
rows. Per the project's own testing note, drive it with a CLI shim via
`netdiagBinaryPath` rather than pointing it at `~/Documents`.

- [ ] **Step 4: Commit**

```bash
git add gui/Sources/NetdiagGUI/Views/Components.swift \
        gui/Sources/NetdiagGUI/Views/RunReportView.swift
git commit -m "feat(gui): the report leads with what should work here

Shared component, because the arrival card renders the same five rows
seconds earlier and the two must not describe a verdict differently."
```

---

### Task 9: The fix box, aimed at whoever can apply it

**Files:**
- Modify: `gui/Sources/NetdiagGUI/Support/Defaults.swift`, `gui/Sources/NetdiagGUI/Services/HistoryStore.swift`, `gui/Sources/NetdiagGUI/Views/NetworksView.swift`, `gui/Sources/NetdiagGUI/Views/RunReportView.swift`

- [ ] **Step 1: Add the ownership flag**

`HistoryDocument.Network` is decoded from `--history` output, so this cannot
live there — the CLI does not emit it. It goes where the rename and merge
overrides already live, in `Defaults`:

```swift
        static let networkOwned       = "networkOwned"
```

```swift
    /// Network IDs the user has said they control the equipment on.
    ///
    /// Default empty, and deliberately not inferred from visit count: a
    /// daily office is visited more often than a home and is not yours,
    /// and a holiday flat is yours for a week. A wrong guess here produces
    /// confidently wrong instructions ("reboot your router" to a hotel
    /// guest), which is worse than the merely redundant default ("ask
    /// whoever runs this network" at home).
    static var networkOwned: Set<String> {
        get { Set(d.stringArray(forKey: Keys.networkOwned) ?? []) }
        set { d.set(Array(newValue).sorted(), forKey: Keys.networkOwned) }
    }
```

In `HistoryStore`, add the accessors next to the existing rename ones:

```swift
    func isOwned(networkID: String) -> Bool {
        Defaults.networkOwned.contains(networkID)
    }

    func setOwned(_ owned: Bool, for networkID: String) {
        var set = Defaults.networkOwned
        if owned { set.insert(networkID) } else { set.remove(networkID) }
        Defaults.networkOwned = set
    }
```

- [ ] **Step 2: Add the toggle to the Networks detail pane**

In `NetworksView.swift`'s right-hand detail column, beside the rename and merge
controls:

```swift
Toggle("I control the equipment on this network", isOn: Binding(
    get: { store.isOwned(networkID: network.id) },
    set: { store.setOwned($0, for: network.id) }))
.help("Turn this on for your home or anywhere you can reach the router. "
      + "It changes the advice netdiag gives from “ask whoever runs this "
      + "network” to instructions you can follow yourself.")
```

- [ ] **Step 3: Render the fix under each diagnosis**

In `RunReportView.swift`, under each diagnosis row, add a box that reads the
catalog entry for that rule:

```swift
/// The fix for one rule, aimed at whoever can actually apply it.
///
/// Both sentences are the CLI's — `fix` and `fix_away` from
/// `--rules-catalog`. This view's entire contribution is choosing between
/// them using one non-diagnostic fact the app owns: whether the user has
/// said they control this network's equipment. It composes neither, and
/// must not start.
struct FixBox: View {
    let rule: RulesCatalog.Rule
    let networkIsOwned: Bool

    var body: some View {
        if let text = resolved {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("What to do")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if let chip = targetChip {
                        Text(chip)
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.secondary.opacity(0.15), in: Capsule())
                    }
                }
                Text(text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(Theme.cardOpacity),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        }
    }

    /// `fix_away` only where the catalog actually carries one — the CLI
    /// emits it exactly for `your_router` and `network_operator`, so a nil
    /// here means the advice does not change and `fix` is correct in both
    /// situations.
    private var resolved: String? {
        if !networkIsOwned, let away = rule.fixAway { return away }
        return rule.fix
    }

    /// Who the advice is aimed at. `nobody` shows no chip: "there is
    /// nothing to do" needs no addressee.
    private var targetChip: String? {
        switch rule.fixTarget {
        case "you":              return "you"
        case "your_router":      return networkIsOwned ? "your router" : "this network's staff"
        case "your_isp":         return "your ISP"
        case "network_operator": return "this network's staff"
        default:                 return nil
        }
    }
}
```

- [ ] **Step 4: Build and verify**

Run: `cd gui && make build && ./.build/debug/NetdiagGUI --verify`
Expected: PASS.

Then, in the running app: toggle "I control the equipment on this network" for
the current network and confirm a `G2`-class finding's advice changes between
"Reboot the router…" and "Ask whoever runs this network…".

- [ ] **Step 5: Commit**

```bash
git add gui/Sources/NetdiagGUI/Support/Defaults.swift \
        gui/Sources/NetdiagGUI/Services/HistoryStore.swift \
        gui/Sources/NetdiagGUI/Views/NetworksView.swift \
        gui/Sources/NetdiagGUI/Views/RunReportView.swift
git commit -m "feat(gui): advice aimed at whoever can act on it

One per-network flag, default off, never inferred from visit count. Both
sentences come from the catalog; the app only picks between them."
```

---

### Task 10: `ArrivalPolicy`

**Files:**
- Create: `gui/Sources/NetdiagGUI/Support/ArrivalPolicy.swift`
- Modify: `gui/Sources/NetdiagGUI/VerifyMode.swift`

- [ ] **Step 1: Write the failing verify cases**

```swift
check("a never-seen network earns a full check") {
    expect(ArrivalPolicy.depth(seenBefore: false, severity: "ok") == .full)
}

check("a familiar network gets a quick check, every time") {
    expect(ArrivalPolicy.depth(seenBefore: true, severity: "ok") == .quick)
}

check("a struggling link is never saturated on arrival") {
    // FullCheckPolicy's rule, extended to the automatic path: the user
    // did not ask for this check, so the app has even less licence to
    // make a bad connection worse for ten seconds.
    expect(ArrivalPolicy.depth(seenBefore: false, severity: "critical") == .alertTriggered)
    expect(ArrivalPolicy.depth(seenBefore: true, severity: "critical") == .alertTriggered)
}

check("an unknown severity is not treated as safe") {
    // Same allow-list stance as FullCheckPolicy: an empty severity is
    // what a fresh launch has before the first sample lands.
    expect(ArrivalPolicy.depth(seenBefore: false, severity: "") == .alertTriggered)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd gui && make build && ./.build/debug/NetdiagGUI --verify`
Expected: FAIL — `ArrivalPolicy` undefined.

- [ ] **Step 3: Write it**

```swift
import Foundation

/// Which depth to run when the Mac joins a network.
///
/// Replaces the old rule, which was "run one full check the first time
/// this app ever sees a network, and never again"
/// (`NetdiagCoordinator.handleSample`, `Defaults.seenNetworks`). That
/// rule left a returning traveller with nothing: come back to the same
/// hotel a year later and the app re-checks nothing, because the network
/// is still in a set that is never pruned.
///
/// The set survives, demoted. It now decides *depth*, not *whether*.
///
/// Pure, and deliberately not a method on the coordinator: `VerifyMode`
/// is the only runnable harness on this toolchain and it cannot construct
/// a coordinator. Same shape and same reason as `FullCheckPolicy` and
/// `StageResolver`.
enum ArrivalPolicy {

    static func depth(seenBefore: Bool, severity: String) -> NetdiagRunner.Depth {
        // The safety rule wins over the depth rule. `FullCheckPolicy`
        // exists because the bufferbloat probe deliberately saturates the
        // link for ~10 s, and doing that to a connection already
        // reporting critical makes the user's actual problem worse. That
        // reasoning is stronger here than it is for the button, because
        // nobody asked for this check.
        guard FullCheckPolicy.isSafe(severity: severity) else {
            return .alertTriggered
        }
        // A first sighting is exactly when a throughput / bufferbloat /
        // MTU baseline is worth having — there is nothing stored to
        // compare against yet, and this is the one chance to take it
        // while the user is not waiting on it.
        return seenBefore ? .quick : .full
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd gui && make build && ./.build/debug/NetdiagGUI --verify`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add gui/Sources/NetdiagGUI/Support/ArrivalPolicy.swift \
        gui/Sources/NetdiagGUI/VerifyMode.swift
git commit -m "feat(gui): decide arrival depth in one testable place

Never seen means full; seen means quick, every rejoin; an unhealthy or
unknown severity means lighter, because nobody asked for this check and
saturating a struggling link is the one thing the app must not do."
```

---

### Task 11: The coordinator uses it

**Files:**
- Modify: `gui/Sources/NetdiagGUI/Services/NetdiagCoordinator.swift:291-328`

- [ ] **Step 1: Replace the guard with the policy**

The existing block returns early unless the network is unseen. Replace it so
every network change runs *something*, at the depth the policy picks:

```swift
        guard Defaults.scanOnNewNetwork else { return }
        let seenBefore = Defaults.seenNetworks.contains(id)
        let depth = ArrivalPolicy.depth(
            seenBefore: seenBefore,
            severity: monitor.latest?.status.severity ?? "")
        log.info("arrived on \(id, privacy: .public) — running \(String(describing: depth), privacy: .public)")

        // `seenNetworks` is still written only after the scan reports it
        // actually started (NET.3), and for the same reason as before:
        // `launch()` silently no-ops when a scan is already in flight, and
        // marking a network seen ahead of an attempt that never ran burns
        // its one automatic full baseline permanently — nothing retries a
        // network already in this set. Both calls run synchronously up to
        // the point the scan's Task is handed to `scanTask`, so no `await`
        // separates "did it start?" from "mark it seen".
        guard runScan(depth: depth, reason: "arrived on a network") else {
            log.debug("arrival scan for \(id, privacy: .public) declined — a scan is already running; left unseen so the next sighting retries")
            return
        }
        if !seenBefore {
            var seen = Defaults.seenNetworks
            seen.insert(id)
            Defaults.seenNetworks = seen
        }
```

Check `runScan`'s actual signature before writing this: the existing call site
uses `coordinator.runScan(depth:reason:)` and `runFullCheck(reason:)` returns
`Bool`. If `runScan` returns `Void`, add a `@discardableResult` `Bool` return
mirroring `runFullCheck`'s — the "did it actually start" answer is what the
`seenNetworks` write depends on, and guessing it is exactly the bug the
existing comment at `:312-321` was written to prevent.

- [ ] **Step 2: Verify the roam case does not trigger it**

This block already sits behind `guard id != lastNetworkID else { return }` at
`:292`, and `id` is `sample.network.historyJoinID` — a roam between two access
points on one SSID does not change it. Confirm by reading those three lines;
add no new guard. A check on every BSSID change would be a probe loop on any
large site.

- [ ] **Step 3: Build and verify**

Run: `cd gui && make build && ./.build/debug/NetdiagGUI --verify`
Expected: PASS.

Then, in the running app: join a known network and confirm from the log that a
`quick` check runs — previously nothing did.

- [ ] **Step 4: Commit**

```bash
git add gui/Sources/NetdiagGUI/Services/NetdiagCoordinator.swift
git commit -m "fix(gui): a familiar network is checked again when you rejoin

Previously one full check per network for the life of the install, so
returning to a hotel a year later re-checked nothing. Now every arrival
runs something; seenNetworks decides the depth rather than whether."
```

---

### Task 12: The `.arrived` stage

**Files:**
- Modify: `gui/Sources/NetdiagGUI/Support/StageResolver.swift`, `gui/Sources/NetdiagGUI/Views/DropdownView.swift`, `gui/Sources/NetdiagGUI/Services/NetdiagCoordinator.swift`
- Modify: `gui/Sources/NetdiagGUI/VerifyMode.swift`

- [ ] **Step 1: Write the failing verify cases**

```swift
check("an arrival shows above healthy") {
    let stage = StageResolver.resolve(.init(
        isScanning: false, monitoringEnabled: true, isPausedForAnyReason: false,
        pauseReason: nil, lastError: nil, monitorRunning: true, activeAlert: nil,
        severity: "ok", linkUp: true, measurementState: "measured",
        arrival: .init(networkName: "Hilton_Guest", joinedAt: .now)))
    guard case .arrived(let a) = stage else { return fail("expected .arrived") }
    expect(a.networkName == "Hilton_Guest")
}

check("an active alert outranks an arrival") {
    // An alert is a problem happening now; an arrival summary is context.
    let stage = StageResolver.resolve(.init(
        isScanning: false, monitoringEnabled: true, isPausedForAnyReason: false,
        pauseReason: nil, lastError: nil, monitorRunning: true,
        activeAlert: .init(title: "No internet connection", body: "…",
                           raisedAt: .now, rules: ["N1"], severityRank: 3),
        severity: "critical", linkUp: true, measurementState: "measured",
        arrival: .init(networkName: "Hilton_Guest", joinedAt: .now)))
    guard case .alerted = stage else { return fail("expected .alerted") }
}

check("a scan in progress still outranks an arrival") {
    // The arrival's own check is the scan that is running; showing a
    // finished-looking card over a check still in flight would report a
    // verdict that does not exist yet.
    let stage = StageResolver.resolve(.init(
        isScanning: true, monitoringEnabled: true, isPausedForAnyReason: false,
        pauseReason: nil, lastError: nil, monitorRunning: true, activeAlert: nil,
        severity: "ok", linkUp: true, measurementState: "measured",
        arrival: .init(networkName: "Hilton_Guest", joinedAt: .now)))
    guard case .testing = stage else { return fail("expected .testing") }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd gui && make build && ./.build/debug/NetdiagGUI --verify`
Expected: FAIL — `Inputs` has no `arrival`.

- [ ] **Step 3: Extend the resolver**

Add the snapshot type and the case:

```swift
    /// What the arrival card needs, decoupled from the coordinator for
    /// the same reason `AlertSnapshot` is: the resolver and the verify
    /// harness depend on nothing but Foundation.
    struct ArrivalSnapshot: Equatable, Sendable {
        let networkName: String
        let joinedAt: Date
    }
```

```swift
        /// Just joined a network. Ranked below `.alerted` (a problem now
        /// beats context) and below `.testing` (the arrival's own check
        /// may still be running, and a card that looked finished would be
        /// reporting a verdict that does not exist yet), but above
        /// `.healthy` and `.watching`: for a laptop that moves, "what is
        /// this network" is the more useful thing to say for the first
        /// minute. The coordinator expires it; this only ranks it.
        case arrived(ArrivalSnapshot)
```

Add `let arrival: ArrivalSnapshot?` to `Inputs` with a defaulted `nil` in the
memberwise `init` so no existing call site changes, then insert one line into
`resolve`, after the `.alerted` check and before the `linkUp` check:

```swift
        if let arrival = i.arrival { return .arrived(arrival) }
```

- [ ] **Step 4: Own its lifetime in the coordinator**

Add an observable `arrival: StageResolver.ArrivalSnapshot?`, set when the
network changes and cleared on a timer and on dismiss:

```swift
    /// The arrival card's own lifetime. Sixty seconds after the check
    /// lands, or immediately on dismiss — a card still saying "arrived"
    /// an hour later would be lying about what the word means.
    private(set) var arrival: StageResolver.ArrivalSnapshot?
    private var arrivalExpiry: Task<Void, Never>?

    func noteArrival(networkName: String) {
        arrival = .init(networkName: networkName, joinedAt: Date())
        arrivalExpiry?.cancel()
        arrivalExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.arrival = nil }
        }
    }

    func dismissArrival() {
        arrivalExpiry?.cancel()
        arrivalExpiry = nil
        arrival = nil
    }
```

Call `noteArrival(networkName: history.displayName(for: id))` from the network
change block in Task 11, immediately after `alerts.networkChanged(to: id)`.

Pass `arrival: coordinator.arrival` into `DropdownView.stage`'s `Inputs`.

- [ ] **Step 5: Render it**

In `DropdownView.swift`, add the `case .arrived(let a): arrivedStage(a)` arm and
the view. It stacks: the network name and join age, the coordinator's existing
`headline` (CLI-authored), `SuitabilityPanel(rows:compact: true)`, the single
worst diagnosis's `FixBox`, and — after Task 19 — the memory line. Plus two
buttons, "See full report" (routes to `.home`) and "Dismiss"
(`coordinator.dismissArrival()`).

Follow `nimbalyst-local/mockups/netdiag-arrival-card.mockup.html` for the
layout; the exact styling is this view's own, as the existing mockup-derived
views note.

- [ ] **Step 6: Add the notification rule**

In `AlertEngine`, when a scan lands whose reason was an arrival, post one
notification **only if** any suitability row is `degraded` or `broken`, or any
diagnosis is `warn` or `critical`. A clean network stays silent.

The title names the network and the worst affected activity — navigation, per
`AlertDefinitions.swift`'s header. The body is `diagnosis[].summary` for the
worst finding, verbatim.

- [ ] **Step 7: Build and verify**

Run: `cd gui && make build && ./.build/debug/NetdiagGUI --verify`
Expected: PASS.

Then, in the running app: switch networks and confirm the card appears, that it
clears after a minute, and that a healthy network posts no notification. Note
that the dropdown cannot be screenshotted — verify by eye.

- [ ] **Step 8: Commit**

```bash
git add gui/Sources/NetdiagGUI/Support/StageResolver.swift \
        gui/Sources/NetdiagGUI/Views/DropdownView.swift \
        gui/Sources/NetdiagGUI/Services/NetdiagCoordinator.swift \
        gui/Sources/NetdiagGUI/Alerts/AlertEngine.swift \
        gui/Sources/NetdiagGUI/VerifyMode.swift
git commit -m "feat(gui): joining a network is a moment the app speaks

A new dropdown stage, ranked under an active alert and under a running
check, expiring after a minute. Notifies only when something is not
good — a commuter joining five networks a day gets five green cards and
no interruptions."
```

---

## Phase 3 — memory

### Task 13: The app writes the journal

**Files:**
- Modify: `gui/Sources/NetdiagGUI/Services/MonitorStream.swift:155`

- [ ] **Step 1: Pass the flag, gated on the recorder**

```swift
        var args = [
            "--monitor",
            "--monitor-fast-interval",     String(fast),
            "--monitor-degraded-interval", String(degraded),
            "--monitor-medium-interval",   String(Defaults.mediumInterval),
            "--monitor-slow-interval",     String(Defaults.slowInterval),
        ]
        // Episodes only exist if something wrote events.jsonl, and today
        // that needs the opt-in launchd recorder — so Activity is empty
        // for almost everyone. This process is already running --monitor
        // continuously; the journal costs it nothing.
        //
        // But only when the recorder is not installed. Two processes
        // appending to one journal is a risk this app will not take on
        // faith, and the recorder is strictly better anyway: it keeps
        // writing while the app is closed. Whichever is running, exactly
        // one thing appends to the file.
        if Defaults.journalEnabled && !recorderIsInstalled {
            args += ["--journal", journalPath]
        }
        proc.arguments = args
```

`recorderIsInstalled` comes from `WatcherControl`'s existing installed-state
check — read that type and use its property rather than re-running `launchctl`.
`journalPath` is `~/net-diag/events.jsonl`, the same path `bin/netdiag:619`
reads.

- [ ] **Step 2: Add the default**

In `Defaults`, key `"journalEnabled"`, defaulting to **true** — with the
registration going through the same `register(defaults:)` path the other
default-true keys use, so an existing install picks it up.

- [ ] **Step 3: Verify exactly one writer**

With the recorder uninstalled, start the app and confirm `~/net-diag/events.jsonl`
grows:

Run: `wc -l ~/net-diag/events.jsonl`
Expected: a count that increases across a network change.

Then install the recorder, restart the app's monitor, and confirm the app's own
child no longer carries the flag:

Run: `ps -Ao args | grep -c '[-]-monitor.*--journal'`
Expected: `1` — the recorder's process, not two.

- [ ] **Step 4: Commit**

```bash
git add gui/Sources/NetdiagGUI/Services/MonitorStream.swift \
        gui/Sources/NetdiagGUI/Support/Defaults.swift
git commit -m "feat(gui): the app records the event journal itself

--monitor writes nothing to disk by default and the journal is opt-in;
the app opting in on the user's behalf is what makes Activity real for
someone who never found --install-recorder. Skipped entirely when the
recorder is installed, so exactly one process ever appends."
```

---

### Task 14: Disclose it

**Files:**
- Modify: `gui/Sources/NetdiagGUI/Views/OnboardingView.swift`, `gui/Sources/NetdiagGUI/Views/SettingsView.swift`

- [ ] **Step 1: Onboarding**

Extend step 3's `detail` so it names what is recorded and where, in the same
what-you-get register the file's header requires:

```swift
             detail: "Optional. Installs a small background job so your history builds up over time. Without it, history only grows when a check actually runs.\n\nEither way netdiag keeps a log of when your connection dropped and came back, at ~/net-diag/events.jsonl — times and network names only, no traffic. You can switch it off or delete it in Settings.",
```

- [ ] **Step 2: Settings**

Add a "Recording" section with the switch and a destructive button:

```swift
Section("Recording") {
    Toggle("Record when the connection drops", isOn: $appSettings.journalEnabled)
        .help("Writes one line per change to ~/net-diag/events.jsonl. "
              + "This is what the Activity screen reads; with it off, "
              + "Activity can only show what happened since the app started.")
    LabeledContent("Recorded history") {
        Button("Delete…", role: .destructive) { showDeleteJournalConfirm = true }
    }
}
.confirmationDialog("Delete recorded history?",
                    isPresented: $showDeleteJournalConfirm) {
    Button("Delete", role: .destructive) { coordinator.deleteJournal() }
} message: {
    Text("Removes ~/net-diag/events.jsonl and its archive. Past checks and "
         + "network names are kept — this only deletes the record of when "
         + "the connection dropped.")
}
```

`deleteJournal()` removes the journal and its archive file, then tells
`EventsStore` to reload so Activity empties immediately rather than showing
episodes from a file that no longer exists.

- [ ] **Step 3: Verify the delete actually deletes**

Run: `ls ~/net-diag/events.jsonl*`
Then use the button, then run the same command.
Expected: no such file, and Activity shows its empty state without a relaunch.

- [ ] **Step 4: Commit**

```bash
git add gui/Sources/NetdiagGUI/Views/OnboardingView.swift \
        gui/Sources/NetdiagGUI/Views/SettingsView.swift \
        gui/Sources/NetdiagGUI/Services/NetdiagCoordinator.swift
git commit -m "feat(gui): say what is recorded, and offer to delete it

The app now writes a journal by default, so onboarding names the file
and Settings carries a switch and a delete button."
```

---

### Task 15: `EventsStore` and the episode model

**Files:**
- Create: `gui/Sources/NetdiagGUI/Models/NetworkEpisode.swift`, `gui/Sources/NetdiagGUI/Services/EventsStore.swift`
- Modify: `gui/Sources/NetdiagGUI/VerifyMode.swift`

- [ ] **Step 1: Read the actual output shape first**

Run: `bash bin/netdiag --events=24 | python3 -m json.tool | head -60`

Write the model against what that prints, not against this plan's guess. The
keys below match `helpers/events.py`'s `main()` at `:222-252` as of `30f12b7` —
confirm them before writing, and if they differ, the emitted JSON wins.

- [ ] **Step 2: Write the failing verify case**

```swift
check("episodes decode, including one still open") {
    let json = """
    {"window_hours":24,"observed_fraction":0.71,
     "episodes":[
       {"kind":"internet-down","started_at":"2026-08-29T15:41:08Z",
        "ended_at":"2026-08-29T15:43:46Z","duration_s":158,
        "network_id":"n1","rules":["N1"]},
       {"kind":"dns-failing","started_at":"2026-08-29T16:10:00Z",
        "ended_at":null,"duration_s":null,"network_id":"n1","rules":["D1"]}]}
    """.data(using: .utf8)!
    let doc = try JSONDecoder().decode(EventsDocument.self, from: json)
    expect(doc.episodes.count == 2)
    expect(doc.episodes[0].durationSeconds == 158)
    // An open episode is not a zero-length one. Rendering it as "0s" would
    // report an outage that ended when it has not.
    expect(doc.episodes[1].durationSeconds == nil)
    expect(doc.episodes[1].isOpen)
    expect(doc.observedFraction == 0.71)
}

check("an events document from an older CLI decodes as empty") {
    let doc = try JSONDecoder().decode(
        EventsDocument.self, from: "{}".data(using: .utf8)!)
    expect(doc.episodes.isEmpty)
    expect(doc.observedFraction == nil)
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `cd gui && make build && ./.build/debug/NetdiagGUI --verify`
Expected: FAIL — `EventsDocument` undefined.

- [ ] **Step 4: Write the model and the store**

`NetworkEpisode.swift`:

```swift
import Foundation

/// One fault, from start to end, as `netdiag --events` paired it.
///
/// The GUI has never had this. `ActivityView` renders individual change
/// records — "what changed, in order" — which cannot answer "was the
/// internet down last night, and for how long". `helpers/events.py` has
/// answered it since it was written; nothing called it.
///
/// This type judges nothing, matching the helper: whether a two-minute
/// outage is acceptable is a verdict, and verdicts live in
/// lib/diagnosis.sh against lib/thresholds.sh (AV-1, AV-2).
struct NetworkEpisode: Decodable, Sendable, Identifiable, Equatable {
    let kind: String
    let startedAt: Date
    /// nil while the fault is still happening.
    let endedAt: Date?
    /// nil for an open episode. Deliberately not defaulted to zero: an
    /// outage that has not ended is not an outage of zero length, and
    /// rendering it as "0s" would report the opposite of the truth.
    let durationSeconds: Int?
    let networkID: String?
    let rules: [String]

    var id: String { "\(kind)@\(startedAt.timeIntervalSince1970)" }
    var isOpen: Bool { endedAt == nil }

    enum CodingKeys: String, CodingKey {
        case kind
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case durationSeconds = "duration_s"
        case networkID = "network_id"
        case rules
    }
}

/// `netdiag --events=HOURS`'s whole document.
struct EventsDocument: Decodable, Sendable {
    let windowHours: Int?
    /// How much of the window was actually watched. The Mac sleeps, and
    /// `lib/availability.sh` refuses to claim "no outages in 24 hours"
    /// from six hours of watching — the GUI must not launder that caveat
    /// away either.
    let observedFraction: Double?
    let episodes: [NetworkEpisode]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        windowHours = try? c.decodeIfPresent(Int.self, forKey: .windowHours)
        observedFraction = try? c.decodeIfPresent(Double.self, forKey: .observedFraction)
        episodes = (try? c.decode([NetworkEpisode].self, forKey: .episodes)) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case windowHours = "window_hours"
        case observedFraction = "observed_fraction"
        case episodes
    }
}
```

`EventsStore.swift` follows `HistoryStore`'s shape exactly — an `@Observable`
`@MainActor` class with `isLoading`, `document`, a `load(hours:)` that runs the
binary via the same `BinaryLocator` path `HistoryStore` uses, and a
`lastError`. Read `HistoryStore.swift` and mirror it; do not invent a second
process-spawning pattern.

- [ ] **Step 5: Run to verify it passes**

Run: `cd gui && make build && ./.build/debug/NetdiagGUI --verify`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add gui/Sources/NetdiagGUI/Models/NetworkEpisode.swift \
        gui/Sources/NetdiagGUI/Services/EventsStore.swift \
        gui/Sources/NetdiagGUI/VerifyMode.swift
git commit -m "feat(gui): read the episodes the CLI has always produced

An open episode decodes with a nil duration rather than zero: an outage
that has not ended is not one of zero length."
```

---

### Task 16: Activity shows episodes

**Files:**
- Modify: `gui/Sources/NetdiagGUI/Views/ActivityView.swift`

- [ ] **Step 1: Add the mode control and the window selector**

Two modes — **Episodes** (new default) and **All changes** (today's list,
unchanged, kept for the expert who wants raw transitions) — plus a 24 h / 7 d /
30 d window picker driving `EventsStore.load(hours:)`.

- [ ] **Step 2: Render the availability header**

Above both modes: outage count, total downtime, longest outage, short-flap
count, and the observed-fraction caveat. The caveat is not optional — see
`NetworkEpisode`'s header and `lib/availability.sh:20-27`. When
`observedFraction` is nil, say the window's coverage is unknown rather than
implying it was fully watched.

- [ ] **Step 3: Group by network visit, not by calendar day**

A visit is a run of consecutive episodes sharing one `networkID`. Replace the
`days` grouping (`ActivityView.swift:99-111`) for the Episodes mode only; the
All-changes mode keeps its day grouping unchanged.

Name each group with `coordinator.history.displayName(for:)` so a visit is
labelled the same way it is everywhere else in the app.

Between two visits whose episodes are more than a few minutes apart, render the
gap line the mockup shows ("— asleep for 6h 40m; nothing was watching —") only
when the CLI reported a gap; do not infer one from the timestamps, which would
be the GUI authoring a claim about what was observed.

- [ ] **Step 4: Verify against real data**

Run: `bash bin/netdiag --events=24 | jq '.episodes | length'`
Then open Activity and confirm the same count appears, grouped by network.

- [ ] **Step 5: Commit**

```bash
git add gui/Sources/NetdiagGUI/Views/ActivityView.swift
git commit -m "feat(gui): Activity answers how long it was down

Episodes grouped by network visit, with the observed-fraction caveat
carried through rather than dropped for looking untidy. The old change
list stays, one segment away."
```

---

### Task 17: The memory line

**Files:**
- Modify: `gui/Sources/NetdiagGUI/Views/DropdownView.swift`, `gui/Sources/NetdiagGUI/Services/NetdiagCoordinator.swift`

- [ ] **Step 1: Compose it from facts only**

On the arrival card, one line built from `history` and `EventsStore`:

```swift
    /// "You've been here 4 times. Last visit it dropped 3 times in 2 hours."
    ///
    /// Counts, durations and visit tallies are facts, and the app may
    /// state a fact. A *verdict* about the network ("this one is
    /// unreliable") is the CLI's — it arrives in `diagnosis[].summary`
    /// via AV-1 and AV-2, which judge exactly this data against
    /// lib/thresholds.sh. Nothing here may grow into one.
    ///
    /// Returns nil when there is nothing worth saying: a network seen
    /// once with no episodes gets no line, rather than "You've been here
    /// 1 time."
    func arrivalMemory(for networkID: String) -> String? { … }
```

- [ ] **Step 2: Render it**

Below the fix box in the arrival card, as the mockup shows.

- [ ] **Step 3: Verify**

Rejoin a network with stored history and confirm the line matches
`bash bin/netdiag --history | jq '.networks[] | select(.id=="<id>") | .run_count'`.

- [ ] **Step 4: Commit**

```bash
git add gui/Sources/NetdiagGUI/Views/DropdownView.swift \
        gui/Sources/NetdiagGUI/Services/NetdiagCoordinator.swift
git commit -m "feat(gui): the arrival card remembers this network

Counts and durations only. The verdict about whether that record is bad
stays with AV-1 and AV-2, where the thresholds are."
```

---

### Task 18: Close it out

- [ ] **Step 1: Full CLI suite**

Run: `bats tests/`
Expected: PASS. bats is fully green in this repo — any failure is a real regression.

- [ ] **Step 2: shellcheck**

Run: `shellcheck bin/netdiag lib/*.sh`
Expected: no output.

- [ ] **Step 3: The GUI harness**

Run: `cd gui && make build && ./.build/debug/NetdiagGUI --verify`
Expected: PASS. (`swift test` is a no-op on this toolchain — do not use it as evidence.)

- [ ] **Step 4: Re-capture the samples one last time**

The text report changed again in Task 5, and `--events` and the arrival card do
not appear in a sample, but the suitability section does:

```bash
bash bin/netdiag --redact --json > examples/sample-output.json
bash bin/netdiag --redact | sed $'s/\x1b\\[[0-9;]*[mK]//g' > examples/sample-output.txt
```

Confirm by eye that no public IPv6 address or city name is present.

- [ ] **Step 5: CHANGELOG**

One entry per phase under `## [Unreleased]`, following the repo's existing
narrative style — what changed, and why it was wrong before.

- [ ] **Step 6: Commit**

```bash
git add CHANGELOG.md examples/
git commit -m "docs: changelog and samples for the arrival work"
```

---

## Self-review notes

**Spec coverage.** Part A → Tasks 1, 3, 4, 5, 7, 8. Part B → Tasks 2, 7, 9.
Part C → Tasks 10, 11, 12. Part D → Tasks 13, 14, 15, 16. Part E → Task 17.
Docs and samples → Tasks 6 and 18.

**Two things this plan defers to the engineer, deliberately, because guessing
them from outside the file would produce wrong code:**

1. `lib/output.sh`'s existing `section` helper name and signature (Task 5,
   Step 3). The new section must use it rather than printing its own header.
2. `--events`'s exact JSON keys (Task 15, Step 1). The plan's model matches
   `helpers/events.py` as of `30f12b7`; the emitted JSON is authoritative.

Both are named as explicit read-first steps inside their tasks, not left as
open questions.

**Ordering constraint.** Task 12 renders `SuitabilityPanel` and `FixBox`, so it
must follow Tasks 8 and 9. Task 17 renders inside the arrival card, so it must
follow Task 12. Nothing else in Phase 3 depends on Phase 2.
