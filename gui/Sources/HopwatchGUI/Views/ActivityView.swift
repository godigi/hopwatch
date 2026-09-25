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
    @Environment(HopwatchCoordinator.self) private var coordinator

    /// Folded once per render, at the top of `body`, and passed down.
    ///
    /// `entries` and `days` used to be computed properties, and every read
    /// of one re-ran `ActivityEntry.fold` over the store's 500 rows: five
    /// folds and four `byDay` calls per `body`, counted with a probe —
    /// `heading` alone read `entries` once and `days` twice, then
    /// `days.isEmpty` and `ForEach(days)` each folded again. `coordinator`
    /// is `@Observable`, so a monitor sample seconds apart invalidates this
    /// view and pays all nine while the screen is open.
    ///
    /// Deliberately *not* `@State`: the fold is a pure function of
    /// `eventLog.events`, and cached state would go stale the moment the
    /// monitor recorded a transition. Recomputing once per render keeps the
    /// observation-driven refresh exactly as it was.
    @State private var issuesOnly = false

    var body: some View {
        let allEntries = ActivityEntry.fold(coordinator.eventLog.events)
        let filteredEntries = issuesOnly ? allEntries.filter(isIssue) : allEntries
        let days = days(of: filteredEntries)

        return VStack(alignment: .leading, spacing: 0) {
            summaryCard(allEntries: allEntries, daysCount: days.count)
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

    // MARK: - Summary Card

    private func summaryCard(allEntries: [ActivityEntry], daysCount: Int) -> some View {
        let issuesCount = allEntries.filter(isIssue).count
        let activeCount = coordinator.alerts.activeSorted.count

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: activeCount > 0 ? "exclamationmark.triangle.fill" : (issuesCount > 0 ? "clock.arrow.circlepath" : "checkmark.shield.fill"))
                    .font(.system(size: 20))
                    .foregroundStyle(activeCount > 0 ? .red : (issuesCount > 0 ? .blue : .green))
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(summaryTitle(activeCount: activeCount, issuesCount: issuesCount))
                        .font(.headline)

                    Text(summarySubtitle(allCount: allEntries.count, issuesCount: issuesCount, daysCount: daysCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Picker("Filter", selection: $issuesOnly) {
                    Text("All Activity (\(allEntries.count))").tag(false)
                    Text("Issues Only (\(issuesCount))").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)
            }
        }
        .padding(12)
    }

    private func summaryTitle(activeCount: Int, issuesCount: Int) -> String {
        if activeCount > 0 {
            return "\(activeCount) Active Alert\(activeCount == 1 ? "" : "s") Now"
        }
        if issuesCount == 0 {
            return "Connection Stable & Quiet"
        }
        return "Network Activity History"
    }

    private func summarySubtitle(allCount: Int, issuesCount: Int, daysCount: Int) -> String {
        if issuesCount == 0 {
            return "No packet loss, latency spikes, or disruptions observed across \(max(daysCount, 1)) day(s)"
        }
        return "\(issuesCount) incident\(issuesCount == 1 ? "" : "s") · \(allCount) total event\(allCount == 1 ? "" : "s") over \(max(daysCount, 1)) day(s)"
    }

    private func isIssue(_ entry: ActivityEntry) -> Bool {
        if entry.ruleID != nil { return true }
        if entry.kind == "rule-fired" || entry.kind == "alert" || entry.kind == "vpn-disconnected" {
            return true
        }
        return false
    }

    // MARK: - Active now

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
        VStack(spacing: 10) {
            Image(systemName: issuesOnly ? "checkmark.shield.fill" : "clock.arrow.circlepath")
                .font(.system(size: 32))
                .foregroundStyle(issuesOnly ? .green : .secondary)
            Text(issuesOnly ? "No Disruptions Recorded" : "No Activity Recorded Yet")
                .font(.headline)
            Text(issuesOnly
                 ? "Your connection has maintained uninterrupted stability with zero packet loss or latency alerts."
                 : "Events and network transitions will appear here as monitoring detects them.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 32)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    // MARK: - Day grouping

    private struct Day: Identifiable {
        let id: String
        let label: String
        let entries: [ActivityEntry]
    }

    /// One section per calendar day, newest first.
    ///
    /// The bucketing itself is `ActivityEntry.byDay`, next to the per-day
    /// key `fold` groups on, so the two cannot disagree about which day a
    /// row belongs to. This view only labels the result.
    private func days(of entries: [ActivityEntry]) -> [Day] {
        ActivityEntry.byDay(entries).map {
            Day(id: "\($0.day.timeIntervalSince1970)", label: dayLabel($0.day),
                entries: $0.entries)
        }
    }

    @MainActor
    private static let relativeDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .none
        f.doesRelativeDateFormatting = true
        return f
    }()

    private func dayLabel(_ day: Date) -> String {
        Self.relativeDayFormatter.string(from: day)
    }
}
