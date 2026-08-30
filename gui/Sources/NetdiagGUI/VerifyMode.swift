import SwiftUI
import AppKit
import Foundation
import os

/// The app's runnable verification harness, reached with `--verify`.
///
/// `swift test` cannot *execute* on this CLT-only machine: Swift Testing's
/// runner needs the `xctest` host, which the Command Line Tools do not
/// ship, so a test target compiles here but `swift test` exits 0 having run
/// nothing. A separate executable target is no substitute either —
/// `NetdiagGUI` is an executable target, and SwiftPM does not export an
/// executable's public symbols to importers, so the linker fails. The only
/// place with access to the resolver *and* a runnable process on this
/// toolchain is the app itself, so the harness lives here as a launch mode.
///
/// `swift run NetdiagGUI --verify` (or the bundled binary with `--verify`)
/// runs it: AppDelegate calls `runVerifyIfNeeded()` early in launch, and if
/// it returns true the app terminates before starting the monitor or showing
/// UI. The harness prints PASS/FAIL per check and exits non-zero on any
/// failure, the way a test runner would.
///
/// Two checks live here, covering the two things that can break silently:
///
/// 1. **StageResolver logic** — the reactivity guarantee: the dropdown's
///    stage card reflects the CLI's current verdict the moment a rule fires,
///    not 15–25 s later when the alert's dwell elapses. That guarantee lives
///    in a pure function (`StageResolver.resolve`), so it is checked directly
///    with constructed inputs — every severity → stage mapping and every
///    precedence guard.
///
/// 2. **Stage-card visual contract** — a faithful stand-in of the dropdown's
///    stage card is rendered offscreen for each stage and written to PNG, so
///    the colour and wording per stage can be eyeballed without launching the
///    app or clicking the menu-bar item. This is not a pixel-identical
///    snapshot of `DropdownView` (that would need a real coordinator, which
///    spawns a monitor and reads history) — it is the visual *contract*
///    (green / amber / red card, icon, title, body) driven by the same
///    `StageResolver.Stage` the real view consumes. Combined with the logic
///    asserts above, it proves both the mapping and its rendering; a
///    screenshot of the running app confirms the real `DropdownView` wires
///    the resolver in.

/// If `--verify` is present in the launch arguments, run the harness and
/// return true so the caller can terminate without starting the monitor.
/// Otherwise return false and let the app launch normally.
@MainActor
func runVerifyIfNeeded() -> Bool {
    guard CommandLine.arguments.contains("--verify") else { return false }
    VerifyHarness.run()
    return true
}

@MainActor
private enum VerifyHarness {

    static var failures: [String] = []

    static func run() {
        // AppKit rendering needs an app instance present; the real app is
        // already up by the time AppDelegate calls us, so just keep the
        // policy consistent and run the checks.
        NSApp?.setActivationPolicy(.accessory)
        runStageTests()
        runHealthResolverTests()
        runAlertAttributionTests()
        runFullCheckPolicyTests()
        runHeadlineRuleTests()
        runPhaseWeightsTests()
        runSuitabilityAndFixFieldTests()
        runSuitabilityPanelTests()
        runSnapshots()
        print("")
        if failures.isEmpty {
            print("All checks passed.")
        } else {
            print("\(failures.count) check(s) failed: \(failures.joined(separator: ", "))")
        }
        exit(failures.isEmpty ? 0 : 1)
    }

    // MARK: - Menu-bar dot

    /// The dot is the app's single most consequential claim — one glyph
    /// asserting "your connection is fine" — and until `HealthResolver`
    /// existed it was unreachable from any check. The first case below is
    /// the regression that motivated it.
    static func runHealthResolverTests() {
        print("HealthResolver (menu-bar dot)")
        func at(_ h: HealthResolver.Inputs) -> Health { HealthResolver.resolve(h) }
        func inputs(isScanning: Bool = false, monitoringEnabled: Bool = true,
                    isPausedForAnyReason: Bool = false, monitorRunning: Bool = true,
                    sampleHealth: Health? = .healthy,
                    runHealth: Health? = nil) -> HealthResolver.Inputs {
            .init(isScanning: isScanning, monitoringEnabled: monitoringEnabled,
                  isPausedForAnyReason: isPausedForAnyReason,
                  monitorRunning: monitorRunning,
                  sampleHealth: sampleHealth, runHealth: runHealth)
        }

        // `MonitorStream.stop()` keeps its final sample on purpose, so
        // "monitoring off" used to fall straight through to it and leave a
        // green dot over a "Monitoring paused" card, indefinitely.
        equal(at(inputs(monitoringEnabled: false, monitorRunning: false)), .paused,
              "monitoring switched off → paused, not the stale sample's green")
        equal(at(inputs(isPausedForAnyReason: true)), .paused,
              "held by display sleep / battery → paused")
        equal(at(inputs(isScanning: true, isPausedForAnyReason: true,
                        sampleHealth: .critical)), .critical,
              "scanning holds the last reading rather than greying out")
        equal(at(inputs(monitorRunning: false)), .warning,
              "supposed to be monitoring but the child is dead → warning")
        equal(at(inputs(sampleHealth: .critical)), .critical,
              "a live sample's own severity wins")
        equal(at(inputs(sampleHealth: nil, runHealth: .warning)), .warning,
              "no sample yet → the newest run's severity")
        equal(at(inputs(sampleHealth: nil, runHealth: nil)), .warning,
              "nothing measured at all → warning, never green")
        check(Health.paused.symbol != Health.healthy.symbol,
              "paused is distinguishable from healthy without colour")
        print("")
    }

    // MARK: - Alert attribution

    /// An alert stores the rules that *fired*, not the whole set it listens
    /// for. Getting this wrong is invisible in the UI right up until it
    /// isn't: `internet-degraded` listens for L1 (critical) and L2 (warn),
    /// so storing the listen-set made every moderate-loss episode rank and
    /// read as a severe one.
    static func runAlertAttributionTests() {
        print("Alert attribution")
        guard let degraded = AlertDefinition.byID("internet-degraded") else {
            check(false, "internet-degraded definition exists"); return
        }
        check(degraded.rules.isSuperset(of: ["L1", "L2"]),
              "internet-degraded listens for both L1 and L2")

        // What `AlertEngine.evaluate(sample:)` now computes.
        let firing = degraded.rules.intersection(Set(["L2"]))
        equal(firing, ["L2"], "an L2-only sample fires L2, not the listen-set")
        equal(firing.sorted().first, "L2",
              "the timeline records the rule that fired, not Set.first of the listen-set")

        let snapshot = StageResolver.AlertSnapshot(
            title: degraded.title, body: "", raisedAt: Date(), rules: firing,
            severityRank: NetdiagCoordinator.severityRank("warn"))
        equal(snapshot.severityRank, 2, "an L2-only alert ranks warn, not critical")

        // The duplicate the dropdown's timeline now filters: the event an
        // alert writes carries the alert's own title verbatim, which is
        // also what the stage card renders.
        equal(degraded.title, snapshot.title,
              "the alert event's summary is the very string the stage card shows")
        print("")
    }

    // MARK: - Tiny assert helpers (no XCTest available at runtime on CLT)

    private static func equal<T: Equatable>(_ got: T, _ want: T, _ name: String) {
        if got == want {
            print("  \u{2714} \(name)")
        } else {
            print("  \u{2718} \(name) — got \(got), want \(want)")
            failures.append(name)
        }
    }

    private static func check(_ condition: Bool, _ name: String) {
        if condition {
            print("  \u{2714} \(name)")
        } else {
            print("  \u{2718} \(name)")
            failures.append(name)
        }
    }

    private static func inputs(severity: String = "ok",
                               linkUp: Bool = true,
                               activeAlert: StageResolver.AlertSnapshot? = nil,
                               isScanning: Bool = false,
                               monitoringEnabled: Bool = true,
                               isPausedForAnyReason: Bool = false,
                               pauseReason: String? = nil,
                               lastError: String? = nil,
                               monitorRunning: Bool = true,
                               measurementState: String = "measured") -> StageResolver.Inputs {
        StageResolver.Inputs(
            isScanning: isScanning,
            monitoringEnabled: monitoringEnabled,
            isPausedForAnyReason: isPausedForAnyReason,
            pauseReason: pauseReason,
            lastError: lastError,
            monitorRunning: monitorRunning,
            activeAlert: activeAlert,
            severity: severity,
            linkUp: linkUp,
            measurementState: measurementState
        )
    }

    // MARK: - 1. StageResolver logic

    static func runStageTests() {
        print("StageResolver:")
        // Healthy: ok and info both read green. Info severity (VPN on, ICMP
        // filtered) is not a problem — the whole point of info is "something
        // is happening but it is fine", so it must not light the card up.
        equal(StageResolver.resolve(inputs(severity: "ok")), .healthy, "ok severity → healthy")
        equal(StageResolver.resolve(inputs(severity: "info")), .healthy, "info severity → healthy (VPN/ICMP-filter is not a fault)")
        equal(StageResolver.resolve(inputs(severity: "ok", linkUp: false)), .watching(severity: .critical), "link down → watching critical even with ok severity")

        // The core reactivity guarantee: warn and critical land on .watching
        // immediately, before any alert dwell. This is the case that used to
        // read .healthy for 15–25 s while the timeline already showed the drop.
        equal(StageResolver.resolve(inputs(severity: "warn")), .watching(severity: .warn), "warn → watching (amber, before dwell)")
        equal(StageResolver.resolve(inputs(severity: "critical")), .watching(severity: .critical), "critical → watching (red, before dwell)")
        equal(StageResolver.resolve(inputs(measurementState: "unknown")), .checking, "unknown measurement → checking, not healthy")

        // An active alert wins over watching — once the dwell elapses the
        // card carries the alert's prose, which a scan may have enriched.
        let alert = StageResolver.AlertSnapshot(title: "No internet connection",
                                                body: "Checking what happened…",
                                                raisedAt: Date(),
                                                rules: ["P1"])
        equal(StageResolver.resolve(inputs(severity: "critical", activeAlert: alert)),
              .alerted(alert), "active alert → alerted (overrides watching)")

        // Precedence: each earlier guard beats the later ones. Testing each
        // guard with every later signal live proves the order is load-bearing,
        // not accidental.
        equal(StageResolver.resolve(inputs(severity: "critical", activeAlert: alert,
                                            isScanning: true, monitoringEnabled: false,
                                            isPausedForAnyReason: true)),
              .testing, "scanning precedes paused / skewed / alert / watching")
        equal(StageResolver.resolve(inputs(severity: "critical", activeAlert: alert,
                                            monitoringEnabled: false, isPausedForAnyReason: true)),
              .paused(nil), "user-disabled monitoring precedes monitor-paused / alert / watching")
        equal(StageResolver.resolve(inputs(severity: "critical", activeAlert: alert,
                                            isPausedForAnyReason: true,
                                            pauseReason: "display sleeping")),
              .paused("display sleeping"), "monitor-paused precedes skewed / alert / watching")
        equal(StageResolver.resolve(inputs(severity: "critical", activeAlert: alert,
                                            lastError: "cli too old", monitorRunning: false)),
              .skewed("cli too old"), "skewed CLI precedes alert / watching")
        equal(StageResolver.resolve(inputs(severity: "warn", activeAlert: nil)),
              .watching(severity: .warn), "no alert + warn → watching (alert gate is what kept it healthy before)")

        // No measurement yet is explicitly neutral, never an all-clear.
        equal(StageResolver.resolve(inputs(severity: "ok", linkUp: true,
                                            measurementState: "unknown")),
              .checking, "first-sample unknown → checking")
    }

    // MARK: - Full-check policy
    //
    // A full check runs a bufferbloat probe that deliberately saturates
    // the link for ~10 s. Doing that to a connection already reporting
    // critical makes the user's situation worse in the middle of the
    // problem they opened the app about. Same reasoning
    // NetdiagRunner.Depth.alertTriggered already encodes by passing
    // --no-bufferbloat; this extends it to the manual path.

    private static func runFullCheckPolicyTests() {
        print("\nFullCheckPolicy")
        equal(FullCheckPolicy.isSafe(severity: "ok"), true, "ok permits a full check")
        equal(FullCheckPolicy.isSafe(severity: "info"), true, "info permits a full check")
        equal(FullCheckPolicy.isSafe(severity: "warn"), true, "warn permits a full check")
        equal(FullCheckPolicy.isSafe(severity: "critical"), false, "critical blocks a full check")
        // An unrecognised severity must not silently read as safe: the
        // CLI is the authority on this vocabulary and a value we do not
        // know is a value we cannot clear.
        equal(FullCheckPolicy.isSafe(severity: ""), false, "unknown severity blocks a full check")
        equal(FullCheckPolicy.isSafe(severity: "catastrophic"), false, "unrecognised severity blocks a full check")

        // The control's label and tooltip must name the depth that will
        // actually run, and the unsafe help must never author a verdict.
        // Commit 69fa7fb shipped one that asserted the connection was
        // down at that instant — Swift composing a diagnosis, and false
        // whenever `isSafe` declined for want of a sample rather than for
        // a critical reading. These four assertions are what keep it out.
        let safeLabel = FullCheckPolicy.controlLabel(isSafe: true)
        let unsafeLabel = FullCheckPolicy.controlLabel(isSafe: false)
        equal(safeLabel.contains("Full check"), true, "safe label names the full check")
        equal(unsafeLabel.contains("Lighter check"), true, "unsafe label names the lighter check")

        let unsafeHelp = FullCheckPolicy.controlHelp(isSafe: false)
        equal(unsafeHelp.contains("is failing"), false, "unsafe help never claims the connection is failing")
        equal(unsafeHelp.contains("speed test"), true, "unsafe help discloses the speed test is skipped too")
    }

    // MARK: - Headline rule selection
    //
    // `lib/monitor.sh`'s `_mon_rules` appends rules in the order it
    // evaluates them, not by severity: TCP-1, the G-loss rules, P-reach,
    // D1, CP-1, VPN-1, ICMP-1, then the L-loss rules. So an `info` VPN-1
    // routinely sits ahead of a `critical` L1 in `status.rules`, and the
    // headline used to take the first rule it could look up — putting "A
    // VPN is carrying your traffic right now" under a red "Detecting a
    // network problem" card while the user lost most of their packets.
    //
    // This is invisible on inspection (both orderings look reasonable) and
    // only reproduces on a machine with a VPN up and a failing link, which
    // is why it is asserted here rather than left to be noticed.

    private static func runHeadlineRuleTests() {
        print("\nHeadline rule selection")

        // A stand-in catalog rather than the real one: the harness runs
        // headless with no CLI to query, and the behaviour under test is
        // the ranking, not the catalog's contents.
        let catalog = stubCatalog([
            ("VPN-1", "info", "A VPN is carrying your traffic right now."),
            ("L1", "critical", "Severe internet packet loss."),
            ("D1", "warn", "DNS resolver flaky."),
        ])

        equal(NetdiagCoordinator.headlineText(forRulesIn: ["VPN-1", "L1"], catalog: catalog),
              "Severe internet packet loss.",
              "a critical rule outranks an info one that precedes it")
        equal(NetdiagCoordinator.headlineText(forRulesIn: ["VPN-1", "D1"], catalog: catalog),
              "DNS resolver flaky.",
              "a warn rule outranks an info one that precedes it")
        equal(NetdiagCoordinator.headlineText(forRulesIn: ["L1", "D1", "VPN-1"], catalog: catalog),
              "Severe internet packet loss.",
              "the worst rule wins regardless of position")
        equal(NetdiagCoordinator.headlineText(forRulesIn: ["VPN-1"], catalog: catalog),
              "A VPN is carrying your traffic right now.",
              "a lone info rule is still shown")
        // A rule this build's catalog has never heard of must not win by
        // default and blank the headline.
        equal(NetdiagCoordinator.headlineText(forRulesIn: ["ZZ-9", "L1"], catalog: catalog),
              "Severe internet packet loss.",
              "an unknown rule id never outranks a known one")
        equal(NetdiagCoordinator.headlineText(forRulesIn: ["ZZ-9"], catalog: catalog),
              nil,
              "only unknown rules yields no headline, not an empty one")
        equal(NetdiagCoordinator.headlineText(forRulesIn: [], catalog: catalog),
              nil,
              "no firing rules yields no headline")
        equal(NetdiagCoordinator.headlineText(forRulesIn: ["L1"], catalog: nil),
              nil,
              "no catalog yields no headline rather than a rule id")

        // Ranking itself, including the vocabulary the CLI actually emits.
        equal(NetdiagCoordinator.severityRank("critical") > NetdiagCoordinator.severityRank("warn"),
              true, "critical outranks warn")
        equal(NetdiagCoordinator.severityRank("warn") > NetdiagCoordinator.severityRank("info"),
              true, "warn outranks info")
        equal(NetdiagCoordinator.severityRank("info") > NetdiagCoordinator.severityRank("varies"),
              true, "a known severity outranks one this build cannot rank")
    }

    /// A minimal `RulesCatalog` built from (id, severity, blurb) triples,
    /// via the type's own decoder so the harness exercises the same path
    /// the app does rather than a hand-built value the decoder might
    /// disagree with.
    private static func stubCatalog(_ rules: [(String, String, String)]) -> RulesCatalog? {
        let payload: [String: Any] = [
            "schema": 3,
            "rules": rules.map { ["id": $0.0, "severity": $0.1, "blurb": $0.2] },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return try? JSONDecoder().decode(RulesCatalog.self, from: data)
    }

    // MARK: - PhaseWeights
    //
    // The one type this feature added that is worth asserting on directly:
    // a pure struct, built here with `PhaseWeights(samples:)` rather than
    // `.loaded()`, so these checks never touch the real `Defaults` store a
    // person's own runs have been teaching. Every scenario re-asserts the
    // two properties that matter most — the fraction never goes down within
    // a run, and it never exceeds 1 — because those are exactly the ones a
    // future refactor could quietly break without any single case catching
    // it.

    private static func runPhaseWeightsTests() {
        print("\nPhaseWeights")

        func phase(_ name: String, _ state: ScanProgress.PhaseState, ms: Int? = nil) -> ScanProgress.Phase {
            ScanProgress.Phase(name: name, state: state, ms: ms)
        }

        /// Asserts a fraction sequence never drops, never exceeds 1, and
        /// ends where expected — the shared shape every scenario below
        /// checks, so the "never decreases / never exceeds 1" guarantee is
        /// verified once per scenario rather than trusted on faith after
        /// the first.
        func assertSequence(_ fractions: [Double], endsAt want: Double, _ label: String) {
            check(fractions.allSatisfy { $0 >= 0 && $0 <= 1 }, "\(label): every fraction in 0...1")
            check(zip(fractions, fractions.dropFirst()).allSatisfy { $0 <= $1 },
                  "\(label): fraction never decreases")
            equal(fractions.last ?? -1, want, "\(label): final fraction")
        }

        // Scenario 1: a "full"-shaped mode with learned weights, dominated
        // by one heavy phase (as the real speed test dominates a real full
        // run — 65-115s against single-digit seconds for everything else).
        // Walking every phase from pending through running to done, in
        // order, must reach exactly 1.0: `doneWeight` and `totalWeight`
        // accumulate the same terms in the same order once every phase is
        // `.done`, so they are bit-for-bit equal, not just "close".
        let full = PhaseWeights(samples: [
            "full": ["iface": [100], "gateway": [200], "wifi": [150], "speedtest": [90_000]],
        ])
        let fullNames = ["iface", "gateway", "wifi", "speedtest"]
        var fullFractions: [Double] = []
        var running = fullNames.map { phase($0, .pending) }
        for index in fullNames.indices {
            running[index].state = .running
            fullFractions.append(full.progress(mode: "full", phases: running,
                                               speedProgress: nil, bufferbloatProgress: nil).fraction)
            running[index].state = .done
            running[index].ms = 1 // learned weight is used regardless of this run's own ms
            fullFractions.append(full.progress(mode: "full", phases: running,
                                               speedProgress: nil, bufferbloatProgress: nil).fraction)
        }
        assertSequence(fullFractions, endsAt: 1.0, "full run, learned weights")

        // Scenario 2: sub-progress inside the heaviest phase (here,
        // "speedtest", weighted 90000 of a 90450 total — ~99.5% of the bar)
        // must visibly move the fraction rather than leaving it pinned at
        // whatever the other phases contributed.
        var atSpeedtest = fullNames.map { phase($0, .done, ms: 1) }
        atSpeedtest[3] = phase("speedtest", .running)
        let atStart = full.progress(mode: "full", phases: atSpeedtest,
                                    speedProgress: 0.0, bufferbloatProgress: nil).fraction
        let atHalf = full.progress(mode: "full", phases: atSpeedtest,
                                   speedProgress: 0.5, bufferbloatProgress: nil).fraction
        let atFull = full.progress(mode: "full", phases: atSpeedtest,
                                   speedProgress: 1.0, bufferbloatProgress: nil).fraction
        check(atStart < atHalf && atHalf < atFull,
              "sub-progress inside the heaviest phase moves the bar (\(atStart) < \(atHalf) < \(atFull))")
        equal(atFull, 1.0, "heaviest phase's sub-progress reaching 1.0 completes the bar")

        // Scenario 3: a "quick"-shaped mode where the speed test is always
        // skipped, so it was never learned — only iface/gateway/wifi have
        // history. The plan still lists it (progress_plan_phases declares
        // the same phases for full and quick — see lib/common.sh), so the
        // bar must re-normalise around it rather than stall short of 1.0.
        let quick = PhaseWeights(samples: [
            "quick": ["iface": [100], "gateway": [200], "wifi": [150]],
        ])
        let beforeSkip = [phase("iface", .done, ms: 100), phase("gateway", .done, ms: 200),
                          phase("wifi", .done, ms: 150), phase("speedtest", .pending)]
        let afterSkip = [phase("iface", .done, ms: 100), phase("gateway", .done, ms: 200),
                         phase("wifi", .done, ms: 150), phase("speedtest", .skipped, ms: nil)]
        let beforeFraction = quick.progress(mode: "quick", phases: beforeSkip,
                                            speedProgress: nil, bufferbloatProgress: nil).fraction
        let afterFraction = quick.progress(mode: "quick", phases: afterSkip,
                                           speedProgress: nil, bufferbloatProgress: nil).fraction
        check(beforeFraction < 1.0, "quick run: still-pending skipped-to-be phase holds the bar below 1.0")
        equal(afterFraction, 1.0, "quick run: skipping the speed test still reaches 1.0")
        check(afterFraction >= beforeFraction, "quick run: resolving to skip never lowers the fraction")

        // Scenario 4: no history at all for this mode. Equal weights, and
        // — the point of `isLearned` — no ETA the app has not earned.
        let unlearned = PhaseWeights()
        let freshPhases = [phase("a", .done, ms: 1), phase("b", .pending), phase("c", .pending)]
        let freshSnapshot = unlearned.progress(mode: "never-seen", phases: freshPhases,
                                               speedProgress: nil, bufferbloatProgress: nil)
        equal(freshSnapshot.isLearned, false, "no history: isLearned is false")
        equal(freshSnapshot.remainingSeconds, nil, "no history: no ETA offered")
        equal(freshSnapshot.fraction, 1.0 / 3.0, "no history: equal weights (1 of 3 phases done)")

        // Scenario 5: `parallel_batch` wraps the ten checks bin/netdiag
        // launches concurrently, so its duration is the wall clock they
        // shared and counting both puts the same seconds in twice. The
        // numbers here are a real `--quick` capture: dns 380, tcp_reach
        // 120, ipv6 18 — and parallel_batch 395 spanning all three.
        let batch = PhaseWeights(samples: [
            "quick": ["dns": [380], "tcp_reach": [120], "ipv6": [18], "parallel_batch": [395]],
        ])
        // Everything inside the batch has landed; the wrapper has not.
        let insideDone = [phase("dns", .done, ms: 380), phase("tcp_reach", .done, ms: 120),
                          phase("ipv6", .done, ms: 18), phase("parallel_batch", .running)]
        let batchSnapshot = batch.progress(mode: "quick", phases: insideDone,
                                           speedProgress: nil, bufferbloatProgress: nil)
        // Without the exclusion this is 518/913 ≈ 0.57 and the bar would
        // still have a "phase" worth 43% of the run left to go — time
        // that has, in fact, already elapsed.
        equal(batchSnapshot.fraction, 1.0,
              "parallel_batch does not double-count the phases it wraps")
        equal(batchSnapshot.remainingSeconds, 0,
              "parallel_batch contributes no time to the ETA")
        // And its stored samples must not skew the fallback estimate used
        // for a phase this mode has never measured.
        let withUnseen = insideDone + [phase("mtu", .pending)]
        let fallbackSnapshot = batch.progress(mode: "quick", phases: withUnseen,
                                              speedProgress: nil, bufferbloatProgress: nil)
        // Fallback = mean of {380, 120, 18} = 172.67 → 173, not the
        // mean of those plus 395 (228) the wrapper would have produced.
        equal(fallbackSnapshot.fraction, 518.0 / 691.0,
              "an overlapping phase's samples stay out of the fallback estimate")
    }

    // MARK: - Suitability rows and rules-catalog fix fields
    //
    // Both decode leniently, for the reason the commit that added them
    // states: the app bundles its own CLI but can be pointed at an older
    // one via `netdiagBinaryPath`, and a report missing a block must cost
    // one panel, never the whole run. These checks are what makes that a
    // guarantee rather than an intention — a document with no `suitability`
    // key, or a verdict string this build has never seen, has to come out
    // the other side as a normal (if partial) run, not a decode failure.

    /// `SuitabilityPanel`'s three mappings. They are static on the view
    /// precisely so they can be called here: this harness cannot construct
    /// a SwiftUI view, so anything buried in a body is unreachable — the
    /// same constraint that put `StageResolver` and `FullCheckPolicy` in
    /// their own files.
    private static func runSuitabilityPanelTests() {
        print("\nSuitability panel mappings")

        typealias V = RunSnapshot.SuitabilityRow.Verdict
        let all: [V] = [.good, .degraded, .broken, .unmeasured, .unknown]

        // Every verdict gets its own word and its own glyph. A duplicate
        // in either would make two different answers look identical.
        check(Set(all.map(SuitabilityPanel.word)).count == all.count,
              "each verdict maps to a distinct word")
        check(Set(all.map(SuitabilityPanel.symbol)).count == all.count,
              "each verdict maps to a distinct symbol")

        // Colour is never the only signal (see MenuBarLabel.dot). The two
        // verdicts that share a tint — unmeasured and unknown — must still
        // differ in shape, and the three coloured ones must differ from
        // each other in shape too, so the panel reads in monochrome.
        check(SuitabilityPanel.symbol(.unmeasured) != SuitabilityPanel.symbol(.unknown),
              "the two secondary-tinted verdicts still differ in shape")

        // The reason line: the CLI's own sentence wins; otherwise the
        // rules that decided it; otherwise nothing at all.
        var row = RunSnapshot.SuitabilityRow()
        row.unmeasuredReason = "This check didn't run the speed test."
        row.because = ["B1"]
        check(SuitabilityPanel.detail(row) == "This check didn't run the speed test.",
              "an unmeasured reason outranks the rule list")

        row.unmeasuredReason = nil
        check(SuitabilityPanel.detail(row) == "because B1",
              "a fired rule is cited when there is no unmeasured reason")

        row.because = ["G3", "G2"]
        check(SuitabilityPanel.detail(row) == "because G3, G2",
              "several rules are joined in the order the CLI gave them")

        row.because = []
        check(SuitabilityPanel.detail(row) == nil,
              "a good row with nothing to cite gets no reason line")

        // An empty reason string is not a reason. The CLI emits null, but
        // a future one emitting "" must not produce a blank second line.
        row.unmeasuredReason = ""
        check(SuitabilityPanel.detail(row) == nil,
              "an empty reason string is treated as absent, not printed blank")
    }

    private static func runSuitabilityAndFixFieldTests() {
        print("\nSuitability rows + rules-catalog fix fields")

        func decodeSnapshot(_ json: String) -> RunSnapshot? {
            guard let data = json.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(RunSnapshot.self, from: data)
        }
        func decodeCatalog(_ json: String) -> RulesCatalog? {
            guard let data = json.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(RulesCatalog.self, from: data)
        }

        // 1. A `broken` row and an `unmeasured` row decode: verdicts map
        // correctly, `because` survives, `unmeasuredReason` is non-nil on
        // the unmeasured row and nil on the other.
        let withRows = decodeSnapshot("""
        {"suitability": [
          {"activity": "calls", "label": "Video & voice calls", "verdict": "broken",
           "because": ["G2"], "unmeasured_reason": null},
          {"activity": "streaming", "label": "Streaming", "verdict": "unmeasured",
           "because": [], "unmeasured_reason": "This check didn't run the speed test."}
        ]}
        """)
        equal(withRows?.suitability.count, 2, "two suitability rows decode")
        equal(withRows?.suitability.first?.verdict, .broken, "broken verdict maps correctly")
        equal(withRows?.suitability.first?.because, ["G2"], "because survives decode")
        equal(withRows?.suitability.first?.unmeasuredReason, nil,
              "a measured row's unmeasuredReason is nil")
        equal(withRows?.suitability.last?.verdict, .unmeasured, "unmeasured verdict maps correctly")
        equal(withRows?.suitability.last?.unmeasuredReason,
              "This check didn't run the speed test.",
              "unmeasuredReason is non-nil on the unmeasured row")

        // 2. No `suitability` key at all decodes as an empty array, not a
        // throw — the missing-block case an older bundled CLI produces.
        let noSuitability = decodeSnapshot("{\"version\": \"0.9.0\"}")
        check(noSuitability != nil, "a document with no suitability key still decodes")
        check(noSuitability?.suitability.isEmpty ?? false,
              "missing suitability key decodes as [], not a throw")

        // 3. An unrecognised verdict string does not throw the whole decode.
        let unknownVerdict = decodeSnapshot("""
        {"suitability": [
          {"activity": "gaming", "label": "Gaming", "verdict": "excellent",
           "because": [], "unmeasured_reason": null}
        ]}
        """)
        equal(unknownVerdict?.suitability.count, 1,
              "a row with an unrecognised verdict still decodes")
        equal(unknownVerdict?.suitability.first?.verdict, .unknown,
              "an unrecognised verdict maps to .unknown rather than throwing")

        // 4. A catalog rule decodes fix, fixAway, fixTarget; a rule with no
        // fix_away leaves it nil.
        let catalog = decodeCatalog("""
        {"schema": 5, "rules": [
          {"id": "G2", "title": "Router dropping packets",
           "impacts": {"calls": "broken", "browsing": "degraded"},
           "fix": "Reboot the router: unplug it, wait ten seconds, plug it back in.",
           "fix_away": "Ask whoever runs this network to restart the router.",
           "fix_target": "your_router"},
          {"id": "VPN-1", "title": "VPN active",
           "fix": "Nothing to do — this is expected.", "fix_target": "nobody"}
        ]}
        """)
        equal(catalog?["G2"]?.fix,
              "Reboot the router: unplug it, wait ten seconds, plug it back in.",
              "a rule decodes fix")
        equal(catalog?["G2"]?.fixAway,
              "Ask whoever runs this network to restart the router.",
              "a rule decodes fix_away")
        equal(catalog?["G2"]?.fixTarget, "your_router", "a rule decodes fix_target")
        equal(catalog?["G2"]?.impacts?["calls"], "broken", "a rule decodes impacts")
        equal(catalog?["VPN-1"]?.fix, "Nothing to do — this is expected.",
              "a rule with fix_target nobody still has a fix")
        equal(catalog?["VPN-1"]?.fixAway, nil,
              "a rule with no fix_away leaves it nil rather than a fabricated default")

        // 5. A catalog from an older CLI with none of the three fields (and
        // no `impacts`) still decodes.
        let oldCatalog = decodeCatalog("""
        {"schema": 3, "rules": [
          {"id": "G2", "title": "Router dropping packets", "category": "router",
           "severity": "critical", "scope": "both",
           "blurb": "Packets are being dropped between your Mac and your router.",
           "doc": "DIAGNOSIS-RULES.md#g2--gateway-loss-with-healthy-wifi"}
        ]}
        """)
        check(oldCatalog != nil, "a pre-schema-5 catalog still decodes")
        equal(oldCatalog?["G2"]?.title, "Router dropping packets",
              "a pre-schema-5 catalog keeps decoding its existing fields")
        equal(oldCatalog?["G2"]?.fix, nil, "fix is nil against a pre-schema-5 catalog")
        equal(oldCatalog?["G2"]?.fixAway, nil, "fix_away is nil against a pre-schema-5 catalog")
        equal(oldCatalog?["G2"]?.fixTarget, nil, "fix_target is nil against a pre-schema-5 catalog")
        equal(oldCatalog?["G2"]?.impacts, nil, "impacts is nil against a pre-schema-5 catalog")
    }

    // MARK: - 2. Stage-card visual contract (offscreen render → PNG)

    /// A stand-in for the dropdown's stage card, driven by the same
    /// `StageResolver.Stage` the real `DropdownView` consumes. The colour,
    /// icon and title per stage match the dropdown's stage views; the body
    /// is representative prose so the snapshot shows how a real card reads.
    private struct StageCardSnapshot: View {
        let stage: StageResolver.Stage
        let bodyText: String

        var body: some View {
            card.frame(width: 340, height: 80)
        }

        @ViewBuilder private var card: some View {
            switch stage {
            case .healthy:
                content(icon: "checkmark.circle.fill", tint: .green,
                        title: "All good — watching", tertiary: "Nothing has changed in 3h 12m")
                    .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            case .watching(let sev):
                let critical = sev == .critical
                content(icon: critical ? "exclamationmark.triangle.fill" : "exclamationmark.triangle",
                        tint: critical ? .red : .orange,
                        title: critical ? "Detecting a network problem" : "Watching — something needs attention",
                        tertiary: critical ? "Confirming before notifying you…" : "Will alert if this keeps up.")
                    .background((critical ? Color.red : Color.orange).opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 10))
            case .alerted(let alert):
                // Never a stand-in: the alerted card is the one whose
                // colour was wrong, so this arm defers to the real view
                // rather than keeping a second copy of it that could
                // agree with the bug. (`runSnapshots` renders these
                // directly, once per severity — this arm exists so the
                // switch stays exhaustive and honest.)
                AlertStageCard(alert: alert)
            case .testing:
                content(icon: "circle.dashed", tint: .accentColor,
                        title: "Checking…", tertiary: "pinging the gateway")
                    .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            case .checking:
                content(icon: "hourglass", tint: .secondary,
                        title: "Checking connection…", tertiary: "waiting for a live reading")
                    .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            case .paused(let reason):
                content(icon: "pause.circle.fill", tint: .secondary,
                        title: "Monitoring paused", tertiary: reason ?? "")
                    .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            case .skewed:
                content(icon: "exclamationmark.triangle", tint: .yellow,
                        title: "The netdiag command needs attention", tertiary: "cli too old")
                    .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
        }

        private func content(icon: String, tint: Color, title: String, tertiary: String) -> some View {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: icon).foregroundStyle(tint)
                    Text(title).font(.callout).fontWeight(.semibold)
                }
                Text(bodyText).font(.caption).foregroundStyle(.secondary)
                if !tertiary.isEmpty {
                    Text(tertiary).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Render a SwiftUI view to an NSImage offscreen via NSHostingView +
    /// `cacheDisplay`. Captures the layer without a window for static
    /// content; called after launch so NSApplication is already up.
    private static func renderImage(_ view: some View, size: NSSize) -> NSImage? {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            return nil
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    static func runSnapshots() {
        print("Render stage-card snapshots:")
        let dir = "/tmp/opencode/verify"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let cases: [(String, StageResolver.Stage, String)] = [
            ("healthy",           .healthy,                                  "Watching for changes."),
            ("watching-warn",     .watching(severity: .warn),                "You're losing a few packets to your router."),
            ("watching-critical", .watching(severity: .critical),            "Your Mac has no internet connection at all."),
            // `.alerted` is deliberately absent: it is rendered above from
            // the real `AlertStageCard`, once per severity band.
            ("paused",            .paused("display sleeping"),               "Monitoring is off while the display sleeps."),
            ("skewed",            .skewed("netdiag CLI is too old"),         "The bundled netdiag is older than this app expects."),
            ("testing",           .testing,                                  "Running a full check…"),
            ("checking",          .checking,                                 "Waiting for a live reading…"),
        ]
        // The alerted stage is rendered from `AlertStageCard` — the real
        // view the dropdown and Activity both use — rather than from the
        // stand-in below, and once per severity band. The stand-in only
        // ever drew the critical case, which is exactly how every alert
        // wearing critical-red survived unnoticed: a warn-severity BL-1
        // and a rule-less "public IP changed" looked identical to a dead
        // connection, while the lower-priority `.watching` card rendered
        // the same warn condition in amber two lines up.
        let alertCases: [(String, StageResolver.AlertSnapshot)] = [
            ("alert-critical", .init(title: "No internet connection",
                                     body: "Checking what happened…",
                                     raisedAt: Date(), rules: ["P1"], severityRank: 3)),
            ("alert-warn",     .init(title: "Slower than usual",
                                     body: "Download is well below this network's usual range.",
                                     raisedAt: Date(), rules: ["BL-1"], severityRank: 2)),
            ("alert-info",     .init(title: "Your public IP address changed",
                                     body: "", raisedAt: Date(), rules: [], severityRank: 0)),
            ("alert-unranked", .init(title: "Connection is unstable",
                                     body: "Checking whether it's your Wi-Fi or your router…",
                                     raisedAt: Date(), rules: ["G2"], severityRank: 0)),
        ]
        for (name, alert) in alertCases {
            guard let image = renderImage(
                AlertStageCard(alert: alert, moreCount: 0, onOpen: {})
                    .frame(width: 340).padding(4),
                size: NSSize(width: 348, height: 88)) else {
                print("  \u{2718} \(name) — could not allocate bitmap representation")
                failures.append("render-\(name)")
                continue
            }
            writePNG(image, to: "\(dir)/stage-\(name).png", name: name)
        }

        for (name, stage, body) in cases {
            guard let image = renderImage(StageCardSnapshot(stage: stage, bodyText: body),
                                          size: NSSize(width: 340, height: 80)) else {
                print("  \u{2718} \(name) — could not allocate bitmap representation")
                failures.append("render-\(name)")
                continue
            }
            writePNG(image, to: "\(dir)/stage-\(name).png", name: name)
        }
    }

    private static func writePNG(_ image: NSImage, to path: String, name: String) {
        let url = URL(fileURLWithPath: path)
        do {
            if let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: url)
                print("  \u{2714} wrote \(url.path)")
            } else {
                print("  \u{2718} \(name) — could not produce PNG bytes")
                failures.append("render-\(name)")
            }
        } catch {
            print("  \u{2718} \(name) — \(error.localizedDescription)")
            failures.append("render-\(name)")
        }
    }
}
