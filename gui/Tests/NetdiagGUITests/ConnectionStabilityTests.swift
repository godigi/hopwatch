import Foundation
import Testing
@testable import NetdiagGUI

@Suite struct ConnectionStabilityTests {

    @Test func stabilityThresholds() {
        // Optimal: RTT < 35, Jitter < 8, Loss == 0%
        let opt = ConnectionStability.evaluate(rtt: 25.0, jitter: 4.0, loss: 0.0)
        #expect(opt.level == .optimal)
        #expect(opt.label == "Optimal")
        #expect(opt.icon == "checkmark.circle.fill")

        // Variable: RTT between 35 and 150
        let varRtt = ConnectionStability.evaluate(rtt: 60.0, jitter: 5.0, loss: 0.0)
        #expect(varRtt.level == .variable)
        #expect(varRtt.label == "Variable")

        // High Jitter: Jitter between 20 and 50
        let highJitter = ConnectionStability.evaluate(rtt: 25.0, jitter: 35.0, loss: 0.0)
        #expect(highJitter.level == .variable)
        #expect(highJitter.label == "High Jitter")

        // Unstable: Loss > 2%
        let unstLoss = ConnectionStability.evaluate(rtt: 20.0, jitter: 2.0, loss: 3.5)
        #expect(unstLoss.level == .unstable)
        #expect(unstLoss.label == "Unstable")
        #expect(unstLoss.icon == "exclamationmark.triangle.fill")

        // Unstable: Jitter > 50ms
        let unstJitter = ConnectionStability.evaluate(rtt: 20.0, jitter: 55.0, loss: 0.0)
        #expect(unstJitter.level == .unstable)

        // Unstable: RTT > 150ms
        let unstRtt = ConnectionStability.evaluate(rtt: 160.0, jitter: 5.0, loss: 0.0)
        #expect(unstRtt.level == .unstable)
    }

    @Test func movingJitterCalculation() {
        let s1 = MonitorSample(internet: .init(lossPct: 0, rttAvgMs: 20.0))
        let s2 = MonitorSample(internet: .init(lossPct: 0, rttAvgMs: 36.0))
        let s3 = MonitorSample(internet: .init(lossPct: 0, rttAvgMs: 24.0))

        let jitter = MonitorSeries.movingJitter(samples: [s1, s2, s3])
        #expect(jitter != nil)
        // Step 1: D = |36 - 20| = 16.0 -> J_1 = 16.0
        // Step 2: D = |24 - 36| = 12.0 -> J_2 = 16.0 + (12.0 - 16.0)/16.0 = 16.0 - 0.25 = 15.75
        if let j = jitter {
            #expect(abs(j - 15.75) < 0.001)
        }
    }

    @Test func prefersLiveJitterOverCalculated() {
        let s1 = MonitorSample(internet: .init(lossPct: 0, rttAvgMs: 20.0))
        let s2 = MonitorSample(internet: .init(lossPct: 0, rttAvgMs: 80.0, rttJitterMs: 3.2))
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
}
