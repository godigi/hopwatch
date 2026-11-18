# Changelog

All notable changes to Hopwatch are recorded here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versioning follows
[SemVer](https://semver.org/spec/v2.0.0.html).

Releases before 1.16.2 are archived in [docs/CHANGELOG-archive.md](docs/CHANGELOG-archive.md).

## [Unreleased]

## [1.24.1] - 2026-11-19

### Fixed
- **CLI & Monitor Reliability**:
  - Updated `hopwatch --watch` to source `lib/thresholds.sh` and `lib/common.sh` cleanly and set `LOG=/dev/null`; replaced remaining `netdiag:` stderr/banner strings in `bin/hopwatch` with `hopwatch`.
  - Stopped running background spinner animations when `--expert` output mode is active (`lib/common.sh`).
  - Hardened continuous monitor signal interruption, fast-refresh state tracking, wired link-drop vs. gateway-loss distinction, per-network `N1c` IP continuity, `WJ-1` / auto-reconnect guards, `THRESH_MON_PUBLIC_RETRY_S` backoff, and `rules_left` journal tracking (`lib/monitor.sh`, `helpers/monitor_sample.py`).
  - Fixed `--app` installer pipeline cleanup (`install.sh`) and aligned `have_bash5` detection across Homebrew, MacPorts, and `PATH`.
- **HopwatchGUI Alignment & Fixes**:
  - Unified GUI suitability, stability, and health-rating thresholds with CLI `THRESH_*` cutoffs (`SuitabilityEngine.Cutoff`, `MonitorSeries`, `MonitorSample`, `DropdownView`, `HomeView`, `LiveView`, `RunReportView`, `SettingsView`).
  - Driven post-repair resolution feedback (`evaluateResolutions`) and `signalRestoredMessage` directly from CLI rule transitions rather than local packet-loss heuristics, and preserved `sessionArrivalStates` across network arrivals and declined checks (`HopwatchCoordinator`, `ResolutionFeedbackTests`).
  - Gated update preload on `autoDownloadAndInstallUpdates`, switched `UpdateChecker` `User-Agent` to `Hopwatch-App/<version>`, guarded unmeasured MTU displays, and updated plain-English `CONN-1` / `Lease expired` wording.
  - Fixed degraded hero subtitles claiming `"4K streaming is fine"` when Streaming is `"HD ready"`, decoupled minor gateway packet loss (`< 2%`) from upstream loss so Wi-Fi isn't blamed for internet drops, wrapped long Internet node detail labels without ellipsis truncation, suppressed gateway-dominant jitter on the Internet node detail, and added a left axis gutter to `PingHeartbeatView` so `150ms`/`70ms` labels never collide with the trace (`SuitabilityEngine`, `DropdownComponents`, `DropdownView`, `HomeView`, `PingHeartbeatView`).

### Changed
- **CI, Docs & Release Metadata**:
  - Added `make test-gui` Swift test job and `timeout-minutes` bounds across GitHub Actions workflows (`.github/workflows/bats.yml`, `auto-version.yml`, `release.yml`, `shellcheck.yml`).
  - Updated `README.md`, `CONTRIBUTING.md`, `docs/ARCHITECTURE.md`, `docs/DIAGNOSIS-RULES.md`, and `docs/JSON-SCHEMA.md` for current `hopwatch` paths, Dashboard sections, `make ship`, and redaction coverage.
  - Updated `CITATION.cff` to `1.24.0`, wired `CITATION.cff` into `scripts/bump.py`, and pointed `Casks/hopwatch.rb` homepage to `https://godigi.github.io/hopwatch/`.

## [1.24.0] - 2026-11-16

### Added
- **Automated Live Condition Simulator & Multi-Tab Visual Screenshot Audit Harness (`VisualAuditMode`, `scripts/visual_audit.py`, `make visual-audit`)**:
  - Added a two-stage simulation suite driving real CLI telemetry + rule evaluation and an isolated GUI harness (`--visual-audit` / `--gallery-scenarios`) through 20 network degradation, recovery, pause, isolated gateway rate-limiting, rolling-window recovery, Wi-Fi TX collapse, auxiliary view, and continuous no-reset transition cycle scenarios.
  - Renders actual light and dark menu-bar dropdown, Dashboard window (`Overview`, `Live monitoring`, `Activity`, `Trends`, `Networks`, and all four `Settings` tabs), and standalone detail/modal (`RunReportView`, `RawJSONViewerSheet`, `OnboardingView`, `WhatsNewView`) PNG screenshots alongside a browsable `index.html` contact sheet, programmatically enforcing 68 cross-surface UI consistency invariants.
- **1-Click Speed Testing & In-Flight Live Progress in Menu Bar Dropdown (`MenuSpeedView`, `DropdownView`)**:
  - Added an instant "Test" button inside the menu bar extra's speed section and a "Run Speed Test" action in its context menu.
  - Replaced static placeholders during active speed testing with live in-flight progress (e.g. `↓ 145.2 Mbps` or `↑ 38.0 Mbps`) and an inline "Cancel" control.
- **Activity History Export (CSV & Markdown) & Log Reset Management (`ActivityView`, `EventStore`, `HopwatchCoordinator`)**:
  - Added an "Export" menu in the Activity tab supporting RFC4180 CSV export (`Timestamp, Kind, RuleID, Network, Summary, Detail, From, To, Evidence`) and formatted Markdown table generation for IT ticketing and ISP support threads.
  - Added a "Clear Activity History…" action with destructive confirmation to reset recorded episodes when diagnosing fresh network incidents.
- **Universal Searchable Raw JSON Sheet with File Export & Filter Navigation (`RawJSONViewerSheet`, `HomeView`, `RunReportView`)**:
  - Introduced `RawJSONViewerSheet` featuring a live substring search bar with real-time match counter, word wrap toggling, "Copy to Clipboard", and 1-click "Save…" via native `NSSavePanel`.
  - Wired raw JSON inspection into `RunReportView` context menus and sharing toolbars so historical stored runs can be inspected in raw JSON without switching views.
- **Persistent User Network Notes & Labels (`Defaults`, `HistoryStore`, `NetworksView`)**:
  - Added persistent custom note storage for Wi-Fi and Ethernet networks to record router locations, captive portal credentials, and bandwidth limits.
  - Added an inline note editor in `NetworksView` and subtle note badges in sidebar network list rows.
- **Historical Network Runs CSV Export (`NetworksView`, `HistoryStore`)**:
  - Added an "Export CSV…" action in `NetworksView` to export all historical diagnostic runs for any selected network (including timestamps, test depths, severities, gateway/internet latencies, packet loss, jitter, speed metrics, and fired rules).
- **Interactive Overview Live Ping Chart (`DashboardLiveChartPanel`)**:
  - Added hover inspection (`chartXSelection`) with a floating timestamp and dual Internet/Router latency readout, shaded monitor gaps (`RectangleMark`), dropped-packet markers (`RuleMark` + `PointMark`), subtle gradient area fills, a minimum Y-axis ceiling to prevent low-ping noise amplification, and dual Internet + Router `min / avg / max` summary stats in the chart footer.
- **Trends Chart Hover Readouts, Throughput Bars & Run Drill-Down (`TrendsView`)**:
  - Added interactive cursor hover readouts to both the historical metric chart (displaying true unclamped values, companion Internet Ping, and outlier flags) and the daily incident bar chart (displaying `ok` / `warn` / `critical` counts per day).
  - Enhanced Speed Test Benchmarks with relative download/upload throughput progress bars and 1-click navigation to the full `RunDetailView` report.
  - Upgraded the "Issues flagged in this window" list in Trends to render interactive `RuleChip` badges and open the corresponding run report on click.
- **Activity History Search & Network Scope Filter (`ActivityView`)**:
  - Added a live search bar (filtering across event summaries, rule IDs, details, IPs, and app traffic evidence) and an `All Networks` vs. `Current Network` scope toggle.
- **Click-to-Copy Network Addresses (`DashboardNetworkDetailsPanel`, `DashboardRouteView`, `DashboardTechnicalPanel`)**:
  - Made `Local IP`, `Public IP`, `Gateway IP`, `DNS Server`, and telemetry values click-to-copy with instant `"Copied"` visual feedback.
- **Real-Time Zoned Ping Heartbeat in Live Tab & Enriched Sidebar Card (`LiveView`, `MainWindow`)**:
  - Embedded `PingHeartbeatView` into the Live Monitoring tab alongside the 60-minute historical charts, added gradient area fills and minimum Y-axis floors to `LiveChart`, and enriched the sidebar network card with live latency/loss telemetry and 1-click navigation to `NetworksView`.
- **Complete "Usual" Baselines in Check Details Table (`HomeView`)**:
  - Populated the `Usual` column for `Jitter` and `Throughput / Speed` in the Check Details table using learned baselines from `NetworkMemory`.
- **Fingerprint-Validated Disk Cache for History & Run Details (`StoreDiskCache`, `HistoryStore`, `RunDetailStore`, `RulesCatalogStore`, `SignalScaleStore`)**:
  - Added `StoreDiskCache` in Application Support keyed by `baseline.jsonl` / `baseline-archive.jsonl` sizes, modification timestamps, and CLI version, eliminating redundant `bash` + `python3` subprocess spawns on warm launches and revisited historical runs while invalidating immediately whenever a new run is recorded.
  - Coalesced concurrent `refresh()` calls in `RulesCatalogStore` and `SignalScaleStore` onto a single in-flight task to avoid duplicate startup probes.
- **Developer ID Signing & Apple Notarization CI Pipeline (`.github/workflows/release.yml`, `gui/Makefile`)**:
  - Added secret-gated Developer ID Application code signing (`--timestamp`), `xcrun notarytool submit --wait` notarization, and `xcrun stapler staple` stapling for `Hopwatch.app` and `Hopwatch.dmg` in the release workflow, with automatic fallback when signing secrets are absent.
  - Added `codesign --verify --deep --strict` verification inside `UpdateChecker` before swapping an installed app bundle.

### Changed
- **Location Services Guidance, Network-Owner-Aware Rules & Check Table Tooltips (`OnboardingView`, `HomeView`, `DropdownView`, `PlainEnglishTranslator`, `MetricGlossary`, `DashboardComponents`)**:
  - Updated `OnboardingView` to label Location Services as required for Wi-Fi diagnostics while still allowing continuation (`"Continue without Wi-Fi names"`), updated `HomeView.locationWarningBanner` copy, and added a matching dismissable `locationReminderBanner` in `DropdownView`.
  - Shortened and clarified `BLOAT-1`, `BLOAT-2`, `W6`, `WS-1`, `NAT-1`, and `NAT-1B` explanations in `PlainEnglishTranslator` so they reflect public/shared Wi-Fi reality and clearly scope router configuration tips to network owners.
  - Added `jitter`, `wifi_channel`, `noise`, and `web_connections` entries plus Check Details row aliases to `MetricGlossary`, and wired hover tooltips with `info.circle` indicators into `DashboardCheckTable`.

### Fixed
- **Live Packet-Loss Accuracy, Rolling-Window Recovery Visibility & Live Wi-Fi Link Rate (`lib/monitor.sh`, `helpers/monitor_sample.py`, `helpers/rules_catalog.py`, `MonitorSample`, `EffectiveLoss`, `HopwatchApp`, `HomeView`, `DropdownView`, `LiveView`, `HopwatchCoordinator`)**:
  - Aligned the `HomeView` Check Details `"Packet loss to router"` row with downstream validation so isolated router ICMP ping loss (`< 20%`) when internet traffic is clean (`<= 1%`) renders `"None · Router ping only"` (`Good`) instead of `"Unstable"`, matching `EffectiveLoss.compute` and the route visualization.
  - Added per-cycle `last_probe_loss_pct` telemetry on `gateway` and `internet` monitor samples (plus `wifi.tx_rate` and live `W4` Wi-Fi transmit-rate collapse evaluation) so the menu bar (`10% avg`), Live card (`0% now · 10% avg`), Dropdown, and Overview rows distinguish a recovering rolling window from active ongoing drops, while exposing `tx_rate` in the Overview Wi-Fi Signal row.
  - Exposed live secondary-resolver `internet.loss_pct_alt` on monitor samples and removed mixed live-primary / historical-secondary packet loss calculations in `HomeView` so a clean secondary probe immediately corroborates transient single-resolver rate-limiting without waiting for a new full scan.
- **Cross-Tab Visual Polish, Paused/Stale States & Suitability Consistency (`SuitabilityEngine`, `HopwatchCoordinator`, `HomeView`, `DropdownView`, `DashboardComponents`, `DropdownComponents`, `PingHeartbeatView`, `MainWindow`, `TrendsView`, `NetworksView`, `SettingsView`)**:
  - Updated `SuitabilityEngine`, route nodes, and `PingHeartbeatView` so manually paused and stale/not-reporting states render explicit `"Paused"` or `"Not reporting"` indicators across suitability cards, route hops, VPN status, jitter, and heartbeat readouts instead of `"Checking…"` or stale green heartbeats.
  - Fixed `SuitabilityEngine` handling when internet ICMP ping is filtered (showing `"Unmeasured · No ICMP"` on Streaming rather than `"Checking…"` without a speed test) or 100% blocked without RTT (showing `"Rubberbanding"` / loss on Gaming instead of `"Checking…"`), and broke `worstRule` severity ties toward combined router+internet rules (`G1`/`G2`) so prose never contradicts visible router loss.
  - Eliminated duplicate `"-61 dBm -61 dBm"` signal labels in `Overview`, fixed `"Issue source"` capsule wrapping and overlap above the Mac hop node (including country-flag stacking), aligned the route connector line to node centers, wrapped long weak-Wi-Fi details cleanly in the menu bar, synced the sidebar cadence badge to `liveSample?.status.cadenceS`, pre-selected the active network immediately when opening `Trends` or `Networks`, and made `SettingsView` header chrome opaque for crisp rendering.
  - Added an explicit `Theme.ColorToken.detailBackground` surface across `MainWindow` and `HomeView` plus `.preferredColorScheme` propagation in `VisualAuditMode` so Dark Mode renders dark backgrounds and legible controls consistently across `Overview`, `Live monitoring`, `Activity`, `Trends`, and `Networks` alongside `Settings`.
  - Fixed chronological sorting in `MonitorSeries.build` so Live Monitoring charts never draw backward horizontal zigzags on unsorted inputs, clipped Trends curves at the plot bounds (`y = 0`), added page titles to `LiveView` and `TrendsView`, added a Download/Upload legend to Trends Speed Benchmarks, removed redundant `"% · Learning (Building)"` double parentheses, synced `SettingsView` status summaries to live cadence without noisy slider tick marks, removed truncation/clipping on Hero Banner subtitles and Suitability strip labels, shortened Check Details TX readouts (`Mbps TX`), gated Networks' `"SSIDs hidden by macOS"` banner when the live SSID is known, and replaced numeric thresholds in `CP-1` captive-portal prose.
  - Fixed `SuitabilityEngine` paused/stale consequences (`"Resume monitoring to check"` instead of `"Assessing …"`) and long rule-blurb truncation in `Browsing` (`W4`), graded `HomeView` `Signal` as `"Slow TX rate"` when `W4` fires, prevented `ms` unit orphan-wrapping in the Overview ping chart footer, labeled known Wi-Fi channels without neighbor-scan data as `"Not scanned"`, fixed Settings `"Alert sensitivity scope"` picker truncation, and formatted single-target packet loss cleanly in `RunReportView` without `"0% / ? to two targets"`.
- **Non-Disruptive Background Investigation, Anti-Loop Cooldown & Telemetry Accuracy (`HopwatchCoordinator`, `StageResolver`, `HealthResolver`, `DropdownView`, `MainWindow`, `HomeView`, `PingHeartbeatView`, `monitor_sample.py`, `monitor.sh`, `rules_catalog.py`)**:
  - Preserved last live network readings (`preScanSample`), hero diagnosis card, and Ping Heartbeat graph across background alert-triggered scans instead of wiping telemetry to `Checking…` / `—` and falsely displaying `"Running full check…"` or `"Monitoring is paused — a check is running."`.
  - Added a 10-minute alert-triggered scan cooldown (cleared after 2 minutes of clean healthy samples) and preserved `MON_INET_LOSS_STREAK` / `MON_GW_LOSS_STREAK` across severity transitions (`L1 -> L2`, `G1 -> G3`) to prevent alert-scan loops every 1–2 minutes.
  - Filtered single-resolver ICMP burst/rate-limit spikes (e.g., `1.1.1.1` showing 94% loss while `8.8.8.8` shows 5%) in `helpers/monitor_sample.py`, surfaced `max(internet_jitter, gateway_jitter)` at top-level `jitter_ms` so `"Uneven response times"` reflects router jitter, and updated `L2` prose so it no longer claims `"the router itself is clean"`.
  - Unified `StageResolver`, `HealthResolver`, `MainWindow`, `DropdownView`, and `HomeView` status pills, menu-bar dots, sidebar footer labels, and speed-card indicators so degraded suitability states never pair a green `"Watching"` pill with a red/amber degraded hero, and prevented sidebar `"Hopwatch"` title wrapping.
- **UI Consistency, Card Sizing, Pluralization & Telemetry Polish Across Views (`SuitabilityEngine`, `DashboardComponents`, `HomeView`, `LiveView`, `PingHeartbeatView`, `DropdownView`, `ActivityView`, `TrendsView`, `NetworksView`, `NetworkDetailCard`, `SettingsView`, `RawJSONViewerSheet`, `WhatsNewView`, `ExpertPanel`, `RunReportView`, `HistoryStore`, `NotificationManager`)**:
  - Unified the unmeasured "Gaming" suitability card to use the standard `"Checking…"` / `"Not measured"` placeholder and `"Assessing game latency"` subtitle, and equalized card/tile heights across `DashboardSuitabilityStrip`, `SuitabilityPanel`, side-by-side Overview cards (`DashboardSpeedCard`, `DashboardReliabilityCard`, `DashboardNetworkDetailsPanel`, `DashboardTechnicalPanel`), `NetworkDetailCard`, `TrendsView` digest tiles, and `LiveView` gauge tiles.
  - Wired click-to-copy telemetry cells with `"Copied"` feedback into `DashboardTechnicalPanel`, excluded `"Checking…"` placeholders from Public IP copying, added `"Copied"` confirmation to `ExpertPanel`, disabled `"View Raw JSON"` when raw JSON is unavailable, widened the Check Details `Usual` column (`105 pt`), preserved `"Skipped in this check"` status for runs completed without a speed test, and avoided amber loss coloring for neutral route loss states (`"Not measured"`, `"—"`, `"roamed"`).
  - Fixed menu bar router ping showing `"no reply"` when gateway ping loss is filtered, prevented non-ms readouts from splitting across mismatched font sizes, aligned `ExperienceGridView` headers, styled `"Cancel check"` to match `"Run full check"`, and fixed `PingHeartbeatView` link-down / paused badges, stats footer, and disabled gateway toggle states.
  - Improved Light/Dark mode legibility (`LiveView` and `TrendsView` hover markers, `SettingsView` active tab pill contrast, `WhatsNewView` pill fills, unified warning colors), enabled remote fallback fetching when switching versions in `WhatsNewView`, and avoided splitting URLs/times on unspaced colons in changelog parsing.
  - Fixed singular/plural grammar (`hop`/`hops`, `neighbor`/`neighbors`, `observation`/`observations`, `hour`/`hours`, `day`/`days`, `check`/`checks`, `issue`/`issues`, `test`/`tests`), standardized speed/latency unit formatting, replaced remaining `"netdiag"` and `"Home tab"` UI references, escaped CSV fields in `HistoryStore` exports, gated update notifications on authorization, added Esc dismissal and `LazyVStack` rendering to `RawJSONViewerSheet`, reset inline network renaming on selection changes, and improved search empty/clear states in Activity and Settings.
- **Dynamic, Release-Aware "What's New" Sheet & Friendly Changelog (`WhatsNewContent`, `WhatsNewView`, `ChangelogReader`)**:
  - Replaced static, obsolete marketing bullet points in the post-update "What's New in Hopwatch" sheet with genuine release highlights loaded dynamically for the installed version.
  - Bundled `CHANGELOG.md` inside `Hopwatch.app/Contents/Resources` and introduced `ChangelogReader` to parse version sections, human-friendly release dates, and category groups (`Added`, `Fixed`, `Changed`) with full Markdown syntax stripping (bold asterisks, code backticks, PR links) and nested sub-bullet resolution.
  - Added release notes pre-caching in `UpdateChecker` upon background update download and asynchronous GitHub release API fallback in `WhatsNewView`.
  - Added category badges (`New`, `Fix`, `Improved`) and contextual SF Symbol icons/colors to feature rows, and enriched sheet headers with human-readable release dates.
  - Added an interactive release switcher in the header to browse and review changes from prior releases.
  - Added interactive category filter pills (`All`, `New`, `Fixes`, `Improvements`) with badge counts to quickly filter updates by topic.
  - Redesigned feature list into structured, scannable cards with a clean one-sentence summary and inline expandable technical details ("More details ▾" / "Show less ▴").
  - Added a 1-click "Copy Notes" button in the footer to copy clean Markdown release notes directly to the clipboard.
- **Parallel CLI Check Redaction Formatting (`lib/common.sh`)**:
  - Fixed line buffering in `collect_parallel` when running with `--redact` so individual redacted output lines are printed with proper trailing newlines rather than concatenating adjacent lines onto a single line.
- **Power Source & Battery Detection Safety (`PowerSourceHelper`)**:
  - Guarded `IOPSCopyPowerSourcesInfo`, `IOPSGetProvidingPowerSourceType`, and `IOPSCopyPowerSourcesList` against force-unwrapping `nil` on desktop Macs, headless environments, or VMs without battery hardware. Fixed CoreFoundation Get-rule memory management by switching `IOPSGetProvidingPowerSourceType` to `takeUnretainedValue()`.
- **Scan-Only Diagnostic Rule Preservation in Active Suitability (`HopwatchCoordinator`)**:
  - Refined `activeFiredRules` to respect catalog `scope == "scan"` so scan-only environmental diagnostics (such as Double NAT `NAT-1`, clock drift `NT-1`, or DHCP overrides `DH-2`) are preserved from the scan snapshot instead of being mistakenly discarded by overly broad prefix checks (`N*` and `D*`).
- **Call Glitch Risk Consequence Text (`SuitabilityEngine`)**:
  - Aligned `SuitabilityEngine.Item.defaultConsequence` for "calls" with the "Glitch risk" status to display "Occasional audio glitches" instead of claiming "Robotic audio & dropouts" when packet loss is 0.0%.
- **Accurate Missing Bash 5+ Detection & Cask Guidance (`CapabilityStore`, `HopwatchError`, `SettingsView`, `bin/hopwatch`, `BinaryLocator`, `Casks/hopwatch.rb`)**:
  - Distinguished `bin/hopwatch` exit status `3` caused by missing Bash 5+ (`CapabilityState.missingBash5` / `HopwatchError.bash5Required`) from an outdated CLI (`cliTooOld`), surfacing an actionable `brew install bash` notice with 1-click copy in `SettingsView` and allowing `MonitorStream` to recover automatically once installed.
  - Extended `bin/hopwatch` and `BinaryLocator` to detect MacPorts (`/opt/local/bin/bash`) and `PATH`-installed Bash 5+, updated `Casks/hopwatch.rb` to pass `brew style` with Bash 5+ caveats, and added a missing `SC2034` shellcheck annotation on `CAPTIVE_CANARY_HOST` in `lib/common.sh`.
- **Modular Coordinator Decomposition & Swift 6 Strict Concurrency Readiness (`HopwatchCoordinator+*`, `Defaults`, `DiagnosticReportSharing`, `FastISO8601`, `RelativeTime`, `HistoryDocument`, `NotificationManager`)**:
  - Split `HopwatchCoordinator` from a single 3,362-line file into focused extension modules (`+Hydration`, `+Arrival`, `+Scans`, `+Repairs`, `+Telemetry`, `+GalleryFixtures`).
  - Resolved all Swift 6 `-strict-concurrency=complete` diagnostics across `HopwatchGUI`.

## [1.23.1] - 2026-11-07

### Fixed
- **Automatic Arrival Full Check Recovery on Unhealthy Link Clearance**:
  - When connecting to a new network that is temporarily struggling or reporting elevated severity (e.g. initial socket exhaustion `SOCK-1` or DHCP settling glitches), Hopwatch continues to safely downgrade the initial arrival check to a quick check to avoid saturating a failing link. However, rather than permanently marking the network as declined and leaving speed and bufferbloat untested indefinitely, Hopwatch now automatically retries the full check once the network link becomes healthy and steady. Hotspot/metered declines remain sticky to prevent unrequested cellular data usage.
- **Stale Scan Snapshot Diagnosis Decoupling from Live Suitability**:
  - Centralized active rule resolution in `HopwatchCoordinator.activeFiredRules`: when the background monitor is actively watching the network, real-time monitor rules (e.g. `SOCK-1`, `CONN-1`, `D1`, `N1`, `G1`, `P1`) that have cleared or are no longer observed in the live stream are strictly authoritative. Stale diagnosis findings from a past scan (or an arrival check that completed during a transient fault) no longer poison the live experience grid or paint the connection as "Offline" / "Unreachable" when the live link is healthy. Scan-only environmental findings (e.g. `BL-1` bufferbloat, `N4` double NAT, `M1` MTU) continue to inform suitability until a fresh scan runs.
- **Relative Timestamp Formatting Polish (`RelativeTime`)**:
  - Clamped event age formatting in `RelativeTime.string(from:)` so events occurring under 1 second ago (or with minor subsecond clock dispatch skew) cleanly render as `"just now"` rather than awkward future-tense strings like `"in 0s"`.
- **In-Flight Scan Phase & Duration Transparency**:
  - Enhanced the status hero banner and Ping Heartbeat watermark during diagnostic and arrival checks to display live phase subtitles via `coordinator.activeScanProgressSubtitle` (e.g. `"Testing bufferbloat & latency under load…"`, `"Speed test: ↓ Download · 45.2 Mbps"`, `"Checking route…"`) instead of remaining on static text for over a minute.
- **Torrent Flow Flood & Peer Stall Attribution (`CONN-1`)**:
  - Calibrated flow holder attribution thresholds (`THRESH_CONN_HOLDER_MIN_FLOWS = 40` and `THRESH_CONN_HOLDER_SHARE_PCT = 40%`) in `lib/thresholds.sh` and `lib/diagnosis.sh` so torrent engines (such as Stremio's bundled helper) flooding BitTorrent peers with dozens of `SYN_SENT` half-open connections are accurately named and offered the 1-click "Quit <app>" button rather than falling back to an anonymous router restart suggestion.
- **Accurate Activity Suitability & Consistent Experience Badges**:
  - Scoped `CONN-1` rule impacts in `helpers/rules_catalog.py` exclusively to `browsing` (matching `D1` and GUI verify fixtures), eliminating contradictory warnings where established audio/video calls with 0% packet loss and clean streaming links with hundreds of Mbps bandwidth were falsely marked as "May cut out" or "May buffer".
  - Prevented contradictory status/metric pairings in `SuitabilityEngine`: when packet loss is 0.0% and jitter is low, Calls displays "Glitch risk" rather than claiming audio "May cut out", Streaming displays "Route check" when degraded without claiming a clean link buffers, and Gaming displays "Spike risk" rather than asserting "Lag likely" when real-time ping is under 35 ms.
- **Wi-Fi Hop Attribution Fidelity**:
  - Prevented advisory Wi-Fi scan findings (such as neighbor channel crowding `WS-1`) on clean wireless links (e.g. 4 ms latency, 1 ms jitter, 0% loss) from falsely painting the connecting link amber and labeling it `Wi-Fi (Laggy)`. Wireless links are now judged as laggy only when physical transmission latency/jitter or packet loss is actually elevated.
- **Clean Initial Check Telemetry on New Network Connection**:
  - Eliminated false "Monitoring paused" status on the "Your connection" card and Ping Heartbeat strip when testing a new network or running diagnostic scans (`isScanning` / `isArrivalCheck`). The connection card now accurately displays "Testing new network" or "Check in progress", and heartbeat displays an active "• Checking" badge with a progress indicator instead of claiming monitoring is paused.
  - Reset and cleared Ping Heartbeat packet drop history when starting and concluding new network baseline checks, preventing transient packet drops from initial Wi-Fi 4-way handshakes and DHCP negotiation from lingering as alarming red packet loss warnings (e.g. `! 4 missed (12.5%)`). Footer stats calmly display "Awaiting first check results…" during the check.
  - Guarded Router node detail (`routerDetailText`) to display "Checking…" while awaiting initial measurements rather than prematurely asserting "default gateway".
  - Prevented premature public IP country name and flag from rendering on the Internet route node before internet connectivity and latency are verified.
  - Prevented `PingHeartbeat.seedFromSamples` from fabricating false `MISS` drops on unmeasured cycles, made seeding gateway-target aware, and ensured pre-arrival samples are never re-seeded after an arrival check reset.
- **Diagnostic Attribution, Signal Clarity & UI Consistency**:
  - Updated `HopAttributionResolver` so `W6` (2.4 GHz band) and `W4`/`W5` carry accurate headlines and advisory/culprit badges (e.g. `Advisory: 2.4 GHz Band`) rather than falling back to `"Culprit: Weak Wi-Fi"`, and distinguished `SOCK-1`, `HOG-1`, `CONN-1`, `NT-1`, and `EDNS-1` badges on the Mac hop. Fixed `HopAttributionCompactView` to honor `result.badgeTint`.
  - Fixed `PlainEnglishTranslator.translateSummaryPatterns` so benign phrases like `"0% packet loss"` or `"no packet loss"` are not misclassified as `"Moderate Internet Packet Loss"` (`L2`).
  - Decoupled physical Wi-Fi signal strength from link lag and advisory Wi-Fi rules in `HomeView` and `DropdownView`, keeping strong RSSI readings green while wireless latency is shown on the link connector.
  - Aligned `LiveView` Router Ping gauge thresholds (`< 25 ms` green, `< 60 ms` yellow) with the Dashboard and Popover, surfaced the active probing cadence pill in `LiveView`, and wired the Captive Portal login button to `coordinator.openPortalPage()`.
  - Updated `ActivityView.isIssue` to exclude informational rules (`severity == "info"`) and `rule-cleared` entries from the incident count and `"Issues Only"` filter, and passed rule severity into `EventStyle.tint` in `MenuActivitySnippetView` and `DashboardRecentActivityPanel`.
  - Wired `"Smart battery-saver cadence"` toggle changes and `NSProcessInfoPowerStateDidChange` events to `coordinator.applyCadenceSettings()`, added clipboard confirmation toasts in `HomeView` and `SettingsView`, and expanded `NetworksView` search to match network IDs and bridged keys.
- **Suitability, Availability, Incident Reports & Support Export Refinements**:
  - Aligned `SuitabilityEngine` settling/arrival tile ordering and labels (`VPN / Remote`, `shield`, `globe`), matched actual tile statuses (`"Lag spikes"`, `"MTU clamped"`, `"Slow lookups"`) in `defaultConsequence`, avoided displaying a fabricated `"2ms jit"` metric when jitter is unmeasured, and removed duplicate dead probe checks in `evaluateBrowsing`.
  - Updated `AvailabilityEngine.evaluate` to include live elapsed duration (`now.timeIntervalSince(entry.latest)`) for ongoing open outages so total downtime and longest outage stay accurate in real time.
  - Refined `ActivityDetailCard` so `HOG-1` entries without captured process names fall back to the rule blurb rather than contradicting their own title, prevented stamping the current live public IP/ISP onto historical `public-ip-changed` events, and fixed transition labels (`ISP Transition`, `Country Transition`, `Wi-Fi Transition`) in Markdown incident exports.
  - Updated `SupportSummaryFormatter` to honor ICMP ping filtering (`TCP-1` and `ICMP-1`) instead of blaming the router or ISP for `"dropping 100% of packets"`, and checked for heavy local traffic (`TR-1`, `HOG-1`, or high Mbps) before claiming `"Mac traffic is low"`.
  - Allowed completing `OnboardingView` when Location Services is declined or unavailable (matching the gateway-MAC fallback design), cancelled in-flight background preloads in `UpdateChecker.installUpdate()` and cleaned up temporary directories on failure, added clamped outlier markers for Internet Ping in `TrendsView` along with `"All networks"` speed test peak badges, and aligned `NetworkDetailCard` latency delta text with `gatewayLatencyVerdict`.
  - Fixed `AlertEngine.gatewayChangeHolds` to resolve readable SSIDs via `liveSSID` fallback instead of treating `"<redacted>"` as a literal SSID, cleared stale `"— resolved"` notifications when an alert re-raises inside its cooldown, guarded `--uninstall-watcher` dispatch in `bin/hopwatch`, and rejected the conflicting `--wifi-only --quick` flag pair.
- **Captive Portal Repair, Power & Window Management, and Check Table Polish**:
  - Fixed `CP-1` (`open-sign-in`) repair offer in `lib/diagnosis.sh` and `lib/repairs.sh` so it no longer attaches a `url=...` parameter rejected by `repair_validate()` with exit status `3`.
  - Preserved `"Show Hopwatch in Dock & App Switcher"` (`Defaults.showInDock`) in `HopwatchCoordinator.applyActivationPolicy()` when all windows close, and removed duplicate `windowAppeared()` / `windowDisappeared()` calls in `SettingsView`.
  - Removed the redundant unconditional `monitor.forceRefresh()` (`SIGUSR2`) right after `monitor.start()` in `HopwatchCoordinator.handleNetworkEvent` so newly spawned monitor processes are never signaled before installing their trap.
  - Wired `"Pause on low battery"` (`Defaults.pauseOnBattery`) via `PowerSourceHelper.isLowBattery` and `HopwatchCoordinator.evaluateBatteryPauseState()`, and mirrored `autoDownloadAndInstallUpdates` on `@Observable` `AppSettings`.
  - Updated `PingHeartbeat` to select `/sbin/ping6` when targeting an IPv6 gateway address instead of failing in an IPv4 `/sbin/ping` respawn loop.
  - Updated `HomeView` Check Details table to compute `"Usual"` Wi-Fi Signal and SNR baselines from `HistoryStore.median`, show a warning icon when MTU is reduced (`< 1400`), format download-only speed results cleanly, and check `snap?.measuredIPv6 != nil` so `--quick` runs do not falsely report `"IPv4-only connection"`.
  - Updated `DropdownView.quietLine` to use an uncapped lookback window (`withinHours: nil`) with day formatting matching `HomeView`, preserved active session state in `reconcileNetworkIdentity` when Location Services upgrades a `gw:` key to `ssid:` on the same gateway, and logged JSON decode errors in `HopwatchRunner`.
- **Harness & Verification Integrity (`VerifyMode`)**:
  - Restored strict scoping in `HopwatchCoordinator.hydrateFromHistoryIfNeeded`: speed test hydration on cold launch is gated exclusively on live monitor or explicit test network confirmation, preventing unconfirmed runs on disk from prematurely populating the speed test widget.
  - Aligned `ActivityEntry.fold` with multi-network fault folding rules: open episodes on one network are not closed prematurely when orphan clears or events arrive on a different network, and network keys are canonicalized through `NetworkIdentity.canonical` to prevent SSID resolution jitter from splitting episodes.
  - Fixed `NetworkIdentity.fold` to allow private RFC-1918 gateway keys to fold onto their uniquely observed MAC group, and preserved fail-closed legacy migration behavior for saved arrival states.
- **Root Cause & Culprit Attribution (`HopAttributionResolver`)**:
  - Prevented disconnected states (`N1`: "No network connection at all") from being misattributed as upstream ISP outages with contradictory claims that "Wi-Fi is healthy and router is reachable", correctly attributing them as link disconnections.
  - Prioritized critical Mac-level faults (`SOCK-1`: system UDP socket exhaustion) over advisory Wi-Fi or router warnings in the culprit chain, promoted DHCP failure (`DH-3`) to critical router health, and eliminated duplicate `NT-1` classification.
- **Availability Outage Precision (`lib/availability.sh`)**:
  - Canonicalized network IDs via `canonical_network_id` when parsing journal episodes for `AV-1` and `AV-2`, ensuring background recorder episodes reliably match GUI scans that include SSID hints.
- **Filtered Ping Handling in Baseline & Show Regressions**:
  - Suppressed ICMP-filtered legs (`TCP-1` gateway loss and `ICMP-1` internet loss) in `helpers/history.py` (`build_comparison`) and `helpers/baseline.py`, preventing intentional ICMP firewall silence from flagging false loss regressions and `BL-1` warnings.
- **Redaction Privacy & UI Polish**:
  - Filtered buffered parallel output in `lib/common.sh` through `_redact_line` during `--expert --redact` runs.
  - Synchronized `PingHeartbeatView` hover readout with `beatTick` during stationary mouse hovering and clamped tooltip callouts to dynamic container width.
  - Formatted `ExpertPanel` to omit unmeasured alternate internet loss rows on quick scans and surfaced internet bufferbloat metrics (`bufferbloat Δ internet` and grade).

## [1.23.0] - 2026-11-01

### Added
- **Smart Battery-Saver Cadence**: Added `batterySaverCadence` preference (enabled by default) and Settings toggle. When running on battery power or in macOS Low Power Mode, Hopwatch automatically relaxes background sampling to 12s when the connection is stable, immediately resuming fast probing upon packet loss, latency degradation, or user-initiated latency tests.
- **Customizable Menu Bar Latency & Packet Loss Display**: Added `.dotPingAndLoss` ("Dot, ping time, and packet loss") style in Settings, displaying both live latency and packet loss (e.g. `● 18ms · 0% loss`) directly in the macOS menu bar.
- **Router Firewall Shield Badge 🛡️**: In `HopAttributionView` and compact status cards, rendered an explicit blue shield badge and `"Firewall 🛡️"` label on the Router node when gateway ICMP pings are blocked (`TCP-1`), reassuring users that their router is protected by a firewall rather than failing.
- **1-Click Markdown Incident Report Export**: Enhanced `ActivityDetailCard` with a 1-click "Copy Incident Report" action that formats a clean, sanitized Markdown report with condition name, timing, occurrences, network name, ISP, IP transitions, and diagnostic advice for IT support or ISP chat.
- **Contextual Location Permission Helper**: Added an actionable banner above the network list in the Networks tab when connected to Wi-Fi without Location Services authorization, explaining why SSIDs are withheld by macOS with a 1-click button to open System Settings.
- **Wi-Fi Roaming & Mesh Handoff Quality Enrichment**: Enriched `wifi-roamed` events with the destination channel and RSSI (e.g. `"Roamed to access point (ch 36, -58 dBm)"`).
- **Mac System Sleep Humanization**: Replaced raw, alarming observation gap summaries (`"Not observed for 902s"`) with human-friendly sleep representations: `"Mac was asleep (15m 2s)"`, with a `moon.fill` symbol and `"Sleep"` badge.
- **DNS Resolver Health Telemetry**: Enriched DNS server telemetry in the dashboard with live resolver response time (e.g. `192.168.1.1 (12 ms)`).

### Fixed
- Fixed network identity resolution, router MAC discovery, and weak gateway bridging:
  - Added router MAC extraction fallback via `ipconfig getsummary "$INTERFACE"` in `lib/arp.sh` and `lib/monitor.sh` when `arp -an` returns empty under adhoc-signed subshells on macOS Sequoia.
  - Bridged weak `gw:` records to unambiguous Wi-Fi `ssid:` groups in `helpers/history.py` when the gateway IP, ISP, and wireless channel uniquely match, unifying isolated private gateway checks with canonical Wi-Fi history while preserving separate identities between 2.4 GHz and 5 GHz networks.
  - Incorporated explicit CLI bridges (`bridgedFrom`) directly into `HistoryStore.foldedKeys`, allowing weak gateway keys to fold directly onto canonical Wi-Fi networks in the GUI.
  - Resolved router ownership (`isOwned` / `isCurrentNetworkOwned`) and admin shortcuts through canonical network identity, ensuring custom router settings and admin actions work seamlessly on Wi-Fi.
  - Updated `NetworksView` and `TrendsView` to resolve the current network via `confirmedNetworkID ?? resolvedNetworkID(...)`, ensuring the active network is correctly highlighted, selected, and defaulted.
  - Scoped `HopwatchCoordinator.currentNetworkEvents` to canonical SSID groups and connected live CoreWLAN SSID to `AlertEngine`, preventing false captive portal alerts on known networks.
- Fixed dangling open episodes when departing a network: In `ActivityEntry.fold()`, open episodes from a departed network are automatically closed at departure time with `isLowerBound = true`, preventing historical network faults from remaining open indefinitely when disconnecting or changing locations.
- Excluded `gap` (sleep) and `wifi-roamed` events from `ActivityView.isIssue(_:)` so neutral system transitions do not inflate the "Issues Only" filter count.
- Fixed missing speed test metrics and "not tested yet" display on Wi-Fi networks:
  - Added Wi-Fi network key normalization in `HopwatchCoordinator` (`resolvedNetworkID`): when macOS hides the Wi-Fi SSID from the background CLI monitor helper causing it to emit a fallback private gateway key (e.g. `gw:192.168.1.1`), the coordinator now resolves the active network ID to the known CoreWLAN SSID (`ssid:<name>`).
  - Updated `confirmedNetworkID`, `reconcileNetworkIdentity`, `currentSpeedTest`, and `runIsForNetwork` to use the resolved network key, ensuring stored throughput tests and live scan results for the active Wi-Fi network are properly matched and displayed rather than being withheld as an unknown or mismatched network.
  - Ensured `adoptStoredSpeedTest` runs once history completes loading when `latestSpeedTest` is unpopulated, preventing asynchronous history loading from leaving speed test figures uninitialized.
- Fixed premature degraded alarms ("Unstable for calls & gaming") and suppressed full check upon joining new networks:
  - Disallowed RFC 1918 private/local gateway IP keys (`192.168.x.x`, `10.x.x.x`, `172.16-31.x.x`) from persisting in `arrivalStates` and from being folded onto MAC groups in `NetworkIdentity.fold`. Purged stale private gateway entries from preferences so common router subnets (e.g. `192.168.1.1`) never falsely suppress new network baseline checks.
  - Prioritized active Wi-Fi SSID over weak private gateway keys in `considerArrival` when evaluating arrival check candidacy on wireless links.
  - Extended connection settling grace period from 4 seconds to 15 seconds after network changes and wake events, ensuring DHCP lease acquisition, ARP resolution, and initial handshakes settle before steady-state verdicts are evaluated.
  - Updated `ArrivalPolicy.decide` to return `.wait` while the connection is settling, preventing initial association packet spikes from permanently downgrading arrival scans to `.quick(.unhealthy)`. Once settled, a full check runs automatically.
  - Suppressed premature service degradation verdicts ("Severe stutter", "Frequent spikes") in `SuitabilityEngine` during settling and arrival scan execution, showing calm "Settling…" / "Checking…" states rather than flashing false critical alarms on single-packet handshake spikes.
  - Guarded `currentJitter` on brand new connections so raw single-cycle ping stddev spikes (≥30ms) require multi-sample confirmation before asserting elevated jitter.
- Fixed dual-stack IPv4/IPv6 public IP flapping in CLI monitor:
  - Tracked IPv4 and IPv6 public IP addresses distinctly across monitor cycles in `helpers/monitor_sample.py` and `lib/monitor.sh`.
  - Prevented transient curl fallback switches between IPv4 and IPv6 on dual-stack networks (where ISP, country, and network identity remain unchanged) from emitting spurious `public-ip-changed` events unless the respective address family's IP actually changed.
- Fixed transient `TCP-1` and `D1` rule firings during interface drop, roam, and handshake in `lib/monitor.sh`:
  - Guarded `TCP-1` evaluation so it only fires when confirmed by a fresh medium-tier check (`MON_MEDIUM_FRESH=1` or `MON_REFRESHED` contains `medium`), preventing stale `MON_TCP_OK=1` readings from past cycles from falsely diagnosing ICMP filtering when a network begins dropping. Established `TCP-1` states continue to hold across fast cycles.
  - On network changes (`network_changed=1`), cleared stale tier readings (`_mon_clear_measurements`), previous rules (`MON_PREV_RULES=""`), dual-stack family records, and connection confirmation streaks (`_mon_conn_reset`), ensuring fresh multi-sample confirmations are required before `TCP-1` or `D1` can fire on a newly joined or transitioning network.
- Fixed visual layout and text clipping in Hopwatch menu bar dropdown and dashboard views:
  - Applied `minimumScaleFactor(0.75)` on status labels and metric text in `ExperienceGridView` so compound metrics (e.g. `0% loss · 1ms jitter`) and status labels fit cleanly in the 4-column layout without truncation.
  - Allowed activity subtitles (`item.consequence`) in `DashboardSuitabilityStrip` ("What should work") to wrap up to 2 lines with unconstrained vertical sizing, resolving clipping across Voice Calls, Online Gaming, Video Streaming, and Web Browsing cards.
  - Switched `ActivityRow` transition event summaries containing `" → "` (e.g. ISP, country, or public IP changes) to middle truncation so both origin and destination entities remain readable.
- Fixed paused monitor state desynchronization during display sleep and wake in `lib/monitor.sh` and `helpers/monitor_sample.py`:
  - When display sleep triggers monitor pause (`MON_PAUSED=1`), `lib/monitor.sh`'s pause announcement cycle now sets `MON_CLEARABLE_RULES=""` and preserves `MON_RULES="$MON_PREV_RULES"`, preventing active rules from being cleared without measurements while probing is suspended.
  - Guarded `helpers/monitor_sample.py`'s `_changes()` when `_env("PAUSED") == "1"` so pause announcements never append spurious `rule-cleared` events to `events.jsonl`.
  - Added `unset NETDIAG_MON_JOURNAL MONITOR_JOURNAL` to `tests/setup_suite.bash` to prevent developer shell environments from leaking test events into the user's live `~/net-diag/events.jsonl`.
- Fixed Wi-Fi network name reporting previous network after switching connections (e.g. reporting a previous Airbnb or hotel network while connected to personal phone hotspot):
  - Fixed a race condition where `adoptLiveSSIDAsNameIfNeeded` adopted the newly connected Wi-Fi SSID onto the *previous* network's ID before the monitor child process produced a new sample, writing cross-pollinated renames (such as `"ssid:Brian’s iPhone" = "Flat Classic 203 - 204"`) into persistent `networkNames` preferences.
  - Restricted `adoptLiveSSIDAsNameIfNeeded` to hardware router `mac:` keys on fresh samples from the active connection, strictly forbidding automated SSID adoption onto `ssid:` or `gw:` keys.
  - Made `CoreWLAN`'s live SSID authoritative in `wifiDisplayName`: prevented stale router MAC custom names from overriding the live Wi-Fi SSID when connected.
  - Fixed `NetworkEventWatcher.Event.ssidChanged` transition handling in `handleNetworkEvent` which previously skipped connection invalidation when `knownSSID` was unset or transitional, leaving previous network state active.
  - Added automatic purge of corrupted cross-SSID custom name entries in `HistoryStore.load()` and `migrateRawKeys`.
- Fixed all tabs for data display and telemetry formatting issues:
  - **Overview**: Resolved `DashboardCheckTable` row states under ICMP filtering so router packet loss shows "Blocked [Declined by router]" (neutral) instead of a false 100% critical alert, internet packet loss shows "Filtered (TCP ok)", router latency shows "Blocked" rather than claiming "Good", and unmeasured jitter displays "Measuring…" with a neutral badge rather than falsely asserting "0 ms [Good]".
  - **Live Monitoring**: Packet loss chart hover tooltip now uses decimal precision formatting so fractional loss (e.g. 0.4%) displays accurately instead of rounding down to "0 %". Empty state now shows "Measuring packet loss…" to match companion charts.
  - **Activity**: Summary card now displays honest "No Activity Recorded Yet" on a fresh install or clean history rather than declaring "Connection Stable & Quiet across 1 day(s)".
  - **Trends**: Resolved sample count aliases for Wi-Fi signal, Wi-Fi SNR, internet ping, and bufferbloat metrics in the metric picker so sample counts no longer show as `(0)` when samples are recorded. Prevented router latency p90 clamping from clipping companion internet ping lines or marking normal WAN latency as outliers.
  - **Networks**: Split network header metadata into a dedicated status badge row and an SSID / Gateway / ISP / Date row to prevent aggressive horizontal truncation. Guarded `NetworkDetailCard` reliability calculation against negative clean ratios (e.g. `-1/2 Clean`).
  - **Settings**: Renamed the secondary "What’s New…" button on available updates to "Review Update…" to eliminate adjacent duplicate labels.
- Fixed Dashboard Connection Reliability widget staying frozen or displaying "No history yet" / "Monitoring started recently": `DashboardReliabilityCard` now dynamically synthesizes live availability via `AvailabilityEngine` directly from active `NetworkEvent` transition history and live heartbeat telemetry rather than relying solely on a stale point-in-time snapshot from a manual scan. Real connection drops, router packet loss episodes, and total downtime update in real time.
- Fixed Wi-Fi network misidentification on shared router gateway subnets: private/local RFC 1918 gateway IPs (e.g. `192.168.1.254`, `192.168.1.1`, `10.x.x.x`) are no longer folded onto previously visited network groups in `HistoryStore`, and live CoreWLAN SSIDs are prioritized over weak gateway keys and adopted names in `wifiDisplayName`. Stale runs from other locations sharing the same private gateway IP are prevented from hydrating or displaying as the active network.
- Fixed false positive Ping Heartbeat alarms on ICMP-filtering networks: when a network policy drops ICMP ping packets wholesale (common on hotel, apartment, guest, and corporate Wi-Fi), Ping Heartbeat now gracefully recognizes the filtered probe state instead of spawning continuous failing `/sbin/ping` processes and rendering alarming red `MISS` drop markers and a false 100% loss alert. Displays calm, reassuring telemetry (`ICMP probe filtered · TCP traffic healthy` and active TCP connect latency when available).
- Fixed false positive Internet hop warning under ICMP filtering: `RouteWarningResolver` now properly honors `internetPingFiltered` (`ICMP-1`), preventing 100% ICMP probe silence from erroneously painting the Internet node and broadband route amber when actual TCP web connectivity is healthy.
- Fixed Gaming suitability evaluating to "Not measured" when ICMP ping is filtered: resolved an unreachable condition in `SuitabilityEngine.evaluateGaming` so healthy TCP connections accurately report "Smooth" multiplayer capability.
- Added TCP fallback latency evaluation in `SuitabilityEngine.evaluateCalls`: calls now evaluate to "Clear audio" using available TCP/HTTPS connection latency when ICMP pings are blocked by network policy.

### Added
- Added `DataSanityWatchdog` invariant engine to proactively validate UI telemetry against ground truth: continuously checks invariants across event history, heartbeat misses, and reliability calculations, asserting that no widget displays empty or misleading "no prior data" placeholders when network faults are actively recorded.

## [1.22.0] - 2026-10-22

### Changed
- Decoupled Wi-Fi signal strength from wireless link latency/jitter. Signal strength now strictly reflects physical RF reception (e.g. "Excellent" at -43 dBm) with a clean green Wi-Fi icon, eliminating confusing "Good (laggy)" label overrides when standing next to the router.
- Added plain-English distance and proximity guidance under "This Mac" (e.g. `Near router`, `Good range`, `Too far from router`), making it immediately obvious whether moving the laptop will help or if the issue is airtime/router delay.
- Attributed wireless latency to the transmission medium: the connecting link between Mac and Router highlights amber with clear labels (`Wi-Fi (Laggy)`), while the Mac client node maintains a healthy green checkmark when antenna signal is strong and no client-level fault rules have fired.

### Added
- Dynamic 1-Second Ping Heartbeat Animation & Radar Beacon:
  - Added an animated radar ripple / beacon wave on the leading edge (the newest probe on the right edge of the graph) that pulses outward on every 1-second ICMP packet arrival, visually confirming live network traffic.
  - Added a dedicated "1s live" cadence badge in the header with a pulsing green indicator dot synchronized with packet arrivals.
  - Added a responsive, spring-based heartbeat thump on the header heart icon.
  - Added decimal-precision millisecond telemetry (e.g. `47.3 ms`) in both the live header readout and hover tooltips so subtle microsecond latency shifts tick visibly every second rather than staying visually frozen under rounded integer displays.
  - Added automatic process recovery and dropdown-open activation to guarantee the ping stream is active whenever the menu dropdown is inspected.

### Fixed
- Fixed Ping Heartbeat stream buffering: bypassed Foundation's 1024-byte `AsyncBytes` line-buffering chunk delay by utilizing a non-blocking `DispatchSourceRead` over POSIX file descriptors, ensuring ICMP reply lines and timeout notifications trigger GUI updates instantaneously every 1.0 second without 7–8 second batching delays.
- Fixed `PingHeartbeatView` observation hierarchy in the menu dropdown by explicitly binding `heartbeat` directly to child components.

## [1.21.0] - 2026-10-21

### Added
- Live Ping Heartbeat in the Menu Bar Dropdown: A real-time telemetry card located between "Your connection" and "What this feels like", executing a 1-second continuous ICMP stream. Features a clean line graph over 3 horizontal latency zones (Green bottom for <70ms, White middle for 70–150ms, Red top for >150ms), interactive hover inspection displaying exact latency per probe, prominent red vertical drop markers and "✕" badges for packet timeouts/MISSes, and one-click target toggling between Internet (1.1.1.1) and the local Router gateway.
- Native macOS Software Update Dialog: modeled on the clean Sparkle / Tungsten Edge update experience, featuring current vs available version comparison, an inset card displaying bulleted release notes with conventional commit prefix cleaning, background pre-caching, and one-click Skip This Version, Remind Me Later, and Install Update controls.

### Changed
- Filtered non-urgent network advisories (Double NAT, DHCP lease countdown, clock drift, and baseline speed regressions) out of the mini menu (taskbar dropdown), menu-bar health status dot, and coordinator status headlines. These conditions remain fully reported in the Dashboard findings panel, check tables, and diagnostic run reports.

### Fixed
- Fixed background process lifecycle for ping heartbeat: stopping monitoring in Settings now properly terminates the continuous ping subprocess, and re-enabling monitoring resumes it.
- Fixed ping heartbeat target retention across network changes: roaming or switching networks now resets ping targets back to default and clears stale packets rather than continuing to ping unreachable gateway IPs from prior networks.
- Fixed corrupt heartbeat beat creation during network outages (`link.up == false`) so drops are recorded cleanly as misses instead of producing invalid readings.
- Fixed captive portal sign-in action spawning duplicate browser tabs by cleanly prioritizing direct gateway HTTP under custom DNS and avoiding simultaneous fallback cascades.
- Fixed macOS Dock icon remaining stuck after dismissing the Software Update dialog by re-evaluating activation policy when the modal closes.
- Added visible error messaging in the Software Update dialog when background downloads or extractions fail.

## [1.20.1] - 2026-10-20

### Fixed
- Fixed false captive portal banner and alert hijacking:
  - Eliminated automatic captive portal network learning from rule `N1c` ("joined with no route out") or momentary `no-route` states so home and office networks are never falsely branded as captive portals.
  - Fixed `isLearnedPortalAwaitingSignIn` in `AlertEngine`: networks where internet access is confirmed (`captive_portal == false` and healthy latency/traffic) immediately clear and never raise false sign-in alerts.
  - Fixed `isCaptivePortalAlert` in dropdown and dashboard views so unrelated network findings (e.g. IPv6, double NAT, jitter) are never hijacked and replaced with captive portal sign-in banners.
  - Added automatic unlearning of portal flags when live probes confirm direct internet access without interception.
- Fixed false captive portal detection and persistent network poisoning: macOS `CaptiveNetwork` state reporting `Stage : Unknown` is no longer mistaken for an active captive portal, and probing the default gateway router on port 80 directly is eliminated so that local router admin login pages are never classified as captive portals.
- Fixed misleading "Internet ping: TCP ok" readout when internet pings fail or time out: under gateway ping filtering (`TCP-1`), missing or failing internet pings now accurately display "no reply" or packet loss instead of falsely displaying "TCP ok" in green.
- Fixed 3-hop topology attribution during upstream internet outages: when the gateway router filters ICMP ping, high internet packet loss now properly warns on the Internet hop (red/amber globe) and attributes the culprit to the ISP/Internet rather than blaming the local router.

## [1.20.0] - 2026-10-19

### Fixed
- Eliminated dropdown flip-flopping between "Monitor is not reporting" and active network states during degraded or timing-out probe cycles by stopping unnecessary monitor process restarts on severity transitions, aligning the coordinator watchdog window with probe timeout durations, and ignoring redundant SSID notifications.
- Updated `G2` (router packet loss with strong Wi-Fi signal) diagnosis and away-network guidance to rule out wireless distance and accurately attribute the issue to overloaded/rebooting router or access-point hardware or upstream ISP failures.
- Enriched "Copy 1-Click IT / Support Ticket" so it always includes the latest telemetry (gateway IP, signal quality, packet loss, active alert/rule findings) even if triggered between live sample windows.
- Fixed captive portal diagnosis to prioritize sign-in instructions and suppress router-reboot blaming (G1/G2/G3) on hotel and guest networks.
- Fixed Support Summary report generation to accurately describe captive portal authentication and avoid misleading front-desk reboot requests.
- Fixed Internet hop node rendering to prevent displaying a green checkmark when internet ping has 100% packet loss / "no reply".
- Suppressed generic connection-unstable and connection-lost alerts while awaiting captive portal authentication.

## [1.19.1] - 2026-10-16

### Changes

- fix(gui): resolve arrival scan loop on weak network IDs and menu bar memory leak

## [1.19.0] - 2026-10-16

### Added
- Captive portal learning and 1-click sign-in button from alert banner
- Custom DNS compatibility for captive networks (bypasses public DNS to reach router gateway)
- Network memory indicator for networks requiring portal authentication
- Plain English ELI5 translations for network diagnostic faults and findings
- Global system hotkey (⌥⌘N) to summon Hopwatch from anywhere
- Dynamic menu bar display mode (minimal dot when healthy, expands when degraded)
- Audio chime sound cues (Basso on disconnect, Glass on restore)
- Instant update restart with background pre-caching
- 1-click IT & ISP support ticket dispatch formatting
- What's New release highlights sheet

### Fixed
- Corrected Double-NAT detection to recognize local gateway and home subnets (10.0.0.x / 10.0.1.x) in 10/8 as home-side.
- Fixed Tailscale VPN detection to require an active online exit node before treating Tailscale as default-route VPN.
- Fixed Wi-Fi 6 GHz band detection in rule W6 to prevent false 2.4 GHz band-trapping warnings.
- Fixed MTR per-hop fallback to preserve true traceroute hop numbers when intermediate hops time out.
- Fixed bufferbloat probe to sustain download load across fast connections and grade saturated 100% loss as Grade F.
- Fixed IP address target handling in DNS and connection reachability checks.

## [1.18.1] - 2026-10-15

### Changes

- docs: hosting moved from vps2 to prod1 (#14)

## [1.18.0] - 2026-10-14

### Changes

- Merge pull request #12 from godigi/fix/audit-round2
- test: restore PATH after the no-sudo test so bats teardown can find rm
- fix(gui): Copy redacted report actually puts the report on the pasteboard
- Merge branch 'worktree-agent-aa35901282fead524' into fix/audit-round2
- feat(gui): gate the share actions on a new 'share' capability
- fix(gui): flush the event log synchronously on quit
- fix(gui): scan-only alerts are no longer suppressed by their own scan
- fix(gui): Home's quiet line scopes to the current network without the 24 h cap
- fix(gui): drop stale announced faults without posting 'Restored'
- fix(gui): Settings re-check restarts the monitor now and clears the stale error
- fix(gui): HistoryStore.load publishes the newest finished load, ignores cancellation
- fix(gui): finish the progress stream before execute's early throws
- fix(gui): ChildProcess.feed owns its stdin fd; bound drain after exit
- fix(common): ping_sigint_bound cleans up after itself; sudo gate needs sudo even for root
- fix(json): --quick --speed is budgeted by what ran, not the 8 s quick budget
- fix(wifi): strip 0x1f from scraped values and stop reading tab-separated records
- fix(share): mask IPv6 prefixes and addresses ending in '::'
- fix(monitor): a signal-induced emit failure exits 0, not 3
- fix(redact): mask $HOME, watcher path and every WAN_LB_IPS address in text mode

## [1.17.2] - 2026-10-14

### Changes

- Merge pull request #11 from godigi/fix/audit-2026-10
- Merge branch 'worktree-agent-a8c3d8446d66a25db' into fix/audit-2026-10
- Merge branch 'worktree-agent-a012de52df3eb1733' into fix/audit-2026-10
- refactor(thresholds): move baseline cutoffs and run budgets into lib/thresholds.sh
- docs(architecture): mtr no longer implies sudo
- docs(schema): netdiag_extras is the real key; document browser_health
- fix(headline): show the Router row at 100% loss; judge the MTU row like rule M1
- fix(monitor): free the stream on stop, init MON_INET_RTT, report emit failure, move loss floors to thresholds
- fix(probes): bound pings with -W, bound ping6 with SIGINT, unknown hop is not clean, fix ::1 filter
- fix(gui): harden the self-updater
- fix(gui): don't drop the first monitor sample in the second after a boundary
- fix(gui): serialise event-log writes and drop stale history loads
- fix(gui): scope the Live view's last event to the current network
- fix(gui): do not cache a failed capability handshake for the session
- fix(helpers): never emit NaN/Infinity; summary skips non-object JSONL lines
- fix(wifi): keep empty Wi-Fi fields in their slot with a non-whitespace separator
- fix(gui): alert pause state, event announcements and same-network roams
- fix(traffic): difference nettop counters per (name, pid), then sum by name
- fix(browser): bind helper-process matching to the browser's own bundle
- fix(events): keep both rule-cleared rows from one sample
- fix(launchd,watch): escape plist XML, check launchctl load, stop calling exit 1/2 a failure
- fix(gui): ignore SIGPIPE and cancel scans through their whole process group
- fix(redact): close share --json, WAN IP and watcher-path leaks under --redact
- fix(sudo): make sudo opt-in and a last resort

## [1.17.1] - 2026-10-13

### Fixed

- **The "All good" banner is readable in dark mode.** The green status banner at the top of Home and the main window set its headline, sentence and "All systems nominal" pill in a fixed dark green that disappeared against the dark green background. They now use the app's own green and body-text colours, which adapt to the appearance, so the banner reads clearly in both light and dark mode. The README and `docs/SCREENSHOTS.md` images that show it are re-captured from synthetic data.
- **Old cache files no longer pile up.** Each version of the app saved its own copy of the rules catalog and the signal scale in its Application Support folder and never removed the older ones, so the folder grew by two files per release. The app now deletes every copy that belongs to another version and keeps only the current one. Nothing else in the folder is touched.
- **The changelog's version links no longer point at deleted tags.** Only the newest release and tag are kept, so the "compare" links under 1.17.0, 1.16.3 and 1.16.2 led to pages that no longer exist. Older versions now link to the commit that released them, and the release script keeps doing that for each version it supersedes instead of generating a link to a tag that is about to be removed.

## [1.17.0] - 2026-10-13

### Fixed

- **The offline card's remaining copy now comes from the CLI.** The monitor's `link.offline` gains `reason_label`, the short caption for the reason ("Wi-Fi is off" for `wifi-off`, "Not connected" for `wifi-not-joined` and `wifi-no-address`, `null` for the rest and for a wired link). The Mac node and the signal tile render it verbatim and fall back to the neutral "No link" wording when it is absent, instead of mapping reasons to text in Swift. The "Not connected" caption under the Mac node in the menu-bar card replaces the old "Wi-Fi · not connected" so one label serves both places.
- **Rule titles are no longer duplicated in Swift.** When the rules catalog has not loaded, the offline headline falls back to the neutral "No network connection" rather than a copy of the WJ-1 or WF-1 title (the WJ-1 copy had already drifted: "hasn't" against the catalog's "has not"). `NoLinkCopy.fallbackSubtitle`, the line shown under it, was a copy of the start of N1's text; it now only states what the app sees ("Hopwatch's connection monitor reports no active network link.").
- **The Reconnect Wi-Fi button on the offline card is driven by the rules catalog.** The card used to draw it for `WJ-1` or `DH-3`, a list kept in Swift. It now asks the catalog's per-rule `repairs` (decoded in the app from catalog schema 6) which firing rule offers `reconnect-wifi`, so the CLI decides which finding offers which repair here as in scans. Consequence: `WF-1` (Wi-Fi switched off), which the catalog and the scan already offer the repair for, now gets the button too; until the catalog has loaded the card shows only "Open Wi-Fi Settings". A new bats test ties the catalog's `repairs` to the `repair_offer` calls in `lib/`, so they cannot drift.
- **"Right before Wi-Fi dropped" is no longer said of a wired link.** `precursor_summary` is worded for the link that was lost: "Wi-Fi", "the wired connection", or "your connection" when the monitor does not know (a restarted monitor does not: the type is not in the carry record).
- **"Last on wired via 192.168.1.1" is gone.** A wired network's label describes a link, not a name, so `netid_label_is_name` now refuses it and `link.offline.last_network` is `null` for a wired network (the card says "Offline for X" alone). Wi-Fi names are unaffected.

## [1.16.3] - 2026-10-13

### Changed

- **Documentation tidy-up.** The screenshots in the README and `docs/SCREENSHOTS.md` are re-captured from the current app using synthetic data (`scripts/gallery-fixture.py` regenerates the fixture they render), and `docs/CHANGELOG-archive.md` now holds the release notes for every version before 1.16.2. The reference docs say Hopwatch where they still said netdiag, the README's roadmap no longer cites versions that are no longer published, and `docs/BACKLOG.md` keeps only the ideas that are still open.
- **Sample output** (`examples/`) no longer shows a real DNS resolver address or a home-directory path.
- **Changelog tests follow the trimmed release history.** `tests/test_changelog.bats` requires a git tag only for the newest version, checks the README's version credits against the changelog and its archive, and runs its parser tests against the archive, since older tags are no longer kept.

## [1.16.2] - 2026-10-13

### Fixed

- **Tags cut by the auto-version bot now become Releases.** `auto-version.yml` pushes the release commit and tag with the default `GITHUB_TOKEN`, and GitHub does not start workflows from events that token creates, so `release.yml`'s tag trigger never fired: v1.15.1, v1.16.0 and v1.16.1 were tagged with no Release and no DMG, while `Casks/hopwatch.rb` pointed at the DMG that was never built (v1.16.1 was repaired by hand). The job now dispatches `release.yml` for the tag it just pushed (`workflow_dispatch` is allowed from `GITHUB_TOKEN`; it needs `actions: write` and no new secret). A tag pushed from a maintainer's machine still triggers the release by itself and is not dispatched twice.
- **A Release is built from its tag, not from whatever main holds when the job runs.** `release.yml` checked out the default branch, so a merge landing between the tag and the build made `gui/Makefile` name its artefacts from the wrong version. It now checks out the tag; only `CHANGELOG.md` and its reader still come from the default branch, so later corrections to old entries keep reaching the notes.
- **A rejected bot push can no longer leave an orphan tag.** The tag and `main` are pushed atomically and by name instead of with `--follow-tags`, and `auto-version` runs are serialised and start from the tip of `main`, so two merges in quick succession cannot both bump from the same tag.

<!-- Only versions that still have a GitHub Release are kept here; older
     history lives in docs/CHANGELOG-archive.md, which tests/test_changelog.bats
     does not read. -->

[Unreleased]: https://github.com/godigi/hopwatch/compare/v1.24.1...HEAD
[1.24.1]: https://github.com/godigi/hopwatch/releases/tag/v1.24.1
[1.24.0]: https://github.com/godigi/hopwatch/commit/c8f842fd1fb1119b36e7b5e1b34722d80be00d76
[1.23.1]: https://github.com/godigi/hopwatch/commit/3b79c6c402610411cf75d24e4e4a4569bbe96fc8
[1.23.0]: https://github.com/godigi/hopwatch/commit/88326623acff0545af1da67884f03f31ac328e27
[1.22.0]: https://github.com/godigi/hopwatch/commit/b9538f93648739b5515d34eea0eb29e7b592a752
[1.21.0]: https://github.com/godigi/hopwatch/commit/8af9b55d24ca875f223196ab4b69c9b07635b296
[1.20.1]: https://github.com/godigi/hopwatch/commit/52c71e3dc125133c3c395de6f004394762825f17
[1.20.0]: https://github.com/godigi/hopwatch/commit/0202371d64474cfd06d9c5b1c5299b8c81ea29a9
[1.19.1]: https://github.com/godigi/hopwatch/commit/03beb7f6daddef01d2fb94e104363eae01374572
[1.19.0]: https://github.com/godigi/hopwatch/commit/0d87c149a5434e1b16733fb4e16ce2f1f4fcfb7b
[1.18.1]: https://github.com/godigi/hopwatch/commit/69148336c6c93b2418b34bdce9b1b9aaf099f148
[1.18.0]: https://github.com/godigi/hopwatch/commit/7b9d11733bda2a37fed505b27c7e81178b50fe61
[1.17.2]: https://github.com/godigi/hopwatch/commit/34aeb710049da8eb73bcf66e116bf3ad05e4695f
[1.17.1]: https://github.com/godigi/hopwatch/commit/d4be4f91116203ba65f20e05eaed87f59c8a6517
[1.17.0]: https://github.com/godigi/hopwatch/commit/685ef4f5e4695ff17a34c5b986f0c877165168fe
[1.16.3]: https://github.com/godigi/hopwatch/commit/7bf928d274434b04483d7a59f5f308785749d242
[1.16.2]: https://github.com/godigi/hopwatch/commit/23379af98d37b28f6b8aed9946c7b103b93dfe9f
