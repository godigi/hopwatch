import Foundation
import Testing
@testable import NetdiagGUI

@Suite struct NetworkHistoryStoreTests {

    private func makeSampleNetwork() -> HistoryDocument.Network {
        var statGW = HistoryDocument.MetricStat()
        statGW.median = 12.0
        var statInet = HistoryDocument.MetricStat()
        statInet.median = 18.0
        var statDown = HistoryDocument.MetricStat()
        statDown.median = 350.0
        var statUp = HistoryDocument.MetricStat()
        statUp.median = 40.0

        return HistoryDocument.Network(
            id: "mac:00:11:22:33:44:55",
            label: "HomeNet 5G",
            synthesized: false,
            bridgedFrom: [],
            firstSeen: "2026-09-01T10:00:00Z",
            lastSeen: "2026-09-12T10:00:00Z",
            runCount: 10,
            checkCount: 10,
            gateways: ["192.168.1.1"],
            isps: ["Comcast"],
            ssids: ["HomeNet 5G"],
            metricSamples: [:],
            metricStats: [
                "gateway_rtt_ms": statGW,
                "inet_rtt_ms": statInet,
                "speed_down_mbps": statDown,
                "speed_up_mbps": statUp,
            ],
            severityCounts: ["ok": 9, "warn": 1, "critical": 0],
            judged: nil
        )
    }

    @Test func memorySynthesizesCorrectAveragesAndGrades() {
        let net = makeSampleNetwork()
        var run1 = HistoryDocument.Run()
        run1.metrics = ["speedtest.down_mbps": 480.0, "speedtest.up_mbps": 50.0]

        let memory = NetworkHistoryStore.memory(for: net, displayName: "HomeNet 5G", runs: [run1])
        #expect(memory.typicalGatewayLatencyMs == 12.0)
        #expect(memory.typicalInternetLatencyMs == 18.0)
        #expect(memory.typicalDownMbps == 350.0)
        #expect(memory.typicalUpMbps == 40.0)
        #expect(memory.peakDownMbps == 480.0)
        #expect(memory.peakUpMbps == 50.0)
        #expect(memory.reliabilityPercent == 90.0)
        #expect(memory.reliabilityGrade == "Good")
        #expect(memory.summaryChipText.contains("350 Mbps"))
        #expect(memory.summaryChipText.contains("90% reliable"))
    }

    @Test func snapshotComparisonVerdicts() {
        let net = makeSampleNetwork()
        let memory = NetworkHistoryStore.memory(for: net, displayName: "HomeNet 5G", runs: [])

        // Fast snapshot
        var snapFast = RunSnapshot()
        snapFast.gateway.rttAvgMs = 8.0 // 4ms faster (> 20% faster)
        snapFast.gateway.lossPct = 0.0
        snapFast.speedtest = RunSnapshot.Speedtest(downMbps: 450.0, upMbps: 45.0)

        let compFast = NetworkHistoryStore.compare(snapshot: snapFast, baseline: memory)
        #expect(compFast.gatewayLatencyVerdict == .faster)
        #expect(compFast.lossVerdict == .normal)
        #expect(compFast.downSpeedVerdict == .faster)
        #expect(compFast.summaryDescription.contains("faster than typical"))

        // Slow snapshot with packet loss
        var snapSlow = RunSnapshot()
        snapSlow.gateway.rttAvgMs = 25.0 // > 20% slower
        snapSlow.gateway.lossPct = 4.0
        snapSlow.speedtest = RunSnapshot.Speedtest(downMbps: 200.0, upMbps: 20.0)

        let compSlow = NetworkHistoryStore.compare(snapshot: snapSlow, baseline: memory)
        #expect(compSlow.gatewayLatencyVerdict == .slower)
        #expect(compSlow.lossVerdict == .degraded)
        #expect(compSlow.downSpeedVerdict == .slower)
        #expect(compSlow.summaryDescription.contains("4% packet loss"))
    }

    @Test func monitorSampleComparisonVerdicts() {
        let net = makeSampleNetwork()
        let memory = NetworkHistoryStore.memory(for: net, displayName: "HomeNet 5G", runs: [])

        var sample = MonitorSample()
        sample.gateway.rttAvgMs = 12.5 // within 20%
        sample.gateway.lossPct = 0.0

        let compNormal = NetworkHistoryStore.compare(sample: sample, baseline: memory)
        #expect(compNormal.gatewayLatencyVerdict == .normal)
        #expect(compNormal.lossVerdict == .normal)
        #expect(compNormal.summaryDescription.contains("Typical latency"))

        sample.gateway.lossPct = 8.0
        let compLoss = NetworkHistoryStore.compare(sample: sample, baseline: memory)
        #expect(compLoss.lossVerdict == .degraded)
        #expect(compLoss.summaryDescription.contains("8% packet loss"))
    }

    @Test func reliabilityGradeThresholds() {
        var net = makeSampleNetwork()
        
        // 100% -> Excellent
        net.checkCount = 10
        net.severityCounts = ["ok": 10, "warn": 0, "critical": 0]
        var mem = NetworkHistoryStore.memory(for: net, displayName: "Net", runs: [])
        #expect(mem.reliabilityGrade == "Excellent")

        // 96% -> Excellent
        net.checkCount = 100
        net.severityCounts = ["ok": 96, "warn": 4, "critical": 0]
        mem = NetworkHistoryStore.memory(for: net, displayName: "Net", runs: [])
        #expect(mem.reliabilityGrade == "Excellent")

        // 90% -> Good
        net.checkCount = 100
        net.severityCounts = ["ok": 90, "warn": 10, "critical": 0]
        mem = NetworkHistoryStore.memory(for: net, displayName: "Net", runs: [])
        #expect(mem.reliabilityGrade == "Good")

        // 80% -> Fair
        net.checkCount = 100
        net.severityCounts = ["ok": 80, "warn": 20, "critical": 0]
        mem = NetworkHistoryStore.memory(for: net, displayName: "Net", runs: [])
        #expect(mem.reliabilityGrade == "Fair")

        // 60% -> Degraded
        net.checkCount = 100
        net.severityCounts = ["ok": 60, "warn": 40, "critical": 0]
        mem = NetworkHistoryStore.memory(for: net, displayName: "Net", runs: [])
        #expect(mem.reliabilityGrade == "Degraded")
    }
}
