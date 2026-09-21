import SwiftUI

/// Evaluates network suitability for everyday real-world activities
/// (Calls, Streaming, Gaming, VPN, Browsing) using live telemetry and saved diagnostics.
enum SuitabilityEngine {

    struct Item: Identifiable, Equatable {
        let id: String
        let title: String
        let icon: String
        let status: String
        let metric: String
        let tint: Color
        let verdict: RunSnapshot.SuitabilityRow.Verdict

        init(
            id: String,
            title: String,
            icon: String,
            status: String,
            metric: String,
            tint: Color,
            verdict: RunSnapshot.SuitabilityRow.Verdict
        ) {
            self.id = id
            self.title = title
            self.icon = icon
            self.status = status
            self.metric = metric
            self.tint = tint
            self.verdict = verdict
        }
    }

    struct Inputs {
        var monitorSample: MonitorSample?
        var speedTest: RunSnapshot.Speedtest?
        var savedSuitability: [RunSnapshot.SuitabilityRow]?
        var catalog: RulesCatalog?
        var firedRules: [String]
        var isLinkUp: Bool
        var isDoubleNat: Bool
        var mtu: Int?
        var vpnActive: Bool
        var vpnName: String?
        var currentJitter: Double?
        var effectiveLoss: Double?

        init(
            monitorSample: MonitorSample? = nil,
            speedTest: RunSnapshot.Speedtest? = nil,
            savedSuitability: [RunSnapshot.SuitabilityRow]? = nil,
            catalog: RulesCatalog? = nil,
            firedRules: [String] = [],
            isLinkUp: Bool = true,
            isDoubleNat: Bool = false,
            mtu: Int? = 1500,
            vpnActive: Bool = false,
            vpnName: String? = nil,
            currentJitter: Double? = nil,
            effectiveLoss: Double? = nil
        ) {
            self.monitorSample = monitorSample
            self.speedTest = speedTest
            self.savedSuitability = savedSuitability
            self.catalog = catalog
            self.firedRules = firedRules
            self.isLinkUp = isLinkUp
            self.isDoubleNat = isDoubleNat
            self.mtu = mtu
            self.vpnActive = vpnActive
            self.vpnName = vpnName
            self.currentJitter = currentJitter
            self.effectiveLoss = effectiveLoss
        }
    }

    static func evaluateAll(_ inputs: Inputs) -> [Item] {
        [
            evaluateCalls(inputs),
            evaluateStreaming(inputs),
            evaluateGaming(inputs),
            evaluateVPN(inputs),
            evaluateBrowsing(inputs)
        ]
    }

    // MARK: - 1. Calls (VoIP / Zoom / Teams / FaceTime)
    /// Primary factors: Packet loss and jitter. High latency is tolerable, but loss causes audio cutouts.
    static func evaluateCalls(_ inputs: Inputs) -> Item {
        if !inputs.isLinkUp {
            return Item(
                id: "calls",
                title: "Calls",
                icon: "video",
                status: "Offline",
                metric: "No link",
                tint: Theme.ColorToken.red,
                verdict: .broken
            )
        }

        let loss = inputs.effectiveLoss ?? inputs.monitorSample?.internet.lossPct ?? 0.0
        let jitter = inputs.currentJitter ?? inputs.monitorSample?.internet.rttJitterMs ?? 2.0
        let metric = String(format: "%.0f%% loss · %.0fms jit", loss, jitter)

        // Check catalog impact for fired rules
        let impacts = catalogImpacts(for: "calls", in: inputs)
        if impacts.contains("broken") || loss >= 8.0 || jitter >= 50.0 {
            return Item(
                id: "calls",
                title: "Calls",
                icon: "video",
                status: "Frequent cutouts",
                metric: metric,
                tint: Theme.ColorToken.red,
                verdict: .broken
            )
        }

        if impacts.contains("degraded") || loss >= 3.0 || jitter >= 25.0 {
            return Item(
                id: "calls",
                title: "Calls",
                icon: "video",
                status: "May cut out",
                metric: metric,
                tint: Theme.ColorToken.amber,
                verdict: .degraded
            )
        }

        return Item(
            id: "calls",
            title: "Calls",
            icon: "video",
            status: "Clear audio",
            metric: metric,
            tint: Theme.ColorToken.green,
            verdict: .good
        )
    }

    // MARK: - 2. Streaming (YouTube / Netflix / Twitch)
    /// Primary factor: Download bandwidth. Video pre-buffers 10-30s ahead, so high ping or bufferbloat does NOT degrade streaming.
    static func evaluateStreaming(_ inputs: Inputs) -> Item {
        if !inputs.isLinkUp {
            return Item(
                id: "streaming",
                title: "Streaming",
                icon: "play.rectangle",
                status: "Offline",
                metric: "No link",
                tint: Theme.ColorToken.red,
                verdict: .broken
            )
        }

        let loss = inputs.effectiveLoss ?? inputs.monitorSample?.internet.lossPct ?? 0.0
        let downMbps = inputs.speedTest?.downMbps

        if let mbps = downMbps {
            let metric = String(format: "%.0f Mbps ↓", mbps)
            if mbps < 2.5 || loss >= 15.0 {
                return Item(
                    id: "streaming",
                    title: "Streaming",
                    icon: "play.rectangle",
                    status: "Buffering",
                    metric: metric,
                    tint: Theme.ColorToken.red,
                    verdict: .broken
                )
            } else if mbps < 8.0 || loss >= 8.0 {
                return Item(
                    id: "streaming",
                    title: "Streaming",
                    icon: "play.rectangle",
                    status: "SD only",
                    metric: metric,
                    tint: Theme.ColorToken.amber,
                    verdict: .degraded
                )
            } else if mbps >= 25.0 && loss < 5.0 {
                return Item(
                    id: "streaming",
                    title: "Streaming",
                    icon: "play.rectangle",
                    status: "4K ready",
                    metric: metric,
                    tint: Theme.ColorToken.green,
                    verdict: .good
                )
            } else {
                return Item(
                    id: "streaming",
                    title: "Streaming",
                    icon: "play.rectangle",
                    status: "HD ready",
                    metric: metric,
                    tint: Theme.ColorToken.green,
                    verdict: .good
                )
            }
        }

        // When speed test is not available yet:
        // Ping is NOT used to degrade streaming. Only catastrophic loss degrades it.
        let impacts = catalogImpacts(for: "streaming", in: inputs)
        let metric = loss > 0 ? String(format: "%.0f%% loss", loss) : "Buffer ready"

        if impacts.contains("broken") || loss >= 15.0 {
            return Item(
                id: "streaming",
                title: "Streaming",
                icon: "play.rectangle",
                status: "Buffering",
                metric: metric,
                tint: Theme.ColorToken.red,
                verdict: .broken
            )
        }

        if impacts.contains("degraded") || loss >= 8.0 {
            return Item(
                id: "streaming",
                title: "Streaming",
                icon: "play.rectangle",
                status: "May buffer",
                metric: metric,
                tint: Theme.ColorToken.amber,
                verdict: .degraded
            )
        }

        return Item(
            id: "streaming",
            title: "Streaming",
            icon: "play.rectangle",
            status: "HD ready",
            metric: metric,
            tint: Theme.ColorToken.green,
            verdict: .good
        )
    }

    // MARK: - 3. Gaming (Multiplayer / Fast-twitch)
    /// Primary factors: RTT latency and jitter spikes. Loss causes rubberbanding.
    static func evaluateGaming(_ inputs: Inputs) -> Item {
        if !inputs.isLinkUp {
            return Item(
                id: "gaming",
                title: "Gaming",
                icon: "gamecontroller",
                status: "Offline",
                metric: "No link",
                tint: Theme.ColorToken.red,
                verdict: .broken
            )
        }

        let isIcmpFiltered = inputs.monitorSample?.status.icmpFiltered == true
        let rtt = inputs.monitorSample?.internet.rttAvgMs
        let jitter = inputs.currentJitter ?? inputs.monitorSample?.internet.rttJitterMs ?? 2.0
        let loss = inputs.effectiveLoss ?? inputs.monitorSample?.internet.lossPct ?? 0.0

        let impacts = catalogImpacts(for: "gaming", in: inputs)

        if isIcmpFiltered {
            let status = impacts.contains("degraded") ? "Lag likely" : "Smooth"
            let tint = impacts.contains("degraded") ? Theme.ColorToken.amber : Theme.ColorToken.green
            let verdict: RunSnapshot.SuitabilityRow.Verdict = impacts.contains("degraded") ? .degraded : .good
            return Item(
                id: "gaming",
                title: "Gaming",
                icon: "gamecontroller",
                status: status,
                metric: "TCP 443 ok",
                tint: tint,
                verdict: verdict
            )
        }

        guard let ping = rtt else {
            return Item(
                id: "gaming",
                title: "Gaming",
                icon: "gamecontroller",
                status: "Checking",
                metric: "Measuring",
                tint: Theme.ColorToken.muted,
                verdict: .unknown
            )
        }

        let metric = String(format: "%.0f ms · %.0fms jit", ping, jitter)

        if impacts.contains("broken") || ping >= 140.0 || jitter >= 45.0 || loss >= 5.0 {
            return Item(
                id: "gaming",
                title: "Gaming",
                icon: "gamecontroller",
                status: "Severe lag",
                metric: metric,
                tint: Theme.ColorToken.red,
                verdict: .broken
            )
        }

        if impacts.contains("degraded") || ping >= 80.0 || jitter >= 20.0 || loss >= 2.0 {
            return Item(
                id: "gaming",
                title: "Gaming",
                icon: "gamecontroller",
                status: "Moderate lag",
                metric: metric,
                tint: Theme.ColorToken.amber,
                verdict: .degraded
            )
        }

        return Item(
            id: "gaming",
            title: "Gaming",
            icon: "gamecontroller",
            status: "Low ping",
            metric: metric,
            tint: Theme.ColorToken.green,
            verdict: .good
        )
    }

    // MARK: - 4. VPN / Remote Access
    /// Primary factors: Double NAT, MTU clamping (<1380 bytes), active tunnels.
    static func evaluateVPN(_ inputs: Inputs) -> Item {
        if !inputs.isLinkUp {
            return Item(
                id: "vpn",
                title: "VPN / Remote",
                icon: "shield",
                status: "Offline",
                metric: "No link",
                tint: Theme.ColorToken.red,
                verdict: .broken
            )
        }

        let impacts = catalogImpacts(for: "vpn", in: inputs)

        if impacts.contains("broken") {
            return Item(
                id: "vpn",
                title: "VPN / Remote",
                icon: "shield",
                status: "Blocked",
                metric: "Tunnel blocked",
                tint: Theme.ColorToken.red,
                verdict: .broken
            )
        }

        if inputs.isDoubleNat {
            return Item(
                id: "vpn",
                title: "VPN / Remote",
                icon: "shield",
                status: "Double NAT",
                metric: "Tunnel risk",
                tint: Theme.ColorToken.amber,
                verdict: .degraded
            )
        }

        if let mtu = inputs.mtu, mtu < 1380 {
            return Item(
                id: "vpn",
                title: "VPN / Remote",
                icon: "shield",
                status: "MTU clamped",
                metric: "\(mtu) bytes",
                tint: Theme.ColorToken.amber,
                verdict: .degraded
            )
        }

        if impacts.contains("degraded") {
            return Item(
                id: "vpn",
                title: "VPN / Remote",
                icon: "shield",
                status: "May drop",
                metric: "High jitter",
                tint: Theme.ColorToken.amber,
                verdict: .degraded
            )
        }

        if inputs.vpnActive {
            return Item(
                id: "vpn",
                title: "VPN / Remote",
                icon: "shield",
                status: "Connected",
                metric: inputs.vpnName ?? "Active tunnel",
                tint: Theme.ColorToken.blue,
                verdict: .good
            )
        }

        return Item(
            id: "vpn",
            title: "VPN / Remote",
            icon: "shield",
            status: "Compatible",
            metric: "Direct route",
            tint: Theme.ColorToken.green,
            verdict: .good
        )
    }

    // MARK: - 5. Browsing (Web / SaaS)
    /// Primary factors: DNS resolution, TCP 443 reachability.
    static func evaluateBrowsing(_ inputs: Inputs) -> Item {
        if !inputs.isLinkUp {
            return Item(
                id: "browsing",
                title: "Browsing",
                icon: "globe",
                status: "Offline",
                metric: "No link",
                tint: Theme.ColorToken.red,
                verdict: .broken
            )
        }

        let impacts = catalogImpacts(for: "browsing", in: inputs)

        if impacts.contains("broken") {
            return Item(
                id: "browsing",
                title: "Browsing",
                icon: "globe",
                status: "Offline",
                metric: "Unreachable",
                tint: Theme.ColorToken.red,
                verdict: .broken
            )
        }

        if impacts.contains("degraded") {
            return Item(
                id: "browsing",
                title: "Browsing",
                icon: "globe",
                status: "Slow lookups",
                metric: "DNS latency",
                tint: Theme.ColorToken.amber,
                verdict: .degraded
            )
        }

        return Item(
            id: "browsing",
            title: "Browsing",
            icon: "globe",
            status: "Fast",
            metric: "TCP 443 ok",
            tint: Theme.ColorToken.green,
            verdict: .good
        )
    }

    // MARK: - Helper
    private static func catalogImpacts(for activity: String, in inputs: Inputs) -> [String] {
        guard let catalog = inputs.catalog else { return [] }
        return inputs.firedRules.compactMap { ruleID in
            catalog[ruleID]?.impacts?[activity]
        }
    }
}
