# Arriving somewhere new

**Date:** 2026-08-29 · **Status:** proposed design, pre-plan

**Mockups** (workspace-local, `nimbalyst-local/` is gitignored):
`nimbalyst-local/mockups/netdiag-arrival-card.mockup.html`,
`netdiag-activity-episodes.mockup.html`,
`netdiag-suitability-and-fixes.mockup.html`.

## Goal

netdiag answers questions when you ask them. For someone travelling with a
laptop, the questions arrive when they *join a network* — and by then they
are already trying to take the call.

Five parts, one theme: make joining a network the moment the app speaks, and
give it something worth saying. Two of the five are CLI work that does not
exist (per-activity suitability, structured fixes); three are GUI work
rendering CLI output that already exists and is never read.

Every claim below was traced to a file and a line in this checkout at
`30f12b7`. Where a thing is asserted not to exist, the grep that found
nothing is named.

**Out of scope:** the menu-bar label (still a coloured dot; deliberately
left alone). Any new *threshold* — Part A is explicitly designed to add no
cutoffs at all, for the reason in §A.2. Automatic captive-portal sign-in.
Anything that would put a verdict string into Swift.

---

## What already exists (and is not being rebuilt)

Worth stating plainly, because three of the five parts are surfacing work
and a reader who assumes otherwise will over-scope the plan.

| Capability | Where | Reached by the GUI? |
|---|---|---|
| Outages paired into episodes with durations | `helpers/events.py`, `netdiag --events=HOURS` (`bin/netdiag:312`, `:618`) | **No** — `grep -rn '\-\-events' gui/Sources` returns nothing |
| Episodes *judged* (AV-1 / AV-2) | `lib/availability.sh`, `lib/diagnosis.sh:534-559` | Only as diagnosis prose inside a scan report |
| Event journal | `--monitor --journal PATH`, `--install-recorder` | **No** — `MonitorStream.swift:155` passes no `--journal` |
| Per-network judged medians | `netdiag --history`'s `judged` block | Networks view stats only, never at the moment you rejoin |
| Per-rule plain-English prose | `helpers/rules_catalog.py`, `--rules-catalog` | Yes — `RulesCatalogStore` |
| Remediation advice | Embedded in `diagnosis[].summary` prose ("Fix: enable Smart Queue Management…", `lib/diagnosis.sh:284`) | Rendered as part of the paragraph; not separable, not rankable |
| A network's identity across visits | `historyJoinID`, `lib/netid.sh`, rename/merge | Yes |

The previous spec (`2026-08-25-reachable-features-design.md`) explicitly
deferred "an *act on this diagnosis* layer (open the router's admin page,
copy the advice)". Part B is that layer, taken up deliberately.

---

## Part A — What this network is good for

### A.1 The problem

The report says `Bufferbloat grade F` and `MTU 1492`. A non-expert cannot
convert either into the only question they have, which is whether the thing
they are about to do will work. The prose sometimes tells them anyway —
`lib/diagnosis.sh:284` says calls "will glitch" — but only for the rules
whose author happened to mention it, only inside a paragraph, and never as a
thing you can look at first.

### A.2 The design: a projection, not a second opinion

`--json` gains a `suitability` array, one entry per activity:

```jsonc
"suitability": [
  {
    "activity": "calls",
    "label": "Video & voice calls",
    "verdict": "broken",              // good | degraded | broken | unmeasured
    "because": ["B1"],                // the rules that decided it
    "unmeasured_reason": null         // set only when verdict is "unmeasured"
  }
]
```

Four activities, chosen 2026-08-29: `calls` (video & voice), `streaming`,
`gaming`, `browsing` (ordinary web).

**The verdict is derived from which rules fired, never from re-reading the
metrics.** This is the load-bearing decision in the whole spec. A
suitability layer that judged `bufferbloat_gw_ms` for itself would be a
fifth judge of a number, next to `lib/diagnosis.sh`, `lib/monitor.sh`,
`helpers/history.py` and `helpers/summary.py` — the exact drift CLAUDE.md's
thresholds rule exists to prevent, and the one that ends with a green
"Calls: fine" row above a red B1 paragraph. Deriving from the fired rule set
makes that contradiction structurally impossible: if no rule fired, nothing
is broken.

Mechanically:

1. `helpers/rules_catalog.py` gains an `impacts` map per rule — the activity
   → impact table. `G2` (router dropping packets) is
   `{"calls": "broken", "gaming": "broken", "streaming": "degraded",
   "browsing": "degraded"}`. Rules with no activity consequence
   (`NT-1` clock drift, `DH-1` lease) carry no `impacts` and contribute
   nothing.
2. `helpers/suitability.py` imports that table, takes this run's fired rule
   IDs plus the set of metrics that came back non-null, and emits the array.
   Worst impact wins. It reads no thresholds and imports nothing from
   `lib/`; `tests/test_thresholds.bats` therefore does not need to grow a
   fifth guarded file, and the spec asserts it must stay that way.
3. `emit_json.py` calls it and inlines the result. `lib/output.sh` renders
   the same four rows in the human-readable report.

### A.3 `unmeasured` is a first-class verdict

A `--quick` run skips bufferbloat, speed, and the loss probe, so `calls`
genuinely cannot be judged. The row still renders, saying so, with the
reason: *"Not measured — run a full check."* Hiding the row instead would
make the panel grow and shrink between depths, which reads as the app
losing information it never had.

The measured test is the schema's existing contract: a metric is `null`
when its probe did not run (`docs/JSON-SCHEMA.md:36`). Each activity
declares which metric keys it depends on; all-null dependencies →
`unmeasured`. A rule that fired outranks this — a connection that is down is
down at any depth.

### A.4 Catalog schema bump

`--rules-catalog` goes `schema: 4` → `5`, adding `impacts` as an optional
per-rule field. Additive, per the guarantee at `docs/JSON-SCHEMA.md`'s
rules-catalog section. `tests/test_rules_catalog.bats` gains an assertion
that every activity key in every `impacts` map is one of the four, and that
every impact value is one of `broken` / `degraded`.

---

## Part B — The fix, lifted out of the paragraph

### B.1 The problem

The advice is already written and already good. It is unreachable as data:
`add_diag` (`lib/common.sh:403`) takes `severity`, `rule`, and then `$*` as
one string, so "Fix: enable Smart Queue Management or QoS in your router's
admin page" is a substring of a paragraph. Nothing can rank it, show it
first, or hide it.

Worse for the traveller: it is often the wrong advice. "Reboot your router"
is sound at home and useless in a hotel, where the router is behind the
front desk.

### B.2 The design: fixes live in the catalog, not in `add_diag`

**`add_diag` is not touched.** Changing its signature would mean editing
every call site in `lib/diagnosis.sh` (52 KB) and `lib/wan.sh` for a field
that is general advice about a rule rather than a fact about this incident —
which is precisely what the rules catalog already holds (`blurb`). So each
catalog rule gains:

```jsonc
{
  "id": "G2",
  "fix": "Reboot your router: unplug it, wait ten seconds, plug it back in.",
  "fix_away": "Ask whoever runs this network to restart the router — tell them your Mac is losing packets to it while the Wi-Fi signal is strong.",
  "fix_target": "your_router"     // you | your_router | your_isp | network_operator
}
```

`fix_away` is present only where the advice genuinely changes when the
equipment is not yours — `your_router` and `network_operator` targets. For
`you` (something on this Mac) and `your_isp` the single `fix` serves both.

Both strings are CLI-authored. The GUI's entire contribution is choosing
between two CLI sentences using a fact it legitimately owns.

### B.3 "Is this network yours?"

That fact is a new per-network flag in `HistoryDocument`, toggled in the
Networks view: **"I control the equipment on this network."** Default
**off** — the safe default for a traveller, and the one that yields the
advice that is at worst redundant ("ask whoever runs this network") rather
than actively wrong.

Not inferred from visit count. A daily office is visited more than a home
and is not yours; a holiday flat is yours for a week. A guess here produces
confidently wrong instructions, and the toggle costs one click, once,
per network you actually own.

### B.4 Rendering

`RunReportView` shows the fix under each diagnosis row as a distinct,
selectable line with a target chip ("your router" / "your ISP" / "this
network's staff"). The arrival card (Part C) shows only the top one.

---

## Part C — The arrival card

### C.1 The problem

Joining a network is currently silent. `NetdiagCoordinator.handleSample`
(`:291-328`) notices the new `historyJoinID`, opens the alert grace period,
and — only if the network has never been seen — starts one full check whose
result lands in Home like any other. Nothing announces it. Nothing appears
in the menu bar.

And the check is once per network **for the life of the install**:
`Defaults.seenNetworks` is a set that is never pruned (`:302-303`,
`:326-328`). Return to that hotel next year and nothing re-checks.

### C.2 The design

**Depth policy changes; the guard does not disappear.** A new
`ArrivalPolicy` (pure, in `Support/`, testable from `VerifyMode` the same
way `FullCheckPolicy` and `StageResolver` are):

- Network never seen → **full check**. Unchanged: first sighting is exactly
  when a throughput/bufferbloat/MTU baseline is worth having.
- Network seen before → **quick check**, every time you rejoin.
  "Rejoin" means the `historyJoinID` changed (`NetdiagCoordinator.swift:291`),
  which is a different *network*. Roaming between two access points on one
  SSID does not change it and must not trigger a check — that event fires
  constantly on a large site and would turn the policy into a probe loop.
- `FullCheckPolicy` still overrides downward: a link already reporting
  `critical` gets the lighter depth regardless, because saturating a
  struggling link is the one thing the app must not do
  (`FullCheckPolicy.swift:1-21`).

`seenNetworks` survives, demoted: it now decides *depth*, not *whether*.
The write-after-start ordering at `:322-328` — and its reason (a network
marked seen on a scan that never started never gets its baseline) — is
preserved verbatim.

**A new dropdown stage.** `StageResolver.Stage` gains
`.arrived(ArrivalSnapshot)`, ranked above `.healthy` and below `.alerted`:
an active alert is more urgent than an arrival summary. The stage shows:

1. The network name and how long you have been on it.
2. The CLI's headline verdict.
3. The four suitability rows (Part A) — the substance of the card.
4. The single highest-severity fix (Part B), with its target chip.
5. One memory line, if this network has history (Part E).

It expires: sixty seconds after the check lands, or immediately on dismiss,
or when any other stage outranks it. An arrival card still sitting there an
hour later would be lying about what "arrived" means.

**Notification only when something is not good.** Fires when any suitability
verdict is `degraded`/`broken`, or any diagnosis is `warn` or above.
A clean network is silent. This follows the stance in
`AlertDefinitions.swift:5-11` — notification fatigue is the most likely
cause of the app being switched off — and it is the reason a commuter
joining five networks a day is not notified five times.

The notification body is the CLI's, verbatim, exactly as
`AlertDefinitions.swift:16-24` requires. Where the card wants a sentence
for "you just joined X", that sentence names the network and nothing else —
navigation, not diagnosis.

---

## Part D — Activity becomes episodes

### D.1 The problem

`ActivityView` renders `coordinator.eventLog` — individual change records —
grouped by calendar day (`ActivityView.swift:12`, `:99-111`). It answers
"what changed, in order". It cannot answer "was the internet down last
night, and for how long", which is the question a traveller has the next
morning.

The CLI has answered that question since `helpers/events.py` was written.
`--events=HOURS` pairs faults into episodes with durations, handles the
sleep gaps honestly (`helpers/events.py:22-35`), and `lib/availability.sh`
judges the result into AV-1/AV-2. `grep -rn '\-\-events' gui/Sources`
returns nothing.

### D.2 The design

`ActivityView` gains a two-mode segmented control:

- **Episodes** (new default) — `netdiag --events=24` via a new
  `EventsStore`, rendered newest-first, grouped by **network visit** rather
  than calendar day. A visit is a run of episodes sharing one
  `network_id`; that grouping is what turns a list into "while you were at
  Heathrow".
- **All changes** — today's list, unchanged, for the expert who wants the
  raw transitions.

Above both, the availability summary: outage count, total downtime, longest
outage, and the observed-fraction caveat that
`availability_observation_note` already produces — a Mac that slept for
eighteen hours has a 24-hour window that is mostly guesswork, and the CLI
already refuses to pretend otherwise (`lib/availability.sh:20-27`). The GUI
must render that caveat, not drop it.

Window selector: 24 h / 7 days / 30 days.

### D.3 The journal has to be written

Episodes only exist if something wrote `events.jsonl`. Today that requires
the opt-in launchd recorder, so Activity is empty for almost everyone.

**The GUI's own monitor writes it**, by passing `--journal` at
`MonitorStream.swift:155`. On by default.

**Except when the recorder is installed.** Two processes appending to one
journal is a corruption risk this spec will not take on faith, and the
recorder is strictly better anyway — it keeps writing while the app is
closed. So: `WatcherControl`/recorder state gates the flag, and the app
passes `--journal` only when the recorder is not installed. Whichever is
writing, exactly one thing is.

This does not break `--monitor`'s stated contract. CLAUDE.md says the
journal is opt-in because `--monitor` writes nothing to disk by default;
the app passing the flag *is* an opt-in, made on the user's behalf and
disclosed:

- **Onboarding** gains a line under step 3 naming what is recorded (network
  transitions and fault start/end times — no traffic, no addresses beyond
  what the report already stores) and where (`~/net-diag/events.jsonl`).
- **Settings** gains a switch and a "Delete recorded history" button.

---

## Part E — What this network was like last time

### E.1 The design

On arrival, once the network is identified, read that network's `judged`
block from `netdiag --history` and its episodes from `--events`, and put one
line on the arrival card:

> *You've been here 4 times. Last visit it dropped 3 times in 2 hours.*

The **counts are facts** — visits, drops, duration — and the GUI may compose
facts. Any **verdict** ("this network is unreliable") comes from the
`judged` block's own prose or does not appear. This is the same line
`RunDetailView` already walks between when it names a network next to a
stored run.

Suppressed when there is nothing to say: a network seen once, with no
episodes, gets no line rather than "You've been here 1 time."

### E.2 Why it is last

It is a few lines once Part C exists and has nowhere to live before it.

---

## Order of work

Five parts, three phases, each shippable:

1. **Phase 1 — CLI.** Part A (`impacts` in the catalog, `helpers/
   suitability.py`, `suitability` in `--json` and the text report,
   catalog schema 5) and Part B (`fix` / `fix_away` / `fix_target` in the
   catalog). Both are testable from bats with no GUI at all, and Parts C
   and D/E are shells without them.
2. **Phase 2 — the arrival moment.** `ArrivalPolicy`, the `.arrived` stage,
   the "I control this network" flag, suitability and fix rendering in
   `RunReportView`, and the arrival notification rule. Part C + the GUI half
   of A and B.
3. **Phase 3 — memory.** Part D (episodes, journal, Settings/onboarding
   disclosure) then Part E (the memory line), which needs both C and D.

## Testing

- **bats:** `suitability` present and well-formed at every depth; a
  `--quick` run yields `unmeasured` for `calls`; a forced B1 yields
  `calls: broken`; every `impacts` key and value is in the allowed sets;
  `fix_away` present exactly on `your_router` / `network_operator` rules;
  `--events` output shape unchanged.
- **`tests/test_thresholds.bats`:** must still pass unmodified.
  `helpers/suitability.py` containing any numeric cutoff is a spec
  violation, not a judgement call.
- **`VerifyMode` (`--verify`):** `ArrivalPolicy` depth selection across
  never-seen / seen / seen-but-critical; `.arrived` stage ranking against
  `.alerted`, `.healthy` and `.watching`; arrival-notification
  suppression on an all-good verdict. `swift test` is a no-op on this
  toolchain — `--verify` is the harness.
- **By hand, on this machine:** join a never-seen network and a familiar
  one; confirm the depth chosen, the card shown, and whether a
  notification fired.

## Open risks

1. **`impacts` is a judgement call per rule, made once, for 53 rules**
   (`netdiag --rules-catalog | jq '.rules | length'`, run 2026-08-29).
   Getting `streaming: degraded` versus `broken` wrong for a given rule
   produces a wrong-but-plausible row. Mitigation: the row always names the
   rule that decided it, so the claim is auditable rather than anonymous.
2. **Quick-check-on-every-rejoin adds probe traffic** at every network
   change. A quick check is ≤ 8 s and runs no saturating test, so this is
   judged acceptable; if it proves annoying, the mitigation is a minimum
   interval per network, not a return to once-ever.
3. **Journal growth.** `events.jsonl` plus its archive on a machine that
   now always writes it. Needs a size check and the existing archive
   rotation confirmed, in Phase 3.
4. **VPN & remote access was considered and dropped** from the activity
   list on 2026-08-29. It is the activity most often broken outright by
   hotel and airport networks, and the CLI already detects VPN state. If it
   returns, it is one more entry in the same table — no structural change.
