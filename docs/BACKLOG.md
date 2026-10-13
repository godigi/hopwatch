# Hopwatch Roadmap

Ideas that are specified but not built. Everything shipped is in [CHANGELOG.md](../CHANGELOG.md)
and [CHANGELOG-archive.md](CHANGELOG-archive.md); this file keeps only what is still open, all of it
low priority.

## Index

| ID | Title | Track | Status | Est. Size |
|---|---|---|---|---|
| [TASK-028](#task-028-meeting-shield--live-call--video-conferencing-quality-guardian-zoom--meet--teams) | "Meeting Shield" — Live Call & Video Conferencing Quality Guardian | **Track F** (Live Work) | Low Priority | M |
| [TASK-029](#task-029-find-the-best-desk--walkaround-wi-fi-signal--roaming-surveyor) | "Find the Best Desk" — Walkaround Wi-Fi Signal & Roaming Surveyor | **Track F** (Live Work) | Low Priority | M |
| [TASK-030](#task-030-passive-local-lan-topology--friendly-device-discovery-bonjour--mdns) | Passive Local LAN Topology & Friendly Device Discovery (Bonjour / mDNS) | **Track D** (Subnet & LAN) | Low Priority | M |
| [TASK-031](#task-031-upstream-isp-outage-corroborator--1-click-support-ticket-dispatch) | Upstream ISP Outage Corroborator & 1-Click Support Ticket Dispatch | **Track A** (Action Layer) | Low Priority | S |
| [TASK-032](#task-032-native-macos-desktop--notification-center-widgets-via-widgetkit) | Native macOS Desktop & Notification Center Widgets via `WidgetKit` | **Track E** (Architecture) | Low Priority | M |
| [TASK-033](#task-033-apple-shortcuts-integration--app-intents-automation) | Apple Shortcuts Integration & App Intents Automation | **Track E** (Architecture) | Low Priority | S |
| [TASK-034](#task-034-gaming--low-latency-stream-optimizer-interactive-cake--sqm-router-guide) | Gaming & Low-Latency Stream Optimizer (Interactive CAKE / SQM Router Guide) | Diagnosis / Remediation | Low Priority | S |

---

## Specifications

### TASK-028: "Meeting Shield" — Live Call & Video Conferencing Quality Guardian (Zoom / Meet / Teams)
- **Area**: macOS GUI / Call Quality & Telemetry
- **Track**: Track F (Live Work & Quality)
- **Status**: Low Priority (Future)
- **Files to touch**:
  - `gui/Sources/HopwatchGUI/Services/CallGuardian.swift`
  - `gui/Sources/HopwatchGUI/Services/HopwatchCoordinator.swift`
  - `gui/Sources/HopwatchGUI/Views/DropdownView.swift`
  - `gui/Sources/HopwatchGUI/Support/StageResolver.swift`
  - `gui/Tests/HopwatchGUITests/CallGuardianTests.swift`
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
  - `gui/Sources/HopwatchGUI/Services/SignalSurveyor.swift`
  - `gui/Sources/HopwatchGUI/Views/SurveyorView.swift`
  - `gui/Sources/HopwatchGUI/Services/HopwatchCoordinator.swift`
  - `gui/Tests/HopwatchGUITests/SignalSurveyorTests.swift`
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
  - `gui/Sources/HopwatchGUI/Models/LANDevice.swift`
  - `gui/Sources/HopwatchGUI/Views/NetworksView.swift`
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
  - `gui/Sources/HopwatchGUI/Support/SupportSummary.swift`
  - `gui/Sources/HopwatchGUI/Views/DropdownView.swift`
  - `tests/test_diagnosis_accuracy.bats`
  - `gui/Tests/HopwatchGUITests/SupportSummaryTests.swift`
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
  - `gui/Sources/HopwatchWidget/`
  - `gui/Sources/HopwatchGUI/Support/AppGroupStore.swift`
  - `gui/Sources/HopwatchGUI/Services/HopwatchCoordinator.swift`
- **Context**:
  On macOS Sonoma and Sequoia, interactive desktop widgets provide ambient, zero-click situational awareness. Users working on full-screen displays or multi-monitor setups benefit from seeing network health without interacting with the menu bar.
- **Architectural Design**:
  1. **Shared App Group Storage (`AppGroupStore`)**:
     - `HopwatchCoordinator` writes an atomic `widget_state.json` snapshot to the shared App Group container on each cadence update.
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
  - `gui/Sources/HopwatchGUI/Intents/HopwatchIntents.swift`
  - `gui/Sources/HopwatchGUI/Services/HopwatchCoordinator.swift`
  - `gui/Tests/HopwatchGUITests/AppIntentsTests.swift`
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
  - `gui/Sources/HopwatchGUI/Views/BufferbloatGuideView.swift`
  - `gui/Sources/HopwatchGUI/Views/DropdownView.swift`
  - `helpers/rules_catalog.py`
  - `docs/DIAGNOSIS-RULES.md`
- **Context**:
  When bufferbloat receives a poor grade (`D` or `F`, rules `B1`/`B2`), competitive gamers and live streamers experience catastrophic latency spikes (jumping from 20ms to 400ms) whenever someone on the LAN starts a video stream or downloads a game update.
  While hopwatch diagnoses bufferbloat accurately, users often don't know how to fix it on their specific router hardware.
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
