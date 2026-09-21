import Foundation
import SwiftUI
import Testing
@testable import HopwatchGUI

@Suite struct DashboardVitalsAndEvidenceTests {

    @Test func gradeBadgeTonesAndColors() {
        let goodBadge = DashboardCheckTable.GradeBadge(label: "Good", tone: .good)
        #expect(goodBadge.label == "Good")
        #expect(goodBadge.tone == .good)
        #expect(goodBadge.tone.foreground == Theme.ColorToken.green)

        let warnBadge = DashboardCheckTable.GradeBadge(label: "Degraded", tone: .warn)
        #expect(warnBadge.label == "Degraded")
        #expect(warnBadge.tone == .warn)
        #expect(warnBadge.tone.foreground == Theme.ColorToken.amber)

        let critBadge = DashboardCheckTable.GradeBadge(label: "Unstable", tone: .critical)
        #expect(critBadge.label == "Unstable")
        #expect(critBadge.tone == .critical)
        #expect(critBadge.tone.foreground == Theme.ColorToken.red)

        let neutralBadge = DashboardCheckTable.GradeBadge(label: "Skipped", tone: .neutral)
        #expect(neutralBadge.label == "Skipped")
        #expect(neutralBadge.tone == .neutral)
        #expect(neutralBadge.tone.foreground == Theme.ColorToken.muted)
    }

    @Test func checkTableRowWithGradeBadge() {
        let row = DashboardCheckTable.Row(
            id: "jitter",
            icon: "waveform.path",
            label: "Jitter",
            measured: "13 ms",
            usual: "—",
            badge: .init(label: "Unstable", tone: .critical),
            isWarning: true
        )
        #expect(row.id == "jitter")
        #expect(row.label == "Jitter")
        #expect(row.measured == "13 ms")
        #expect(row.badge?.label == "Unstable")
        #expect(row.badge?.tone == .critical)
        #expect(row.isWarning == true)
    }

    @Test func speedCardAndReliabilityCardInstantiation() {
        let speedCard = DashboardSpeedCard(
            downMbps: "625",
            upMbps: "310",
            testedMeta: "Tested 20m ago",
            isScanning: false,
            onRunSpeedTest: {}
        )
        #expect(speedCard.downMbps == "625")
        #expect(speedCard.upMbps == "310")
        #expect(speedCard.testedMeta == "Tested 20m ago")

        let relCard = DashboardReliabilityCard(
            observationSummary: "Last 24 hours · Continuously monitored",
            outageCount: "0 outages",
            totalDowntime: "0s",
            longestOutage: "0s"
        )
        #expect(relCard.observationSummary == "Last 24 hours · Continuously monitored")
        #expect(relCard.outageCount == "0 outages")
        #expect(relCard.totalDowntime == "0s")
    }
}
