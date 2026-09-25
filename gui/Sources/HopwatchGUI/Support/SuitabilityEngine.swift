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
        let helpText: String?

        init(
            id: String,
            title: String,
            icon: String,
            status: String,
            metric: String,
            tint: Color,
            verdict: RunSnapshot.SuitabilityRow.Verdict,
            helpText: String? = nil
        ) {
            self.id = id
            self.title = title
            self.icon = icon
            self.status = status
            self.metric = metric
            self.tint = tint
            self.verdict = verdict
            self.helpText = helpText
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
    /// Primary factors: Packet loss and jitter (audio cutouts/stutter), latency (talk-over delay), and upload bandwidth (video freeze).
    static func evaluateCalls(_ inputs: Inputs) -> Item {
        if !inputs.isLinkUp {
            return Item(
                id: "calls",
                title: "Calls",
                icon: "video",
                status: "Offline",
                metric: "No link",
                tint: Theme.ColorToken.red,
                verdict: .broken,
                helpText: "Network link is down"
            )
        }

        let loss = inputs.effectiveLoss ?? inputs.monitorSample?.internet.lossPct ?? 0.0
        let jitter = inputs.currentJitter ?? inputs.monitorSample?.internet.rttJitterMs ?? 2.0
        let ping = inputs.monitorSample?.internet.rttAvgMs ?? 0.0
        let upMbps = inputs.speedTest?.upMbps
        let downMbps = inputs.speedTest?.downMbps

        let impacts = catalogImpacts(for: "calls", in: inputs)

        // 1. Broken conditions: severe packet loss, severe jitter buffer underruns, extreme latency, or choked bandwidth
        if impacts.contains("broken") || loss >= 8.0 || jitter >= 50.0 || ping >= 400.0 || (upMbps != nil && upMbps! < 0.4) {
            let status: String
            let metric: String
            let help: String

            if loss >= 8.0 {
                status = "Frequent cutouts"
                metric = String(format: "%.0f%% loss · %.0fms jit", loss, jitter)
                help = "High packet loss (≥8%) causing severe audio dropouts, choppy speech, and frozen video"
            } else if jitter >= 50.0 {
                status = "Severe stutter"
                metric = String(format: "%.0f%% loss · %.0fms jit", loss, jitter)
                help = "Extreme jitter (≥50ms) causing jitter buffer overruns, severe robotic distortion, and audio stutter"
            } else if ping >= 400.0 {
                status = "Heavy delay"
                metric = String(format: "%.0f ms delay", ping)
                help = "Extreme round-trip latency (≥400ms) causing awkward delays and frequent accidental interruption"
            } else if let up = upMbps, up < 0.4 {
                status = "Low bandwidth"
                metric = String(format: "%.1f Mbps ↑", up)
                help = "Insufficient upload bandwidth (<0.4 Mbps) to sustain stable voice or video calls"
            } else {
                status = "Frequent cutouts"
                metric = String(format: "%.0f%% loss · %.0fms jit", loss, jitter)
                help = "Network conditions causing frequent audio cutouts or call failures"
            }

            return Item(
                id: "calls",
                title: "Calls",
                icon: "video",
                status: status,
                metric: metric,
                tint: Theme.ColorToken.red,
                verdict: .broken,
                helpText: help
            )
        }

        // 2. Degraded conditions: audio cutouts from packet loss, jitter stutter, latency delay, or upload choke
        if impacts.contains("degraded") || loss >= 3.0 || jitter >= 25.0 || ping >= 250.0 || (upMbps != nil && upMbps! < 1.0) || (downMbps != nil && downMbps! < 1.5) {
            let status: String
            let metric: String
            let help: String

            if loss >= 3.0 {
                status = "May cut out"
                metric = String(format: "%.0f%% loss · %.0fms jit", loss, jitter)
                help = "Elevated packet loss (≥3%) may cause words to drop, robotic audio, and momentary video stutter"
            } else if jitter >= 25.0 {
                status = "Audio stutter"
                metric = String(format: "%.0f%% loss · %.0fms jit", loss, jitter)
                help = "Elevated jitter (≥25ms) causing audio pitch warping, robotic voice, or micro-stutters"
            } else if ping >= 250.0 {
                status = "Audio delay"
                metric = String(format: "%.0f ms delay", ping)
                help = "Elevated latency (≥250ms) causing conversational delay and talk-over in two-way calls"
            } else if let up = upMbps, up < 1.0 {
                status = "Video limited"
                metric = String(format: "%.1f Mbps ↑", up)
                help = "Low upload bandwidth (<1.0 Mbps) restricts calls to low resolution or audio-only to prevent freezing"
            } else if let down = downMbps, down < 1.5 {
                status = "Video limited"
                metric = String(format: "%.1f Mbps ↓", down)
                help = "Low download bandwidth (<1.5 Mbps) may cause incoming video feeds to drop resolution or pause"
            } else {
                status = "May cut out"
                metric = String(format: "%.0f%% loss · %.0fms jit", loss, jitter)
                help = "Network conditions or route issues may cause intermittent voice or video degradation"
            }

            return Item(
                id: "calls",
                title: "Calls",
                icon: "video",
                status: status,
                metric: metric,
                tint: Theme.ColorToken.amber,
                verdict: .degraded,
                helpText: help
            )
        }

        // 3. Good conditions:
        // Pristine HD Video tier: upload >= 3.0 Mbps, loss < 1.0%, jitter < 8.0ms, ping < 150.0ms
        // Standard Clear Audio tier: loss < 1.0%, jitter < 15.0ms
        let metric = String(format: "%.0f%% loss · %.0fms jit", loss, jitter)
        if let up = upMbps, up >= 3.0, loss < 1.0, jitter < 8.0, ping < 150.0 {
            return Item(
                id: "calls",
                title: "Calls",
                icon: "video",
                status: "HD video ready",
                metric: metric,
                tint: Theme.ColorToken.green,
                verdict: .good,
                helpText: "Zero packet loss, low jitter, and ample upload bandwidth for crisp 1080p video calls"
            )
        }

        return Item(
            id: "calls",
            title: "Calls",
            icon: "video",
            status: "Clear audio",
            metric: metric,
            tint: Theme.ColorToken.green,
            verdict: .good,
            helpText: "Zero packet loss and low jitter for clear voice and video calls"
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
                verdict: .broken,
                helpText: "Network link is down"
            )
        }

        let loss = inputs.effectiveLoss ?? inputs.monitorSample?.internet.lossPct ?? 0.0
        let downMbps = inputs.speedTest?.downMbps

        if let mbps = downMbps {
            let speedStr = mbps >= 10.0 ? String(format: "%.0f Mbps ↓", mbps) : String(format: "%.1f Mbps ↓", mbps)

            if mbps < 2.5 || loss >= 15.0 {
                let metric = loss >= 15.0 ? String(format: "%.0f%% loss", loss) : speedStr
                let help = loss >= 15.0
                    ? "Severe packet loss (≥15%) causing video playback buffer starvation and frequent freezing"
                    : "Insufficient download bandwidth (<2.5 Mbps) causing video to stall and buffer"
                return Item(
                    id: "streaming",
                    title: "Streaming",
                    icon: "play.rectangle",
                    status: "Buffering",
                    metric: metric,
                    tint: Theme.ColorToken.red,
                    verdict: .broken,
                    helpText: help
                )
            } else if mbps < 8.0 || loss >= 8.0 {
                let metric = loss >= 8.0 ? String(format: "%.0f%% loss", loss) : speedStr
                let help = loss >= 8.0
                    ? "Packet loss (≥8%) causes throughput drops, forcing video players to downgrade to standard definition (SD)"
                    : "Limited download speed (<8.0 Mbps) restricts streaming to standard definition (SD)"
                return Item(
                    id: "streaming",
                    title: "Streaming",
                    icon: "play.rectangle",
                    status: "SD only",
                    metric: metric,
                    tint: Theme.ColorToken.amber,
                    verdict: .degraded,
                    helpText: help
                )
            } else if mbps >= 25.0 && loss < 5.0 {
                return Item(
                    id: "streaming",
                    title: "Streaming",
                    icon: "play.rectangle",
                    status: "4K ready",
                    metric: speedStr,
                    tint: Theme.ColorToken.green,
                    verdict: .good,
                    helpText: "High download bandwidth for instant 4K Ultra HD video streaming"
                )
            } else {
                return Item(
                    id: "streaming",
                    title: "Streaming",
                    icon: "play.rectangle",
                    status: "HD ready",
                    metric: speedStr,
                    tint: Theme.ColorToken.green,
                    verdict: .good,
                    helpText: "Sufficient download bandwidth for smooth 1080p Full HD video"
                )
            }
        }

        // When speed test is not available yet:
        // Ping is NOT used to degrade streaming. Only catastrophic loss degrades it.
        let impacts = catalogImpacts(for: "streaming", in: inputs)
        let metric = loss > 0 ? String(format: "%.0f%% loss", loss) : "Clean link"

        if impacts.contains("broken") || loss >= 15.0 {
            return Item(
                id: "streaming",
                title: "Streaming",
                icon: "play.rectangle",
                status: "Buffering",
                metric: metric,
                tint: Theme.ColorToken.red,
                verdict: .broken,
                helpText: "Catastrophic packet loss causing video streaming buffer starvation"
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
                verdict: .degraded,
                helpText: "Packet loss or route congestion may cause occasional video buffering"
            )
        }

        return Item(
            id: "streaming",
            title: "Streaming",
            icon: "play.rectangle",
            status: "HD ready",
            metric: metric,
            tint: Theme.ColorToken.green,
            verdict: .good,
            helpText: "Zero packet loss and stable link ready for buffered video streaming"
        )
    }

    // MARK: - 3. Gaming (Multiplayer / Fast-twitch)
    /// Primary factors: RTT latency, jitter spikes, and packet loss. Loss causes rubberbanding, jitter causes spikes.
    static func evaluateGaming(_ inputs: Inputs) -> Item {
        if !inputs.isLinkUp {
            return Item(
                id: "gaming",
                title: "Gaming",
                icon: "gamecontroller",
                status: "Offline",
                metric: "No link",
                tint: Theme.ColorToken.red,
                verdict: .broken,
                helpText: "Network link is down"
            )
        }

        let isIcmpFiltered = inputs.monitorSample?.status.icmpFiltered == true
        let rtt = inputs.monitorSample?.internet.rttAvgMs
        let jitter = inputs.currentJitter ?? inputs.monitorSample?.internet.rttJitterMs ?? 2.0
        let loss = inputs.effectiveLoss ?? inputs.monitorSample?.internet.lossPct ?? 0.0

        let impacts = catalogImpacts(for: "gaming", in: inputs)

        if isIcmpFiltered {
            let isBroken = impacts.contains("broken")
            let isDegraded = impacts.contains("degraded")
            let status = isBroken ? "Severe lag" : (isDegraded ? "Lag likely" : "Smooth")
            let tint = isBroken ? Theme.ColorToken.red : (isDegraded ? Theme.ColorToken.amber : Theme.ColorToken.green)
            let verdict: RunSnapshot.SuitabilityRow.Verdict = isBroken ? .broken : (isDegraded ? .degraded : .good)
            let help = isBroken
                ? "ICMP ping blocked; diagnosis rules report broken gaming conditions"
                : (isDegraded
                    ? "ICMP ping blocked; diagnosis rules report degraded gaming conditions"
                    : "ICMP ping blocked by network, but TCP 443 connection is healthy")
            return Item(
                id: "gaming",
                title: "Gaming",
                icon: "gamecontroller",
                status: status,
                metric: "TCP 443 ok",
                tint: tint,
                verdict: verdict,
                helpText: help
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
                verdict: .unknown,
                helpText: "Measuring latency, jitter, and packet loss…"
            )
        }

        // For gaming, packet loss causes rubberbanding and input drops, which takes priority
        // over raw jitter when reporting the compact metric.
        let metric: String
        if loss >= 1.0 {
            metric = String(format: "%.0f ms · %.0f%% loss", ping, loss)
        } else {
            metric = String(format: "%.0f ms · %.0fms jit", ping, jitter)
        }

        // Broken conditions: constant rollbacks, extreme jitter desync, or unplayable ping
        if impacts.contains("broken") || loss >= 8.0 || jitter >= 45.0 || ping >= 140.0 {
            let status: String
            let help: String
            if loss >= 8.0 {
                status = "Rubberbanding"
                help = "Severe packet loss (≥8%) causing constant rollbacks, desync, and hit registration failure"
            } else if jitter >= 45.0 {
                status = "Frequent spikes"
                help = "Severe jitter causing frequent latency spikes, stuttering, and sync loss"
            } else if ping >= 140.0 {
                status = "Severe lag"
                help = "High latency (>140ms) causing heavy delay and competitive disadvantage"
            } else {
                status = "Severe lag"
                help = "Network conditions causing severe lag in online games"
            }
            return Item(
                id: "gaming",
                title: "Gaming",
                icon: "gamecontroller",
                status: status,
                metric: metric,
                tint: Theme.ColorToken.red,
                verdict: .broken,
                helpText: help
            )
        }

        // Degraded conditions: noticeable rollbacks, latency spikes, or elevated ping
        if impacts.contains("degraded") || loss >= 2.0 || jitter >= 20.0 || ping >= 80.0 {
            let status: String
            let help: String
            if loss >= 2.0 {
                status = "May rubberband"
                help = "Packet loss may cause rubberbanding, player warping, and dropped inputs"
            } else if jitter >= 20.0 {
                status = "Lag spikes"
                help = "High jitter causes sudden latency spikes and micro-stutter"
            } else if ping >= 80.0 {
                status = "Noticeable delay"
                help = "Elevated ping (≥80ms) causes slight delay between actions and server response"
            } else {
                status = "Lag likely"
                help = "Network conditions or route issues may cause intermittent lag in games"
            }
            return Item(
                id: "gaming",
                title: "Gaming",
                icon: "gamecontroller",
                status: status,
                metric: metric,
                tint: Theme.ColorToken.amber,
                verdict: .degraded,
                helpText: help
            )
        }

        // Good conditions:
        // Ping <= 35ms with jitter < 8ms and loss < 1%: competitive tier ("Responsive")
        // Ping 35-80ms with jitter < 20ms: smooth multiplayer ("Smooth")
        if ping <= 35.0 && jitter < 8.0 && loss < 1.0 {
            return Item(
                id: "gaming",
                title: "Gaming",
                icon: "gamecontroller",
                status: "Responsive",
                metric: metric,
                tint: Theme.ColorToken.green,
                verdict: .good,
                helpText: "Ultra-low latency (<35ms) & stable jitter for competitive fast-twitch gaming"
            )
        }

        return Item(
            id: "gaming",
            title: "Gaming",
            icon: "gamecontroller",
            status: "Smooth",
            metric: metric,
            tint: Theme.ColorToken.green,
            verdict: .good,
            helpText: "Stable latency and jitter for online multiplayer gaming"
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
                verdict: .broken,
                helpText: "Network link is down"
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
                verdict: .broken,
                helpText: "Network route or firewall blocking VPN tunnel traffic"
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
                verdict: .degraded,
                helpText: "Multiple NAT layers may interfere with incoming connections and peer tunnels"
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
                verdict: .degraded,
                helpText: "Path MTU is clamped (<1380 bytes), which can cause tunnel packet drops"
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
                verdict: .degraded,
                helpText: "Jitter or packet drops may cause intermittent VPN reconnects"
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
                verdict: .good,
                helpText: "Active VPN tunnel connected and routing traffic"
            )
        }

        return Item(
            id: "vpn",
            title: "VPN / Remote",
            icon: "shield",
            status: "Compatible",
            metric: "Direct route",
            tint: Theme.ColorToken.green,
            verdict: .good,
            helpText: "Clean path MTU and single NAT — fully compatible with VPN tunnels"
        )
    }

    // MARK: - 5. Browsing (Web / SaaS)
    /// Primary factors: DNS resolution speed & reliability, TCP 443 HTTPS reachability, packet loss, and latency.
    static func evaluateBrowsing(_ inputs: Inputs) -> Item {
        if !inputs.isLinkUp {
            return Item(
                id: "browsing",
                title: "Browsing",
                icon: "globe",
                status: "Offline",
                metric: "No link",
                tint: Theme.ColorToken.red,
                verdict: .broken,
                helpText: "Network link is down"
            )
        }

        let loss = inputs.effectiveLoss ?? inputs.monitorSample?.internet.lossPct ?? 0.0
        let ping = inputs.monitorSample?.internet.rttAvgMs ?? 0.0
        let dnsOk = inputs.monitorSample?.dns.ok
        let dnsElapsed = inputs.monitorSample?.dns.elapsedMs
        let tcpOk = inputs.monitorSample?.tcp.anyOk
        let downMbps = inputs.speedTest?.downMbps
        let impacts = catalogImpacts(for: "browsing", in: inputs)

        // 1. Broken conditions: DNS resolution failure, TCP 443 blocked, extreme packet loss, or diagnostic outage
        if impacts.contains("broken") || dnsOk == false || tcpOk == false || loss >= 15.0 {
            let status: String
            let metric: String
            let help: String

            if dnsOk == false {
                status = "DNS failing"
                metric = "Lookup failed"
                help = "Domain name resolution is failing; web addresses cannot be resolved to IP addresses"
            } else if tcpOk == false {
                status = "Web blocked"
                metric = "Port 443 down"
                help = "Outbound HTTPS (port 443) traffic is blocked or unreachable; websites cannot load"
            } else if loss >= 15.0 {
                status = "Pages stall"
                metric = String(format: "%.0f%% loss", loss)
                help = "Severe packet loss (≥15%) causes TCP connection stalls and failed web page rendering"
            } else {
                status = "Offline"
                metric = "Unreachable"
                help = "DNS resolution or web services completely unreachable"
            }

            return Item(
                id: "browsing",
                title: "Browsing",
                icon: "globe",
                status: status,
                metric: metric,
                tint: Theme.ColorToken.red,
                verdict: .broken,
                helpText: help
            )
        }

        // 2. Degraded conditions: slow DNS lookups, elevated packet loss, high latency, or severely choked bandwidth
        if impacts.contains("degraded") || (dnsElapsed != nil && dnsElapsed! >= 250.0) || loss >= 6.0 || ping >= 350.0 || (downMbps != nil && downMbps! < 1.0) {
            let status: String
            let metric: String
            let help: String

            if loss >= 6.0 {
                status = "Sluggish"
                metric = String(format: "%.0f%% loss", loss)
                help = "Elevated packet loss (≥6%) causes TCP retransmissions and delayed web page rendering"
            } else if let dnsMs = dnsElapsed, dnsMs >= 250.0 {
                status = "Slow lookups"
                metric = String(format: "%.0fms DNS", dnsMs)
                help = "DNS lookups are taking ≥250ms, causing a noticeable delay before websites start loading"
            } else if ping >= 350.0 {
                status = "Slow loads"
                metric = String(format: "%.0f ms ping", ping)
                help = "High round-trip latency (≥350ms) slows down TCP handshakes and interactive web apps"
            } else if let down = downMbps, down < 1.0 {
                status = "Slow assets"
                metric = String(format: "%.1f Mbps ↓", down)
                help = "Low download bandwidth (<1.0 Mbps) causes images, media, and web assets to load slowly"
            } else {
                status = "Slow lookups"
                metric = "DNS latency"
                help = "Elevated DNS resolution latency causing slow initial page loads"
            }

            return Item(
                id: "browsing",
                title: "Browsing",
                icon: "globe",
                status: status,
                metric: metric,
                tint: Theme.ColorToken.amber,
                verdict: .degraded,
                helpText: help
            )
        }

        // 3. Good conditions: fast DNS & responsive TCP/HTTPS
        let metric: String
        let help: String
        if let dnsMs = dnsElapsed, dnsMs < 60.0 {
            metric = String(format: "%.0fms DNS", dnsMs)
            help = "Fast DNS lookups (<60ms) and responsive HTTPS connectivity for snappy web browsing"
        } else if loss > 0 {
            metric = String(format: "%.0f%% loss", loss)
            help = "Low packet loss and reliable HTTPS connectivity for web browsing"
        } else {
            metric = "TCP 443 ok"
            help = "Fast DNS resolution and reliable HTTPS connectivity"
        }

        return Item(
            id: "browsing",
            title: "Browsing",
            icon: "globe",
            status: "Fast",
            metric: metric,
            tint: Theme.ColorToken.green,
            verdict: .good,
            helpText: help
        )
    }

    // MARK: - Synthesis

    /// Synthesizes a human-oriented status headline and subtitle when network conditions
    /// degrade everyday activities (Calls, Gaming, Streaming, Browsing), even if no coarse
    /// CLI rule has fired. Returns `nil` if all activities are healthy.
    static func synthesizeDegradedExperience(
        items: [Item],
        monitorSample: MonitorSample?,
        currentJitter: Double? = nil,
        effectiveLoss: Double? = nil
    ) -> StageResolver.DegradedSnapshot? {
        let calls = items.first { $0.id == "calls" }
        let gaming = items.first { $0.id == "gaming" }
        let streaming = items.first { $0.id == "streaming" }
        let browsing = items.first { $0.id == "browsing" }

        let callsBroken = calls?.verdict == .broken
        let callsDegraded = calls?.verdict == .degraded
        let gamingBroken = gaming?.verdict == .broken
        let gamingDegraded = gaming?.verdict == .degraded
        let streamingBroken = streaming?.verdict == .broken
        let streamingDegraded = streaming?.verdict == .degraded
        let browsingBroken = browsing?.verdict == .broken
        let browsingDegraded = browsing?.verdict == .degraded

        let anyBroken = callsBroken || gamingBroken || streamingBroken || browsingBroken
        let anyDegraded = callsDegraded || gamingDegraded || streamingDegraded || browsingDegraded

        guard anyBroken || anyDegraded else { return nil }

        let gwLoss = monitorSample?.gateway.lossPct ?? 0.0
        let inetLoss = effectiveLoss ?? monitorSample?.internet.lossPct ?? 0.0
        let loss = max(gwLoss, inetLoss)
        let jitter = currentJitter ?? monitorSample?.internet.rttJitterMs ?? 0.0
        let isWiFi = monitorSample?.link.isWiFi ?? false
        let isRouterCulprit = gwLoss >= 2.0 || (monitorSample?.gateway.rttJitterMs ?? 0.0) >= 20.0
        let targetSuffix = isRouterCulprit ? (isWiFi ? " on Wi-Fi" : " to router") : ""

        var affected: [String] = []
        if callsBroken || callsDegraded { affected.append("Calls") }
        if gamingBroken || gamingDegraded { affected.append("Gaming") }
        if streamingBroken || streamingDegraded { affected.append("Streaming") }
        if browsingBroken || browsingDegraded { affected.append("Browsing") }

        let headline: String
        let subtitle: String

        if (callsBroken || callsDegraded) && (gamingBroken || gamingDegraded) {
            headline = (callsBroken || gamingBroken) ? "Unstable for calls & gaming" : "Calls & gaming may lag"
            let streamingOk = streaming?.verdict == .good
            let streamNote = streamingOk ? " · 4K streaming is fine" : ""
            if loss >= 1.0 && jitter >= 5.0 {
                if inetLoss >= 1.0 && gwLoss < 1.0 && (monitorSample?.gateway.rttJitterMs ?? 0.0) >= 20.0 {
                    let jitLabel = isWiFi ? "Wi-Fi jitter" : "jitter to router"
                    subtitle = String(format: "%.0f%% internet packet loss · %.0fms %@%@", inetLoss, jitter, jitLabel, streamNote)
                } else if gwLoss >= 1.0 && inetLoss < 1.0 {
                    let lossLabel = isWiFi ? "Wi-Fi packet loss" : "packet loss to router"
                    subtitle = String(format: "%.0f%% %@ · %.0fms jitter%@", gwLoss, lossLabel, jitter, streamNote)
                } else {
                    subtitle = String(format: "%.0f%% packet loss · %.0fms jitter%@%@", loss, jitter, targetSuffix, streamNote)
                }
            } else if loss >= 1.0 {
                if inetLoss >= 1.0 && gwLoss < 1.0 && isRouterCulprit {
                    subtitle = String(format: "%.0f%% internet packet loss%@", inetLoss, streamNote)
                } else if gwLoss >= 1.0 && inetLoss < 1.0 {
                    let lossLabel = isWiFi ? "Wi-Fi packet loss" : "packet loss to router"
                    subtitle = String(format: "%.0f%% %@%@", gwLoss, lossLabel, streamNote)
                } else {
                    subtitle = String(format: "%.0f%% packet loss%@%@", loss, targetSuffix, streamNote)
                }
            } else {
                let ping = monitorSample?.internet.rttAvgMs ?? 0.0
                subtitle = String(format: "%.0f ms ping · %.0fms jitter%@", ping, jitter, streamNote)
            }
        } else if callsBroken || callsDegraded {
            let ping = monitorSample?.internet.rttAvgMs ?? 0.0
            if callsBroken {
                if loss >= 8.0 {
                    headline = "Frequent cutouts on calls"
                } else if jitter >= 50.0 {
                    headline = "Severe audio stutter on calls"
                } else if ping >= 400.0 {
                    headline = "Heavy delay on calls"
                } else if calls?.status == "Low bandwidth" {
                    headline = "Calls failing from low bandwidth"
                } else {
                    headline = "Frequent cutouts on calls"
                }
            } else {
                if loss >= 3.0 {
                    headline = "Voice & video calls may cut out"
                } else if jitter >= 25.0 {
                    headline = "Audio stutter on calls"
                } else if ping >= 250.0 {
                    headline = "Audio delay on calls"
                } else if calls?.status == "Video limited" {
                    headline = "Video may freeze on calls"
                } else {
                    headline = "Voice & video calls may cut out"
                }
            }
            subtitle = "\(calls?.metric ?? "")\(targetSuffix) · Browsing & streaming fine"
        } else if gamingBroken || gamingDegraded {
            let ping = monitorSample?.internet.rttAvgMs ?? 0.0
            if gamingBroken {
                if loss >= 8.0 {
                    headline = "Severe rubberbanding in games"
                } else if jitter >= 45.0 {
                    headline = "Severe lag spikes in games"
                } else if ping >= 140 {
                    headline = "High lag for gaming"
                } else {
                    headline = "Severe lag in games"
                }
            } else {
                if loss >= 2.0 {
                    headline = "Rubberbanding in games"
                } else if jitter >= 20.0 {
                    headline = "Lag spikes in games"
                } else if ping >= 80.0 {
                    headline = "Delayed response in games"
                } else {
                    headline = "Moderate lag in games"
                }
            }
            subtitle = "\(gaming?.metric ?? "") · Web browsing & streaming fine"
        } else if streamingBroken || streamingDegraded {
            if streamingBroken {
                if loss >= 15.0 {
                    headline = "Severe packet loss buffering video"
                } else if streaming?.metric.contains("Mbps") == true {
                    headline = "Video buffering from low bandwidth"
                } else {
                    headline = "Video streaming is buffering"
                }
            } else {
                if loss >= 8.0 {
                    headline = "Packet loss may buffer video"
                } else if streaming?.status == "SD only" {
                    headline = "Streaming limited to standard definition"
                } else {
                    headline = "Video streaming quality reduced"
                }
            }
            subtitle = "\(streaming?.metric ?? "")\(targetSuffix) · Calls & web browsing fine"
        } else if browsingBroken || browsingDegraded {
            let dnsElapsed = monitorSample?.dns.elapsedMs
            let ping = monitorSample?.internet.rttAvgMs ?? 0.0

            if browsingBroken {
                if browsing?.status == "DNS failing" || monitorSample?.dns.ok == false {
                    headline = "DNS lookup failure"
                } else if browsing?.status == "Web blocked" || monitorSample?.tcp.anyOk == false {
                    headline = "Web traffic blocked (port 443)"
                } else if loss >= 15.0 {
                    headline = "Web pages failing from packet loss"
                } else {
                    headline = "Websites aren't loading"
                }
            } else {
                if browsing?.status == "Slow lookups" || (dnsElapsed != nil && dnsElapsed! >= 250.0) {
                    headline = "Slow DNS delaying page loads"
                } else if loss >= 6.0 {
                    headline = "Web browsing sluggish from packet loss"
                } else if ping >= 350.0 {
                    headline = "Web browsing delayed by high latency"
                } else if browsing?.status == "Slow assets" {
                    headline = "Web pages loading slowly"
                } else {
                    headline = "Web browsing is slow"
                }
            }
            subtitle = "\(browsing?.metric ?? "")\(targetSuffix) · Video streaming fine"
        } else {
            headline = "Connection is degraded"
            subtitle = "Some services may experience intermittent slowdowns."
        }

        return StageResolver.DegradedSnapshot(
            headline: headline,
            subtitle: subtitle,
            isCritical: anyBroken,
            affectedActivities: affected
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
