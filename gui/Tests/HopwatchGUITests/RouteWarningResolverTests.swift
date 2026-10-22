import Foundation
import Testing
@testable import HopwatchGUI

@Suite struct RouteWarningResolverTests {

    @Test func image1ScenarioIsolatedRouterLossSuppressedByDownstreamValidation() {
        // In the scenario from Image 1:
        // Internet is pristine: 18ms ping, 3ms jitter, 0% loss, all activities healthy.
        // Router has isolated ICMP packet drops (e.g. 6%) and 19ms ping.
        // Wi-Fi must NOT be flagged as laggy, and all hops must remain healthy.
        let result = RouteWarningResolver.resolve(
            linkUp: true,
            isWiFi: true,
            stage: .healthy,
            firedCategories: [],
            gwLoss: 6.0,
            gwPing: 19.0,
            gwJitter: 3.0,
            inetLoss: 0.0,
            inetPing: 18.0,
            inetJitter: 3.0,
            hasRecentRoam: false
        )

        #expect(!result.isWifiLaggy)
        #expect(result.macStatusGood)
        #expect(!result.routerWarn)
        #expect(!result.internetWarn)
        #expect(result.culpritHop == nil)
    }

    @Test func image2ScenarioInternetJitterAndLossAttributesToInternet() {
        // In the scenario from Image 2:
        // Local link and router are pristine (8ms ping, 0% loss, 1ms jitter).
        // Internet has 43ms ping, 76ms jitter, 1% loss, degrading Calls & Gaming.
        // The Internet hop must be warned and attributed as the culprit.
        let degraded = StageResolver.DegradedSnapshot(
            headline: "Unstable for calls & gaming",
            subtitle: "1% packet loss · 76ms jitter · 4K streaming is fine",
            isCritical: true,
            affectedActivities: ["Calls", "Gaming"]
        )
        let stage = StageResolver.Stage.degraded(degraded)

        let result = RouteWarningResolver.resolve(
            linkUp: true,
            isWiFi: true,
            stage: stage,
            firedCategories: [],
            gwLoss: 0.0,
            gwPing: 8.0,
            gwJitter: 1.0,
            inetLoss: 1.0,
            inetPing: 43.0,
            inetJitter: 76.0,
            hasRecentRoam: false
        )

        #expect(!result.isWifiLaggy)
        #expect(result.macStatusGood)
        #expect(!result.routerWarn)
        #expect(result.internetWarn)
        #expect(result.culpritHop == "internet")
    }

    @Test func realWifiDegradationFlagsWifiAndMac() {
        // When real Wi-Fi latency and loss occurs (propagating to internet)
        let degraded = StageResolver.DegradedSnapshot(
            headline: "Calls & gaming may lag",
            subtitle: "High Wi-Fi latency",
            isCritical: false,
            affectedActivities: ["Gaming"]
        )

        let result = RouteWarningResolver.resolve(
            linkUp: true,
            isWiFi: true,
            stage: .degraded(degraded),
            firedCategories: [],
            gwLoss: 15.0,
            gwPing: 55.0,
            gwJitter: 30.0,
            inetLoss: 15.0,
            inetPing: 65.0,
            inetJitter: 32.0,
            hasRecentRoam: false
        )

        #expect(result.isWifiLaggy)
        #expect(!result.macStatusGood)
        #expect(result.culpritHop == "wifi")
    }

    @Test func realRouterFailureAttributesToRouter() {
        // When router rule fires or heavy real gateway loss occurs without Wi-Fi issues
        let result = RouteWarningResolver.resolve(
            linkUp: true,
            isWiFi: true,
            stage: .watching(severity: .warn),
            firedCategories: ["router"],
            gwLoss: 25.0,
            gwPing: 2.0,
            gwJitter: 1.0,
            inetLoss: 25.0,
            inetPing: 15.0,
            inetJitter: 2.0,
            hasRecentRoam: false
        )

        #expect(result.routerWarn)
        #expect(result.culpritHop == "router")
    }

    @Test func roamingHandoverSuppressesTransientRouterWarning() {
        let result = RouteWarningResolver.resolve(
            linkUp: true,
            isWiFi: true,
            stage: .healthy,
            firedCategories: [],
            gwLoss: 8.0,
            gwPing: 12.0,
            gwJitter: 4.0,
            inetLoss: 0.0,
            inetPing: 15.0,
            inetJitter: 4.0,
            hasRecentRoam: true
        )

        #expect(!result.routerWarn)
        #expect(!result.isWifiLaggy)
    }

    @Test func wiredConnectionNeverReportsWifiLaggy() {
        let result = RouteWarningResolver.resolve(
            linkUp: true,
            isWiFi: false,
            stage: .watching(severity: .warn),
            firedCategories: [],
            gwLoss: 25.0,
            gwPing: 50.0,
            gwJitter: 30.0,
            inetLoss: 25.0,
            inetPing: 60.0,
            inetJitter: 30.0,
            hasRecentRoam: false
        )

        #expect(!result.isWifiLaggy)
    }

    @Test func gatewayPingFilteredWithCleanInternetDoesNotWarnRouter() {
        // Router blocks/filters ICMP ping (100% gateway loss), but downstream
        // internet is clean and healthy (0% loss, 54ms latency).
        // Router must NOT be marked with a warning, and Wi-Fi must remain good.
        let result = RouteWarningResolver.resolve(
            linkUp: true,
            isWiFi: true,
            stage: .healthy,
            firedCategories: [],
            gwLoss: 100.0,
            gwPing: 0.0,
            gwJitter: 0.0,
            inetLoss: 0.0,
            inetPing: 54.0,
            inetJitter: 7.0,
            hasRecentRoam: false,
            gatewayPingFiltered: true
        )

        #expect(!result.routerWarn)
        #expect(!result.isWifiLaggy)
        #expect(result.macStatusGood)
        #expect(!result.internetWarn)
        #expect(result.culpritHop == nil)
    }

    @Test func gatewayPingFilteredWithInternetLossWarnsInternetNotRouter() {
        // Router blocks/filters ICMP ping (100% gateway loss, gatewayPingFiltered: true),
        // but the internet connection is degraded/down (100% internet loss).
        // The router must NOT be blamed; the Internet hop must be warned and named culprit.
        let degraded = StageResolver.DegradedSnapshot(
            headline: "Connection is unstable",
            subtitle: "100% packet loss",
            isCritical: true,
            affectedActivities: ["Calls", "Gaming", "Streaming", "Browsing"]
        )
        let result = RouteWarningResolver.resolve(
            linkUp: true,
            isWiFi: true,
            stage: .degraded(degraded),
            firedCategories: [],
            gwLoss: 100.0,
            gwPing: 0.0,
            gwJitter: 0.0,
            inetLoss: 100.0,
            inetPing: 0.0,
            inetJitter: 0.0,
            hasRecentRoam: false,
            gatewayPingFiltered: true
        )

        #expect(!result.routerWarn)
        #expect(!result.isWifiLaggy)
        #expect(result.macStatusGood)
        #expect(result.internetWarn)
        #expect(result.culpritHop == "internet")
    }

    @Test func strongSignalWithRouterLagDoesNotFlagMacHardware() {
        // High router ping/jitter (177ms / ±139ms) on Wi-Fi without client packet loss.
        // Wi-Fi link is flagged laggy, but Mac hardware status remains good (green checkmark).
        let degraded = StageResolver.DegradedSnapshot(
            headline: "Unstable for calls & gaming",
            subtitle: "8% internet packet loss · 321ms Wi-Fi jitter",
            isCritical: true,
            affectedActivities: ["Calls", "Gaming"]
        )
        let result = RouteWarningResolver.resolve(
            linkUp: true,
            isWiFi: true,
            stage: .degraded(degraded),
            firedCategories: [],
            gwLoss: 0.0,
            gwPing: 177.0,
            gwJitter: 139.0,
            inetLoss: 8.0,
            inetPing: 370.0,
            inetJitter: 321.0,
            hasRecentRoam: false
        )

        #expect(result.isWifiLaggy)
        #expect(result.macStatusGood)
        #expect(result.routerWarn)
        #expect(result.internetWarn)
    }

    @Test func distanceGuidanceResolution() {
        #expect(SignalScale.distanceGuidance(forRSSI: -43) == "Near router")
        #expect(SignalScale.distanceGuidance(forRSSI: -50) == "Near router")
        #expect(SignalScale.distanceGuidance(forRSSI: -55) == "Good range")
        #expect(SignalScale.distanceGuidance(forRSSI: -70) == "Medium range")
        #expect(SignalScale.distanceGuidance(forRSSI: -80) == "Too far from router")
        #expect(SignalScale.distanceGuidance(forRSSI: nil) == nil)
    }
}
