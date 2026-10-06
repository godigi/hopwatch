import Foundation
import Testing
@testable import HopwatchGUI

@Suite struct DashboardCheckEvidenceTests {
    @Test func fourOffChannelNeighboursDoNotCrowdCurrentChannel() throws {
        let snapshot = try decode("""
        {"wifi_scan":{"current_channel":"44","neighbour_count":4,"current_channel_neighbours":0},"diagnosis":[]}
        """)
        let row = DashboardCheckEvidence.wifiChannel(snapshot: snapshot, channel: "44", fallbackChannel: "")

        #expect(row.measured == "44")
        #expect(row.subvalue == "0 neighboring networks")
        #expect(row.badge == .init(label: "Clear", tone: .good))
        #expect(!row.isWarning)
        #expect(row.isGood)
    }

    @Test func fourSameChannelNeighboursUseCLICrowdingVerdict() throws {
        let snapshot = try decode("""
        {"wifi_scan":{"current_channel":"44","neighbour_count":9,"current_channel_neighbours":4},"diagnosis":[{"rule":"WS-1","severity":"warn"}]}
        """)
        let row = DashboardCheckEvidence.wifiChannel(snapshot: snapshot, channel: "44", fallbackChannel: "")

        #expect(row.subvalue == "4 neighboring networks")
        #expect(row.badge == .init(label: "Crowded", tone: .warn))
        #expect(row.isWarning)
        #expect(!row.isGood)
    }

    @Test func channelVerdictFollowsCLIInsteadOfSwiftCountThreshold() {
        var snapshot = RunSnapshot()
        snapshot.wifiScan = .init(neighbourCount: 4, currentChannelNeighbours: 4)
        let clear = DashboardCheckEvidence.wifiChannel(snapshot: snapshot, channel: "44", fallbackChannel: "")
        #expect(clear.badge == .init(label: "Clear", tone: .good))

        snapshot.wifiScan = .init(neighbourCount: 1, currentChannelNeighbours: 1)
        snapshot.diagnosis = [.init(severity: "warn", rule: "WS-1")]
        let crowded = DashboardCheckEvidence.wifiChannel(snapshot: snapshot, channel: "44", fallbackChannel: "")
        #expect(crowded.badge == .init(label: "Crowded", tone: .warn))
    }

    @Test func missingSavedCheckShowsNeutralEvidence() {
        let rows = [
            DashboardCheckEvidence.dns(snapshot: nil),
            DashboardCheckEvidence.bufferbloat(snapshot: nil),
            DashboardCheckEvidence.web(snapshot: nil)
        ]

        for row in rows {
            #expect(row.measured == "Awaiting check")
            #expect(row.subvalue == nil)
            #expect(row.badge == .init(label: "Unknown", tone: .neutral))
            #expect(!row.isGood)
            #expect(!row.isWarning)
        }
        #expect(DashboardCheckEvidence.loadedRTT(snapshot: nil) == "Not measured")
    }

    @Test func savedCheckWithoutProbeResultsShowsSkippedEvidence() throws {
        let snapshot = try decode("""
        {"run_mode":"ping","dns":[],"tcp_reach":[],"bufferbloat":{"gw_grade":"","inet_grade":"","gw_delta_ms":null,"inet_delta_ms":null}}
        """)
        let rows = [
            DashboardCheckEvidence.dns(snapshot: snapshot),
            DashboardCheckEvidence.bufferbloat(snapshot: snapshot),
            DashboardCheckEvidence.web(snapshot: snapshot)
        ]
        for row in rows {
            #expect(row.measured == "Not measured in this check")
            #expect(row.badge == .init(label: "Skipped", tone: .neutral))
            #expect(!row.isGood)
            #expect(!row.isWarning)
        }
        #expect(DashboardCheckEvidence.loadedRTT(snapshot: snapshot) == "Not measured")
    }

    @Test func partialBufferbloatDoesNotInventRouterGradeOrDelta() {
        var snapshot = RunSnapshot()
        snapshot.bufferbloat = .init(inetDeltaMs: 180, inetGrade: "D")
        let row = DashboardCheckEvidence.bufferbloat(snapshot: snapshot)

        #expect(row.measured == "Router —")
        #expect(row.subvalue == "Internet D (+180 ms)")
        #expect(row.badge == .init(label: "Grade D", tone: .critical))
        #expect(row.isWarning)
    }

    @Test func channelWithoutScanEvidenceIsNeutral() {
        let row = DashboardCheckEvidence.wifiChannel(snapshot: RunSnapshot(), channel: "44", fallbackChannel: "")
        #expect(row.badge == .init(label: "Unknown", tone: .neutral))
        #expect(row.subvalue == nil)
        #expect(!row.isGood)
        #expect(!row.isWarning)
    }

    @Test func secondSuccessfulTCPTargetShowsWebReachable() {
        var snapshot = RunSnapshot()
        snapshot.tcpReach = [
            .init(host: "1.1.1.1", port: 443, ok: false),
            .init(host: "8.8.8.8", port: 443, ok: true)
        ]
        let row = DashboardCheckEvidence.web(snapshot: snapshot)
        #expect(row.badge == .init(label: "Good", tone: .good))
        #expect(row.measured == "TCP 443 reachable")
        #expect(row.isGood)
    }

    @Test func measuredProbeRowsKeepTheirExistingStates() {
        var snapshot = RunSnapshot()
        snapshot.dns = [.init(ok: true), .init(ok: false)]
        snapshot.tcpReach = [.init(host: "1.1.1.1", port: 443, ok: false)]
        snapshot.bufferbloat = .init(gwDeltaMs: 3, inetDeltaMs: 180, gwGrade: "A", inetGrade: "D")

        let dns = DashboardCheckEvidence.dns(snapshot: snapshot)
        #expect(dns.measured == "1 of 2 resolvers OK")
        #expect(dns.badge == .init(label: "Degraded", tone: .warn))
        #expect(dns.isWarning)

        let web = DashboardCheckEvidence.web(snapshot: snapshot)
        #expect(web.measured == "TCP 443 blocked")
        #expect(web.badge == .init(label: "Blocked", tone: .critical))
        #expect(web.isWarning)

        let bb = DashboardCheckEvidence.bufferbloat(snapshot: snapshot)
        #expect(bb.measured == "Router A (+3 ms)")
        #expect(bb.subvalue == "Internet D (+180 ms)")
        #expect(bb.badge == .init(label: "Grade D", tone: .critical))
        #expect(bb.isWarning)
        #expect(DashboardCheckEvidence.loadedRTT(snapshot: snapshot) == "router 3 ms / internet 180 ms")

        snapshot.dns = [.init(ok: true)]
        snapshot.tcpReach = [.init(ok: true)]
        snapshot.bufferbloat = .init(gwDeltaMs: 3, inetDeltaMs: 15, gwGrade: "A", inetGrade: "A")
        #expect(DashboardCheckEvidence.dns(snapshot: snapshot).badge == .init(label: "Good", tone: .good))
        #expect(DashboardCheckEvidence.web(snapshot: snapshot).badge == .init(label: "Good", tone: .good))
        #expect(DashboardCheckEvidence.bufferbloat(snapshot: snapshot).badge == .init(label: "Grade A", tone: .good))
    }

    private func decode(_ json: String) throws -> RunSnapshot {
        try JSONDecoder().decode(RunSnapshot.self, from: Data(json.utf8))
    }
}
