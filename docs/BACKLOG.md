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
| [TASK-006](#task-006-icloud-private-relay--profile-encrypted-dns-qualifiers-pr-1-edns-1) | iCloud Private Relay & Profile Encrypted DNS qualifiers (`PR-1`, `EDNS-1`) | Backlog | **Backlog** | M |
| [TASK-007](#task-007-gui-distribution-dmg-packaging-and-homebrew-formula) | GUI distribution DMG packaging and Homebrew formula | Backlog | **Backlog** | M |

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
- **Status**: **Backlog**
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
- **Status**: **Backlog**
- **Files to touch**:
  - `Makefile`
  - `gui/Makefile`
  - `.github/workflows/release.yml`
- **Context**:
  Allow users to install via `brew install --cask netdiag` or download a signed/stapled `.dmg` artifact from GitHub Releases.
