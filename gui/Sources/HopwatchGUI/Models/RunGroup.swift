import Foundation

/// A coalesced cluster of consecutive checks on the same network that share
/// the exact same health, severity, and fired rules within the same calendar day.
///
/// ── The problem this fixes ──────────────────────────────────────────────────
/// Background watchers run every 15 minutes, arrival checks run on reconnect,
/// and availability rules (like AV-1) span 24 hours. Without coalescing, a user
/// browsing past checks sees dozens of identical rows saying the exact same
/// thing within minutes of each other.
///
/// `RunGroup` folds consecutive identical runs together into a single summary
/// row (e.g. "1:44 AM – 1:47 AM · 14 identical checks"), while keeping each
/// underlying `Run` accessible when expanded. Single runs remain single rows.
struct RunGroup: Identifiable, Sendable {
    var id: String { leadRun.id }
    /// The newest run in the group, representing the group's current state.
    let leadRun: HistoryDocument.Run
    /// All runs in the group, sorted newest first.
    let runs: [HistoryDocument.Run]

    var count: Int { runs.count }
    var isSingle: Bool { count == 1 }

    var health: Health { leadRun.health }
    var severity: String { leadRun.severity }
    var rules: [String] { leadRun.rules }
    var date: Date { leadRun.date }

    /// The oldest run in the group.
    var oldestRun: HistoryDocument.Run {
        runs.last ?? leadRun
    }

    /// Clean time display: "1:47 AM" for a single check, or "1:44 AM – 1:47 AM" for a span.
    var timeDescription: String {
        let fmt = DateFormatter()
        fmt.timeStyle = .short
        fmt.dateStyle = .none
        if isSingle {
            return fmt.string(from: leadRun.date)
        } else {
            let start = fmt.string(from: oldestRun.date)
            let end = fmt.string(from: leadRun.date)
            return start == end ? start : "\(start) – \(end)"
        }
    }

    /// Subtitle for coalesced rows.
    var countDescription: String {
        isSingle ? "" : "\(count) checks · status unchanged"
    }
}

extension RunGroup {
    /// Folds a list of runs (sorted newest first) into coalesced `RunGroup`s.
    /// Consecutive runs coalesce if they have the exact same severity and rules,
    /// and occurred on the same calendar day.
    static func coalesce(_ runs: [HistoryDocument.Run],
                         calendar: Calendar = .current) -> [RunGroup] {
        guard !runs.isEmpty else { return [] }

        var groups: [RunGroup] = []
        var currentCluster: [HistoryDocument.Run] = []

        for run in runs {
            if let lead = currentCluster.first {
                if canCoalesce(lead, run, calendar: calendar) {
                    currentCluster.append(run)
                } else {
                    groups.append(RunGroup(leadRun: lead, runs: currentCluster))
                    currentCluster = [run]
                }
            } else {
                currentCluster = [run]
            }
        }

        if let lead = currentCluster.first {
            groups.append(RunGroup(leadRun: lead, runs: currentCluster))
        }

        return groups
    }

    private static func canCoalesce(_ a: HistoryDocument.Run,
                                    _ b: HistoryDocument.Run,
                                    calendar: Calendar) -> Bool {
        a.severity == b.severity &&
        a.rules == b.rules &&
        calendar.isDate(a.date, inSameDayAs: b.date)
    }
}

/// A calendar-day bucket of run groups.
struct DaySection: Identifiable, Sendable {
    let id: String
    let label: String
    let date: Date
    let groups: [RunGroup]

    static func group(_ groups: [RunGroup],
                      calendar: Calendar = .current) -> [DaySection] {
        guard !groups.isEmpty else { return [] }

        var buckets: [(Date, [RunGroup])] = []
        for group in groups {
            let day = calendar.startOfDay(for: group.date)
            if let index = buckets.firstIndex(where: { $0.0 == day }) {
                buckets[index].1.append(group)
            } else {
                buckets.append((day, [group]))
            }
        }

        let nowDay = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: nowDay)

        let dateFmt = DateFormatter()
        dateFmt.dateStyle = .medium
        dateFmt.timeStyle = .none

        return buckets.map { day, dayGroups in
            let label: String
            if day == nowDay {
                label = "Today"
            } else if let yesterday, day == yesterday {
                label = "Yesterday"
            } else {
                label = dateFmt.string(from: day)
            }
            return DaySection(id: "\(day.timeIntervalSince1970)",
                              label: label,
                              date: day,
                              groups: dayGroups)
        }
    }
}
