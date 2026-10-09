# Network Freshness Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan task by task. The user requested investigation, a plan, and implementation in this session.

**Goal:** Menu and dashboard describe the current connection using fresh evidence; a brand new network has no inherited metrics, ratings, charts, or activity.

**Architecture:** Strengthen the coordinator's existing live-data gate, separate confirmed current identity from retained monitor state, and make consumers preserve unknown measurements. Invalidate cached evidence at network and wake boundaries and reject asynchronous results from an earlier connection. Keep saved records available through explicitly historical views.

**Tech stack:** Existing SwiftUI/macOS 14+, Swift Testing, bash monitor, Bats. No new dependencies.

**Spec:** User request: “No stale info, everything should be fresh on a brand new network. Not only in the menu, but in the dashboard.”

## Findings

- Sample lateness is suspended while paused/off, and `liveSample` currently treats that as measurement freshness. A paused sample may carry old values with a new timestamp.
- Current report/speed identity uses retained `monitor.latest`; `RunScope` permits unknown identities. A post-wake or network-event interval can therefore expose an old report.
- Network events request a refresh but do not immediately invalidate the previous evidence; delayed router probes/hydration/scans can update state after a move.
- Menu VPN freshness is hardcoded. Missing SSID becomes DISCONNECTED. Missing route evidence becomes green checks.
- Home evidence table defaults absent jitter/loss to zero and gives absent RTT/RSSI good badges. Home network details include illustrative defaults that look measured.
- Suitability evaluates unknown latency/loss/TCP as positive experience ratings.
- Home/Live/Expert charts and menu/Home activity are unscoped across networks. Reliability defaults missing history to zero outages/downtime.
- GUI baseline: 133 tests across 21 suites pass. CLI cache audit is included in Task 1.

## Global constraints

- Diagnostics remain read-only and sudo-free. No automatic full check timers or new speed tests.
- An unknown value remains optional and renders a neutral waiting/unknown state. A connected link is not proof of router/internet reachability.
- Confirm current identity before using stored data; unknown identity cannot authorize a current-network fallback.
- Freshness is about measurement age, independently of whether the monitor is expected to emit. Pause/off explains the state but cannot extend readings indefinitely.
- Wake/network invalidation must survive paused or in-flight old samples. A new sample must represent probes after the boundary.
- Historical Activity/Networks/Trends and report detail retain saved records. Current-network summaries scope both identities through history canonicalization.
- Keep all changes local until verified; patch bump and install/relaunch locally. Ask before committing/pushing/releasing main.

## Review focus

- Wake then scan pause before the first new sample: no old measurements or saved run may become current.
- Unknown/redacted SSID or unresolved gateway MAC: show unknown identity, never infer disconnected or authorize another network's report.
- Delayed hydration/router probe/scan after a move, including A→B→A: reject superseded current-state writes.
- ICMP filtering and partial successful probes: do not require ping to prove web reachability, and do not turn unknown loss into measured zero.
- A fresh failed public lookup or a long paused/off interval: old country/IP/ISP/VPN and optimistic ratings must not survive.

### Task 1: Current-connection evidence boundary

**Files:** `Services/HopwatchCoordinator.swift`, `Services/MonitorStream.swift`, `Support/RunScope.swift`, `Support/MonitorSeries.swift`, `lib/monitor.sh`, corresponding GUI/Bats regressions.

**Interfaces:** Coordinator provides confirmed current-network identity, current samples, fresh run evidence, scoped activity, and actual VPN freshness. Monitor exposes an invalidation operation that waits for a genuinely new non-paused sample. Existing identity canonicalization remains authoritative.

- [x] Add regressions for stale paused/off measurements, wake before first sample, unknown identity/report fallback, network boundary and delayed sample acceptance. Confirm failures against the baseline.
- [x] Invalidate on wake and actual network/link/VPN changes, enforce measurement age separately from emission lateness, and guard late asynchronous writes. Audit/reset CLI probe caches at connection boundaries.
- [x] Scope chart samples to the confirmed connection, exclude paused samples, and split chart segments on identity changes.
- [x] Run GUI suite and relevant monitor/network identity Bats tests; preserve known link-down and ICMP-filtered behavior.

### Task 2: Evidence-based suitability

**Files:** `Support/SuitabilityEngine.swift`, `Tests/HopwatchGUITests/SuitabilityEngineTests.swift`.

**Interfaces:** Existing `Inputs` optional measurements and `Item.Verdict.unknown`; no invented measurements.

- [x] Add tests proving an empty/paused/unmeasured sample cannot yield clear calls, smooth gaming, HD streaming, compatible VPN, or fast browsing. Add partial-evidence cases including TCP success without ICMP.
- [x] Require evidence appropriate to each rating; show “Checking…”/“Not measured” in neutral items. Retain actual measured bad outcomes and saved explicitly historical judgments.
- [x] Run suitability and full GUI suites.

### Task 3: Menu and dashboard current-data consumers

**Files:** `Views/HomeView.swift`, `Views/DropdownView.swift`, `Views/DropdownComponents.swift`, `Views/DashboardComponents.swift`, `Views/DashboardCheckEvidence.swift`, `Views/LiveView.swift`, `Views/NetworksView.swift`, `Views/ExpertPanel.swift`, GUI tests/verify fixtures.

**Interfaces:** Consume Task 1's confirmed identity/current evidence and Task 2's unknown ratings. Use the existing neutral evidence badge patterns.

- [x] Add regressions/fixtures showing empty new-network menu and dashboard with no invented zeros, green route verdicts, previous charts, outages, speed, country, or network details.
- [x] Remove sample/report bypasses and fake DNS/IP/security/channel/ISP defaults; live fields prefer fresh samples and may use only fresh matching-run evidence.
- [x] Show actual VPN measurement freshness; missing network name means unnamed/identifying network. Scope current activity and reliability and render “No history yet”/“Not measured” rather than zero records.
- [x] Scope Live/Networks live comparisons and Expert charts; preserve explicit historical reports.
- [x] Run GUI suite and render the actual menu/dashboard in empty/moved/stale/fresh fixture states; inspect output.

### Task 4: Validation and local installation

**Files:** Version definitions `bin/hopwatch`, `Casks/hopwatch.rb`, `gui/Sources/HopwatchGUI/VerifyMode.swift`, `sample-output.json`, `CHANGELOG.md`, this plan.

- [x] Fresh-context review of the whole diff; fix material findings with failing regressions.
- [x] Run full GUI and CLI suites and relevant verification fixtures. Record exact commands/outcomes and any limitations below.
- [x] Manually bump the patch version consistently without running the release script (it commits/tags). Add a truthful CHANGELOG entry.
- [x] `make install-gui` and `open /Applications/Hopwatch.app`; verify installed version/signature and rendered current state.
- [x] Present local results and gather commit/push/public-release approval in one prompt. Do not release or push main without approval.

## Execution record

Baseline: `make test-gui`: 133 tests / 21 suites passed. Isolated worktree `fix/network-freshness`, based on `7c2b8c0`.

Ruling: Implement locally without incremental commits. User requires local verification before deciding on a public release; the release bumper creates commits/tags, so version edits will be applied without invoking it.

### Review findings and corrective work

A fresh-context review identified additional lifecycle and evidence gaps. All are included in the local fix:

1. Ordinary scan cleanup marked a boundary after completion, hiding a successful scan when monitoring was off. Keep scan identity separately from full-report adoption and do not mark a resumption boundary without a live child; cover full and speed-only checks.
2. Monitor-observed identity changes must invalidate the connection generation even if system watcher callbacks are suppressed. Preserve the just-arrived sample, discard prior-visit chart points, and reject old asynchronous writes across A→B→A.
3. Freshness deadlines need observable clock updates even when no live sample exists; scan expiry, waiting-for-monitor and known-link-down expiry otherwise remain painted indefinitely.
4. Router admin probe cache and in-flight deduplication need connection generation scope because different networks share gateway addresses.
5. Resume must force every CLI probe tier before emitting, so pre-scan DNS/TCP/radio/public caches cannot override the scan's newer evidence.
6. Filtered loss is optional evidence, not measured zero. Streaming without bandwidth or measurable loss remains unknown; successful DNS and TCP can independently establish browsing readiness.
7. Dashboard technical telemetry must preserve optional traceroute, IPv6, double NAT, SNR, conflicts and neighbors. Empty findings and monitoring duration must not claim healthy results or fabricated history.
8. An unknown interface cannot be labeled wired in the menu.

The original no-link survival contract remains: a recent known-down sample can survive a stopped/restarting monitor. Actual connection invalidation clears it; missing network identity alone is not a disconnect.

Validation to date: GUI 148 tests passed before review corrections; full CLI 1,208 tests passed. The new CLI resume regression failed before forcing tiers and passed after. GUI review corrections will be verified together after source edits finish. One attempted focused build overlapped source edits and was rejected by Swift; it produced no test result.

### Final regression and review results

- `make test-gui`: **157 tests across 23 suites passed** after all product corrections and verification-fixture updates.
- Full `make test-cli`: **1,208 tests passed** before the resume correction. The complete changed monitor suite was then rerun: `bats tests/test_monitor.bats`: **163 passed**, including the new resume test. The relevant decoding-parity suite also passed **4/4** after adding optional measured technical fields.
- The filtered-streaming regression failed with `.good` before the guard correction and passes with `.unknown` afterward. Successful DNS/TCP still produces good browsing. Direct `swift test` attempts lacked the CLT framework search/rpath options supplied by the repository's Makefile; final validation uses the supported target.
- `gui/.build/debug/HopwatchGUI --verify`: **All checks passed.** Updated obsolete fixtures to distinguish a monitorless scan resume from an actual wake/connection boundary. The existing changed-network activity-fold verification retains the proper end of the previous network's episode.
- `shellcheck -x lib/monitor.sh` and `git diff --check`: **passed**.
- Actual menu/dashboard gallery views rendered in light/dark moved-network states. Inspected the primary menu and full Home PNGs: empty charts, unknown ratings and technical checks, neutral router/internet readings, no previous network activity/throughput/country, and no invented healthy findings or 24-hour monitoring claim.
- Focused review follow-up confirmed the original eight findings addressed. Its two additional findings are fixed: capture the old identity before sample reconciliation for activity continuity, and clear announced fault state at a connection boundary so the new network cannot receive an old-network recovery notification.

Local build is **1.14.4** on `fix/network-freshness`. No commit, remote push, release tag or public distribution has been made. Local installation and the user's release decision are recorded below when verified.

Limit: fixtures exercise wake/connection transitions; this session does not reproduce an hours-long physical sleep followed by a move to a second real access point. The installed app is ready for that user check.

### Installed-app inspection

The signed app was installed and launched. `/Applications/Hopwatch.app` and its bundled CLI both report **1.14.4**; `codesign --verify --deep --strict` passed and the GUI process was confirmed running. Native accessibility inspection verified live current-network router/internet ping, actual Wi-Fi signal, current public information and unknown unmeasured VPN path suitability.

The initial native dashboard inspection caught an additional shell-level gap: `MainWindow`'s sidebar treated a missing network name as disconnected, and its toolbar could show Watching before fresh data. Its sidebar and toolbar now consume the same fresh evidence, use an unnamed-network label when appropriate, and show neutral Checking while awaiting a sample. The complete 157-test GUI suite passed again after this fix. Final rebuild/reinstallation is in progress; fresh installed effect is checked below.

Stale-monitor gallery views were also rendered and inspected: Not reporting, no stale pings/jitter/IP/country/VPN, no old chart samples, and neutral technical/suitability fields. Existing historical OS notification banners are retained as history; boundary tracking is cleared to prevent false recovery announcements.

### Final installed effect

The final signed rebuild completed and was reinstalled/relaunched. Signature verification, GUI/CLI **1.14.4** version checks and running GUI-process check all passed. Native inspection immediately after relaunch confirmed:

- Sidebar: **Wi-Fi network**, without a false Disconnected label.
- Toolbar: **Awaiting fresh reading · Checking**, without Watching before evidence.
- Throughput, jitter, loss, router/internet RTT and technical fields: unknown placeholders.
- Suitability: neutral waiting states; reliability: no current-network history; check table: Awaiting check.

The already completed native live inspection confirmed that genuine new samples subsequently populate current Wi-Fi, router/internet, DNS/TCP and public information. No source changes followed the final 157-test GUI pass. Public-release approval was subsequently provided; see the public release approval record below.

### Public release approval

The user explicitly approved committing, pushing to main, and publishing through the desktop release prompt. All changes were transferred to clean main at the unchanged base commit. The release bumper advances local 1.14.4 to public **1.14.5**. Its no-commit mode preserves the required Nimbalyst commit-proposal workflow; the release tag will be created after the reviewed commit and pushed immediately. The normal shipping target then verifies and packages the tagged version without bumping again.

Integrated-main validation at public version 1.14.5: `make test-gui` passed **157 tests / 23 suites**; `git diff --check` passed. All 28 changed/new publishable files, including both regression suites and this plan, are included in the Nimbalyst commit proposal. The ignored session-goal file remains local workspace metadata.
