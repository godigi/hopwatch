import SwiftUI

/// What the arrival card says, as plain values.
///
/// Split from the view for the same reason `FullCheckPolicy.controlLabel`
/// is: `VerifyMode` is the only runnable harness on this toolchain, and it
/// can assert on a struct where it cannot assert on a `View`. The copy
/// check that matters is the negative one — no verdict words — and it can
/// only run against something testable.
///
/// Mechanism only. Every string says what netdiag is doing and what it
/// costs. None says whether the network is any good; that is
/// `lib/diagnosis.sh`'s job and it reaches the UI through
/// `diagnosis[].summary` verbatim. See AlertDefinitions.swift's header.
struct ArrivalCopy {
    let title: String
    let body: String
    /// nil when there is nothing for the user to do but wait.
    var actionTitle: String?

    /// nil means "render no card" — the network has been checked and the
    /// report below speaks for itself.
    static func forState(_ state: ArrivalState, network: String?) -> ArrivalCopy? {
        let name = network ?? "this network"
        switch state {
        case .checked:
            return nil

        case .unchecked:
            return ArrivalCopy(
                title: "New network: \(name)",
                body: "netdiag hasn't measured this one yet. Starting a check.")

        case .checking(let depth, _):
            let what = depth == .full
                ? "Running a full check — speed, latency under load, path MTU and per-hop loss."
                : "Running a quick check."
            return ArrivalCopy(title: "New network: \(name)", body: what)

        case .declined(_, let reason, _):
            switch reason {
            case .hotspot:
                return ArrivalCopy(
                    title: "New network: \(name)",
                    body: """
                        This looks like a personal hotspot, so netdiag ran the quick check \
                        instead of the full one — a full check runs a speed test, which can \
                        spend a few hundred megabytes of cellular data.
                        """,
                    actionTitle: "Run full check anyway")
            case .unhealthy:
                // Deliberately not `FullCheckPolicy.controlHelp(isSafe:
                // false)`, though that string covers the same policy. Two
                // reasons. It is written in the future tense of a button
                // tooltip ("this runs a lighter check") and this card
                // reports something that already happened; and its opening
                // clause — "the last reading wasn't clearly healthy" —
                // carries a word this card's own harness rejects as a
                // verdict. That sentence is defended in FullCheckPolicy's
                // header and asserted in VerifyMode, so it stays where it
                // is; the arrival card states the same mechanism without
                // characterising the link.
                return ArrivalCopy(
                    title: "New network: \(name)",
                    body: """
                        netdiag ran the quick check instead of the full one — a full check \
                        saturates the link for about ten seconds to measure latency under \
                        load, and the last monitor reading was outside the range it treats \
                        as safe to add that traffic to.
                        """,
                    actionTitle: "Run full check anyway")
            }
        }
    }
}

/// The card at the top of Home whenever the current network has not been
/// checked. Renders `ArrivalCopy` and, while a check is in flight, the
/// existing scan progress rows.
struct ArrivalCard: View {
    let state: ArrivalState
    let network: String?
    let progress: ScanProgress?
    var onRunFullCheck: () -> Void

    var body: some View {
        if let copy = ArrivalCopy.forState(state, network: network) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack(spacing: Theme.Spacing.sm) {
                    switch state {
                    case .unchecked, .checking:
                        ProgressView().controlSize(.small)
                    default:
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                    Text(copy.title).font(.headline)
                }
                Text(copy.body)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .proseWidth(520)

                if case .checking = state, let progress {
                    ScanProgressView(progress: progress)
                }

                if let action = copy.actionTitle {
                    Button(action, action: onRunFullCheck)
                        .controlSize(.small)
                }
            }
            .padding(Theme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The same container every other card on Home and in the
            // dropdown uses, rather than a new one: `Theme.cardStyle()`
            // exists precisely so a new card cannot invent its own radius
            // and fill. See that modifier's header.
            .cardStyle()
        }
    }
}
