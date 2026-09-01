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
    /// An alert for this rule fired on this day, i.e. the user was actually
    /// notified. Folded in from the alert's own event rather than left as a
    /// separate row — see `absorbAlerts`.
    var notified: Bool = false
}

extension ActivityEntry {

    /// One closed-or-open span of a single rule.
    private struct Episode {
        var ruleID: String
        var kind: String
        var summary: String
        var start: Date
        /// When the rule was *observed to stop*. `nil` while it is still
        /// firing as far as the log knows.
        var end: Date?
        /// The newest moment the rule is known to have still been firing.
        /// Distinct from `end`, which is an ending; this is a sighting.
        ///
        /// `helpers/events.py` needs the same distinction and gets it from
        /// the journal's own last row (`close(key, last_at, "still-open")`),
        /// so an episode there can be `ongoing: true` and carry a
        /// `duration_s` at once. Nothing in `EventStore` marks the end of
        /// the log, so the sighting is tracked per episode instead.
        var lastSeen: Date
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
                if open[ruleID] != nil {
                    // A second `fired` with no `cleared` between. The monitor
                    // only emits on transition, so this means it restarted
                    // and lost its previous sample — the span in between was
                    // not observed and must not be reported as though it
                    // were continuous.
                    //
                    // Keep the *earlier* start, exactly as `helpers/events.py`
                    // does (`episodes()` skips the second `rule-fired`): it is
                    // the earliest moment the fault is known to have been
                    // true, and the rule was still firing now, so the span
                    // between the two is evidence, not invention. Only its
                    // continuity is unobserved — hence the floor.
                    //
                    // The previous code closed the open episode at
                    // `existing.end ?? existing.start`, and `end` is nil for
                    // everything in `open` by construction. That made every
                    // such episode zero-length, so the duration fell under the
                    // one-second floor below, `totalDuration` came out nil,
                    // and `isLowerBound` ended up qualifying a duration that
                    // no longer existed: an hour-long fault rendered as a bare
                    // occurrence with no duration and no `+`.
                    open[ruleID]?.lastSeen = event.date
                    open[ruleID]?.isLowerBound = true
                    continue
                }
                open[ruleID] = Episode(ruleID: ruleID, kind: event.kind,
                                       summary: event.summary, start: event.date,
                                       end: nil, lastSeen: event.date,
                                       isLowerBound: false)
            case "rule-cleared":
                if var existing = open.removeValue(forKey: ruleID) {
                    existing.end = event.date
                    episodes.append(existing)
                } else {
                    // An orphan `cleared`: the `fired` predates the store's
                    // 500-entry cap, or the app was installed mid-fault, or
                    // — much more often — it simply predates the slice being
                    // folded. `DropdownView` folds a rolling
                    // `eventLog.within(hours: 24)`, so any fault that began
                    // more than a day ago and ended today arrives here with
                    // its beginning already outside the window.
                    //
                    // This used to contribute no row at all, which made a
                    // long fault that had just been resolved disappear from
                    // the panel — the one thing someone opening the menu bar
                    // most wants to see, and something the older `EventRow`
                    // timeline did render, as "Resolved: …".
                    //
                    // An end with no beginning is still an end. It becomes a
                    // zero-length episode: the one-second floor in `group`
                    // then leaves `totalDuration` nil, so the row states the
                    // resolution and invents no duration for it.
                    episodes.append(Episode(
                        ruleID: ruleID, kind: event.kind,
                        summary: event.summary, start: event.date,
                        end: event.date, lastSeen: event.date,
                        isLowerBound: false))
                }
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
            // A day on which the rule was actually seen to fire reads as the
            // fault, not as its resolution. Without this, a group holding
            // both an orphan `cleared` and a real episode would take its
            // words and its icon from whichever happened to merge first.
            if existing.kind == "rule-cleared" && candidate.kind != "rule-cleared" {
                existing.kind = candidate.kind
                existing.summary = candidate.summary
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
            // Keyed on the day the episode *began*. `byDay` sections on the
            // same field via `earliest`; if one of the two ever moves, the
            // other has to move with it or a row can be filed under a day
            // its key does not name.
            let day = calendar.startOfDay(for: episode.start)
            let key = "rule|\(episode.ruleID)|\(day.timeIntervalSince1970)"
            // Measured to the observed end where there is one, and otherwise
            // to the last sighting — which for an episode nothing has
            // re-observed is its own start, so an ordinary open episode still
            // states no duration. Only a fire-on-fire moves `lastSeen`, and
            // that span is a floor (`Episode.lastSeen`).
            let seen = episode.end ?? episode.lastSeen
            let duration = seen.timeIntervalSince(episode.start)
            merge(key, ActivityEntry(
                // The episode's own kind, which is "rule-fired" for every
                // episode that was seen to start and "rule-cleared" for an
                // orphan resolution — so the latter keeps the green check
                // its text ("Resolved: …") is asking for.
                id: key, kind: episode.kind, summary: episode.summary,
                ruleID: episode.ruleID,
                latest: seen, earliest: episode.start,
                occurrences: 1,
                // A sub-second pair is a sampling artefact, not a duration
                // worth printing; it still counts as an occurrence.
                totalDuration: duration >= 1 ? duration : nil,
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

        return absorbAlerts(entries).values.sorted { $0.latest > $1.latest }
    }

    /// Fold each alert row into the rule row it is about.
    ///
    /// `AlertEngine` firing writes an `alert` event alongside the
    /// `rule-fired` the CLI already reported, so one incident produced two
    /// rows saying the same thing in different words — "Moderate internet
    /// packet loss" (rule `L2`) and "Internet connection degraded" (the
    /// alert `L2` raised). The dropdown's teaser already drops that echo;
    /// Activity listed both.
    ///
    /// Dropping the alert row outright would lose the one thing it knows
    /// that the rule row does not: that the user was *notified*. So the
    /// alert is absorbed as a flag on the rule's own row instead of
    /// deleted. An alert carrying no rule — "Your public IP address
    /// changed", captive portal, VPN dropped, which are raised from monitor
    /// events rather than rules — has no row to merge into and keeps its
    /// own, which is correct: nothing else is reporting it.
    private static func absorbAlerts(
        _ entries: [String: ActivityEntry]) -> [String: ActivityEntry] {
        var result = entries
        for (key, entry) in entries where entry.kind == "alert" {
            guard let ruleID = entry.ruleID else { continue }
            let day = key.split(separator: "|").last.map(String.init) ?? ""
            let ruleKey = "rule|\(ruleID)|\(day)"
            guard var target = result[ruleKey] else { continue }
            target.notified = true
            // The alert lands after the rule's dwell, so it can be the
            // newest thing in the group; keep the row dated by it.
            target.latest = max(target.latest, entry.latest)
            result[ruleKey] = target
            result.removeValue(forKey: key)
        }
        return result
    }
}

extension ActivityEntry {

    /// Rows bucketed into calendar-day sections, newest day first.
    ///
    /// Lives beside `group`, which builds the per-day key these sections
    /// have to agree with, because they are one decision made twice — and
    /// they drifted. `group` keys on the episode's `start`; this bucketed
    /// on its `latest`. A rule that fired 23:50 Monday and cleared 00:10
    /// Tuesday, then fired and cleared again at 09:00 Tuesday, therefore
    /// produced two entries (`rule|G3|Monday`, `rule|G3|Tuesday`) that both
    /// landed in Tuesday's section, printing the same sentence twice and
    /// breaking the one-row-per-rule-per-day promise in this type's header.
    ///
    /// `earliest` is the field both now use, i.e. an episode belongs to the
    /// day it *began*. Three reasons, in order of weight:
    ///
    ///  * `helpers/events.py` — the reference for this fold — identifies an
    ///    episode by its start, sorting `episodes()` on `started`.
    ///  * `earliest` reproduces `group`'s key exactly. Every episode merged
    ///    under one key has the same `startOfDay(start)`, and `merge` takes
    ///    the `min`, so `startOfDay(earliest)` is that day by construction.
    ///    `latest` has no such guarantee: `merge` and `absorbAlerts` both
    ///    move it, so a key built from it would change as rows accumulate.
    ///  * A fault that ran through midnight is one thing that happened on
    ///    Monday night, and Monday night is where someone goes looking.
    static func byDay(_ entries: [ActivityEntry],
                      calendar: Calendar = .current)
        -> [(day: Date, entries: [ActivityEntry])] {
        var buckets: [Date: [ActivityEntry]] = [:]
        for entry in entries {
            buckets[calendar.startOfDay(for: entry.earliest), default: []]
                .append(entry)
        }
        // Sorted, not taken in encounter order. `fold` returns rows newest
        // `latest` first, which only implied day order while the bucket was
        // `latest` too: a Monday-night fault still running Tuesday lunchtime
        // outranks a Tuesday-morning one and would print Monday's section
        // above Tuesday's.
        return buckets.keys.sorted(by: >).map { ($0, buckets[$0] ?? []) }
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
