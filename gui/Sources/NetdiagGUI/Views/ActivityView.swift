import SwiftUI

/// What has happened on this Mac's networks, as episodes rather than
/// transitions — the full history the dropdown's three-row timeline teases.
///
/// Reads `coordinator.eventLog` (the durable `EventStore`, not
/// `coordinator.events`, the unrelated CoreWLAN/NWPath watcher).
///
/// ── Why this is not a straight list of `eventLog.events` ───────────────
/// It was, and on a flapping link that made it useless. The store holds one
/// row per transition, so a fault that came and went six times in an
/// afternoon printed twelve rows — six "Minor packet loss to router" and
/// six "Resolved: Minor packet loss to router" — none of which said how
/// long any of them lasted. Twelve days of that is 329 rows and no
/// answer to "is this network bad?".
///
/// `ActivityEntry.fold` pairs each fired with its cleared and groups the
/// day's episodes per rule, so those twelve rows become one that reads
/// "Minor packet loss to router · 6 times · over 4m total". See that type's
/// header for the pairing rules and for why it states durations but judges
/// none of them.
struct ActivityView: View {
    @Environment(NetdiagCoordinator.self) private var coordinator

    private var events: [NetworkEvent] { coordinator.eventLog.events }
    private var entries: [ActivityEntry] { ActivityEntry.fold(events) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading
            Divider()
            List {
                activeSection
                if days.isEmpty {
                    emptyState
                } else {
                    ForEach(days) { day in
                        Section(day.label) {
                            ForEach(day.entries) { ActivityRow(entry: $0) }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Heading

    /// Counts episodes, not stored rows. "329 events" was technically true
    /// and told the reader nothing except that the list would be long; the
    /// number that matters is how many distinct things happened.
    private var heading: some View {
        let count = entries.count
        return VStack(alignment: .leading, spacing: 2) {
            Text("Activity").font(.headline)
            Text(count == 0
                 ? "Nothing recorded yet"
                 : "\(count) event\(count == 1 ? "" : "s") in the last \(days.count) day\(days.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    // MARK: - Active now

    /// What is firing *right now*, above the history.
    ///
    /// This view previously rendered `eventLog` and nothing else, while
    /// `MainWindow` badged its sidebar row with `alerts.activeSorted.count`
    /// and the dropdown's alert card offered "See full report (+2)" pointing
    /// here — a badge counting something the screen never showed, and a
    /// button promising two more findings at a destination that listed
    /// neither. An `alert` event does appear in the history below once an
    /// alert fires, but that is a record of a past moment; it says nothing
    /// about whether the condition still holds now.
    ///
    /// Reuses `AlertStageCard`, the dropdown's own card, so an alert reads
    /// identically wherever it appears — including its severity colour.
    @ViewBuilder
    private var activeSection: some View {
        let active = coordinator.alerts.activeSorted
        if !active.isEmpty {
            Section("Active now") {
                ForEach(active) { alert in
                    AlertStageCard(alert: .init(
                        title: alert.title, body: alert.body,
                        raisedAt: alert.raisedAt, rules: alert.rules,
                        severityRank: alert.rules
                            .map(coordinator.severityRank(forRuleID:)).max() ?? 0))
                    .listRowSeparator(.hidden)
                }
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        Label("No events recorded yet — changes and alerts will appear here as monitoring notices them.",
              systemImage: "clock.arrow.circlepath")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 6)
    }

    // MARK: - Day grouping

    private struct Day: Identifiable {
        let id: String
        let label: String
        let entries: [ActivityEntry]
    }

    /// One section per calendar day, newest first. `fold` returns entries
    /// newest-first, so the days come out of it in order too.
    private var days: [Day] {
        let calendar = Calendar.current
        var order: [Date] = []
        var buckets: [Date: [ActivityEntry]] = [:]
        for entry in entries {
            let day = calendar.startOfDay(for: entry.latest)
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(entry)
        }
        return order.map {
            Day(id: "\($0.timeIntervalSince1970)", label: dayLabel($0),
                entries: buckets[$0] ?? [])
        }
    }

    private func dayLabel(_ day: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .none
        // "Today" and "Yesterday" where they apply — same relative-date
        // formatting RunListView's day grouping uses, for the same reason:
        // the recent events are the interesting ones, and a full date
        // makes the reader work out which of them that is.
        f.doesRelativeDateFormatting = true
        return f.string(from: day)
    }
}
