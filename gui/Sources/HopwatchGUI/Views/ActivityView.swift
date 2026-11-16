import SwiftUI
import UniformTypeIdentifiers

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

    @State private var issuesOnly = false
    @State private var currentNetworkOnly = false
    @State private var searchQuery = ""
    @State private var expandedEntryIDs: Set<String> = []
    @State private var showingClearConfirmation = false
    @State private var exportToast: String? = nil

    var body: some View {
        let sourceEvents = currentNetworkOnly
            ? coordinator.currentNetworkEvents(withinHours: nil)
            : coordinator.eventLog.events
        let allEntries = ActivityEntry.fold(sourceEvents)
        let issueFiltered = issuesOnly ? allEntries.filter(isIssue) : allEntries
        let filteredEntries = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? issueFiltered
            : issueFiltered.filter { matchesSearch($0, query: searchQuery) }
        let allDaysCount = days(of: allEntries).count
        let days = days(of: filteredEntries)

        return VStack(alignment: .leading, spacing: 0) {
            summaryCard(allEntries: allEntries, daysCount: allDaysCount)
            Divider()
            List {
                activeSection
                if days.isEmpty {
                    emptyState
                } else {
                    ForEach(days) { day in
                        Section(day.label) {
                            ForEach(day.entries) { entry in
                                ActivityRowContainer(
                                    entry: entry,
                                    isExpanded: expandedEntryIDs.contains(entry.id),
                                    onToggleExpand: {
                                        withAnimation(.easeInOut(duration: 0.18)) {
                                            if expandedEntryIDs.contains(entry.id) {
                                                expandedEntryIDs.remove(entry.id)
                                            } else {
                                                expandedEntryIDs.insert(entry.id)
                                            }
                                        }
                                    }
                                )
                            }
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            "Clear Activity History?",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear All Activity", role: .destructive) {
                coordinator.clearEventLog()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently remove all recorded event episodes and transition history.")
        }
    }

    // MARK: - Summary Card

    private func summaryCard(allEntries: [ActivityEntry], daysCount: Int) -> some View {
        let issuesCount = allEntries.filter(isIssue).count
        let activeCount = coordinator.alerts.urgentActiveSorted.count

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: activeCount > 0 ? "exclamationmark.triangle.fill" : (allEntries.isEmpty ? "clock" : (issuesCount > 0 ? "clock.arrow.circlepath" : "checkmark.shield.fill")))
                    .font(.system(size: 20))
                    .foregroundStyle(activeCount > 0 ? .red : (allEntries.isEmpty ? .secondary : (issuesCount > 0 ? .blue : .green)))
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.summaryTitle(activeCount: activeCount, issuesCount: issuesCount, allCount: allEntries.count))
                        .font(.headline)

                    Text(Self.summarySubtitle(allCount: allEntries.count, issuesCount: issuesCount, daysCount: daysCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Picker("Filter", selection: $issuesOnly) {
                    Text("All Activity (\(allEntries.count))").tag(false)
                    Text("Issues Only (\(issuesCount))").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 240)
            }

            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField("Search events, rules, IPs, or apps…", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .font(.caption)
                    if !searchQuery.isEmpty {
                        Button {
                            searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))

                Picker("Scope", selection: $currentNetworkOnly) {
                    Text("All Networks").tag(false)
                    Text("Current Network").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)

                Menu {
                    Button {
                        exportCSV()
                    } label: {
                        Label("Save as CSV (.csv)…", systemImage: "tablecells")
                    }
                    Button {
                        copyMarkdown()
                    } label: {
                        Label("Copy as Markdown", systemImage: "doc.on.doc")
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 11))
                        Text("Export")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(allEntries.isEmpty)
                .opacity(allEntries.isEmpty ? 0.45 : 1.0)

                Button {
                    showingClearConfirmation = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(5)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("Clear activity history…")
            }

            if let toast = exportToast {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.ColorToken.green)
                        .font(.system(size: 11))
                    Text(toast)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.ColorToken.ink)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Theme.ColorToken.nodeBackground)
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(Theme.ColorToken.line, lineWidth: 1))
            }
        }
        .padding(12)
    }

    private func exportCSV() {
        let csv = coordinator.exportActivityCSV(currentNetworkOnly: currentNetworkOnly)
        let name = "Hopwatch-Activity-\(Date().formatted(.iso8601.year().month().day())).csv"
        let type = UTType.commaSeparatedText
        DiagnosticReportSharing.saveFile(content: csv, defaultName: name, contentType: type)
    }

    private func copyMarkdown() {
        let md = coordinator.exportActivityMarkdown(currentNetworkOnly: currentNetworkOnly)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(md, forType: .string)
        withAnimation {
            exportToast = "Activity copied as Markdown"
        }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation {
                exportToast = nil
            }
        }
    }

    private func matchesSearch(_ entry: ActivityEntry, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let haystacks: [String?] = [
            entry.displaySummary,
            entry.summary,
            entry.ruleID,
            entry.kind,
            entry.detail,
            entry.extraDetail,
            entry.fromValue,
            entry.toValue,
            entry.trafficEvidence.map(\.name).joined(separator: " ")
        ]
        return haystacks.contains { text in
            guard let text else { return false }
            return text.localizedCaseInsensitiveContains(trimmed)
        }
    }

    static func summaryTitle(activeCount: Int, issuesCount: Int, allCount: Int) -> String {
        if activeCount > 0 {
            return "\(activeCount) Active Alert\(activeCount == 1 ? "" : "s") Now"
        }
        if allCount == 0 {
            return "No Activity Recorded Yet"
        }
        if issuesCount == 0 {
            return "Connection Stable & Quiet"
        }
        return "Network Activity History"
    }

    static func summarySubtitle(allCount: Int, issuesCount: Int, daysCount: Int) -> String {
        if allCount == 0 {
            return "Network transitions and disruptions will appear here as they are observed."
        }
        let span = max(daysCount, 1)
        let dayWord = span == 1 ? "day" : "days"
        if issuesCount == 0 {
            return "No packet loss, latency spikes, or disruptions observed across \(span) \(dayWord)"
        }
        return "\(issuesCount) incident\(issuesCount == 1 ? "" : "s") · \(allCount) total event\(allCount == 1 ? "" : "s") over \(span) \(dayWord)"
    }

    private func isIssue(_ entry: ActivityEntry) -> Bool {
        if entry.kind == "gap" || entry.kind == "wifi-roamed" || entry.kind == "rule-cleared" { return false }
        if let ruleID = entry.ruleID {
            let sev = coordinator.rulesCatalog.catalog?[ruleID]?.severity
            if sev == "info" { return false }
            return true
        }
        if entry.kind == "rule-fired" || entry.kind == "alert" || entry.kind == "vpn-disconnected" {
            return true
        }
        return false
    }

    // MARK: - Active now

    @ViewBuilder
    private var activeSection: some View {
        let active = coordinator.alerts.urgentActiveSorted
        if !active.isEmpty {
            Section("Active now") {
                ForEach(active) { alert in
                    AlertStageCard(
                        alert: .init(
                            title: alert.title, body: alert.body,
                            raisedAt: alert.raisedAt, rules: alert.rules,
                            severityRank: alert.rules
                                .map(coordinator.severityRank(forRuleID:)).max() ?? 0,
                            id: alert.id,
                            isUrgent: alert.isUrgent),
                        onAction: {
                            if alert.id == "captive-portal" || alert.rules.contains("CP-1") || alert.rules.contains("N1c") {
                                coordinator.openPortalPage()
                            }
                        }
                    )
                    .listRowSeparator(.hidden)
                }
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        let hasSearch = !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return ContentUnavailableView {
            Label(hasSearch ? "No Matching Activity" : "No Activity Yet",
                  systemImage: hasSearch ? "magnifyingglass" : "clock")
        } description: {
            Text(hasSearch
                 ? "No events match your current search filter."
                 : (issuesOnly
                    ? "No connection issues have been recorded."
                    : "Network transitions and alerts will appear here as they happen."))
        }
    }

    // MARK: - Day grouping

    struct DayGroup: Identifiable {
        let id: Date
        let label: String
        let entries: [ActivityEntry]
    }

    private func days(of entries: [ActivityEntry]) -> [DayGroup] {
        let calendar = Calendar.current
        var grouped: [Date: [ActivityEntry]] = [:]
        for entry in entries {
            let startOfDay = calendar.startOfDay(for: entry.earliest)
            grouped[startOfDay, default: []].append(entry)
        }
        return grouped.keys.sorted(by: >).map { day in
            DayGroup(
                id: day,
                label: dayLabel(day),
                entries: (grouped[day] ?? []).sorted { $0.earliest > $1.earliest }
            )
        }
    }

    private static let relativeDayFormatter: DateFormatter = {
        let df = DateFormatter()
        df.timeStyle = .none
        df.dateStyle = .medium
        df.doesRelativeDateFormatting = true
        return df
    }()

    private func dayLabel(_ day: Date) -> String {
        Self.relativeDayFormatter.string(from: day)
    }
}

// MARK: - Expandable Activity Row Container

struct ActivityRowContainer: View {
    let entry: ActivityEntry
    let isExpanded: Bool
    let onToggleExpand: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                ActivityRow(entry: entry)

                Button(action: onToggleExpand) {
                    Image(systemName: isExpanded ? "chevron.up.circle.fill" : "info.circle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isExpanded ? .blue : (isHovered ? .primary : .secondary.opacity(0.8)))
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Collapse details" : "Explain this activity & show more details")
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isExpanded ? Color.blue.opacity(0.06) : (isHovered ? Color.secondary.opacity(0.08) : Color.clear))
            )
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .onTapGesture { onToggleExpand() }

            if isExpanded {
                ActivityDetailCard(entry: entry)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .padding(.leading, 34)
                    .padding(.trailing, 6)
                    .padding(.bottom, 6)
            }
        }
    }
}
