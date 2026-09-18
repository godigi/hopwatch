import Foundation
import Testing
@testable import HopwatchGUI

@Suite struct HopAttributionTests {

    @Test func wifiDegradedVsGatewayLossAttributesToWifi() {
        // G1: Gateway loss caused by poor Wi-Fi link
        let result = HopAttributionResolver.resolve(
            rules: ["G1"],
            isWifi: true,
            wifiRSSI: -82,
            gatewayRTT: 12.0,
            gatewayLoss: 30.0,
            inetLoss: 30.0
        )
        #expect(result.culprit == .wifi)
        #expect(result.wifiHealth == .critical)
        #expect(result.reassurance.contains("Wi-Fi") || result.reassurance.contains("wireless"))
    }

    @Test func gatewayLossWithStrongWifiAttributesToRouter() {
        // G2: Gateway loss while Wi-Fi signal is strong
        let result = HopAttributionResolver.resolve(
            rules: ["G2"],
            isWifi: true,
            wifiRSSI: -45,
            gatewayRTT: 1.2,
            gatewayLoss: 25.0,
            inetLoss: 25.0
        )
        #expect(result.culprit == .router)
        #expect(result.wifiHealth == .healthy)
        #expect(result.routerHealth == .critical)
        #expect(result.reassurance.contains("router"))
    }

    @Test func routerHealthyAndInternetLossAttributesToISP() {
        // P1 / P2: Total or high packet loss past router
        let result = HopAttributionResolver.resolve(
            rules: ["P1"],
            isWifi: true,
            wifiRSSI: -48,
            gatewayRTT: 1.1,
            gatewayLoss: 0.0,
            inetLoss: 100.0
        )
        #expect(result.culprit == .isp)
        #expect(result.wifiHealth == .healthy)
        #expect(result.routerHealth == .healthy)
        #expect(result.ispHealth == .critical)
        #expect(result.reassurance.contains("Internet Service Provider") || result.reassurance.contains("ISP"))
    }

    @Test func localBufferbloatVsISPBufferbloat() {
        // B1: Local router bufferbloat
        let r1 = HopAttributionResolver.resolve(
            rules: ["B1"],
            isWifi: true,
            wifiRSSI: -50,
            gatewayRTT: 1.5,
            bufferbloatGW: 220.0,
            bufferbloatInet: 230.0
        )
        #expect(r1.culprit == .router)
        #expect(r1.routerHealth == .warning)

        // B2: Upstream ISP bufferbloat
        let r2 = HopAttributionResolver.resolve(
            rules: ["B2"],
            isWifi: true,
            wifiRSSI: -50,
            gatewayRTT: 1.5,
            bufferbloatGW: 10.0,
            bufferbloatInet: 250.0
        )
        #expect(r2.culprit == .isp)
        #expect(r2.routerHealth == .healthy)
        #expect(r2.ispHealth == .warning)
    }

    @Test func allClearWhenZeroFaults() {
        let result = HopAttributionResolver.resolve(
            rules: [],
            isWifi: true,
            wifiRSSI: -50,
            gatewayRTT: 1.5,
            gatewayLoss: 0.0,
            inetRTT: 14.0,
            inetLoss: 0.0
        )
        #expect(result.culprit == .none)
        #expect(result.wifiHealth == .healthy)
        #expect(result.routerHealth == .healthy)
        #expect(result.ispHealth == .healthy)
        #expect(result.reassurance.contains("cleanly") || result.reassurance.contains("healthy"))
    }

    @Test func wifiRateCollapseAndAsymmetricLinkAttributeToWifi() {
        // W4: Transmit rate collapse
        let w4 = HopAttributionResolver.resolve(
            rules: ["W4"],
            isWifi: true,
            wifiRSSI: -50,
            gatewayRTT: 2.0
        )
        #expect(w4.culprit == .wifi)
        #expect(w4.wifiHealth == .warning)
        #expect(w4.reassurance.contains("rate has collapsed"))

        // W5: Asymmetric Wi-Fi return path loss
        let w5 = HopAttributionResolver.resolve(
            rules: ["W5"],
            isWifi: true,
            wifiRSSI: -60,
            gatewayRTT: 2.0,
            gatewayLoss: 15.0
        )
        #expect(w5.culprit == .wifi)
        #expect(w5.wifiHealth == .warning)
        #expect(w5.reassurance.contains("asymmetric link"))

        // AWDL-1: Apple Wireless Direct Link channel hopping
        let awdl = HopAttributionResolver.resolve(
            rules: ["AWDL-1"],
            isWifi: true,
            wifiRSSI: -50,
            gatewayRTT: 12.0
        )
        #expect(awdl.culprit == .wifi)
        #expect(awdl.wifiHealth == .warning)
        #expect(awdl.reassurance.contains("Apple Wireless Direct Link"))

        // D5: Primary DNS unresponsive, falling back to secondary
        let d5 = HopAttributionResolver.resolve(
            rules: ["D5"],
            isWifi: true,
            wifiRSSI: -50,
            gatewayRTT: 1.5,
            gatewayLoss: 0.0,
            inetRTT: 15.0,
            inetLoss: 0.0
        )
        #expect(d5.culprit == .isp)
        #expect(d5.ispHealth == .warning)
        #expect(d5.reassurance.contains("primary DNS server is unresponsive"))

        // W6: Suboptimal 2.4 GHz band trapping
        let w6 = HopAttributionResolver.resolve(
            rules: ["W6"],
            isWifi: true,
            wifiRSSI: -55,
            gatewayRTT: 2.0
        )
        #expect(w6.culprit == .wifi)
        #expect(w6.wifiHealth == .warning)
        #expect(w6.reassurance.contains("slower 2.4 GHz band"))

        // WS-1: Crowded Wi-Fi channel with zero packet loss
        let ws1 = HopAttributionResolver.resolve(
            rules: ["WS-1"],
            isWifi: true,
            wifiRSSI: -56,
            gatewayRTT: 19.4,
            gatewayLoss: 0.0,
            inetRTT: 76.0,
            inetLoss: 0.0
        )
        #expect(ws1.culprit == .wifi)
        #expect(ws1.wifiHealth == .warning)
        #expect(ws1.headline == "Wi-Fi Channel Crowded")
        #expect(ws1.badgeTitle == "Advisory: Crowded Channel")
        #expect(!ws1.reassurance.contains("dropping packets"))
        #expect(ws1.reassurance.contains("crowded by neighboring networks"))

        // Upstream packet loss (12%) vs Outage (100%)
        let ispDegraded = HopAttributionResolver.resolve(
            rules: ["L2"],
            isWifi: true,
            wifiRSSI: -49,
            gatewayRTT: 8.0,
            gatewayLoss: 0.0,
            inetRTT: 54.0,
            inetLoss: 12.0
        )
        #expect(ispDegraded.culprit == .isp)
        #expect(ispDegraded.badgeTitle == "Culprit: Upstream Packet Loss")

        let ispOutage = HopAttributionResolver.resolve(
            rules: ["P1"],
            isWifi: true,
            wifiRSSI: -49,
            gatewayRTT: 8.0,
            gatewayLoss: 0.0,
            inetRTT: 0.0,
            inetLoss: 100.0
        )
        #expect(ispOutage.culprit == .isp)
        #expect(ispOutage.badgeTitle == "Culprit: ISP Outage")
    }

    @Test func browserDesyncAttributesToMac() {
        // BR-1 alone: browser updated in background, needs relaunch
        let brAlone = HopAttributionResolver.resolve(
            rules: ["BR-1"],
            isWifi: true,
            wifiRSSI: -50,
            gatewayRTT: 1.5,
            gatewayLoss: 0.0,
            inetRTT: 14.0,
            inetLoss: 0.0
        )
        #expect(brAlone.culprit == .mac)
        #expect(brAlone.macHealth == .warning)
        #expect(brAlone.wifiHealth == .healthy)
        #expect(brAlone.routerHealth == .healthy)
        #expect(brAlone.ispHealth == .healthy)
        #expect(brAlone.headline == "Browser Needs Relaunch")
        #expect(brAlone.badgeTitle == "Culprit: Browser App")
        #expect(brAlone.reassurance.contains("reopening the browser finishes the update"))

        // BR-1 co-occurring with advisory Wi-Fi channel crowding (WS-1):
        // BR-1 breaks browsing, so Mac app remains primary culprit rather than blaming router/Wi-Fi
        let brWithCrowding = HopAttributionResolver.resolve(
            rules: ["WS-1", "BR-1"],
            isWifi: true,
            wifiRSSI: -56,
            gatewayRTT: 15.0,
            gatewayLoss: 0.0,
            inetRTT: 40.0,
            inetLoss: 0.0
        )
        #expect(brWithCrowding.culprit == .mac)
        #expect(brWithCrowding.macHealth == .warning)
        #expect(brWithCrowding.wifiHealth == .warning)
        #expect(brWithCrowding.badgeTitle == "Culprit: Browser App")
        #expect(brWithCrowding.headline == "Browser Needs Relaunch")
    }
}
