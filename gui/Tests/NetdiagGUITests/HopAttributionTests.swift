import Foundation
import Testing
@testable import NetdiagGUI

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
}
