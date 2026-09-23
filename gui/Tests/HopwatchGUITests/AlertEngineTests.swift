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
}
