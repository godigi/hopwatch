# Arrival, and the three modes

**Date:** 2026-08-31
**Status:** approved (design)
**Supersedes nothing.** Extends `2026-08-29-arriving-somewhere-new-design.md`,
which specified *what* an arrival card should say. This one specifies *when the
app knows it has arrived*, and why the previous attempt did not fire.

---

## The report that started this

A user joined a brand-new network, "SB Airbnb", opened the dashboard, and saw:

- no full check running, none queued, and no evidence one had ever run;
- at the top of the window, a Wi-Fi warning describing "the last hour" — an hour
  that was spent on a different network in a different building.

Both are true bugs, not misreadings. What follows is what was actually wrong.

---

## What was actually wrong

Three defects, each verified against the running app's `UserDefaults` and the
code on `main` at `c729ab4`.

### 1. The one automatic full check can decline itself permanently

`NetdiagCoordinator.handleSample` advances `lastNetworkID` *before* it attempts
the arrival scan:

```swift
guard id != lastNetworkID else { return }
lastNetworkID = id                       // ← committed here
…
guard runFullCheck(reason: "new network") else {
    log.debug("… left unseen so the next sighting retries")
    return
}
Defaults.seenNetworks.insert(id)         // ← only on success
```

`launch()` silently declines when a scan is already in flight. The comment
claims "the next sighting retries", but there is no next sighting: `id` equals
`lastNetworkID` on every subsequent sample, so the function returns at the guard
above forever. The only way to retry is to leave the network and rejoin it.

**Evidence this is what happened.** In the live defaults, `networkNames` contains
`"mac:24:fd:d:d2:c2:19" = "SB Airbnb"` — the app saw the network and adopted its
name — while `seenNetworks` does not contain that key. Name adopted, baseline
never taken. That pair of facts is only reachable through this path.

### 2. Home shows another network's report, unlabelled

`hydrateFromHistoryIfNeeded` populates the cold-launch report with:

```swift
history.recentChecks(limit: 1).compactMap(\.runID).first
```

The most recent stored run *globally* — no network predicate. Arriving somewhere
new with no run of your own, Home renders the last run from wherever you were
before, through the same `RunReportView` that renders a live one, with nothing on
screen distinguishing the two. The "last hour" Wi-Fi warning is that report.

This is a class of bug, not an instance: any Home surface that reads history
without scoping to the current network can do the same thing.

### 3. Network identity is not stable, so "first sighting" is not reliable

`MonitorSample.Network.historyJoinID` is `groupId ?? id`, where `id` is the
*record* format. When the CLI has not yet resolved a group, the fallback yields a
record-format string that will never match the canonical one.

The live defaults show the damage — `seenNetworks` holds all three of:

```
"gw:10.125.128.1"          "wifi:gw=10.125.128.1"       "mac:76:42:18:5c:40:64"
```

for one iPhone hotspot, and `networkNames` maps both `gw:172.20.10.1` and
`mac:64:d1:54:4a:93:7f` to "Mercure". `helpers/history.py` already solves this —
`mac:` > `ssid:` > `gw:`, plus a pass at line 444 folding weak keys onto the MAC
group they belong to. The GUI never got that logic.

Consequence: a network can be marked seen under one key and present under
another (arrival fires twice), or vice versa (arrival never fires again).

---

## The model this app is supposed to implement

Written here because it has drifted repeatedly, and is being added to `CLAUDE.md`
in the same change so it becomes load-bearing.

There are exactly **three** depths, and they answer three different questions.

| | **Monitoring** | **Full check** | **Quick check** |
|---|---|---|---|
| Question | *Is it still fine?* | *What is this network actually capable of?* | *What is wrong right now?* |
| Cadence | continuous, every few seconds | on demand; automatically **once** per new network | on demand; automatically on arrival when a full check is unsafe or unwise |
| Cost | negligible; no saturation | ~65–115 s; **deliberately saturates the link** | ~8 s; never saturates |
| Produces | one compact sample per cycle, alerts on transitions | bufferbloat, speed, path MTU, per-hop loss | everything else |
| Never | writes to disk (`--monitor`'s contract) | runs on a timer | claims to have measured throughput |

**The rule the GUI keeps breaking:** the app must always show *which of the three
is happening, and which one produced what is on screen.* A number with no depth
attached is a number the user cannot act on.

Two existing constraints stay exactly as they are, and this design does not
touch them: full checks are never on a timer
(`netdiag-monitoring-vs-full-checks`), and every threshold lives in
`lib/thresholds.sh` with no verdict authored in Swift (`CLAUDE.md`).

---

## The design

Five parts. A–C fix arrival; D fixes the identity it depends on; E fixes the
class of bug that produced the phantom warning.

### A. Arrival is a state the UI renders, not a side effect

Introduce `ArrivalState`, persisted per canonical network id:

```swift
enum ArrivalState: Codable, Sendable {
    case unchecked                       // seen, never successfully checked
    case checking(Depth, startedAt: Date)
    case checked(Depth, at: Date, runID: String?)
    case declined(Depth, reason: DeclineReason, at: Date)
}
```

`declined` is a distinct case from `unchecked` because it is a state the user can
act on: it carries a button. `unchecked` carries a spinner.

Home gains an **arrival card**, rendered above everything else whenever the
current network's state is anything but `.checked`:

- `unchecked` → "New network: SB Airbnb. Starting a full check…"
- `checking` → the same line plus the existing `ScanProgressView` rows
- `declined(.full, .hotspot)` → "This looks like a personal hotspot, so netdiag
  ran the quick check instead of the full one — a full check runs a speed test,
  which can spend a few hundred megabytes of cellular data."
  · **[Run full check anyway]**

  (The figure is deliberately vague: the transfer is whatever the speedtest CLI
  decides to move at the link's speed, and netdiag does not measure it. Do not
  replace "a few hundred megabytes" with a specific number we cannot stand
  behind.)
- `declined(.full, .unhealthy)` → the `FullCheckPolicy.controlHelp` string that
  already exists, plus the same button.

All prose above is *mechanism*, never a verdict — it says what netdiag did and
what it costs, and nothing about whether the network is good. Verdicts continue
to come from `diagnosis[].summary` verbatim. This is the contract in
`AlertDefinitions.swift`'s header and it is not being relaxed.

`StageResolver` gains a corresponding `.arrived` stage so the menu-bar dropdown
and Home cannot describe the same moment differently — the same reason
`SignalScale.cellContent` is shared.

### B. Arrival retries until it succeeds

`seenNetworks: Set<String>` is replaced by `arrivalStates: [String: ArrivalState]`.
`Defaults` gains a one-time migration that reads the old set, folds each key to
canonical form (part D), and records `.checked(.full, at: .distantPast, runID: nil)`
so existing networks are not all re-checked on upgrade.

The retry rule:

- `lastNetworkID` still guards the *log line and the alert engine's* notification
  of a network change — that part is correct and stays.
- The arrival attempt moves out from behind that guard. It is driven by
  `arrivalStates[id]`, so it re-attempts on every sample while the state is
  `.unchecked`, subject to a backoff (`min(30s * 2^n, 5 min)`) held in memory
  only.
- A declined-because-busy attempt leaves the state `.unchecked`. A declined-
  because-policy attempt records `.declined`, which does *not* retry — that one
  is a decision, not a failure.
- `.checking` older than the depth's estimate × 3 is treated as `.unchecked`:
  a crash mid-scan must not wedge a network permanently.

### C. Decide full-vs-lighter from a real sample, not from a missing one

`FullCheckPolicy.isSafe` treats any severity outside `{ok, info, warn}` as
unsafe. That allow-list is right, and stays. The bug is *when it is asked*: at
arrival the monitor has produced no sample, severity is `""`, and the policy
correctly answers "I do not understand this, so no" — which silently downgraded
essentially every arrival to the lighter check.

The fix is to not ask yet. `ArrivalPolicy.decide` returns a three-valued result:

```swift
enum Decision { case full, quick(DeclineReason), wait }
```

- no sample yet → `.wait` (state stays `.unchecked`, backoff does not advance)
- `path.isExpensive || path.isConstrained` → `.quick(.hotspot)`
- `!FullCheckPolicy.isSafe(severity:)` → `.quick(.unhealthy)`
- otherwise → `.full`

`isExpensive`/`isConstrained` come free: `NetworkEventWatcher` already runs an
`NWPathMonitor`. It needs to publish those two flags, which it currently drops.

`ArrivalPolicy` is a pure function over `(severity, isExpensive, isConstrained,
hasSample)` for the same reason `FullCheckPolicy` and `StageResolver` are pure —
`VerifyMode` is the only runnable harness on this toolchain and it cannot build a
coordinator.

**Answering the report directly:** on SB Airbnb — ordinary Wi-Fi, not a hotspot —
this yields `.full`. Every new network gets a full check. The hotspot carve-out
is the single exception, it is visible on screen, and it is one button away from
being overridden.

### D. One canonical network identity

New `NetworkIdentity` enum, porting `helpers/history.py`'s rule into Swift:

```swift
static func canonical(_ raw: String) -> String?   // record form → mac:/ssid:/gw:
static func fold(_ ids: Set<String>) -> [String: String]   // weak keys → their MAC group
```

Strength order `mac:` > `ssid:` > `gw:`, identical to history.py. Anything that
canonicalises to nothing returns `nil`, and **`nil` means "do not decide yet"** —
never "new network". That single change removes the `groupId ?? id` fallback that
seeded the mixed keys.

`historyJoinID` becomes `groupId.flatMap(NetworkIdentity.canonical)`, with `id`
used only as a last-resort display value, never as a dictionary key.
`arrivalStates`, `networkNames` and the alert engine's per-network memory all key
on the canonical form, and the migration folds existing entries.

A bats-style guard, in `VerifyMode`: a table of raw record strings and their
expected canonical form, shared with a new `tests/test_network_identity.bats`
reading the same fixture, so the Swift and Python rules cannot drift. This is the
same shape as the existing `test_thresholds.bats` guard, for the same reason.

### E. Nothing on Home is unlabelled cross-network data

Two changes:

1. `hydrateFromHistoryIfNeeded` takes a network predicate and hydrates only from
   runs on the *current* canonical id. With no such run, Home shows the arrival
   card and the empty state — not another network's report.
2. `RunReportView.presentation` gains a `provenance` field: the network name and
   relative time a report came from. `.home` renders it as a caption whenever the
   report is not both (a) from the current network and (b) from this session.
   `.stored` (the Runs tab) always renders it — that is a browser, and the
   context is the point.

The general rule, added to `CLAUDE.md` alongside the three-mode table: **any Home
surface reading history must scope to the current network or state its
provenance.** The alert engine's window carries the same obligation, which is
what makes the "last hour" warning stop being possible rather than merely fixed.

---

## What is deliberately not in scope

- **No new thresholds.** Nothing here judges a network. `ArrivalPolicy` reads
  severity as an opaque string, exactly as `FullCheckPolicy` does today.
- **No timed full checks.** The trigger remains "new network, once" plus the
  user's own button.
- **No change to the CLI.** Every part of this is GUI-side. `--quick`, `--json`
  and `--monitor` are untouched.
- **Not re-litigating the arrival card's *content*** — that is the 2026-08-29
  spec, and where it already specifies wording, that wording wins.

---

## Testing

`VerifyMode` (the only runnable Swift harness — `swift test` is a no-op on this
toolchain):

- `ArrivalPolicy.decide` across the full cross-product of
  `(hasSample × severity × isExpensive × isConstrained)`, including the
  regression case that started this: no sample ⇒ `.wait`, never `.quick`.
- The `ArrivalState` machine: declined-busy retries, declined-policy does not,
  stale `.checking` recovers, migration maps an old `seenNetworks` set correctly.
- `NetworkIdentity.canonical`/`fold` against the shared fixture, including the
  three real mixed keys from the live defaults.
- Arrival-card snapshot renders for each state, alongside the existing
  `stage-*.png` set.

bats:

- `tests/test_network_identity.bats` reads the same fixture through
  `helpers/history.py` and asserts identical output.

Manual, on this machine, and reported honestly: join a network the app has never
seen and confirm the arrival card appears, the full check runs, and Home shows
that network's report rather than the previous one's.

---

## Risk

The migration is the sharp edge. Reading it wrong re-checks every known network
on next launch — noisy, and on a hotspot, expensive. It is therefore written to
fail closed: anything it cannot confidently fold becomes
`.checked(at: .distantPast)`, i.e. "assume seen". A network wrongly assumed seen
loses one automatic baseline and is one button away from getting it; a network
wrongly assumed new can spend a few hundred megabytes of someone's cellular data
without asking.
