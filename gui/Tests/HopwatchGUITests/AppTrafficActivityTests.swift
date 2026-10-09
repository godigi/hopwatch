import Foundation
import Testing
@testable import HopwatchGUI

@Suite struct AppTrafficActivityTests {
    private func event(_ date: Double, app: String? = "Backup Pro",
                       kind: String = "rule-fired", rate: Double = 40) throws -> NetworkEvent {
        var evidence: [String: Any] = ["process": "backup", "direction": "up",
            "rate_mbps": rate, "dominance_pct": 95,
            "observed_at": "2026-10-09T03:00:00Z", "gateway_rtt_ms": 30]
        if let app { evidence["app_name"] = app; evidence["app_bundle"] = "com.example.\(app)" }
        let row: [String: Any] = ["date": date, "kind": kind, "ruleID": "HOG-1",
            "summary": "High app traffic with elevated latency", "network": "mac:router", "evidence": evidence]
        return try JSONDecoder().decode(NetworkEvent.self, from: JSONSerialization.data(withJSONObject: row))
    }

    @Test func savedEventRetainsMeasuredAttribution() throws {
        let original = try event(1000)
        let encoded = try JSONEncoder().encode(original)
        let stored = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        #expect((stored["evidence"] as? [String: Any])?["app_name"] as? String == "Backup Pro")
        let entry = ActivityEntry.fold([try JSONDecoder().decode(NetworkEvent.self, from: encoded)])[0]
        #expect(entry.displaySummary.contains("Backup Pro"))
    }

    @Test func legacyEventDoesNotInventAnApp() {
        let row = NetworkEvent(date: Date(timeIntervalSinceReferenceDate: 1000), kind: "rule-fired",
                               summary: "One app is using up your connection", ruleID: "HOG-1")
        let entry = ActivityEntry.fold([row])[0]
        #expect(entry.detail?.contains("not recorded") == true)
    }

    @Test func changedAppDuringAnEpisodeDoesNotCreateAnotherOccurrence() throws {
        let entry = ActivityEntry.fold([try event(1000), try event(1060, app: "Browser", kind: "rule-updated")])[0]
        #expect(entry.occurrences == 1)
        #expect(entry.displaySummary.contains("2 apps"))
    }

    @Test func differentAppsOnOneDayAreNotBlamedOnOnlyOneApp() throws {
        var cleared = try event(1030, kind: "rule-cleared")
        cleared.summary = "Resolved: High app traffic with elevated latency"
        let rows = ActivityEntry.fold([try event(1000), cleared, try event(1100, app: "Browser")])
        #expect(rows.count == 1)
        #expect(rows[0].occurrences == 2)
        #expect(rows[0].displaySummary.contains("2 apps"))
    }

    @Test func unattributedProcessIsShownWithoutInventingAnApp() throws {
        let entry = ActivityEntry.fold([try event(1000, app: nil)])[0]
        #expect(entry.displaySummary.contains("backup"))
        #expect(entry.trafficEvidence[0].detail.contains("app unidentified"))
        #expect(entry.trafficEvidence[0].detail.contains("40 Mbps"))
    }

    @Test func updateWithoutOpeningEventStillShowsTheObservedApp() throws {
        let rows = ActivityEntry.fold([try event(1060, app: "Browser", kind: "rule-updated")])
        #expect(rows.count == 1)
        #expect(rows.first?.displaySummary.contains("Browser") == true)
    }

    @Test func trafficRecaptureDoesNotResetTimeSinceNetworkChanged() throws {
        let opening = try event(1000)
        let update = try event(1060, kind: "rule-updated")
        #expect(NetworkEvent.timeSinceLast([opening, update], now: Date(timeIntervalSinceReferenceDate: 1100)) == 100)
    }

    @Test func resolutionInRollingWindowRetainsTheLastMeasuredApp() throws {
        let cleared = try event(1100, kind: "rule-cleared")
        let entry = ActivityEntry.fold([cleared])[0]
        #expect(entry.displaySummary.contains("Backup Pro"))
        #expect(entry.trafficEvidence.first?.observedAt == "2026-10-09T03:00:00Z")
        #expect(!entry.attributionIncomplete)
        #expect(entry.totalDuration == nil)
    }

    @Test @MainActor func repeatedCapturesKeepHistoryWithoutEvictingTheOpening() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: directory.appendingPathComponent("events.json"))
        let store = EventStore(directory: directory)
        let first = try event(1000)
        store.record(kind: first.kind, summary: first.summary, ruleID: first.ruleID, network: first.network,
                     date: first.date, evidence: first.evidence)
        for i in 1...10 {
            let next = try event(1000 + Double(i * 60), kind: "rule-updated", rate: Double(i + 40))
            store.record(kind: next.kind, summary: next.summary, ruleID: next.ruleID, network: next.network,
                         date: next.date, evidence: next.evidence)
        }
        #expect(store.events.count == 2)
        #expect(store.events.contains { $0.kind == "rule-fired" })
        #expect(ActivityEntry.fold(store.events)[0].trafficEvidence[0].rateMbps == 50)
    }

    @Test @MainActor func repeatedRecoveriesCloseBothAttributedEpisodes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: directory.appendingPathComponent("events.json"))
        let store = EventStore(directory: directory)
        for (date, app) in [(1000.0, "Backup Pro"), (1100.0, "Browser")] {
            let fired = try event(date, app: app)
            store.record(kind: fired.kind, summary: fired.summary, ruleID: fired.ruleID, network: fired.network,
                         date: fired.date, evidence: fired.evidence)
            store.record(kind: "rule-cleared", summary: "Resolved: High app traffic with elevated latency",
                         ruleID: "HOG-1", network: fired.network,
                         date: Date(timeIntervalSinceReferenceDate: date + 30))
        }
        let entry = ActivityEntry.fold(store.events)[0]
        #expect(entry.occurrences == 2)
        #expect(!entry.isOngoing)
        #expect(entry.totalDuration == 60)
    }
}
