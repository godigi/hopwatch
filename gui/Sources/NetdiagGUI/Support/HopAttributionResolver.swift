import SwiftUI
import Foundation

/// Resolves the diagnostic path into 3 distinct network segments:
/// 1. Local Link / Wi-Fi (Mac ➔ Router)
/// 2. Local Router / Gateway (Router itself)
/// 3. Internet & ISP (Router ➔ Global CDN / Public Internet)
///
/// Pinpoints the primary Culprit (or confirms All Clear) and produces
/// plain-English reassurance so non-technical users immediately understand
/// whether the issue is local Wi-Fi, their router, or an upstream ISP outage.
public enum HopAttributionResolver {

    public enum HopHealth: String, Equatable, Sendable, CaseIterable {
        case healthy
        case warning
        case critical
        case skipped

        public var symbol: String {
            switch self {
            case .healthy:  return "checkmark.circle.fill"
            case .warning:  return "exclamationmark.triangle.fill"
            case .critical: return "xmark.circle.fill"
            case .skipped:  return "minus.circle"
            }
        }

        public var tint: Color {
            switch self {
            case .healthy:  return .green
            case .warning:  return .orange
            case .critical: return .red
            case .skipped:  return .secondary
            }
        }
    }

    public enum Culprit: String, Equatable, Sendable {
        case none = "All Clear"
        case wifi = "Wi-Fi Signal"
        case router = "Local Router"
        case isp = "Internet Service Provider"

        public var badgeTitle: String {
            switch self {
            case .none:   return "All Hops Healthy"
            case .wifi:   return "Culprit: Weak Wi-Fi"
            case .router: return "Culprit: Router Issue"
            case .isp:    return "Culprit: ISP Outage"
            }
        }

        public var badgeTint: Color {
            switch self {
            case .none:   return .green
            case .wifi:   return .orange
            case .router: return .red
            case .isp:    return .red
            }
        }
    }

    public struct Result: Equatable, Sendable {
        public let culprit: Culprit
        public let macHealth: HopHealth
        public let wifiHealth: HopHealth
        public let routerHealth: HopHealth
        public let ispHealth: HopHealth
        public let headline: String
        public let reassurance: String
        public let isWired: Bool
        public let activeRules: [String]

        public init(
            culprit: Culprit,
            macHealth: HopHealth = .healthy,
            wifiHealth: HopHealth,
            routerHealth: HopHealth,
            ispHealth: HopHealth,
            headline: String,
            reassurance: String,
            isWired: Bool = false,
            activeRules: [String] = []
        ) {
            self.culprit = culprit
            self.macHealth = macHealth
            self.wifiHealth = wifiHealth
            self.routerHealth = routerHealth
            self.ispHealth = ispHealth
            self.headline = headline
            self.reassurance = reassurance
            self.isWired = isWired
            self.activeRules = activeRules
        }
    }

    // MARK: - Rule Classifications

    private static let wifiCriticalRules: Set<String> = ["G1", "W1", "WD-1"]
    private static let wifiWarningRules: Set<String> = ["W2", "W3", "WS-1"]

    private static let routerCriticalRules: Set<String> = ["G2", "DI-1"]
    private static let routerWarningRules: Set<String> = ["G3", "B1", "NAT-1", "LAN-1", "DH-1", "DH-2", "DH-3"]

    private static let ispCriticalRules: Set<String> = ["P1", "P2", "N1", "N1b", "L1", "CP-1", "D1"]
    private static let ispWarningRules: Set<String> = ["L2", "B2", "D2", "D3", "D4", "M1", "SP-1", "BL-1"]

    // MARK: - Resolution

    public static func resolve(
        rules: [String],
        isWifi: Bool = true,
        wifiRSSI: Int? = nil,
        gatewayRTT: Double? = nil,
        gatewayLoss: Double? = nil,
        inetRTT: Double? = nil,
        inetLoss: Double? = nil,
        bufferbloatGW: Double? = nil,
        bufferbloatInet: Double? = nil
    ) -> Result {
        let ruleSet = Set(rules)

        // 1. Evaluate Wi-Fi / Local Link Health
        var wifiHealth: HopHealth = .healthy
        if !isWifi {
            wifiHealth = .healthy // Ethernet wired
        } else if !ruleSet.isDisjoint(with: wifiCriticalRules) || (wifiRSSI != nil && wifiRSSI! <= -80) {
            wifiHealth = .critical
        } else if !ruleSet.isDisjoint(with: wifiWarningRules) || (wifiRSSI != nil && wifiRSSI! <= -75) {
            wifiHealth = .warning
        }

        // 2. Evaluate Local Router Health
        var routerHealth: HopHealth = .healthy
        if !ruleSet.isDisjoint(with: routerCriticalRules) || (gatewayLoss != nil && gatewayLoss! >= 10 && wifiHealth == .healthy) {
            routerHealth = .critical
        } else if !ruleSet.isDisjoint(with: routerWarningRules) || (bufferbloatGW != nil && bufferbloatGW! >= 150) {
            routerHealth = .warning
        }

        // 3. Evaluate Internet / ISP Health
        var ispHealth: HopHealth = .healthy
        if !ruleSet.isDisjoint(with: ispCriticalRules) || (inetLoss != nil && inetLoss! >= 10) {
            ispHealth = .critical
        } else if !ruleSet.isDisjoint(with: ispWarningRules) || (bufferbloatInet != nil && bufferbloatInet! >= 150) {
            ispHealth = .warning
        }

        // 4. Attribute Primary Culprit (Local precedes Upstream in root cause analysis)
        let culprit: Culprit
        let headline: String
        let reassurance: String

        if wifiHealth != .healthy {
            culprit = .wifi
            headline = "Local Wi-Fi Signal Degraded"
            if let rssi = wifiRSSI {
                reassurance = "Your Wi-Fi signal is weak (\(rssi) dBm). Moving closer to the access point or switching to 5GHz will resolve the packet loss."
            } else {
                reassurance = "The wireless link between your Mac and the router is dropping packets. Moving closer to the router or toggling Wi-Fi usually fixes this."
            }
        } else if routerHealth != .healthy {
            culprit = .router
            headline = "Local Router or Gateway Issue"
            if ruleSet.contains("B1") {
                reassurance = "Your Wi-Fi link is fine, but your router buffers heavily under load. Restarting the router or enabling Smart Queue Management (SQM) helps."
            } else {
                reassurance = "Your Wi-Fi connection is solid, but your router itself is dropping packets or experiencing elevated queue latency."
            }
        } else if ispHealth != .healthy {
            culprit = .isp
            headline = "Upstream Issue with Internet Service Provider"
            var parts: [String] = []
            if isWifi, let rssi = wifiRSSI {
                parts.append("Wi-Fi is strong (\(rssi) dBm)")
            } else if !isWifi {
                parts.append("Wired Ethernet is healthy")
            } else {
                parts.append("Wi-Fi is healthy")
            }
            if let gw = gatewayRTT {
                parts.append(String(format: "router ping is fast (%.1f ms)", gw))
            } else {
                parts.append("router is reachable")
            }
            let localStatus = parts.joined(separator: " and ")
            if ruleSet.contains("CP-1") {
                reassurance = "\(localStatus). A captive portal login is blocking access to the internet."
            } else if ruleSet.contains("B2") {
                reassurance = "\(localStatus). The latency surge is occurring upstream in your ISP's network."
            } else {
                reassurance = "\(localStatus). The packet loss and downtime are upstream on your ISP's broadband network."
            }
        } else {
            culprit = .none
            headline = "All Network Hops Healthy"
            reassurance = "Data flows cleanly from your Mac across the local network, through your router, and out to the internet."
        }

        return Result(
            culprit: culprit,
            macHealth: .healthy,
            wifiHealth: wifiHealth,
            routerHealth: routerHealth,
            ispHealth: ispHealth,
            headline: headline,
            reassurance: reassurance,
            isWired: !isWifi,
            activeRules: rules
        )
    }

    static func resolve(snapshot: RunSnapshot) -> Result {
        let rules = snapshot.diagnosis.compactMap(\.rule)
        let isWifi = snapshot.wifi != nil
        return resolve(
            rules: rules,
            isWifi: isWifi,
            wifiRSSI: snapshot.wifi?.rssi,
            gatewayRTT: snapshot.gateway.rttAvgMs,
            gatewayLoss: snapshot.gateway.lossPct,
            inetRTT: snapshot.internetLatency.rttAvgMs,
            inetLoss: snapshot.internetLatency.lossPct,
            bufferbloatGW: snapshot.bufferbloat.gwDeltaMs,
            bufferbloatInet: snapshot.bufferbloat.inetDeltaMs
        )
    }

    static func resolve(sample: MonitorSample) -> Result {
        let rules = sample.status.rules
        let isWifi = sample.link.isWiFi
        return resolve(
            rules: rules,
            isWifi: isWifi,
            wifiRSSI: sample.wifi?.rssi,
            gatewayRTT: sample.gateway.rttAvgMs,
            gatewayLoss: sample.gateway.lossPct,
            inetRTT: sample.internet.rttAvgMs,
            inetLoss: sample.internet.lossPct,
            bufferbloatGW: nil,
            bufferbloatInet: nil
        )
    }
}

// MARK: - SwiftUI Views

/// Full visual 3-hop attribution card for RunReportView:
/// [Mac] ──(Wi-Fi)──► [Router] ──(Broadband)──► [Internet]
public struct HopAttributionView: View {
    public let result: HopAttributionResolver.Result

    public init(result: HopAttributionResolver.Result) {
        self.result = result
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            // Header with Culprit Badge
            HStack(alignment: .center) {
                HStack(spacing: 6) {
                    Image(systemName: result.culprit == .none ? "checkmark.seal.fill" : "exclamationmark.octagon.fill")
                        .foregroundStyle(result.culprit.badgeTint)
                        .imageScale(.medium)
                    Text(result.headline)
                        .font(.headline)
                }
                Spacer()
                Text(result.culprit.badgeTitle)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(result.culprit.badgeTint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(result.culprit.badgeTint.opacity(0.12), in: Capsule())
            }

            // Visual Node & Link Chain
            HStack(alignment: .center, spacing: 0) {
                nodeView(title: "Mac", icon: "laptopcomputer", health: result.macHealth)

                linkSegment(label: result.isWired ? "Ethernet" : "Wi-Fi", health: result.wifiHealth)

                nodeView(title: "Router", icon: "wifi.router", health: result.routerHealth)

                linkSegment(label: "Broadband", health: result.ispHealth)

                nodeView(title: "Internet", icon: "globe", health: result.ispHealth)
            }
            .padding(.vertical, Theme.Spacing.xs)

            // Plain-English Reassurance Text
            Text(result.reassurance)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Spacing.md)
        .cardStyle()
    }

    private func nodeView(title: String, icon: String, health: HopAttributionResolver.HopHealth) -> some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(health == .healthy ? .primary : health.tint)
                    .frame(width: 40, height: 40)
                    .background(health.tint.opacity(0.12), in: Circle())

                Image(systemName: health.symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(health.tint)
                    .offset(x: 3, y: -2)
            }
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .frame(minWidth: 56)
    }

    private func linkSegment(label: String, health: HopAttributionResolver.HopHealth) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(health == .healthy ? .secondary : health.tint)

            HStack(spacing: 0) {
                Rectangle()
                    .fill(health.tint.opacity(health == .healthy ? 0.35 : 0.8))
                    .frame(height: 2)

                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(health.tint)
                    .offset(x: -2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 4)
    }
}

/// Compact 1-line hop attribution chain for DropdownView status cards:
public struct HopAttributionCompactView: View {
    public let result: HopAttributionResolver.Result

    public init(result: HopAttributionResolver.Result) {
        self.result = result
    }

    public var body: some View {
        HStack(spacing: 6) {
            miniNode("Mac", icon: "laptopcomputer", health: result.macHealth)
            miniArrow(result.wifiHealth)
            miniNode("Router", icon: "wifi.router", health: result.routerHealth)
            miniArrow(result.ispHealth)
            miniNode("Internet", icon: "globe", health: result.ispHealth)

            Spacer()

            Text(result.culprit.badgeTitle)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(result.culprit.badgeTint)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(result.culprit.badgeTint.opacity(0.12), in: Capsule())
        }
        .help(result.reassurance)
    }

    private func miniNode(_ name: String, icon: String, health: HopAttributionResolver.HopHealth) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(health.tint)
            Text(name)
                .font(.system(size: 10, weight: .medium))
        }
    }

    private func miniArrow(_ health: HopAttributionResolver.HopHealth) -> some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(health.tint)
    }
}
