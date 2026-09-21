import Foundation
import Testing
@testable import HopwatchGUI

@Suite struct SuitabilityEngineTests {

    @Test func streamingWorksFineWithBadPingAndHighBandwidth() {
        // High ping (350ms) and bufferbloat, but 100 Mbps download speed and 0% loss
        var sample = MonitorSample()
        sample.internet = .init(lossPct: 0.0, rttAvgMs: 350.0, rttJitterMs: 40.0)

        let speed = RunSnapshot.Speedtest(downMbps: 120.0, upMbps: 25.0)

        let inputs = SuitabilityEngine.Inputs(
            monitorSample: sample,
            speedTest: speed,
            isLinkUp: true,
            currentJitter: 40.0,
            effectiveLoss: 0.0
        )

        let streaming = SuitabilityEngine.evaluateStreaming(inputs)
        #expect(streaming.verdict == .good)
        #expect(streaming.status == "4K ready")
        #expect(streaming.metric == "120 Mbps ↓")

        // In contrast, gaming under 350ms ping should be flagged as severe lag
        let gaming = SuitabilityEngine.evaluateGaming(inputs)
        #expect(gaming.verdict == .broken)
        #expect(gaming.status == "Severe lag")
    }

    @Test func streamingDegradesOnLowBandwidthOrExtremeLoss() {
        var sample = MonitorSample()
        sample.internet = .init(lossPct: 20.0, rttAvgMs: 15.0, rttJitterMs: 2.0)

        let lowSpeed = RunSnapshot.Speedtest(downMbps: 2.0, upMbps: 1.0)

        let inputs = SuitabilityEngine.Inputs(
            monitorSample: sample,
            speedTest: lowSpeed,
            isLinkUp: true,
            effectiveLoss: 20.0
        )

        let streaming = SuitabilityEngine.evaluateStreaming(inputs)
        #expect(streaming.verdict == .broken)
        #expect(streaming.status == "Buffering")
    }

    @Test func callsDependOnPacketLossAndJitterNotPing() {
        // Ping is 120ms (e.g. transatlantic), but 0% loss and 3ms jitter
        var sample = MonitorSample()
        sample.internet = .init(lossPct: 0.0, rttAvgMs: 120.0, rttJitterMs: 3.0)

        let inputsGood = SuitabilityEngine.Inputs(
            monitorSample: sample,
            isLinkUp: true,
            currentJitter: 3.0,
            effectiveLoss: 0.0
        )

        let callsGood = SuitabilityEngine.evaluateCalls(inputsGood)
        #expect(callsGood.verdict == .good)
        #expect(callsGood.status == "Clear audio")

        // Now introduce 3% packet loss (audio cutouts likely)
        let inputsLoss = SuitabilityEngine.Inputs(
            monitorSample: sample,
            isLinkUp: true,
            currentJitter: 3.0,
            effectiveLoss: 3.0
        )

        let callsLoss = SuitabilityEngine.evaluateCalls(inputsLoss)
        #expect(callsLoss.verdict == .degraded)
        #expect(callsLoss.status == "May cut out")

        // Now severe packet loss 8%
        let inputsSevere = SuitabilityEngine.Inputs(
            monitorSample: sample,
            isLinkUp: true,
            currentJitter: 3.0,
            effectiveLoss: 8.0
        )

        let callsSevere = SuitabilityEngine.evaluateCalls(inputsSevere)
        #expect(callsSevere.verdict == .broken)
        #expect(callsSevere.status == "Frequent cutouts")
    }

    @Test func gamingPrioritizesPingAndJitter() {
        var sampleFast = MonitorSample()
        sampleFast.internet = .init(lossPct: 0.0, rttAvgMs: 18.0, rttJitterMs: 2.0)

        let inputsFast = SuitabilityEngine.Inputs(
            monitorSample: sampleFast,
            isLinkUp: true,
            currentJitter: 2.0,
            effectiveLoss: 0.0
        )

        let gamingFast = SuitabilityEngine.evaluateGaming(inputsFast)
        #expect(gamingFast.verdict == .good)
        #expect(gamingFast.status == "Low ping")

        // Moderate latency 95ms
        var sampleLag = MonitorSample()
        sampleLag.internet = .init(lossPct: 0.0, rttAvgMs: 95.0, rttJitterMs: 4.0)

        let inputsLag = SuitabilityEngine.Inputs(
            monitorSample: sampleLag,
            isLinkUp: true,
            currentJitter: 4.0,
            effectiveLoss: 0.0
        )

        let gamingLag = SuitabilityEngine.evaluateGaming(inputsLag)
        #expect(gamingLag.verdict == .degraded)
        #expect(gamingLag.status == "Moderate lag")
    }

    @Test func vpnDetectsDoubleNatAndMTUClamping() {
        let inputsClean = SuitabilityEngine.Inputs(
            isLinkUp: true,
            isDoubleNat: false,
            mtu: 1500,
            vpnActive: false
        )
        let vpnClean = SuitabilityEngine.evaluateVPN(inputsClean)
        #expect(vpnClean.verdict == .good)
        #expect(vpnClean.status == "Compatible")

        let inputsDoubleNat = SuitabilityEngine.Inputs(
            isLinkUp: true,
            isDoubleNat: true,
            mtu: 1500,
            vpnActive: false
        )
        let vpnDoubleNat = SuitabilityEngine.evaluateVPN(inputsDoubleNat)
        #expect(vpnDoubleNat.verdict == .degraded)
        #expect(vpnDoubleNat.status == "Double NAT")

        let inputsClamped = SuitabilityEngine.Inputs(
            isLinkUp: true,
            isDoubleNat: false,
            mtu: 1350,
            vpnActive: false
        )
        let vpnClamped = SuitabilityEngine.evaluateVPN(inputsClamped)
        #expect(vpnClamped.verdict == .degraded)
        #expect(vpnClamped.status == "MTU clamped")
    }

    @Test func offlineLinkFailsAllActivities() {
        let inputsOffline = SuitabilityEngine.Inputs(
            isLinkUp: false
        )
        let all = SuitabilityEngine.evaluateAll(inputsOffline)
        #expect(all.count == 5)
        for item in all {
            #expect(item.verdict == .broken)
            #expect(item.status == "Offline")
        }
    }

    @Test func synthesizeDegradedExperienceWithCallsAndGamingDegraded() {
        var sample = MonitorSample()
        sample.gateway = .init(lossPct: 4.0, rttAvgMs: 29.0, rttJitterMs: 50.0)
        sample.internet = .init(lossPct: 4.0, rttAvgMs: 101.0, rttJitterMs: 56.0)

        let speed = RunSnapshot.Speedtest(downMbps: 539.0, upMbps: 307.0)

        let inputs = SuitabilityEngine.Inputs(
            monitorSample: sample,
            speedTest: speed,
            isLinkUp: true,
            currentJitter: 56.0,
            effectiveLoss: 4.0
        )

        let items = SuitabilityEngine.evaluateAll(inputs)
        let degraded = SuitabilityEngine.synthesizeDegradedExperience(
            items: items,
            monitorSample: sample,
            currentJitter: 56.0,
            effectiveLoss: 4.0
        )

        #expect(degraded != nil)
        #expect(degraded?.headline == "Unstable for calls & gaming")
        #expect(degraded?.isCritical == true)
        #expect(degraded?.affectedActivities == ["Calls", "Gaming"])
        #expect(degraded?.subtitle.contains("4% packet loss") == true)
        #expect(degraded?.subtitle.contains("56ms jitter") == true)
        #expect(degraded?.subtitle.contains("to router") == true)
        #expect(degraded?.subtitle.contains("4K streaming is fine") == true)
    }

    @Test func synthesizeDegradedExperienceHighPingForGaming() {
        var sample = MonitorSample()
        sample.gateway = .init(lossPct: 0.0, rttAvgMs: 2.0, rttJitterMs: 1.0)
        sample.internet = .init(lossPct: 0.0, rttAvgMs: 220.0, rttJitterMs: 4.0)

        let speed = RunSnapshot.Speedtest(downMbps: 150.0, upMbps: 50.0)

        let inputs = SuitabilityEngine.Inputs(
            monitorSample: sample,
            speedTest: speed,
            isLinkUp: true,
            currentJitter: 4.0,
            effectiveLoss: 0.0
        )

        let items = SuitabilityEngine.evaluateAll(inputs)
        let degraded = SuitabilityEngine.synthesizeDegradedExperience(
            items: items,
            monitorSample: sample,
            currentJitter: 4.0,
            effectiveLoss: 0.0
        )

        #expect(degraded != nil)
        #expect(degraded?.headline == "High lag for gaming")
        #expect(degraded?.affectedActivities.contains("Gaming") == true)
        #expect(degraded?.subtitle.contains("220 ms") == true)
    }

    @Test func synthesizeDegradedExperienceHealthyWhenZeroLossAndLowPing() {
        var sample = MonitorSample()
        sample.gateway = .init(lossPct: 0.0, rttAvgMs: 2.0, rttJitterMs: 1.0)
        sample.internet = .init(lossPct: 0.0, rttAvgMs: 15.0, rttJitterMs: 2.0)

        let speed = RunSnapshot.Speedtest(downMbps: 200.0, upMbps: 50.0)

        let inputs = SuitabilityEngine.Inputs(
            monitorSample: sample,
            speedTest: speed,
            isLinkUp: true,
            currentJitter: 2.0,
            effectiveLoss: 0.0
        )

        let items = SuitabilityEngine.evaluateAll(inputs)
        let degraded = SuitabilityEngine.synthesizeDegradedExperience(
            items: items,
            monitorSample: sample,
            currentJitter: 2.0,
            effectiveLoss: 0.0
        )

        #expect(degraded == nil)
    }
}
