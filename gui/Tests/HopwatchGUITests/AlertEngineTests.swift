import Foundation
import Testing
@testable import HopwatchGUI

@Suite struct AlertEngineTests {

    @Test @MainActor func browserDesyncAlertDefinitionExists() {
        let def = AlertDefinition.byID("browser-desync")
        #expect(def != nil)
        #expect(def?.rules == ["BR-1"])
        #expect(def?.title == "Browser needs relaunch")
        #expect(def?.dwell == 0)
        #expect(def?.resolves == true)
        #expect(def?.scanOnly == false)
    }

    @Test @MainActor func browserDesyncAlertFiresAndResolvesFromLiveSample() {
        let notifMgr = NotificationManager()
        notifMgr.setAuthorizedForTesting(true)
        notifMgr.notificationsEnabled = true

        var delivered: [(id: String, title: String, body: String)] = []

        notifMgr.onPostNotification = { id, title, body, _ in
            delivered.append((id, title, body))
        }
        notifMgr.onRemoveNotification = { _ in }

        let engine = AlertEngine(notificationManager: notifMgr)

        // 1. Initial healthy sample - no alert
        var healthySample = MonitorSample()
        healthySample.status.rules = []
        healthySample.status.severity = "ok"

        engine.evaluate(sample: healthySample)
        #expect(engine.active["browser-desync"] == nil)
        #expect(delivered.isEmpty)

        // 2. Sample with BR-1 (browser background update desync)
        var desyncSample = MonitorSample()
        desyncSample.status.rules = ["BR-1"]
        desyncSample.status.severity = "warn"

        engine.evaluate(sample: desyncSample)

        // Alert should be active immediately (dwell: 0)
        #expect(engine.active["browser-desync"] != nil)
        #expect(engine.active["browser-desync"]?.title == "Browser needs relaunch")
        #expect(delivered.contains { $0.id.contains("browser-desync") && $0.title == "Browser needs relaunch" })

        // 3. User relaunches browser - BR-1 clears
        var recoveredSample = MonitorSample()
        recoveredSample.status.rules = []
        recoveredSample.status.severity = "ok"

        engine.evaluate(sample: recoveredSample)

        #expect(engine.active["browser-desync"] == nil)
        #expect(delivered.contains { $0.id.contains("browser-desync") && $0.title.contains("resolved") })
    }

    @Test @MainActor func captivePortalAlertDoesNotFireOnHealthyLearnedPortal() {
        let notifMgr = NotificationManager()
        let engine = AlertEngine(notificationManager: notifMgr)

        let testSSID = "TestCafe"
        Defaults.recordPortalNetwork("ssid:\(testSSID)")
        defer { Defaults.removePortalNetwork("ssid:\(testSSID)") }

        var sample = MonitorSample()
        sample.link.ssid = testSSID
        sample.publicInfo.captivePortal = false
        sample.publicInfo.ip = "203.0.113.1"
        sample.internet.lossPct = 0
        sample.internet.rttAvgMs = 20.0
        sample.status.severity = "ok"

        var currentTime = Date()
        engine.now = { currentTime }

        engine.evaluate(sample: sample)
        currentTime = currentTime.addingTimeInterval(30)
        engine.evaluate(sample: sample)

        #expect(engine.active["captive-portal"] == nil)
    }

    @Test @MainActor func n1cDoesNotFireCaptivePortalAlert() {
        let notifMgr = NotificationManager()
        let engine = AlertEngine(notificationManager: notifMgr)

        var sample = MonitorSample()
        sample.status.rules = ["N1c"]
        sample.status.severity = "critical"

        var currentTime = Date()
        engine.now = { currentTime }

        engine.evaluate(sample: sample)
        currentTime = currentTime.addingTimeInterval(30)
        engine.evaluate(sample: sample)

        #expect(engine.active["captive-portal"] == nil)
    }

    @Test @MainActor func cp1FiresCaptivePortalAlert() {
        let notifMgr = NotificationManager()
        let engine = AlertEngine(notificationManager: notifMgr)

        var sample = MonitorSample()
        sample.status.rules = ["CP-1"]
        sample.publicInfo.captivePortal = true
        sample.status.severity = "critical"

        var currentTime = Date()
        engine.now = { currentTime }

        engine.evaluate(sample: sample)
        // Def dwell is 15s
        currentTime = currentTime.addingTimeInterval(20)
        engine.evaluate(sample: sample)

        #expect(engine.active["captive-portal"] != nil)
    }

    @Test func nonUrgentAlertDefinitionsAreExcludedFromMiniMenu() {
        // Non-urgent advisories that must not reach the mini menu taskbar dropdown
        let nonUrgentIDs = ["double-nat", "lease-expiring", "clock-drift", "slower-than-usual"]
        for id in nonUrgentIDs {
            let def = AlertDefinition.byID(id)
            #expect(def != nil, "AlertDefinition \(id) must exist")
            #expect(def?.isUrgent == false, "\(id) must have isUrgent == false")
            #expect(def?.reachesMiniMenu == false, "\(id) must have reachesMiniMenu == false")
        }

        // Urgent connection health issues that must reach the mini menu
        let urgentIDs = ["connection-lost", "wifi-unstable", "internet-degraded", "dns-failing", "captive-portal", "vpn-dropped", "ip-conflict", "different-network", "browser-desync"]
        for id in urgentIDs {
            let def = AlertDefinition.byID(id)
            #expect(def != nil, "AlertDefinition \(id) must exist")
            #expect(def?.isUrgent == true, "\(id) must have isUrgent == true")
            #expect(def?.reachesMiniMenu == true, "\(id) must have reachesMiniMenu == true")
        }
    }

    @Test @MainActor func doubleNATDoesNotReachMiniMenuStageOrDotHealth() {
        let notifMgr = NotificationManager()
        let engine = AlertEngine(notificationManager: notifMgr)

        var run = RunSnapshot()
        run.network.id = "test-net"
        var diag = RunSnapshot.Diagnosis()
        diag.rule = "NAT-1"
        diag.summary = "Two routers connected (Double NAT)"
        diag.severity = "warn"
        run.diagnosis = [diag]

        engine.evaluate(run: run)

        // 1. Double NAT is tracked in active alerts (accessible by dashboard findings and reports)
        #expect(engine.active["double-nat"] != nil)

        // 2. But excluded from urgentActiveSorted (used by the mini menu dropdown and menu bar dot)
        #expect(!engine.urgentActiveSorted.contains { $0.id == "double-nat" })

        let activeAlert = engine.active["double-nat"]!
        #expect(activeAlert.isUrgent == false)
        #expect(activeAlert.reachesMiniMenu == false)

        let snapshot = StageResolver.AlertSnapshot(
            title: activeAlert.title,
            body: activeAlert.body,
            raisedAt: activeAlert.raisedAt,
            rules: activeAlert.rules,
            severityRank: 2,
            id: activeAlert.id,
            isUrgent: activeAlert.isUrgent
        )

        // 3. StageResolver must NEVER resolve to .alerted for non-urgent alert
        let stageInputs = StageResolver.Inputs(
            isScanning: false,
            monitoringEnabled: true,
            isPausedForAnyReason: false,
            pauseReason: nil,
            lastError: nil,
            monitorRunning: true,
            activeAlert: snapshot,
            severity: "ok",
            linkUp: true,
            measurementState: "measured"
        )
        let resolvedStage = StageResolver.resolve(stageInputs)
        #expect(resolvedStage == .healthy, "StageResolver must not resolve to .alerted for non-urgent alert")

        // 4. HealthResolver must NOT turn the menu bar dot amber when the connection is healthy
        let healthInputs = HealthResolver.Inputs(
            isScanning: false,
            monitoringEnabled: true,
            isPausedForAnyReason: false,
            monitorRunning: true,
            activeAlert: snapshot,
            sampleHealth: .healthy,
            runHealth: .warning
        )
        #expect(HealthResolver.resolve(healthInputs) == .healthy, "HealthResolver must remain healthy when live sample is healthy")
    }
}
