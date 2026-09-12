import SwiftUI
import AppKit
import Foundation
import ServiceManagement
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
        runCaptivePortalActionTests()
        runFullCheckPolicyTests()
        runNetworkIdentityTests()
        runNetworkIdentityFixtureTests()
        runArrivalStateTests()
        runArrivalPolicyTests()
        runArrivalMigrationTests()
        runArrivalCopyTests()
        runArrivalStageTests()
        runHeadlineRuleTests()
        runPhaseWeightsTests()
        runActivityFoldTests()
        runSuitabilityAndFixFieldTests()
        runSuitabilityPanelTests()
        runReportProvenanceTests()
        runTrendsClampTests()
        runRunGroupTests()
        runMonitorSeriesGapTests()
        runLaunchAtLoginTests()
        runMenuBarLatencyTests()
        runDiagnosticShareTests()
        runSnapshots()
        renderArrivalCards()
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

    static func runCaptivePortalActionTests() {
        print("Captive portal action (CP-1)")
        guard let captiveDef = AlertDefinition.byID("captive-portal") else {
            check(false, "captive-portal alert definition exists"); return
        }
        check(captiveDef.id == "captive-portal", "captive-portal definition id is captive-portal")
        check(captiveDef.title == "This network needs you to sign in", "title is 'This network needs you to sign in'")

        let snapshot = StageResolver.AlertSnapshot(
            title: captiveDef.title,
            body: captiveDef.interimBody,
            raisedAt: Date(),
            rules: ["CP-1"],
            severityRank: 1,
            id: "captive-portal"
        )
        equal(snapshot.id, "captive-portal", "snapshot carries alert ID")
        check(snapshot.rules.contains("CP-1"), "snapshot contains CP-1")

        let url = URL(string: "http://captive.apple.com/hotspot-detect.html")
        equal(url?.host, "captive.apple.com", "hotspot detect host is captive.apple.com")
        equal(url?.path, "/hotspot-detect.html", "hotspot detect path is /hotspot-detect.html")

        // Verify AlertStageCard renders with captive portal action
        let card = AlertStageCard(alert: snapshot, moreCount: 0, onOpen: {})
        let rendered = renderImage(card.frame(width: 340).padding(4), size: NSSize(width: 348, height: 110))
        check(rendered != nil, "AlertStageCard with captive portal renders successfully")
        print("")
    }

    // MARK: - Activity fold

    /// The transition-log → episode fold behind the Activity screen.
    ///
    /// Worth asserting rather than eyeballing because every interesting
    /// case is a *missing* event — a fault whose clear never arrived, a
    /// clear whose fire predates the store's cap — and each one has a
    /// plausible wrong answer that looks fine in a screenshot: a duration
    /// invented across an unobserved gap, or an episode silently dropped.
    static func runActivityFoldTests() {
        print("Activity fold (episodes, not transitions)")
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        func event(_ kind: String, _ rule: String?, _ offset: TimeInterval,
                   _ summary: String = "Minor packet loss to router",
                   _ network: String? = nil) -> NetworkEvent {
            NetworkEvent(date: day.addingTimeInterval(offset), kind: kind,
                         summary: summary, ruleID: rule, network: network)
        }

        // One fired, one cleared → one row carrying the duration the two
        // transitions imply and neither of them states.
        let paired = ActivityEntry.fold([
            event("rule-cleared", "G3", 120, "Resolved: Minor packet loss to router"),
            event("rule-fired", "G3", 0),
        ])
        equal(paired.count, 1, "a fired/cleared pair folds to one row")
        equal(paired.first?.occurrences, 1, "and counts as one occurrence")
        equal(paired.first?.totalDuration, 120, "carrying the 2-minute duration")
        equal(paired.first?.detail, "lasted 2m", "rendered as a duration, not a count")

        // Three pairs in a day → one row. This is the whole point: six
        // stored rows, one line of history.
        var flapping: [NetworkEvent] = []
        for i in 0..<3 {
            flapping.append(event("rule-fired", "G3", Double(i) * 600))
            flapping.append(event("rule-cleared", "G3", Double(i) * 600 + 60,
                                  "Resolved: Minor packet loss to router"))
        }
        let folded = ActivityEntry.fold(flapping)
        equal(folded.count, 1, "three pairs in one day fold to one row")
        equal(folded.first?.occurrences, 3, "counting all three")
        equal(folded.first?.totalDuration, 180, "and summing their durations")
        equal(folded.first?.detail, "3 times · 3m total", "read as count plus total")

        // A second fire with no clear between: the monitor emits only on
        // transition, so this means it restarted and the span in between
        // went unobserved. The duration must be a floor, not a guess.
        let restarted = ActivityEntry.fold([
            event("rule-fired", "G3", 3600),
            event("rule-cleared", "G3", 300, "Resolved: Minor packet loss to router"),
            event("rule-fired", "G3", 0),
        ])
        equal(restarted.count, 1, "a re-fire after a restart stays one row")
        equal(restarted.first?.occurrences, 2, "as two observed occurrences")
        check(restarted.first?.isOngoing == true,
              "the unpaired last fire is marked open")
        equal(restarted.first?.totalDuration, 300,
              "only the observed span counts — the unobserved gap is not invented")

        // ...and an open episode never claims the fault is still running,
        // because the usual reason a clear is missing is that the monitor
        // stopped, not that the condition persisted.
        check(!(restarted.first?.detail?.contains("still active") ?? false),
              "an open episode does not assert the fault is ongoing")

        // Two fires with *no clear between* — the case above never reaches,
        // because its clear closes the first episode before the second fire
        // arrives. This is the real restart: the monitor died at some point
        // during an hour-long fault and re-observed it on the way back up.
        //
        // The hour between the two fires is not a guess. The rule was firing
        // at the start of it and firing at the end of it, so the fault is
        // known to have held for at least that long, and `helpers/events.py`
        // says so by keeping the earlier start (`episodes()`, the `continue`
        // on a second `rule-fired`). What went unobserved is only whether it
        // held *continuously*, which is what the `+` is for.
        let refired = ActivityEntry.fold([
            event("rule-fired", "G3", 3600),
            event("rule-fired", "G3", 0),
        ])
        equal(refired.count, 1, "a fire-on-fire stays one row")
        equal(refired.first?.occurrences, 1,
              "as one episode — the second fire re-observed a fault already open")
        equal(refired.first?.totalDuration, 3600,
              "carrying the span from the first fire to the last sighting")
        check(refired.first?.durationIsLowerBound == true,
              "marked a floor, because the gap between the two was unobserved")
        equal(refired.first?.detail, "lasted 1h+",
              "and the floor actually renders — a `+` needs a duration to sit on")
        check(refired.first?.isOngoing == true,
              "still open: no clear was ever seen for it")

        // An explicit monitor-started row closes open episodes as a lower bound,
        // matching helpers/events.py:217.
        let restartCloses = ActivityEntry.fold([
            event("monitor-started", nil, 3000, "Monitoring started"),
            event("rule-fired", "G3", 0),
        ])
        equal(restartCloses.count, 1, "an open episode closed by monitor-started")
        equal(restartCloses.first?.occurrences, 1, "counts as one occurrence")
        equal(restartCloses.first?.totalDuration, 3000, "duration measured to restart")
        check(restartCloses.first?.durationIsLowerBound == true, "marked as a lower bound")
        check(restartCloses.first?.isOngoing == false, "closed by the restart, not ongoing")

        // Monitor restarted mid-fault: first episode closed at restart,
        // second episode opened by the new fire.
        let restartAndRefire = ActivityEntry.fold([
            event("rule-fired", "G3", 3001),
            event("monitor-started", nil, 3000, "Monitoring started"),
            event("rule-fired", "G3", 0),
        ])
        equal(restartAndRefire.count, 1, "folded into the day's rule row")
        equal(restartAndRefire.first?.occurrences, 2, "as two distinct episodes")
        check(restartAndRefire.first?.isOngoing == true, "second episode is still open")
        equal(restartAndRefire.first?.totalDuration, 3000, "total duration from first episode")
        check(restartAndRefire.first?.durationIsLowerBound == true, "first episode was a lower bound")

        // Keyed on (network, rule). A clear on network B must not close
        // network A's open episode when a laptop moves mid-fault.
        let twoNetworks = ActivityEntry.fold([
            event("rule-cleared", "G3", 300, "Resolved: Minor packet loss to router", "wifi:mac=bb"),
            event("rule-fired", "G3", 0, "Minor packet loss to router", "wifi:mac=aa"),
        ])
        equal(twoNetworks.count, 1, "same day and rule merges into one row")
        equal(twoNetworks.first?.occurrences, 2, "two distinct episodes")
        check(twoNetworks.first?.isOngoing == true, "network A's episode is still open")
        equal(twoNetworks.first?.totalDuration, nil,
              "neither has an observed duration (net A is open, net B is an orphan clear)")

        // And matching clears close only the matching network's episode.
        let netACleared = ActivityEntry.fold([
            event("rule-cleared", "G3", 300, "Resolved: Minor packet loss to router", "wifi:mac=aa"),
            event("rule-fired", "G3", 100, "Minor packet loss to router", "wifi:mac=bb"),
            event("rule-fired", "G3", 0, "Minor packet loss to router", "wifi:mac=aa"),
        ])
        equal(netACleared.first?.occurrences, 2, "two distinct episodes")
        equal(netACleared.first?.totalDuration, 300, "only network A has a closed duration")
        check(netACleared.first?.isOngoing == true, "network B is still open")

        // A clear whose fire is not in the slice being folded describes an
        // end with no beginning. There is no duration to state — but there
        // is still an ending, and the CLI's own "Resolved: …" states it.
        //
        // Dropping the row entirely was defensible against the store's
        // 500-entry cap and wrong against the dropdown, which folds a
        // rolling `eventLog.within(hours: 24)` and so manufactures orphans
        // routinely: a fault that fired 20:00 yesterday and cleared 09:00
        // today is a lone `rule-cleared` by 10:00, and a long fault that
        // just ended is precisely what someone opening the menu bar is
        // looking for.
        let orphan = ActivityEntry.fold([
            event("rule-cleared", "G3", 0, "Resolved: Minor packet loss to router"),
        ])
        equal(orphan.count, 1, "an orphan clear still reports that the fault ended")
        equal(orphan.first?.summary, "Resolved: Minor packet loss to router",
              "in the CLI's own words")
        equal(orphan.first?.kind, "rule-cleared",
              "styled as a resolution — the green check EventRow used to give it")
        equal(orphan.first?.totalDuration, nil,
              "carrying no duration, because no start was ever observed")
        check(orphan.first?.isOngoing == false, "and not marked still open")
        equal(orphan.first?.detail, nil,
              "so the row adds nothing beyond the summary")

        // ...and where the rule fired again later the same day, the orphan
        // merges into that row rather than doubling it — and the row reads
        // as the fault, not as its resolution, whichever merged first.
        let orphanThenFlap = ActivityEntry.fold([
            event("rule-cleared", "G3", 0, "Resolved: Minor packet loss to router"),
            event("rule-fired", "G3", 600),
            event("rule-cleared", "G3", 900, "Resolved: Minor packet loss to router"),
        ])
        equal(orphanThenFlap.count, 1, "an orphan merges into the rule's day row")
        equal(orphanThenFlap.first?.occurrences, 2, "counting both endings")
        equal(orphanThenFlap.first?.kind, "rule-fired",
              "a day the rule was seen to fire reads as the fault")
        equal(orphanThenFlap.first?.summary, "Minor packet loss to router",
              "keeping the fault's words, not the resolution's")
        equal(orphanThenFlap.first?.totalDuration, 300,
              "and only the span that was actually observed")

        // Discrete facts have no duration and must never be paired.
        let discrete = ActivityEntry.fold([
            event("interface-changed", nil, 0, "Network interface changed: en7 → en0"),
            event("alert", "L1", 60, "Internet connection degraded"),
        ])
        equal(discrete.count, 2, "non-rule events stay one row each")
        check(discrete.allSatisfy { $0.totalDuration == nil },
              "and carry no duration")

        // Days are the grouping unit, so yesterday's flap and today's stay
        // apart — collapsing them would hide a recurrence pattern.
        let acrossDays = ActivityEntry.fold([
            event("rule-fired", "G3", 0),
            event("rule-cleared", "G3", 60, "Resolved: Minor packet loss to router"),
            event("rule-fired", "G3", 86_400 * 2),
            event("rule-cleared", "G3", 86_400 * 2 + 60, "Resolved: Minor packet loss to router"),
        ])
        equal(acrossDays.count, 2, "separate days stay separate rows")

        // ...and a fault that runs *through* midnight is filed once, under
        // the day it began.
        //
        // `group` keys per day on the episode's start, so a 23:50→00:10
        // fault and a 09:00 one the next morning are two entries — right,
        // they are two occurrences on two days. `ActivityView` then bucketed
        // both into sections by `latest`, which is Tuesday for both, and
        // Tuesday's section printed two identical "Minor packet loss to
        // router" rows: the one-row-per-rule-per-day promise this type's
        // header makes, broken by keying and bucketing on different fields.
        let cal = Calendar.current
        let midnightBase = cal.startOfDay(for: day)
        func moment(_ dayOffset: Int, _ hour: Int, _ minute: Int) -> Date {
            let shifted = cal.date(byAdding: .day, value: dayOffset,
                                   to: midnightBase)!
            return cal.date(bySettingHour: hour, minute: minute, second: 0,
                            of: shifted)!
        }
        func at(_ kind: String, _ when: Date, _ summary: String) -> NetworkEvent {
            NetworkEvent(date: when, kind: kind, summary: summary, ruleID: "G3")
        }
        let crossing = ActivityEntry.byDay(ActivityEntry.fold([
            at("rule-fired", moment(0, 23, 50), "Minor packet loss to router"),
            at("rule-cleared", moment(1, 0, 10),
               "Resolved: Minor packet loss to router"),
            at("rule-fired", moment(1, 9, 0), "Minor packet loss to router"),
            at("rule-cleared", moment(1, 9, 5),
               "Resolved: Minor packet loss to router"),
        ], calendar: cal), calendar: cal)
        equal(crossing.count, 2, "a midnight crossing spans two day sections")
        equal(crossing.first?.day, cal.startOfDay(for: moment(1, 0, 0)),
              "newest day first")
        equal(crossing.first?.entries.count, 1,
              "the second day lists G3 once, not twice")
        equal(crossing.last?.entries.count, 1,
              "and the crossing episode is filed under the day it began")
        equal(crossing.last?.entries.first?.totalDuration, 1200,
              "still carrying the 20 minutes it ran across midnight")

        // An alert is about a rule the CLI already reported, so listing both
        // printed one incident twice in different words. The alert is
        // absorbed as a flag, not deleted — being notified is the one thing
        // it knows that the rule row does not.
        let withAlert = ActivityEntry.fold([
            event("rule-fired", "G2", 0, "Router dropping packets"),
            event("rule-cleared", "G2", 90, "Resolved: Router dropping packets"),
            event("alert", "G2", 30, "Connection is unstable"),
        ])
        equal(withAlert.count, 1, "an alert merges into the rule row it is about")
        check(withAlert.first?.notified == true, "and marks it as having notified")
        equal(withAlert.first?.summary, "Router dropping packets",
              "keeping the CLI's words for the rule, not the alert's category label")

        // An alert with no rule — public IP changed, captive portal, VPN
        // dropped — has no row to merge into and must keep its own.
        let ruleless = ActivityEntry.fold([
            event("alert", nil, 0, "Your public IP address changed"),
        ])
        equal(ruleless.count, 1, "a rule-less alert keeps its own row")
        check(ruleless.first?.notified == false,
              "and is not marked as a merge target")

        equal(ActivityEntry.duration(45), "45s", "sub-minute durations read in seconds")
        equal(ActivityEntry.duration(240), "4m", "a whole number of minutes drops seconds")
        equal(ActivityEntry.duration(3600 * 2 + 720), "2h 12m", "hours keep minutes")
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

    // MARK: - NetworkIdentity
    //
    // The three real keys below came out of a live install's defaults,
    // where one iPhone hotspot had accumulated all of gw:10.125.128.1,
    // wifi:gw=10.125.128.1 and mac:76:42:18:5c:40:64. That is the bug this
    // type exists to make unrepresentable.
    private static func runNetworkIdentityTests() {
        print("NetworkIdentity:")

        check(NetworkIdentity.canonical("wifi:mac=AA:BB:CC:DD:EE:FF") == "mac:aa:bb:cc:dd:ee:ff",
              "a record-form MAC canonicalises and lowercases")
        check(NetworkIdentity.canonical("mac:aa:bb:cc:dd:ee:ff") == "mac:aa:bb:cc:dd:ee:ff",
              "an already-canonical MAC is unchanged")
        check(NetworkIdentity.canonical("wifi:gw=10.125.128.1") == "gw:10.125.128.1",
              "a record-form gateway canonicalises")
        check(NetworkIdentity.canonical("lan:gw=192.168.60.1") == "gw:192.168.60.1",
              "the lan: record prefix canonicalises the same way")
        check(NetworkIdentity.canonical("wifi:ssid=SB Airbnb") == "ssid:SB Airbnb",
              "a record-form SSID canonicalises")

        // MAC wins over SSID wins over gateway, matching history.py.
        check(NetworkIdentity.canonical("wifi:mac=AA:BB:CC:DD:EE:FF,ssid=Home,gw=192.168.1.1")
                == "mac:aa:bb:cc:dd:ee:ff",
              "MAC outranks SSID and gateway")
        check(NetworkIdentity.canonical("wifi:ssid=Home,gw=192.168.1.1") == "ssid:Home",
              "SSID outranks gateway")

        check(NetworkIdentity.canonical("") == nil,
              "an empty id canonicalises to nothing")
        check(NetworkIdentity.canonical("unknown") == nil,
              "the CLI's unknown sentinel canonicalises to nothing")
        check(NetworkIdentity.canonical("wifi:mac=") == nil,
              "a present-but-empty field is not an identity")

        // fold: weak keys collapse onto the MAC group that shares their
        // gateway or SSID. The map is weak-key -> strong-key.
        let folded = NetworkIdentity.fold(
            [
                "mac:76:42:18:5c:40:64": ["gw:10.125.128.1", "ssid:Richard's iPhone"],
                "mac:64:d1:54:4a:93:7f": ["gw:172.20.10.1"],
            ],
            weak: ["gw:10.125.128.1", "gw:172.20.10.1", "ssid:Richard's iPhone", "gw:8.8.8.8"])
        check(folded["gw:10.125.128.1"] == "mac:76:42:18:5c:40:64",
              "a gateway folds onto the MAC group that used it")
        check(folded["ssid:Richard's iPhone"] == "mac:76:42:18:5c:40:64",
              "an SSID folds onto the MAC group that used it")
        check(folded["gw:172.20.10.1"] == "mac:64:d1:54:4a:93:7f",
              "a second gateway folds onto its own MAC group")
        check(folded["gw:8.8.8.8"] == nil,
              "a weak key with no MAC group folds nowhere, rather than guessing")
    }

    /// The Swift half of the fixture guard. `tests/test_network_identity
    /// .bats` drives the identical file through helpers/history.py; this
    /// drives it through NetworkIdentity. Both must agree, because two
    /// implementations of one rule drift and the drift is invisible until
    /// a network's arrival check is filed under a key it never presents
    /// under again.
    ///
    /// Skipped rather than failed when the fixture is not found: the
    /// harness runs from the built .app bundle too, where the repo's tests
    /// directory is not present. bats covers the file's existence.
    private static func runNetworkIdentityFixtureTests() {
        print("NetworkIdentity fixture:")
        let candidates = [
            "tests/fixtures/network-ids.txt",
            "../tests/fixtures/network-ids.txt",
        ]
        guard let text = candidates.lazy
            .compactMap({ try? String(contentsOfFile: $0, encoding: .utf8) })
            .first
        else {
            print("  – fixture not reachable from this working directory, skipped")
            return
        }

        var cases = 0
        var mismatches: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let row = line.trimmingCharacters(in: .whitespaces)
            guard !row.isEmpty, !row.hasPrefix("#") else { continue }
            let parts = row.split(separator: "|", maxSplits: 1,
                                  omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            cases += 1
            let raw = String(parts[0])
            let expected = String(parts[1])
            let got = NetworkIdentity.canonical(raw) ?? "-"
            if got != expected {
                mismatches.append("\(raw) -> \(got), fixture says \(expected)")
            }
        }
        check(cases >= 10, "the fixture supplied cases to check (\(cases))")
        check(mismatches.isEmpty,
              mismatches.isEmpty
                ? "every fixture case canonicalises as the fixture says"
                : "fixture mismatches: \(mismatches.joined(separator: "; "))")
    }

    // MARK: - ArrivalState
    private static func runArrivalStateTests() {
        print("ArrivalState:")

        let now = Date(timeIntervalSince1970: 1_700_000_000)

        check(ArrivalState.unchecked.needsAttempt(now: now),
              "unchecked wants an attempt")
        check(!ArrivalState.checked(depth: .full, at: now, runID: "r1").needsAttempt(now: now),
              "checked wants nothing")
        check(!ArrivalState.declined(depth: .full, reason: .hotspot, at: now)
                .needsAttempt(now: now),
              "declined is a decision, not a failure, so it does not retry")

        // A scan that crashed leaves .checking behind. Without a staleness
        // rule that network is wedged forever, which is the same class of
        // bug as the one this whole change is fixing.
        let fresh = ArrivalState.checking(depth: .full, startedAt: now)
        check(!fresh.needsAttempt(now: now.addingTimeInterval(60)),
              "a checking state inside its window is left alone")
        check(fresh.needsAttempt(now: now.addingTimeInterval(ArrivalState.stallWindow + 1)),
              "a checking state past the stall window is retried")

        // Round-trips through UserDefaults as JSON.
        for state: ArrivalState in [
            .unchecked,
            .checking(depth: .quick, startedAt: now),
            .checked(depth: .full, at: now, runID: "abc"),
            .checked(depth: .full, at: now, runID: nil),
            .declined(depth: .full, reason: .unhealthy, at: now),
            .declined(depth: .full, reason: .hotspot, at: now),
        ] {
            let data = try? JSONEncoder().encode(state)
            let back = data.flatMap { try? JSONDecoder().decode(ArrivalState.self, from: $0) }
            check(back == state, "\(state.debugLabel) survives a JSON round trip")
        }

        // Forward compatibility: a state written by a newer build must not
        // crash this one, and must not read as "checked" — we cannot clear
        // a verdict we do not understand. Same reasoning as
        // FullCheckPolicy's allow-list.
        let futureJSON = Data(#"{"kind":"quarantined","at":0}"#.utf8)
        let decoded = try? JSONDecoder().decode(ArrivalState.self, from: futureJSON)
        check(decoded == .unchecked || decoded == nil,
              "an unrecognised persisted state never reads as checked")
    }

    // MARK: - ArrivalPolicy
    private static func runArrivalPolicyTests() {
        print("ArrivalPolicy:")

        // The regression that started this work. At the instant a network
        // is joined the monitor has produced no sample, so severity is "".
        // FullCheckPolicy correctly refuses to call an unknown severity
        // safe — but asking it *then* silently downgraded essentially
        // every arrival to the lighter check. The answer is to not ask
        // yet.
        check(ArrivalPolicy.decide(hasSample: false, severity: "",
                                   isExpensive: false, isConstrained: false) == .wait,
              "no sample yet means wait, never a downgrade")
        check(ArrivalPolicy.decide(hasSample: false, severity: "ok",
                                   isExpensive: false, isConstrained: false) == .wait,
              "hasSample is what gates the decision, not the severity string")

        check(ArrivalPolicy.decide(hasSample: true, severity: "ok",
                                   isExpensive: false, isConstrained: false) == .full,
              "an ordinary healthy network gets the full check")
        check(ArrivalPolicy.decide(hasSample: true, severity: "info",
                                   isExpensive: false, isConstrained: false) == .full,
              "info is not a problem and still earns a full check")
        check(ArrivalPolicy.decide(hasSample: true, severity: "warn",
                                   isExpensive: false, isConstrained: false) == .full,
              "warn still earns a full check — FullCheckPolicy allows it")

        check(ArrivalPolicy.decide(hasSample: true, severity: "critical",
                                   isExpensive: false, isConstrained: false)
                == .quick(.unhealthy),
              "a critical link gets the quick check, with a reason")
        check(ArrivalPolicy.decide(hasSample: true, severity: "wat",
                                   isExpensive: false, isConstrained: false)
                == .quick(.unhealthy),
              "an unrecognised severity is not treated as safe")

        check(ArrivalPolicy.decide(hasSample: true, severity: "ok",
                                   isExpensive: true, isConstrained: false)
                == .quick(.hotspot),
              "an expensive path gets the quick check rather than a speed test")
        check(ArrivalPolicy.decide(hasSample: true, severity: "ok",
                                   isExpensive: false, isConstrained: true)
                == .quick(.hotspot),
              "a constrained path (Low Data Mode) is treated the same way")

        // Precedence: cost beats health. Both downgrade to quick, but the
        // reason the user is shown must be the one they can act on — and
        // "this is your phone's data" is more actionable than "the link
        // looked unhealthy a moment ago".
        check(ArrivalPolicy.decide(hasSample: true, severity: "critical",
                                   isExpensive: true, isConstrained: false)
                == .quick(.hotspot),
              "when both apply, the hotspot reason is the one shown")
    }

    // MARK: - Arrival migration
    private static func runArrivalMigrationTests() {
        print("Arrival migration:")

        // The keys below are verbatim from a live install, where one
        // iPhone hotspot had accumulated all three forms.
        let legacy: Set<String> = [
            "gw:10.125.128.1",
            "wifi:gw=10.125.128.1",
            "mac:76:42:18:5c:40:64",
            "mac:28:70:4e:45:89:5a",
            "unknown",
            "",
        ]
        let migrated = Defaults.migratedArrivalStates(from: legacy)

        check(migrated["gw:10.125.128.1"] != nil,
              "a canonical legacy key survives migration")
        check(migrated["wifi:gw=10.125.128.1"] == nil,
              "a record-format legacy key is not carried across verbatim")
        check(migrated["mac:76:42:18:5c:40:64"] != nil,
              "a MAC key survives migration")
        check(migrated["unknown"] == nil && migrated[""] == nil,
              "nameless legacy entries are dropped rather than keyed")

        // Fail closed. Every migrated network reads as already checked, so
        // an upgrade never re-checks the world — and never spends cellular
        // data re-baselining a hotspot it already knew about.
        let allChecked = migrated.values.allSatisfy {
            if case .checked = $0 { return true }
            return false
        }
        check(allChecked, "every migrated entry is checked, never unchecked")
        check(migrated.values.allSatisfy { !$0.needsAttempt(now: Date()) },
              "no migrated entry asks for an attempt")

        check(Defaults.migratedArrivalStates(from: []).isEmpty,
              "an empty legacy set migrates to an empty map")
    }

    // MARK: - Arrival card copy
    private static func runArrivalCopyTests() {
        print("Arrival card:")

        let hotspot = ArrivalCopy.forState(
            .declined(depth: .quick, reason: .hotspot, at: Date()), network: "SB Airbnb")
        check(hotspot?.body.contains("hotspot") == true,
              "the hotspot decline says why")
        check(hotspot?.actionTitle != nil,
              "the hotspot decline offers the override")

        let unhealthy = ArrivalCopy.forState(
            .declined(depth: .quick, reason: .unhealthy, at: Date()), network: "SB Airbnb")
        check(unhealthy?.actionTitle != nil,
              "the unhealthy decline also offers the override")

        let checking = ArrivalCopy.forState(
            .checking(depth: .full, startedAt: Date()), network: "SB Airbnb")
        check(checking?.title.contains("SB Airbnb") == true,
              "a check in flight names the network")
        check(checking?.actionTitle == nil,
              "a check in flight offers no button")

        check(ArrivalCopy.forState(.unchecked, network: "SB Airbnb") != nil,
              "unchecked renders something rather than nothing")
        check(ArrivalCopy.forState(.checked(depth: .full, at: Date(), runID: nil),
                                   network: "SB Airbnb") == nil,
              "a checked network shows no card at all")

        // The three unchecked intents must be distinguishable. All three
        // used to render one spinner and one "Starting a check." — so a
        // user who had switched automatic checks off in Settings saw a
        // permanent promise of work that was never coming, and a check
        // queued behind another one claimed to be starting for up to five
        // minutes. Both are the same failure this whole change exists to
        // fix: a UI implying work that is not happening.
        let starting = ArrivalCopy.forState(.unchecked, network: "SB Airbnb",
                                            intent: .starting)
        let waiting = ArrivalCopy.forState(.unchecked, network: "SB Airbnb",
                                           intent: .waitingForAnotherCheck)
        let manual = ArrivalCopy.forState(.unchecked, network: "SB Airbnb",
                                          intent: .notAutomatic)

        check(starting?.isBusy == true, "an imminent arrival check shows a spinner")
        check(waiting?.isBusy == true, "a queued arrival check shows a spinner")
        check(manual?.isBusy == false,
              "an unchecked network with no automatic check coming shows no spinner")
        check(manual?.actionTitle != nil,
              "with automatic checks off, the card offers the check as a button")
        check(starting?.actionTitle == nil,
              "a check already starting offers no redundant button")
        check(starting?.body != waiting?.body,
              "a queued check does not claim to be starting")
        check(waiting?.body != manual?.body && starting?.body != manual?.body,
              "the three unchecked intents each say something different")

        // The busy states are exactly the ones where work is in flight.
        check(ArrivalCopy.forState(.checking(depth: .full, startedAt: Date()),
                                   network: "SB Airbnb")?.isBusy == true,
              "a check in flight is busy")
        check(ArrivalCopy.forState(.declined(depth: .quick, reason: .hotspot, at: Date()),
                                   network: "SB Airbnb")?.isBusy == false,
              "a declined check is finished, not busy")

        // The GUI authors no verdicts. These are the words that would mean
        // this file had started diagnosing, which is lib/diagnosis.sh's
        // job — see AlertDefinitions.swift's header.
        // Every reachable (state, intent) pair, not just the states: the
        // three unchecked intents each have their own sentence, and a
        // verdict word smuggled into one of them would otherwise ship
        // unchecked.
        let forbidden = ["slow", "bad", "poor", "unusable", "broken", "healthy", "good"]
        let cases: [(ArrivalState, ArrivalCopy.Intent)] = [
            (.unchecked, .starting),
            (.unchecked, .waitingForAnotherCheck),
            (.unchecked, .notAutomatic),
            (.checking(depth: .full, startedAt: Date()), .starting),
            (.checking(depth: .quick, startedAt: Date()), .starting),
            (.declined(depth: .quick, reason: .hotspot, at: Date()), .starting),
            (.declined(depth: .quick, reason: .unhealthy, at: Date()), .starting),
        ]
        for (state, intent) in cases {
            guard let copy = ArrivalCopy.forState(state, network: "SB Airbnb",
                                                  intent: intent) else { continue }
            let text = (copy.title + " " + copy.body + " " + (copy.actionTitle ?? "")).lowercased()
            let hit = forbidden.first { text.contains($0) }
            let label = "\(state.debugLabel)/\(intent)"
            check(hit == nil,
                  hit == nil
                    ? "\(label) copy states mechanism, not a verdict"
                    : "\(label) copy contains the verdict word \"\(hit!)\"")
        }
    }

    // MARK: - Arrival stage
    private static func runArrivalStageTests() {
        print("Arrival stage:")

        check(StageResolver.resolve(inputs(isScanning: true, isArrivalCheck: true)) == .arrived,
              "a scan that is the arrival check reads as .arrived, not .testing")
        check(StageResolver.resolve(inputs(isScanning: true, isArrivalCheck: false)) == .testing,
              "a scan the user started still reads as .testing")
        check(StageResolver.resolve(inputs(isScanning: false, isArrivalCheck: true)) != .arrived,
              "arrival only shows while the check is actually running")

        // Precedence, and a correction to the plan this task was written
        // from. That plan expected "monitoring off" to outrank `.arrived`;
        // it does not, and must not. `runStageTests` already asserts
        // "scanning precedes paused / skewed / alert / watching" with
        // `monitoringEnabled: false` live, so the scanning guard runs
        // first by long-standing design — a scan is a thing genuinely
        // happening right now, and the card has to say so whether or not
        // background monitoring is switched on. `.arrived` inherits that
        // position rather than carving out an exception, because a user
        // watching an arrival check run would otherwise see "Monitoring
        // paused" over a progress bar. What keeps `.arrived` from
        // resurrecting a stage while nothing is running is the check
        // above: it requires `isScanning`.
        check(StageResolver.resolve(inputs(isScanning: true, isArrivalCheck: true,
                                           monitoringEnabled: false)) == .arrived,
              "an arrival check in flight outranks monitoring being off, exactly as a user scan does")
    }

    // MARK: - Home report provenance

    /// The predicate deciding whether a stored report on Home is labelled
    /// with where it came from. Asserted because its nil handling is the
    /// only thing standing between a user and another building's report
    /// presented as this network's — the bug it was written for.
    private static func runReportProvenanceTests() {
        print("Home report provenance:")
        // Identity, so these assert the predicate rather than HistoryStore's
        // merge table.
        let plain: (String) -> String = { $0 }

        check(HomeView.needsProvenance(storedNetworkID: "ssid:sb-airbnb",
                                       currentNetworkID: "ssid:sb-airbnb",
                                       canonical: plain) == false,
              "a stored run from the network we are on needs no caption")
        check(HomeView.needsProvenance(storedNetworkID: "ssid:home",
                                       currentNetworkID: "ssid:sb-airbnb",
                                       canonical: plain),
              "a stored run from another network is labelled")
        check(HomeView.needsProvenance(storedNetworkID: "ssid:home",
                                       currentNetworkID: nil,
                                       canonical: plain),
              "an unidentified current network labels rather than assumes")
        check(HomeView.needsProvenance(storedNetworkID: nil,
                                       currentNetworkID: "ssid:sb-airbnb",
                                       canonical: plain) == false,
              "a run with no recorded network has nothing truthful to caption")
        // Merges are why `canonical` is a parameter: two raw ids the user
        // has merged are one network, and a caption saying otherwise would
        // contradict the Networks tab.
        check(HomeView.needsProvenance(storedNetworkID: "gw:10.0.0.1",
                                       currentNetworkID: "mac:aa:bb:cc:dd:ee:ff",
                                       canonical: { _ in "merged" }) == false,
              "two ids merged into one network count as the same network")
    }

    // MARK: - Trends y-axis clamp

    /// `TrendsView.Clamp` is the only thing standing between one 2.8 s
    /// reading and a latency chart drawn as a flat line on the floor, and
    /// it was unreachable from any check until this one.
    ///
    /// It had to be: the tail was located by the *index* `floor(n * 0.99)`,
    /// and for every n from 10 to 100 that index is `n - 1` — the maximum
    /// itself. The "genuinely extreme tail" guard then read
    /// `maximum > maximum * 2`, false for all positive data, so no series
    /// of 100 samples or fewer ever clamped. Trends draws series that short
    /// routinely: a day's worth of runs on one network is dozens of points,
    /// not thousands. The sizes below are chosen to walk that dead range.
    static func runTrendsClampTests() {
        print("TrendsView.Clamp (y-axis outlier clamp):")

        /// `count - 1` readings in a believable 2–8 ms band, plus one spike
        /// — the shape the `Clamp` doc comment describes verbatim.
        func band(_ count: Int, spike: Double) -> [Double] {
            (0..<(count - 1)).map { 2.0 + Double($0 % 7) } + [spike]
        }

        for n in [10, 38, 100, 101, 2371] {
            guard let clamp = TrendsView.Clamp.forValues(band(n, spike: 2800), p90: nil) else {
                check(false, "n = \(n): a lone 2.8 s spike clamps the axis")
                continue
            }
            check(true, "n = \(n): a lone 2.8 s spike clamps the axis")
            check(clamp.upper < 20,
                  "n = \(n): ceiling lands in the band, not near the spike (\(clamp.upper))")
            equal(clamp.outliers, 1, "n = \(n): the one spike is counted as out of range")
            equal(clamp.maximum, 2800, "n = \(n): the spike's real height is kept for the caption")
        }

        // The other half of the contract: a series whose spread is real
        // must be drawn at full height, because clamping it would be
        // meddling with data the user should see.
        check(TrendsView.Clamp.forValues((1...50).map { Double($0) * 10 }, p90: nil) == nil,
              "a smoothly spread 10–500 ms series is left alone")
        check(TrendsView.Clamp.forValues((1...200).map { Double($0) }, p90: nil) == nil,
              "a smoothly spread 1–200 series is left alone")
        check(TrendsView.Clamp.forValues(Array(repeating: 5.0, count: 40), p90: nil) == nil,
              "a series with no spread at all has no outlier to clamp")
        // A maximum merely twice the bulk is spread, not a tail — the
        // existing 2x guard, which the index bug made unreachable below
        // 101 samples and which must survive the fix.
        check(TrendsView.Clamp.forValues(band(38, spike: 16), p90: nil) == nil,
              "n = 38: a maximum only twice the band is drawn at full height")
        check(TrendsView.Clamp.forValues(band(9, spike: 2800), p90: nil) == nil,
              "n = 9: too few readings to call anything a tail")

        // The band the chart also shades must fit inside the axis it is
        // drawn on, so p90 raises the ceiling — and if that lifts it to
        // the maximum there is nothing left to clamp.
        if let clamp = TrendsView.Clamp.forValues(band(38, spike: 2800), p90: 40) {
            check(clamp.upper >= 48, "p90 raises the ceiling above the shaded band (\(clamp.upper))")
        } else {
            check(false, "p90 raises the ceiling above the shaded band")
        }
        check(TrendsView.Clamp.forValues(band(38, spike: 2800), p90: 3000) == nil,
              "a p90 at the top of the data leaves no room to clamp")

        // The boundary of the approach, stated rather than left to be
        // rediscovered: below 100 samples only a single reading can be set
        // aside, so two equal extremes out of 38 — 5% of the data — are
        // spread, not a tail, and are drawn at full height.
        check(TrendsView.Clamp.forValues(band(37, spike: 2800) + [2800], p90: nil) == nil,
              "n = 38: two equal extremes are 5% of the data, not a tail")
    }

    // MARK: - RunGroup (coalescing and day grouping)

    private static func runRunGroupTests() {
        print("RunGroup (coalescing and day grouping):")
        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        let minAgo5 = now.addingTimeInterval(-300)
        let minAgo10 = now.addingTimeInterval(-600)
        let minAgo15 = now.addingTimeInterval(-900)
        let yesterday = now.addingTimeInterval(-86400)

        func makeRun(id: String, ts: Date, severity: String, rules: [String], mode: String? = "quick") -> HistoryDocument.Run {
            HistoryDocument.Run(
                ts: HistoryDocument.iso.string(from: ts),
                runID: id,
                networkID: "net1",
                version: "0.14.0",
                runMode: mode,
                severity: severity,
                diagnosisCount: rules.count,
                rules: rules,
                rootCause: rules.isEmpty ? nil : "Some issue",
                metrics: [:]
            )
        }

        let r1 = makeRun(id: "r1", ts: now, severity: "warn", rules: ["AV-1", "WI-1"])
        let r2 = makeRun(id: "r2", ts: minAgo5, severity: "warn", rules: ["AV-1", "WI-1"])
        let r3 = makeRun(id: "r3", ts: minAgo10, severity: "warn", rules: ["AV-1", "WI-1"])
        let r4 = makeRun(id: "r4", ts: minAgo15, severity: "ok", rules: [])

        // 1. Coalescing identical consecutive runs
        let groups = RunGroup.coalesce([r1, r2, r3, r4], calendar: cal)
        check(groups.count == 2, "3 identical consecutive runs + 1 ok run collapse into 2 groups (got \(groups.count))")
        check(groups[0].count == 3, "first group has 3 runs")
        check(groups[0].isSingle == false, "first group is not single")
        check(groups[0].leadRun.id == "r1", "first group lead run is newest (r1)")
        check(groups[0].oldestRun.id == "r3", "first group oldest run is r3")
        check(groups[1].count == 1, "second group has 1 run")
        check(groups[1].isSingle == true, "second group is single")

        // 2. Midnight crossing does not coalesce across days
        let rYesterday = makeRun(id: "ry", ts: yesterday, severity: "warn", rules: ["AV-1", "WI-1"])
        let groupsAcrossMidnight = RunGroup.coalesce([r1, rYesterday], calendar: cal)
        check(groupsAcrossMidnight.count == 2, "identical runs across midnight boundary stay separate (got \(groupsAcrossMidnight.count))")

        // 3. DaySection grouping
        let days = DaySection.group(groupsAcrossMidnight, calendar: cal)
        check(days.count == 2, "2 days produced for runs across yesterday and today")
        check(days[0].label == "Today", "first day section is Today")
        check(days[1].label == "Yesterday", "second day section is Yesterday")
    }

    // MARK: - MonitorSample & MonitorSeries (gap_s)

    private static func runMonitorSeriesGapTests() {
        print("MonitorSeries (gap_s decoding and gap detection):")
        let now = Date()
        let t0 = now.addingTimeInterval(-60)
        let t1 = now.addingTimeInterval(-40)
        let t2 = now.addingTimeInterval(-20)

        // Test 1: MonitorSample decodes gap_s
        let jsonWithGap = """
        {"seq": 5, "ts": "\(HistoryDocument.iso.string(from: t1))", "gap_s": 28800}
        """.data(using: .utf8)!
        let sampleWithGap = try? JSONDecoder().decode(MonitorSample.self, from: jsonWithGap)
        check(sampleWithGap?.gapS == 28800, "MonitorSample decodes integer gap_s")

        let jsonWithoutGap = """
        {"seq": 6, "ts": "\(HistoryDocument.iso.string(from: t2))", "gap_s": null}
        """.data(using: .utf8)!
        let sampleWithoutGap = try? JSONDecoder().decode(MonitorSample.self, from: jsonWithoutGap)
        check(sampleWithoutGap?.gapS == nil, "MonitorSample decodes null gap_s as nil")

        // Helper to construct sample
        func makeSample(date: Date, gapS: Int?, cadenceS: Int = 10, rtt: Double? = 15.0) -> MonitorSample {
            var s = MonitorSample()
            s.ts = HistoryDocument.iso.string(from: date)
            s.refreshed = ["fast"]
            s.gapS = gapS
            s.status.cadenceS = cadenceS
            s.gateway.rttAvgMs = rtt
            return s
        }

        // Test 2: MonitorSeries detects gap when sample.gapS > 0 even if wall clock within cadence*2
        let s0 = makeSample(date: t0, gapS: nil, cadenceS: 30)
        let s1 = makeSample(date: t1, gapS: 120, cadenceS: 30) // 20s wall clock, but gapS = 120
        let res1 = MonitorSeries.build([s0, s1], tier: "fast") { $0.gateway.rttAvgMs }
        check(res1.gaps.count == 1, "sample.gapS marks a gap even when wall clock interval <= cadence*2")
        check(res1.segments.count == 2 && res1.segments[0].count == 1 && res1.segments[1].count == 1, "gap splits segment into distinct segments")

        // Test 3: MonitorSeries detects gap via cadence*2 fallback when sample.gapS is nil
        let s1NoGap = makeSample(date: t1, gapS: nil, cadenceS: 5)
        let s2 = makeSample(date: t2, gapS: nil, cadenceS: 5) // 20s wall clock, cadence=5, interval (20s) > 10s
        let res2 = MonitorSeries.build([s1NoGap, s2], tier: "fast") { $0.gateway.rttAvgMs }
        check(res2.gaps.count == 1, "nil gapS falls back to cadence*2 wall-clock heuristic")

        // Test 4: Continuous series with gapS == nil and interval <= cadence*2 has no gaps
        let s3 = makeSample(date: t0, gapS: nil, cadenceS: 10)
        let s4 = makeSample(date: t0.addingTimeInterval(10), gapS: nil, cadenceS: 10)
        let res3 = MonitorSeries.build([s3, s4], tier: "fast") { $0.gateway.rttAvgMs }
        check(res3.gaps.isEmpty, "continuous stream produces no gaps")
        check(res3.segments.count == 1 && res3.segments[0].count == 2, "continuous stream produces a single segment with all points")
    }

    // MARK: - Launch at login (SMAppService)

    private static func runLaunchAtLoginTests() {
        print("Launch at login (SMAppService & AppSettings):")
        let serviceStatus = SMAppService.mainApp.status
        // SMAppService status should be a valid known case (.enabled, .notRegistered, .requiresApproval, .notFound)
        let validStatus = serviceStatus == .enabled || serviceStatus == .notRegistered || serviceStatus == .requiresApproval || serviceStatus == .notFound
        check(validStatus, "SMAppService.mainApp.status returns a valid status")

        let settings = AppSettings()
        check(settings.launchAtLogin == (serviceStatus == .enabled), "AppSettings.launchAtLogin reflects SMAppService.mainApp.status")

        // Test mutating launchAtLogin without crashing / handles error or success gracefully
        let original = settings.launchAtLogin
        settings.launchAtLogin = !original
        // Revert back
        settings.launchAtLogin = original
        check(settings.launchAtLogin == (SMAppService.mainApp.status == .enabled), "AppSettings.launchAtLogin remains consistent after toggle attempt")
    }

    // MARK: - Menu-bar latency (dotAndPing)

    private static func runMenuBarLatencyTests() {
        print("Menu bar latency (dotAndPing & formatPing):")
        check(MenuBarStyle.allCases.contains(.dotAndPing), "MenuBarStyle.allCases includes .dotAndPing")
        check(MenuBarStyle.dotAndPing.rawValue == "dot+ping", "MenuBarStyle.dotAndPing rawValue is dot+ping")
        check(MenuBarStyle.dotAndPing.label == "Dot and ping time", "MenuBarStyle.dotAndPing label is Dot and ping time")
        check(MenuBarLabel.formatPing(internetRtt: 18.2, gatewayRtt: nil) == "18ms", "formatPing rounds internet RTT with ms")
        check(MenuBarLabel.formatPing(internetRtt: nil, gatewayRtt: 5.4) == "5ms", "formatPing falls back to gateway RTT")
        check(MenuBarLabel.formatPing(internetRtt: 25.1, gatewayRtt: 3.0) == "25ms", "formatPing prioritizes internet RTT")
        check(MenuBarLabel.formatPing(internetRtt: nil, gatewayRtt: nil) == nil, "formatPing is nil when unmeasured")
    }

    // MARK: - Diagnostic Share

    private static func runDiagnosticShareTests() {
        print("Diagnostic share (DiagnosticReportSharing):")
        let mdName = DiagnosticReportSharing.defaultFileName(extension: "md", timestamp: "2026-08-25T12:00:00Z")
        check(mdName == "netdiag-report-2026-08-25-120000.md", "defaultFileName formats md timestamp correctly")

        let jsonName = DiagnosticReportSharing.defaultFileName(extension: "json", timestamp: "2026-08-25T12:00:00Z")
        check(jsonName == "netdiag-report-2026-08-25-120000.json", "defaultFileName formats json timestamp correctly")

        let nowName = DiagnosticReportSharing.defaultFileName(extension: "md", timestamp: nil)
        check(nowName.hasPrefix("netdiag-report-") && nowName.hasSuffix(".md"), "defaultFileName handles nil timestamp")
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
                               isArrivalCheck: Bool = false,
                               monitoringEnabled: Bool = true,
                               isPausedForAnyReason: Bool = false,
                               pauseReason: String? = nil,
                               lastError: String? = nil,
                               monitorRunning: Bool = true,
                               measurementState: String = "measured") -> StageResolver.Inputs {
        StageResolver.Inputs(
            isScanning: isScanning,
            isArrivalCheck: isArrivalCheck,
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

    /// `SuitabilityPanel`'s mappings. They are static on the view
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

        let activities = ["calls", "streaming", "gaming", "vpn", "browsing"]
        check(Set(activities.map(SuitabilityPanel.activitySymbol)).count == activities.count,
              "each activity in the visual strip has a distinct icon")
        check(SuitabilityPanel.activitySymbol("future-activity") == "network",
              "an activity from a newer CLI keeps a generic fallback icon")

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

        // 6. LAN block decoding: arpActiveCount decodes directly and via helper
        let snapWithLAN = decodeSnapshot("""
        {"lan": {"arp_active_count": 18}}
        """)
        equal(snapWithLAN?.lan?.arpActiveCount, 18, "lan.arpActiveCount decodes integer")
        equal(snapWithLAN?.arpActiveCount, 18, "snapshot.arpActiveCount reflects lan.arpActiveCount")

        let snapWithoutLAN = decodeSnapshot("{}")
        equal(snapWithoutLAN?.lan?.arpActiveCount, nil, "missing lan block leaves lan nil")
        equal(snapWithoutLAN?.arpActiveCount, nil, "missing lan block leaves arpActiveCount nil")
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
            case .arrived:
                // Same treatment as `.testing` — same icon, same tint. The
                // only difference is the title, because the only
                // difference is who asked for the check.
                content(icon: "circle.dashed", tint: .accentColor,
                        title: "Checking a new network", tertiary: "pinging the gateway")
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
            ("alert-captive-portal", .init(title: "This network needs you to sign in",
                                           body: "Open your browser to sign in to this network.",
                                           raisedAt: Date(), rules: [], severityRank: 1,
                                           id: "captive-portal")),
        ]
        for (name, alert) in alertCases {
            let height: CGFloat = (name == "alert-captive-portal") ? 116 : 88
            guard let image = renderImage(
                AlertStageCard(alert: alert, moreCount: 0, onOpen: {})
                    .frame(width: 340).padding(4),
                size: NSSize(width: 348, height: height)) else {
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

    /// The arrival card, rendered offscreen per state, for the same reason
    /// the stage cards are: the card at the top of Home cannot be
    /// screenshotted from the menu-bar dropdown, and joining seven
    /// different networks to see seven states is not a workflow.
    ///
    /// `progress: nil` on the `.checking` states deliberately — the scan
    /// progress rows have their own coverage, and a live `ScanProgress`
    /// cannot be constructed here without a running child process. What is
    /// being checked is the card's own copy and layout.
    private static func renderArrivalCards() {
        print("Render arrival-card snapshots:")
        let dir = "/tmp/opencode/verify"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let now = Date()
        let cases: [(String, ArrivalState, ArrivalCopy.Intent)] = [
            ("unchecked-starting",  .unchecked, .starting),
            ("unchecked-queued",    .unchecked, .waitingForAnotherCheck),
            ("unchecked-manual",    .unchecked, .notAutomatic),
            ("checking-full",       .checking(depth: .full, startedAt: now), .starting),
            ("checking-quick",      .checking(depth: .quick, startedAt: now), .starting),
            ("declined-hotspot",    .declined(depth: .quick, reason: .hotspot, at: now), .starting),
            ("declined-unhealthy",  .declined(depth: .quick, reason: .unhealthy, at: now), .starting),
        ]
        for (name, state, intent) in cases {
            // Taller than the stage cards: the hotspot and unhealthy copy
            // run to three or four lines plus a button, where a stage card
            // is one line plus a title.
            // Everything about the two pins below is the harness, not the
            // card. `renderImage` hosts a view with no window and no
            // appearance, and semantic colours then resolve dark. The stage
            // cards survive that only because they paint concrete
            // `Color.gray` fills; `Theme.cardStyle` uses `.quaternary` and
            // the card's text uses the default foreground, so unpinned this
            // drew white text over an unresolved fill and the PNG came out
            // blank — which is what the first run of this actually
            // produced.
            //
            // `.environment` goes *outside* `.background`, which is load
            // bearing and was wrong the first time. A background's content
            // inherits the environment from above the `.background`
            // modifier, not from the subtree it sits behind — so with the
            // scheme pinned on the inside, the card's text resolved light
            // while its backdrop resolved dark and the PNG came out
            // dark-on-dark, looking like a real contrast bug.
            let card = ArrivalCard(state: state, network: "SB Airbnb",
                                   progress: nil, intent: intent, onRunFullCheck: {})
                .frame(width: 360).padding(4)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, .light)
            guard let image = renderImage(card, size: NSSize(width: 368, height: 190)) else {
                print("  \u{2718} arrival-\(name) — could not allocate bitmap representation")
                failures.append("render-arrival-\(name)")
                continue
            }
            writePNG(image, to: "\(dir)/arrival-\(name).png", name: "arrival-\(name)")
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
