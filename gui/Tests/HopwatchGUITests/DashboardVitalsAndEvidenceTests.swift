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

    @Test func dashboardRouteViewWarnsWithoutRedWhenNotCritical() {
        let routeView = DashboardRouteView(
            wifiSignalText: "-55 dBm",
            wifiSignalDetail: "Excellent",
            wifiSignalTint: Theme.ColorToken.green,
            macIP: "192.168.0.36",
            routerPingText: "10",
            routerPingTint: Theme.ColorToken.green,
            routerWarn: false,
            routerIP: "192.168.0.1",
            routerLossText: "0%",
            routerJitterText: "1 ms",
            internetPingText: "20",
            internetPingTint: Theme.ColorToken.amber,
            internetWarn: true,
            countryFlag: "🇧🇷",
            countryName: "Brazil",
            ispName: "Claro",
            internetLossText: "0%",
            internetJitterText: "5 ms",
            bandChannelText: "5 GHz · Channel 44",
            vpnActive: false,
            vpnProvider: nil,
            publicIP: "179.156.166.144",
            pingTarget: "1.1.1.1",
            culpritHop: "internet",
            internetDetailText: "Calls & gaming may lag",
            routerDetailText: "192.168.0.1 · gateway",
            isCritical: false
        )
        #expect(routeView.culpritHop == "internet")
        #expect(routeView.internetWarn == true)
        #expect(routeView.isCritical == false)
        #expect(routeView.internetDetailText == "Calls & gaming may lag")
    }

    @Test func speedCardDuringActiveSpeedTesting() {
        var didCancel = false
        let speed = ScanProgress.Speed(stage: "download", progress: 0.65, mbps: 450.2)
        let activeCard = DashboardSpeedCard(
            downMbps: "625",
            upMbps: "310",
            testedMeta: "Tested 20m ago",
            isScanning: true,
            isSpeedTesting: true,
            speedProgress: speed,
            onRunSpeedTest: {},
            onCancelSpeedTest: { didCancel = true }
        )

        #expect(activeCard.isScanning == true)
        #expect(activeCard.isSpeedTesting == true)
        #expect(activeCard.speedProgress?.mbps == 450.2)
        #expect(activeCard.speedProgress?.progress == 0.65)
        #expect(activeCard.speedProgress?.direction == .download)

        activeCard.onCancelSpeedTest?()
        #expect(didCancel == true)
    }

    @Test func speedOnlyRunnerDepthArguments() {
        let depth = HopwatchRunner.Depth.speedOnly
        let args = depth.arguments
        #expect(args.contains("--speed-only"))
        #expect(args.contains("--json"))
        #expect(args.contains("--no-gping"))
    }

    @Test func dashboardLiveChartPanelBurstStateAndFastTierSampling() {
        var didToggle = false
        var window = 15
        let binding = Binding(get: { window }, set: { window = $0 })
        let until = Date().addingTimeInterval(60)

        var s1 = MonitorSample()
        s1.ts = ISO8601DateFormatter().string(from: Date())
        s1.refreshed = ["fast"]
        s1.gateway.rttAvgMs = 5.2
        s1.internet.rttAvgMs = 18.4

        let panel = DashboardLiveChartPanel(
            samples: [s1],
            selectedWindowMinutes: binding,
            isBursting: true,
            burstUntil: until,
            onToggleBurst: { didToggle = true }
        )

        #expect(panel.isBursting == true)
        #expect(panel.burstUntil == until)
        #expect(panel.selectedWindowMinutes == 15)

        panel.onToggleBurst()
        #expect(didToggle == true)

        let fastResult = MonitorSeries.build([s1], tier: "fast") { $0.internet.rttAvgMs }
        #expect(fastResult.points.count == 1)
        #expect(fastResult.points.first?.value == 18.4)
    }
}
