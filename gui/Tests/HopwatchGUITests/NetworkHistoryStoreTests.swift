import Foundation
import Testing
@testable import HopwatchGUI

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

        // Monitor sample with standalone speed test fallback
        let compWithSpeed = NetworkHistoryStore.compare(sample: sample, baseline: memory, fallbackDownMbps: 450.0)
        #expect(compWithSpeed.currentDownMbps == 450.0)
        #expect(compWithSpeed.downSpeedVerdict == .faster)
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

    @Test func fallbackMediansComputedWhenStatsAreNil() {
        // Simulates a network with <10 checks where the CLI withholds metric_stats
        var net = makeSampleNetwork()
        net.checkCount = 3
        net.metricStats = nil
        net.severityCounts = ["ok": 1, "warn": 2, "critical": 0]

        var run1 = HistoryDocument.Run()
        run1.metrics = [
            "gateway_rtt_ms": 10.0,
            "inet_rtt_ms": 50.0,
            "speed_down_mbps": 360.0,
            "speed_up_mbps": 200.0,
        ]

        var run2 = HistoryDocument.Run()
        run2.metrics = [
            "gateway_rtt_ms": 3.0,
            "inet_rtt_ms": 6.0,
            "speed_down_mbps": 390.0,
            "speed_up_mbps": 210.0,
        ]

        var run3 = HistoryDocument.Run()
        run3.metrics = [
            "gateway_rtt_ms": 3.2,
            "inet_rtt_ms": 8.0,
        ]

        let mem = NetworkHistoryStore.memory(for: net, displayName: "My WiFi", runs: [run1, run2, run3])

        // Verify fallback medians are computed from runs
        #expect(mem.typicalGatewayLatencyMs == 3.2)
        #expect(mem.typicalInternetLatencyMs == 8.0)
        #expect(mem.typicalDownMbps == 375.0)
        #expect(mem.typicalUpMbps == 205.0)
        #expect(mem.peakDownMbps == 390.0)
        #expect(mem.speedTestCount == 2)
        #expect(mem.isLearningBaseline == true)
        // With <10 checks, it should NOT mark as "Degraded"
        #expect(mem.reliabilityGrade.contains("Learning"))
    }

    @Test @MainActor func canonicalIDFoldsWeakKeysOntoNetworkGroup() {
        let store = HistoryStore()
        var net = makeSampleNetwork()
        net.id = "mac:64:d1:54:4a:93:7f"
        net.gateways = ["10.125.128.1", "198.51.100.1"]
        net.ssids = ["Mercure"]
        net.bridgedFrom = ["ssid:Mercure"]

        var doc = HistoryDocument.empty
        doc.networks = [net]
        store.adoptDocumentForTesting(doc)

        // Weak SSID and public gateway keys fold onto the MAC group
        #expect(store.canonicalID("ssid:Mercure") == "mac:64:d1:54:4a:93:7f")
        #expect(store.canonicalID("wifi:ssid=Mercure") == "mac:64:d1:54:4a:93:7f")
        #expect(store.canonicalID("gw:198.51.100.1") == "mac:64:d1:54:4a:93:7f")
        #expect(store.canonicalID("mac:64:d1:54:4a:93:7f") == "mac:64:d1:54:4a:93:7f")

        // Private/local RFC-1918 gateway IPs must NEVER fold onto a network group
        #expect(store.canonicalID("gw:10.125.128.1") == "gw:10.125.128.1")
        #expect(store.canonicalID("wifi:gw=10.125.128.1") == "gw:10.125.128.1")

        // An unrelated network must not fold
        #expect(store.canonicalID("gw:192.168.1.1") == "gw:192.168.1.1")
    }

    @Test @MainActor func privateGatewayIPsNeverFoldAndNeverAdoptCustomNames() {
        let store = HistoryStore()
        var net = makeSampleNetwork()
        net.id = "mac:54:9f:6:cb:48:70"
        net.gateways = ["192.168.1.254"]
        net.ssids = ["Carlos&Delianne_5G"]

        var doc = HistoryDocument.empty
        doc.networks = [net]
        store.adoptDocumentForTesting(doc)

        // Ensure renaming a gateway IP is rejected
        store.rename("gw:192.168.1.254", to: "Bete Costa - 2G")
        #expect(store.customName(for: "gw:192.168.1.254") == nil)

        // Renaming the MAC group works
        store.rename("mac:54:9f:6:cb:48:70", to: "Carlos&Delianne_5G")
        #expect(store.customName(for: "mac:54:9f:6:cb:48:70") == "Carlos&Delianne_5G")

        // Looking up custom name for gw:192.168.1.254 must not return Carlos's name
        #expect(store.customName(for: "gw:192.168.1.254") == nil)
        #expect(store.canonicalID("gw:192.168.1.254") == "gw:192.168.1.254")
    }

    @Test @MainActor func corruptedSSIDRenamesArePurged() {
        let store = HistoryStore()
        var net1 = makeSampleNetwork()
        net1.id = "ssid:Flat Classic 203 - 204"
        net1.ssids = ["Flat Classic 203 - 204"]

        var net2 = makeSampleNetwork()
        net2.id = "ssid:Brian’s iPhone"
        net2.ssids = ["Brian’s iPhone"]

        var doc = HistoryDocument.empty
        doc.networks = [net1, net2]

        // Manually simulate corrupted names in customNames
        store.rename("ssid:Brian’s iPhone", to: "Flat Classic 203 - 204")
        #expect(store.customName(for: "ssid:Brian’s iPhone") == "Flat Classic 203 - 204")

        // Adopting the document should detect and purge the cross-SSID corruption
        store.adoptDocumentForTesting(doc)
        #expect(store.customName(for: "ssid:Brian’s iPhone") == nil)
        #expect(store.displayName(for: "ssid:Brian’s iPhone") == "Brian’s iPhone")
    }

    @Test @MainActor func privateGatewayIPsNeverPersistInArrivalStates() {
        // When arrivalStates are set, any private gateway key (e.g. gw:192.168.1.1) must be rejected
        Defaults.arrivalStates = [
            "gw:192.168.1.1": .declined(depth: .quick, reason: .unhealthy, at: Date()),
            "mac:68:2a:dd:9f:87:d1": .checked(depth: .full, at: Date(), runID: "run1"),
            "ssid:Circle 94_5G": .checked(depth: .full, at: Date(), runID: "run2")
        ]

        let retrieved = Defaults.arrivalStates
        #expect(retrieved["gw:192.168.1.1"] == nil)
        #expect(retrieved["mac:68:2a:dd:9f:87:d1"] != nil)
        #expect(retrieved["ssid:Circle 94_5G"] != nil)
    }

    @Test func arrivalPolicyWaitsDuringSettling() {
        // Even with a sample reporting critical severity, if the connection is settling, ArrivalPolicy waits
        let decision = ArrivalPolicy.decide(
            hasSample: true,
            severity: "critical",
            isExpensive: false,
            isConstrained: false,
            isSettling: true
        )
        #expect(decision == .wait)

        // Once settling ends, it makes the definitive decision
        let settledDecision = ArrivalPolicy.decide(
            hasSample: true,
            severity: "ok",
            isExpensive: false,
            isConstrained: false,
            isSettling: false
        )
        #expect(settledDecision == .full)
    }

    @Test func arrivalStateNeedsAttemptRetriesWhenUnhealthyDeclineBecomesHealthy() {
        let now = Date()
        let unhealthyDeclined = ArrivalState.declined(depth: .quick, reason: .unhealthy, at: now)
        #expect(unhealthyDeclined.needsAttempt(now: now))
        #expect(unhealthyDeclined.isDeclined)

        let hotspotDeclined = ArrivalState.declined(depth: .quick, reason: .hotspot, at: now)
        #expect(!hotspotDeclined.needsAttempt(now: now))
        #expect(hotspotDeclined.isDeclined)

        let fullChecked = ArrivalState.checked(depth: .full, at: now, runID: "run1")
        #expect(!fullChecked.needsAttempt(now: now))
        #expect(!fullChecked.isDeclined)
    }
}
