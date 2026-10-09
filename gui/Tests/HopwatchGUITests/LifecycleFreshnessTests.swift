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
}
