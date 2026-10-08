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

/// "Has the monitor stopped reporting?", as one answer every surface shares.
///
/// `LinkState` believes a sample *about a down link* for a long time because
/// that is the app's loudest fact. This is the opposite question: a hung
/// `ipconfig`, `arp` or `route` inside the monitor freezes its output
/// without killing the process, so `isRunning` stays true, `latest` keeps
/// its last (green) sample, and the dot stays green forever. A sample older
/// than a few of the monitor's own cadences is not a reading of the network
/// now, whatever it says.
///
/// The window is a fact about the observation, not a verdict about the
/// network, so it is named in `Defaults` rather than in `lib/thresholds.sh`.
enum SampleFreshness {

    /// How old the newest sample may be before it stops counting as live.
    static func window(cadenceS: Int?) -> TimeInterval {
        Double(cadenceS ?? Defaults.assumedMonitorCadenceS)
            * Double(Defaults.staleSampleMissedCadences)
            + Defaults.staleSampleMargin
    }

    /// - Parameters:
    ///   - sampleAge: Age of the newest sample, counted from the later of
    ///     its own timestamp and the moment the monitor last (re)started
    ///     observing (`MonitorStream.awaitingSince`) — a monitor that has
    ///     only just resumed has not had time to be late. `nil` with no
    ///     sample: nothing to be stale, that is "not measured yet".
    ///   - observing: Monitoring is on and not held by any pause. Off and
    ///     paused have their own states, and a paused monitor is *supposed*
    ///     to stop reporting.
    ///   - samplePaused: The sample itself says it is a paused one.
    static func isStale(sampleAge: TimeInterval?, cadenceS: Int?,
                        observing: Bool, samplePaused: Bool = false) -> Bool {
        guard observing, !samplePaused, let sampleAge else { return false }
        return sampleAge > window(cadenceS: cadenceS)
    }
}

/// What the cards say when the monitor has stopped reporting. State-of-the-
/// app facts, like `NoLinkCopy`: nothing here says what is wrong with the
/// network.
enum StaleSampleCopy {
    static let headline = "Monitor is not reporting"
    /// A reading slot with nothing believable to read.
    static let unknownValue = "—"
    static let subtitle = "Hopwatch has not received a reading from the connection monitor for a while, so it cannot say how your network is doing right now."
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
