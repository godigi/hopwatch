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
| [TASK-022](#task-022-anti-false-positive-guardrails-for-mtu-dhcp-leases-and-bufferbloat-severity-m1-dh-1-b1-b2) | Anti-False-Positive Guardrails for MTU, DHCP Leases & Bufferbloat Severity (`M1`, `DH-1`, `B1`, `B2`) | Diagnosis / Accuracy | Ready | M |
| [TASK-023](#task-023-audit--align-diagnosis-remediation-with-do-no-harm-standard-d1-d3-v6-2-b1) | Audit & Align Diagnosis Remediation with "Do No Harm" Standard (`D1`, `D3`, `V6-2`, `B1`) | Diagnosis / Safety | Ready | S |
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
- **Status**: Ready
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
- **Status**: Ready
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
