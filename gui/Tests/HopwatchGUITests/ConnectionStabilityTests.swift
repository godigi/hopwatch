import Foundation
import Testing
@testable import HopwatchGUI

@Suite struct ConnectionStabilityTests {

    @Test func stabilityThresholds() {
        // Optimal: nothing over the CLI's cutoffs
        let opt = ConnectionStability.evaluate(rtt: 55.0, jitter: 9.0, loss: 0.0)
        #expect(opt.level == .optimal)
        #expect(opt.label == "Optimal")
        #expect(opt.icon == "checkmark.circle.fill")

        // Small loss and moderate jitter are not findings: still Optimal
        let smallLoss = ConnectionStability.evaluate(rtt: 55.0, jitter: 18.0, loss: 5.0)
        #expect(smallLoss.level == .optimal)

        // Latency alone is never rated: the CLI has no latency-only rule
        let highRtt = ConnectionStability.evaluate(rtt: 160.0, jitter: 5.0, loss: 0.0)
        #expect(highRtt.level == .optimal)

        // High Jitter at the CLI's jitter cutoff (30 ms), and never red for it
        let highJitter = ConnectionStability.evaluate(rtt: 25.0, jitter: 35.0, loss: 0.0)
        #expect(highJitter.level == .variable)
        #expect(highJitter.label == "High Jitter")
        let hugeJitter = ConnectionStability.evaluate(rtt: 20.0, jitter: 55.0, loss: 0.0)
        #expect(hugeJitter.level == .variable)

        // Packet loss at the CLI's warn cutoff (10%)
        let packetLoss = ConnectionStability.evaluate(rtt: 20.0, jitter: 2.0, loss: 10.0)
        #expect(packetLoss.level == .variable)
        #expect(packetLoss.label == "Packet Loss")

        // Unstable at the CLI's critical cutoff (20%)
        let unstLoss = ConnectionStability.evaluate(rtt: 20.0, jitter: 2.0, loss: 20.0)
        #expect(unstLoss.level == .unstable)
        #expect(unstLoss.label == "Unstable")
        #expect(unstLoss.icon == "exclamationmark.triangle.fill")
    }

    @Test func movingJitterCalculation() {
        let s1 = MonitorSample(link: .init(up: true), internet: .init(lossPct: 0, rttAvgMs: 20.0))
        let s2 = MonitorSample(link: .init(up: true), internet: .init(lossPct: 0, rttAvgMs: 36.0))
        let s3 = MonitorSample(link: .init(up: true), internet: .init(lossPct: 0, rttAvgMs: 24.0))

        let jitter = MonitorSeries.movingJitter(samples: [s1, s2, s3])
        #expect(jitter != nil)
        // Step 1: D = |36 - 20| = 16.0 -> J_1 = 16.0
        // Step 2: D = |24 - 36| = 12.0 -> J_2 = 16.0 + (12.0 - 16.0)/16.0 = 16.0 - 0.25 = 15.75
        if let j = jitter {
            #expect(abs(j - 15.75) < 0.001)
        }
    }

    @Test func prefersLiveJitterOverCalculated() {
        let s1 = MonitorSample(link: .init(up: true), internet: .init(lossPct: 0, rttAvgMs: 20.0))
        let s2 = MonitorSample(link: .init(up: true), internet: .init(lossPct: 0, rttAvgMs: 80.0, rttJitterMs: 3.2))
        let jitter = MonitorSeries.movingJitter(samples: [s1, s2])
        #expect(jitter == 3.2)
    }

    @Test func decodesJitterFromSampleJSON() throws {
        let json = """
        {
            "ts": "2026-09-12T18:00:00Z",
            "seq": 10,
            "jitter_ms": 4.75,
            "gateway": {
                "loss_pct": 0.0,
                "rtt_avg_ms": 2.1,
                "rtt_jitter_ms": 0.8
            },
            "internet": {
                "loss_pct": 0.0,
                "rtt_avg_ms": 22.4,
                "rtt_jitter_ms": 4.75
            },
            "wifi": {},
            "dns": {},
            "tcp": {},
            "status": {}
        }
        """.data(using: .utf8)!

        let sample = try JSONDecoder().decode(MonitorSample.self, from: json)
        #expect(sample.jitterMs == 4.75)
        #expect(sample.gateway.rttJitterMs == 0.8)
        #expect(sample.internet.rttJitterMs == 4.75)
        #expect(sample.liveJitterMs == 4.75)
    }

    @Test func handlesNilMeasurementsGracefully() {
        let unknown = ConnectionStability.evaluate(rtt: nil, jitter: nil, loss: nil)
        #expect(unknown.label == "Unknown")
        #expect(unknown.icon == "questionmark.circle")

        let emptyJitter = MonitorSeries.movingJitter(samples: [])
        #expect(emptyJitter == nil)
    }

    @Test func dropTrackingInMonitorSeries() {
        let t0 = Date()
        let t1 = t0.addingTimeInterval(10)
        let t2 = t0.addingTimeInterval(20)

        var s1 = MonitorSample()
        s1.ts = HistoryDocument.iso.string(from: t0)
        s1.refreshed = ["fast"]
        s1.internet.rttAvgMs = 24.0

        var s2 = MonitorSample()
        s2.ts = HistoryDocument.iso.string(from: t1)
        s2.refreshed = ["fast"]
        s2.internet.lossPct = 100.0
        s2.internet.rttAvgMs = nil

        var s3 = MonitorSample()
        s3.ts = HistoryDocument.iso.string(from: t2)
        s3.refreshed = ["fast"]
        s3.internet.rttAvgMs = 26.0

        let result = MonitorSeries.build(
            [s1, s2, s3],
            tier: "fast",
            isDrop: { ($0.internet.lossPct ?? 0) >= 100 || $0.internet.rttAvgMs == nil },
            value: { $0.internet.rttAvgMs }
        )

        #expect(result.points.count == 2)
        #expect(result.drops.count == 1)
        #expect(result.drops.first?.date == s2.timestamp)
        #expect(result.segments.count == 2)
    }
}
