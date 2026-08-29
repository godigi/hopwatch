import Foundation

/// The menu-bar dot's state, decided by a pure function.
///
/// Sibling of `StageResolver`, and extracted for the same reason: the dot
/// is the app's most-seen surface and its single most consequential claim
/// — one glyph asserting "your connection is fine" — and it used to be a
/// computed property on the coordinator, unreachable from any test.
///
/// The bug that motivated the extraction: `currentHealth` read
/// `monitor.latest` whenever monitoring was switched off, and
/// `MonitorStream.stop()` deliberately keeps its final sample. So pausing
/// monitoring left the last pre-pause reading on screen forever — a green
/// dot, indefinitely, over a dropdown card reading "Monitoring paused".
///
/// The precedence below deliberately mirrors `StageResolver.resolve`, so
/// the dot and the card it summarises cannot disagree about which state
/// the app is in. The one deliberate divergence is scanning: the card
/// swaps to `.testing`, but the dot holds its last known value rather than
/// greying out, because a scan lasts seconds and *is* a measurement — a
/// dot that blinked to "not watching" every time the app looked harder
/// would be both wrong and distracting.
///
/// Nothing here decides whether a number is bad: `Health` arrives already
/// computed from the CLI's own severity (`MonitorSample.health`,
/// `RunSnapshot.worstSeverity`). This only maps app state to which of
/// those to trust.
enum HealthResolver {

    struct Inputs: Sendable {
        let isScanning: Bool
        let monitoringEnabled: Bool
        let isPausedForAnyReason: Bool
        let monitorRunning: Bool
        /// `MonitorSample.health` for the newest sample, if any.
        let sampleHealth: Health?
        /// `RunSnapshot.worstSeverity` for the newest live run, if any.
        let runHealth: Health?

        init(isScanning: Bool, monitoringEnabled: Bool,
             isPausedForAnyReason: Bool, monitorRunning: Bool,
             sampleHealth: Health?, runHealth: Health?) {
            self.isScanning = isScanning
            self.monitoringEnabled = monitoringEnabled
            self.isPausedForAnyReason = isPausedForAnyReason
            self.monitorRunning = monitorRunning
            self.sampleHealth = sampleHealth
            self.runHealth = runHealth
        }
    }

    static func resolve(_ i: Inputs) -> Health {
        // A scan is the app looking harder, not looking away. Hold the last
        // reading rather than greying out for its duration.
        if i.isScanning { return i.sampleHealth ?? i.runHealth ?? .warning }
        // Switched off by the user, or held by display sleep / battery /
        // the pause signal. Either can last indefinitely, and while it does
        // the app has no current opinion to report.
        if !i.monitoringEnabled || i.isPausedForAnyReason { return .paused }
        // Supposed to be monitoring and isn't: a dead or unstartable
        // monitor child. `.warning`, never the stale sample it left behind
        // — that is exactly how a crashed monitor came to read as a quiet
        // network.
        if !i.monitorRunning { return .warning }
        if let sampleHealth = i.sampleHealth { return sampleHealth }
        if let runHealth = i.runHealth { return runHealth }
        return .warning
    }
}
