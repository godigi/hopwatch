import Foundation
import Testing
@testable import HopwatchGUI

@Suite("Degraded Flow & Background Scan")
struct DegradedFlowTests {

    private func makeSample(
        seq: Int = 1,
        gwRtt: Double? = 6.0,
        gwLoss: Double? = 0.0,
        gwJitter: Double? = 1.0,
        inetRtt: Double? = 22.0,
        inetLoss: Double? = 0.0,
        inetJitter: Double? = 1.5,
        topJitter: Double? = nil,
        severity: String = "ok",
        rules: [String] = []
    ) -> MonitorSample {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var s = MonitorSample()
        s.schema = 2
        s.ts = iso.string(from: Date())
        s.seq = seq
        s.refreshed = ["fast", "medium", "slow"]
        s.jitterMs = topJitter ?? max(gwJitter ?? 0, inetJitter ?? 0)
        s.link.up = true
        s.link.interface = "en0"
        s.link.type = "wifi"
        s.link.ssid = "TestNet"
        s.link.gateway = "192.168.1.1"
        s.network.id = "mac:aa:bb:cc:dd:ee:01"
        s.network.label = "TestNet"
        s.gateway.rttAvgMs = gwRtt
        s.gateway.lossPct = gwLoss
        s.gateway.rttJitterMs = gwJitter
        s.internet.rttAvgMs = inetRtt
        s.internet.lossPct = inetLoss
        s.internet.rttJitterMs = inetJitter
        s.dns.ok = true
        s.dns.elapsedMs = 12.0
        s.tcp.anyOk = true
        s.status.severity = severity
        s.status.measurement = "measured"
        s.status.rules = rules
        return s
    }

    @Test func statusPillNeverShowsGreenWatchingOnDegradedOrAlertedStages() {
        let degWarn = StageResolver.statusPill(for: .degraded(.init(headline: "Unstable for calls", subtitle: "10% loss", isCritical: false)))
        #expect(degWarn.text == "Degraded")
        #expect(degWarn.tone == .amber)

        let degCrit = StageResolver.statusPill(for: .degraded(.init(headline: "Unstable for calls", subtitle: "25% loss", isCritical: true)))
        #expect(degCrit.text == "Problem")
        #expect(degCrit.tone == .red)

        let alertCrit = StageResolver.statusPill(for: .alerted(.init(title: "Outage", body: "No route", raisedAt: Date(), rules: ["L1"], severityRank: 3)))
        #expect(alertCrit.text == "Problem")
        #expect(alertCrit.tone == .red)

        let alertWarn = StageResolver.statusPill(for: .alerted(.init(title: "Slow", body: "Congested", raisedAt: Date(), rules: ["L2"], severityRank: 2)))
        #expect(alertWarn.text == "Degraded")
        #expect(alertWarn.tone == .amber)

        let healthy = StageResolver.statusPill(for: .healthy)
        #expect(healthy.text == "Watching")
        #expect(healthy.tone == .green)

        let testing = StageResolver.statusPill(for: .testing)
        #expect(testing.text == "Checking")
        #expect(testing.tone == .blue)
    }

    @Test func menuBarDotFollowsDegradedExperienceWhenSampleSeverityIsOk() {
        let degradedWarn = HealthResolver.resolve(.init(
            isScanning: false,
            monitoringEnabled: true,
            isPausedForAnyReason: false,
            monitorRunning: true,
            sampleHealth: .healthy,
            runHealth: nil,
            linkDown: false,
            degradedIsCritical: false
        ))
        #expect(degradedWarn == .warning)

        let degradedCrit = HealthResolver.resolve(.init(
            isScanning: false,
            monitoringEnabled: true,
            isPausedForAnyReason: false,
            monitorRunning: true,
            sampleHealth: .healthy,
            runHealth: nil,
            linkDown: false,
            degradedIsCritical: true
        ))
        #expect(degradedCrit == .critical)

        let clean = HealthResolver.resolve(.init(
            isScanning: false,
            monitoringEnabled: true,
            isPausedForAnyReason: false,
            monitorRunning: true,
            sampleHealth: .healthy,
            runHealth: nil,
            linkDown: false,
            degradedIsCritical: nil
        ))
        #expect(clean == .healthy)

        let warningUpgraded = HealthResolver.resolve(.init(
            isScanning: false,
            monitoringEnabled: true,
            isPausedForAnyReason: false,
            monitorRunning: true,
            sampleHealth: .warning,
            runHealth: nil,
            linkDown: false,
            degradedIsCritical: true
        ))
        #expect(warningUpgraded == .critical)
    }

    @Test func stageResolverStaysOutOfTestingDuringBackgroundAlertScan() {
        let stage = StageResolver.resolve(.init(
            isScanning: true,
            isArrivalCheck: false,
            isBackgroundScan: true,
            monitoringEnabled: true,
            isPausedForAnyReason: false,
            pauseReason: "scan",
            lastError: nil,
            monitorRunning: true,
            activeAlert: nil,
            severity: "warn",
            linkUp: true,
            sampleStale: false,
            measurementState: "measured",
            activeResolution: nil,
            degradedExperience: nil,
            settling: false
        ))
        #expect(stage == .watching(severity: .warn))
    }

    @Test @MainActor func coordinatorPreservesLiveTelemetryAcrossBackgroundScanAndEnforcesCooldown() {
        let coord = HopwatchCoordinator()
        coord.resetGalleryState()

        // 1. Degraded L2 reading arrives before background scan pauses monitor
        let sample = makeSample(
            seq: 10,
            gwRtt: 91.0, gwLoss: 0.0, gwJitter: 61.0,
            inetRtt: 60.0, inetLoss: 5.0, inetJitter: 24.0,
            topJitter: 61.0,
            severity: "warn",
            rules: ["L2"]
        )
        coord.monitor.adoptGallerySample(sample, historical: [sample, sample])
        coord.handleSampleForTesting(sample)
        coord.adoptGalleryArrivalSettled()

        // 2. Background alert-triggered scan pauses monitor for "scan"
        coord.monitor.pause(reason: HopwatchCoordinator.scanPauseReason)
        coord.adoptGalleryScanState(isScanning: true, depth: .alertTriggered, currentStep: "ipv6", alertTriggered: true)

        #expect(coord.isBackgroundInvestigating)
        #expect(coord.liveSample?.internet.rttAvgMs == 60.0)
        #expect(coord.liveSample?.internet.lossPct == 5.0)
        #expect(coord.currentJitter == 61.0)
        let stage = coord.currentStage(monitoringEnabled: true)
        #expect(stage != .testing)
        #expect(StageResolver.statusPill(for: stage).text == "Degraded")

        // 3. Explicit user full check enters .testing while still keeping preScanSample visible
        coord.adoptGalleryScanState(isScanning: true, depth: .full, currentStep: "speedtest", alertTriggered: false)
        #expect(!coord.isBackgroundInvestigating)
        #expect(coord.currentStage(monitoringEnabled: true) == .testing)
        #expect(coord.liveSample?.internet.rttAvgMs == 60.0)

        // 4. Cooldown blocks back-to-back alert-triggered scan for 600s
        coord.monitor.resume(reason: HopwatchCoordinator.scanPauseReason)
        coord.adoptGalleryScanState(isScanning: false, depth: nil)
        coord.adoptGalleryLastAlertScanAt(Date())
        #expect(coord.isAlertTriggeredScanInCooldown())
        #expect(!coord.canStartAlertTriggeredScanForTesting)

        // 5. After 10m cooldown has elapsed, scan is permitted again
        coord.adoptGalleryLastAlertScanAt(Date().addingTimeInterval(-601))
        #expect(!coord.isAlertTriggeredScanInCooldown())
    }
}
