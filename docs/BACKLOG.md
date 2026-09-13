# netdiag Backlog & Engineering Roadmap

This backlog tracks prioritized improvements across the CLI, helpers, and macOS GUI.
Tasks are structured so that an autonomous worker session (e.g. running `/goal`) can pick up the next ready task, implement it against the acceptance criteria, run the test suites, and mark it complete.

---

## Task Index

| ID | Title | Track | Status | Est. Size |
|---|---|---|---|---|
| [TASK-001](#task-001-document-unreleased-gui-episode-folding--monitor-started-parity-in-changelogmd) | Document unreleased GUI episode folding & monitor-started parity in CHANGELOG.md | Quality | **Done** | XS |
| [TASK-002](#task-002-decode-gap_s-in-monitorsampleswift-and-use-in-monitorseriesswift) | Decode `gap_s` in `MonitorSample.swift` and use in `MonitorSeries.swift` | GUI / Monitor | **Done** | S |
| [TASK-003](#task-003-unify-event-journaling-between-gui-and-cli-eventsjsonl) | Unify event journaling between GUI and CLI (`events.jsonl`) | **Track E** (Architecture) | **Done** | M |
| [TASK-004](#task-004-add-launch-at-login-support-to-gui-via-smappservice) | Add "Launch at Login" support to GUI via `SMAppService` | **Track E** (Architecture) | **Done** | S |
| [TASK-005](#task-005-subnet-crowding-telemetry--device-surge-detection-lan-1) | Subnet crowding telemetry & device surge detection (`LAN-1`) | **Track D** (Subnet) | **Done** | M |
| [TASK-008](#task-008-copy-diagnostic-summary-for-support--front-desk--host) | "Copy Diagnostic Summary for Support / Front Desk / Host" | **Track A** (Action Layer) | **Done** | S |
| [TASK-009](#task-009-open-router-admin-page-quick-action) | "Open Router Admin Page" quick action for owned networks | **Track A** (Action Layer) | **Done** | XS |
| [TASK-010](#task-010-open-login-page-action-on-captive-portal-detection) | "Open Login Page" quick action on captive portal detection (`CP-1`) | **Track C** (Captive Portal)| **Done** | S |
| [TASK-011](#task-011-live-latency-in-the-menu-bar) | Live Latency & Ping in the Menu Bar (`● 18ms`) | GUI / Telemetry | **Done** | XS |
| [TASK-012](#task-012-share-diagnostics-menu-action--redacted-report-export) | "Share Diagnostics..." friendly menu action & redacted report export | GUI / Sharing | **Done** | S |
| [TASK-013](#task-013-prominent-speedometer--throughput-gauge-during-speed-test) | Prominent Speedometer & live throughput gauge during speed test | GUI / Polish | **Done** | S |
| [TASK-014](#task-014-sticky-access-point-detection-on-multi-ap-wi-fi-networks-w3) | Sticky Access Point detection on multi-AP Wi-Fi networks (`W3`) | Wi-Fi / Roaming | **Done** | M |
| [TASK-015](#task-015-what-does-this-mean-plain-english-tooltips-on-technical-metrics) | "What Does This Mean?" Plain-English tooltips on technical metrics | GUI / UX | **Done** | S |
| [TASK-016](#task-016-dropdown-view-redesign-unified-telemetry-card-integrated-action--cohesive-visual-hierarchy) | Dropdown View Redesign (Unified Telemetry Card & Integrated Action) | GUI / Redesign | **Done** | M |
| [TASK-017](#task-017-visual-hop-attribution-chain--culprit-badge-mac--wi-fi--router--isp) | Visual Hop Attribution Chain & Culprit Badge (Mac ➔ Wi-Fi ➔ Router ➔ ISP) | GUI / Diagnosis | **Done** | M |
| [TASK-018](#task-018-effective-wi-fi-health--asymmetric-link--rate-collapse-detection-w4-w5) | Effective Wi-Fi Health & Asymmetric Link / Rate-Collapse Detection (`W4`, `W5`) | Wi-Fi / Diagnosis | **Done** | M |
| [TASK-019](#task-019-apple-wireless-direct-link-awdl--airdrop-latency-spike-detection-awdl-1) | Apple Wireless Direct Link (AWDL / AirDrop) Latency Spike Detection (`AWDL-1`) | Wi-Fi / Jitter | **Done** | S |
| [TASK-020](#task-020-unresponsive-primary-dns-resolver--silent-fallback-delay-d5) | Unresponsive Primary DNS Resolver & Silent Fallback Delay (`D5`) | DNS / Latency | **Done** | S |
| [TASK-021](#task-021-suboptimal-wi-fi-band-trapping-detection-w6) | Suboptimal Wi-Fi Band Trapping Detection (`W6`) (2.4 GHz vs 5/6 GHz) | Wi-Fi / Bands | **Done** | S |
| [TASK-022](#task-022-anti-false-positive-guardrails-for-mtu-dhcp-leases-and-bufferbloat-severity-m1-dh-1-b1-b2) | Anti-False-Positive Guardrails for MTU, DHCP Leases & Bufferbloat Severity (`M1`, `DH-1`, `B1`, `B2`) | Diagnosis / Accuracy | **Done** | M |
| [TASK-023](#task-023-audit--align-diagnosis-remediation-with-do-no-harm-standard-d1-d3-v6-2-b1) | Audit & Align Diagnosis Remediation with "Do No Harm" Standard (`D1`, `D3`, `V6-2`, `B1`) | Diagnosis / Safety | **Done** | S |
| [TASK-024](#task-024-network-memory--historical-performance-card-for-known-networks) | Network Memory & Historical Performance Card for Known Networks | GUI / Travel & History | **Done** | M |
| [TASK-025](#task-025-smart-rate-limited-macos-system-notifications-on-network-degradation) | Smart, Rate-Limited macOS System Notifications on Network Degradation | GUI / System Alerts | **Done** | S |
| [TASK-026](#task-026-live-jitter-tracking--real-time-connection-stability-badge-in-monitor) | Live Jitter Tracking & Real-Time Connection Stability Badge in Monitor | GUI / Telemetry & Quality | **Done** | S |
| [TASK-027](#task-027-remediation-feedback--resolution-banner-closed-loop-confirmation) | Remediation Feedback & Resolution Banner (Closed-Loop Confirmation) | GUI / UX & Delight | **Done** | S |
| [TASK-035](#task-035-dashboard-usability--visual-clarity-polish-home-live-activity-trends-networks) | Dashboard Usability & Visual Clarity Polish (Home, Live, Activity, Trends, Networks) | GUI / UX & Design | **Done** | L |
| [TASK-028](#task-028-meeting-shield--live-call--video-conferencing-quality-guardian-zoom--meet--teams) | "Meeting Shield" — Live Call & Video Conferencing Quality Guardian | **Track F** (Live Work) | Low Priority | M |
| [TASK-029](#task-029-find-the-best-desk--walkaround-wi-fi-signal--roaming-surveyor) | "Find the Best Desk" — Walkaround Wi-Fi Signal & Roaming Surveyor | **Track F** (Live Work) | Low Priority | M |
| [TASK-030](#task-030-passive-local-lan-topology--friendly-device-discovery-bonjour--mdns) | Passive Local LAN Topology & Friendly Device Discovery (Bonjour / mDNS) | **Track D** (Subnet & LAN) | Low Priority | M |
| [TASK-031](#task-031-upstream-isp-outage-corroborator--1-click-support-ticket-dispatch) | Upstream ISP Outage Corroborator & 1-Click Support Ticket Dispatch | **Track A** (Action Layer) | Low Priority | S |
| [TASK-032](#task-032-native-macos-desktop--notification-center-widgets-via-widgetkit) | Native macOS Desktop & Notification Center Widgets via `WidgetKit` | **Track E** (Architecture) | Low Priority | M |
| [TASK-033](#task-033-apple-shortcuts-integration--app-intents-automation) | Apple Shortcuts Integration & App Intents Automation | **Track E** (Architecture) | Low Priority | S |
| [TASK-034](#task-034-gaming--low-latency-stream-optimizer-interactive-cake--sqm-router-guide) | Gaming & Low-Latency Stream Optimizer (Interactive CAKE / SQM Router Guide) | Diagnosis / Remediation | Low Priority | S |
| [TASK-006](#task-006-icloud-private-relay--profile-encrypted-dns-qualifiers-pr-1-edns-1) | iCloud Private Relay & Profile Encrypted DNS qualifiers (`PR-1`, `EDNS-1`) | CLI / Diagnosis | **Done** | M |
| [TASK-007](#task-007-gui-distribution-dmg-packaging-and-homebrew-formula) | GUI distribution DMG packaging and Homebrew formula | Build & Dist | **Done** | M |

---

## Detailed Task Specifications

### TASK-001: Document unreleased GUI episode folding & monitor-started parity in CHANGELOG.md
- **Area**: Documentation / Release Prep
- **Status**: **Done**
- **Files to touch**:
  - `CHANGELOG.md`
- **Context**:
  Commit `5775cad` fixed two parity discrepancies with `helpers/events.py`:
  1. Spanning monitor restarts: `NetdiagCoordinator` now logs `monitor-started` on `sample.seq == 1`, and `ActivityEntry.fold` closes open episodes as lower bounds.
  2. Episode keying: `NetworkEvent` now carries `network: String?`, and `ActivityEntry.fold` keys open episodes on `(network, ruleID)` so roaming networks doesn't cross-close faults.
- **Acceptance Criteria**:
  - Detailed entry under `## [Unreleased]` in `CHANGELOG.md` following project voice and format.
  - `bats tests/test_changelog.bats` passes.

---

### TASK-002: Decode `gap_s` in `MonitorSample.swift` and use in `MonitorSeries.swift`
- **Area**: macOS GUI / Live Chart
- **Status**: **Done**
- **Files to touch**:
  - `gui/Sources/NetdiagGUI/Models/MonitorSample.swift`
  - `gui/Sources/NetdiagGUI/Support/MonitorSeries.swift`
  - `gui/Tests/NetdiagGUITests/` or `gui/Sources/NetdiagGUI/VerifyMode.swift`
- **Context**:
  `lib/monitor.sh` accurately measures time lost to sleep and stalls using monotonic time and emits `gap_s` (null on regular samples, integer on gap samples). `MonitorSample.swift` does not declare or decode `gap_s`. `MonitorSeries.swift` currently uses a rough heuristic (`now - prev > cadence * 2`) to identify gaps.
- **Acceptance Criteria**:
  - `MonitorSample` declares `var gapS: Int?` with CodingKey `"gap_s"`.
  - `MonitorSeries` uses `sample.gapS` when present to mark a `Gap`, falling back to `cadence * 2` only when absent.
  - Swift tests pass: `swift run -c debug NetdiagGUI --verify` and `make -C gui test`.

---

### TASK-003: Unify event journaling between GUI and CLI (`events.jsonl`) [Track E]
- **Area**: Core Architecture / Availability
- **Status**: **Done**
- **Files to touch**:
  - `gui/Sources/NetdiagGUI/Services/MonitorStream.swift`
  - `lib/availability.sh`
  - `docs/ARCHITECTURE.md`
- **Context**:
  `lib/availability.sh` skips with `no event journal (netdiag --install-recorder)` if `~/net-diag/events.jsonl` does not exist. The GUI runs a monitor continuously, but writes only to its internal `events.json`. Spawning the GUI's monitor with `--journal "$HOME/net-diag/events.jsonl"` gives the system a shared, single source of truth for network transitions, enabling `AV-1`/`AV-2` availability rules during GUI-triggered full checks.
- **Acceptance Criteria**:
  - `MonitorStream.spawn` passes `--journal <path>` pointing to `$HOME/net-diag/events.jsonl`.
  - Running a full check from the GUI (or CLI while GUI is running) evaluates availability (`AV-1`/`AV-2`) against real journal history without skipping.
  - `bats tests/test_availability.bats` and `bats tests/test_events.bats` pass.

---

### TASK-004: Add "Launch at Login" support to GUI via `SMAppService` [Track E]
- **Area**: macOS GUI / Settings
- **Status**: **Done**
- **Files to touch**:
  - `gui/Sources/NetdiagGUI/Services/AppSettings.swift`
  - `gui/Sources/NetdiagGUI/Views/SettingsView.swift`
- **Context**:
  `NetdiagGUI` runs as a menu bar item (`LSUIElement`), but after a Mac restart, nothing is watching until the user manually launches the app. Modern macOS provides `SMAppService.mainApp` to register the app as a login item cleanly without background helper bundles.
- **Acceptance Criteria**:
  - Add `launchAtLogin` toggle to Settings UI.
  - Use `SMAppService.mainApp.register()` / `unregister()`.
  - Synchronize toggle state with `SMAppService.mainApp.status == .enabled`.
  - Handle permission errors or unprivileged states gracefully.
  - Clean verification in `--verify` harness.

---

### TASK-005: Subnet crowding telemetry & device surge detection (`LAN-1`) [Track D]
- **Area**: CLI & GUI / Diagnosis
- **Status**: **Done**
- **Files to touch**:
  - `helpers/emit_json.py`
  - `docs/JSON-SCHEMA.md`
  - `gui/Sources/NetdiagGUI/Models/RunSnapshot.swift`
  - `gui/Sources/NetdiagGUI/Views/RunReportView.swift`
  - `helpers/baseline.py`
  - `lib/diagnosis.sh`
  - `tests/test_json.bats`
- **Context**:
  `lib/arp.sh` calculates `ARP_ACTIVE_COUNT`, but it is omitted from JSON output. Consequently, the GUI cannot show local device count, and `baseline.py` cannot detect sudden surges in active devices on a private network (e.g. device count quadrupling on an Airbnb or home network).
- **Acceptance Criteria**:
  - `emit_json.py` includes `"arp_active_count"` under the `lan` block.
  - `RunSnapshot.swift` decodes `arpActiveCount: Int?`.
  - `RunReportView.swift` displays active device count in the LAN summary card.
  - `baseline.py` flags a device count surge when current count is ≥ 3× median on an owned/known network.
  - Bats and Swift verify tests pass.

---

### TASK-008: "Copy Diagnostic Summary for Support / Front Desk / Host" [Track A]
- **Area**: macOS GUI / Action Layer
- **Status**: **Done**
- **Files to touch**:
  - `gui/Sources/NetdiagGUI/Views/RunReportView.swift`
  - `gui/Sources/NetdiagGUI/Views/DropdownView.swift`
  - `gui/Sources/NetdiagGUI/Support/SupportSummaryFormatter.swift` (new helper)
- **Context**:
  When a traveller at a hotel or Airbnb experiences network degradation (e.g. 12% packet loss to the router), they need to communicate the exact problem to non-technical staff without technical jargon. The GUI should provide a one-click "Copy for Support" button.
- **Acceptance Criteria**:
  - Formats a clean, professional plain-text report:
    - Network Name / SSID
    - Local Gateway IP
    - Observed Problem (using `fix_away` if network is not owned)
    - Signal Strength & Quality
    - Local verification ("Laptop link is idle; issue is on the network/router side")
    - Concrete action ("Please restart floor access point / router")
  - Copies formatted text to `NSPasteboard.general` with clear visual feedback ("Copied!").
  - Testable formatter with unit test coverage.

---

### TASK-009: "Open Router Admin Page" quick action [Track A]
- **Area**: macOS GUI / Action Layer
- **Status**: **Done**
- **Files to touch**:
  - `gui/Sources/NetdiagGUI/Views/RunReportView.swift`
  - `gui/Sources/NetdiagGUI/Views/DropdownView.swift`
- **Context**:
  When a diagnosis indicates a router issue (e.g. `G2` or bufferbloat `B1`) on an owned network (`network.isMine == true`), jumping to the router admin portal (`http://192.168.1.1`) to enable SQM or reboot should be a one-click action.
- **Acceptance Criteria**:
  - Validates that `gateway.ip` is an RFC1918 private IPv4 address (`10.x.x.x`, `172.16-31.x.x`, `192.168.x.x`).
  - Only displays the button when `network.isMine == true`.
  - Opens `http://<gateway_ip>` in the default web browser via `NSWorkspace.shared.open`.

---

### TASK-010: "Open Login Page" action on captive portal detection (`CP-1`) [Track C]
- **Area**: macOS GUI / Captive Portal
- **Status**: **Done**
- **Files to touch**:
  - `gui/Sources/NetdiagGUI/Views/DropdownComponents.swift`
  - `gui/Sources/NetdiagGUI/Views/LiveView.swift`
- **Context**:
  When arriving at an airport or cafe, captive portals (`CP-1` / `sample.publicInfo.captivePortal == true`) often silently intercept DNS/HTTP traffic without macOS automatically launching the login assistant. Users sit waiting, wondering why apps aren't connecting.
- **Acceptance Criteria**:
  - In `AlertStageCard` (and Arrival/Live cards), when the active alert is `captive-portal`, surface an explicit action button: `[Open Login Page]`.
  - Clicking opens `http://captive.apple.com/hotspot-detect.html` in the default browser, reliably triggering the portal redirection.
  - Tested in `--verify` harness.

---

### TASK-011: Live Latency in the Menu Bar (`● 18ms`)
- **Area**: macOS GUI / Telemetry & Menu Bar
- **Status**: **Done**
- **Files to touch**:
  - `gui/Sources/NetdiagGUI/Services/AppSettings.swift`
  - `gui/Sources/NetdiagGUI/NetdiagApp.swift`
  - `gui/Sources/NetdiagGUI/Views/SettingsView.swift`
- **Context**:
  During video or voice calls, users want to know instantly if their connection is lagging without clicking the menu bar. Adding a "Dot and ping" menu bar style displays the latest ping (e.g. `● 18ms`, turning amber/red on spikes) directly in the menu bar.
- **Acceptance Criteria**:
  - Add `.dotAndPing` to `AppSettings.MenuBarStyle`.
  - `MenuBarLabel` displays the live rounded RTT (from `coordinator.monitor.latest?.internet.rttMs` or `gateway.rttMs`) in monospace font next to the status dot.
  - Dropdown Picker in `SettingsView` offers "Dot and ping time".
  - Verified in Swift tests.

---

### TASK-012: "Share Diagnostics..." Action & Redacted Report Export
- **Area**: macOS GUI / Sharing & Support
- **Status**: **Done**
- **Files to touch**:
  - `gui/Sources/NetdiagGUI/Views/RunReportView.swift`
  - `gui/Sources/NetdiagGUI/Views/DropdownView.swift`
  - `gui/Sources/NetdiagGUI/Services/NetdiagCoordinator.swift`
- **Context**:
  Users need an easy, user-friendly way to share diagnostic reports with IT helpdesks, landlords, or ISPs without leaking private information (passwords, MACs, public IP).
- **Acceptance Criteria**:
  - Add a friendly menu item / button: `"Share Diagnostics..."` in the report view and dropdown context menu.
  - Exports or copies a redacted diagnostic summary (using the rules defined by `helpers/share.py`).
  - Allows saving as `.json` or `.md` or copying directly to clipboard.
  - Clean error handling and user feedback ("Diagnostic report copied").

---

### TASK-013: Prominent Speedometer & Throughput Gauge during Speed Test
- **Area**: macOS GUI / Visual Polish
- **Status**: **Done**
- **Files to touch**:
  - `gui/Sources/NetdiagGUI/Views/ScanProgressView.swift`
  - `gui/Sources/NetdiagGUI/Models/ScanProgress.swift`
- **Context**:
  The speed test is the longest phase of a full scan (~25s). Currently, live throughput is shown only as a tiny 11pt inline caption. Giving it a prominent, tactile live readout (`↓ 245 Mbps`, `↑ 82 Mbps`) transforms the waiting experience.
- **Acceptance Criteria**:
  - During the `speedtest` phase, `ScanProgressView` renders a prominent live throughput display with directional indicator (`↓ Download` / `↑ Upload`) and live Mbps.
  - Smooth animation as speed milestones arrive via fd-3 progress stream.
  - Reverts gracefully when speed test finishes.

---

### TASK-014: Sticky Access Point detection on multi-AP Wi-Fi networks (`W3`)
- **Area**: Wi-Fi / Diagnosis & Roaming
- **Status**: **Done**
- **Files to touch**:
  - `lib/thresholds.sh`
  - `lib/wifi.sh`
  - `lib/diagnosis.sh`
  - `helpers/rules_catalog.py`
  - `tests/test_parse.bats`
- **Context**:
  In multi-AP environments (mesh networks, offices, hotels), a MacBook often stays associated with a distant AP (-78 dBm) even though a much stronger AP (-50 dBm) on the same SSID is nearby. To avoid noise, an alert must only fire if: (1) multiple BSSIDs exist on this SSID, (2) current signal is poor (≤ -75 dBm) while candidate is ≥ 15 dBm stronger (≥ -60 dBm), and (3) the condition persists for at least 75 seconds.
- **Acceptance Criteria**:
  - Thresholds defined in `lib/thresholds.sh` (`THRESH_WIFI_STICKY_DELTA_DBM=15`, `THRESH_WIFI_STICKY_MAX_RSSI=-75`, `THRESH_WIFI_STICKY_CANDIDATE_MIN_RSSI=-60`).
  - Rule `W3` (info) added to `rules_catalog.py` with fix: "Toggle Wi-Fi off and back on to force macOS to associate with the closer access point."
  - Detection logic validates that the alternative BSSID belongs to the current SSID and enforces the signal delta.
  - Bats unit tests verify triggering when conditions match and staying silent when delta < 15 dBm or single AP.

---

### TASK-006: iCloud Private Relay & Profile Encrypted DNS qualifiers (`PR-1`, `EDNS-1`)
- **Area**: CLI / Diagnosis
- **Status**: **Done**
- **Files to touch**:
  - `lib/path.sh`
  - `lib/diagnosis.sh`
  - `helpers/rules_catalog.py`
  - `tests/test_path.bats`
- **Context**:
  `lib/path.sh` detects iCloud Private Relay and profile encrypted DNS, but diagnostic rules do not consume this to qualify WAN latency, hop timeouts, or explain proxy effects to the user.

---

### TASK-007: GUI distribution DMG packaging and Homebrew formula
- **Area**: Build & Distribution
- **Status**: **Done**
- **Files to touch**:
  - `Makefile`
  - `gui/Makefile`
  - `.github/workflows/release.yml`
- **Context**:
  Allow users to install via `brew install --cask netdiag` or download a signed/stapled `.dmg` artifact from GitHub Releases.

---

### TASK-015: "What Does This Mean?" Plain-English Tooltips on Technical Metrics
- **Area**: macOS GUI / Accessibility & UX
- **Status**: **Done**
- **Files to touch**:
  - `gui/Sources/NetdiagGUI/Views/RunReportView.swift`
  - `gui/Sources/NetdiagGUI/Views/DropdownView.swift`
  - `gui/Sources/NetdiagGUI/Support/MetricGlossary.swift` (new helper)
- **Context**:
  Technical measurements like `Bufferbloat (+184 ms)`, `Packet size (MTU) 1492 bytes`, `UPnP enabled`, `RSSI -76 dBm`, and `SNR 21 dB` leave non-network engineers confused about whether a number is healthy or problematic. Adding native macOS help tooltips (`ⓘ` or hover text) explains the metric in plain, friendly English and outlines its real-world impact.
- **Acceptance Criteria**:
  - Create a central `MetricGlossary` providing concise, jargon-free explanations for all diagnostic rows (Bufferbloat, MTU, RSSI, SNR, IPv6, VPN, UPnP, Clock drift, DNS latency, Packet loss).
  - Add native `.help(...)` or subtle info popover triggers on metric labels in `RunReportView` and `DropdownView`.
  - Explanations focus on real-world impact (e.g. why bufferbloat causes video call audio glitches, why MTU matters for VPNs).
  - Verified in Swift tests.

---

### TASK-016: Dropdown View Redesign (Unified Telemetry Card, Integrated Action & Cohesive Visual Hierarchy)
- **Area**: macOS GUI / Dropdown & Visual Polish
- **Status**: **Done**
- **Files to touch**:
  - `gui/Sources/NetdiagGUI/Views/DropdownView.swift`
  - `gui/Sources/NetdiagGUI/Views/DropdownComponents.swift`
  - `gui/Sources/NetdiagGUI/VerifyMode.swift`
- **Context**:
  The current dropdown stacks 7 disjointed elements vertically with awkward sandwiching (the primary check button sits in the middle of live telemetry, separating the status card from the sparkline and instrument grid). The goal is a cohesive, modern macOS Control Center-style layout where **100% of the content remains immediately visible with zero clicks or disclosures**, but with vastly improved visual hierarchy.
- **Key Architectural Sections**:
  1. **Status Header & Integrated Action**: Status card ("All good — watching on HomeNet 5G") with an integrated, sleek "Run Check" action button, removing the awkward floating sandwich button.
  2. **Performance & Live Heartbeat (Unified Card)**: Fuses the live ping, packet loss, and heartbeat sparkline into one cohesive card, paired beside live throughput (Down/Up speeds and last check age).
  3. **Connection Path & Context Strip**: A 4-item pill row cleanly displaying local first hop (Wi-Fi signal, Router latency) and network identity (VPN state, Country/Public IP).
  4. **Recent Activity Stream**: Formats the 24-hour events with aligned relative timestamps, status glyphs (resolved check, roam icon, alert icon), and clean summary text.
  5. **Utility Footer**: Streamlined bottom bar for Dashboard, Pause, Settings, and Quit.
- **Acceptance Criteria**:
  - All existing features and information remain 100% visible on launch (no collapsing or expanding required).
  - "Run Full Check" is cleanly integrated into the header/stage card.
  - Live ping, packet loss, and the sparkline are visually united in a single card.
  - Passes all tests in `--verify` harness (`swift run -c debug NetdiagGUI --verify`).

---

### TASK-017: Visual Hop Attribution Chain & Culprit Badge (Mac ➔ Wi-Fi ➔ Router ➔ ISP)
- **Area**: macOS GUI / Diagnosis & UX
- **Status**: **Done**
- **Files to touch**:
  - `gui/Sources/NetdiagGUI/Support/HopAttributionResolver.swift` (new helper)
  - `gui/Sources/NetdiagGUI/Views/RunReportView.swift`
  - `gui/Sources/NetdiagGUI/Views/DropdownView.swift`
  - `gui/Sources/NetdiagGUI/VerifyMode.swift`
  - `gui/Tests/NetdiagGUITests/`
- **Context**:
  Users consistently confuse "Wi-Fi" with "Internet" (e.g. rebooting their router or complaining about local signal when the problem is an external ISP outage, or vice versa). While `lib/diagnosis.sh` accurately calculates the fault domain (`G1` vs `G2` for Wi-Fi vs Gateway, `B1` vs `B2` for local bufferbloat vs ISP bufferbloat, `P1`/`P2` for ISP down, `TCP-1` for ICMP blocks), this intelligence is presented as dense rule text that non-technical users find difficult to decipher.
- **Architectural Design**:
  1. **Pure Attribution Resolver (`HopAttributionResolver.swift`)**:
     - Takes `DiagnosticReport` / `RunStatus` snapshots and resolves the network path into 3 distinct segments:
       - **Segment 1: Wi-Fi / Local Link** (Mac ➔ Access Point/Router): Checks RSSI, SNR, noise, channel interference, Wi-Fi gateway loss (`G1`).
       - **Segment 2: Router / Local Gateway** (Access Point ➔ WAN Gateway): Checks router response time, router loss without Wi-Fi degradation (`G2`), local bufferbloat (`B1`), subnet crowding (`LAN-1`).
       - **Segment 3: Internet & ISP** (WAN Gateway ➔ Global CDN / 1.1.1.1 / 8.8.8.8): Checks WAN packet loss (`P1`, `P2`), ISP bufferbloat (`B2`), DNS latency (`D1`, `D2`), captive portal (`CP-1`).
     - Identifies the primary **Culprit** (or confirms "All Clear").
     - Emits structured reassurance text (e.g., *"Your Wi-Fi signal is excellent (-48 dBm). The issue is upstream with your Internet Service Provider."*).
  2. **Visual Hop Chain Component**:
     - Displays a clean, intuitive 3-hop horizontal node chain:
       `[Mac] ──(Wi-Fi)──► [Router] ──(Broadband)──► [Internet]`
     - Each node and link has visual state indicators:
       - 🟢 Healthy / Low Latency
       - 🟡 Warning / Elevated Latency / Bufferbloat
       - 🔴 Broken / Packet Loss / Unreachable
     - A prominent **Culprit Badge** points directly to the failing hop (e.g. `[ Culprit: ISP Outage ]` or `[ Culprit: Weak Wi-Fi ]`).
  3. **Integration**:
     - Embedded prominently at the top of `RunReportView` (Full Check Results) above the detailed metrics table.
     - Condensed compact chain integrated into the `DropdownView` status card when a diagnosis or fault is active.
- **Acceptance Criteria**:
  - `HopAttributionResolver` pure unit tests covering:
    - Wi-Fi signal degraded vs Gateway loss (`G1` -> Wi-Fi culprit).
    - Gateway loss with strong Wi-Fi (`G2` -> Router culprit).
    - Router healthy, Internet ping 100% loss (`P1`/`P2` -> ISP culprit).
    - Local bufferbloat (`B1` -> Router culprit) vs ISP bufferbloat (`B2` -> ISP culprit).
    - All clear (All hops green, zero culprits).
  - Hop chain renders in SwiftUI with accessible symbols and color states.
  - Clear plain-English reassurance explaining which hops are working and which hop failed.
  - Passes all verification suites: `swift run -c debug NetdiagGUI --verify` and `make -C gui test`.

---

### TASK-018: Effective Wi-Fi Health & Asymmetric Link / Rate-Collapse Detection (`W4`, `W5`)
- **Area**: CLI / Diagnosis & Wi-Fi Link Quality
- **Status**: **Done**
- **Files to touch**:
  - `lib/wifi_common.sh`
  - `lib/constants.sh`
  - `lib/diagnosis.sh`
  - `lib/headline.sh`
  - `docs/DIAGNOSIS-RULES.md`
  - `tests/test_diagnosis_wifi.bats`
  - `gui/Sources/NetdiagGUI/Support/HopAttributionResolver.swift`
- **Context**:
  Users frequently encounter situations where Wi-Fi is the root cause of network degradation (and moving closer immediately resolves it), yet traditional tools and the OS signal indicator display "Excellent Signal" (e.g. -50 to -55 dBm).
  This occurs because RSSI measures only the router's beacon power received by the Mac, ignoring:
  1. **Asymmetric Transmit Power**: The wall-powered router transmits at 200–500 mW, while the battery-operated MacBook transmits at 30–50 mW. The Mac hears the router fine, but the router cannot hear the Mac's return frames through obstacles.
  2. **Tx Rate Collapse**: Physical multipath interference causes 802.11 modulation downshifting (e.g. from 866 Mbps down to 12–54 Mbps) despite high RSSI.
  3. **High RF Noise / Low SNR**: Strong signal buried under heavy ambient noise (e.g. -55 dBm signal with -70 dBm noise yields an unusable 15 dB SNR).
- **Architectural Rules & Detection**:
  - **Rule `W4` (Wi-Fi Rate Collapse)**:
    - Triggers when `tx_rate` falls below threshold (e.g. `< 54 Mbps` on Wi-Fi 5/6, or `< 20%` of expected PHY mode rate) while RSSI appears strong (`>= -65 dBm`).
    - *Diagnosis*: "Your Wi-Fi signal power reads strong (${WIFI_RSSI} dBm), but your negotiated transmit rate has collapsed to ${WIFI_TX_RATE} Mbps due to physical obstacles or radio interference. Moving closer to your router will restore full throughput."
  - **Rule `W5` (Asymmetric Wi-Fi Link / Return Path Degradation)**:
    - Triggers when gateway packet loss (`GW_LOSS > 5%`) or extreme local gateway jitter occurs on Wi-Fi even though RSSI is healthy (`>= -65 dBm`).
    - Prevents `G2` from falsely advising "reboot the router or call your ISP".
    - *Diagnosis*: "Your Mac hears a strong signal from your router (${WIFI_RSSI} dBm), but packet loss (${GW_LOSS}%) indicates your router is struggling to hear your Mac through walls or interference. Try moving closer to the router."
  - **SNR Floor Elevation**:
    - Ensure SNR (`RSSI - Noise`) `< 20 dB` triggers a dedicated link-quality warning even if RSSI is in the "green" range.
  - **Hop Attribution Integration**:
    - Update `HopAttributionResolver` (from TASK-017) to evaluate `Effective Wi-Fi Quality` ($f(\text{RSSI}, \text{SNR}, \text{Tx Rate}, \text{GW Loss})$) so the local Wi-Fi hop correctly takes the culprit badge rather than passing blame to the Router or ISP.
- **Acceptance Criteria**:
  - `lib/constants.sh` adds thresholds (`THRESH_WIFI_TX_COLLAPSE_MBPS=54`, `THRESH_WIFI_SNR_MIN_DB=20`).
  - `lib/diagnosis.sh` implements `W4` and `W5` with strict unit tests in `tests/test_diagnosis_wifi.bats`.
  - `docs/DIAGNOSIS-RULES.md` documents `W4` and `W5` rationale and remedies.
  - Passes all tests in `bats tests/` and `make test`.

---

### TASK-019: Apple Wireless Direct Link (AWDL / AirDrop) Latency Spike Detection (`AWDL-1`)
- **Area**: macOS CLI & GUI / Wi-Fi Jitter & Diagnosis
- **Status**: **Done**
- **Files to touch**:
  - `lib/wifi_common.sh`
  - `lib/diagnosis.sh`
  - `lib/constants.sh`
  - `docs/DIAGNOSIS-RULES.md`
  - `helpers/rules_catalog.py`
  - `tests/test_diagnosis_wifi.bats`
- **Context**:
  macOS uses `awdl0` (Apple Wireless Direct Link) for AirDrop, AirPlay, Sidecar, and Universal Control. The Mac's single Wi-Fi radio periodically leaves the current access point channel to scan social channels (channels 44 & 149) for nearby Apple devices. During these discovery hops, network packets stall, causing periodic 200–500 ms latency spikes and micro-freezes in video calls (Zoom, Google Meet, Teams) and gaming. Users mistakenly blame their ISP or router.
- **Architectural Design**:
  - Check `awdl0` status via `ifconfig awdl0` (active flags, broadcast state).
  - Correlate with ping RTT jitter: when base ping is low (<30 ms) but exhibits periodic 200–600 ms spikes with zero overall packet loss, evaluate AWDL presence.
  - Implement rule `AWDL-1`:
    - Severity: `warn`
    - Impacts: video calls (degraded), gaming (degraded).
    - Fix target: `you`
    - Text: *"Periodic 200–500ms latency spikes detected matching Apple Wireless Direct Link (AirDrop/Sidecar) channel hopping. If experiencing video call freezes or audio stutter, set AirDrop to 'Receiving Off' in Control Center or disconnect Sidecar."*
- **Acceptance Criteria**:
  - `AWDL-1` rule defined in `lib/diagnosis.sh` and cataloged in `helpers/rules_catalog.py`.
  - Comprehensive unit test in `tests/test_diagnosis_wifi.bats`.
  - `docs/DIAGNOSIS-RULES.md` updated with technical background and remediation steps.
  - Passes `bats tests/` and `make test`.

---

### TASK-020: Unresponsive Primary DNS Resolver & Silent Fallback Delay (`D5`)
- **Area**: macOS CLI & GUI / DNS Health & Diagnosis
- **Status**: **Done**
- **Files to touch**:
  - `lib/dns.sh`
  - `lib/diagnosis.sh`
  - `docs/DIAGNOSIS-RULES.md`
  - `helpers/rules_catalog.py`
  - `tests/test_dns.bats`
- **Context**:
  macOS typically configures multiple DNS resolvers from DHCP or VPN profiles (e.g. Primary `192.168.1.1`, Secondary `8.8.8.8`). When the primary resolver becomes unresponsive or hangs, macOS waits for a 2-to-5 second timeout before silently failing over to the secondary resolver.
  From the user's perspective, web pages take several seconds just to begin loading ("hanging"), yet standard speed tests and superficial DNS checks report that the internet is "Working" because the secondary resolver eventually succeeded.
- **Architectural Design**:
  - In `lib/dns.sh`, test each configured system resolver independently (using `dig +time=1 +tries=1 @<resolver>`).
  - Measure per-resolver response status:
    - If Resolver #1 times out / fails, but Resolver #2 (or subsequent) responds promptly, emit rule `D5`:
      - Severity: `warn`
      - Impacts: ordinary browsing (degraded).
      - Fix target: `your_router` or `you`.
      - Text: *"Your primary DNS server (${PRIMARY_DNS}) is not responding. macOS is experiencing a multi-second delay waiting for timeouts before silently falling back to secondary DNS (${SECONDARY_DNS}). This causes web pages and links to hesitate for several seconds before opening. Update your DNS settings or restart your router."*
- **Acceptance Criteria**:
  - `lib/dns.sh` benchmarks individual resolvers when multiple exist.
  - Rule `D5` triggers in `lib/diagnosis.sh` when primary fails but secondary succeeds.
  - Cataloged in `helpers/rules_catalog.py` and documented in `docs/DIAGNOSIS-RULES.md`.
  - Unit tests in `tests/test_dns.bats` prove fallback detection with zero regressions.
  - Passes `bats tests/` and `make test`.

---

### TASK-021: Suboptimal Wi-Fi Band Trapping Detection (`W6`) (2.4 GHz vs 5/6 GHz)
- **Area**: macOS CLI & GUI / Wi-Fi Bands & Roaming
- **Status**: **Done**
- **Files to touch**:
  - `lib/wifi_common.sh`
  - `lib/constants.sh`
  - `lib/diagnosis.sh`
  - `docs/DIAGNOSIS-RULES.md`
  - `helpers/rules_catalog.py`
  - `tests/test_diagnosis_wifi.bats`
- **Context**:
  Modern routers broadcast a unified SSID across both 2.4 GHz and 5 GHz (or 6 GHz) bands. When MacBooks wake from sleep or connect from afar, they often grab the 2.4 GHz beacon because 2.4 GHz propagates further through walls. Even when the user walks right next to the router, macOS does not aggressively roam to 5 GHz if the 2.4 GHz connection is deemed "acceptable".
  The user remains trapped on 2.4 GHz, suffering from Bluetooth interference, microwave leakage, and speed caps of 40–70 Mbps when 400–1000 Mbps on 5/6 GHz is available right beside them.
- **Accuracy & Anti-False-Positive Guardrails**:
  To prevent nagging or wrongly prompting the user to toggle Wi-Fi when toggling wouldn't help:
  1. **Strict 5 GHz Signal Floor**: A 5 GHz or 6 GHz BSSID on the **same SSID** must be detected with strong signal: `RSSI >= -65 dBm` (well above Apple's -75 dBm roam threshold). If 5 GHz is weak (-78 dBm), macOS is *right* to stay on 2.4 GHz, so do not fire.
  2. **Substantial Delta**: The 5 GHz candidate must provide an advantageous link (e.g. within 12 dBm of the 2.4 GHz beacon).
  3. **Current Link Suboptimal**: The current 2.4 GHz link is experiencing congestion (`tx_rate < 100 Mbps` or channel width 20 MHz).
  4. **Informative / Low Severity**: Scored as `info` (or gentle `warn` only when active traffic speed is capped), so it never alarms the user as an "outage".
- **Architectural Design**:
  - `lib/wifi_common.sh` scans current SSID BSSIDs.
  - Detect if current connection is 2.4 GHz (channels 1–14).
  - Check if same SSID has a 5 GHz (channels 36–165) or 6 GHz BSSID with `RSSI >= -65 dBm`.
  - Emit rule `W6`:
    - Severity: `info` (or `warn` if `tx_rate <= 54 Mbps`).
    - Impacts: video calls (degraded), ordinary browsing (degraded).
    - Fix target: `you`
    - Text: *"Your Mac is connected to the 2.4 GHz band (${WIFI_CHAN}, ${WIFI_TX_RATE} Mbps) while a faster 5 GHz band on \"${WIFI_SSID}\" is available with strong signal (${CANDIDATE_5GHZ_RSSI} dBm). Toggling Wi-Fi off and back on will prompt your Mac to join 5 GHz."*
- **Acceptance Criteria**:
  - `W6` only fires when a 5 GHz BSSID on the same SSID has `RSSI >= -65 dBm`. Never fires if 5 GHz is weak or absent.
  - Cataloged in `helpers/rules_catalog.py` and documented in `docs/DIAGNOSIS-RULES.md`.
  - Comprehensive unit test in `tests/test_diagnosis_wifi.bats` covering edge cases (strong 5 GHz, weak 5 GHz, separate SSIDs).
  - Passes `bats tests/` and `make test`.

---

### TASK-022: Anti-False-Positive Guardrails for MTU, DHCP Leases, and Bufferbloat Severity (`M1`, `DH-1`, `B1`, `B2`)
- **Area**: CLI / Diagnosis & Precision Accuracy
- **Status**: **Done**
- **Files to touch**:
  - `lib/diagnosis.sh`
  - `lib/constants.sh`
  - `docs/DIAGNOSIS-RULES.md`
  - `helpers/rules_catalog.py`
  - `tests/test_diagnosis_mtu.bats`
  - `tests/test_diagnosis_dhcp.bats`
  - `tests/test_diagnosis_bufferbloat.bats`
- **Context**:
  An audit of the diagnosis engine revealed three rules with high false-positive rates that create phantom anxiety or mislead users into unnecessary actions:
  1. **Rule `M1` (Path MTU below 1500)**: Accuses active VPNs of "breaking websites" because the tunnel MTU is 1380–1420 bytes. Nearly all modern VPN protocols (WireGuard, Tailscale, Cloudflare WARP, IPsec) deliberately configure sub-1500 MTUs for encryption overhead, and TCP MSS clamping handles this transparently.
  2. **Rule `DH-1` (DHCP lease expires soon)**: Warns that users will "suddenly lose the network with no warning" if lease time remaining is < 60 minutes. Many legitimate public/hotel networks set 30-to-60 minute leases to recycle IPs, and macOS silently renews at 50% time (T1).
  3. **Rules `B1`/`B2` (Bufferbloat)**: Flags `critical` severity on high-speed fiber lines (>200 Mbps) during synthetic artificial speed test bursts, advising users to replace their routers or enable SQM even though the line never saturates in ordinary daily usage.
- **Architectural Guardrails**:
  - **`M1` VPN Awareness**:
    - When `VPN_ACTIVE=1` or `PATH_SPLIT_TUNNEL=1`, suppress `critical`/`warn` for standard VPN MTUs (1280–1499 bytes). Down-grade to an `info` note or silent no-op.
    - Only emit `warn` on VPNs if MTU < 1280 (violating standard IPv6 minimum transmission units).
    - On direct physical links (non-VPN), preserve existing MTU warning logic.
  - **`DH-1` T2 Phase Timing**:
    - Change threshold from `< 60 minutes` to `< 10 minutes` (or `< 15%` of total lease duration) to target actual renewal distress rather than normal short leases.
    - Wording softened: "Your DHCP lease has not renewed yet (expires in X minutes)..."
  - **`B1`/`B2` High-Bandwidth Proportional Severity**:
    - On connections with download/upload throughput > 150 Mbps, demote grade `D`/`F` bufferbloat from `critical` to `warn`.
    - Restrict `critical` bufferbloat to constrained connections (< 30 Mbps) where latency spikes genuinely ruin active video calls and voice chats.
- **Acceptance Criteria**:
  - Unit tests verify `M1` does not fire `critical` on a VPN with MTU 1380.
  - Unit tests verify `DH-1` does not fire on a 1-hour lease with 45 minutes remaining.
  - Unit tests verify `B1`/`B2` grade D on a 300 Mbps connection emits `warn` instead of `critical`.
  - Cataloged in `helpers/rules_catalog.py` and documented in `docs/DIAGNOSIS-RULES.md`.
  - All existing BATS tests continue to pass.

---

### TASK-023: Audit & Align Diagnosis Remediation with "Do No Harm" Standard (`D1`, `D3`, `V6-2`, `B1`)
- **Area**: CLI / Diagnosis & Safety
- **Status**: **Done**
- **Files to touch**:
  - `lib/diagnosis.sh`
  - `docs/DIAGNOSIS-RULES.md`
  - `helpers/rules_catalog.py`
  - `tests/test_diagnosis_dns.bats`
  - `tests/test_diagnosis_v6.bats`
  - `tests/test_diagnosis_bufferbloat.bats`
  - `tests/test_rules_catalog.bats`
- **Context**:
  A core design rule of `netdiag` is **"Do No Harm"**: A diagnostic tool must never recommend a permanent, hard-coded system configuration change to solve a transient network symptom.
  Currently, several rules advise non-technical users to take actions that create long-term foot-guns:
  1. **Rules `D1` and `D3` (DNS Flakiness / Latency)**: Currently advises: *"Switch your DNS to 1.1.1.1 or 8.8.8.8 in System Settings"*. Hardcoding public DNS on a MacBook's network adapter **permanently breaks future captive portal logins** in airports and hotels (which require local router DNS interception) and breaks internal domain resolution (`printer.local`, corporate split DNS).
  2. **Rule `V6-2` (Unresponsive IPv6 DNS)**: Currently advises: *"disable IPv6 in System Settings → Network"*. Disabling IPv6 leaves the Mac unable to connect to modern IPv6-only networks (common in European mobile networks and cellular hotspots).
  3. **Rule `B1` (Bufferbloat)**: Currently advises: *"replace the router with one that supports SQM"*. This induces unnecessary panic and expense; enabling QoS on consumer routers often disables hardware NAT offloading and slashes overall throughput.
- **Remediation Refinements ("Do No Harm")**:
  - **`D1` / `D3` Rewrite**:
    - Avoid telling users to permanently hardcode system DNS adapter settings.
    - Recommend non-destructive fixes:
      *"Restart your router to refresh its DNS cache. If on public/hotel Wi-Fi, toggle Wi-Fi off and on. For encrypted browsing without breaking local networks, consider an Encrypted DNS browser profile or app."*
  - **`V6-2` Rewrite**:
    - Never advise disabling IPv6 on the client Mac.
    - Recommend router-side remedies:
      *"Your router's IPv6 configuration appears stalled. Restart your router to re-acquire its IPv6 prefix lease. No settings changes are needed on your Mac."*
  - **`B1` Rewrite**:
    - Demote tone from hardware crisis to bandwidth hygiene:
      *"Your router delays latency-sensitive traffic during heavy simultaneous downloads or uploads. If video calls stutter while others are streaming, pause large background downloads during meetings, or configure QoS/SQM in your router's admin page."* (Removes "replace your router").
- **Acceptance Criteria**:
  - `lib/diagnosis.sh` strings updated to eliminate hardcoding DNS, disabling IPv6, or demanding router replacement.
  - `helpers/rules_catalog.py` fixes and remediation targets aligned.
  - Unit tests updated to match new copy and ensure no regressions.
  - Passes `bats tests/` and `make test`.

---

### TASK-024: Network Memory & Historical Performance Card for Known Networks
- **Area**: macOS GUI / History & Travel Log
- **Status**: **Done**
- **Files to touch**:
  - `gui/Sources/NetdiagGUI/Support/NetworkHistoryStore.swift` (new helper)
  - `gui/Sources/NetdiagGUI/Views/HistoryView.swift`
  - `gui/Sources/NetdiagGUI/Views/NetworkDetailCard.swift`
  - `helpers/history.py`
  - `gui/Tests/NetdiagGUITests/`
- **Context**:
  Travelers, remote workers, and consultants regularly move between multiple networks (home, office, local cafés, Airbnbs, client sites, co-working spaces). While `netdiag` captures journaled runs, the GUI currently presents history as a linear stream of raw runs rather than an organized "memory" of distinct networks.
  Users have no easy way to answer: *"How did this cafe's Wi-Fi perform last week?"* or *"Was my home connection faster before the ISP upgraded the firmware?"*
- **Architectural Design**:
  1. **Network Memory Store**:
     - Groups historical snapshots by stable network identity (`group_key`: gateway MAC when available, SSID fallback).
     - Computes aggregated summary metrics per network:
       - Typical latency & jitter
       - Tested download/upload speeds (peak vs typical)
       - Reliability grade (uptime %, disconnect count)
       - Last seen date
  2. **Past Networks View in GUI**:
     - Accessible from Dashboard or History tab.
     - Lists saved networks with quick rating chips (e.g. `[ HomeNet 5G: 450 Mbps, 12ms, 100% reliable ]`, `[ Airport Lounge: 15 Mbps, 85ms, 4% loss ]`).
     - Detail card shows historical comparison: "Today vs Typical for this network".
- **Acceptance Criteria**:
  - `NetworkHistoryStore` aggregates multiple runs per unique network.
  - GUI renders a clean list of past networks with performance ratings.
  - Privacy preserved: local on-device storage only (`~/.local/share/netdiag/` or App Support).
  - Passes all verify suites: `swift run -c debug NetdiagGUI --verify` and `make -C gui test`.

---

### TASK-025: Smart, Rate-Limited macOS System Notifications on Network Degradation
- **Area**: macOS GUI / System Alerts & Background Monitoring
- **Status**: **Done**
- **Files to touch**:
  - `gui/Sources/NetdiagGUI/Support/NotificationManager.swift` (new helper)
  - `gui/Sources/NetdiagGUI/Support/NetdiagCoordinator.swift`
  - `gui/Sources/NetdiagGUI/Views/SettingsView.swift`
- **Context**:
  The background monitor continuously tracks latency and packet loss. However, when a user is working full-screen in Xcode, Figma, Keynote, or on a browser, they cannot see the menu bar icon turn amber or red.
  Without notifications, they only discover network degradation after a web form submission fails or a stream buffers.
- **Architectural Design & Anti-Spam Guardrails**:
  1. **Native `UserNotifications` Framework**:
     - Emits standard macOS banner notifications for critical network state changes.
  2. **Strict Rate-Limiting & Suppression**:
     - **No spam**: Only notify on *state transitions* (e.g. Healthy ➔ Outage, or Healthy ➔ High Packet Loss > 10%).
     - Cooldown timer: Maximum 1 degradation notification per 30 minutes for the same ongoing fault.
     - Immediate notification when connection is fully restored: *"Wi-Fi Restored: Reconnected to HomeNet (14ms latency)"*.
  3. **User Preferences**:
     - Toggle in `SettingsView`: "Show system notifications for network drops and outages" (default: enabled).
     - Option to alert only on complete outages vs performance degradation.
- **Acceptance Criteria**:
  - `NotificationManager` manages `UNUserNotificationCenter` requests and authorizations.
  - Emits rate-limited notifications on genuine loss/outage transitions.
  - Setting toggle in GUI allows users to disable or customize notification sensitivity.
  - Verified in test suite.

---

### TASK-026: Live Jitter Tracking & Real-Time Connection Stability Badge in Monitor
- **Area**: macOS CLI & GUI / Telemetry & Quality
- **Status**: **Done**
- **Files to touch**:
  - `lib/monitor.sh`
  - `gui/Sources/NetdiagGUI/Models/MonitorSample.swift`
  - `gui/Sources/NetdiagGUI/Support/MonitorSeries.swift`
  - `gui/Sources/NetdiagGUI/Views/DropdownView.swift`
  - `gui/Sources/NetdiagGUI/VerifyMode.swift`
  - `gui/Tests/NetdiagGUITests/`
- **Context**:
  Users rely on their laptops for real-time, latency-sensitive activities (gaming, Zoom/Meet calls, SSH terminal sessions, live streaming). While average ping latency might look acceptable (e.g. 35 ms), sudden variance (**jitter**) or micro-bursts of loss cause audio clipping, frame skips, and input lag.
  Currently, `netdiag` monitors RTT and loss, but does not calculate instantaneous jitter in the live stream, nor does it translate raw latency numbers into an immediate, universal **Stability Index** that users can understand without needing network engineering expertise.
- **Architectural Design**:
  1. **Telemetry & Monotonic Jitter Calculation**:
     - `lib/monitor.sh` tracks successive valid RTT measurements and computes the moving jitter ($|RTT_t - RTT_{t-1}|$ smoothed via RFC 3550 exponential moving average).
     - Emits `jitter_ms` in the monitor JSON stream (or decoded from consecutive samples in Swift).
     - `MonitorSample.swift` decodes `jitter_ms: Double?`.
  2. **Real-Time Stability Index (Zero Clicks)**:
     - In the unified telemetry card (`DropdownView`), alongside ping and loss, display a clean activity readiness badge:
       - 🟢 **Optimal**: RTT < 35ms, Jitter < 8ms, Loss 0% (Flawless for competitive gaming, live streaming, 4K calls).
       - 🟡 **Variable / High Jitter**: RTT 35–90ms or Jitter > 20ms (Acceptable for browsing/streaming; occasional micro-stutter in live calls/games).
       - 🔴 **Unstable**: Packet loss > 2% or Jitter > 50ms or RTT > 150ms (Expect dropouts, buffering, and call audio glitching).
  3. **Zero Extra Overhead**:
     - Derived entirely from the existing lightweight 1-packet-per-second monitor probe. No extra packets sent, zero battery impact, no buttons required.
- **Acceptance Criteria**:
  - `MonitorSample` decodes `jitter_ms` and `MonitorSeries` calculates moving jitter.
  - `DropdownView` renders the real-time stability badge with accessible status glyphs.
  - Fully verified in `swift run -c debug NetdiagGUI --verify` and test suite.

---

### TASK-027: Remediation Feedback & Resolution Banner (Closed-Loop Confirmation)
- **Area**: macOS GUI / UX & User Delight
- **Status**: **Done**
- **Files to touch**:
  - `gui/Sources/NetdiagGUI/Support/StageResolver.swift`
  - `gui/Sources/NetdiagGUI/Services/NetdiagCoordinator.swift`
  - `gui/Sources/NetdiagGUI/Views/DropdownView.swift`
  - `gui/Sources/NetdiagGUI/VerifyMode.swift`
  - `gui/Tests/NetdiagGUITests/`
- **Context**:
  When `netdiag` advises a user to take action (e.g. *"Your Wi-Fi signal is weak, move closer"* or *"Connected to 2.4 GHz band, toggle Wi-Fi to join 5 GHz"* or captive portal authentication), the user takes the physical action.
  Currently, once the condition clears, the dropdown simply reverts to its default idle state (*"All good — watching on HomeNet"*).
  The user is left with a broken feedback loop: they are unsure whether what they just did actually succeeded, or if the alert just timed out.
- **Architectural Design**:
  1. **Resolution Event Tracking in `NetdiagCoordinator`**:
     - Maintain an ephemeral `recentResolutions: [ResolutionEvent]` tracking active alerts that successfully transition from non-healthy (warning/critical) back to healthy within the session.
     - Store pre-resolution and post-resolution metrics (e.g. band switched from `2.4 GHz` to `5 GHz`, RSSI jumped from `-78 dBm` to `-45 dBm`, packet loss dropped from `15%` to `0%`).
  2. **Resolution Banner in Stage Card**:
     - When a resolution event occurs within the last 60 seconds, `StageResolver` presents a temporary, uplifting **Resolution Stage** (`.resolved(summary)`):
       - 🟢 *“✓ Wi-Fi Improved: Moved from 2.4 GHz to 5 GHz (Ch 52). Negotiated rate increased from 54 Mbps to 650 Mbps.”*
       - 🟢 *“✓ Signal Restored: Wi-Fi signal jumped from -78 dBm to -46 dBm (Excellent).”*
       - 🟢 *“✓ Network Stabilized: Packet loss resolved (0% loss, 18ms ping).”*
       - 🟢 *“✓ Online: Captive portal authentication succeeded. Internet access active.”*
     - Fades smoothly back to normal idle `.watching` after 45 seconds or on dismiss.
- **Acceptance Criteria**:
  - `StageResolver` resolves `.resolved` state when an alert clears and presents actionable metric improvements.
  - Off-screen snapshot and `--verify` tests prove `.resolved` rendering contract.
  - Passes all verification suites: `swift run -c debug NetdiagGUI --verify` and `make -C gui test`.

---

### TASK-035: Dashboard Usability & Visual Clarity Polish (Home, Live, Activity, Trends, Networks)
- **Area**: macOS GUI / Dashboard & Usability
- **Track**: Track F (UX & Polish)
- **Status**: **Done**
- **Files to touch**:
  - `gui/Sources/NetdiagGUI/Views/HomeView.swift`
  - `gui/Sources/NetdiagGUI/Views/LiveView.swift`
  - `gui/Sources/NetdiagGUI/Views/ActivityView.swift`
  - `gui/Sources/NetdiagGUI/Views/TrendsView.swift`
  - `gui/Sources/NetdiagGUI/Views/NetworksView.swift`
  - `gui/Sources/NetdiagGUI/Views/NetworkDetailCard.swift`
  - `gui/Sources/NetdiagGUI/Views/DropdownComponents.swift`
- **Context**:
  While `netdiag` captures deep, high-precision network telemetry and diagnosis rules, non-expert users find the dashboard tabs dense, text-heavy, or graph-centric without immediate plain-English answers to: *"Is my connection working well right now?"*
  Each of the 5 tabs in `MainWindow` (Home, Live, Activity, Trends, Networks) needs a focused usability and visual hierarchy overhaul to maximize glanceability, clarity, and ease of understanding.
- **Architectural Design**:
  1. **Home Tab ("Status at a Glance")**:
     - Introduces a friendly, welcoming hero status card at the top with plain-English health verdict, friendly glyph, and 4 glanceable instrument tiles (Internet Latency, Connection Stability & Jitter, Link Loss %, Current Wi-Fi/Ethernet link quality).
     - Elevates the full-check action and clean separation between live telemetry and past check reports.
  2. **Live Tab ("Real-Time Live Monitor")**:
     - Introduces a 4-metric live gauge bar (Router Ping, Internet Ping, Jitter & Stability badge, Packet Loss) above the 3 charts for instant comprehension without axis reading.
     - Adds clear visual guidance explaining what normal vs problematic graphs look like.
  3. **Activity Tab ("Actionable History & Reassurance")**:
     - Introduces an activity summary banner (incident counts vs clean periods).
     - Polishes `ActivityRow` with clear severity pill tags, duration badges, and friendly iconography.
     - Reassuring empty-state presentation when no disruptions occurred.
  4. **Trends Tab ("Historical Baseline Digest")**:
     - Highlights baseline performance summary cards (typical download/upload, typical latency, reliability score).
     - Intuitive time-window segmented pills (`24h`, `7d`, `30d`, `All`) and friendly metric names.
  5. **Networks Tab ("Active Network Spotlight")**:
     - Prominently spotlights the currently active network at the top of the sidebar under "Active Connection".
     - Streamlines the detail pane with enhanced metrics grid and clear "Today vs Typical" comparison chips.
- **Acceptance Criteria**:
  - All 5 tabs provide immediate glanceability and plain-English clarity.
  - No regression in existing 49 unit tests or `--verify` checks.
  - Clean SwiftUI implementation complying with `Theme.swift`.

---

### TASK-028: "Meeting Shield" — Live Call & Video Conferencing Quality Guardian (Zoom / Meet / Teams)
- **Area**: macOS GUI / Call Quality & Telemetry
- **Track**: Track F (Live Work & Quality)
- **Status**: Low Priority (Future)
- **Files to touch**:
  - `gui/Sources/NetdiagGUI/Services/CallGuardian.swift`
  - `gui/Sources/NetdiagGUI/Services/NetdiagCoordinator.swift`
  - `gui/Sources/NetdiagGUI/Views/DropdownView.swift`
  - `gui/Sources/NetdiagGUI/Support/StageResolver.swift`
  - `gui/Tests/NetdiagGUITests/CallGuardianTests.swift`
- **Context**:
  Nothing undermines professional confidence like dropping out of a client pitch, job interview, or team sync with robotic audio, freezing video, or sudden disconnection.
  While macOS indicates when the microphone or camera is active, it does nothing to prevent or diagnose network glitches while they happen.
  Users currently only find out their Wi-Fi is failing when meeting attendees say *"You're breaking up"*.
- **Architectural Design**:
  1. **Passive Meeting Detection**:
     - `CallGuardian` observes active audio input streams via `AudioHardware` CoreAudio property listeners (`kAudioHardwarePropertyDefaultInputDevice` run state) and active conferencing processes (`zoom.us`, `Google Chrome` with WebRTC active, `Microsoft Teams`, `FaceTime`, `Slack`).
     - Flags `isMeetingActive: Bool`.
  2. **High-Sensitivity Meeting Mode**:
     - When a meeting is active, monitor adapts to a non-saturating, high-sensitivity cadence (e.g. 1 probe/sec with fast jitter tracking).
     - If packet loss > 1.5% or jitter > 25ms sustained for 3 seconds, triggers a non-disruptive, floating HUD alert:
       *“⚠️ Meeting Shield: Wi-Fi jitter rising (32ms). Moving 5 ft closer or pausing downloads will prevent audio clipping.”*
  3. **Post-Meeting Debrief**:
     - When the meeting ends, synthesizes an uplifting session debrief card in the dropdown:
       *“✓ 42-min meeting completed with 99.4% stability (1 minor jitter spike at 14:12).”*
- **Acceptance Criteria**:
  - `CallGuardian` detects call state without requesting sensitive accessibility permissions.
  - Generates meeting health telemetry metrics and post-call debrief.
  - Tested in unit tests and verify mode.

---

### TASK-029: "Find the Best Desk" — Walkaround Wi-Fi Signal & Roaming Surveyor
- **Area**: macOS GUI / Travel & Wi-Fi Heatmap
- **Track**: Track F (Live Work & Quality)
- **Status**: Low Priority (Future)
- **Files to touch**:
  - `gui/Sources/NetdiagGUI/Services/SignalSurveyor.swift`
  - `gui/Sources/NetdiagGUI/Views/SurveyorView.swift`
  - `gui/Sources/NetdiagGUI/Services/NetdiagCoordinator.swift`
  - `gui/Tests/NetdiagGUITests/SignalSurveyorTests.swift`
- **Context**:
  When digital nomads, travelers, or hybrid workers arrive at an Airbnb, coworking space, cafe, or hotel, the first thing they do is pick where to sit.
  Guessing signal strength from menu-bar Wi-Fi fan icons is notoriously inaccurate because macOS does not refresh RSSI/SNR in real time while walking, nor does it tell the user which room has low latency.
- **Architectural Design**:
  1. **60-Second Real-Time Survey Mode**:
     - Accessible via "Survey Room / Find Best Spot" quick action.
     - Samples Wi-Fi RSSI, SNR, noise, channel, and gateway RTT at 500ms intervals via CoreWLAN.
     - Optional pleasant, low-latency audio pitch feedback (higher pitch = stronger signal / lower latency, like a sonar locator) so users can walk around with the laptop closed or screen tilted.
  2. **Location Tagging & Benchmark Comparison**:
     - Users can click "Tag This Spot" (e.g. *"Balcony"*, *"Living Room Desk"*, *"Bedroom Corner"*).
     - Renders a comparison table ranking spots by signal strength, throughput potential, and ping stability.
- **Acceptance Criteria**:
  - `SignalSurveyor` provides real-time signal sampling and spot benchmarking.
  - Clean SwiftUI survey view with live needle gauge and spot ranking.
  - Fully tested with unit test coverage.

---

### TASK-030: Passive Local LAN Topology & Friendly Device Discovery (Bonjour / mDNS)
- **Area**: Core CLI & GUI / Subnet & Local Devices
- **Track**: Track D (Subnet & LAN)
- **Status**: Low Priority (Future)
- **Files to touch**:
  - `lib/lan.sh`
  - `helpers/lan_inventory.py`
  - `gui/Sources/NetdiagGUI/Models/LANDevice.swift`
  - `gui/Sources/NetdiagGUI/Views/NetworksView.swift`
  - `tests/test_lan.bats`
- **Context**:
  `TASK-005` introduced subnet crowding telemetry (`LAN-1`) using ARP cache size. However, users seeing "28 devices on this subnet" cannot tell *what* those devices are, leading to anxiety about rogue devices, network eavesdropping, or unauthorized bandwidth hogs.
- **Architectural Design**:
  1. **Passive Zero-Traffic Discovery**:
     - Uses `dns-sd` / Bonjour service browsing (`_http._tcp`, `_airplay._tcp`, `_googlecast._tcp`, `_smb._tcp`, `_printer._tcp`) to passively collect device hostnames and friendly model names without sending active port probes.
     - Matches MAC OUIs (via `oui.txt` database) to manufacturers (Apple, Sonos, Samsung, Philips Hue, Sony, Espressif).
  2. **Friendly Device Roster in GUI**:
     - In `NetworksView`, expands the subnet section into a clean, categorized device roster:
       - 📱 Personal Devices (MacBook, iPhone, iPad)
       - 🔊 Entertainment & Audio (Sonos, Apple TV, Roku)
       - 💡 Smart Home & IoT (Hue Bridge, Smart Plugs)
       - 🖨️ Office Equipment (Printers, NAS)
     - Highlights duplicate IP address collisions (`ARP-1`) or unfamiliar device surges.
- **Acceptance Criteria**:
  - Helper parses Bonjour services and maps IP/MAC addresses to friendly device types.
  - Displays structured device inventory in `NetworksView`.
  - Backed by bats tests and Swift unit tests.

---

### TASK-031: Upstream ISP Outage Corroborator & 1-Click Support Ticket Dispatch
- **Area**: Core CLI & GUI / ISP Attribution & Support
- **Track**: Track A (Action Layer)
- **Status**: Low Priority (Future)
- **Files to touch**:
  - `lib/diagnosis.sh`
  - `gui/Sources/NetdiagGUI/Support/SupportSummary.swift`
  - `gui/Sources/NetdiagGUI/Views/DropdownView.swift`
  - `tests/test_diagnosis_accuracy.bats`
  - `gui/Tests/NetdiagGUITests/SupportSummaryTests.swift`
- **Context**:
  When the internet goes down, users struggle to determine whether the issue is inside their home (bad router/cable) or outside (ISP fiber cut / neighborhood node failure). When contacting an ISP support rep, Airbnb host, or building manager, users get stuck in canned troubleshooting loops (*"Did you try rebooting your Mac?"*).
- **Architectural Design**:
  1. **Upstream Multi-Target Hop Dissection**:
     - When internet loss occurs (`P1`/`L1`), ping gateway, first upstream ISP hop (from traceroute / DHCP gateway), and 3 geographically diverse public targets (Cloudflare 1.1.1.1, Google 8.8.8.8, Quad9 9.9.9.9).
     - Categorizes failure boundary:
       - **Local Link Failure**: Wi-Fi / Ethernet dropped or router unreachable.
       - **WAN / Modem Line Down**: Router reachable (0% loss, <2ms RTT), but default WAN gateway is silent.
       - **Transit / Peering Blackhole**: ISP WAN reachable, but core peering exchanges dropping packets.
  2. **1-Click Support Dispatch Generator**:
     - Enhances `SupportSummary` with a dedicated "Copy ISP Support Ticket / SMS" button producing an indisputable technical summary:
       ```
       Connection Outage Report - Comcast/Xfinity
       Timestamp: Sep 12, 2026 20:45 EDT
       Local Router (192.168.1.1): Reachable (0% packet loss, 1.4 ms ping)
       WAN Gateway (68.86.92.1): Silent (100% packet loss since 20:38 EDT)
       Conclusion: Issue is localized to the external WAN connection / modem line.
       ```
- **Acceptance Criteria**:
  - Diagnosis distinguishes between local gateway failure, modem WAN drop, and ISP peering outage.
  - Dropdown view provides 1-click formatted support ticket snippet ready for copy/pasting.
  - Verified in bats and Swift unit tests.

---

### TASK-032: Native macOS Desktop & Notification Center Widgets via WidgetKit
- **Area**: macOS Platform Integration / Widgets
- **Track**: Track E (Architecture & Platform)
- **Status**: Low Priority (Future)
- **Files to touch**:
  - `gui/Package.swift`
  - `gui/Sources/NetdiagWidget/`
  - `gui/Sources/NetdiagGUI/Support/AppGroupStore.swift`
  - `gui/Sources/NetdiagGUI/Services/NetdiagCoordinator.swift`
- **Context**:
  On macOS Sonoma and Sequoia, interactive desktop widgets provide ambient, zero-click situational awareness. Users working on full-screen displays or multi-monitor setups benefit from seeing network health without interacting with the menu bar.
- **Architectural Design**:
  1. **Shared App Group Storage (`AppGroupStore`)**:
     - `NetdiagCoordinator` writes an atomic `widget_state.json` snapshot to the shared App Group container on each cadence update.
  2. **WidgetKit Extension**:
     - **Small Widget**: Live status dot (`●`), network name, current ping, and stability badge.
     - **Medium Widget**: Real-time 6-hour latency timeline sparkline, current download/upload speeds, and today vs typical performance chips.
     - Supports macOS light and dark desktop appearances with vibrant tinted styles.
- **Acceptance Criteria**:
  - `WidgetKit` extension renders small and medium desktop widgets.
  - State updates dynamically from background monitor snapshots without launching the main window.

---

### TASK-033: Apple Shortcuts Integration & App Intents Automation
- **Area**: macOS Platform Integration / Automation
- **Track**: Track E (Architecture & Platform)
- **Status**: Low Priority (Future)
- **Files to touch**:
  - `gui/Sources/NetdiagGUI/Intents/NetdiagIntents.swift`
  - `gui/Sources/NetdiagGUI/Services/NetdiagCoordinator.swift`
  - `gui/Tests/NetdiagGUITests/AppIntentsTests.swift`
- **Context**:
  Power users, sysadmins, and remote workers use Apple Shortcuts to automate workflows (e.g. morning routine, arriving at work, switching VPNs, testing internet speed before starting a stream).
- **Architectural Design**:
  1. **Native App Intents**:
     - `GetNetworkHealthIntent`: Returns current network status, latency, jitter, and reliability rating.
     - `RunDiagnosticCheckIntent`: Initiates a quick or full diagnostic scan and returns firing rules.
     - `RunSpeedTestIntent`: Runs an on-demand speed test and outputs Mbps figures.
     - `GetNetworkMemoryIntent`: Retrieves historical performance baseline for current network.
  2. **Shortcuts Action Library**:
     - Exposes actions directly in the macOS Shortcuts app with formatted parameters and Siri support.
- **Acceptance Criteria**:
  - Declares App Intents complying with `AppIntent` protocol.
  - Supports automation queries from Shortcuts.app and Terminal (`shortcuts run`).
  - Unit tested for input/output correctness.

---

### TASK-034: Gaming & Low-Latency Stream Optimizer (Interactive CAKE / SQM Router Guide)
- **Area**: Diagnosis & Remediation / Bufferbloat
- **Track**: Track A (Action Layer)
- **Status**: Low Priority (Future)
- **Files to touch**:
  - `gui/Sources/NetdiagGUI/Views/BufferbloatGuideView.swift`
  - `gui/Sources/NetdiagGUI/Views/DropdownView.swift`
  - `helpers/rules_catalog.py`
  - `docs/DIAGNOSIS-RULES.md`
- **Context**:
  When bufferbloat receives a poor grade (`D` or `F`, rules `B1`/`B2`), competitive gamers and live streamers experience catastrophic latency spikes (jumping from 20ms to 400ms) whenever someone on the LAN starts a video stream or downloads a game update.
  While netdiag diagnoses bufferbloat accurately, users often don't know how to fix it on their specific router hardware.
- **Architectural Design**:
  1. **Router Manufacturer Detection & Custom Guides**:
     - Identifies gateway hardware via MAC OUI and default router admin interface headers (e.g. Ubiquiti UniFi, Eero, ASUS Asuswrt-Merlin, Netgear, TP-Link, OpenWrt/pfSense).
     - Presents brand-specific step-by-step interactive instructions for configuring Smart Queue Management (SQM) or CAKE (Common Applications Kept Enhanced).
  2. **Interactive Live Bufferbloat Gauge**:
     - Visualizes bufferbloat latency deltas during upload vs download load with a target line showing the SQM improvement threshold (<10ms delta).
- **Acceptance Criteria**:
  - Interactive modal guide provides brand-tailored SQM configuration instructions.
  - Clear, accessible remediation advice without technical jargon.
  - Verified in unit tests.

