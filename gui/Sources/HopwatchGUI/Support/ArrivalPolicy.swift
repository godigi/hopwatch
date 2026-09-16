import Foundation

/// What depth to check a newly-joined network at, and whether to decide
/// at all yet.
///
/// The bug this exists to fix: `FullCheckPolicy.isSafe` is an allow-list
/// over the CLI's severity vocabulary, and it is right to refuse an
/// unrecognised value. But the coordinator asked it at the exact moment a
/// network was joined — when the monitor has produced no sample and
/// severity is the empty string — so the honest "I do not understand this"
/// became a silent downgrade on essentially every arrival. The user's
/// report was that a brand-new network showed no full check at all; this
/// is half of why.
///
/// The fix is the third case. `.wait` is not a decision, it is the absence
/// of one: the caller leaves the state `.unchecked`, does not advance its
/// backoff, and asks again on the next sample.
///
/// Pure, for the same reason as `FullCheckPolicy` and `StageResolver`:
/// `VerifyMode` is the only runnable harness on this toolchain and cannot
/// construct a coordinator.
///
/// This is not a threshold. It reads severity as an opaque string against
/// `FullCheckPolicy`'s existing allow-list and reads two booleans the OS
/// hands it. It never decides what makes a network bad — that stays in
/// `lib/thresholds.sh`, per CLAUDE.md.
enum ArrivalPolicy {

    enum Decision: Equatable, Sendable {
        /// Run the full battery: bufferbloat, speed, path MTU, per-hop loss.
        case full
        /// Run the quick check instead, for a reason the card will show
        /// alongside a button offering the full one anyway.
        case quick(DeclineReason)
        /// Not enough is known yet. Ask again next sample.
        case wait
    }

    /// - Parameters:
    ///   - hasSample: whether the monitor has produced at least one sample
    ///     for this network. Until it has, `severity` is meaningless and
    ///     the honest answer is `.wait`.
    ///   - severity: the CLI's `status.severity` from that sample.
    ///   - isExpensive: `NWPath.isExpensive` — cellular, including a
    ///     personal hotspot.
    ///   - isConstrained: `NWPath.isConstrained` — Low Data Mode.
    static func decide(hasSample: Bool, severity: String,
                       isExpensive: Bool, isConstrained: Bool) -> Decision {
        guard hasSample else { return .wait }

        // Cost before health, deliberately. Both downgrade to the quick
        // check, so the only thing the order changes is which reason the
        // user is shown — and the one they can act on is the one about
        // their data allowance.
        if isExpensive || isConstrained { return .quick(.hotspot) }

        // Reuses the existing allow-list rather than restating it, so the
        // button a user presses and the check that runs itself can never
        // disagree about what "safe" means.
        guard FullCheckPolicy.isSafe(severity: severity) else {
            return .quick(.unhealthy)
        }
        return .full
    }
}
