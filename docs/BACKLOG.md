# netdiag Backlog & Engineering Roadmap

This backlog tracks prioritized improvements across the CLI, helpers, and macOS GUI.
Tasks are structured so that an autonomous or background agent session (e.g. running `/goal`) can pick up the next ready task, implement it against the acceptance criteria, run the test suites, and mark it complete.

---

## Task Index

| ID | Title | Area | Status | Est. Size |
|---|---|---|---|---|
| [TASK-001](#task-001-document-unreleased-gui-episode-folding--monitor-started-parity-in-changelogmd) | Document unreleased GUI episode folding & monitor-started parity in CHANGELOG.md | Docs / Quality | **Done** | XS |
| [TASK-002](#task-002-decode-gap_s-in-monitorsampleswift-and-use-in-monitorseriesswift) | Decode `gap_s` in `MonitorSample.swift` and use in `MonitorSeries.swift` | GUI / Monitor | **Done** | S |
| [TASK-003](#task-003-unify-event-journaling-between-gui-and-cli-eventsjsonl) | Unify event journaling between GUI and CLI (`events.jsonl`) | Architecture / Parity | **Done** | M |
| [TASK-004](#task-004-add-launch-at-login-support-to-gui-via-smappservice) | Add "Launch at Login" support to GUI via `SMAppService` | macOS GUI | **Done** | S |
| [TASK-005](#task-005-device-inventory--surge-detection-lan-1) | Device inventory & surge detection (`LAN-1`) | CLI / Diagnosis | **Done** | M |
| [TASK-006](#task-006-icloud-private-relay--profile-encrypted-dns-qualifiers-pr-1-edns-1) | iCloud Private Relay & Profile Encrypted DNS qualifiers (`PR-1`, `EDNS-1`) | CLI / Diagnosis | **Backlog** | M |
| [TASK-007](#task-007-gui-distribution-dmg-packaging-and-homebrew-formula) | GUI distribution DMG packaging and Homebrew formula | Build / Release | **Backlog** | M |

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

### TASK-003: Unify event journaling between GUI and CLI (`events.jsonl`)
- **Area**: Core Architecture / Availability
- **Status**: **Done**
- **Files to touch**:
  - `gui/Sources/NetdiagGUI/Services/MonitorStream.swift`
  - `lib/availability.sh`
  - `docs/ARCHITECTURE.md`
- **Context**:
  `lib/availability.sh` skips with `no event journal (netdiag --install-recorder)` if `~/net-diag/events.jsonl` does not exist. The GUI runs a monitor continuously, but writes only to its internal `events.json`. Spawning the GUI's monitor with `--journal "$HOME/net-diag/events.jsonl"` gives the system a shared, single source of truth for network transitions, enabling `AV-1`/`AV-2` availability rules during GUI-triggered full checks.
- **Acceptance Criteria**:
  - The GUI monitor passes `--journal <path>` safely.
  - Running a full check from the GUI (or CLI while GUI is running) evaluates availability (`AV-1`/`AV-2`) against real journal history.
  - `bats tests/test_availability.bats` and `bats tests/test_events.bats` pass.

---

### TASK-004: Add "Launch at Login" support to GUI via `SMAppService`
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
  - Handle permission errors or unprivileged states gracefully.
  - Clean verification in `--verify` harness.

---

### TASK-005: Device inventory & surge detection (`LAN-1`)
- **Area**: CLI / Rules Engine
- **Status**: **Done**
- **Files to touch**:
  - `lib/arp.sh`
  - `lib/diagnosis.sh`
  - `lib/thresholds.sh`
  - `helpers/rules_catalog.py`
  - `tests/test_parse.bats`
- **Context**:
  ARP cache parsing currently discards the list of active hosts on the subnet after checking for duplicate IPs. Tracking active device count per network explains sudden bufferbloat/throughput drops caused by local LAN contention.
- **Acceptance Criteria**:
  - `LAN-1` rule defined in `rules_catalog.py` and `thresholds.sh`.
  - Tests verify counting, formatting, and threshold triggering.

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
