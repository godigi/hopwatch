import SwiftUI
import Foundation

/// Resolves warning and culprit states for the 3-hop connection route:
/// Hop 1: This Mac (Local Wi-Fi link)
/// Hop 2: Router (Local Gateway)
/// Hop 3: Internet (Broadband WAN & Upstream ISP)
///
/// Ensures consistent attribution across both the Menu Bar Dropdown
/// and the Dashboard HomeView, avoiding false positive Wi-Fi warnings
/// and properly surfacing upstream Internet instability (such as jitter and loss).
enum RouteWarningResolver {

    struct Result: Equatable, Sendable {
        let isWifiLaggy: Bool
        let macStatusGood: Bool
        let routerWarn: Bool
        let internetWarn: Bool
        let culpritHop: String?

        init(
            isWifiLaggy: Bool,
            macStatusGood: Bool,
            routerWarn: Bool,
            internetWarn: Bool,
            culpritHop: String? = nil
        ) {
            self.isWifiLaggy = isWifiLaggy
            self.macStatusGood = macStatusGood
            self.routerWarn = routerWarn
            self.internetWarn = internetWarn
            self.culpritHop = culpritHop
        }
    }

    static func resolve(
        linkUp: Bool,
        isWiFi: Bool,
        stage: StageResolver.Stage,
        firedCategories: Set<String>,
        gwLoss: Double,
        gwPing: Double,
        gwJitter: Double,
        inetLoss: Double,
        inetPing: Double,
        inetJitter: Double,
        hasRecentRoam: Bool,
        wifiRuleTint: Color? = nil
    ) -> Result {
        // Downstream validation: Packets to the internet must traverse the local gateway.
        // If internet through-traffic is clean (loss <= 1.0%), isolated router ping loss (< 20%)
        // is harmless ICMP control-plane rate limiting by the router's CPU, NOT physical data loss.
        let isIsolatedGWLoss = (inetLoss <= 1.0 && gwLoss < 20.0)
        let realGWLoss = !isIsolatedGWLoss && gwLoss >= 5.0

        // If the full round-trip to the internet has lower latency or jitter than the router,
        // any delay/jitter to the router IP itself is router CPU reply delay, not local Wi-Fi latency.
        let realGWPing = gwPing >= 35.0 && (inetPing >= 35.0 || inetPing == 0)
        let realGWJitter = gwJitter >= 25.0 && (inetJitter >= 20.0 || inetJitter == 0)

        // 1. Wi-Fi Laggy evaluation
        // Wi-Fi is laggy when wireless latency/jitter is elevated or Wi-Fi rules indicate degradation.
        // Isolated gateway packet loss without Wi-Fi degradation is a Router issue, not Wi-Fi.
        let isWifiLaggy: Bool
        if !isWiFi || stage == .healthy {
            isWifiLaggy = false
        } else {
            isWifiLaggy = (wifiRuleTint != nil && wifiRuleTint != .green) || realGWPing || realGWJitter
        }

        // 2. Mac / Local Link status
        let macStatusGood = linkUp && !isWifiLaggy && (wifiRuleTint == nil || wifiRuleTint == .green)

        // 3. Router status
        let routerWarn: Bool
        if hasRecentRoam && gwLoss < 10.0 {
            routerWarn = false
        } else {
            routerWarn = firedCategories.contains("router")
                || realGWLoss
                || (gwPing > 30.0 && (inetPing >= 30.0 || inetPing == 0))
        }

        // 4. Internet / Broadband status
        var internetWarn = false
        if firedCategories.contains("internet") {
            internetWarn = true
        } else if inetLoss >= 3.0 && inetLoss > gwLoss {
            internetWarn = true
        } else if inetJitter >= 30.0 && gwJitter < 20.0 {
            internetWarn = true
        } else if inetPing >= 120.0 && gwPing < 30.0 {
            internetWarn = true
        } else if case .degraded = stage, !routerWarn, !isWifiLaggy {
            // When user experiences degradation for calls/gaming/streaming/browsing
            // and local hops (Wi-Fi and Router) are verified clean, the culprit is the Internet/ISP.
            internetWarn = true
        }

        // 5. Culprit Hop
        let culpritHop: String?
        if !macStatusGood || isWifiLaggy {
            culpritHop = "wifi"
        } else if routerWarn {
            culpritHop = "router"
        } else if internetWarn {
            culpritHop = "internet"
        } else {
            culpritHop = nil
        }

        return Result(
            isWifiLaggy: isWifiLaggy,
            macStatusGood: macStatusGood,
            routerWarn: routerWarn,
            internetWarn: internetWarn,
            culpritHop: culpritHop
        )
    }
}
