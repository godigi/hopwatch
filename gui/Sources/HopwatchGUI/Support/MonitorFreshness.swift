import Foundation

/// The gate every live cell has to clear before it may show a number.
///
/// Phase 4 of the reporting-accuracy plan: "every live cell blanks when
/// the sample's latest is older than 2× cadence, paused, or scanning —
/// not just the two ping cells." Before this, only the two ping cells in
/// the dropdown checked paused/scanning; a Wi-Fi reading or a jitter
/// figure the monitor had stopped refreshing kept its last value on
/// screen without the "—" those ping cells learned to show. Stale numbers
/// that look live are worse than blanks.
///
/// Two granularities, because the stream has two:
///
///  * *Sample-level* (`samplePresentable`): the whole sample is dated
///    against the configured fast cadence. A sample older than twice that
///    cadence means at least one cycle went missing, so nothing in it can
///    answer "how is the link right now". A `gap_s` past the same bound
///    is the stream's own side of the same fact — two samples eight hours
///    apart, both claiming a healthy link. Either witness alone blanks.
///  * *Tier-level* (`tierPresentable`): medium (60 s) and slow (300 s)
///    readings are carried over between refreshes, and the sample's
///    emitted `age_s` (Phase 1, helpers/monitor_sample.py) says how far
///    back each came from. Past twice the tier's own interval, the
///    carried-over figure describes the recent past, not now. An absent
///    age fails *open*: the CLI owns the tier nulling (`MEDIUM_FRESH`),
///    and an old stream that never emitted `age_s` is not evidence of a
///    stale value — the sample-level gate still covers it.
///
/// Pure and clock-absent where it can be: `now` is a parameter so the
/// verify harness and the test target can drive both gates with
/// constructed input.
enum MonitorFreshness {

    /// How far past its own cadence a reading may stand before it stops
    /// being presentable, in interval units.
    static let stalenessFactor = 2

    /// Whether the sample's readings may be presented at all.
    static func samplePresentable(ts: String?,
                                  gapS: Int?,
                                  cadenceS: Int?,
                                  paused: Bool,
                                  scanning: Bool,
                                  fallbackCadenceS: Int,
                                  now: Date = .now) -> Bool {
        guard !paused, !scanning else { return false }
        guard let ts else { return false }
        guard let sampledAt = FastISO8601.parse(ts) else { return false }
        let cadence = TimeInterval(cadenceS ?? fallbackCadenceS)
        let maximum = cadence * Double(stalenessFactor)
        if now.timeIntervalSince(sampledAt) > maximum { return false }
        if let gapS, TimeInterval(gapS) > maximum { return false }
        return true
    }

    /// Whether one tier's carried-over reading may still be presented.
    static func tierPresentable(ageS: Int?, intervalS: Int) -> Bool {
        guard let ageS else { return true }
        return TimeInterval(ageS) <= TimeInterval(intervalS) * Double(stalenessFactor)
    }
}
