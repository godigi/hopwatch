import Foundation

/// Where the one repair the user last pressed has got to.
///
/// A repair that reports nothing is not done (docs/design/
/// 2026-10-07-repair-actions-design.md), so this is what the app shows from
/// the moment the button is confirmed until the user dismisses it. It is
/// kept apart from the findings list on purpose: when a repair works, the
/// finding it was attached to is gone from the next scan, and an outcome
/// stored on the finding would vanish with it — taking "Fixed" with it.
///
/// Only the two status labels in `statusText` are written here. Every other
/// sentence the user reads (the button, the confirmation, what to try next,
/// what the repair did) comes from the CLI, verbatim.
struct RepairOutcome: Equatable, Identifiable, Sendable {
    enum Phase: Equatable, Sendable {
        /// `hopwatch --repair` is running.
        case working
        /// The repair worked; the quick depth is checking whether the
        /// finding is gone.
        case checking
        /// The re-check no longer shows the finding's rule.
        case fixed
        /// The re-check still shows it. `detail` is the repair's own
        /// `if_unfixed`.
        case didntHelp
        /// The repair ran and has an effect the user must finish (sign in)
        /// or that ends the session (restart). `detail` is the CLI's
        /// message; no verdict is claimed.
        case done
        /// The repair did not run or did not work. `detail` is the CLI's
        /// message, or the reason it was refused.
        case failed
    }

    var ruleID: String
    /// The button text the user pressed, so the outcome names the action.
    var label: String
    var phase: Phase
    var detail: String?

    var id: String { "\(ruleID)-\(label)" }

    var isInFlight: Bool { phase == .working || phase == .checking }

    /// The short status. UI chrome, not diagnosis: it states what the
    /// re-check found and nothing about why.
    var statusText: String {
        switch phase {
        case .working:    return "Working…"
        case .checking:   return "Checking whether that helped…"
        case .fixed:      return "Fixed"
        case .didntHelp:  return "That didn't help"
        case .done:       return "Done"
        case .failed:     return "That didn't work"
        }
    }
}
