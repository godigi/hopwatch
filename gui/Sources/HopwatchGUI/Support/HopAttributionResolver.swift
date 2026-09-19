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
        case mac = "This Mac"
        case wifi = "Wi-Fi Signal"
        case router = "Local Router"
        case isp = "Internet Service Provider"

        public var badgeTitle: String {
            switch self {
            case .none:   return "All Hops Healthy"
            case .mac:    return "Culprit: Browser App"
            case .wifi:   return "Culprit: Weak Wi-Fi"
            case .router: return "Culprit: Router Issue"
            case .isp:    return "Culprit: ISP Outage"
            }
        }

        public var badgeTint: Color {
            switch self {
            case .none:   return .green
            case .mac:    return .orange
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
        public let badgeTitle: String
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
            badgeTitle: String? = nil,
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
            self.badgeTitle = badgeTitle ?? culprit.badgeTitle
            self.isWired = isWired
            self.activeRules = activeRules
        }
    }

    // MARK: - Rule Classifications

    private static let macCriticalRules: Set<String> = []
    private static let macWarningRules: Set<String> = ["BR-1", "CK-1", "EDNS-1"]

    private static let wifiCriticalRules: Set<String> = ["G1", "W1", "WD-1"]
    private static let wifiWarningRules: Set<String> = ["W2", "W3", "WS-1", "W4", "W5", "W6", "AWDL-1"]

    private static let routerCriticalRules: Set<String> = ["G2", "DI-1"]
    private static let routerWarningRules: Set<String> = ["G3", "B1", "NAT-1", "LAN-1", "DH-1", "DH-2", "DH-3"]

    private static let ispCriticalRules: Set<String> = ["P1", "P2", "N1", "N1b", "L1", "CP-1", "D1"]
    private static let ispWarningRules: Set<String> = ["L2", "B2", "D2", "D3", "D4", "D5", "M1", "SP-1", "BL-1"]

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

        // 0. Evaluate Mac / Host Health
        var macHealth: HopHealth = .healthy
        if !ruleSet.isDisjoint(with: macCriticalRules) {
            macHealth = .critical
        } else if !ruleSet.isDisjoint(with: macWarningRules) {
            macHealth = .warning
        }

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
        let isIcmpFiltered = ruleSet.contains("TCP-1") || ruleSet.contains("ICMP-1")
        let effectiveInetLoss = isIcmpFiltered ? nil : inetLoss
        var ispHealth: HopHealth = .healthy
        if !ruleSet.isDisjoint(with: ispCriticalRules) || (effectiveInetLoss != nil && effectiveInetLoss! >= 10) {
            ispHealth = .critical
        } else if !ruleSet.isDisjoint(with: ispWarningRules) || (bufferbloatInet != nil && bufferbloatInet! >= 150) {
            ispHealth = .warning
        }

        // 4. Attribute Primary Culprit (Local precedes Upstream in root cause analysis)
        let culprit: Culprit
        var headline: String
        let reassurance: String
        var badgeTitle: String

        // A broken browser process (BR-1) takes precedence over minor/advisory local degradation
        // when the physical network link is operational.
        if ruleSet.contains("BR-1") && wifiHealth != .critical && routerHealth != .critical && ispHealth != .critical {
            culprit = .mac
            headline = "Browser Needs Relaunch"
            badgeTitle = "Culprit: Browser App"
            reassurance = "A web browser updated in the background while open and its active session files were removed from disk. Quitting and reopening the browser finishes the update and restores normal browsing."
        } else if wifiHealth != .healthy {
            culprit = .wifi
            headline = "Local Wi-Fi Signal Degraded"
            badgeTitle = culprit.badgeTitle

            if ruleSet.contains("AWDL-1") {
                reassurance = "Apple Wireless Direct Link (AirDrop/Sidecar) channel hopping is causing periodic latency spikes. Setting AirDrop to 'Receiving Off' in Control Center restores steady ping."
            } else if ruleSet.contains("W6") {
                reassurance = "Your Mac is connected to the slower 2.4 GHz band while a faster 5 GHz band is available. Toggling Wi-Fi off and back on will prompt your Mac to join 5 GHz."
            } else if ruleSet.contains("W4") {
                reassurance = "Your Wi-Fi signal appears strong, but your transmit rate has collapsed. Moving closer or switching Wi-Fi bands will restore link speed."
            } else if ruleSet.contains("W5") {
                reassurance = "Your Mac hears the router well, but the router struggles to hear your Mac (asymmetric link). Moving closer balances transmission power."
            } else if ruleSet.contains("WS-1") {
                headline = "Wi-Fi Channel Crowded"
                let hasDrops = gatewayLoss != nil && gatewayLoss! > 0
                badgeTitle = hasDrops ? "Culprit: Crowded Channel" : "Advisory: Crowded Channel"
                reassurance = "Your Wi-Fi channel is crowded by neighboring networks. If performance is inconsistent, changing your router to a less congested channel will improve stability."
            } else if let rssi = wifiRSSI {
                reassurance = "Your Wi-Fi signal is weak (\(rssi) dBm). Moving closer to the access point or switching to 5GHz will resolve the packet loss."
            } else {
                if let loss = gatewayLoss, loss > 0 {
                    reassurance = "The wireless link between your Mac and the router is dropping packets. Moving closer to the router or toggling Wi-Fi usually fixes this."
                } else {
                    reassurance = "The wireless link between your Mac and the router is experiencing instability. Moving closer to the router or switching Wi-Fi bands usually helps."
                }
            }
        } else if routerHealth != .healthy {
            culprit = .router
            headline = "Local Router or Gateway Issue"
            badgeTitle = culprit.badgeTitle
            if ruleSet.contains("B1") {
                badgeTitle = "Culprit: Router Bufferbloat"
                reassurance = "Your Wi-Fi link is fine, but your router buffers heavily under load. Restarting the router or enabling Smart Queue Management (SQM) helps."
            } else {
                reassurance = "Your Wi-Fi connection is solid, but your router itself is dropping packets or experiencing elevated queue latency."
            }
        } else if ispHealth != .healthy {
            culprit = .isp
            headline = "Upstream Issue with Internet Service Provider"
            badgeTitle = culprit.badgeTitle
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
                badgeTitle = "Culprit: Captive Portal"
                reassurance = "\(localStatus). A captive portal login is blocking access to the internet."
            } else if ruleSet.contains("D5") {
                badgeTitle = "Culprit: Unresponsive DNS"
                reassurance = "\(localStatus). Your primary DNS server is unresponsive and queries are silently falling back to a secondary resolver."
            } else if ruleSet.contains("B2") {
                badgeTitle = "Culprit: Upstream Latency"
                reassurance = "\(localStatus). The latency surge is occurring upstream in your ISP's network."
            } else if (effectiveInetLoss != nil && effectiveInetLoss! >= 95) || ruleSet.contains("P1") || ruleSet.contains("P2") {
                badgeTitle = "Culprit: ISP Outage"
                reassurance = "\(localStatus). Complete packet loss past your router indicates an upstream ISP outage."
            } else if let loss = effectiveInetLoss, loss > 0 {
                badgeTitle = "Culprit: Upstream Packet Loss"
                reassurance = "\(localStatus). Packet loss (\(String(format: "%.0f%%", loss))) is occurring upstream on your ISP's broadband network."
            } else {
                reassurance = "\(localStatus). The packet loss and downtime are upstream on your ISP's broadband network."
            }
        } else if macHealth != .healthy {
            culprit = .mac
            headline = "Mac System / Application Issue"
            badgeTitle = culprit.badgeTitle
            if ruleSet.contains("CK-1") {
                reassurance = "Your Mac's system clock has drifted significantly from network time, which can disrupt TLS handshakes and secure connections."
            } else if ruleSet.contains("EDNS-1") {
                reassurance = "An encrypted DNS profile is active on your Mac. If lookups fail, check your installed profile in System Settings."
            } else {
                reassurance = "A local application or system configuration on your Mac is affecting network connectivity."
            }
        } else {
            culprit = .none
            headline = "All Network Hops Healthy"
            badgeTitle = culprit.badgeTitle
            reassurance = "Data flows cleanly from your Mac across the local network, through your router, and out to the internet."
        }

        return Result(
            culprit: culprit,
            macHealth: macHealth,
            wifiHealth: wifiHealth,
            routerHealth: routerHealth,
            ispHealth: ispHealth,
            headline: headline,
            reassurance: reassurance,
            badgeTitle: badgeTitle,
            isWired: !isWifi,
            activeRules: rules
        )
    }

    static func resolve(snapshot: RunSnapshot, fallbackRSSI: Int? = nil) -> Result {
        let rules = snapshot.diagnosis.compactMap(\.rule)
        let isWifi = snapshot.wifi != nil
        var res = resolve(
            rules: rules,
            isWifi: isWifi,
            wifiRSSI: snapshot.wifi?.rssi ?? fallbackRSSI,
            gatewayRTT: snapshot.gateway.rttAvgMs,
            gatewayLoss: snapshot.gateway.lossPct,
            inetRTT: snapshot.internetLatency.rttAvgMs,
            inetLoss: snapshot.internetLatency.lossPct,
            bufferbloatGW: snapshot.bufferbloat.gwDeltaMs,
            bufferbloatInet: snapshot.bufferbloat.inetDeltaMs
        )
        if rules.contains("BR-1"),
           let brDiag = snapshot.diagnosis.first(where: { $0.rule == "BR-1" }),
           res.culprit == .mac {
            res = Result(
                culprit: res.culprit,
                macHealth: res.macHealth,
                wifiHealth: res.wifiHealth,
                routerHealth: res.routerHealth,
                ispHealth: res.ispHealth,
                headline: res.headline,
                reassurance: brDiag.summary,
                badgeTitle: res.badgeTitle,
                isWired: res.isWired,
                activeRules: res.activeRules
            )
        }
        return res
    }

    static func resolve(sample: MonitorSample, fallbackRSSI: Int? = nil) -> Result {
        var rules = sample.status.rules
        if sample.status.icmpFiltered && !rules.contains("ICMP-1") && !rules.contains("TCP-1") {
            rules.append("ICMP-1")
        }
        let isWifi = sample.link.isWiFi
        return resolve(
            rules: rules,
            isWifi: isWifi,
            wifiRSSI: sample.wifi?.rssi ?? fallbackRSSI,
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
    @Environment(HopwatchCoordinator.self) private var coordinator
    @State private var isEvidenceExpanded = false

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
                Text(result.badgeTitle)
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

            // Expandable Evidence & Diagnostics drawer when there is an active culprit or rules
            if result.culprit != .none || !result.activeRules.isEmpty {
                Divider()
                    .padding(.vertical, 2)

                DisclosureGroup(isExpanded: $isEvidenceExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        if result.activeRules.isEmpty {
                            Text(result.reassurance)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(result.activeRules, id: \.self) { ruleID in
                                evidenceRow(ruleID: ruleID)
                            }
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(result.culprit.badgeTint)
                        Text(result.activeRules.count > 1 ? "Evidence & Diagnostics (\(result.activeRules.count) findings)" : "Evidence & Diagnostics")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                }
            }
        }
        .padding(Theme.Spacing.md)
        .cardStyle()
    }

    @ViewBuilder
    private func evidenceRow(ruleID: String) -> some View {
        let rule = coordinator.rulesCatalog.catalog?[ruleID]
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                RuleChip(ruleID: ruleID)
                if let title = rule?.title {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                }
            }
            if let blurb = rule?.blurb {
                Text(blurb)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let fix = rule?.fix {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 10))
                        .foregroundStyle(.blue)
                        .padding(.top, 1)
                    Text(fix)
                        .font(.caption)
                        .foregroundStyle(.primary)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.06))
        )
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

            Text(result.badgeTitle)
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
