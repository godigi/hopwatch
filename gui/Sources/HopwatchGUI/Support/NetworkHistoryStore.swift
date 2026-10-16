import Foundation

/// Models a high-level "Network Memory" profile synthesized from historical runs
/// and statistics for a single network identity.
struct NetworkMemory: Identifiable, Sendable, Equatable {
    let id: String
    let displayName: String
    let ssids: [String]
    let gateways: [String]
    let isps: [String]
    let lastSeenDate: Date?
    let checkCount: Int
    let runCount: Int
    let incidentCount: Int

    // Performance profile (medians / typicals)
    let typicalGatewayLatencyMs: Double?
    let typicalInternetLatencyMs: Double?
    let typicalGatewayJitterMs: Double?
    let typicalDownMbps: Double?
    let peakDownMbps: Double?
    let typicalUpMbps: Double?
    let peakUpMbps: Double?

    // Reliability
    let reliabilityPercent: Double?
    let reliabilityGrade: String
    let isLearningBaseline: Bool
    let speedTestCount: Int
    let requiresPortal: Bool

    init(
        id: String,
        displayName: String,
        ssids: [String] = [],
        gateways: [String] = [],
        isps: [String] = [],
        lastSeenDate: Date? = nil,
        checkCount: Int = 0,
        runCount: Int = 0,
        incidentCount: Int = 0,
        typicalGatewayLatencyMs: Double? = nil,
        typicalInternetLatencyMs: Double? = nil,
        typicalGatewayJitterMs: Double? = nil,
        typicalDownMbps: Double? = nil,
        peakDownMbps: Double? = nil,
        typicalUpMbps: Double? = nil,
        peakUpMbps: Double? = nil,
        reliabilityPercent: Double? = nil,
        reliabilityGrade: String = "Good",
        isLearningBaseline: Bool = false,
        speedTestCount: Int = 0,
        requiresPortal: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.ssids = ssids
        self.gateways = gateways
        self.isps = isps
        self.lastSeenDate = lastSeenDate
        self.checkCount = checkCount
        self.runCount = runCount
        self.incidentCount = incidentCount
        self.typicalGatewayLatencyMs = typicalGatewayLatencyMs
        self.typicalInternetLatencyMs = typicalInternetLatencyMs
        self.typicalGatewayJitterMs = typicalGatewayJitterMs
        self.typicalDownMbps = typicalDownMbps
        self.peakDownMbps = peakDownMbps
        self.typicalUpMbps = typicalUpMbps
        self.peakUpMbps = peakUpMbps
        self.reliabilityPercent = reliabilityPercent
        self.reliabilityGrade = reliabilityGrade
        self.isLearningBaseline = isLearningBaseline
        self.speedTestCount = speedTestCount
        self.requiresPortal = requiresPortal
    }

    /// Quick summary rating string for list rows (e.g. "450 Mbps · 12 ms · 99% reliable").
    var summaryChipText: String {
        var parts: [String] = []
        if let down = typicalDownMbps {
            parts.append(String(format: "%.0f Mbps", down))
        }
        if let lat = typicalGatewayLatencyMs ?? typicalInternetLatencyMs {
            parts.append(String(format: "%.0f ms", lat))
        }
        if let rel = reliabilityPercent {
            if checkCount >= 5 {
                parts.append(String(format: "%.0f%% reliable", rel))
            } else if incidentCount == 0 {
                parts.append("Clean link")
            } else {
                parts.append("\(checkCount) check\(checkCount == 1 ? "" : "s")")
            }
        }
        if parts.isEmpty {
            if checkCount > 0 {
                return "\(checkCount) check\(checkCount == 1 ? "" : "s")"
            }
            return "No checks"
        }
        return parts.joined(separator: " · ")
    }
}

/// Comparison between current real-time or snapshot metrics and the network memory baseline.
struct NetworkComparison: Sendable, Equatable {
    enum MetricVerdict: String, Sendable, Equatable {
        case faster = "Faster"
        case normal = "Normal"
        case slower = "Slower"
        case degraded = "Degraded"
    }

    let currentGatewayLatencyMs: Double?
    let baselineGatewayLatencyMs: Double?
    let gatewayLatencyVerdict: MetricVerdict
    let gatewayLatencyDeltaMs: Double?

    let currentLossPct: Double?
    let baselineLossPct: Double?
    let lossVerdict: MetricVerdict

    let currentDownMbps: Double?
    let baselineDownMbps: Double?
    let downSpeedVerdict: MetricVerdict?

    init(
        currentGatewayLatencyMs: Double?,
        baselineGatewayLatencyMs: Double?,
        gatewayLatencyVerdict: MetricVerdict,
        gatewayLatencyDeltaMs: Double?,
        currentLossPct: Double?,
        baselineLossPct: Double?,
        lossVerdict: MetricVerdict,
        currentDownMbps: Double? = nil,
        baselineDownMbps: Double? = nil,
        downSpeedVerdict: MetricVerdict? = nil
    ) {
        self.currentGatewayLatencyMs = currentGatewayLatencyMs
        self.baselineGatewayLatencyMs = baselineGatewayLatencyMs
        self.gatewayLatencyVerdict = gatewayLatencyVerdict
        self.gatewayLatencyDeltaMs = gatewayLatencyDeltaMs
        self.currentLossPct = currentLossPct
        self.baselineLossPct = baselineLossPct
        self.lossVerdict = lossVerdict
        self.currentDownMbps = currentDownMbps
        self.baselineDownMbps = baselineDownMbps
        self.downSpeedVerdict = downSpeedVerdict
    }

    var summaryDescription: String {
        var notes: [String] = []
        if let delta = gatewayLatencyDeltaMs {
            let rounded = abs(round(delta))
            if delta <= -3 {
                notes.append("\(Int(rounded)) ms faster than typical")
            } else if delta >= 5 {
                notes.append("\(Int(rounded)) ms slower than typical")
            } else {
                notes.append("Typical latency")
            }
        }
        if let loss = currentLossPct, loss > 0 {
            notes.append(LossFormatter.formatPacketLoss(loss))
        }
        if notes.isEmpty {
            return "Typical performance for this network"
        }
        return notes.joined(separator: " · ")
    }
}

/// Helper and aggregation engine for network memory profiles.
enum NetworkHistoryStore {

    /// Synthesizes a `NetworkMemory` from a `HistoryDocument.Network` and its historical runs.
    static func memory(
        for network: HistoryDocument.Network,
        displayName: String,
        runs: [HistoryDocument.Run] = [],
        activeSpeedTest: (down: Double, up: Double)? = nil,
        activeLiveMetrics: (gatewayLatency: Double?, internetLatency: Double?, jitter: Double?)? = nil
    ) -> NetworkMemory {
        let checks = network.checkCount ?? network.runCount
        let incidents = network.incidentCount

        var typicalGWLatency = network.stat(for: "gateway_rtt_ms")?.median
        var typicalInetLatency = network.stat(for: "inet_rtt_ms")?.median
        var typicalGWJitter = network.stat(for: "gateway_jitter_ms")?.median
        var typicalDown = network.stat(for: "speed_down_mbps")?.median
        var typicalUp = network.stat(for: "speed_up_mbps")?.median

        // Fall back to local calculation from runs when the CLI withholds stats (e.g. <10 checks or custom merge)
        if typicalGWLatency == nil {
            typicalGWLatency = localMedian(from: runs, key: "gateway_rtt_ms")
        }
        if typicalInetLatency == nil {
            typicalInetLatency = localMedian(from: runs, key: "inet_rtt_ms")
        }
        if typicalGWJitter == nil {
            typicalGWJitter = localMedian(from: runs, key: "gateway_jitter_ms")
        }
        if typicalDown == nil {
            typicalDown = localMedian(from: runs, keys: ["speed_down_mbps", "speedtest.down_mbps"])
        }
        if typicalUp == nil {
            typicalUp = localMedian(from: runs, keys: ["speed_up_mbps", "speedtest.up_mbps"])
        }

        // Active live/coordinator fallbacks for current network
        if typicalDown == nil, let act = activeSpeedTest {
            typicalDown = act.down
        }
        if typicalUp == nil, let act = activeSpeedTest {
            typicalUp = act.up
        }
        if typicalGWLatency == nil, let gw = activeLiveMetrics?.gatewayLatency {
            typicalGWLatency = gw
        }
        if typicalInetLatency == nil, let inet = activeLiveMetrics?.internetLatency {
            typicalInetLatency = inet
        }
        if typicalGWJitter == nil, let jit = activeLiveMetrics?.jitter {
            typicalGWJitter = jit
        }

        // Count speed tests and peak throughput across available runs + active test
        var peakDown: Double? = typicalDown
        var peakUp: Double? = typicalUp
        var speedTestCount = 0
        for run in runs {
            let d = run.metrics["speed_down_mbps"] ?? run.metrics["speedtest.down_mbps"]
            let u = run.metrics["speed_up_mbps"] ?? run.metrics["speedtest.up_mbps"]
            if d != nil || u != nil {
                speedTestCount += 1
            }
            if let d { peakDown = max(peakDown ?? 0, d) }
            if let u { peakUp = max(peakUp ?? 0, u) }
        }
        if let act = activeSpeedTest {
            peakDown = max(peakDown ?? 0, act.down)
            peakUp = max(peakUp ?? 0, act.up)
            if speedTestCount == 0 {
                speedTestCount = 1
            }
        }

        // Reliability percentage: fraction of clean checks without critical or warning diagnoses
        let isLearning = checks < 10
        var reliabilityPercent: Double? = nil
        var reliabilityGrade = isLearning ? "Learning" : "Good"
        if checks > 0 {
            let clean = max(0, checks - incidents)
            let pct = (Double(clean) / Double(checks)) * 100.0
            reliabilityPercent = pct
            if isLearning {
                if incidents == 0 {
                    reliabilityGrade = "Learning (Stable)"
                } else if pct >= 70.0 {
                    reliabilityGrade = "Learning (Good)"
                } else {
                    reliabilityGrade = "Learning (Building)"
                }
            } else {
                if pct >= 95.0 {
                    reliabilityGrade = "Excellent"
                } else if pct >= 85.0 {
                    reliabilityGrade = "Good"
                } else if pct >= 70.0 {
                    reliabilityGrade = "Fair"
                } else {
                    reliabilityGrade = "Degraded"
                }
            }
        }

        let requiresPortal = Defaults.portalNetworks.contains(network.id)
            || network.ssids.contains { Defaults.portalNetworks.contains("ssid:\($0)") }

        return NetworkMemory(
            id: network.id,
            displayName: displayName,
            ssids: network.ssids,
            gateways: network.gateways,
            isps: network.isps,
            lastSeenDate: network.lastSeenDate,
            checkCount: checks,
            runCount: network.runCount,
            incidentCount: incidents,
            typicalGatewayLatencyMs: typicalGWLatency,
            typicalInternetLatencyMs: typicalInetLatency,
            typicalGatewayJitterMs: typicalGWJitter,
            typicalDownMbps: typicalDown,
            peakDownMbps: peakDown,
            typicalUpMbps: typicalUp,
            peakUpMbps: peakUp,
            reliabilityPercent: reliabilityPercent,
            reliabilityGrade: reliabilityGrade,
            isLearningBaseline: isLearning,
            speedTestCount: speedTestCount,
            requiresPortal: requiresPortal
        )
    }

    private static func localMedian(from runs: [HistoryDocument.Run], keys: [String]) -> Double? {
        let values = runs.compactMap { run -> Double? in
            for key in keys {
                if let val = run.metrics[key], val.isFinite { return val }
            }
            return nil
        }.sorted()
        guard !values.isEmpty else { return nil }
        let mid = values.count / 2
        return values.count.isMultiple(of: 2)
            ? (values[mid - 1] + values[mid]) / 2.0
            : values[mid]
    }

    private static func localMedian(from runs: [HistoryDocument.Run], key: String) -> Double? {
        localMedian(from: runs, keys: [key])
    }

    /// Compares a snapshot against a network memory baseline.
    static func compare(
        snapshot: RunSnapshot,
        baseline: NetworkMemory,
        fallbackDownMbps: Double? = nil
    ) -> NetworkComparison {
        let currentGW = snapshot.gateway.rttAvgMs
        let baseGW = baseline.typicalGatewayLatencyMs
        var deltaGW: Double? = nil
        var verdictGW: NetworkComparison.MetricVerdict = .normal
        if let cur = currentGW, let base = baseGW {
            let diff = cur - base
            deltaGW = diff
            if diff <= -3.0 {
                verdictGW = .faster
            } else if diff >= 5.0 {
                verdictGW = .slower
            }
        }

        let currentLoss = snapshot.gateway.lossPct
        let baseLoss = 0.0
        var verdictLoss: NetworkComparison.MetricVerdict = .normal
        if let curLoss = currentLoss, curLoss > 2.0 {
            verdictLoss = .degraded
        }

        let currentDown = snapshot.speedtest?.downMbps ?? fallbackDownMbps
        let baseDown = baseline.typicalDownMbps
        var verdictDown: NetworkComparison.MetricVerdict? = nil
        if let cur = currentDown, let base = baseDown, base > 0 {
            let ratio = cur / base
            if ratio >= 1.2 {
                verdictDown = .faster
            } else if ratio <= 0.75 {
                verdictDown = .slower
            } else {
                verdictDown = .normal
            }
        }

        return NetworkComparison(
            currentGatewayLatencyMs: currentGW,
            baselineGatewayLatencyMs: baseGW,
            gatewayLatencyVerdict: verdictGW,
            gatewayLatencyDeltaMs: deltaGW,
            currentLossPct: currentLoss,
            baselineLossPct: baseLoss,
            lossVerdict: verdictLoss,
            currentDownMbps: currentDown,
            baselineDownMbps: baseDown,
            downSpeedVerdict: verdictDown
        )
    }

    /// Compares a monitor sample against a network memory baseline.
    static func compare(
        sample: MonitorSample,
        baseline: NetworkMemory,
        fallbackDownMbps: Double? = nil
    ) -> NetworkComparison {
        let currentGW = sample.gateway.rttAvgMs
        let baseGW = baseline.typicalGatewayLatencyMs
        var deltaGW: Double? = nil
        var verdictGW: NetworkComparison.MetricVerdict = .normal
        if let cur = currentGW, let base = baseGW {
            let diff = cur - base
            deltaGW = diff
            if diff <= -3.0 {
                verdictGW = .faster
            } else if diff >= 5.0 {
                verdictGW = .slower
            }
        }

        let currentLoss = sample.gateway.lossPct
        let baseLoss = 0.0
        var verdictLoss: NetworkComparison.MetricVerdict = .normal
        if let curLoss = currentLoss, curLoss > 2.0 {
            verdictLoss = .degraded
        }

        let currentDown = fallbackDownMbps
        let baseDown = baseline.typicalDownMbps
        var verdictDown: NetworkComparison.MetricVerdict? = nil
        if let cur = currentDown, let base = baseDown, base > 0 {
            let ratio = cur / base
            if ratio >= 1.2 {
                verdictDown = .faster
            } else if ratio <= 0.75 {
                verdictDown = .slower
            } else {
                verdictDown = .normal
            }
        }

        return NetworkComparison(
            currentGatewayLatencyMs: currentGW,
            baselineGatewayLatencyMs: baseGW,
            gatewayLatencyVerdict: verdictGW,
            gatewayLatencyDeltaMs: deltaGW,
            currentLossPct: currentLoss,
            baselineLossPct: baseLoss,
            lossVerdict: verdictLoss,
            currentDownMbps: currentDown,
            baselineDownMbps: baseDown,
            downSpeedVerdict: verdictDown
        )
    }
}
