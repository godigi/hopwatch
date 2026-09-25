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

    @Test func callsDifferentiateJitterStutterLatencyDelayAndBandwidth() {
        // High jitter (30ms jitter, 0% loss) -> Audio stutter
        var sampleJitter = MonitorSample()
        sampleJitter.internet = .init(lossPct: 0.0, rttAvgMs: 30.0, rttJitterMs: 30.0)

        let inputsJitter = SuitabilityEngine.Inputs(
            monitorSample: sampleJitter,
            isLinkUp: true,
            currentJitter: 30.0,
            effectiveLoss: 0.0
        )
        let callsJitter = SuitabilityEngine.evaluateCalls(inputsJitter)
        #expect(callsJitter.verdict == .degraded)
        #expect(callsJitter.status == "Audio stutter")

        // Severe jitter (55ms jitter) -> Severe stutter
        let inputsSevereJitter = SuitabilityEngine.Inputs(
            monitorSample: sampleJitter,
            isLinkUp: true,
            currentJitter: 55.0,
            effectiveLoss: 0.0
        )
        let callsSevereJitter = SuitabilityEngine.evaluateCalls(inputsSevereJitter)
        #expect(callsSevereJitter.verdict == .broken)
        #expect(callsSevereJitter.status == "Severe stutter")

        // High latency (280ms ping, 0% loss, 3ms jitter) -> Audio delay
        var sampleDelay = MonitorSample()
        sampleDelay.internet = .init(lossPct: 0.0, rttAvgMs: 280.0, rttJitterMs: 3.0)

        let inputsDelay = SuitabilityEngine.Inputs(
            monitorSample: sampleDelay,
            isLinkUp: true,
            currentJitter: 3.0,
            effectiveLoss: 0.0
        )
        let callsDelay = SuitabilityEngine.evaluateCalls(inputsDelay)
        #expect(callsDelay.verdict == .degraded)
        #expect(callsDelay.status == "Audio delay")
        #expect(callsDelay.metric == "280 ms delay")

        // Extreme latency (420ms ping) -> Heavy delay
        var sampleHeavyDelay = MonitorSample()
        sampleHeavyDelay.internet = .init(lossPct: 0.0, rttAvgMs: 420.0, rttJitterMs: 3.0)

        let inputsHeavyDelay = SuitabilityEngine.Inputs(
            monitorSample: sampleHeavyDelay,
            isLinkUp: true,
            currentJitter: 3.0,
            effectiveLoss: 0.0
        )
        let callsHeavyDelay = SuitabilityEngine.evaluateCalls(inputsHeavyDelay)
        #expect(callsHeavyDelay.verdict == .broken)
        #expect(callsHeavyDelay.status == "Heavy delay")
        #expect(callsHeavyDelay.metric == "420 ms delay")

        // Low upload bandwidth (0.7 Mbps) -> Video limited
        var sampleClean = MonitorSample()
        sampleClean.internet = .init(lossPct: 0.0, rttAvgMs: 20.0, rttJitterMs: 2.0)
        let speedChoked = RunSnapshot.Speedtest(downMbps: 20.0, upMbps: 0.7)

        let inputsChoked = SuitabilityEngine.Inputs(
            monitorSample: sampleClean,
            speedTest: speedChoked,
            isLinkUp: true,
            currentJitter: 2.0,
            effectiveLoss: 0.0
        )
        let callsChoked = SuitabilityEngine.evaluateCalls(inputsChoked)
        #expect(callsChoked.verdict == .degraded)
        #expect(callsChoked.status == "Video limited")
        #expect(callsChoked.metric == "0.7 Mbps ↑")

        // Fast upload bandwidth (15 Mbps) -> HD video ready
        let speedFast = RunSnapshot.Speedtest(downMbps: 150.0, upMbps: 15.0)
        let inputsHD = SuitabilityEngine.Inputs(
            monitorSample: sampleClean,
            speedTest: speedFast,
            isLinkUp: true,
            currentJitter: 2.0,
            effectiveLoss: 0.0
        )
        let callsHD = SuitabilityEngine.evaluateCalls(inputsHD)
        #expect(callsHD.verdict == .good)
        #expect(callsHD.status == "HD video ready")
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
        #expect(gamingFast.status == "Responsive")
        #expect(gamingFast.metric == "18 ms · 2ms jit")

        // Smooth tier: 50ms latency, 4ms jitter
        var sampleSmooth = MonitorSample()
        sampleSmooth.internet = .init(lossPct: 0.0, rttAvgMs: 50.0, rttJitterMs: 4.0)

        let inputsSmooth = SuitabilityEngine.Inputs(
            monitorSample: sampleSmooth,
            isLinkUp: true,
            currentJitter: 4.0,
            effectiveLoss: 0.0
        )

        let gamingSmooth = SuitabilityEngine.evaluateGaming(inputsSmooth)
        #expect(gamingSmooth.verdict == .good)
        #expect(gamingSmooth.status == "Smooth")
        #expect(gamingSmooth.metric == "50 ms · 4ms jit")

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
        #expect(gamingLag.status == "Noticeable delay")
        #expect(gamingLag.metric == "95 ms · 4ms jit")

        // Packet loss degrades to rubberbanding and surfaces loss in metric
        var sampleLoss = MonitorSample()
        sampleLoss.internet = .init(lossPct: 3.0, rttAvgMs: 25.0, rttJitterMs: 2.0)

        let inputsLoss = SuitabilityEngine.Inputs(
            monitorSample: sampleLoss,
            isLinkUp: true,
            currentJitter: 2.0,
            effectiveLoss: 3.0
        )

        let gamingLoss = SuitabilityEngine.evaluateGaming(inputsLoss)
        #expect(gamingLoss.verdict == .degraded)
        #expect(gamingLoss.status == "May rubberband")
        #expect(gamingLoss.metric == "25 ms · 3% loss")

        // Jitter spikes
        var sampleJitter = MonitorSample()
        sampleJitter.internet = .init(lossPct: 0.0, rttAvgMs: 30.0, rttJitterMs: 25.0)

        let inputsJitter = SuitabilityEngine.Inputs(
            monitorSample: sampleJitter,
            isLinkUp: true,
            currentJitter: 25.0,
            effectiveLoss: 0.0
        )

        let gamingJitter = SuitabilityEngine.evaluateGaming(inputsJitter)
        #expect(gamingJitter.verdict == .degraded)
        #expect(gamingJitter.status == "Lag spikes")
        #expect(gamingJitter.metric == "30 ms · 25ms jit")
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

    @Test func synthesizeDegradedExperienceDecouplesInternetLossAndWifiJitter() {
        var sample = MonitorSample()
        sample.link = .init(up: true, type: "wifi")
        sample.gateway = .init(lossPct: 0.0, rttAvgMs: 49.0, rttJitterMs: 77.0)
        sample.internet = .init(lossPct: 10.0, rttAvgMs: 108.0, rttJitterMs: 77.0)

        let speed = RunSnapshot.Speedtest(downMbps: 263.0, upMbps: 42.0)

        let inputs = SuitabilityEngine.Inputs(
            monitorSample: sample,
            speedTest: speed,
            isLinkUp: true,
            currentJitter: 77.0,
            effectiveLoss: 10.0
        )

        let items = SuitabilityEngine.evaluateAll(inputs)
        let degraded = SuitabilityEngine.synthesizeDegradedExperience(
            items: items,
            monitorSample: sample,
            currentJitter: 77.0,
            effectiveLoss: 10.0
        )

        #expect(degraded != nil)
        #expect(degraded?.headline == "Unstable for calls & gaming")
        #expect(degraded?.subtitle.contains("10% internet packet loss") == true)
        #expect(degraded?.subtitle.contains("77ms Wi-Fi jitter") == true)
        #expect(degraded?.subtitle.contains("to router") == false)
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

    @Test func synthesizeDegradedExperienceRubberbandingForGaming() {
        var sample = MonitorSample()
        sample.gateway = .init(lossPct: 0.0, rttAvgMs: 2.0, rttJitterMs: 1.0)
        sample.internet = .init(lossPct: 2.0, rttAvgMs: 24.0, rttJitterMs: 2.0)

        let speed = RunSnapshot.Speedtest(downMbps: 150.0, upMbps: 50.0)

        let inputs = SuitabilityEngine.Inputs(
            monitorSample: sample,
            speedTest: speed,
            isLinkUp: true,
            currentJitter: 2.0,
            effectiveLoss: 2.0
        )

        let items = SuitabilityEngine.evaluateAll(inputs)
        let degraded = SuitabilityEngine.synthesizeDegradedExperience(
            items: items,
            monitorSample: sample,
            currentJitter: 2.0,
            effectiveLoss: 2.0
        )

        #expect(degraded != nil)
        #expect(degraded?.headline == "Rubberbanding in games")
        #expect(degraded?.subtitle.contains("2% loss") == true)
        #expect(degraded?.subtitle.contains("Web browsing & streaming fine") == true)
    }

    @Test func synthesizeDegradedExperienceLagSpikesForGaming() {
        var sample = MonitorSample()
        sample.gateway = .init(lossPct: 0.0, rttAvgMs: 2.0, rttJitterMs: 1.0)
        sample.internet = .init(lossPct: 0.0, rttAvgMs: 30.0, rttJitterMs: 22.0)

        let speed = RunSnapshot.Speedtest(downMbps: 150.0, upMbps: 50.0)

        let inputs = SuitabilityEngine.Inputs(
            monitorSample: sample,
            speedTest: speed,
            isLinkUp: true,
            currentJitter: 22.0,
            effectiveLoss: 0.0
        )

        let items = SuitabilityEngine.evaluateAll(inputs)
        let degraded = SuitabilityEngine.synthesizeDegradedExperience(
            items: items,
            monitorSample: sample,
            currentJitter: 22.0,
            effectiveLoss: 0.0
        )

        #expect(degraded != nil)
        #expect(degraded?.headline == "Lag spikes in games")
        #expect(degraded?.subtitle.contains("22ms jit") == true)
        #expect(degraded?.subtitle.contains("Web browsing & streaming fine") == true)
    }

    @Test func synthesizeDegradedExperienceVideoFreezeForCalls() {
        var sample = MonitorSample()
        sample.gateway = .init(lossPct: 0.0, rttAvgMs: 2.0, rttJitterMs: 1.0)
        sample.internet = .init(lossPct: 0.0, rttAvgMs: 20.0, rttJitterMs: 2.0)

        // Upload choked at 0.7 Mbps while download is fine (30 Mbps)
        let speed = RunSnapshot.Speedtest(downMbps: 30.0, upMbps: 0.7)

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

        #expect(degraded != nil)
        #expect(degraded?.headline == "Video may freeze on calls")
        #expect(degraded?.subtitle.contains("0.7 Mbps ↑") == true)
        #expect(degraded?.subtitle.contains("Browsing & streaming fine") == true)
    }

    @Test func synthesizeDegradedExperienceModerateLossTriggersWarningNotCritical() {
        // 6% Wi-Fi loss with 5ms jitter: should trigger warning ("Calls & gaming may lag", not critical "Unstable")
        var sample = MonitorSample()
        sample.link = .init(up: true, type: "wifi")
        sample.gateway = .init(lossPct: 6.0, rttAvgMs: 13.0, rttJitterMs: 5.0)
        sample.internet = .init(lossPct: 4.0, rttAvgMs: 22.0, rttJitterMs: 5.0)

        let speed = RunSnapshot.Speedtest(downMbps: 300.0, upMbps: 80.0)

        let inputs = SuitabilityEngine.Inputs(
            monitorSample: sample,
            speedTest: speed,
            isLinkUp: true,
            currentJitter: 5.0,
            effectiveLoss: 6.0
        )

        let items = SuitabilityEngine.evaluateAll(inputs)
        let degraded = SuitabilityEngine.synthesizeDegradedExperience(
            items: items,
            monitorSample: sample,
            currentJitter: 5.0,
            effectiveLoss: 6.0
        )

        #expect(degraded != nil)
        #expect(degraded?.headline == "Calls & gaming may lag")
        #expect(degraded?.isCritical == false)
        #expect(degraded?.subtitle.contains("6% packet loss") == true)
        #expect(degraded?.subtitle.contains("on Wi-Fi") == true)
    }

    @Test func browsingDifferentiatesDnsFailureHttpBlockingLossAndLatency() {
        // 1. DNS failure
        var sampleDNSFail = MonitorSample()
        sampleDNSFail.dns = .init(ok: false, resolver: "1.1.1.1", elapsedMs: nil)
        let inputsDNS = SuitabilityEngine.Inputs(monitorSample: sampleDNSFail, isLinkUp: true)
        let browsingDNS = SuitabilityEngine.evaluateBrowsing(inputsDNS)
        #expect(browsingDNS.verdict == .broken)
        #expect(browsingDNS.status == "DNS failing")
        #expect(browsingDNS.metric == "Lookup failed")

        // 2. Web / Port 443 blocked
        var sampleTCPFail = MonitorSample()
        sampleTCPFail.tcp = .init(anyOk: false, targets: [])
        let inputsTCP = SuitabilityEngine.Inputs(monitorSample: sampleTCPFail, isLinkUp: true)
        let browsingTCP = SuitabilityEngine.evaluateBrowsing(inputsTCP)
        #expect(browsingTCP.verdict == .broken)
        #expect(browsingTCP.status == "Web blocked")
        #expect(browsingTCP.metric == "Port 443 down")

        // 3. High packet loss (15%) -> Pages stall
        var sampleLoss = MonitorSample()
        sampleLoss.internet = .init(lossPct: 15.0, rttAvgMs: 20.0, rttJitterMs: 2.0)
        let inputsLoss = SuitabilityEngine.Inputs(monitorSample: sampleLoss, isLinkUp: true, effectiveLoss: 15.0)
        let browsingLoss = SuitabilityEngine.evaluateBrowsing(inputsLoss)
        #expect(browsingLoss.verdict == .broken)
        #expect(browsingLoss.status == "Pages stall")
        #expect(browsingLoss.metric == "15% loss")

        // 4. Slow DNS lookups (310ms) -> Slow lookups
        var sampleSlowDNS = MonitorSample()
        sampleSlowDNS.dns = .init(ok: true, resolver: "8.8.8.8", elapsedMs: 310.0)
        let inputsSlowDNS = SuitabilityEngine.Inputs(monitorSample: sampleSlowDNS, isLinkUp: true)
        let browsingSlowDNS = SuitabilityEngine.evaluateBrowsing(inputsSlowDNS)
        #expect(browsingSlowDNS.verdict == .degraded)
        #expect(browsingSlowDNS.status == "Slow lookups")
        #expect(browsingSlowDNS.metric == "310ms DNS")

        // 5. Moderate packet loss (6%) -> Sluggish
        var sampleModLoss = MonitorSample()
        sampleModLoss.internet = .init(lossPct: 6.0, rttAvgMs: 20.0, rttJitterMs: 2.0)
        let inputsModLoss = SuitabilityEngine.Inputs(monitorSample: sampleModLoss, isLinkUp: true, effectiveLoss: 6.0)
        let browsingModLoss = SuitabilityEngine.evaluateBrowsing(inputsModLoss)
        #expect(browsingModLoss.verdict == .degraded)
        #expect(browsingModLoss.status == "Sluggish")
        #expect(browsingModLoss.metric == "6% loss")

        // 6. Fast DNS (<60ms) -> Fast
        var sampleFast = MonitorSample()
        sampleFast.dns = .init(ok: true, resolver: "1.1.1.1", elapsedMs: 18.0)
        sampleFast.internet = .init(lossPct: 0.0, rttAvgMs: 15.0, rttJitterMs: 1.0)
        let inputsFast = SuitabilityEngine.Inputs(monitorSample: sampleFast, isLinkUp: true, effectiveLoss: 0.0)
        let browsingFast = SuitabilityEngine.evaluateBrowsing(inputsFast)
        #expect(browsingFast.verdict == .good)
        #expect(browsingFast.status == "Fast")
        #expect(browsingFast.metric == "18ms DNS")
    }

    @Test func streamingDifferentiatesBandwidthAndPacketLoss() {
        // High bandwidth (100 Mbps) but elevated packet loss (10%) -> SD only with loss in metric
        var sample = MonitorSample()
        sample.internet = .init(lossPct: 10.0, rttAvgMs: 20.0, rttJitterMs: 2.0)
        let speed = RunSnapshot.Speedtest(downMbps: 100.0, upMbps: 20.0)

        let inputs = SuitabilityEngine.Inputs(
            monitorSample: sample,
            speedTest: speed,
            isLinkUp: true,
            effectiveLoss: 10.0
        )

        let streaming = SuitabilityEngine.evaluateStreaming(inputs)
        #expect(streaming.verdict == .degraded)
        #expect(streaming.status == "SD only")
        #expect(streaming.metric == "10% loss")
    }

    @Test func synthesizeDegradedExperienceSlowDnsForBrowsing() {
        var sample = MonitorSample()
        sample.dns = .init(ok: true, resolver: "8.8.8.8", elapsedMs: 350.0)
        sample.gateway = .init(lossPct: 0.0, rttAvgMs: 2.0, rttJitterMs: 1.0)
        sample.internet = .init(lossPct: 0.0, rttAvgMs: 20.0, rttJitterMs: 2.0)

        let inputs = SuitabilityEngine.Inputs(
            monitorSample: sample,
            isLinkUp: true,
            effectiveLoss: 0.0
        )

        let items = SuitabilityEngine.evaluateAll(inputs)
        let degraded = SuitabilityEngine.synthesizeDegradedExperience(
            items: items,
            monitorSample: sample,
            effectiveLoss: 0.0
        )

        #expect(degraded != nil)
        #expect(degraded?.headline == "Slow DNS delaying page loads")
        #expect(degraded?.subtitle.contains("350ms DNS") == true)
        #expect(degraded?.subtitle.contains("Video streaming fine") == true)
    }

    @Test func synthesizeDegradedExperiencePacketLossForStreaming() {
        var sample = MonitorSample()
        sample.gateway = .init(lossPct: 0.0, rttAvgMs: 2.0, rttJitterMs: 1.0)
        sample.internet = .init(lossPct: 16.0, rttAvgMs: 20.0, rttJitterMs: 2.0)

        let inputs = SuitabilityEngine.Inputs(
            monitorSample: sample,
            isLinkUp: true,
            effectiveLoss: 16.0
        )

        let items = SuitabilityEngine.evaluateAll(inputs)
        // With 16% loss, Calls and Gaming will also degrade if present.
        // Test streaming in isolation to verify its headline synthesizer:
        let streamingItem = SuitabilityEngine.evaluateStreaming(inputs)
        let degraded = SuitabilityEngine.synthesizeDegradedExperience(
            items: [streamingItem],
            monitorSample: sample,
            effectiveLoss: 16.0
        )

        #expect(degraded != nil)
        #expect(degraded?.headline == "Severe packet loss buffering video")
        #expect(degraded?.subtitle.contains("16% loss") == true)
    }
}
