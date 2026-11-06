import Foundation
import Testing
@testable import HopwatchGUI

@Suite struct AvailabilityEngineTests {

    @Test func hardOutagesCountedCorrectly() {
        let now = Date(timeIntervalSince1970: 1700000000)
        let event1 = NetworkEvent(
            date: now.addingTimeInterval(-600),
            kind: "rule-fired",
            summary: "No network connection at all",
            ruleID: "N1",
            network: "wifi:gw=192.168.0.1"
        )
        let event2 = NetworkEvent(
            date: now.addingTimeInterval(-540),
            kind: "rule-cleared",
            summary: "Resolved: No network connection at all",
            ruleID: "N1",
            network: "wifi:gw=192.168.0.1"
        )
        let event3 = NetworkEvent(
            date: now.addingTimeInterval(-300),
            kind: "rule-fired",
            summary: "Internet ping 100% packet loss",
            ruleID: "P2",
            network: "wifi:gw=192.168.0.1"
        )
        let event4 = NetworkEvent(
            date: now.addingTimeInterval(-220),
            kind: "rule-cleared",
            summary: "Resolved: Internet ping 100% packet loss",
            ruleID: "P2",
            network: "wifi:gw=192.168.0.1"
        )

        let result = AvailabilityEngine.evaluate(
            networkEvents: [event1, event2, event3, event4],
            now: now
        )

        #expect(result.outages == 2)
        #expect(result.outageCountText == "2 outages")
        #expect(result.downtimeSeconds == 140) // 60s + 80s
        #expect(result.totalDowntimeText == "2m 20s")
        #expect(result.longestOutageSeconds == 80)
        #expect(result.longestOutageText == "1m 20s")
        #expect(!result.observationSummary.contains("No prior data"))

        // Watchdog invariant check
        let violations = DataSanityWatchdog.checkAvailability(
            result: result,
            events: [event1, event2, event3, event4],
            heartbeatMisses: 0
        )
        #expect(violations.isEmpty)
    }

    @Test func severeDisruptionsCountedWhenHardOutagesZero() {
        let now = Date(timeIntervalSince1970: 1700000000)
        let event1 = NetworkEvent(
            date: now.addingTimeInterval(-400),
            kind: "rule-fired",
            summary: "Severe internet packet loss",
            ruleID: "L1",
            network: "wifi:gw=192.168.0.1"
        )
        let event2 = NetworkEvent(
            date: now.addingTimeInterval(-350),
            kind: "rule-cleared",
            summary: "Resolved: Severe internet packet loss",
            ruleID: "L1",
            network: "wifi:gw=192.168.0.1"
        )
        let event3 = NetworkEvent(
            date: now.addingTimeInterval(-200),
            kind: "rule-fired",
            summary: "Router dropping packets",
            ruleID: "G2",
            network: "wifi:gw=192.168.0.1"
        )
        let event4 = NetworkEvent(
            date: now.addingTimeInterval(-170),
            kind: "rule-cleared",
            summary: "Resolved: Router dropping packets",
            ruleID: "G2",
            network: "wifi:gw=192.168.0.1"
        )

        let result = AvailabilityEngine.evaluate(
            networkEvents: [event1, event2, event3, event4],
            now: now
        )

        #expect(result.outages == 2)
        #expect(result.outageCountText == "2 drops")
        #expect(result.downtimeSeconds == 80) // 50s + 30s
        #expect(result.totalDowntimeText == "1m 20s")
        #expect(result.longestOutageSeconds == 50)
        #expect(result.longestOutageText == "50s")
    }

    @Test func cleanMonitoringReportsZeroOutagesHonesty() {
        let now = Date(timeIntervalSince1970: 1700000000)
        let result = AvailabilityEngine.evaluate(
            networkEvents: [],
            heartbeatMisses: 0,
            heartbeatTotal: 60,
            networkConnectedAt: now.addingTimeInterval(-7200),
            now: now
        )

        #expect(result.outages == 0)
        #expect(result.outageCountText == "0 outages")
        #expect(result.totalDowntimeText == "0s")
        #expect(result.longestOutageText == "0s")
        #expect(result.observationSummary == "Last 24 hours · Continuously monitored")

        let violations = DataSanityWatchdog.checkAvailability(
            result: result,
            events: [],
            heartbeatMisses: 0
        )
        #expect(violations.isEmpty)
    }

    @Test func newlyJoinedNetworkShowsPoliteNotice() {
        let now = Date(timeIntervalSince1970: 1700000000)
        let result = AvailabilityEngine.evaluate(
            networkEvents: [],
            allRecentEvents: [
                NetworkEvent(
                    date: now.addingTimeInterval(-1800),
                    kind: "rule-fired",
                    summary: "No network connection at all",
                    ruleID: "N1",
                    network: "wifi:gw=192.168.0.99"
                )
            ],
            heartbeatMisses: 0,
            heartbeatTotal: 5,
            networkConnectedAt: now.addingTimeInterval(-300), // connected 5m ago
            now: now
        )

        #expect(result.outages == 0)
        #expect(result.outageCountText == "0 outages")
        #expect(result.observationSummary == "Joined 5m ago · Monitoring active")
    }

    @Test func storedScanAvailabilityFoldsWithoutLoss() {
        let now = Date(timeIntervalSince1970: 1700000000)
        var snapAvail = RunSnapshot.Availability()
        snapAvail.outages = 5
        snapAvail.downtimeS = 320
        snapAvail.longestOutageS = 110
        snapAvail.unobservedPct = 12

        let result = AvailabilityEngine.evaluate(
            networkEvents: [],
            currentRunAvailability: snapAvail,
            now: now
        )

        #expect(result.outages == 5)
        #expect(result.outageCountText == "5 outages")
        #expect(result.downtimeSeconds == 320)
        #expect(result.totalDowntimeText == "5m 20s")
        #expect(result.longestOutageSeconds == 110)
        #expect(result.longestOutageText == "1m 50s")
        #expect(result.observationSummary.contains("12% offline or asleep"))
    }

    @Test func ongoingOutageAccumulatesLiveElapsedDuration() {
        let now = Date(timeIntervalSince1970: 1700000000)
        let ongoingEvent = NetworkEvent(
            date: now.addingTimeInterval(-95),
            kind: "rule-fired",
            summary: "No network connection at all",
            ruleID: "N1",
            network: "wifi:gw=192.168.0.1"
        )
        let result = AvailabilityEngine.evaluate(
            networkEvents: [ongoingEvent],
            currentRunAvailability: nil,
            now: now
        )
        #expect(result.outages == 1)
        #expect(result.downtimeSeconds == 95)
        #expect(result.longestOutageSeconds == 95)
    }
}
