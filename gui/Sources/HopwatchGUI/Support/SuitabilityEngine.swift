import SwiftUI

/// Evaluates network suitability for everyday real-world activities
/// (Calls, Streaming, Gaming, VPN, Browsing) using live telemetry and saved diagnostics.
enum SuitabilityEngine {

    /// The CLI's own cutoffs, restated for the fallback that judges a live
    /// sample when no rule has fired. The authority is lib/thresholds.sh:
    /// `LOSS_WARN_PCT`, `LOSS_CRIT_PCT`, `THRESH_LATENCY_JITTER_WARN_MS`,
    /// `THRESH_MTU_STANDARD`. The CLI projects an activity's verdict only
    /// through rule impacts (`helpers/suitability.py`) and has no latency-only
    /// rule, so a number below these is never "degraded" here either: an
    /// amber tile over a report that lists no finding is the contradiction
    /// this file used to produce.
    enum Cutoff {
        static let lossWarnPct = 10.0
        static let lossCritPct = 20.0
        static let jitterWarnMs = 30.0
        static let mtuStandard = 1400
        /// `THRESH_WIFI_SNR_LOW_DB`: W2 fires strictly below it.
        static let snrLowDb = 20
    }

    struct Item: Identifiable, Equatable {
        let id: String
        let title: String
        let icon: String
        let status: String
        let metric: String
        let tint: Color
        let verdict: RunSnapshot.SuitabilityRow.Verdict
        let helpText: String?
        let consequence: String
        /// The CLI rule this tile's status was taken from, when it was (see
        /// `evaluateBrowsing`). `nil` for every status decided from a number.
        var ruleID: String?

        init(
            id: String,
            title: String,
            icon: String,
            status: String,
            metric: String,
            tint: Color,
            verdict: RunSnapshot.SuitabilityRow.Verdict,
            helpText: String? = nil,
            consequence: String? = nil
        ) {
            self.id = id
            self.title = title
            self.icon = icon
            self.status = status
            self.metric = metric
            self.tint = tint
            self.verdict = verdict
            self.helpText = helpText
            self.consequence = consequence ?? Self.defaultConsequence(id: id, verdict: verdict, status: status)
        }

        static func defaultConsequence(id: String, verdict: RunSnapshot.SuitabilityRow.Verdict, status: String) -> String {
            switch id {
            case "calls":
                switch verdict {
                case .good:
                    return status == "HD video ready" ? "Crisp 1080p video & voice" : "Clear audio for voice calls"
                case .degraded:
                    if status == "Audio stutter" { return "Robotic speech distortion" }
                    if status == "Audio delay" { return "Conversational talk-over lag" }
                    if status == "Video limited" { return "Restricted to low-res video" }
                    return "Robotic audio & dropouts"
                case .broken:
                    return "Frequent call disconnections"
                case .unknown, .unmeasured:
                    return "Assessing call quality"
                }
            case "streaming":
                switch verdict {
                case .good:
                    return status == "4K ready" ? "Instant 4K Ultra HD" : "Smooth 1080p Full HD"
                case .degraded:
                    return "Occasional buffering or 720p"
                case .broken:
                    return "Frequent video buffering"
                case .unknown, .unmeasured:
                    return "Assessing video stream"
                }
            case "gaming":
                switch verdict {
                case .good:
                    return "Ultra-low ping, zero desync"
                case .degraded:
                    if status == "May rubberband" { return "Player desync & missed inputs" }
                    if status == "Spike risk" || status == "Lag spikes" { return "Intermittent hit registration lag" }
                    return "Player desync & rollbacks"
                case .broken:
                    return "Constant rubberbanding"
                case .unknown, .unmeasured:
                    return "Assessing multiplayer latency"
                }
            case "vpn":
                switch verdict {
                case .good:
                    return "Clean route & single NAT"
                case .degraded:
                    if status == "Double NAT" { return "VoIP / tunnel rekeys risk" }
                    if status == "Reduced MTU" || status == "MTU clamped" { return "Fragmentation overhead" }
                    return "Tunnel rekeys or MTU choke"
                case .broken:
                    return "VPN tunnels fail to connect"
                case .unknown, .unmeasured:
                    return "Assessing tunnel route"
                }
            case "browsing":
                switch verdict {
                case .good:
                    return "Fast DNS & page loads"
                case .degraded:
                    if status == "DNS slow" || status == "Slow lookups" { return "Initial domain lookup delay" }
                    return "Retransmissions delay web loads"
                case .broken:
                    return "Websites fail to load"
                case .unknown, .unmeasured:
                    return "Assessing web browsing"
                }
            default:
                return status
            }
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
        /// Which loss legs ping cannot measure (see `EffectiveLoss`). `nil`
        /// derives it from the sample's `icmp_filtered` flag and rule IDs plus
        /// `firedRules`, so every call site agrees even if it forgets to pass it.
        var lossFiltering: EffectiveLoss.Filtering?
        var isSettling: Bool
        var isArrivalCheck: Bool

        init(
            monitorSample: MonitorSample? = nil,
            speedTest: RunSnapshot.Speedtest? = nil,
            savedSuitability: [RunSnapshot.SuitabilityRow]? = nil,
            catalog: RulesCatalog? = nil,
            firedRules: [String] = [],
            isLinkUp: Bool = true,
            isDoubleNat: Bool = false,
            mtu: Int? = nil,
            vpnActive: Bool = false,
            vpnName: String? = nil,
            currentJitter: Double? = nil,
            effectiveLoss: Double? = nil,
            lossFiltering: EffectiveLoss.Filtering? = nil,
            isSettling: Bool = false,
            isArrivalCheck: Bool = false
        ) {
            self.lossFiltering = lossFiltering
            self.monitorSample = monitorSample?.status.paused == true ? nil : monitorSample
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
            self.isSettling = isSettling
            self.isArrivalCheck = isArrivalCheck
        }

        /// The legs a filter makes unmeasurable, resolved once for all evaluators.
        var filtering: EffectiveLoss.Filtering {
            lossFiltering ?? EffectiveLoss.filtering(sample: monitorSample, extraRuleIDs: firedRules)
        }

        /// Loss the evaluators judge. `effectiveLoss` when the coordinator
        /// supplied one; otherwise the sample's internet figure, unless that
        /// leg is filtered — a filtered figure is unknown, not its raw value,
        /// and unknown is judged as "no loss evidence" rather than 100%.
        var measuredLoss: Double? {
            if let effectiveLoss { return effectiveLoss }
            guard !filtering.internetLeg else { return nil }
            return monitorSample?.internet.lossPct
        }

        var resolvedLoss: Double { measuredLoss ?? 0.0 }
    }

    static func evaluateAll(_ inputs: Inputs) -> [Item] {
        if inputs.isSettling || inputs.isArrivalCheck {
            let isCheckingNetwork = inputs.isArrivalCheck
            let status = isCheckingNetwork ? "Checking…" : "Settling…"
            let help = isCheckingNetwork ? "Running initial check on network." : "Stabilizing connection baseline."
            return [
                Item(id: "calls", title: "Calls", icon: "video", status: status, metric: "Measuring", tint: Theme.ColorToken.muted, verdict: .unknown, helpText: help),
                Item(id: "streaming", title: "Streaming", icon: "play.rectangle", status: status, metric: "Measuring", tint: Theme.ColorToken.muted, verdict: .unknown, helpText: help),
                Item(id: "gaming", title: "Gaming", icon: "gamecontroller", status: status, metric: "Measuring", tint: Theme.ColorToken.muted, verdict: .unknown, helpText: help),
                Item(id: "vpn", title: "VPN / Remote", icon: "shield", status: status, metric: "Measuring", tint: Theme.ColorToken.muted, verdict: .unknown, helpText: help),
                Item(id: "browsing", title: "Browsing", icon: "globe", status: status, metric: "Measuring", tint: Theme.ColorToken.muted, verdict: .unknown, helpText: help)
            ]
        }
        return [
            saved("calls", "Calls", "video", inputs) ?? evaluateCalls(inputs),
            saved("streaming", "Streaming", "play.rectangle", inputs) ?? evaluateStreaming(inputs),
            saved("gaming", "Gaming", "gamecontroller", inputs) ?? evaluateGaming(inputs),
            saved("vpn", "VPN / Remote", "shield", inputs) ?? evaluateVPN(inputs),
            saved("browsing", "Browsing", "globe", inputs) ?? evaluateBrowsing(inputs)
        ]
    }

    /// The CLI's own verdict for `id`, shown as a tile when nothing live is
    /// judging instead. With no monitor sample (monitoring off or paused)
    /// the last run's `suitability` rows are the only evidence there is, and
    /// they are the CLI's answer, so they are used as written rather than
    /// re-derived. The metric line says they come from the last check: a
    /// verdict about the past must not read as one about right now. While a
    /// live sample exists, the live path judges, through the fired rules and
    /// the catalog's `impacts`, which are the same projection.
    private static func saved(_ id: String, _ title: String, _ icon: String, _ inputs: Inputs) -> Item? {
        guard inputs.monitorSample == nil,
              let row = inputs.savedSuitability?.first(where: { $0.activity == id }) else { return nil }
        let tint: Color
        switch row.verdict {
        case .good:                 tint = Theme.ColorToken.green
        case .degraded:             tint = Theme.ColorToken.amber
        case .broken:               tint = Theme.ColorToken.red
        case .unmeasured, .unknown: tint = Theme.ColorToken.muted
        }
        let metric: String
        switch row.verdict {
        case .unmeasured: metric = row.unmeasuredReason ?? "Not measured"
        case .unknown:    metric = "Not measured"
        default:          metric = "From last check"
        }
        // No `ruleID`: that marks a tile whose wording is a rule's own title,
        // and the headline builder keys off it.
        return Item(
            id: id, title: title, icon: icon,
            status: SuitabilityPanel.word(row.verdict),
            metric: metric,
            tint: tint,
            verdict: row.verdict,
            helpText: SuitabilityPanel.detail(row, catalog: inputs.catalog)
        )
    }

    static func awaiting(_ id: String, _ title: String, _ icon: String, metric: String = "Not measured") -> Item {
        Item(id: id, title: title, icon: icon, status: "Checking…",
             metric: metric, tint: Theme.ColorToken.muted, verdict: .unknown,
             helpText: "Waiting for measurements from this connection.")
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

        let loss = inputs.resolvedLoss
        let measuredJitter = inputs.currentJitter ?? inputs.monitorSample?.internet.rttJitterMs
        let jitter = measuredJitter ?? 2.0
        let lossAndJitterMetric = measuredJitter != nil
            ? "\(LossFormatter.formatLoss(loss)) · \(Int(round(jitter)))ms jit"
            : LossFormatter.formatLoss(loss)
        let ping = inputs.monitorSample?.internet.rttAvgMs ?? 0.0
        let upMbps = inputs.speedTest?.upMbps
        let downMbps = inputs.speedTest?.downMbps

        let impacts = catalogImpacts(for: "calls", in: inputs)

        // 1. Broken: a rule the CLI says breaks calls, loss at the CLI's critical cutoff, or choked upload
        if impacts.contains("broken") || loss >= Cutoff.lossCritPct || (upMbps != nil && upMbps! < 0.4) {
            let status: String
            let metric: String
            let help: String

            if loss >= Cutoff.lossCritPct {
                status = "Frequent cutouts"
                metric = lossAndJitterMetric
                help = "High packet loss (≥\(Int(Cutoff.lossCritPct))%) causing severe audio dropouts, choppy speech, and frozen video"
            } else if let up = upMbps, up < 0.4 {
                status = "Low bandwidth"
                metric = String(format: "%.1f Mbps ↑", up)
                help = "Insufficient upload bandwidth (<0.4 Mbps) to sustain stable voice or video calls"
            } else {
                status = "Frequent cutouts"
                metric = lossAndJitterMetric
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

        // 2. Degraded: a rule the CLI says degrades calls, loss or jitter at the CLI's cutoffs, or low bandwidth
        if impacts.contains("degraded") || loss >= Cutoff.lossWarnPct || jitter >= Cutoff.jitterWarnMs || (upMbps != nil && upMbps! < 1.0) || (downMbps != nil && downMbps! < 1.5) {
            let status: String
            let metric: String
            let help: String

            if loss >= Cutoff.lossWarnPct {
                status = "May cut out"
                metric = lossAndJitterMetric
                help = "Elevated packet loss (≥\(Int(Cutoff.lossWarnPct))%) may cause words to drop, robotic audio, and momentary video stutter"
            } else if jitter >= Cutoff.jitterWarnMs {
                status = "Audio stutter"
                metric = lossAndJitterMetric
                help = "Elevated jitter (≥\(Int(Cutoff.jitterWarnMs))ms) causing audio pitch warping, robotic voice, or micro-stutters"
            } else if let up = upMbps, up < 1.0 {
                status = "Video limited"
                metric = String(format: "%.1f Mbps ↑", up)
                help = "Low upload bandwidth (<1.0 Mbps) restricts calls to low resolution or audio-only to prevent freezing"
            } else if let down = downMbps, down < 1.5 {
                status = "Video limited"
                metric = String(format: "%.1f Mbps ↓", down)
                help = "Low download bandwidth (<1.5 Mbps) may cause incoming video feeds to drop resolution or pause"
            } else if loss == 0.0 && jitter < 15.0 {
                status = "Glitch risk"
                metric = lossAndJitterMetric
                help = "Channel contention or route issues may cause occasional audio glitches"
            } else {
                status = "May cut out"
                metric = lossAndJitterMetric
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
        let pingFiltered = inputs.filtering.internetLeg
        if pingFiltered {
            let tcpMs = inputs.monitorSample?.tcp.targets.filter(\.ok).compactMap(\.elapsedMs).min()
            let callMetric = tcpMs != nil ? "\(Int(round(tcpMs!)))ms TCP" : "TCP 443 ok"
            return Item(
                id: "calls",
                title: "Calls",
                icon: "video",
                status: "Clear audio",
                metric: callMetric,
                tint: Theme.ColorToken.green,
                verdict: .good,
                helpText: "Voice and video calls work over TCP/UDP while ICMP ping is blocked by network policy"
            )
        }

        guard inputs.monitorSample?.internet.rttAvgMs != nil,
              inputs.currentJitter != nil || inputs.monitorSample?.internet.rttJitterMs != nil,
              inputs.measuredLoss != nil else {
            return awaiting("calls", "Calls", "video")
        }
        // Pristine HD Video tier: upload >= 3.0 Mbps, loss < 1.0%, jitter < 8.0ms, ping < 150.0ms
        // Standard Clear Audio tier: loss < 1.0%, jitter < 15.0ms
        let metric = "\(LossFormatter.formatLoss(loss)) · \(Int(round(jitter)))ms jit"
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

        let loss = inputs.resolvedLoss
        let downMbps = inputs.speedTest?.downMbps

        if let mbps = downMbps {
            let speedStr = mbps >= 10.0 ? String(format: "%.0f Mbps ↓", mbps) : String(format: "%.1f Mbps ↓", mbps)

            if mbps < 2.5 || loss >= Cutoff.lossCritPct {
                let metric = loss >= Cutoff.lossCritPct ? LossFormatter.formatLoss(loss) : speedStr
                let help = loss >= Cutoff.lossCritPct
                    ? "Severe packet loss (≥\(Int(Cutoff.lossCritPct))%) causing video playback buffer starvation and frequent freezing"
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
            } else if mbps < 8.0 || loss >= Cutoff.lossWarnPct {
                let metric = loss >= Cutoff.lossWarnPct ? LossFormatter.formatLoss(loss) : speedStr
                let help = loss >= Cutoff.lossWarnPct
                    ? "Packet loss (≥\(Int(Cutoff.lossWarnPct))%) causes throughput drops, forcing video players to downgrade to standard definition (SD)"
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
        let metric = loss > 0 ? LossFormatter.formatLoss(loss) : "Clean link"

        if impacts.contains("broken") || loss >= Cutoff.lossCritPct {
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

        if impacts.contains("degraded") || loss >= Cutoff.lossWarnPct {
            let streamMetric = loss >= Cutoff.lossWarnPct ? LossFormatter.formatLoss(loss) : "Route check"
            return Item(
                id: "streaming",
                title: "Streaming",
                icon: "play.rectangle",
                status: "May buffer",
                metric: streamMetric,
                tint: Theme.ColorToken.amber,
                verdict: .degraded,
                helpText: "Packet loss or route congestion may cause occasional video buffering"
            )
        }

        guard inputs.measuredLoss != nil else {
            return awaiting("streaming", "Streaming", "play.rectangle")
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

        let rtt = inputs.monitorSample?.internet.rttAvgMs
        let measuredJitter = inputs.currentJitter ?? inputs.monitorSample?.internet.rttJitterMs
        let jitter = measuredJitter ?? 2.0
        let loss = inputs.resolvedLoss

        let impacts = catalogImpacts(for: "gaming", in: inputs)

        // Ping-derived numbers are genuinely unavailable only when a filter is
        // declared AND no usable RTT came back. Loss, jitter and catalog
        // impacts still judge below; only the "all clear" is reworded, because
        // without RTT the most that can be said is that TCP connects.
        let pingFiltered = rtt == nil && inputs.filtering.any

        guard rtt != nil || pingFiltered else {
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
        let ping = rtt ?? 0.0

        // For gaming, packet loss causes rubberbanding and input drops, which takes priority
        // over raw jitter when reporting the compact metric.
        let metric: String
        if pingFiltered {
            metric = loss > 0 ? LossFormatter.formatLoss(loss) : "TCP 443 ok"
        } else if loss > 0 {
            metric = String(format: "%.0f ms · %@", ping, LossFormatter.formatLoss(loss))
        } else if measuredJitter != nil {
            metric = String(format: "%.0f ms · %.0fms jit", ping, jitter)
        } else {
            metric = String(format: "%.0f ms", ping)
        }

        // Broken: a rule the CLI says breaks gaming, or loss at the CLI's critical cutoff
        if impacts.contains("broken") || loss >= Cutoff.lossCritPct {
            let status: String
            let help: String
            if loss >= Cutoff.lossCritPct {
                status = "Rubberbanding"
                help = "Severe packet loss (≥\(Int(Cutoff.lossCritPct))%) causing constant rollbacks, desync, and hit registration failure"
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

        // Degraded: a rule the CLI says degrades gaming, loss at the warn cutoff, or jitter over the CLI's cutoff
        if impacts.contains("degraded") || loss >= Cutoff.lossWarnPct || jitter >= Cutoff.jitterWarnMs {
            let status: String
            let help: String
            if loss >= Cutoff.lossWarnPct {
                status = "May rubberband"
                help = "Packet loss may cause rubberbanding, player warping, and dropped inputs"
            } else if jitter >= Cutoff.jitterWarnMs {
                status = "Lag spikes"
                help = "High jitter causes sudden latency spikes and micro-stutter"
            } else if ping < 35.0 && jitter < 10.0 && loss == 0.0 {
                status = "Spike risk"
                help = "Channel contention or route issues may cause occasional latency spikes despite low average ping"
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
        if pingFiltered {
            return Item(
                id: "gaming",
                title: "Gaming",
                icon: "gamecontroller",
                status: "Unmeasured",
                metric: "No ICMP",
                tint: Theme.ColorToken.muted,
                verdict: .unknown,
                helpText: "Gaming latency cannot be established because ICMP ping is blocked by network policy"
            )
        }

        guard inputs.currentJitter != nil || inputs.monitorSample?.internet.rttJitterMs != nil,
              inputs.measuredLoss != nil else {
            return awaiting("gaming", "Gaming", "gamecontroller")
        }
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
    /// Primary factors: Double NAT, MTU clamping (below the CLI's standard MTU), active tunnels.
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

        if let mtu = inputs.mtu, mtu < Cutoff.mtuStandard {
            return Item(
                id: "vpn",
                title: "VPN / Remote",
                icon: "shield",
                status: "MTU clamped",
                metric: "\(mtu) bytes",
                tint: Theme.ColorToken.amber,
                verdict: .degraded,
                helpText: "Path MTU is clamped (<\(Cutoff.mtuStandard) bytes), which can cause tunnel packet drops"
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

        guard inputs.mtu != nil || inputs.measuredLoss != nil || inputs.monitorSample?.gateway.rttAvgMs != nil || inputs.monitorSample?.internet.rttAvgMs != nil else {
            return awaiting("vpn", "VPN / Remote", "shield")
        }

        let metric = inputs.mtu.map { "\($0) bytes" } ?? "Direct route"
        return Item(
            id: "vpn",
            title: "VPN / Remote",
            icon: "shield",
            status: "Compatible",
            metric: metric,
            tint: Theme.ColorToken.green,
            verdict: .good,
            helpText: inputs.mtu != nil
                ? "Measured packet size supports common VPN tunnels"
                : "Single NAT and direct route support VPN tunnels and remote work"
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

        let loss = inputs.resolvedLoss
        // A failed lookup or connect in the sample is ONE probe, and it is
        // not this tile's to judge: the same fault looked like "DNS failing"
        // on one cycle and "Web blocked" on the next, depending on which
        // probe lost. The monitor confirms a failure over several samples
        // and names it (CONN-1, D1, P1/P2) in status.rules, which arrives
        // here as `firedRules` and through the catalog's `impacts`. The raw
        // samples are read only for what they can still honestly say: how
        // long a lookup took when it was answered, and that something is
        // being rechecked.
        let dnsOk = inputs.monitorSample?.dns.ok
        let dnsElapsed = dnsOk == false ? nil : inputs.monitorSample?.dns.elapsedMs
        let tcpOk = inputs.monitorSample?.tcp.anyOk
        let downMbps = inputs.speedTest?.downMbps
        let impacts = catalogImpacts(for: "browsing", in: inputs)

        // 1. Broken conditions: extreme packet loss, or a rule the CLI says breaks browsing
        if impacts.contains("broken") || loss >= Cutoff.lossCritPct {
            let status: String
            let metric: String
            let help: String

            if loss >= Cutoff.lossCritPct {
                status = "Pages stall"
                metric = LossFormatter.formatLoss(loss)
                help = "Severe packet loss (≥\(Int(Cutoff.lossCritPct))%) causes TCP connection stalls and failed web page rendering"
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
        if impacts.contains("degraded") || (dnsElapsed != nil && dnsElapsed! >= 250.0) || loss >= Cutoff.lossWarnPct || (downMbps != nil && downMbps! < 1.0) {
            let status: String
            let metric: String
            let help: String

            var ruleConsequence: String?
            var ruleID: String?
            if loss >= Cutoff.lossWarnPct {
                status = "Sluggish"
                metric = LossFormatter.formatLoss(loss)
                help = "Elevated packet loss (≥\(Int(Cutoff.lossWarnPct))%) causes TCP retransmissions and delayed web page rendering"
            } else if let rule = catalogRule(impacting: "browsing", in: inputs) {
                // A confirmed finding (CONN-1, D1, ...): the CLI's own words.
                // The metric is the ping figure on purpose — it is what makes
                // "connections failing while pings are fine" visible.
                status = rule.title ?? rule.id
                ruleID = rule.id
                metric = LossFormatter.formatLoss(loss)
                help = rule.blurb ?? status
                ruleConsequence = rule.blurb.map(firstSentence)
            } else if let dnsMs = dnsElapsed, dnsMs >= 250.0 {
                status = "Slow lookups"
                metric = String(format: "%.0fms DNS", dnsMs)
                help = "DNS lookups are taking ≥250ms, causing a noticeable delay before websites start loading"
            } else if let down = downMbps, down < 1.0 {
                status = "Slow assets"
                metric = String(format: "%.1f Mbps ↓", down)
                help = "Low download bandwidth (<1.0 Mbps) causes images, media, and web assets to load slowly"
            } else {
                status = "Slow lookups"
                metric = "DNS latency"
                help = "Elevated DNS resolution latency causing slow initial page loads"
            }

            var item = Item(
                id: "browsing",
                title: "Browsing",
                icon: "globe",
                status: status,
                metric: metric,
                tint: Theme.ColorToken.amber,
                verdict: .degraded,
                helpText: help,
                consequence: ruleConsequence
            )
            item.ruleID = ruleID
            return item
        }

        // 3. Good conditions: fast DNS & responsive TCP/HTTPS
        guard dnsOk == true, tcpOk == true else {
            return awaiting("browsing", "Browsing", "globe",
                            metric: dnsOk == false || tcpOk == false ? "Rechecking" : "Not measured")
        }
        let metric: String
        let help: String
        if let dnsMs = dnsElapsed, dnsMs < 60.0 {
            metric = String(format: "%.0fms DNS", dnsMs)
            help = "Fast DNS lookups (<60ms) and responsive HTTPS connectivity for snappy web browsing"
        } else if loss > 0 {
            metric = LossFormatter.formatLoss(loss)
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
        effectiveLoss: Double? = nil,
        lossFiltering: EffectiveLoss.Filtering? = nil
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

        // A leg the CLI says ping cannot measure is unknown, not its raw figure.
        let filtering = lossFiltering ?? EffectiveLoss.filtering(sample: monitorSample)
        let gwLoss = filtering.gatewayLeg ? 0.0 : (monitorSample?.gateway.lossPct ?? 0.0)
        let inetLoss = effectiveLoss ?? (filtering.internetLeg ? 0.0 : (monitorSample?.internet.lossPct ?? 0.0))
        // Downstream validation: if internet loss is clean (< 2.0%), isolated router loss (< 20%)
        // is control-plane rate limiting and does not indicate data-plane link drops.
        // Never when the CLI has confirmed it: a firing gateway rule (G1, G2, G3) is the
        // verdict, and the measured loss is what the finding is about.
        let gatewayRuleFiring = !Set(monitorSample?.status.rules ?? []).isDisjoint(with: ["G1", "G2", "G3"])
        let effectiveGWLoss = (!gatewayRuleFiring && inetLoss < 2.0 && gwLoss < 20.0) ? min(gwLoss, inetLoss) : gwLoss
        let loss = max(effectiveGWLoss, inetLoss)
        let jitter = currentJitter ?? monitorSample?.internet.rttJitterMs ?? 0.0
        let isWiFi = monitorSample?.link.isWiFi ?? false
        let isRouterCulprit = (effectiveGWLoss >= Cutoff.lossWarnPct) || (monitorSample?.gateway.rttJitterMs ?? 0.0) >= Cutoff.jitterWarnMs
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
            let streamNote = streaming?.verdict == .good ? " · 4K streaming is fine" : ""
            if loss > 0 && jitter >= 5.0 {
                if inetLoss > 0 && gwLoss < 1.0 && (monitorSample?.gateway.rttJitterMs ?? 0.0) >= Cutoff.jitterWarnMs {
                    let jitLabel = isWiFi ? "Wi-Fi jitter" : "jitter to router"
                    subtitle = String(format: "%@ internet packet loss · %.0fms %@%@", LossFormatter.formatPct(inetLoss), jitter, jitLabel, streamNote)
                } else if effectiveGWLoss > 0 && inetLoss < 1.0 {
                    let lossLabel = isWiFi ? "Wi-Fi packet loss" : "packet loss to router"
                    subtitle = String(format: "%@ %@ · %.0fms jitter%@", LossFormatter.formatPct(effectiveGWLoss), lossLabel, jitter, streamNote)
                } else {
                    subtitle = String(format: "%@ · %.0fms jitter%@%@", LossFormatter.formatPacketLoss(loss), jitter, targetSuffix, streamNote)
                }
            } else if loss > 0 {
                if inetLoss > 0 && effectiveGWLoss < 1.0 && isRouterCulprit {
                    subtitle = String(format: "%@ internet packet loss%@", LossFormatter.formatPct(inetLoss), streamNote)
                } else if effectiveGWLoss > 0 && inetLoss < 1.0 {
                    let lossLabel = isWiFi ? "Wi-Fi packet loss" : "packet loss to router"
                    subtitle = String(format: "%@ %@%@", LossFormatter.formatPct(effectiveGWLoss), lossLabel, streamNote)
                } else {
                    subtitle = String(format: "%@%@%@", LossFormatter.formatPacketLoss(loss), targetSuffix, streamNote)
                }
            } else {
                let ping = monitorSample?.internet.rttAvgMs ?? 0.0
                subtitle = String(format: "%.0f ms ping · %.0fms jitter%@", ping, jitter, streamNote)
            }
        } else if callsBroken || callsDegraded {
            if callsBroken {
                if loss >= Cutoff.lossCritPct {
                    headline = "Frequent cutouts on calls"
                } else if calls?.status == "Low bandwidth" {
                    headline = "Calls failing from low bandwidth"
                } else {
                    headline = "Frequent cutouts on calls"
                }
            } else {
                if loss >= Cutoff.lossWarnPct {
                    headline = "Voice & video calls may cut out"
                } else if jitter >= Cutoff.jitterWarnMs {
                    headline = "Audio stutter on calls"
                } else if calls?.status == "Video limited" {
                    headline = "Video may freeze on calls"
                } else {
                    headline = "Voice & video calls may cut out"
                }
            }
            subtitle = "\(calls?.metric ?? "")\(targetSuffix)" + fineSuffix([("Browsing", browsing), ("streaming", streaming)])
        } else if gamingBroken || gamingDegraded {
            if gamingBroken {
                if loss >= Cutoff.lossCritPct {
                    headline = "Severe rubberbanding in games"
                } else {
                    headline = "Severe lag in games"
                }
            } else {
                if loss >= Cutoff.lossWarnPct {
                    headline = "Rubberbanding in games"
                } else if jitter >= Cutoff.jitterWarnMs {
                    headline = "Lag spikes in games"
                } else {
                    headline = "Moderate lag in games"
                }
            }
            subtitle = "\(gaming?.metric ?? "")" + fineSuffix([("Web browsing", browsing), ("streaming", streaming)])
        } else if streamingBroken || streamingDegraded {
            if streamingBroken {
                if loss >= Cutoff.lossCritPct {
                    headline = "Severe packet loss buffering video"
                } else if streaming?.metric.contains("Mbps") == true {
                    headline = "Video buffering from low bandwidth"
                } else {
                    headline = "Video streaming is buffering"
                }
            } else {
                if loss >= Cutoff.lossWarnPct {
                    headline = "Packet loss may buffer video"
                } else if streaming?.status == "SD only" {
                    headline = "Streaming limited to standard definition"
                } else {
                    headline = "Video streaming quality reduced"
                }
            }
            subtitle = "\(streaming?.metric ?? "")\(targetSuffix)" + fineSuffix([("Calls", calls), ("web browsing", browsing)])
        } else if browsingBroken || browsingDegraded {
            // A lookup that failed took as long as its timeout, which says
            // nothing about how slow DNS is.
            let dnsElapsed = monitorSample?.dns.ok == false ? nil : monitorSample?.dns.elapsedMs

            if browsingBroken {
                if loss >= Cutoff.lossCritPct {
                    headline = "Web pages failing from packet loss"
                } else {
                    headline = "Websites aren't loading"
                }
            } else if let rule = browsing, rule.ruleID != nil {
                // The CLI's own title for the finding, not a headline written here.
                headline = rule.status
            } else {
                if browsing?.status == "Slow lookups" || (dnsElapsed != nil && dnsElapsed! >= 250.0) {
                    headline = "Slow DNS delaying page loads"
                } else if loss >= Cutoff.lossWarnPct {
                    headline = "Web browsing sluggish from packet loss"
                } else if browsing?.status == "Slow assets" {
                    headline = "Web pages loading slowly"
                } else {
                    headline = "Web browsing is slow"
                }
            }
            subtitle = "\(browsing?.metric ?? "")\(targetSuffix)" + fineSuffix([("Video streaming", streaming)])
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

    /// " · A & b fine" naming only the activities whose tile verdict is `.good`;
    /// empty when none qualify, so a headline never reassures about a tile that
    /// is red or still unmeasured. The first label is capitalised, later ones
    /// are joined as written ("Browsing & streaming fine").
    private static func fineSuffix(_ activities: [(label: String, item: Item?)]) -> String {
        let good = activities.filter { $0.item?.verdict == .good }.map(\.label)
        guard let first = good.first else { return "" }
        let head = first.prefix(1).uppercased() + first.dropFirst()
        let named = ([head] + good.dropFirst()).joined(separator: " & ")
        return " · \(named) fine"
    }

    /// The first fired rule the CLI's catalog says affects `activity`, so the
    /// tile can show that rule's own title and blurb instead of a verdict
    /// written here.
    private static func catalogRule(impacting activity: String, in inputs: Inputs) -> RulesCatalog.Rule? {
        guard let catalog = inputs.catalog else { return nil }
        for ruleID in inputs.firedRules {
            if let rule = catalog[ruleID], rule.impacts?[activity] != nil { return rule }
        }
        return nil
    }

    private static func firstSentence(_ text: String) -> String {
        guard let end = text.range(of: ". ") else { return text }
        return String(text[..<end.lowerBound]) + "."
    }

    private static func catalogImpacts(for activity: String, in inputs: Inputs) -> [String] {
        guard let catalog = inputs.catalog else { return [] }
        return inputs.firedRules.compactMap { ruleID in
            catalog[ruleID]?.impacts?[activity]
        }
    }
}
