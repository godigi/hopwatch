import Foundation

/// Why a full check was not run on arrival.
///
/// Mechanism, never verdict: each case says what netdiag observed about
/// the *link* and what that costs, and nothing about whether the network
/// is any good. See AlertDefinitions.swift's header for the contract.
enum DeclineReason: String, Codable, Sendable, Equatable {
    /// `NWPath.isExpensive` or `.isConstrained` — a personal hotspot, or
    /// Low Data Mode. A full check runs a speed test, and on cellular that
    /// spends the user's data allowance without asking.
    case hotspot
    /// The CLI's severity was outside the set `FullCheckPolicy` recognises
    /// as safe. A full check saturates the link for ~10 s, which on a
    /// connection already struggling makes the user's situation worse.
    case unhealthy
}

/// What has happened, so far, about checking the network you are on.
///
/// This replaces `Defaults.seenNetworks`, a `Set<String>` that could only
/// express "checked" and had no way to say "tried and was declined". The
/// coordinator advanced its `lastNetworkID` guard *before* attempting the
/// arrival scan, so a scan declined for being busy left the network absent
/// from the set with no path back: the retry the code's comment promised
/// required leaving the network and rejoining it. A live install had
/// "SB Airbnb" named in `networkNames` and missing from `seenNetworks`,
/// which is only reachable that way.
///
/// Modelled as a state rather than a flag because the UI renders it —
/// `unchecked` is a spinner, `declined` is a button, `checked` is nothing
/// at all. A flag cannot carry that.
enum ArrivalState: Codable, Sendable, Equatable {
    /// Seen, never successfully checked. Wants an attempt.
    case unchecked
    /// An attempt is in flight.
    case checking(depth: ArrivalDepth, startedAt: Date)
    /// Done. The `runID` is nil for a migrated entry, where the run
    /// predates this feature and cannot be named.
    case checked(depth: ArrivalDepth, at: Date, runID: String?)
    /// Deliberately not run at full depth. A decision, not a failure — it
    /// does not retry, and the card offers the user the override.
    case declined(depth: ArrivalDepth, reason: DeclineReason, at: Date)

    /// How long a `.checking` state may sit before it is assumed dead.
    ///
    /// Three times the slowest depth's real-world duration (~115 s with
    /// speedtest-cli, per CLAUDE.md). Not a threshold in the
    /// lib/thresholds.sh sense — it judges nothing about the network, only
    /// how long this app's own child process is allowed to be silent
    /// before we stop waiting for it.
    static let stallWindow: TimeInterval = 345

    /// Whether the coordinator should try to check this network now.
    func needsAttempt(now: Date) -> Bool {
        switch self {
        case .unchecked:
            return true
        case .checking(_, let startedAt):
            return now.timeIntervalSince(startedAt) > Self.stallWindow
        case .checked, .declined:
            return false
        }
    }

    var debugLabel: String {
        switch self {
        case .unchecked:                 return "unchecked"
        case .checking(let d, _):        return "checking(\(d.rawValue))"
        case .checked(let d, _, _):      return "checked(\(d.rawValue))"
        case .declined(let d, let r, _): return "declined(\(d.rawValue), \(r.rawValue))"
        }
    }

    // MARK: - Codable
    //
    // Hand-rolled rather than synthesised, for one reason: a value written
    // by a newer build must decode to `.unchecked` rather than throwing.
    // The synthesised enum coding would fail the whole dictionary read, so
    // one unknown network would wipe every network's state.

    private enum CodingKeys: String, CodingKey {
        case kind, depth, at, reason, runID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        let depth = (try? c.decodeIfPresent(ArrivalDepth.self, forKey: .depth)) ?? nil
        let at = (try? c.decodeIfPresent(Date.self, forKey: .at)) ?? nil

        switch kind {
        case "checking":
            guard let depth, let at else { self = .unchecked; return }
            self = .checking(depth: depth, startedAt: at)
        case "checked":
            guard let depth, let at else { self = .unchecked; return }
            self = .checked(depth: depth, at: at,
                            runID: try? c.decodeIfPresent(String.self, forKey: .runID))
        case "declined":
            let reason = (try? c.decodeIfPresent(DeclineReason.self, forKey: .reason)) ?? nil
            guard let depth, let at, let reason else { self = .unchecked; return }
            self = .declined(depth: depth, reason: reason, at: at)
        default:
            // "unchecked", and anything a newer build invents. Never
            // `.checked`: we cannot clear a verdict we do not understand.
            self = .unchecked
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .unchecked:
            try c.encode("unchecked", forKey: .kind)
        case .checking(let depth, let startedAt):
            try c.encode("checking", forKey: .kind)
            try c.encode(depth, forKey: .depth)
            try c.encode(startedAt, forKey: .at)
        case .checked(let depth, let at, let runID):
            try c.encode("checked", forKey: .kind)
            try c.encode(depth, forKey: .depth)
            try c.encode(at, forKey: .at)
            try c.encodeIfPresent(runID, forKey: .runID)
        case .declined(let depth, let reason, let at):
            try c.encode("declined", forKey: .kind)
            try c.encode(depth, forKey: .depth)
            try c.encode(reason, forKey: .reason)
            try c.encode(at, forKey: .at)
        }
    }
}

/// The depth an arrival attempt used.
///
/// A separate, persistable mirror of `NetdiagRunner.Depth` rather than that
/// type itself: `Depth` is a runner concern that may gain cases, and this
/// one is written to disk, where a case's spelling is a compatibility
/// commitment.
enum ArrivalDepth: String, Codable, Sendable, Equatable {
    case full
    case quick

    var runnerDepth: NetdiagRunner.Depth {
        switch self {
        case .full:  return .full
        case .quick: return .quick
        }
    }
}
