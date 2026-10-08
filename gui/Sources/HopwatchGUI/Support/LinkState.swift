import Foundation

/// "Does the newest monitor sample say there is no network?", as one
/// answer every surface shares.
///
/// Four things used to answer this separately and disagree: the menu-bar
/// dot (which asked whether the monitor *process* was alive first), the
/// stage card (which mapped it to the generic "Connection is unstable"),
/// the tiles (which kept drawing the last readings and a hard-coded
/// "Ethernet"), and the jitter/loss/stability figures (which fell back to
/// older samples and to the last scan). They now all read this.
///
/// The one judgement in here is *how long a "no link" sample stays
/// believable*. It is a fact about the observation, not about the network,
/// so it is not a diagnostic threshold: a link-down sample from the monitor
/// that has since died and not come back is not evidence about the link
/// now. The window has to outlast the monitor's longest restart backoff
/// (60 s, `MonitorStream.scheduleRestart`) or the dot would flick back to
/// amber between a crash and its replacement, which is exactly the flicker
/// this exists to remove.
enum LinkState {

    /// Floor for how old the newest sample may be and still count.
    static let minimumFreshness: TimeInterval = 120

    /// A sample's freshness window: never less than the floor, and never
    /// less than four of the monitor's own cadences (a slow configured
    /// cadence must not make every sample "stale" before the next arrives).
    static func freshness(cadenceS: Int?) -> TimeInterval {
        max(minimumFreshness, Double(cadenceS ?? 0) * 4)
    }

    /// `linkUp` and `sampleAge` come straight off the newest sample.
    /// `linkUp == nil` (no sample yet) is "don't know", never "down".
    static func isDown(linkUp: Bool?, sampleAge: TimeInterval?, cadenceS: Int? = nil) -> Bool {
        guard linkUp == false else { return false }
        guard let sampleAge else { return true }
        return sampleAge <= freshness(cadenceS: cadenceS)
    }

    static func isDown(sample: MonitorSample?, now: Date = Date()) -> Bool {
        guard let sample else { return false }
        return isDown(linkUp: sample.link.up,
                      sampleAge: now.timeIntervalSince(sample.timestamp),
                      cadenceS: sample.status.cadenceS)
    }
}

/// What the live tiles say when there is no link. State-of-the-app facts
/// ("there is no link"), not verdicts about a cause: the explanation of
/// *why* is the CLI's N1 prose, which the hero shows.
enum NoLinkCopy {
    /// Stage headline, Dropdown and Home.
    static let headline = "No network connection"
    /// Used only when the CLI's own N1 text is unavailable.
    static let fallbackSubtitle = "Your Mac has no network connection at all."
    /// A reading slot with nothing to read.
    static let unknownValue = "—"
    /// The caption under the router and internet nodes.
    static let nodeDetail = "No link"
    /// The caption under the Mac node.
    static let macDetail = "Not connected"
    /// The Mac node's reading.
    static let linkReading = "No link"
    /// The glyph on the stage card and the Mac node. Neither Wi-Fi nor
    /// wired: the monitor reports no interface at all, and "wired" in a
    /// down sample is only the CLI's default.
    static let icon = "network.slash"
}
