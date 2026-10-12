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

    @Test @MainActor func autoReconnectGuardsAgainstManualDisconnectWithoutPrecursor() {
        let coordinator = HopwatchCoordinator()
        coordinator.appSettings.autoReconnectWiFi = true

        // 1. Link drops with WJ-1 but NO precursor (user manually disconnected while healthy)
        var manualDrop = sample("ssid:home", linkUp: false)
        manualDrop.status.rules = ["N1", "WJ-1"]
        manualDrop.link.offline = .init(reason: "wifi-not-joined", downSince: nil, downDurationS: 50, lastNetwork: "home", precursor: nil)
        coordinator.handleSampleForTesting(manualDrop)
        #expect(!coordinator.hasAutoReconnectedThisOutage)

        // 2. Link drops with WJ-1 WITH involuntary precursor (router reboot or gateway down)
        var involuntaryDrop = sample("ssid:home", linkUp: false)
        involuntaryDrop.status.rules = ["N1", "WJ-1"]
        involuntaryDrop.link.offline = .init(reason: "wifi-not-joined", downSince: nil, downDurationS: 50, lastNetwork: "home", precursor: "router-unreachable")
        coordinator.handleSampleForTesting(involuntaryDrop)
        #expect(coordinator.hasAutoReconnectedThisOutage)
    }

    @Test @MainActor func autoReconnectDHCPExhaustionRetries() {
        let coordinator = HopwatchCoordinator()
        coordinator.appSettings.autoReconnectWiFi = true

        // 1. Establish SSID
        var initial = sample("ssid:home", linkUp: true)
        initial.link.ssid = "HomeNetwork"
        coordinator.handleSampleForTesting(initial)
        #expect(coordinator.lastAssociatedSSID == "HomeNetwork")

        // 2. DH-3 fires
        var dhcpDrop = sample("ssid:home", linkUp: false)
        dhcpDrop.status.rules = ["N1", "DH-3"]
        dhcpDrop.link.offline = .init(reason: "self-assigned", downSince: nil, downDurationS: 10, lastNetwork: "HomeNetwork", precursor: nil)
        coordinator.handleSampleForTesting(dhcpDrop)
        #expect(coordinator.dhcpRetryCount == 1)

        // 3. Immediate next sample within 30s doesn't spam retry
        coordinator.handleSampleForTesting(dhcpDrop)
        #expect(coordinator.dhcpRetryCount == 1)

        // 4. Link recovers with valid lease -> retry count resets
        var recovered = sample("ssid:home", linkUp: true)
        recovered.status.rules = []
        coordinator.handleSampleForTesting(recovered)
        #expect(coordinator.dhcpRetryCount == 0)
    }

    @Test @MainActor func autoReconnectWedgedRouterWithGoodSignal() {
        let coordinator = HopwatchCoordinator()
        coordinator.appSettings.autoReconnectWiFi = true

        var wedged = sample("ssid:home", linkUp: true)
        wedged.link.type = "wifi"
        wedged.wifi = .init(rssi: -58, noise: -90, snr: 32, channel: "36")
        wedged.gateway = .init(lossPct: 100, rttAvgMs: nil, rttJitterMs: nil)
        wedged.status.rules = ["G2", "N1"]

        // First 2 samples should observe and confirm without premature toggle
        coordinator.handleSampleForTesting(wedged)
        #expect(!coordinator.hasAutoReconnectedWedgedGateway)
        coordinator.handleSampleForTesting(wedged)
        #expect(!coordinator.hasAutoReconnectedWedgedGateway)

        // 3rd sample confirms persistent wedged router and triggers recovery
        coordinator.handleSampleForTesting(wedged)
        #expect(coordinator.hasAutoReconnectedWedgedGateway)

        // Gateway recovers cleanly -> resets latch
        var recovered = sample("ssid:home", linkUp: true)
        recovered.gateway = .init(lossPct: 0, rttAvgMs: 2.1, rttJitterMs: 0.5)
        recovered.status.rules = []
        coordinator.handleSampleForTesting(recovered)
        #expect(!coordinator.hasAutoReconnectedWedgedGateway)
    }
}
