import SwiftUI

/// Renders the CLI's suitability judgements.
///
/// Since the reporting-accuracy plan's Phase 3 there is no
/// engine here: every verdict (good / degraded / broken / unmeasured),
/// every label and every metric line arrives pre-computed from
/// helpers/inference.py — judged against lib/thresholds.sh up the street,
/// the same source lib/diagnosis.sh and lib/monitor.sh read. This file
/// used to re-derive all of it from its own private cutoffs (calls broken
/// at 8% loss in the Swift; 10/20% in the CLI) — the "green row above a
/// red paragraph" bug, and the reason the rule now reads: the GUI holds
/// no diagnostic logic. What remains is the rendering: one icon and one
/// tint per activity and verdict, chosen from the verdict enum the CLI
/// itself writes, never from a figure.
///
/// Rows come from either the live monitor sample's `suitability` block or
/// a stored run's `suitability` (helpers/suitability.py). When neither is
/// present — an older CLI — every activity proves nothing was judged and
/// renders as unmeasured rather than guessing.
enum SuitabilityEngine {

    struct Item: Identifiable, Equatable {
        let id: String
        let title: String
        let icon: String
        /// The CLI's short word for the row (its label), rendered verbatim.
        let status: String
        /// The figure line backing that word ("3% loss · 9 ms jitter").
        let metric: String
        let tint: Color
        let verdict: RunSnapshot.SuitabilityRow.Verdict
        let helpText: String?
        let consequence: String?

        /// The sentence the chip renders when its body calls for one.
        var consequenceText: String { consequence ?? "" }

        init(row: RunSnapshot.SuitabilityRow) {
            let activity = row.activity ?? "?"
            self.id = activity
            self.title = SuitabilityEngine.titleFor(activity)
            self.icon = SuitabilityEngine.iconFor(activity)
            self.status = row.label ?? SuitabilityEngine.fallbackLabelFor(row.verdict)
            self.metric = row.metric ?? ""
            self.tint = SuitabilityEngine.tintFor(verdict: row.verdict)
            self.verdict = row.verdict
            self.helpText = row.detail ?? row.unmeasuredReason
            self.consequence = SuitabilityEngine.consequenceFor(activity, verdict: row.verdict)
        }

        private init(id: String, title: String, icon: String, status: String,
                     metric: String, tint: Color, verdict: RunSnapshot.SuitabilityRow.Verdict,
                     helpText: String?, consequence: String?) {
            self.id = id
            self.title = title
            self.icon = icon
            self.status = status
            self.metric = metric
            self.tint = tint
            self.verdict = verdict
            self.helpText = helpText
            self.consequence = consequence
        }

        /// The item for an activity the CLI declined to judge (no row in
        /// the block, an older CLI, a block omitted, or — on run snapshots
        /// — a run that predates the field). Deliberately neutral: no
        /// verdict phrase, no figure.
        static func unmeasured(activity: String) -> Item {
            Item(
                id: activity,
                title: SuitabilityEngine.titleFor(activity),
                icon: SuitabilityEngine.iconFor(activity),
                status: "Not measured",
                metric: "",
                tint: Theme.ColorToken.muted,
                verdict: .unmeasured,
                helpText: "Hopwatch hasn't assessed this activity yet.",
                consequence: "Run a full check to assess it."
            )
        }
    }

    /// Items for the five activities, from whichever judgement source is
    /// available. `sample` wins (live); `snapshot`'s saved rows second
    /// (history); unmeasured rows otherwise.
    static func items(sample: MonitorSample?, snapshot: RunSnapshot?) -> [Item] {
        let rows: [RunSnapshot.SuitabilityRow]
        if let fromSample = sample?.suitability, !fromSample.isEmpty {
            rows = fromSample
        } else if let fromRun = snapshot?.suitability, !fromRun.isEmpty {
            rows = fromRun
        } else {
            return ACTIVITY_IDS.map { Item.unmeasured(activity: $0) }
        }
        let byActivity = Dictionary(
            rows.compactMap { row -> (String, Item)? in
                row.activity.map { ($0, Item(row: row)) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        return ACTIVITY_IDS.map { byActivity[$0] ?? Item.unmeasured(activity: $0) }
    }

    /// The degraded status hero's copy, from the sample's `headline` block.
    /// `nil` — the healthy card, with the app's own copy — when the CLI
    /// says every grid activity is good, or when it declines to judge.
    static func degradedExperience(_ sample: MonitorSample?) -> StageResolver.DegradedSnapshot? {
        guard let headline = sample?.headline else { return nil }
        return StageResolver.DegradedSnapshot(
            headline: headline.text,
            subtitle: headline.subtitle,
            isCritical: headline.critical
        )
    }

    // MARK: - Rendering tables
    // Pure lookups by closed sets. `ACTIVITY_IDS` doubles as the dependency
    // on the CLI's own vocabulary (helpers/suitability.py ACTIVITY_ORDER).

    static let ACTIVITY_IDS: [String] = ["calls", "streaming", "gaming", "vpn", "browsing"]

    private static func titleFor(_ activity: String) -> String {
        switch activity {
        case "calls":     return "Calls"
        case "streaming": return "Streaming"
        case "gaming":    return "Gaming"
        case "vpn":       return "VPN / Remote"
        case "browsing":  return "Browsing"
        default:          return activity
        }
    }

    private static func iconFor(_ activity: String) -> String {
        switch activity {
        case "calls":     return "video"
        case "streaming": return "play.rectangle"
        case "gaming":    return "gamecontroller"
        case "vpn":       return "shield"
        case "browsing":  return "globe"
        default:          return "circle.dashed"
        }
    }

    private static func tintFor(verdict: RunSnapshot.SuitabilityRow.Verdict) -> Color {
        switch verdict {
        case .broken:    return Theme.ColorToken.red
        case .degraded:  return Theme.ColorToken.amber
        case .good:      return Theme.ColorToken.green
        case .unknown,
             .unmeasured: return Theme.ColorToken.muted
        }
    }

    private static func fallbackLabelFor(_ verdict: RunSnapshot.SuitabilityRow.Verdict) -> String {
        switch verdict {
        case .broken:    return "Broken"
        case .degraded:  return "Degraded"
        case .good:      return "Good"
        case .unknown,
             .unmeasured: return "Not measured"
        }
    }

    /// The one sentence behind the level — the CLI's row in words: what a
    /// reader should expect the activity to do at this verdict.
    private static func consequenceFor(_ activity: String, verdict: RunSnapshot.SuitabilityRow.Verdict) -> String {
        switch (activity, verdict) {
        case ("calls", .good):       return "Clear audio for voice calls"
        case ("calls", .degraded):   return "Robotic audio & dropouts"
        case ("calls", .broken):     return "Frequent call disconnections"
        case ("streaming", .good):   return "Smooth 1080p Full HD"
        case ("streaming", .degraded): return "Occasional buffering or 720p"
        case ("streaming", .broken): return "Frequent video buffering"
        case ("gaming", .good):      return "Ultra-low ping, zero desync"
        case ("gaming", .degraded):  return "Player desync & rollbacks"
        case ("gaming", .broken):    return "Constant rubberbanding"
        case ("vpn", .good):         return "Clean route & single NAT"
        case ("vpn", .degraded):     return "Tunnel rekeys or MTU choke"
        case ("vpn", .broken):       return "VPN tunnels fail to connect"
        case ("browsing", .good):    return "Fast DNS & page loads"
        case ("browsing", .degraded): return "Retransmissions delay web loads"
        case ("browsing", .broken):  return "Websites fail to load"
        case (_, .unknown), (_, .unmeasured):
            return "Assessing…"
        default:
            return ""
        }
    }
}

