# Moving live suitability verdicts out of Swift — plan

Status: **proposed, not started.** Written 2026-10-06 after the Gaming tile
said "Smooth" over 58% packet loss (fixed tactically in `a608268`).

## Problem

`gui/Sources/HopwatchGUI/Support/SuitabilityEngine.swift` decides in Swift
whether the network suits Calls, Streaming, Gaming, VPN and Browsing. It
carries dozens of inline cutoffs and verdict strings, which breaks two
project rules — thresholds live only in `lib/thresholds.sh`, and the GUI
holds no diagnostic logic. `tests/test_thresholds.bats` does not look at
Swift, which is how it grew unnoticed.

## Finding: most of this is already built, unmerged

Two branches forked from `c1db0c7` (1.10.2) and sharing their first 22
commits already contain the redesign:

- `feat/monitor-stability` — 29 commits ahead, with uncommitted edits in
  its worktree at the time of writing.
- `feat/reporting-accuracy` — 25 commits ahead.

What the shared trunk has:

- `aadf3a4` — `helpers/inference.py`; each monitor sample gains
  `suitability`, `hops` and `headline`, projected from fired rules through
  the catalog `impacts` table, with cutoffs from `lib/thresholds.sh`.
- `deefb92` — `SuitabilityEngine.swift` cut to lookups only.
- `1987b71` — a GUI guard in `tests/test_thresholds.bats`.
- `83bacc1`, `1a17865`, `e207d26` — rules LA-1, LA-2, TCP-2 and a rewritten
  TCP-1.

`feat/arrival-suitability` is fully merged; nothing to reuse there. The
branches' own "tests green" claims were not re-run for this plan.

So the work is **land and finish**, not build. Main has four commits the
branches lack, and nineteen files changed on both sides.

## Defects to fix while landing

1. **The GUI guard is vacuous.** It greps one quoted, space-joined path;
   grep exits 2 and both assertions pass on exit 2.
2. **`label` means two things.** Scan rows carry the activity name, monitor
   rows the verdict word; a stored-run fallback shows "Video & voice calls"
   as the status.
3. **Verdict strings remain in Swift** (`consequenceFor`), and the guard
   permits them.
4. **Judging remains outside the guarded files** — `HomeView.swift` (loss,
   jitter, ping, RSSI bands), `MonitorSeries.swift`, and the 2% / 10%
   effective-loss inferences.
5. **The projection loop is duplicated** between `inference.py` and
   `suitability.project()`, so scan and monitor share the table but not the
   code.
6. **A slow speed can read "HD ready"** — no rule judges absolute speed.

## Design

Keep the branch architecture: rules decide, `impacts` projects, the CLI
authors every string, Swift maps verdict to tint and icon. No per-activity
numeric bands anywhere — an activity degrades only because a named rule
fired, which makes disagreement with the report impossible.

Per-sample JSON, as on the branch with two changes (`status` instead of a
second meaning for `label`; `consequence` so the Swift table can go):

```json
"suitability":[{"activity":"calls","verdict":"degraded","status":"May cut out",
  "metric":"12% loss · 9 ms jitter","detail":"…","consequence":"…",
  "because":["L2"],"unmeasured_reason":null}],
"headline":{"text":"Limited for Calls and Gaming","subtitle":"…","critical":false}
```

`inference.py` calls an extended `suitability.project()`; a bats parity
test holds scan and monitor rows equal whenever either is degraded or
broken.

Split: bash judges (`_mon_rules`) and exports thresholds; Python projects,
phrases and serialises; Swift renders.

## Steps

| # | Step | Verify | Size |
|---|---|---|---|
| 1 | Rebase the trunk's CLI commits onto main; reconcile TCP-1 (D1). App unchanged. | bats parity block, shellcheck, live `--monitor` | L, conflict-heavy |
| 2 | Emit the blocks, with the `status` rename, `consequence`, the `project()` refactor and a `monitor-suitability` capability. App ignores unknown keys, so this ships alone. | invariant tests, `jq .suitability` on a live sample, cycle timing | M |
| 3 | Atomic Swift cutover: delete `evaluate*`, `synthesizeDegradedExperience`, `consequenceFor`; land the fixed guard in the same commit. | `--verify`, planted-cutoff test | L |
| 4 | Move the residual judges (defect 4) into CLI fields; widen the guard to all of `gui/Sources` with an allowlist for layout lines. | guard, `--verify` | M–L |
| 5 | Land the branch tails; docs, CHANGELOG, redacted samples. | full bats | M |

Step 3 deletes the old API in the commit that switches all three consumers,
so a build showing verdicts from two sources cannot compile. Precedence:
the sample's rows, then the stored run's, then neutral "Not measured".

## Decisions needed

| # | Decision | Swift today | CLI | Recommendation |
|---|---|---|---|---|
| D1 | TCP-1 semantics | — | main: gateway loss ≥ 50% and not corroborated (`a608268`); branch: gateway fully silent and internet leg clean | Take the branch rule; keep `a608268`'s test cases |
| D2 | Loss bands | calls 8/3, gaming 8/2, streaming 15/8, browsing 15/6 | warn 10, crit 20 | Use the CLI's, or lower the warn cutoff globally; no per-activity bands |
| D3 | Latency | calls 400/250, gaming 140/80, browsing 350 | branch LA-1 at 150/400 | Take LA-1 |
| D4 | Jitter | calls 50/25, gaming 45/20 | single 30 ms warn | Single 30 ms warn |
| D5 | Absolute speed | several bands | none | One new rule for streaming speed; drop the others |
| D6 | MTU | < 1380 | 1400 | CLI's 1400 |
| D7 | DNS | ≥ 250 | scan-only rule | Keep scan-only |
| D8 | "Good" tiers | Responsive vs Smooth, 4K vs HD | one label per level | Drop the tiers |
| D9 | G1 impact | — | degraded for calls and gaming | Make it broken |
| D10 | Wording | "Rubberbanding", "Frequent cutouts", "Pages stall" | "Unplayable", "Breaking up", "Pages fail" | Take the branch's |
| D11 | Landing vehicle | — | two branches | Trunk first, then the tails |

D2–D4 change what users see: with the CLI's bands, 3–9% loss and gaming at
80–149 ms would read good.

## Risks

- **Cycle cost.** Importing the catalog costs roughly 30 ms cold, and the
  sealed bundle always runs cold. Precompile `helpers/` at bundle time.
- **Older CLI.** Lenient decoding gives neutral tiles, which is safe; the
  capability flag lets the app say why.
- **Second checkout.** The watcher's checkout judges stored runs with its
  own (older) rules, so history can disagree with live tiles until it is
  updated.
- **Rebase.** Step 1 reconciles two independent fixes for the same TCP-1
  bug in the same hunks.

Roughly 6.3k insertions already exist on `feat/monitor-stability`; about
400–600 new lines remain. Most of the effort is conflict resolution and
decisions D1–D5.
