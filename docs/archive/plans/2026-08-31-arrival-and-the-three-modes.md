# Arrival and the Three Modes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every new network reliably get a check on arrival, render that arrival as a visible state rather than a silent side effect, and stop Home showing another network's report unlabelled.

**Architecture:** Four new pure value-types in `gui/Sources/NetdiagGUI/Support/` (`NetworkIdentity`, `ArrivalState`, `ArrivalPolicy`, and a `DeclineReason`), persisted through one new `Defaults` key with a fail-closed migration, consumed by `NetdiagCoordinator.handleSample` and rendered by a new `ArrivalCard` view on Home. Every new type is a pure function or plain value so `VerifyMode` can exercise it — `swift test` is a no-op on this CLT-only toolchain and cannot construct a coordinator.

**Tech Stack:** Swift 6 / SwiftUI (`@Observable`, strict concurrency, `@MainActor`), SwiftPM without Xcode, `VerifyMode` as the runnable Swift harness, bats-core for the CLI-side parity check, Python 3 (`helpers/history.py`) as the canonical source of the network-id rule.

**Working directory:** `/Users/bfreeman/Documents/AI-Workspace/netdiag_worktrees/arrival-state` (branch `feat/arrival-state`, already created from `main` at `b25df72`). All paths below are relative to it.

**Spec:** `docs/design/2026-08-31-arrival-and-the-three-modes-design.md`

---

## Background the implementer needs

Three things about this codebase that are not obvious and will cause wasted work if missed:

1. **`swift test` compiles but runs nothing here.** The machine has Command Line Tools, no Xcode.app, so Swift Testing's `xctest` host is absent. The real harness is `VerifyMode.swift`, reached with `--verify`. Every Swift assertion in this plan goes there. Run it with:
   ```bash
   swift build -c release && ./.build/release/NetdiagGUI --verify
   ```
   from the `gui/` directory. It prints `✔`/`✘` per check and exits non-zero on any failure.

2. **Thresholds may not be written in Swift.** `tests/test_thresholds.bats` fails the build on an inline numeric cutoff in the four judging files. Nothing in this plan judges a network: `ArrivalPolicy` reads `severity` as an opaque string and compares it against an allow-list of the CLI's own vocabulary, exactly as the existing `FullCheckPolicy` does. Do not add a latency number, a loss percentage, or a speed figure anywhere in this work.

3. **The GUI must not author verdicts.** See the header of `Alerts/AlertDefinitions.swift`. Arrival-card copy is allowed to say what netdiag *is doing* and what it *costs*. It may not say whether the network is good. Verdict prose keeps coming from `diagnosis[].summary` verbatim.

---

## File Structure

**Create:**

| Path | Responsibility |
|---|---|
| `gui/Sources/NetdiagGUI/Support/NetworkIdentity.swift` | Canonicalise a network id (`mac:` > `ssid:` > `gw:`), and fold weak keys onto their MAC group. Swift port of `helpers/history.py:263-300,444`. Pure. |
| `gui/Sources/NetdiagGUI/Support/ArrivalState.swift` | The per-network state value + `DeclineReason`. `Codable`. No logic beyond staleness. |
| `gui/Sources/NetdiagGUI/Support/ArrivalPolicy.swift` | `decide(...) -> Decision` — full, quick-with-reason, or wait. Pure. |
| `gui/Sources/NetdiagGUI/Views/ArrivalCard.swift` | Renders one `ArrivalState` as the card at the top of Home. |
| `tests/fixtures/network-ids.txt` | Shared fixture: raw record string → expected canonical form. Read by both `VerifyMode` and bats. |
| `tests/test_network_identity.bats` | Asserts `helpers/history.py` produces the fixture's canonical forms, so the Swift and Python rules cannot drift. |

**Modify:**

| Path | Change |
|---|---|
| `gui/Sources/NetdiagGUI/Support/Defaults.swift` | Add `arrivalStates`; keep `seenNetworks` readable for the migration only. |
| `gui/Sources/NetdiagGUI/Models/MonitorSample.swift` | `historyJoinID` stops falling back to the record-format `id`. |
| `gui/Sources/NetdiagGUI/Services/NetworkEventWatcher.swift` | Publish `pathIsExpensive` / `pathIsConstrained`. |
| `gui/Sources/NetdiagGUI/Services/NetdiagCoordinator.swift` | Replace the first-sighting block with the arrival state machine; scope hydration to the current network. |
| `gui/Sources/NetdiagGUI/Views/HomeView.swift` | Render `ArrivalCard`; pass provenance. |
| `gui/Sources/NetdiagGUI/Views/RunReportView.swift` | Add `provenance` and render it. |
| `gui/Sources/NetdiagGUI/Support/StageResolver.swift` | Add the `.arrived` stage and its input. |
| `gui/Sources/NetdiagGUI/Views/DropdownView.swift` | Render `.arrived`. |
| `gui/Sources/NetdiagGUI/VerifyMode.swift` | Four new check suites + arrival-card snapshots. |
| `CHANGELOG.md` | One entry at the end. |

---

## Task 1: Canonical network identity

Ports the rule that `helpers/history.py` already implements. Everything downstream keys on this, so it goes first.

**Files:**
- Create: `gui/Sources/NetdiagGUI/Support/NetworkIdentity.swift`
- Modify: `gui/Sources/NetdiagGUI/VerifyMode.swift`

- [ ] **Step 1: Read the Python rule you are porting**

```bash
cd /Users/bfreeman/Documents/AI-Workspace/netdiag_worktrees/arrival-state
sed -n '260,300p;440,495p' helpers/history.py
```

Expected: you will see record-form parsing returning `mac:<lowercased>`, `ssid:<name>`, `gw:<ip>` in that precedence, and a `fold`-style pass mapping weak (`ssid:`/`gw:`) group keys onto the `mac:` group they belong to. Match this exactly — the bats test in Task 2 asserts the two agree.

- [ ] **Step 2: Write the failing checks in VerifyMode**

Add to `gui/Sources/NetdiagGUI/VerifyMode.swift`, immediately before the `private static func check(` declaration:

```swift
    // MARK: - NetworkIdentity
    //
    // The three real keys below came out of a live install's defaults,
    // where one iPhone hotspot had accumulated all of gw:10.125.128.1,
    // wifi:gw=10.125.128.1 and mac:76:42:18:5c:40:64. That is the bug this
    // type exists to make unrepresentable.
    private static func runNetworkIdentityTests() {
        print("NetworkIdentity:")

        check(NetworkIdentity.canonical("wifi:mac=AA:BB:CC:DD:EE:FF") == "mac:aa:bb:cc:dd:ee:ff",
              "a record-form MAC canonicalises and lowercases")
        check(NetworkIdentity.canonical("mac:aa:bb:cc:dd:ee:ff") == "mac:aa:bb:cc:dd:ee:ff",
              "an already-canonical MAC is unchanged")
        check(NetworkIdentity.canonical("wifi:gw=10.125.128.1") == "gw:10.125.128.1",
              "a record-form gateway canonicalises")
        check(NetworkIdentity.canonical("lan:gw=192.168.60.1") == "gw:192.168.60.1",
              "the lan: record prefix canonicalises the same way")
        check(NetworkIdentity.canonical("wifi:ssid=SB Airbnb") == "ssid:SB Airbnb",
              "a record-form SSID canonicalises")

        // MAC wins over SSID wins over gateway, matching history.py.
        check(NetworkIdentity.canonical("wifi:mac=AA:BB:CC:DD:EE:FF,ssid=Home,gw=192.168.1.1")
                == "mac:aa:bb:cc:dd:ee:ff",
              "MAC outranks SSID and gateway")
        check(NetworkIdentity.canonical("wifi:ssid=Home,gw=192.168.1.1") == "ssid:Home",
              "SSID outranks gateway")

        check(NetworkIdentity.canonical("") == nil,
              "an empty id canonicalises to nothing")
        check(NetworkIdentity.canonical("unknown") == nil,
              "the CLI's unknown sentinel canonicalises to nothing")
        check(NetworkIdentity.canonical("wifi:mac=") == nil,
              "a present-but-empty field is not an identity")

        // fold: weak keys collapse onto the MAC group that shares their
        // gateway or SSID. The map is weak-key -> strong-key, and strong
        // keys map to themselves so callers can look up unconditionally.
        let folded = NetworkIdentity.fold(
            [
                "mac:76:42:18:5c:40:64": ["gw:10.125.128.1", "ssid:Richard’s iPhone"],
                "mac:64:d1:54:4a:93:7f": ["gw:172.20.10.1"],
            ],
            weak: ["gw:10.125.128.1", "gw:172.20.10.1", "ssid:Richard’s iPhone", "gw:8.8.8.8"])
        check(folded["gw:10.125.128.1"] == "mac:76:42:18:5c:40:64",
              "a gateway folds onto the MAC group that used it")
        check(folded["ssid:Richard’s iPhone"] == "mac:76:42:18:5c:40:64",
              "an SSID folds onto the MAC group that used it")
        check(folded["gw:172.20.10.1"] == "mac:64:d1:54:4a:93:7f",
              "a second gateway folds onto its own MAC group")
        check(folded["gw:8.8.8.8"] == nil,
              "a weak key with no MAC group folds nowhere, rather than guessing")
    }
```

Now register it. In `VerifyHarness.run()`, add the call after `runFullCheckPolicyTests()`:

```swift
        runFullCheckPolicyTests()
        runNetworkIdentityTests()
```

- [ ] **Step 3: Run to verify it fails**

```bash
cd /Users/bfreeman/Documents/AI-Workspace/netdiag_worktrees/arrival-state/gui
swift build -c release 2>&1 | tail -20
```

Expected: FAIL to compile, `cannot find 'NetworkIdentity' in scope`.

- [ ] **Step 4: Write the implementation**

Create `gui/Sources/NetdiagGUI/Support/NetworkIdentity.swift`:

```swift
import Foundation

/// The one way this app names a network.
///
/// `helpers/history.py` has always canonicalised a network record into one
/// of three forms — `mac:` (strongest), `ssid:`, `gw:` (weakest) — and then
/// folded the weak forms onto the MAC group they belong to, so one physical
/// network is one group. The GUI never got that logic: `historyJoinID` fell
/// back to the raw *record* format when the CLI had not yet resolved a
/// group, and every dictionary keyed by network accumulated a mixture. One
/// live install held all three of `gw:10.125.128.1`,
/// `wifi:gw=10.125.128.1` and `mac:76:42:18:5c:40:64` for a single iPhone
/// hotspot, which is why its arrival check could be recorded under a key it
/// would never present under again.
///
/// Pure, and deliberately not a method on `MonitorSample.Network`: the
/// verify harness is the only runnable test host on this toolchain and it
/// must be able to call this without decoding a sample. Same shape and same
/// reason as `StageResolver` and `FullCheckPolicy`.
///
/// This is not a threshold and not a verdict — it is an identity. It says
/// which network you are on, never whether that network is any good.
enum NetworkIdentity {

    /// The CLI's sentinel for "could not identify this network". Treated
    /// exactly like an empty string: not an identity.
    private static let unknown = "unknown"

    /// Canonicalise either a record-format id (`wifi:mac=…`, `lan:gw=…`) or
    /// an already-canonical one (`mac:…`) into the canonical form.
    ///
    /// Returns `nil` when there is no identity to be had, and **`nil` means
    /// "do not decide yet", never "a new network"**. That distinction is
    /// the entire point of the optional: the previous code's `groupId ?? id`
    /// fallback treated an unresolved network as a nameable one, and every
    /// mixed key in the wild came from there.
    static func canonical(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != unknown else { return nil }

        // Already canonical: accept, but normalise a MAC's case so two
        // spellings of one address cannot be two keys.
        for prefix in ["mac:", "ssid:", "gw:"] where trimmed.hasPrefix(prefix) {
            let value = String(trimmed.dropFirst(prefix.count))
            guard !value.isEmpty else { return nil }
            return prefix == "mac:" ? "mac:\(value.lowercased())" : "\(prefix)\(value)"
        }

        // Record format: `<scope>:<k>=<v>,<k>=<v>`. The scope (`wifi`,
        // `lan`, …) is not part of the identity — the same gateway reached
        // over Wi-Fi and over Ethernet is the same network.
        guard let colon = trimmed.firstIndex(of: ":") else { return nil }
        let fields = parseFields(String(trimmed[trimmed.index(after: colon)...]))

        // Precedence is load-bearing and matches history.py.
        if let mac = fields["mac"], !mac.isEmpty { return "mac:\(mac.lowercased())" }
        if let ssid = fields["ssid"], !ssid.isEmpty { return "ssid:\(ssid)" }
        if let gw = fields["gw"], !gw.isEmpty { return "gw:\(gw)" }
        return nil
    }

    /// Split `k=v,k=v` into a dictionary. An SSID may legitimately contain
    /// `=`, so only the *first* `=` in each field separates key from value.
    private static func parseFields(_ body: String) -> [String: String] {
        var out: [String: String] = [:]
        for field in body.split(separator: ",", omittingEmptySubsequences: true) {
            guard let eq = field.firstIndex(of: "=") else { continue }
            let key = String(field[field.startIndex..<eq])
            let value = String(field[field.index(after: eq)...])
            out[key] = value
        }
        return out
    }

    /// Map weak keys onto the MAC group that shares them.
    ///
    /// `strong` is what each MAC group is known to have used — its
    /// gateways and SSIDs, in canonical form. `weak` is the set of
    /// non-MAC keys needing a home. The result maps each foldable weak key
    /// to its MAC key; a weak key with no matching group is **absent**
    /// rather than mapped to itself, so a caller can tell "folded" from
    /// "nothing known about this" without a second lookup.
    ///
    /// A weak key claimed by two MAC groups folds onto neither: two
    /// networks behind the same RFC-1918 gateway address is common (every
    /// 192.168.1.1 on earth), and merging them would be worse than leaving
    /// them apart.
    static func fold(_ strong: [String: [String]], weak: Set<String>) -> [String: String] {
        var claims: [String: Set<String>] = [:]
        for (mac, used) in strong {
            for key in used where weak.contains(key) {
                claims[key, default: []].insert(mac)
            }
        }
        return claims.compactMapValues { $0.count == 1 ? $0.first : nil }
    }
}
```

- [ ] **Step 5: Run to verify it passes**

```bash
cd /Users/bfreeman/Documents/AI-Workspace/netdiag_worktrees/arrival-state/gui
swift build -c release && ./.build/release/NetdiagGUI --verify 2>&1 | grep -A 20 "NetworkIdentity:"
```

Expected: 15 lines beginning `✔`, and `All checks passed.` at the end of the full output.

- [ ] **Step 6: Commit**

```bash
cd /Users/bfreeman/Documents/AI-Workspace/netdiag_worktrees/arrival-state
git add gui/Sources/NetdiagGUI/Support/NetworkIdentity.swift gui/Sources/NetdiagGUI/VerifyMode.swift
git commit -m "feat(gui): one canonical name for a network

history.py has always folded a network record down to mac:/ssid:/gw: and
merged the weak forms onto the MAC group. The GUI never got that rule, so
historyJoinID's groupId ?? id fallback seeded a mixture — one live install
held gw:10.125.128.1, wifi:gw=10.125.128.1 and mac:76:42:18:5c:40:64 for a
single iPhone hotspot.

canonical() returns nil for anything it cannot name, and nil means 'do not
decide yet' rather than 'new network'. That is the distinction the old
fallback collapsed."
```

---

## Task 2: Lock the Swift and Python rules together

A Swift port that silently drifts from `helpers/history.py` reintroduces the bug. This is the same guard shape as `tests/test_thresholds.bats`.

**Files:**
- Create: `tests/fixtures/network-ids.txt`, `tests/test_network_identity.bats`
- Modify: `gui/Sources/NetdiagGUI/VerifyMode.swift`

- [ ] **Step 1: Write the shared fixture**

Create `tests/fixtures/network-ids.txt`. Format is `<raw record>|<expected canonical>`, one per line, `-` meaning "no identity". `#` comments and blank lines are skipped.

```
# Shared by tests/test_network_identity.bats and VerifyMode's
# runNetworkIdentityFixtureTests(). Both must agree on every line — that
# agreement is the whole point of the file. See
# docs/design/2026-08-31-arrival-and-the-three-modes-design.md.
#
# raw record | expected canonical form ("-" = no identity)
wifi:mac=AA:BB:CC:DD:EE:FF|mac:aa:bb:cc:dd:ee:ff
wifi:mac=aa:bb:cc:dd:ee:ff|mac:aa:bb:cc:dd:ee:ff
wifi:gw=10.125.128.1|gw:10.125.128.1
lan:gw=192.168.60.1|gw:192.168.60.1
wifi:ssid=SB Airbnb|ssid:SB Airbnb
wifi:mac=24:FD:0D:D2:C2:19,ssid=SB Airbnb,gw=192.168.1.1|mac:24:fd:0d:d2:c2:19
wifi:ssid=Mercure,gw=172.20.10.1|ssid:Mercure
mac:aa:bb:cc:dd:ee:ff|mac:aa:bb:cc:dd:ee:ff
gw:10.125.128.1|gw:10.125.128.1
ssid:Mercure|ssid:Mercure
unknown|-
|-
wifi:mac=|-
```

- [ ] **Step 2: Write the failing bats test**

Create `tests/test_network_identity.bats`:

```bash
#!/usr/bin/env bats
#
# The Swift and Python halves of the network-id rule must agree.
#
# helpers/history.py canonicalises a network record so runs group into
# networks; NetworkIdentity.swift does the same so the GUI's per-network
# state keys match. Two implementations of one rule drift, and when they
# drift the app records an arrival check under a key it will never present
# under again — which is the bug this fixture exists to prevent.
#
# VerifyMode's runNetworkIdentityFixtureTests() reads the same file.

setup() {
    REPO_ROOT="$( cd "$( dirname "$BATS_TEST_FILENAME" )/.." && pwd )"
    FIXTURE="$REPO_ROOT/tests/fixtures/network-ids.txt"
}

@test "the fixture exists and has cases" {
    [ -f "$FIXTURE" ]
    run bash -c "grep -vc '^#\|^$' '$FIXTURE'"
    [ "$status" -eq 0 ]
    [ "$output" -ge 10 ]
}

@test "history.py canonicalises every fixture case as the fixture says" {
    run python3 - "$FIXTURE" <<'PY'
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(sys.argv[1])), "..", "helpers"))
import history

failures = []
with open(sys.argv[1], encoding="utf-8") as fh:
    for lineno, line in enumerate(fh, 1):
        line = line.rstrip("\n")
        if not line or line.startswith("#"):
            continue
        raw, _, expected = line.partition("|")
        got = history.canonical_network_id(raw)
        got = "-" if got is None else got
        if got != expected:
            failures.append(f"line {lineno}: {raw!r} -> {got!r}, fixture says {expected!r}")

if failures:
    print("\n".join(failures))
    sys.exit(1)
print("all cases agree")
PY
    [ "$status" -eq 0 ]
    [[ "$output" == *"all cases agree"* ]]
}
```

- [ ] **Step 3: Run to verify it fails**

```bash
cd /Users/bfreeman/Documents/AI-Workspace/netdiag_worktrees/arrival-state
bats tests/test_network_identity.bats
```

Expected: the first test passes; the second FAILS with `AttributeError: module 'history' has no attribute 'canonical_network_id'`. The rule currently lives inline inside a larger grouping function and is not callable on its own.

- [ ] **Step 4: Expose the rule in history.py**

Open `helpers/history.py` and find the existing canonicalisation around lines 263–300 (the block returning `f"mac:{…}"`, `f"ssid:{…}"`, `f"gw:{…}"`). Extract its logic into a module-level function that takes the raw string, keeping the existing caller working by having it delegate:

```python
def canonical_network_id(raw):
    """Canonical form of one network id, or None when there is no identity.

    The rule the GUI's NetworkIdentity.swift ports: mac: beats ssid: beats
    gw:, MACs lowercase, and a record-format id (`wifi:mac=…`, `lan:gw=…`)
    reduces to the same form as an already-canonical one. Exposed as its
    own function so tests/test_network_identity.bats can drive it against
    the fixture the Swift side reads — two implementations of one rule
    drift silently otherwise.

    None means "no identity", never "a new network". Callers must not
    substitute a fallback id here; that is exactly the bug that let one
    hotspot accumulate three different keys.
    """
    if raw is None:
        return None
    raw = raw.strip()
    if not raw or raw == "unknown":
        return None

    for prefix in ("mac:", "ssid:", "gw:"):
        if raw.startswith(prefix):
            value = raw[len(prefix):]
            if not value:
                return None
            return f"mac:{value.lower()}" if prefix == "mac:" else f"{prefix}{value}"

    if ":" not in raw:
        return None
    _, _, body = raw.partition(":")
    fields = {}
    for field in body.split(","):
        if "=" not in field:
            continue
        key, _, value = field.partition("=")
        fields[key] = value

    if fields.get("mac"):
        return f"mac:{fields['mac'].lower()}"
    if fields.get("ssid"):
        return f"ssid:{fields['ssid']}"
    if fields.get("gw"):
        return f"gw:{fields['gw']}"
    return None
```

Then rewrite the existing block at ~263–300 to call `canonical_network_id`, so there is one implementation rather than two. Preserve the existing function's second return value (the `bool` it currently returns alongside the id) — read the surrounding code to see what that flag means before changing anything, and keep its behaviour identical.

- [ ] **Step 5: Run to verify it passes**

```bash
cd /Users/bfreeman/Documents/AI-Workspace/netdiag_worktrees/arrival-state
bats tests/test_network_identity.bats
```

Expected: `2 tests, 0 failures`.

- [ ] **Step 6: Verify you did not break the existing suite**

```bash
cd /Users/bfreeman/Documents/AI-Workspace/netdiag_worktrees/arrival-state
bats tests/ 2>&1 | tail -3
```

Expected: `841 tests, 0 failures` (839 before, plus this file's 2). Any other number of failures means the refactor in Step 4 changed grouping behaviour — fix it before continuing; the history grouping is what the Networks tab and `--show`'s comparison both read.

- [ ] **Step 7: Add the Swift half of the fixture check**

In `gui/Sources/NetdiagGUI/VerifyMode.swift`, add before `private static func check(`:

```swift
    /// The Swift half of the fixture guard. `tests/test_network_identity
    /// .bats` drives the identical file through helpers/history.py; this
    /// drives it through NetworkIdentity. Both must agree, because two
    /// implementations of one rule drift and the drift is invisible until
    /// a network's arrival check is filed under a key it never presents
    /// under again.
    ///
    /// Skipped rather than failed when the fixture is not found: the
    /// harness runs from the built .app bundle too, where the repo's tests
    /// directory is not present. bats covers the file's existence.
    private static func runNetworkIdentityFixtureTests() {
        print("NetworkIdentity fixture:")
        let candidates = [
            "tests/fixtures/network-ids.txt",
            "../tests/fixtures/network-ids.txt",
        ]
        guard let text = candidates.lazy
            .compactMap({ try? String(contentsOfFile: $0, encoding: .utf8) })
            .first
        else {
            print("  – fixture not reachable from this working directory, skipped")
            return
        }

        var cases = 0
        var mismatches: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let row = line.trimmingCharacters(in: .whitespaces)
            guard !row.isEmpty, !row.hasPrefix("#") else { continue }
            let parts = row.split(separator: "|", maxSplits: 1,
                                  omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            cases += 1
            let raw = String(parts[0])
            let expected = String(parts[1])
            let got = NetworkIdentity.canonical(raw) ?? "-"
            if got != expected {
                mismatches.append("\(raw) -> \(got), fixture says \(expected)")
            }
        }
        check(cases >= 10, "the fixture supplied cases to check (\(cases))")
        check(mismatches.isEmpty,
              mismatches.isEmpty
                ? "every fixture case canonicalises as the fixture says"
                : "fixture mismatches: \(mismatches.joined(separator: "; "))")
    }
```

Register it in `run()` directly after `runNetworkIdentityTests()`:

```swift
        runNetworkIdentityTests()
        runNetworkIdentityFixtureTests()
```

- [ ] **Step 8: Run both halves**

```bash
cd /Users/bfreeman/Documents/AI-Workspace/netdiag_worktrees/arrival-state/gui
swift build -c release && (cd .. && ./gui/.build/release/NetdiagGUI --verify 2>&1 | grep -A 4 "NetworkIdentity fixture:")
```

Expected:
```
NetworkIdentity fixture:
  ✔ the fixture supplied cases to check (13)
  ✔ every fixture case canonicalises as the fixture says
```

- [ ] **Step 9: Commit**

```bash
cd /Users/bfreeman/Documents/AI-Workspace/netdiag_worktrees/arrival-state
git add tests/fixtures/network-ids.txt tests/test_network_identity.bats \
        helpers/history.py gui/Sources/NetdiagGUI/VerifyMode.swift
git commit -m "test: the Swift and Python network-id rules cannot drift apart

One rule with two implementations drifts, and this one drifts invisibly:
the symptom is an arrival check filed under a key the network will never
present under again, months later.

tests/fixtures/network-ids.txt is read by both halves — bats drives it
through helpers/history.py, --verify drives it through NetworkIdentity.
Same shape as the test_thresholds.bats guard, for the same reason.

history.py's canonicalisation is lifted into canonical_network_id() so it
can be called on its own; the existing caller delegates to it rather than
keeping a second copy."
```

---

## Task 3: The arrival state value

**Files:**
- Create: `gui/Sources/NetdiagGUI/Support/ArrivalState.swift`
- Modify: `gui/Sources/NetdiagGUI/VerifyMode.swift`

- [ ] **Step 1: Write the failing checks**

Add to `VerifyMode.swift` before `private static func check(`:

```swift
    // MARK: - ArrivalState
    private static func runArrivalStateTests() {
        print("ArrivalState:")

        let now = Date(timeIntervalSince1970: 1_700_000_000)

        check(ArrivalState.unchecked.needsAttempt(now: now),
              "unchecked wants an attempt")
        check(!ArrivalState.checked(depth: .full, at: now, runID: "r1").needsAttempt(now: now),
              "checked wants nothing")
        check(!ArrivalState.declined(depth: .full, reason: .hotspot, at: now)
                .needsAttempt(now: now),
              "declined is a decision, not a failure, so it does not retry")

        // A scan that crashed leaves .checking behind. Without a staleness
        // rule that network is wedged forever, which is the same class of
        // bug as the one this whole change is fixing.
        let fresh = ArrivalState.checking(depth: .full, startedAt: now)
        check(!fresh.needsAttempt(now: now.addingTimeInterval(60)),
              "a checking state inside its window is left alone")
        check(fresh.needsAttempt(now: now.addingTimeInterval(ArrivalState.stallWindow + 1)),
              "a checking state past the stall window is retried")

        // Round-trips through UserDefaults as JSON.
        for state: ArrivalState in [
            .unchecked,
            .checking(depth: .quick, startedAt: now),
            .checked(depth: .full, at: now, runID: "abc"),
            .checked(depth: .full, at: now, runID: nil),
            .declined(depth: .full, reason: .unhealthy, at: now),
            .declined(depth: .full, reason: .hotspot, at: now),
        ] {
            let data = try? JSONEncoder().encode(state)
            let back = data.flatMap { try? JSONDecoder().decode(ArrivalState.self, from: $0) }
            check(back == state, "\(state.debugLabel) survives a JSON round trip")
        }

        // Forward compatibility: a state written by a newer build must not
        // crash this one, and must not read as "checked" — we cannot clear
        // a verdict we do not understand. Same reasoning as
        // FullCheckPolicy's allow-list.
        let futureJSON = Data(#"{"kind":"quarantined","at":0}"#.utf8)
        let decoded = try? JSONDecoder().decode(ArrivalState.self, from: futureJSON)
        check(decoded == .unchecked || decoded == nil,
              "an unrecognised persisted state never reads as checked")
    }
```

Register in `run()` after `runNetworkIdentityFixtureTests()`:

```swift
        runNetworkIdentityFixtureTests()
        runArrivalStateTests()
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd /Users/bfreeman/Documents/AI-Workspace/netdiag_worktrees/arrival-state/gui
swift build -c release 2>&1 | tail -20
```

Expected: FAIL, `cannot find 'ArrivalState' in scope`.

- [ ] **Step 3: Write the implementation**

Create `gui/Sources/NetdiagGUI/Support/ArrivalState.swift`:

```swift
import Foundation

/// Why a full check was not run on arrival.
///
/// Mechanism, never verdict: each case says what netdiag observed about
/// the *link* and what that costs, and nothing about whether the network
/// is any good. See AlertDefinitions.swift's header for the contract.
enum DeclineReason: String, Codable, Sendable, Equatable {
    /// `NWPath.isExpensive` or `.isConstrained` — a personal hotspot, or
    /// Low Data Mode. A full check runs a speed test, and on cellular that
    /// spends the user's data allowance without asking.
    case hotspot
    /// The CLI's severity was outside the set `FullCheckPolicy` recognises
    /// as safe. A full check saturates the link for ~10 s, which on a
    /// connection already struggling makes the user's situation worse.
    case unhealthy
}

/// What has happened, so far, about checking the network you are on.
///
/// This replaces `Defaults.seenNetworks`, a `Set<String>` that could only
/// express "checked" and had no way to say "tried and was declined". The
/// coordinator advanced its `lastNetworkID` guard *before* attempting the
/// arrival scan, so a scan declined for being busy left the network absent
/// from the set with no path back: the retry the code's comment promised
/// required leaving the network and rejoining it. A live install had
/// "SB Airbnb" named in `networkNames` and missing from `seenNetworks`,
/// which is only reachable that way.
///
/// Modelled as a state rather than a flag because the UI renders it —
/// `unchecked` is a spinner, `declined` is a button, `checked` is nothing
/// at all. A flag cannot carry that.
enum ArrivalState: Codable, Sendable, Equatable {
    /// Seen, never successfully checked. Wants an attempt.
    case unchecked
    /// An attempt is in flight.
    case checking(depth: ArrivalDepth, startedAt: Date)
    /// Done. The `runID` is nil for a migrated entry, where the run
    /// predates this feature and cannot be named.
    case checked(depth: ArrivalDepth, at: Date, runID: String?)
    /// Deliberately not run at full depth. A decision, not a failure — it
    /// does not retry, and the card offers the user the override.
    case declined(depth: ArrivalDepth, reason: DeclineReason, at: Date)

    /// How long a `.checking` state may sit before it is assumed dead.
    ///
    /// Three times the slowest depth's real-world duration (~115 s with
    /// speedtest-cli, per CLAUDE.md). Not a threshold in the
    /// lib/thresholds.sh sense — it judges nothing about the network, only
    /// how long this app's own child process is allowed to be silent
    /// before we stop waiting for it.
    static let stallWindow: TimeInterval = 345

    /// Whether the coordinator should try to check this network now.
    func needsAttempt(now: Date) -> Bool {
        switch self {
        case .unchecked:
            return true
        case .checking(_, let startedAt):
            return now.timeIntervalSince(startedAt) > Self.stallWindow
        case .checked, .declined:
            return false
        }
    }

    var debugLabel: String {
        switch self {
        case .unchecked:                 return "unchecked"
        case .checking(let d, _):        return "checking(\(d.rawValue))"
        case .checked(let d, _, _):      return "checked(\(d.rawValue))"
        case .declined(let d, let r, _): return "declined(\(d.rawValue), \(r.rawValue))"
        }
    }

    // MARK: - Codable
    //
    // Hand-rolled rather than synthesised, for one reason: a value written
    // by a newer build must decode to `.unchecked` rather than throwing.
    // The synthesised enum coding would fail the whole dictionary read, so
    // one unknown network would wipe every network's state.

    private enum CodingKeys: String, CodingKey {
        case kind, depth, at, reason, runID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        let depth = (try? c.decodeIfPresent(ArrivalDepth.self, forKey: .depth)) ?? nil
        let at = (try? c.decodeIfPresent(Date.self, forKey: .at)) ?? nil

        switch kind {
        case "checking":
            guard let depth, let at else { self = .unchecked; return }
            self = .checking(depth: depth, startedAt: at)
        case "checked":
            guard let depth, let at else { self = .unchecked; return }
            self = .checked(depth: depth, at: at,
                            runID: try? c.decodeIfPresent(String.self, forKey: .runID))
        case "declined":
            let reason = (try? c.decodeIfPresent(DeclineReason.self, forKey: .reason)) ?? nil
            guard let depth, let at, let reason else { self = .unchecked; return }
            self = .declined(depth: depth, reason: reason, at: at)
        default:
            // "unchecked", and anything a newer build invents. Never
            // `.checked`: we cannot clear a verdict we do not understand.
            self = .unchecked
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .unchecked:
            try c.encode("unchecked", forKey: .kind)
        case .checking(let depth, let startedAt):
            try c.encode("checking", forKey: .kind)
            try c.encode(depth, forKey: .depth)
            try c.encode(startedAt, forKey: .at)
        case .checked(let depth, let at, let runID):
            try c.encode("checked", forKey: .kind)
            try c.encode(depth, forKey: .depth)
            try c.encode(at, forKey: .at)
            try c.encodeIfPresent(runID, forKey: .runID)
        case .declined(let depth, let reason, let at):
            try c.encode("declined", forKey: .kind)
            try c.encode(depth, forKey: .depth)
            try c.encode(reason, forKey: .reason)
            try c.encode(at, forKey: .at)
        }
    }
}

/// The depth an arrival attempt used.
///
/// A separate, persistable mirror of `NetdiagRunner.Depth` rather than that
/// type itself: `Depth` is a runner concern that may gain cases, and this
/// one is written to disk, where a case's spelling is a compatibility
/// commitment.
enum ArrivalDepth: String, Codable, Sendable, Equatable {
    case full
    case quick

    var runnerDepth: NetdiagRunner.Depth {
        switch self {
        case .full:  return .full
        case .quick: return .quick
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

```bash
cd /Users/bfreeman/Documents/AI-Workspace/netdiag_worktrees/arrival-state/gui
swift build -c release && ./.build/release/NetdiagGUI --verify 2>&1 | grep -A 16 "^ArrivalState:"
```

Expected: 12 `✔` lines, no `✘`.

- [ ] **Step 5: Commit**

```bash
cd /Users/bfreeman/Documents/AI-Workspace/netdiag_worktrees/arrival-state
git add gui/Sources/NetdiagGUI/Support/ArrivalState.swift gui/Sources/NetdiagGUI/VerifyMode.swift
git commit -m "feat(gui): arrival is a state, not a flag

seenNetworks was a Set<String>: it could say 'checked' and nothing else.
It could not say 'tried, and was declined because a scan was already
running' — so the coordinator recorded nothing, and its promised retry
needed the user to leave the network and rejoin.

Four states, because the UI renders each differently: unchecked is a
spinner, checking is progress rows, declined is a button, checked is
nothing at all.

Codable is hand-rolled so a state written by a newer build decodes to
.unchecked instead of throwing — the synthesised version would fail the
whole dictionary, wiping every network's state over one unknown entry.
It never decodes to .checked, on FullCheckPolicy's reasoning: we cannot
clear a verdict we do not understand."
```

---

## Task 4: The arrival policy

**Files:**
- Create: `gui/Sources/NetdiagGUI/Support/ArrivalPolicy.swift`
- Modify: `gui/Sources/NetdiagGUI/VerifyMode.swift`

- [ ] **Step 1: Write the failing checks**

Add to `VerifyMode.swift` before `private static func check(`:

```swift
    // MARK: - ArrivalPolicy
    private static func runArrivalPolicyTests() {
        print("ArrivalPolicy:")

        // The regression that started this work. At the instant a network
        // is joined the monitor has produced no sample, so severity is "".
        // FullCheckPolicy correctly refuses to call an unknown severity
        // safe — but asking it *then* silently downgraded essentially
        // every arrival to the lighter check. The answer is to not ask
        // yet.
        check(ArrivalPolicy.decide(hasSample: false, severity: "",
                                   isExpensive: false, isConstrained: false) == .wait,
              "no sample yet means wait, never a downgrade")
        check(ArrivalPolicy.decide(hasSample: false, severity: "ok",
                                   isExpensive: false, isConstrained: false) == .wait,
              "hasSample is what gates the decision, not the severity string")

        check(ArrivalPolicy.decide(hasSample: true, severity: "ok",
                                   isExpensive: false, isConstrained: false) == .full,
              "an ordinary healthy network gets the full check")
        check(ArrivalPolicy.decide(hasSample: true, severity: "info",
                                   isExpensive: false, isConstrained: false) == .full,
              "info is not a problem and still earns a full check")
        check(ArrivalPolicy.decide(hasSample: true, severity: "warn",
                                   isExpensive: false, isConstrained: false) == .full,
              "warn still earns a full check — FullCheckPolicy allows it")

        check(ArrivalPolicy.decide(hasSample: true, severity: "critical",
                                   isExpensive: false, isConstrained: false)
                == .quick(.unhealthy),
              "a critical link gets the quick check, with a reason")
        check(ArrivalPolicy.decide(hasSample: true, severity: "wat",
                                   isExpensive: false, isConstrained: false)
                == .quick(.unhealthy),
              "an unrecognised severity is not treated as safe")

        check(ArrivalPolicy.decide(hasSample: true, severity: "ok",
                                   isExpensive: true, isConstrained: false)
                == .quick(.hotspot),
              "an expensive path gets the quick check rather than a speed test")
        check(ArrivalPolicy.decide(hasSample: true, severity: "ok",
                                   isExpensive: false, isConstrained: true)
                == .quick(.hotspot),
              "a constrained path (Low Data Mode) is treated the same way")

        // Precedence: cost beats health. Both downgrade to quick, but the
        // reason the user is shown must be the one they can act on — and
        // "this is your phone's data" is more actionable than "the link
        // looked unhealthy a moment ago".
        check(ArrivalPolicy.decide(hasSample: true, severity: "critical",
                                   isExpensive: true, isConstrained: false)
                == .quick(.hotspot),
              "when both apply, the hotspot reason is the one shown")
    }
```

Register in `run()` after `runArrivalStateTests()`:

```swift
        runArrivalStateTests()
        runArrivalPolicyTests()
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd /Users/bfreeman/Documents/AI-Workspace/netdiag_worktrees/arrival-state/gui
swift build -c release 2>&1 | tail -20
```

Expected: FAIL, `cannot find 'ArrivalPolicy' in scope`.

- [ ] **Step 3: Write the implementation**

Create `gui/Sources/NetdiagGUI/Support/ArrivalPolicy.swift`:

```swift
import Foundation

/// What depth to check a newly-joined network at, and whether to decide
/// at all yet.
///
/// The bug this exists to fix: `FullCheckPolicy.isSafe` is an allow-list
/// over the CLI's severity vocabulary, and it is right to refuse an
/// unrecognised value. But the coordinator asked it at the exact moment a
/// network was joined — when the monitor has produced no sample and
/// severity is the empty string — so the honest "I do not understand this"
/// became a silent downgrade on essentially every arrival. The user's
/// report was that a brand-new network showed no full check at all; this
/// is half of why.
///
/// The fix is the third case. `.wait` is not a decision, it is the absence
/// of one: the caller leaves the state `.unchecked`, does not advance its
/// backoff, and asks again on the next sample.
///
/// Pure, for the same reason as `FullCheckPolicy` and `StageResolver`:
/// `VerifyMode` is the only runnable harness on this toolchain and cannot
/// construct a coordinator.
///
/// This is not a threshold. It reads severity as an opaque string against
/// `FullCheckPolicy`'s existing allow-list and reads two booleans the OS
/// hands it. It never decides what makes a network bad — that stays in
/// `lib/thresholds.sh`, per CLAUDE.md.
enum ArrivalPolicy {

    enum Decision: Equatable, Sendable {
        /// Run the full battery: bufferbloat, speed, path MTU, per-hop loss.
        case full
        /// Run the quick check instead, for a reason the card will show
        /// alongside a button offering the full one anyway.
        case quick(DeclineReason)
        /// Not enough is known yet. Ask again next sample.
        case wait
    }

    /// - Parameters:
    ///   - hasSample: whether the monitor has produced at least one sample
    ///     for this network. Until it has, `severity` is meaningless and
    ///     the honest answer is `.wait`.
    ///   - severity: the CLI's `status.severity` from that sample.
    ///   - isExpensive: `NWPath.isExpensive` — cellular, including a
    ///     personal hotspot.
    ///   - isConstrained: `NWPath.isConstrained` — Low Data Mode.
    static func decide(hasSample: Bool, severity: String,
                       isExpensive: Bool, isConstrained: Bool) -> Decision {
        guard hasSample else { return .wait }

        // Cost before health, deliberately. Both downgrade to the quick
        // check, so the only thing the order changes is which reason the
        // user is shown — and the one they can act on is the one about
        // their data allowance.
        if isExpensive || isConstrained { return .quick(.hotspot) }

        // Reuses the existing allow-list rather than restating it, so the
        // button a user presses and the check that runs itself can never
        // disagree about what "safe" means.
        guard FullCheckPolicy.isSafe(severity: severity) else {
            return .quick(.unhealthy)
        }
        return .full
    }
}
```

- [ ] **Step 4: Run to verify it passes**

```bash
cd /Users/bfreeman/Documents/AI-Workspace/netdiag_worktrees/arrival-state/gui
swift build -c release && ./.build/release/NetdiagGUI --verify 2>&1 | grep -A 12 "^ArrivalPolicy:"
```

Expected: 10 `✔` lines, no `✘`.

- [ ] **Step 5: Commit**

```bash
cd /Users/bfreeman/Documents/AI-Workspace/netdiag_worktrees/arrival-state
git add gui/Sources/NetdiagGUI/Support/ArrivalPolicy.swift gui/Sources/NetdiagGUI/VerifyMode.swift
git commit -m "feat(gui): decide the arrival depth from a real sample

FullCheckPolicy's allow-list is right to refuse an unrecognised severity.
The bug was asking it at the moment a network is joined, when the monitor
has produced no sample and severity is \"\" — so an honest 'I do not
understand this' became a silent downgrade on essentially every arrival.

Three-valued now: .wait is the absence of a decision, and the caller keeps
the network unchecked and asks again next sample. On ordinary Wi-Fi this
means every new network gets the full check, which is the contract.

Cost is checked before health so a phone hotspot shows the reason the user
can act on. isExpensive/isConstrained cost nothing new — NetworkEventWatcher
already runs an NWPathMonitor and was dropping them."
```

---

## Task 5: Publish the path's cost flags

**Files:**
- Modify: `gui/Sources/NetdiagGUI/Services/NetworkEventWatcher.swift`

`NWPathMonitor` is already running and already receives `isExpensive`/`isConstrained` on every path update; the handler discards them. This task only stops discarding them. There is no `VerifyMode` check here — it is OS plumbing with no logic to assert. Task 4 covers the logic that consumes it.

- [ ] **Step 1: Add the published properties**

In `NetworkEventWatcher`, alongside the existing `pathSatisfied` / `pathUsesVPN`:

```swift
    private(set) var pathSatisfied = true
    private(set) var pathUsesVPN = false
    /// `NWPath.isExpensive` — cellular, which includes a personal hotspot.
    /// Read by `ArrivalPolicy` so joining a phone's hotspot does not
    /// silently spend the user's data allowance on a speed test.
    ///
    /// Defaults to `false`, i.e. "not expensive". A wrong `false` costs
    /// data on one check; a wrong `true` would permanently downgrade every
    /// arrival on ordinary Wi-Fi, which is the bug this whole change is
    /// fixing. NWPathMonitor delivers a real path within milliseconds of
    /// `start()`, and `ArrivalPolicy` will not decide before the first
    /// monitor sample lands anyway.
    private(set) var pathIsExpensive = false
    /// `NWPath.isConstrained` — Low Data Mode.
    private(set) var pathIsConstrained = false
```

- [ ] **Step 2: Capture them in the update handler**

Replace the body of `monitor.pathUpdateHandler` in `start()`:

```swift
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            let vpn = path.availableInterfaces.contains { $0.type == .other }
            let expensive = path.isExpensive
            let constrained = path.isConstrained
            Task { @MainActor in
                self?.handlePath(satisfied: satisfied, usesVPN: vpn,
                                 expensive: expensive, constrained: constrained)
            }
        }
```

- [ ] **Step 3: Store them without widening the event**

Replace `handlePath`:

```swift
    private func handlePath(satisfied: Bool, usesVPN: Bool,
                            expensive: Bool, constrained: Bool) {
        // Recorded unconditionally, and above the transition guard below.
        // These two are *state* the arrival policy reads on demand, not
        // events anyone subscribes to — and the guard exists to suppress
        // duplicate emissions, not to suppress state. Updating them only
        // on a satisfied/VPN transition would leave a hotspot's isExpensive
        // stale at exactly the moment arrival reads it.
        pathIsExpensive = expensive
        pathIsConstrained = constrained

        // NWPathMonitor is chatty — it re-reports the same path on every
        // interface flap. Only forward real transitions, or the alert
        // engine's 30-second grace window would be permanently open and no
        // alert would ever fire.
        guard satisfied != pathSatisfied || usesVPN != pathUsesVPN else { return }
        pathSatisfied = satisfied
        pathUsesVPN = usesVPN
        emit(.pathChanged(satisfied: satisfied, usesVPN: usesVPN))
    }
```

Note: `Event.pathChanged` deliberately keeps its existing two associated values. Nothing subscribes to cost changes; adding them to the event would force every `case .pathChanged` pattern in the codebase to change for no gain.

- [ ] **Step 4: Verify it builds and nothing regressed**

```bash
cd /Users/bfreeman/Documents/AI-Workspace/netdiag_worktrees/arrival-state/gui
swift build -c release && ./.build/release/NetdiagGUI --verify 2>&1 | tail -3
```

Expected: `All checks passed.`

- [ ] **Step 5: Commit**

```bash
cd /Users/bfreeman/Documents/AI-Workspace/netdiag_worktrees/arrival-state
git add gui/Sources/NetdiagGUI/Services/NetworkEventWatcher.swift
git commit -m "feat(gui): keep the path's cost flags instead of dropping them

NWPathMonitor has always handed this app isExpensive and isConstrained on
every update and the handler threw them away. ArrivalPolicy needs both to
tell a phone hotspot from ordinary Wi-Fi.

Stored above the transition guard, not below it: that guard suppresses
duplicate *emissions*, and these are state read on demand. Below it, a
hotspot's isExpensive would be stale at exactly the moment arrival reads
it. The event's payload is unchanged — nothing subscribes to cost."
```

---

## Task 6: Persist arrival states, and migrate

The migration is the sharp edge of this whole change. It fails **closed**: anything ambiguous is treated as already checked. A network wrongly assumed seen loses one automatic baseline and is one button away from getting it; a network wrongly assumed new can spend a few hundred megabytes of someone's cellular data without asking.

**Files:**
- Modify: `gui/Sources/NetdiagGUI/Support/Defaults.swift`, `gui/Sources/NetdiagGUI/VerifyMode.swift`

- [ ] **Step 1: Write the failing checks**

Add to `VerifyMode.swift` before `private static func check(`:

```swift
    // MARK: - Arrival migration
    private static func runArrivalMigrationTests() {
        print("Arrival migration:")

        // The three keys below are verbatim from a live install, where one
        // iPhone hotspot had accumulated all of them.
        let legacy: Set<String> = [
            "gw:10.125.128.1",
            "wifi:gw=10.125.128.1",
            "mac:76:42:18:5c:40:64",
            "mac:28:70:4e:45:89:5a",
            "unknown",
            "",
        ]
        let migrated = Defaults.migratedArrivalStates(from: legacy)

        check(migrated["gw:10.125.128.1"] != nil,
              "a canonical legacy key survives migration")
        check(migrated["wifi:gw=10.125.128.1"] == nil,
              "a record-format legacy key is not carried across verbatim")
        check(migrated["mac:76:42:18:5c:40:64"] != nil,
              "a MAC key survives migration")
        check(migrated["unknown"] == nil && migrated[""] == nil,
              "nameless legacy entries are dropped rather than keyed")

        // Fail closed. Every migrated network reads as already checked, so
        // an upgrade never re-checks the world — and never spends cellular
        // data re-baselining a hotspot it already knew about.
        let allChecked = migrated.values.allSatisfy {
            if case .checked = $0 { return true }
            return false
        }
        check(allChecked, "every migrated entry is checked, never unchecked")
        check(migrated.values.allSatisfy { !$0.needsAttempt(now: Date()) },
              "no migrated entry asks for an attempt")

        check(Defaults.migratedArrivalStates(from: []).isEmpty,
              "an empty legacy set migrates to an empty map")
    }
```

Register in `run()` after `runArrivalPolicyTests()`:

```swift
        runArrivalPolicyTests()
        runArrivalMigrationTests()
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd /Users/bfreeman/Documents/AI-Workspace/netdiag_worktrees/arrival-state/gui
swift build -c release 2>&1 | tail -20
```

Expected: FAIL, `type 'Defaults' has no member 'migratedArrivalStates'`.

- [ ] **Step 3: Add the key**

In `Defaults.Key`, directly below the existing `seenNetworks` line:

```swift
        static let seenNetworks       = "seenNetworks"
        static let arrivalStates      = "arrivalStates"
```

- [ ] **Step 4: Add the accessors and the migration**

Replace the existing `seenNetworks` accessor block (currently at ~line 215) with:

```swift
    /// Superseded by `arrivalStates`. Kept readable so the one-time
    /// migration can find it, and *not* written to any more — a build that
    /// still read this would see a set frozen at the moment of upgrade.
    /// Delete once no supported version reads it.
    static var legacySeenNetworks: Set<String> {
        Set(d.stringArray(forKey: Key.seenNetworks) ?? [])
    }

    /// What has happened about checking each network, keyed by
    /// `NetworkIdentity.canonical`.
    ///
    /// Stored as JSON in a single key rather than as a plist dictionary,
    /// because the value is an enum with associated values. The
    /// dictionary-of-dictionaries pattern `phaseDurationSamples` uses does
    /// not stretch that far.
    ///
    /// A malformed or absent value reads as empty, which means every
    /// network is `.unchecked` — the correct behaviour for a corrupt read
    /// (check them again) rather than a crash. Per-entry decoding failures
    /// cannot happen: `ArrivalState.init(from:)` decodes an unrecognised
    /// state as `.unchecked` rather than throwing, precisely so one bad
    /// entry cannot wipe the map.
    static var arrivalStates: [String: ArrivalState] {
        get {
            guard let data = d.data(forKey: Key.arrivalStates) else { return [:] }
            return (try? JSONDecoder().decode([String: ArrivalState].self, from: data)) ?? [:]
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            d.set(data, forKey: Key.arrivalStates)
        }
    }

    /// Fold a legacy `seenNetworks` set into arrival states. Pure, so
    /// `VerifyMode` can check it without touching the real defaults.
    ///
    /// **Fails closed.** Everything it can name becomes `.checked` at
    /// `.distantPast`; everything it cannot name is dropped. The asymmetry
    /// is deliberate: a network wrongly assumed seen loses one automatic
    /// baseline and is one button away from getting it, while a network
    /// wrongly assumed new can spend a few hundred megabytes of someone's
    /// cellular data without asking.
    ///
    /// `.distantPast` rather than `Date()` so the entry is visibly a
    /// migration artefact — nothing in the UI claims a real check happened
    /// at that timestamp, because `runID` is nil and the card renders
    /// nothing for `.checked`.
    static func migratedArrivalStates(from legacy: Set<String>) -> [String: ArrivalState] {
        var out: [String: ArrivalState] = [:]
        for raw in legacy {
            guard let id = NetworkIdentity.canonical(raw) else { continue }
            out[id] = .checked(depth: .full, at: .distantPast, runID: nil)
        }
        return out
    }

    /// Run the migration once, on first launch of a build that has
    /// `arrivalStates`. Idempotent: a non-empty `arrivalStates` means it
    /// has already run, and a second pass would resurrect networks the
    /// user has since been re-checked on.
    static func migrateArrivalStatesIfNeeded() {
        guard d.data(forKey: Key.arrivalStates) == nil else { return }
        arrivalStates = migratedArrivalStates(from: legacySeenNetworks)
    }
```

Now find every remaining reference to `Defaults.seenNetworks`:

```bash
cd /Users/bfreeman/Documents/AI-Workspace/netdiag_worktrees/arrival-state
grep -rn "seenNetworks" gui/Sources/
```

Expected: the two writes in `NetdiagCoordinator.handleSample` (~lines 307, 330–332), plus any read in `SettingsView`. Leave them failing to compile for now — Task 7 replaces the coordinator block, and if `SettingsView` has a "forget networks" control, point it at `Defaults.arrivalStates = [:]` instead. Do not leave a dangling `Defaults.seenNetworks` reference; the property no longer exists under that name.

- [ ] **Step 5: Call the migration at launch**

In `NetdiagCoordinator`, find `start()` and add the migration as its first statement, before anything reads a network id:

```swift
        Defaults.migrateArrivalStatesIfNeeded()
```

- [ ] **Step 6: Run to verify it passes**

```bash
cd /Users/bfreeman/Documents/AI-Workspace/netdiag_worktrees/arrival-state/gui
swift build -c release && ./.build/release/NetdiagGUI --verify 2>&1 | grep -A 9 "^Arrival migration:"
```

Expected: 7 `✔` lines, no `✘`.

- [ ] **Step 7: Commit**

```bash
cd /Users/bfreeman/Documents/AI-Workspace/netdiag_worktrees/arrival-state
git add gui/Sources/NetdiagGUI/Support/Defaults.swift \
        gui/Sources/NetdiagGUI/Services/NetdiagCoordinator.swift \
        gui/Sources/NetdiagGUI/VerifyMode.swift
git commit -m "feat(gui): persist arrival state, and migrate off seenNetworks

seenNetworks becomes legacySeenNetworks — read once, never written again.

The migration fails closed: anything it can canonicalise becomes checked
at .distantPast, anything it cannot is dropped. The asymmetry is the whole
design. A network wrongly assumed seen loses one automatic baseline and
has a button; a network wrongly assumed new can spend a few hundred
megabytes of someone's cellular data without asking.

JSON in one key rather than a plist dictionary, because the value is an
enum with associated values. One bad entry cannot wipe the map —
ArrivalState decodes an unknown state as .unchecked rather than throwing."
```

---

## Task 7: Rewire the coordinator

This is the task that fixes the reported bug. Read the spec's "What was actually wrong §1" before starting.

**Files:**
- Modify: `gui/Sources/NetdiagGUI/Models/MonitorSample.swift`, `gui/Sources/NetdiagGUI/Services/NetdiagCoordinator.swift`

- [ ] **Step 1: Stop `historyJoinID` inventing identities**

In `MonitorSample.Network`, replace the `historyJoinID` computed property (~line 94):

```swift
        /// The id to join against `--history`'s network groups with.
        ///
        /// Canonicalised, and **nil rather than a fallback**. The raw `id`
        /// is the *record* format (`wifi:mac=AA:BB:…`), which history.py
        /// canonicalises before grouping — joining on it never matches.
        /// The previous `groupId ?? id` fallback papered over that by
        /// handing back a record-format string when the CLI had not yet
        /// resolved a group, which is how one live install accumulated
        /// `gw:10.125.128.1`, `wifi:gw=10.125.128.1` and
        /// `mac:76:42:18:5c:40:64` for a single iPhone hotspot.
        ///
        /// `nil` means "not identified yet", and every caller must treat it
        /// as "do not decide", never as "a new network". `id` remains
        /// available for display, which is the only thing it is fit for.
        var historyJoinID: String? {
            if let groupId, let canonical = NetworkIdentity.canonical(groupId) {
                return canonical
            }
            return NetworkIdentity.canonical(id ?? "")
        }
```

Note the fallback is *retained but canonicalised*: a record-format `id` still yields a usable identity, it just yields the same one the group would. What is removed is the possibility of returning a non-canonical string.

- [ ] **Step 2: Add the coordinator's arrival state**

Add to `NetdiagCoordinator`'s stored properties, near `lastNetworkID`:

```swift
    private var lastNetworkID: String?
    /// The current network's arrival state, mirrored into observable
    /// storage so `ArrivalCard` re-renders when it changes. `Defaults` is
    /// the source of truth; this is the copy SwiftUI can see.
    private(set) var arrivalState: ArrivalState = .unchecked
    /// The canonical id `arrivalState` describes. Views read this to name
    /// the network on the arrival card.
    private(set) var arrivalNetworkID: String?
    /// Consecutive failed arrival attempts for the current network, held
    /// in memory only: a backoff that survived relaunch would punish a
    /// user for quitting the app. Reset when the network changes or an
    /// attempt succeeds.
    private var arrivalAttempts = 0
    private var nextArrivalAttemptAt: Date?
```

- [ ] **Step 3: Replace the first-sighting block**

In `handleSample`, replace everything from `guard let id = sample.network.historyJoinID else { return }` to the end of the function with:

```swift
        // Not identified yet — the CLI has no group and no usable record
        // id. Decide nothing: `nil` here has never meant "a new network".
        guard let id = sample.network.historyJoinID else { return }

        if id != lastNetworkID {
            lastNetworkID = id
            alerts.networkChanged(to: id)
            log.info("now on network \(id, privacy: .public)")
            // A different network's backoff is meaningless.
            arrivalAttempts = 0
            nextArrivalAttemptAt = nil
        }

        // Deliberately outside the id-changed guard above. The previous
        // version attempted the arrival scan *inside* it, having already
        // advanced `lastNetworkID` — so a scan declined for being busy
        // could never be retried, because every later sample returned at
        // the guard. Its comment promised "the next sighting retries";
        // there is no next sighting while you stay on the network. A live
        // install had "SB Airbnb" named in `networkNames` and absent from
        // `seenNetworks`, which is only reachable that way.
        considerArrival(for: id, sample: sample)
    }

    // MARK: - Arrival

    /// The one automatic check, and the reason there is no timed one:
    /// joining a network for the first time is exactly when a baseline of
    /// what it can do — throughput, bufferbloat, path MTU — is worth
    /// having. Monitoring covers the continuous question; this covers the
    /// one-off one. See CLAUDE.md's three-depth table.
    private func considerArrival(for id: String, sample: MonitorSample) {
        arrivalNetworkID = id
        let state = Defaults.arrivalStates[id] ?? .unchecked
        arrivalState = state

        guard Defaults.scanOnNewNetwork else { return }
        let now = Date()
        guard state.needsAttempt(now: now) else { return }
        if let next = nextArrivalAttemptAt, now < next { return }

        switch ArrivalPolicy.decide(hasSample: true,
                                    severity: sample.status.severity,
                                    isExpensive: events.pathIsExpensive,
                                    isConstrained: events.pathIsConstrained) {
        case .wait:
            // Unreachable from here — we hold a sample. Kept exhaustive
            // rather than defaulted so a future case cannot be silently
            // swallowed into "do nothing".
            return

        case .full:
            attemptArrival(id: id, depth: .full, reason: "new network")

        case .quick(let why):
            // A decision, not a failure: recorded so it does not retry,
            // and rendered as a button rather than a spinner.
            attemptArrival(id: id, depth: .quick, reason: "new network (\(why.rawValue))",
                           declineWith: why)
        }
    }

    /// Try to start an arrival check, and record what happened.
    ///
    /// `launch()` silently declines while another scan is in flight. That
    /// decline must leave the state `.unchecked` so the next sample tries
    /// again — the bug being fixed here is precisely a decline that was
    /// recorded as nothing and never retried.
    private func attemptArrival(id: String, depth: ArrivalDepth, reason: String,
                                declineWith: DeclineReason? = nil) {
        let now = Date()
        guard runScan(depth: depth.runnerDepth, reason: reason) else {
            arrivalAttempts += 1
            // 30 s doubling, capped at 5 minutes. In memory only.
            let delay = min(30 * pow(2, Double(arrivalAttempts - 1)), 300)
            nextArrivalAttemptAt = now.addingTimeInterval(delay)
            log.debug("arrival check for \(id, privacy: .public) declined — a scan is running; retrying in \(delay, format: .fixed(precision: 0))s")
            return
        }

        arrivalAttempts = 0
        nextArrivalAttemptAt = nil

        // `.checking` while it runs, so Home shows progress rather than a
        // stale report. `scanTask`'s completion writes the terminal state.
        setArrivalState(.checking(depth: depth, startedAt: now), for: id)
        pendingArrivalDecline = declineWith
        pendingArrivalNetworkID = id
        pendingArrivalDepth = depth
    }

    /// Write one network's arrival state to both the store and the
    /// observable mirror, so the two cannot disagree.
    private func setArrivalState(_ state: ArrivalState, for id: String) {
        var all = Defaults.arrivalStates
        all[id] = state
        Defaults.arrivalStates = all
        if id == arrivalNetworkID { arrivalState = state }
    }
```

Add the three pending properties alongside the others from Step 2:

```swift
    /// Carried from `attemptArrival` to the scan's completion, which is
    /// where the terminal arrival state is written. Nil when the in-flight
    /// scan is not an arrival check.
    private var pendingArrivalNetworkID: String?
    private var pendingArrivalDepth: ArrivalDepth?
    private var pendingArrivalDecline: DeclineReason?
```

- [ ] **Step 4: Record the terminal state when the scan ends**

In `launch(depth:reason:target:adoptAsReport:)`, inside `scanTask`'s `do` block, immediately after `await self.history.load()`:

```swift
                await self.history.load()
                self.finishArrivalIfPending(runID: result.snapshot.runID)
```

and in the `catch` block that sets `lastRunError`, before the log line:

```swift
            } catch {
                // A failed arrival check must not read as done. Clearing
                // the pending id without writing a terminal state leaves
                // the network `.unchecked`, so the next sample retries —
                // which is the entire point of this change.
                self.pendingArrivalNetworkID = nil
                self.pendingArrivalDepth = nil
                self.pendingArrivalDecline = nil
                self.lastRunError = error.localizedDescription
                self.log.error("scan failed: \(error.localizedDescription, privacy: .public)")
            }
```

Do the same three-line clear in the `catch is CancellationError` block, above its `log.debug`.

Then add the method, next to `setArrivalState`:

```swift
    /// Write the terminal arrival state for a scan that has just landed.
    ///
    /// `.declined` when the policy chose the quick check for a reason the
    /// user can override, `.checked` otherwise. Both are terminal: neither
    /// retries. A network whose check failed or was cancelled never
    /// reaches here, and stays `.unchecked`.
    private func finishArrivalIfPending(runID: String?) {
        guard let id = pendingArrivalNetworkID, let depth = pendingArrivalDepth else { return }
        let decline = pendingArrivalDecline
        pendingArrivalNetworkID = nil
        pendingArrivalDepth = nil
        pendingArrivalDecline = nil

        if let decline {
            setArrivalState(.declined(depth: depth, reason: decline, at: Date()), for: id)
        } else {
            setArrivalState(.checked(depth: depth, at: Date(), runID: runID), for: id)
        }
        log.info("arrival check for \(id, privacy: .public) finished at \(depth.rawValue, privacy: .public)")
    }

    /// The arrival card's override button: run the full check the policy
    /// declined, and record it as the network's arrival check.
    func runDeclinedFullCheck() {
        guard let id = arrivalNetworkID else { return }
        guard runScan(depth: .full, reason: "you asked for the full check anyway") else { return }
        setArrivalState(.checking(depth: .full, startedAt: Date()), for: id)
        pendingArrivalNetworkID = id
        pendingArrivalDepth = .full
        pendingArrivalDecline = nil
    }
```

If `RunSnapshot` has no `runID`, pass `nil` and note it — the field is cosmetic here. Check with:

```bash
grep -n "runID\|run_id" gui/Sources/NetdiagGUI/Models/RunSnapshot.swift | head
```

- [ ] **Step 5: Verify it builds and nothing regressed**

```bash
cd /Users/bfreeman/Documents/AI-Workspace/netdiag_worktrees/arrival-state/gui
swift build -c release && ./.build/release/NetdiagGUI --verify 2>&1 | tail -3
```

Expected: `All checks passed.`

- [ ] **Step 6: Commit**

```bash
cd /Users/bfreeman/Documents/AI-Workspace/netdiag_worktrees/arrival-state
git add gui/Sources/NetdiagGUI/Models/MonitorSample.swift \
        gui/Sources/NetdiagGUI/Services/NetdiagCoordinator.swift
git commit -m "fix(gui): the arrival check retries until it actually runs

The reported bug. handleSample advanced lastNetworkID and *then* attempted
the arrival scan, so a scan declined for being busy was recorded as
nothing and every later sample returned at the id guard. The comment
promised 'the next sighting retries'; there is no next sighting while you
stay on the network. Leaving and rejoining was the only way out.

considerArrival now runs on every sample and is driven by the stored
state, with a 30s-doubling in-memory backoff capped at five minutes. A
decline for policy (hotspot, unhealthy link) records .declined and stops;
a decline for busy, a failure and a cancellation all leave .unchecked, so
the next sample tries again.

historyJoinID no longer returns a non-canonical string. nil means 'not
identified yet' and callers must not read it as 'a new network' — that
conflation is where the mixed keys came from."
```

---

## Task 8: The arrival card

**Files:**
- Create: `gui/Sources/NetdiagGUI/Views/ArrivalCard.swift`
- Modify: `gui/Sources/NetdiagGUI/Views/HomeView.swift`, `gui/Sources/NetdiagGUI/VerifyMode.swift`

Every string below is **mechanism** — what netdiag is doing and what it costs. None of it says whether the network is good. Verdict prose still comes from `diagnosis[].summary` verbatim.

- [ ] **Step 1: Write the failing copy checks**

Add to `VerifyMode.swift` before `private static func check(`:

```swift
    // MARK: - Arrival card copy
    private static func runArrivalCopyTests() {
        print("Arrival card:")

        let hotspot = ArrivalCopy.forState(
            .declined(depth: .quick, reason: .hotspot, at: Date()), network: "SB Airbnb")
        check(hotspot?.body.contains("hotspot") == true,
              "the hotspot decline says why")
        check(hotspot?.actionTitle != nil,
              "the hotspot decline offers the override")

        let unhealthy = ArrivalCopy.forState(
            .declined(depth: .quick, reason: .unhealthy, at: Date()), network: "SB Airbnb")
        check(unhealthy?.actionTitle != nil,
              "the unhealthy decline also offers the override")

        let checking = ArrivalCopy.forState(
            .checking(depth: .full, startedAt: Date()), network: "SB Airbnb")
        check(checking?.title.contains("SB Airbnb") == true,
              "a check in flight names the network")
        check(checking?.actionTitle == nil,
              "a check in flight offers no button")

        check(ArrivalCopy.forState(.unchecked, network: "SB Airbnb") != nil,
              "unchecked renders something rather than nothing")
        check(ArrivalCopy.forState(.checked(depth: .full, at: Date(), runID: nil),
                                   network: "SB Airbnb") == nil,
              "a checked network shows no card at all")

        // The GUI authors no verdicts. These are the words that would mean
        // this file had started diagnosing, which is lib/diagnosis.sh's
        // job — see AlertDefinitions.swift's header.
        let forbidden = ["slow", "bad", "poor", "unusable", "broken", "healthy", "good"]
        for state: ArrivalState in [
            .unchecked,
            .checking(depth: .full, startedAt: Date()),
            .declined(depth: .quick, reason: .hotspot, at: Date()),
            .declined(depth: .quick, reason: .unhealthy, at: Date()),
        ] {
            guard let copy = ArrivalCopy.forState(state, network: "SB Airbnb") else { continue }
            let text = (copy.title + " " + copy.body + " " + (copy.actionTitle ?? "")).lowercased()
            let hit = forbidden.first { text.contains($0) }
            check(hit == nil,
                  hit == nil
                    ? "\(state.debugLabel) copy states mechanism, not a verdict"
                    : "\(state.debugLabel) copy contains the verdict word \"\(hit!)\"")
        }
    }
```

Register in `run()` after `runArrivalMigrationTests()`:

```swift
        runArrivalMigrationTests()
        runArrivalCopyTests()
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd /Users/bfreeman/Documents/AI-Workspace/netdiag_worktrees/arrival-state/gui
swift build -c release 2>&1 | tail -20
```

Expected: FAIL, `cannot find 'ArrivalCopy' in scope`.

- [ ] **Step 3: Write the implementation**

Create `gui/Sources/NetdiagGUI/Views/ArrivalCard.swift`:

```swift
import SwiftUI

/// What the arrival card says, as plain values.
///
/// Split from the view for the same reason `FullCheckPolicy.controlLabel`
/// is: `VerifyMode` is the only runnable harness on this toolchain, and it
/// can assert on a struct where it cannot assert on a `View`. The copy
/// check that matters is the negative one — no verdict words — and it can
/// only run against something testable.
///
/// Mechanism only. Every string says what netdiag is doing and what it
/// costs. None says whether the network is any good; that is
/// `lib/diagnosis.sh`'s job and it reaches the UI through
/// `diagnosis[].summary` verbatim. See AlertDefinitions.swift's header.
struct ArrivalCopy {
    let title: String
    let body: String
    /// nil when there is nothing for the user to do but wait.
    var actionTitle: String?

    /// nil means "render no card" — the network has been checked and the
    /// report below speaks for itself.
    static func forState(_ state: ArrivalState, network: String?) -> ArrivalCopy? {
        let name = network ?? "this network"
        switch state {
        case .checked:
            return nil

        case .unchecked:
            return ArrivalCopy(
                title: "New network: \(name)",
                body: "netdiag hasn't measured this one yet. Starting a check.")

        case .checking(let depth, _):
            let what = depth == .full
                ? "Running a full check — speed, latency under load, path MTU and per-hop loss."
                : "Running a quick check."
            return ArrivalCopy(title: "New network: \(name)", body: what)

        case .declined(_, let reason, _):
            switch reason {
            case .hotspot:
                return ArrivalCopy(
                    title: "New network: \(name)",
                    body: """
                        This looks like a personal hotspot, so netdiag ran the quick check \
                        instead of the full one — a full check runs a speed test, which can \
                        spend a few hundred megabytes of cellular data.
                        """,
                    actionTitle: "Run full check anyway")
            case .unhealthy:
                return ArrivalCopy(
                    title: "New network: \(name)",
                    body: FullCheckPolicy.controlHelp(isSafe: false),
                    actionTitle: "Run full check anyway")
            }
        }
    }
}

/// The card at the top of Home whenever the current network has not been
/// checked. Renders `ArrivalCopy` and, while a check is in flight, the
/// existing scan progress rows.
struct ArrivalCard: View {
    let state: ArrivalState
    let network: String?
    let progress: ScanProgress?
    var onRunFullCheck: () -> Void

    var body: some View {
        if let copy = ArrivalCopy.forState(state, network: network) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if case .checking = state {
                        ProgressView().controlSize(.small)
                    } else if case .unchecked = state {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                    Text(copy.title).font(.headline)
                }
                Text(copy.body)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if case .checking = state, let progress {
                    ScanProgressView(progress: progress)
                }

                if let action = copy.actionTitle {
                    Button(action, action: onRunFullCheck)
                        .controlSize(.small)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
```

Check `Theme` for the correct background token before building — if `Theme.cardBackground` does not exist, use whatever the existing cards use:

```bash
grep -n "static var\|static let" gui/Sources/NetdiagGUI/Support/Theme.swift | head -20
grep -n "background(" gui/Sources/NetdiagGUI/Views/HomeView.swift | head -5
```

- [ ] **Step 4: Render it on Home**

In `HomeView.body`, replace the existing scan-progress block (lines 29–32) so the card owns arrival progress and the bare progress view only covers user-initiated scans:

```swift
                locationWarningBanner
                wifiRow

                ArrivalCard(state: coordinator.arrivalState,
                            network: coordinator.wifiDisplayName,
                            progress: coordinator.isScanning ? coordinator.progress : nil,
                            onRunFullCheck: { coordinator.runDeclinedFullCheck() })

                // Only for scans the arrival card is not already showing —
                // otherwise a new network renders two sets of progress rows.
                if coordinator.isScanning,
                   ArrivalCopy.forState(coordinator.arrivalState,
                                        network: coordinator.wifiDisplayName) == nil {
                    ScanProgressView(progress: coordinator.progress)
                    Divider()
                }
```

Confirm `wifiDisplayName` is the right accessor:

```bash
grep -n "wifiDisplayName" gui/Sources/NetdiagGUI/Services/NetdiagCoordinator.swift | head -3
```

- [ ] **Step 5: Run to verify it passes**

```bash
cd /Users/bfreeman/Documents/AI-Workspace/netdiag_worktrees/arrival-state/gui
swift build -c release && ./.build/release/NetdiagGUI --verify 2>&1 | grep -A 12 "^Arrival card:"
```

Expected: 10 `✔` lines, no `✘`. If the verdict-word check fails, the copy is diagnosing — reword it to describe what netdiag is doing, not what it found.

- [ ] **Step 6: Commit**

```bash
cd /Users/bfreeman/Documents/AI-Workspace/netdiag_worktrees/arrival-state
git add gui/Sources/NetdiagGUI/Views/ArrivalCard.swift gui/Sources/NetdiagGUI/Views/HomeView.swift \
        gui/Sources/NetdiagGUI/VerifyMode.swift
git commit -m "feat(gui): Home says which check is running, and on which network

The user's report was a brand-new network showing no evidence a check had
run, was running, or would run. The state existed nowhere and the UI had
nothing to render.

ArrivalCopy is split out from the view so --verify can assert on it,
including the negative check that matters: none of this copy may contain a
verdict word. The card says what netdiag is doing and what it costs; what
is wrong with a network still comes from diagnosis[].summary verbatim."
```

---

## Task 8A: The dropdown says the same thing Home does

Spec part A's last paragraph. Without this, an arrival check renders as `.testing` in the menu bar — indistinguishable from a scan the user started — while Home calls it a new-network check. The two surfaces must not describe one moment two ways; it is the same reason `SignalScale.cellContent` is shared between them.

**Files:**
- Modify: `gui/Sources/NetdiagGUI/Support/StageResolver.swift`, `gui/Sources/NetdiagGUI/Views/DropdownView.swift`, `gui/Sources/NetdiagGUI/VerifyMode.swift`

- [ ] **Step 1: Write the failing checks**

The harness already has an `inputs(...)` factory (search for `private static func inputs(`). Add the new parameter to it with a default of `false` so the ~40 existing call sites keep compiling, then add:

```swift
    // MARK: - Arrival stage
    private static func runArrivalStageTests() {
        print("Arrival stage:")

        check(StageResolver.resolve(inputs(isScanning: true, isArrivalCheck: true)) == .arrived,
              "a scan that is the arrival check reads as .arrived, not .testing")
        check(StageResolver.resolve(inputs(isScanning: true, isArrivalCheck: false)) == .testing,
              "a scan the user started still reads as .testing")
        check(StageResolver.resolve(inputs(isScanning: false, isArrivalCheck: true)) != .arrived,
              "arrival only shows while the check is actually running")

        // Precedence: a user pause outranks it, because the user's own
        // action outranks the app's — and .arrived must not resurrect a
        // stage while monitoring is off.
        check(StageResolver.resolve(inputs(isScanning: true, isArrivalCheck: true,
                                           monitoringEnabled: false)) == .paused(nil),
              "monitoring off outranks the arrival stage")
    }
```

Register in `run()` after `runArrivalCopyTests()`.

- [ ] **Step 2: Run to verify it fails**

```bash
cd /Users/bfreeman/Documents/AI-Workspace/netdiag_worktrees/arrival-state/gui
swift build -c release 2>&1 | tail -20
```

Expected: FAIL, `type 'StageResolver.Stage' has no member 'arrived'`.

- [ ] **Step 3: Add the stage**

In `StageResolver.Stage`, above `case testing`:

```swift
        /// A check running because this network is new to the app, as
        /// opposed to one the user started. Distinct from `.testing`
        /// purely so the menu bar and Home describe the same moment the
        /// same way — the dropdown used to call an arrival check "Testing",
        /// which reads as something the user did.
        case arrived
        case testing
```

In `Inputs`, alongside `isScanning`:

```swift
        let isScanning: Bool
        /// Whether the in-flight scan is this network's arrival check.
        /// Meaningless when `isScanning` is false.
        let isArrivalCheck: Bool
```

Add it to the memberwise `init` with `isArrivalCheck: Bool = false` so existing call sites are unaffected, and assign it.

In `resolve`, replace the first guard:

```swift
        if i.isScanning { return i.isArrivalCheck ? .arrived : .testing }
```

- [ ] **Step 4: Render it**

Find where `DropdownView` switches on `Stage` and give `.arrived` a case. Reuse `.testing`'s visual treatment exactly — same colour, same icon — and change only the wording, to something like "Checking a new network". Do **not** invent a verdict; this is mechanism, like every other string in this change.

```bash
grep -rn "case .testing" gui/Sources/NetdiagGUI/Views/ gui/Sources/NetdiagGUI/VerifyMode.swift
```

Every one of those switches needs the new case. A non-exhaustive switch will fail the build, which is the point.

Build the `Inputs` with the real value at the call site — the coordinator knows, because Task 7 gave it `pendingArrivalNetworkID`. Expose it:

```swift
    /// Whether the in-flight scan (if any) is an arrival check. Read by
    /// the dropdown's stage resolution.
    var isArrivalCheck: Bool { pendingArrivalNetworkID != nil }
```

- [ ] **Step 5: Run to verify it passes**

```bash
cd /Users/bfreeman/Documents/AI-Workspace/netdiag_worktrees/arrival-state/gui
swift build -c release && ./.build/release/NetdiagGUI --verify 2>&1 | grep -A 6 "^Arrival stage:"
```

Expected: 4 `✔` lines, no `✘`. Then confirm the whole harness still passes — adding an enum case can silently change an existing snapshot's switch:

```bash
./.build/release/NetdiagGUI --verify 2>&1 | tail -3
```

Expected: `All checks passed.`

- [ ] **Step 6: Commit**

```bash
cd /Users/bfreeman/Documents/AI-Workspace/netdiag_worktrees/arrival-state
git add gui/Sources/NetdiagGUI/Support/StageResolver.swift \
        gui/Sources/NetdiagGUI/Views/DropdownView.swift \
        gui/Sources/NetdiagGUI/Services/NetdiagCoordinator.swift \
        gui/Sources/NetdiagGUI/VerifyMode.swift
git commit -m "feat(gui): the menu bar calls an arrival check what it is

An arrival check set isScanning, so the dropdown rendered .testing —
indistinguishable from a scan the user started, while Home called it a
new-network check. One moment, two descriptions.

.arrived reuses .testing's visual treatment and changes only the wording.
Same reason SignalScale.cellContent is shared between the two surfaces."
```

---

## Task 9: Home stops showing another network's report

The second half of the report — the Wi-Fi warning "over the last hour", which belonged to a different network in a different building.

**Files:**
- Modify: `gui/Sources/NetdiagGUI/Services/NetdiagCoordinator.swift`, `gui/Sources/NetdiagGUI/Views/RunReportView.swift`, `gui/Sources/NetdiagGUI/Views/HomeView.swift`

- [ ] **Step 1: Scope hydration to the current network**

Read the current implementation first:

```bash
sed -n '215,255p' gui/Sources/NetdiagGUI/Services/NetdiagCoordinator.swift
grep -n "func recentChecks" -A 20 gui/Sources/NetdiagGUI/Services/HistoryStore.swift
```

`recentChecks(limit:)` returns records across all networks. Replace the id selection inside `hydrateFromHistoryIfNeeded`:

```swift
        if latestRun == nil, hydratedReport == nil {
            // Scoped to the network we are actually on. Unscoped, this
            // took the newest stored run *anywhere* and Home rendered it
            // through the same RunReportView as a live one, with nothing
            // on screen saying otherwise — so arriving somewhere new
            // showed the previous building's report as if it were this
            // network's. That is where the phantom "last hour" Wi-Fi
            // warning in the bug report came from.
            //
            // No run for this network is the correct empty state: the
            // arrival card is already saying a check is on its way.
            let current = monitor.latest?.network.historyJoinID
            let id = history.recentChecks(limit: 25)
                .first { current == nil || $0.networkID == current }
                .flatMap(\.runID)
            if let id {
                do {
                    hydratedReport = try await details.detail(for: id)
                } catch {
                    log.debug("cold-launch hydration skipped: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
```

Check what the record's network field is actually called — it may be `groupID`, `networkID` or nested:

```bash
grep -n "struct.*Check\|networkID\|groupID\|var runID" gui/Sources/NetdiagGUI/Models/HistoryDocument.swift | head -20
```

Canonicalise both sides of the comparison with `NetworkIdentity.canonical` if the stored form is raw.

- [ ] **Step 2: Add provenance to the report view**

In `RunReportView`, next to `presentation`:

```swift
    var presentation: Presentation = .full
    /// Where this report came from, when it is not self-evidently about
    /// the here and now. Rendered as a caption above the report.
    ///
    /// Exists because Home rendered a stored run from another network
    /// through this same view with nothing distinguishing it from a live
    /// one, and users read it as current. Task 9 scopes hydration so that
    /// specific case cannot recur; this closes the general one — any
    /// report whose network or age is not obvious says so.
    var provenance: String?
```

Render it as the first element of the view's outer `VStack`:

```swift
            if let provenance {
                Text(provenance)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
```

- [ ] **Step 3: Pass it from Home**

In `HomeView`, the `.stored` case:

```swift
                case .stored(let detail):
                    RunReportView(snapshot: detail.run, comparison: detail.comparison,
                                  rawJSON: detail.asRunResult.rawJSON,
                                  showRuleIDs: appSettings.expertExpanded,
                                  presentation: .home,
                                  provenance: storedProvenance(detail))
```

and add the helper to `HomeView`:

```swift
    /// A stored run is only unremarkable when it is about the network you
    /// are on. Anything else is labelled, because an unlabelled report
    /// from an hour ago somewhere else is indistinguishable from a live
    /// one — which is exactly how a Wi-Fi warning about a previous
    /// building ended up at the top of a brand-new network's dashboard.
    private func storedProvenance(_ detail: RunDetail) -> String? {
        let name = detail.run.network?.label ?? detail.run.network?.id
        let when = RelativeTime.phrase(for: detail.run.timestamp)
        guard let name else { return "Last check, \(when)" }
        return "Last check on \(name), \(when)"
    }
```

Check the real accessor names first — `RunSnapshot.network`, its label field, the timestamp field, and `RelativeTime`'s API:

```bash
grep -n "var label\|var id\|var timestamp\|struct Network" gui/Sources/NetdiagGUI/Models/RunSnapshot.swift | head
grep -n "static func" gui/Sources/NetdiagGUI/Support/RelativeTime.swift
```

- [ ] **Step 4: Verify**

```bash
cd /Users/bfreeman/Documents/AI-Workspace/netdiag_worktrees/arrival-state/gui
swift build -c release && ./.build/release/NetdiagGUI --verify 2>&1 | tail -3
```

Expected: `All checks passed.`

- [ ] **Step 5: Commit**

```bash
cd /Users/bfreeman/Documents/AI-Workspace/netdiag_worktrees/arrival-state
git add gui/Sources/NetdiagGUI/Services/NetdiagCoordinator.swift \
        gui/Sources/NetdiagGUI/Views/RunReportView.swift \
        gui/Sources/NetdiagGUI/Views/HomeView.swift
git commit -m "fix(gui): Home no longer shows another network's report unlabelled

hydrateFromHistoryIfNeeded took the newest stored run globally, with no
network predicate, and Home rendered it through the same RunReportView as
a live one. Arriving somewhere new, that is the previous building's
report presented as this network's — the phantom 'Wi-Fi over the last
hour' warning in the bug report.

Hydration is now scoped to the current network; no run for it is the
correct empty state, because the arrival card is already saying a check is
on its way. RunReportView gains provenance so the general case is closed
too: any report whose network or age is not obvious now says both."
```

---

## Task 10: Arrival-card snapshots

The existing `stage-*.png` set exists so the dropdown's card can be eyeballed without launching the app. The arrival card needs the same.

**Files:**
- Modify: `gui/Sources/NetdiagGUI/VerifyMode.swift`

- [ ] **Step 1: Confirm the renderer you are reusing**

```bash
cd /Users/bfreeman/Documents/AI-Workspace/netdiag_worktrees/arrival-state
sed -n '855,935p' gui/Sources/NetdiagGUI/VerifyMode.swift
```

Expected: `renderImage(_ view: some View, size: NSSize) -> NSImage?` at ~857, `writePNG(_ image: NSImage, to path: String, name: String)` at ~929, and `let dir = "/tmp/opencode/verify"` at ~872. Reuse all three as-is; do not add a second snapshot path.

- [ ] **Step 2: Add the snapshot pass**

Add to `VerifyMode.swift`, directly above `private static func writePNG(`:

```swift
    /// The arrival card, rendered offscreen per state, for the same reason
    /// the stage cards are: the card at the top of Home cannot be
    /// screenshotted from the menu-bar dropdown, and joining five
    /// different networks to see five states is not a workflow.
    ///
    /// `progress: nil` on the two `.checking` states deliberately — the
    /// scan progress rows have their own coverage, and a live ScanProgress
    /// cannot be constructed here without a running child process. What is
    /// being checked is the card's own copy and layout.
    private static func renderArrivalCards() {
        print("Render arrival-card snapshots:")
        let dir = "/tmp/opencode/verify"
        let now = Date()
        let states: [(String, ArrivalState)] = [
            ("unchecked",          .unchecked),
            ("checking-full",      .checking(depth: .full, startedAt: now)),
            ("checking-quick",     .checking(depth: .quick, startedAt: now)),
            ("declined-hotspot",   .declined(depth: .quick, reason: .hotspot, at: now)),
            ("declined-unhealthy", .declined(depth: .quick, reason: .unhealthy, at: now)),
        ]
        for (name, state) in states {
            // Taller than the stage cards: the hotspot copy is three lines
            // plus a button, where a stage card is one line plus a title.
            guard let image = renderImage(
                ArrivalCard(state: state, network: "SB Airbnb",
                            progress: nil, onRunFullCheck: {})
                    .frame(width: 360).padding(4),
                size: NSSize(width: 368, height: 170)) else {
                print("  \u{2718} arrival-\(name) — could not allocate bitmap representation")
                failures.append("render-arrival-\(name)")
                continue
            }
            writePNG(image, to: "\(dir)/arrival-\(name).png", name: "arrival-\(name)")
        }
    }
```

Register it in `run()` immediately after the existing stage-card render call.

- [ ] **Step 3: Run and look at the output**

```bash
cd /Users/bfreeman/Documents/AI-Workspace/netdiag_worktrees/arrival-state/gui
swift build -c release && ./.build/release/NetdiagGUI --verify 2>&1 | grep -A 8 "arrival-card snapshots"
open /tmp/opencode/verify/arrival-declined-hotspot.png
```

Expected: five `✔ wrote …` lines. Open each PNG and confirm the text is not clipped, the button is visible on both declined states, and the hotspot copy reads as an explanation of cost rather than a warning about the network.

- [ ] **Step 4: Commit**

```bash
cd /Users/bfreeman/Documents/AI-Workspace/netdiag_worktrees/arrival-state
git add gui/Sources/NetdiagGUI/VerifyMode.swift
git commit -m "test(gui): render the arrival card offscreen, one PNG per state

Same reason as the stage cards: the card at the top of Home cannot be
screenshotted from the dropdown, and joining four different networks to
see four states is not a workflow."
```

---

## Task 11: Verify against reality, then document

Nothing above proves the app behaves correctly on a real network join. This task does, and reports honestly if it cannot.

**Files:**
- Modify: `CHANGELOG.md`, `docs/ARCHITECTURE.md`

- [ ] **Step 1: Full suite, both halves**

```bash
cd /Users/bfreeman/Documents/AI-Workspace/netdiag_worktrees/arrival-state
bats tests/ 2>&1 | tail -3
cd gui && swift build -c release && ./.build/release/NetdiagGUI --verify 2>&1 | tail -3
```

Expected: `841 tests, 0 failures`, and `All checks passed.` Do not continue past a failure.

- [ ] **Step 2: shellcheck**

```bash
cd /Users/bfreeman/Documents/AI-Workspace/netdiag_worktrees/arrival-state
shellcheck bin/netdiag lib/*.sh
```

Expected: no output. (This work is GUI-side, so this should be untouched — it is here to catch an accidental edit.)

- [ ] **Step 3: Exercise the state machine without changing networks**

Joining five networks to test five states is impractical. Drive it through defaults instead:

```bash
# Back up the real state first.
defaults read com.godigi.netdiag arrivalStates > /tmp/arrivalStates.backup 2>/dev/null || true

# Force the current network back to unchecked and relaunch.
defaults delete com.godigi.netdiag arrivalStates
cd /Users/bfreeman/Documents/AI-Workspace/netdiag_worktrees/arrival-state/gui
make sign && open build/Netdiag.app
```

Expected, in the app: Home shows the arrival card naming the current network, a check starts within one monitor cycle, the card shows progress rows, and when it finishes the card disappears and the report is about *this* network. Confirm the state landed:

```bash
defaults read com.godigi.netdiag arrivalStates
```

Expected: JSON containing one canonical `mac:`/`ssid:`/`gw:` key with `"kind":"checked"`.

- [ ] **Step 4: Exercise the retry that was broken**

The original bug is a decline while a scan is in flight. Reproduce it:

```bash
defaults delete com.godigi.netdiag arrivalStates
```

Relaunch, and immediately press **Full check** in the app so a manual scan is running when the first sample lands. The arrival attempt will be declined.

Expected: the arrival card stays visible with its spinner, and within ~30 s of the manual scan finishing the arrival check starts on its own. Before this change, that retry never happened. Confirm in the log:

```bash
log show --last 10m --predicate 'subsystem == "com.godigi.netdiag"' --info --style compact \
  | grep -i arrival
```

Note: `info`-level logs are not always persisted on this machine. If the grep is empty, say so rather than claiming the retry was observed — the visible behaviour in Step 4 is the real evidence.

- [ ] **Step 5: Restore your own state**

```bash
# If Step 3's backup has content and you want your real history back:
cat /tmp/arrivalStates.backup
```

Leave the app in whatever state the test produced — it is correct data, just freshly gathered.

- [ ] **Step 6: Write the CHANGELOG entry**

Read the last three entries first and match their voice and numbering:

```bash
tail -60 /Users/bfreeman/Documents/AI-Workspace/netdiag_worktrees/arrival-state/CHANGELOG.md
```

Cover, in the project's own register: the arrival check that could decline itself permanently and how (`lastNetworkID` advanced before the attempt); Home showing another network's report unlabelled; the three id forms one hotspot had accumulated; the hotspot carve-out and why it exists; and the fail-closed migration.

- [ ] **Step 7: Note the decision in ARCHITECTURE.md**

Find the section covering GUI/CLI division and add a short paragraph: arrival state lives in the GUI because it is about *this install's* history with a network, which the CLI has no concept of; the depth decision reuses `FullCheckPolicy`'s allow-list rather than restating it; and no threshold was added.

- [ ] **Step 8: Bump the version**

```bash
grep -n 'NETDIAG_VERSION=' bin/netdiag
```

Bump the minor: `0.13.1` → `0.14.0`. This adds a defaults key and changes arrival behaviour.

- [ ] **Step 9: Final commit**

```bash
cd /Users/bfreeman/Documents/AI-Workspace/netdiag_worktrees/arrival-state
git add CHANGELOG.md docs/ARCHITECTURE.md bin/netdiag
git commit -m "docs: arrival state, and bump to 0.14.0"
```

- [ ] **Step 10: Hand back**

Do **not** merge to `main` unprompted. Report: the bats count, the `--verify` result, what Steps 3 and 4 actually showed, and anything that could not be verified. Then use `superpowers:finishing-a-development-branch` to decide how this lands.

---

## Notes for whoever executes this

- **Order matters.** Tasks 1→2→3→4→6→7 are a dependency chain. Task 5 is independent and can move, but must land before 7 (which reads the cost flags). Tasks 8, 8A, 9 and 10 all depend on 7; among themselves they are independent.
- **Task 7 is the one that fixes the reported bug.** If time runs short, everything through 7 is a coherent shippable change; 8–10 are what make it visible.
- **Task 8A adds an enum case to `StageResolver.Stage`.** Every switch over it must gain a case or the build fails — that is deliberate, not an obstacle to route around with a `default:`.
- **Verify each step's expected output before moving on.** Several steps deliberately expect a *failure* — a step that passes when it should fail means the test is not testing anything.
- **Do not add a number that judges a network.** If a task seems to need one, it is wrong; re-read CLAUDE.md's thresholds rule.
