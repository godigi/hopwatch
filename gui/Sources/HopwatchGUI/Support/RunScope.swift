import Foundation

/// "Is this stored or session run about the network I am on?", as one
/// answer.
///
/// CLAUDE.md rule 2: any Home surface reading history scopes to the current
/// network, or states its provenance. Before this, the answer was asked (or
/// not asked) separately by every fallback chain — `monitor ?? latestRun ??
/// hydratedReport` for the public IP, the flag and the ISP, the loss and RTT
/// a scan left behind, the speed test — and none of them asked, so a café
/// showed the previous network's flag, the home speed test and a "Good"
/// report from the living room.
///
/// The one decision in here is what to do when the answer is *unknown*, and
/// it is "show the run": the live network is unknown before the monitor's
/// first sample (a cold launch, or monitoring switched off), and a run with
/// no recorded network cannot be shown to be about another one. Refusing in
/// those cases would blank Home on every launch until the monitor spoke.
/// Hydration is already scoped to the live network when it has one
/// (`HopwatchCoordinator.hydrateFromHistoryIfNeeded`), and when it
/// deliberately is not (monitoring off), Home captions the report with its
/// network and date (`HomeView.lastCheckedCaption`).
enum RunScope {

    /// - Parameters:
    ///   - run: the run's own network id (`historyJoinID`), if it has one.
    ///   - live: the monitor's newest sample's, if it has one.
    ///   - canonical: the history store's `canonicalID`, which follows
    ///     manual merges — two ids the user has merged are one network.
    /// - Returns: `false` only when both ids are known and differ.
    static func isSameNetwork(run: String?, live: String?,
                              canonical: (String) -> String) -> Bool {
        guard let run, let live else { return true }
        return canonical(run) == canonical(live)
    }
}

/// The run a surface may show as being about the network the Mac is on,
/// with how old it is. Produced only by
/// `HopwatchCoordinator.currentNetworkRun`.
struct CurrentNetworkRun: Sendable {
    let result: RunResult
    /// From a scan this session, as opposed to one hydrated from history.
    let isLive: Bool
    var snapshot: RunSnapshot { result.snapshot }
    var finishedAt: Date { result.finishedAt }
    func age(now: Date = Date()) -> TimeInterval {
        max(0, now.timeIntervalSince(result.finishedAt))
    }
}
