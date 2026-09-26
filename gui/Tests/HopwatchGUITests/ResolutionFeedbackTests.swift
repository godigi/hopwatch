import Foundation
import Testing
@testable import HopwatchGUI

@Suite struct ResolutionFeedbackTests {

    @Test func stageResolverResolvesResolutionWhenHealthy() {
        let res = StageResolver.ResolutionSnapshot(
            title: "Wi-Fi Improved",
            message: "Moved from 2.4 GHz to 5 GHz (Ch 52). Negotiated higher throughput.",
            icon: "wifi"
        )
        let inputs = StageResolver.Inputs(
            isScanning: false,
            isArrivalCheck: false,
            monitoringEnabled: true,
            isPausedForAnyReason: false,
            pauseReason: nil,
            lastError: nil,
            monitorRunning: true,
            activeAlert: nil,
            severity: "ok",
            linkUp: true,
            measurementState: "measured",
            activeResolution: res
        )
        let stage = StageResolver.resolve(inputs)
        #expect(stage == .resolved(res))
    }

    @Test func faultsPrecedeResolution() {
        let res = StageResolver.ResolutionSnapshot(
            title: "Network Stabilized",
            message: "Packet loss resolved (0% loss, 18ms ping)."
        )
        let alert = StageResolver.AlertSnapshot(
            title: "Packet loss",
            body: "Losing packets",
            raisedAt: Date(),
            rules: ["L1"]
        )

        // 1. Critical severity precedes resolved
        let critInputs = StageResolver.Inputs(
            isScanning: false,
            monitoringEnabled: true,
            isPausedForAnyReason: false,
            pauseReason: nil,
            lastError: nil,
            monitorRunning: true,
            activeAlert: nil,
            severity: "critical",
            linkUp: true,
            measurementState: "measured",
            activeResolution: res
        )
        #expect(StageResolver.resolve(critInputs) == .watching(severity: .critical))

        // 2. Warn severity precedes resolved
        let warnInputs = StageResolver.Inputs(
            isScanning: false,
            monitoringEnabled: true,
            isPausedForAnyReason: false,
            pauseReason: nil,
            lastError: nil,
            monitorRunning: true,
            activeAlert: nil,
            severity: "warn",
            linkUp: true,
            measurementState: "measured",
            activeResolution: res
        )
        #expect(StageResolver.resolve(warnInputs) == .watching(severity: .warn))

        // 3. Active alert precedes resolved
        let alertInputs = StageResolver.Inputs(
            isScanning: false,
            monitoringEnabled: true,
            isPausedForAnyReason: false,
            pauseReason: nil,
            lastError: nil,
            monitorRunning: true,
            activeAlert: alert,
            severity: "ok",
            linkUp: true,
            measurementState: "measured",
            activeResolution: res
        )
        #expect(StageResolver.resolve(alertInputs) == .alerted(alert))

        // 4. Link down precedes resolved
        let downInputs = StageResolver.Inputs(
            isScanning: false,
            monitoringEnabled: true,
            isPausedForAnyReason: false,
            pauseReason: nil,
            lastError: nil,
            monitorRunning: true,
            activeAlert: nil,
            severity: "ok",
            linkUp: false,
            measurementState: "measured",
            activeResolution: res
        )
        #expect(StageResolver.resolve(downInputs) == .watching(severity: .critical))
    }

    @Test func resolutionEventLifecycleAndExpiration() {
        let event = NetdiagCoordinator.ResolutionEvent(
            title: "Online",
            message: "Captive portal authentication succeeded. Internet access active."
        )
        #expect(event.isCurrent)
        #expect(!event.dismissed)

        var dismissedEvent = event
        dismissedEvent.dismissed = true
        #expect(!dismissedEvent.isCurrent)

        let expiredDate = Date().addingTimeInterval(-50)
        let expiredEvent = NetdiagCoordinator.ResolutionEvent(
            title: "Signal Restored",
            message: "Wi-Fi signal jumped from -78 dBm to -46 dBm.",
            timestamp: expiredDate
        )
        #expect(!expiredEvent.isCurrent)
    }

    @Test func snapshotPreservesFields() {
        let date = Date()
        let event = NetdiagCoordinator.ResolutionEvent(
            title: "Wi-Fi Improved",
            message: "Moved from 2.4 GHz to 5 GHz (Ch 52).",
            timestamp: date,
            icon: "wifi"
        )
        let snap = event.snapshot
        #expect(snap.title == "Wi-Fi Improved")
        #expect(snap.message == "Moved from 2.4 GHz to 5 GHz (Ch 52).")
        #expect(snap.timestamp == date)
        #expect(snap.icon == "wifi")
        #expect(snap.id.contains("Wi-Fi Improved"))
    }

    @MainActor
    @Test func activeResolutionDismissedWhenLossReturns() {
        let coord = HopwatchCoordinator()
        coord.start()
        coord.recordResolution(
            title: "Network Stabilized",
            message: "Packet loss resolved (0% loss, 80 ms ping)."
        )
        #expect(coord.activeResolution != nil)

        // Incoming sample with 3% packet loss must invalidate resolution immediately
        var lossSample = MonitorSample()
        lossSample.link.up = true
        lossSample.status.measurement = "measured"
        lossSample.status.severity = "ok"
        lossSample.gateway.lossPct = 3.0
        lossSample.internet.lossPct = 3.0

        coord.monitor.onSample?(lossSample)
        #expect(coord.activeResolution == nil)
    }

    @Test func healthResolverRespectsActiveAlertAndFaultedRuns() {
        let alert = StageResolver.AlertSnapshot(
            title: "Internet Degraded",
            body: "Loss observed",
            raisedAt: Date(),
            rules: ["L2"],
            severityRank: 2
        )
        let alertInputs = HealthResolver.Inputs(
            isScanning: false,
            monitoringEnabled: true,
            isPausedForAnyReason: false,
            monitorRunning: true,
            activeAlert: alert,
            sampleHealth: .healthy,
            runHealth: nil
        )
        #expect(HealthResolver.resolve(alertInputs) == .warning)

        // When monitoring is active with no alerts, live sample health is the source of truth
        let liveHealthyInputs = HealthResolver.Inputs(
            isScanning: false,
            monitoringEnabled: true,
            isPausedForAnyReason: false,
            monitorRunning: true,
            activeAlert: nil,
            sampleHealth: .healthy,
            runHealth: .warning
        )
        #expect(HealthResolver.resolve(liveHealthyInputs) == .healthy)

        // When no live sample has been received yet, the newest run's severity provides fallback
        let fallbackInputs = HealthResolver.Inputs(
            isScanning: false,
            monitoringEnabled: true,
            isPausedForAnyReason: false,
            monitorRunning: true,
            activeAlert: nil,
            sampleHealth: nil,
            runHealth: .warning
        )
        #expect(HealthResolver.resolve(fallbackInputs) == .warning)
    }

    @Test func monitorSampleHealthDetectsElevatedLoss() {
        var sample = MonitorSample()
        sample.link.up = true
        sample.status.measurement = "measured"
        sample.status.severity = "ok"

        // 1. Elevated internet loss triggers warning
        sample.gateway.lossPct = 0.0
        sample.internet.lossPct = 3.0
        #expect(sample.health == .warning)

        // 2. Isolated router ping loss with clean internet stays healthy (harmless ICMP rate limiting)
        sample.gateway.lossPct = 3.0
        sample.internet.lossPct = 0.0
        #expect(sample.health == .healthy)
    }
}
