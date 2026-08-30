import Foundation

/// One line of history: a condition that came and went, not a transition.
///
/// ── The problem this fixes ─────────────────────────────────────────────
/// `EventStore` records what the CLI's monitor reports, which is one entry
/// per *transition* — a `rule-fired` when a rule enters the sample's rule
/// set, a `rule-cleared` when it leaves. That is the right thing to store
/// and the wrong thing to show. On a link that flaps, twelve days produced
/// 329 rows of which 61 said "Severe internet packet loss" and 53 said
/// "Resolved: Severe internet packet loss" — a screen that scrolls forever
/// and answers nothing, because the two facts a reader actually wants are
/// the two the transition log throws away: *how long* it lasted, and *how
/// often* it has happened.
///
/// So a fired and its matching cleared are folded into one episode with a
/// duration, and same-rule episodes on the same day are folded into one
/// row with a count. Six rows saying "Minor packet loss to router" become
/// one row saying it happened six times today for four minutes in total.
///
/// ── Precedent ──────────────────────────────────────────────────────────
/// This is deliberately the same shape `helpers/events.py` already gives
/// `netdiag --events`, which pairs journal transitions into episodes by
/// (network, rule id). Three of its honest cases are reproduced here
/// because they are properties of transition logs, not of that file:
/// an episode still open at the end of the log, a second `fired` arriving
/// while one is already open (the monitor restarted and lost its previous
/// sample, so the gap was never observed), and an orphan `cleared` with no
/// `fired` before it.
///
/// ── What this does not do ──────────────────────────────────────────────
/// It judges nothing. There is no threshold here and no verdict about
/// whether four minutes of packet loss is acceptable — that is
/// `lib/diagnosis.sh`'s to say against `lib/thresholds.sh`, exactly as
/// `helpers/events.py`'s header records for the same reason. `summary`
/// stays the CLI's own words, copied and never composed.
struct ActivityEntry: Identifiable, Equatable {
    var id: String
    /// Representative event kind, for icon selection.
    var kind: String
    /// The CLI's own words for what happened, verbatim.
    var summary: String
    /// The rule this describes, when it describes one. Drives severity
    /// colour via the CLI's rules catalog.
    var ruleID: String?
    /// Newest occurrence — what the row is dated by and sorted on.
    var latest: Date
    /// Oldest occurrence in the group.
    var earliest: Date
    /// How many times this happened in the group's day.
    var occurrences: Int
    /// Total observed time the condition held, summed across occurrences.
    /// `nil` when nothing in the group ever paired into a closed episode —
    /// an instantaneous event, or one still open.
    var totalDuration: TimeInterval?
    /// At least one episode in the group was never seen to end.
    var isOngoing: Bool
    /// At least one duration in the group is a floor rather than a
    /// measurement, because the monitor restarted while the rule was
    /// firing and the gap went unobserved.
    var durationIsLowerBound: Bool
}

extension ActivityEntry {

    /// One closed-or-open span of a single rule.
    private struct Episode {
        var ruleID: String
        var kind: String
        var summary: String
        var start: Date
        var end: Date?
        var isLowerBound: Bool
    }

    /// Fold a transition log into episodes, then group same-rule episodes
    /// per calendar day.
    ///
    /// `events` arrives newest-first (`EventStore`'s invariant) and is
    /// walked oldest-first, because pairing is only meaningful forwards.
    /// Pure — no clock, no environment — so `--verify` can drive it with
    /// constructed input.
    static func fold(_ events: [NetworkEvent],
                     calendar: Calendar = .current) -> [ActivityEntry] {
        let chronological = events.sorted { $0.date < $1.date }

        var episodes: [Episode] = []
        var open: [String: Episode] = [:]
        var loose: [NetworkEvent] = []

        for event in chronological {
            guard let ruleID = event.ruleID,
                  event.kind == "rule-fired" || event.kind == "rule-cleared" else {
                // Alerts, VPN drops, interface changes, IP changes: discrete
                // facts with no duration. Grouped below, never paired.
                loose.append(event)
                continue
            }

            switch event.kind {
            case "rule-fired":
                if var existing = open[ruleID] {
                    // A second `fired` with no `cleared` between. The monitor
                    // only emits on transition, so this means it restarted
                    // and lost its previous sample — the span in between was
                    // not observed and must not be reported as though it
                    // were. Close the old episode where it was last seen and
                    // mark the duration a floor, as `helpers/events.py` does.
                    existing.end = existing.end ?? existing.start
                    existing.isLowerBound = true
                    episodes.append(existing)
                }
                open[ruleID] = Episode(ruleID: ruleID, kind: event.kind,
                                       summary: event.summary, start: event.date,
                                       end: nil, isLowerBound: false)
            case "rule-cleared":
                if var existing = open.removeValue(forKey: ruleID) {
                    existing.end = event.date
                    episodes.append(existing)
                }
                // An orphan `cleared` — the `fired` predates the store's
                // 500-entry cap, or the app was installed mid-fault. It
                // describes an end with no beginning, so there is no
                // duration to state and nothing to show.
            default:
                break
            }
        }
        // Whatever is still firing.
        for episode in open.values { episodes.append(episode) }

        return group(episodes: episodes, loose: loose, calendar: calendar)
    }

    private static func group(episodes: [Episode], loose: [NetworkEvent],
                              calendar: Calendar) -> [ActivityEntry] {
        var entries: [String: ActivityEntry] = [:]

        func merge(_ key: String, _ candidate: ActivityEntry) {
            guard var existing = entries[key] else {
                entries[key] = candidate
                return
            }
            existing.occurrences += candidate.occurrences
            existing.latest = max(existing.latest, candidate.latest)
            existing.earliest = min(existing.earliest, candidate.earliest)
            existing.isOngoing = existing.isOngoing || candidate.isOngoing
            existing.durationIsLowerBound =
                existing.durationIsLowerBound || candidate.durationIsLowerBound
            // nil + nil stays nil, so a day of never-paired events reports
            // no duration rather than a misleading zero.
            if let extra = candidate.totalDuration {
                existing.totalDuration = (existing.totalDuration ?? 0) + extra
            }
            entries[key] = existing
        }

        for episode in episodes {
            let day = calendar.startOfDay(for: episode.start)
            let key = "rule|\(episode.ruleID)|\(day.timeIntervalSince1970)"
            let duration = episode.end.map { $0.timeIntervalSince(episode.start) }
            merge(key, ActivityEntry(
                id: key, kind: "rule-fired", summary: episode.summary,
                ruleID: episode.ruleID,
                latest: episode.end ?? episode.start, earliest: episode.start,
                occurrences: 1,
                // A sub-second pair is a sampling artefact, not a duration
                // worth printing; it still counts as an occurrence.
                totalDuration: (duration ?? 0) >= 1 ? duration : nil,
                isOngoing: episode.end == nil,
                durationIsLowerBound: episode.isLowerBound))
        }

        for event in loose {
            let day = calendar.startOfDay(for: event.date)
            let key = "event|\(event.kind)|\(event.summary)|\(day.timeIntervalSince1970)"
            merge(key, ActivityEntry(
                id: key, kind: event.kind, summary: event.summary,
                ruleID: event.ruleID, latest: event.date, earliest: event.date,
                occurrences: 1, totalDuration: nil, isOngoing: false,
                durationIsLowerBound: false))
        }

        return entries.values.sorted { $0.latest > $1.latest }
    }
}

extension ActivityEntry {
    /// The row's second line: how often, and for how long. Counts and
    /// durations only — arithmetic over timestamps, never a verdict about
    /// whether the number is good (see this file's header).
    /// `nil` when there is nothing to add beyond the summary itself.
    ///
    /// Deliberately silent about `isOngoing`. An earlier draft appended
    /// "still active" whenever an episode had no recorded end, which put
    /// that phrase on three rows at once — including one two days old —
    /// because the common reason a `fired` never pairs is that the monitor
    /// stopped (app quit, Mac slept), not that the fault is still running.
    /// Whether something is happening *now* is the "Active now" section's
    /// claim, made from live alert state; history describes the past, and
    /// an unpaired episode means the end was never observed, which is not
    /// evidence that there was none. The `+` on a duration carries the
    /// only honest part of it: this is a floor, not a measurement.
    var detail: String? {
        var parts: [String] = []
        if occurrences > 1 { parts.append("\(occurrences) times") }
        if let total = totalDuration, total >= 1 {
            let formatted = Self.duration(total) + (durationIsLowerBound ? "+" : "")
            parts.append(occurrences > 1 ? "\(formatted) total" : "lasted \(formatted)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Compact duration: "45s", "4m", "1h 12m". Never zero-padded, never
    /// more than two units — this is a scannable list, not a stopwatch.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        if minutes < 60 {
            let remainder = total % 60
            return remainder == 0 ? "\(minutes)m" : "\(minutes)m \(remainder)s"
        }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
    }
}
