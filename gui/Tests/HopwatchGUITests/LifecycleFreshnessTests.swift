import Foundation
import Observation
import Testing
@testable import HopwatchGUI

@Suite struct LifecycleFreshnessTests {
    private actor ProbeOutcomes {
        private(set) var calls = 0
        func next() -> Bool {
            calls += 1
            return calls == 1
        }
    }

    private final class ObservationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var changed = false
        func mark() { lock.lock(); changed = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return changed }
    }

    private func sample(_ id: String, linkUp: Bool = true) -> MonitorSample {
        var value = MonitorSample()
        value.ts = ISO8601DateFormatter().string(from: Date())
        value.network = .init(id: id, label: id, groupId: id)
        value.link = .init(up: linkUp, type: "wifi", gateway: "192.168.1.1")
        value.status = .init(severity: linkUp ? "ok" : "critical",
                             measurement: linkUp ? "measured" : "link-down", cadenceS: 5)
        value.refreshed = ["fast"]
        return value
    }

    private func result(_ id: String, startedAt: Date = Date(), withSpeed: Bool = false) -> RunResult {
        var snapshot = RunSnapshot()
        snapshot.network = .init(id: id, groupId: id)
        if withSpeed { snapshot.speedtest = .init(downMbps: 90, upMbps: 12) }
        return RunResult(snapshot: snapshot, rawJSON: "{}", exitCode: 0,
                         startedAt: startedAt, finishedAt: Date())
    }

    @Test @MainActor func monitorlessScanRemainsCurrentAfterItsPauseEnds() {
        let coordinator = HopwatchCoordinator()
        let run = result("ssid:cafe", startedAt: Date().addingTimeInterval(-2))
        coordinator.adoptSessionStateForTesting(latestRun: run)
        coordinator.monitor.pause(reason: "a check is running")
        coordinator.monitor.resume(reason: "a check is running")
        #expect(coordinator.monitor.awaitingSince == nil)
        #expect(coordinator.confirmedNetworkID == "ssid:cafe")
    }

    @Test @MainActor func sampleIdentityChangeInvalidatesEvenWhenReturningToFirstNetwork() {
        let coordinator = HopwatchCoordinator()
        let a = sample("ssid:a")
        coordinator.monitor.adoptGallerySample(a)
        coordinator.reconcileNetworkIdentity(for: a)
        let before = coordinator.connectionGeneration
        let b = sample("ssid:b")
        coordinator.monitor.adoptGallerySample(b)
        coordinator.reconcileNetworkIdentity(for: b)
        #expect(coordinator.connectionGeneration == before + 1)
        #expect(coordinator.liveSample?.network.historyJoinID == "ssid:b")
        let again = sample("ssid:a")
        coordinator.monitor.adoptGallerySample(again)
        coordinator.reconcileNetworkIdentity(for: again)
        #expect(coordinator.connectionGeneration == before + 2)
        #expect(coordinator.liveSample?.network.historyJoinID == "ssid:a")
    }

    @Test @MainActor func lastKnownNoLinkSurvivesMonitorStop() {
        let coordinator = HopwatchCoordinator()
        coordinator.monitor.adoptGallerySample(sample("ssid:a", linkUp: false))
        coordinator.monitor.stop()
        #expect(coordinator.linkIsDown)
    }

    @Test func routerProbeRepeatsForSameAddressOnNewConnection() async {
        let outcomes = ProbeOutcomes()
        let store = RouterAdminProbeStore(probe: { _ in await outcomes.next() })
        #expect(await store.checkAvailability(for: "192.168.1.1", generation: 1))
        #expect(await store.checkAvailability(for: "192.168.1.1", generation: 1))
        #expect(!(await store.checkAvailability(for: "192.168.1.1", generation: 2)))
        #expect(await outcomes.calls == 2)
    }

    @Test @MainActor func speedOnlyIdentityCanBeEstablishedWithoutMonitor() {
        let coordinator = HopwatchCoordinator()
        coordinator.adoptAcceptedScanIdentity(result("ssid:cafe", withSpeed: true))
        #expect(coordinator.confirmedNetworkID == "ssid:cafe")
        #expect(coordinator.currentSpeedTest?.speed.downMbps == 90)
    }

    @Test @MainActor func ageDrivenTickNotifiesNoLinkAndScanReaders() {
        let coordinator = HopwatchCoordinator()
        coordinator.monitor.adoptGallerySample(sample("ssid:a", linkUp: false))
        let noLinkChange = ObservationFlag()
        withObservationTracking({ _ = coordinator.linkIsDown }) { noLinkChange.mark() }
        let scanChange = ObservationFlag()
        withObservationTracking({ _ = coordinator.freshNetworkRunSnapshot }) { scanChange.mark() }
        coordinator.tickAgeDrivenState()
        #expect(noLinkChange.value)
        #expect(scanChange.value)
    }

    // MARK: - Automatic Wi-Fi reconnect
    //
    // The coordinator's runner is injected here: the real one runs
    // `hopwatch --repair=reconnect-wifi`, which power-cycles this Mac's
    // Wi-Fi. Nothing in this section may ever reach it. The decision to
    // reconnect belongs to the monitor (`status.auto_reconnect`); these tests
    // pin that the app only checks its setting and that nothing is already
    // repairing, and then runs exactly the repair the field calls for.

    private final class RepairRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [(id: String, params: [String: String])] = []
        func record(_ id: String, _ params: [String: String]) {
            lock.lock(); recorded.append((id, params)); lock.unlock()
        }
        var calls: [(id: String, params: [String: String])] {
            lock.lock(); defer { lock.unlock() }; return recorded
        }
    }

    /// A coordinator whose repairs are recorded, not run, with the user's
    /// "Automatically reconnect Wi-Fi" setting restored by `restore()`.
    @MainActor private func recordingCoordinator(
        enabled: Bool, delayNanos: UInt64 = 0
    ) -> (HopwatchCoordinator, RepairRecorder, restore: () -> Void) {
        let recorder = RepairRecorder()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hopwatch-test-\(UUID().uuidString)", isDirectory: true)
        let coordinator = HopwatchCoordinator(
            repairRunner: { id, params in
                recorder.record(id, params)
                if delayNanos > 0 { try await Task.sleep(nanoseconds: delayNanos) }
                return NetdiagRunner.RepairResult(id: id, ok: true, dryRun: false,
                                                  ran: [], message: "recorded, not run")
            },
            eventLog: EventStore(directory: dir))
        let original = coordinator.appSettings.autoReconnectWiFi
        coordinator.appSettings.autoReconnectWiFi = enabled
        return (coordinator, recorder, {
            coordinator.appSettings.autoReconnectWiFi = original
            try? FileManager.default.removeItem(at: dir)
        })
    }

    private func joined(_ id: String, ssid: String?) -> MonitorSample {
        var value = sample(id, linkUp: true)
        value.link.ssid = ssid
        return value
    }

    private func dropped(_ id: String, rules: [String], reason: String,
                         precursor: String? = nil,
                         decision: MonitorSample.Status.AutoReconnect? = nil) -> MonitorSample {
        var value = sample(id, linkUp: false)
        value.status.rules = rules
        value.status.autoReconnect = decision
        value.link.offline = .init(reason: reason, downSince: nil, downDurationS: 60,
                                   lastNetwork: id, precursor: precursor)
        return value
    }

    private func decision(_ reason: String, _ rule: String, attempt: Int = 1,
                          of max: Int = 1) -> MonitorSample.Status.AutoReconnect {
        .init(reason: reason, rule: rule, attempt: attempt, maxAttempts: max)
    }

    @Test @MainActor func autoReconnectIsOffUnlessTheUserEnabledIt() async {
        let (coordinator, recorder, restore) = recordingCoordinator(enabled: false)
        defer { restore() }
        coordinator.handleSampleForTesting(joined("ssid:home", ssid: "HomeNet"))
        coordinator.handleSampleForTesting(
            dropped("ssid:home", rules: ["N1", "WJ-1"], reason: "wifi-not-joined",
                    decision: decision("wifi-dropped", "WJ-1")))
        await coordinator.awaitRepairForTesting()
        #expect(recorder.calls.isEmpty)
    }

    @Test @MainActor func theAppMakesNoReconnectDecisionOfItsOwn() async {
        let (coordinator, recorder, restore) = recordingCoordinator(enabled: true)
        defer { restore() }
        coordinator.handleSampleForTesting(joined("ssid:home", ssid: "HomeNet"))
        // Every condition the old app-side logic looked at, with no
        // `auto_reconnect` field from the monitor: WJ-1 with a precursor,
        // DH-3, and a wedged gateway at a strong signal. None may act.
        coordinator.handleSampleForTesting(
            dropped("ssid:home", rules: ["N1", "WJ-1"], reason: "wifi-not-joined",
                    precursor: "router-unreachable"))
        coordinator.handleSampleForTesting(
            dropped("ssid:home", rules: ["N1", "DH-3"], reason: "self-assigned"))
        for _ in 0..<10 {
            var wedged = joined("ssid:home", ssid: "HomeNet")
            wedged.wifi = .init(rssi: -50, noise: -90, snr: 40, channel: "36")
            wedged.gateway = .init(lossPct: 100, rttAvgMs: nil, rttJitterMs: nil)
            wedged.status.rules = ["G2"]
            coordinator.handleSampleForTesting(wedged)
        }
        await coordinator.awaitRepairForTesting()
        #expect(recorder.calls.isEmpty)
    }

    @Test @MainActor func aWarrantedDropRejoinsTheNetworkThatWasLost() async {
        let (coordinator, recorder, restore) = recordingCoordinator(enabled: true)
        defer { restore() }
        coordinator.handleSampleForTesting(joined("ssid:home", ssid: "HomeNet"))
        coordinator.handleSampleForTesting(
            dropped("ssid:home", rules: ["N1", "WJ-1"], reason: "wifi-not-joined",
                    precursor: "router-unreachable",
                    decision: decision("wifi-dropped", "WJ-1")))
        await coordinator.awaitRepairForTesting()
        #expect(recorder.calls.count == 1)
        #expect(recorder.calls.first?.id == "reconnect-wifi")
        #expect(recorder.calls.first?.params == ["network": "HomeNet"])
        // The app keeps no record of its own: what a restarted monitor needs
        // is the monitor's (`status.carry`), not something built here.
        #expect(coordinator.monitor.monitorCarry == nil)
    }

    @Test @MainActor func aJoinedFaultNeverTargetsARememberedNetwork() async {
        let (coordinator, recorder, restore) = recordingCoordinator(enabled: true)
        defer { restore() }
        // The Mac is joined to something now; the name remembered from
        // earlier may be a network the user left on purpose. Only the name
        // CoreWLAN reads this instant (nil without Location access) may be
        // passed, never "HomeNet".
        coordinator.handleSampleForTesting(joined("ssid:home", ssid: "HomeNet"))
        coordinator.handleSampleForTesting(
            dropped("ssid:home", rules: ["N1", "DH-3"], reason: "self-assigned",
                    decision: decision("no-address", "DH-3", attempt: 2, of: 4)))
        await coordinator.awaitRepairForTesting()
        #expect(recorder.calls.count == 1)
        #expect(recorder.calls.first?.params["network"] == coordinator.liveSSID)
        #expect(coordinator.monitor.monitorCarry == nil)
    }

    @Test @MainActor func aWedgedGatewayDecisionRunsTheRepair() async {
        let (coordinator, recorder, restore) = recordingCoordinator(enabled: true)
        defer { restore() }
        var wedged = joined("ssid:home", ssid: "HomeNet")
        wedged.status.autoReconnect = decision("wedged-gateway", "G2")
        coordinator.handleSampleForTesting(wedged)
        await coordinator.awaitRepairForTesting()
        #expect(recorder.calls.count == 1)
        #expect(recorder.calls.first?.id == "reconnect-wifi")
    }

    @Test @MainActor func aRepairInFlightBlocksAutomaticAndManualOnes() async {
        let (coordinator, recorder, restore) = recordingCoordinator(
            enabled: true, delayNanos: 100_000_000)
        defer { restore() }
        coordinator.handleSampleForTesting(joined("ssid:home", ssid: "HomeNet"))
        let warranted = dropped("ssid:home", rules: ["N1", "WJ-1"], reason: "wifi-not-joined",
                                decision: decision("wifi-dropped", "WJ-1"))
        coordinator.handleSampleForTesting(warranted)
        #expect(coordinator.isRepairing)
        // A second warranted sample, and a click on the manual button, while
        // the first is still running.
        coordinator.handleSampleForTesting(warranted)
        coordinator.reconnectWiFi()
        await coordinator.awaitRepairForTesting()
        #expect(recorder.calls.count == 1)
        // And a manual one first blocks an automatic one.
        coordinator.reconnectWiFi()
        coordinator.handleSampleForTesting(warranted)
        await coordinator.awaitRepairForTesting()
        #expect(recorder.calls.count == 2)
    }

    @Test @MainActor func aNewNetworkWithAHiddenNameNeverInheritsTheLastOnes() async {
        let (coordinator, recorder, restore) = recordingCoordinator(enabled: true)
        defer { restore() }
        coordinator.handleSampleForTesting(joined("ssid:home", ssid: "HomeNet"))
        #expect(coordinator.lastAssociatedSSID == "HomeNet")
        // Moved to a network whose name macOS will not give us.
        coordinator.handleSampleForTesting(joined("ssid:cafe", ssid: "<redacted>"))
        #expect(coordinator.lastAssociatedSSID != "HomeNet")
        coordinator.handleSampleForTesting(
            dropped("ssid:cafe", rules: ["N1", "WJ-1"], reason: "wifi-not-joined",
                    decision: decision("wifi-dropped", "WJ-1")))
        await coordinator.awaitRepairForTesting()
        #expect(recorder.calls.count == 1)
        #expect(recorder.calls.first?.params["network"] != "HomeNet")
    }

    /// An offline sample carries the identity the monitor held through the
    /// drop (same process) or none at all (a restarted process has no gateway
    /// and no ARP entry to build one from). Neither is a different network,
    /// so neither may forget the name WJ-1's repair is about to rejoin.
    @Test @MainActor func goingOfflineKeepsTheNameOfTheNetworkThatWasLost() async {
        let (coordinator, recorder, restore) = recordingCoordinator(enabled: true)
        defer { restore() }
        coordinator.handleSampleForTesting(joined("ssid:home", ssid: "HomeNet"))
        for id in ["ssid:home", ""] {
            coordinator.handleSampleForTesting(
                dropped(id, rules: ["N1"], reason: "wifi-not-joined"))
            #expect(coordinator.lastAssociatedSSID == "HomeNet")
        }
        // The restarted monitor's sample, which is the one that warrants it.
        coordinator.handleSampleForTesting(
            dropped("", rules: ["N1", "WJ-1"], reason: "wifi-not-joined",
                    precursor: "router-unreachable",
                    decision: decision("wifi-dropped", "WJ-1")))
        await coordinator.awaitRepairForTesting()
        #expect(recorder.calls.count == 1)
        #expect(recorder.calls.first?.params == ["network": "HomeNet"])
    }

    /// The other half: keeping the name through a drop must not let it leak
    /// onto whatever the Mac joins next.
    @Test @MainActor func aNetworkJoinedAfterTheDropDoesNotInheritTheLostName() async {
        let (coordinator, _, restore) = recordingCoordinator(enabled: true)
        defer { restore() }
        coordinator.handleSampleForTesting(joined("ssid:home", ssid: "HomeNet"))
        coordinator.handleSampleForTesting(
            dropped("", rules: ["N1"], reason: "wifi-not-joined"))
        coordinator.handleSampleForTesting(joined("ssid:cafe", ssid: "<redacted>"))
        #expect(coordinator.lastAssociatedSSID != "HomeNet")
    }

    @Test func theMonitorsCarryRecordDecodesAndIsAbsentFromOlderCLIs() throws {
        func decode(_ tail: String) throws -> MonitorSample.Status {
            let json = """
            {"severity":"ok","measurement":"measured","rules":[],
             "icmp_filtered":false,"degraded":false,"paused":false\(tail)}
            """
            return try JSONDecoder().decode(MonitorSample.Status.self, from: Data(json.utf8))
        }
        let record = "v1:1700000000:0:0:0:0:0:0:0:0:0:0:0:0:0"
        #expect(try decode(#","carry":"\#(record)""#).carry == record)
        #expect(try decode(#","carry":null"#).carry == nil)
        #expect(try decode("").carry == nil)
    }

    @Test func theMonitorsAutoReconnectFieldDecodes() throws {
        func decode(_ tail: String) throws -> MonitorSample.Status {
            let json = """
            {"severity":"critical","measurement":"link-down","rules":["N1","DH-3"],
             "icmp_filtered":false,"degraded":true,"paused":false\(tail)}
            """
            return try JSONDecoder().decode(MonitorSample.Status.self, from: Data(json.utf8))
        }
        let fired = try decode(#","auto_reconnect":{"reason":"no-address","rule":"DH-3","attempt":2,"max_attempts":4}"#)
        #expect(fired.autoReconnect == .init(reason: "no-address", rule: "DH-3",
                                             attempt: 2, maxAttempts: 4))
        #expect(try decode(#","auto_reconnect":null"#).autoReconnect == nil)
        // A CLI older than the field never sends it: not warranted.
        #expect(try decode("").autoReconnect == nil)
    }
}
