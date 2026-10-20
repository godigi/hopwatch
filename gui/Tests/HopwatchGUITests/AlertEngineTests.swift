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
}
