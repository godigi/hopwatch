# Network Detection Accuracy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix all 13 confirmed false positives, false negatives, and cross-surface inconsistencies in the audit.

**Architecture:** Preserve the existing shell probe modules, shared Python history judgement, monitor emitter, and Swift rendering boundaries. Carry measurement availability and scan context into each verdict instead of treating absent values as success. Keep user-visible thresholds in `lib/thresholds.sh` and diagnosis logic out of the GUI.

**Tech Stack:** Bash 5, Python 3, Bats, SwiftUI, Swift Testing, macOS.

**Spec:** [Network detection accuracy design](../specs/2026-10-06-detection-accuracy-design.md)

## Global Constraints

- macOS 14+, sudo-free network checks.
- Shell code supports Bash 5; no new mandatory dependencies.
- Only `lib/thresholds.sh` owns numeric network cutoffs.
- Final CLI and GUI verdicts must agree; unmeasured is not healthy.
- Keep active feature worktrees untouched; no `main` commit, push, or release without user review.
- Patch bump, local GUI install/relaunch, and installed-version verification are required after local fixes.

## Review Focus

- Healthy `--ping-only` with unrun public/DNS modules: test no P1/P2 and no unreachable report-card label (Task 1).
- Single public-IP metadata service failure with another public success: test no critical outage (Task 1).
- An unknown monitor sample following critical L1: test no recovery event or journal clear (Task 5).
- Many clean checks plus repeated critical L1 or DNS faults: test history cannot claim “Usually healthy” (Task 4).
- First launch with no saved check: test dashboard DNS/TCP/bufferbloat display is unknown, not green (Task 6).

---

### Task 1: Focused-run and public-outage gates

**Files:** `bin/hopwatch`, `lib/diagnosis.sh`, `lib/headline.sh`, `tests/test_diagnosis_accuracy.bats`, `tests/test_output.bats`.

**Interfaces:** Consume existing `PUBLIC_CHECKED`, `PUBLIC_OK`, `DNS_LINES`, captive canary result, and ping/TCP evidence. Produce P1/P2 only on measured, unrefuted public failure.

- [ ] Add failing tests for healthy `--ping-only` and independent public success despite metadata-service failure. Assert rule IDs, severity, and report-card wording.
- [ ] Run the focused Bats tests and confirm the expected failures.
- [ ] Change diagnosis/report-card gates; preserve captive-portal precedence and true-outage coverage.
- [ ] Run focused Bats tests to green.

### Task 2: DNS fallback and speed-dependent diagnosis

**Files:** `lib/dns.sh`, `lib/diagnosis.sh`, `bin/hopwatch`, `tests/test_dns.bats`, `tests/test_diagnosis_accuracy.bats`, `tests/test_progress.bats`.

**Interfaces:** `DNS_FALLBACK_OK` names only a measured configured secondary. Full-check `DIAG*` arrays and final output use `SPEEDTEST_DOWN_MBPS` after the speed phase, without concurrent saturation probes.

- [ ] Add failing DNS test: two configured resolvers fail, direct public resolvers work, D5 must not claim configured fallback.
- [ ] Add failing orchestration test: D-grade bufferbloat plus measured 300 Mbps saves the speed-aware warning and can emit SP-1 where its other conditions hold.
- [ ] Run focused tests and confirm both failures.
- [ ] Implement probe-state separation and final diagnosis reevaluation/output ordering.
- [ ] Run focused DNS, diagnosis, and progress tests to green.

### Task 3: Context-aware historical metrics

**Files:** `helpers/judgement.py`, `helpers/history.py`, `helpers/summary.py`, `tests/test_history.bats`, `tests/test_summary.bats`, `tests/test_thresholds.bats`.

**Interfaces:** Use the existing `JUDGED_METRICS` table and threshold environment. Per-run diagnosis and VPN context filter judged observations; raw measurements remain in stored records. `build_judged` must account for recurring critical/warn diagnoses before emitting a whole-network summary.

- [ ] Add failing regressions for ten critical L1 runs judged healthy, ten TCP-1 runs judged as router loss, ten VPN MTU 1380 runs warned, exact MTU 1400/1280 disagreement, and signed −120 s drift.
- [ ] Run focused history/summary tests and confirm expected failures.
- [ ] Implement context filtering, per-observation drift magnitude, diagnosis-aware overall verdict, and consistent comparison direction.
- [ ] Run focused history, summary, and threshold tests to green.

### Task 4: Stable baseline identity and directional MTU

**Files:** `helpers/baseline.py`, `helpers/history.py` (read-only identity API unless needed), `tests/test_helpers.bats`, `tests/test_history.bats`.

**Interfaces:** Reuse `history.group_key` for network matching. Keep BL-1's regression output shape, but emit `mtu.effective` only for harmful decrease.

- [ ] Add failing regression for same gateway MAC with and without visible SSID; assert previous checks remain eligible.
- [ ] Add failing regression for MTU 1380→1500; assert no regression while 1500→1380 still reports.
- [ ] Run focused tests and confirm expected failures.
- [ ] Implement canonical matching and directional MTU classification.
- [ ] Run focused tests to green.

### Task 5: Recovery requires measured evidence

**Files:** `lib/monitor.sh`, `helpers/monitor_sample.py`, `tests/test_monitor.bats`, `tests/test_events.bats`.

**Interfaces:** Preserve prior rule state across unknown measurements or suppress clear transitions until a fresh measured cycle confirms absence. Journal receives only supported `rule-cleared` events.

- [ ] Add failing L1→unknown→healthy sequence test, checking emitted changes and persisted journal events.
- [ ] Run focused monitor/event tests and confirm expected failure.
- [ ] Implement measured recovery gate without suppressing true clears or new unrelated measured faults.
- [ ] Run focused monitor/event tests to green.

### Task 6: Honest dashboard evidence

**Files:** `gui/Sources/HopwatchGUI/Views/HomeView.swift`, existing GUI models or a focused presentation helper, `gui/Tests/HopwatchGUITests/*`.

**Interfaces:** Use decoded `wifiScan.currentChannelNeighbours` for the count and CLI rule `WS-1` for the crowding verdict; represent absent DNS/TCP/bufferbloat as neutral unknown or skipped. No new Swift threshold values.

- [ ] Add failing GUI tests for four off-channel neighbors, four same-channel neighbors, and a missing saved check.
- [ ] Run focused Swift tests and confirm expected failures.
- [ ] Change row data preparation and rendering as minimally as possible.
- [ ] Run focused Swift tests to green.

### Task 7: Integration, local version, and install

**Files:** version-bearing files per `scripts/bump.py`, `CHANGELOG.md` if appropriate; no release tag.

- [ ] Run `make test` and investigate every failure.
- [ ] Bump local patch version once using a no-commit path consistent with project version files; verify all version-bearing files agree.
- [ ] Run `make test` again after the bump.
- [ ] Run `make install-gui`, relaunch `/Applications/Hopwatch.app`, and confirm the installed version and process.
- [ ] Review the full diff against the 13 audit findings and active-branch changes; report any remaining limit explicitly.
- [ ] Present the reviewable result and request the project-required decision about commit, push to `main`, and public release.
