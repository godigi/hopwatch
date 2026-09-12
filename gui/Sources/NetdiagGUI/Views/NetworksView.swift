import SwiftUI

/// Two columns: a list of networks on the left, everything about the
/// selected one on the right.
///
/// The previous design was a `NavigationStack` of network cards — each
/// card carried its stats inline and a "Browse Checks" link that pushed a
/// second screen for the run list, which pushed a third for a single run.
/// Three screens deep to read one check. This collapses to one: the list
/// is just names (clickable, searchable, arrow-key cycleable), and the
/// right pane shows the stats, the controls, and the checks together.
/// Clicking a check swaps the right pane to its detail with a back button
/// — still one screen, no navigation push.
///
/// Neither rename nor merge is a nicety. Without Location Services every
/// Wi-Fi network on this machine has the ISP name as its label (the CLI
/// records no SSID without a Location grant), so a rename is the only way
/// to tell home from the office. And `helpers/history.py` deliberately
/// refuses to guess when its bridge heuristic is ambiguous — leaving two
/// groups apart rather than merging them wrongly — so a manual merge is
/// the honest completion of that refusal, not a workaround for it.
struct NetworksView: View {
    @Environment(NetdiagCoordinator.self) private var coordinator
    @State private var searchQuery = ""
    /// The network the right pane is about. Bound to the List's selection,
    /// so clicking a row or pressing arrow keys updates it immediately.
    @State private var selectedNetworkID: String?
    /// Set when a selection existed and the user cleared it (cmd-click or
    /// a click on empty list space). Stops `selectCurrentNetworkIfNeeded`
    /// from re-selecting the current network on the next monitor sample —
    /// a pane the user emptied on purpose must stay empty.
    @State private var userDeselected = false
    /// When set, the right pane shows this check's detail instead of the
    /// network overview. Set by clicking a row in the checks list; cleared
    /// by the back button. A state change in the right pane, not a
    /// navigation push — the list column never moves.
    @State private var selectedRunRoute: RunRoute?
    @State private var editingName = false
    @State private var draftName = ""
    @State private var mergeSource: HistoryDocument.Network?
    @State private var problemsOnly = false

    enum CheckScope: String, CaseIterable, Identifiable {
        case all = "All checks"
        case fullOnly = "Full checks"
        var id: String { rawValue }
    }
    @State private var checkScope = CheckScope.all
    @State private var expandedGroupIDs: Set<String> = []

    private var store: HistoryStore { coordinator.history }

    /// The recency-ordered list, narrowed to the search query. Empty-query
    /// returns the full list unchanged; matching is case- and
    /// diacritic-insensitive so "comcast" finds "Comcast" and "café" finds
    /// "Cafe" without the user having to type either precisely.
    private var visibleNetworks: [HistoryDocument.Network] {
        let all = store.mergedNetworksByRecency
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return all }
        let needle = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                     locale: .current)
        return all.filter { net in
            haystack(for: net)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .contains(needle)
        }
    }

    /// Every string a user might search for this network by, joined so one
    /// `contains` covers them all. The display name leads, because a
    /// user-assigned rename is the thing the user themselves will type.
    /// Includes the raw (uncleaned) label so searching for the full
    /// "SPACEX-STARLINK via 192.168.50.1" still works even though
    /// `displayName` now strips the " via ..." suffix.
    private func haystack(for net: HistoryDocument.Network) -> String {
        var parts: [String] = [store.displayName(for: net.id), net.label]
        parts += net.ssids
        parts += net.gateways
        parts += net.isps
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    var body: some View {
        HStack(spacing: 0) {
            listColumn
            Divider()
            detailColumn
        }
        .task {
            if store.document.networks.isEmpty { await store.load() }
            selectCurrentNetworkIfNeeded()
        }
        // The `.task` above usually runs before the monitor's first
        // sample arrives, so the default selection can't find the current
        // network yet and the pane opens on "Select a network". Re-apply
        // on every sample until a selection exists.
        .onChange(of: coordinator.monitor.latest?.seq) { _, _ in
            selectCurrentNetworkIfNeeded()
        }
        .onChange(of: selectedNetworkID) { old, new in
            if old != nil && new == nil { userDeselected = true }
            if new != nil { userDeselected = false }
        }
        .sheet(item: $mergeSource) { source in
            MergeSheet(source: source) { destination in
                store.merge(source.id, into: destination)
                mergeSource = nil
            } onCancel: {
                mergeSource = nil
            }
            .environment(coordinator)
        }
    }

    // MARK: - Left column: the network list

    private var listColumn: some View {
        VStack(spacing: 0) {
            if store.isLoading && store.document.networks.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading networks…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            List(selection: $selectedNetworkID) {
                if !store.isLoading && store.document.networks.isEmpty {
                    Text("No networks recorded yet. Run a check to start building history.")
                        .foregroundStyle(.secondary)
                } else if visibleNetworks.isEmpty {
                    Text("No networks match \"\(searchQuery.trimmingCharacters(in: .whitespacesAndNewlines))\"")
                        .foregroundStyle(.secondary)
                }
                ForEach(visibleNetworks) { net in
                    let mem = NetworkHistoryStore.memory(for: net, displayName: store.displayName(for: net.id))
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(store.displayName(for: net.id))
                                .lineLimit(1)
                            if isCurrent(net) {
                                Image(systemName: "circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.system(size: 8))
                            }
                            Spacer(minLength: 4)
                            // Last-seen rather than another badge: the row
                            // already identifies, this tells you how stale that
                            // identity is — "the café, 3 weeks ago" — which is
                            // the thing you actually scan the list for.
                            if let last = net.lastSeenDate {
                                Text(RelativeTime.string(from: last))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .help("Last seen \(last.formatted(date: .abbreviated, time: .shortened))")
                            }
                        }
                        Text(mem.summaryChipText)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 2)
                    .tag(net.id)
                }
            }
            .searchable(text: $searchQuery, placement: .toolbar,
                        prompt: "Search by name, SSID, gateway or ISP")
        }
        .frame(width: 250)
    }

    // MARK: - Right column: detail pane

    @ViewBuilder
    private var detailColumn: some View {
        if let route = selectedRunRoute {
            checkDetail(route)
        } else if let id = selectedNetworkID,
                  let net = visibleNetworks.first(where: { $0.id == id }) ?? store.mergedNetworksByRecency.first(where: { $0.id == id }) {
            networkOverview(net)
        } else {
            VStack {
                Text("Select a network")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Network overview (header + stats + controls + checks)

    private func networkOverview(_ net: HistoryDocument.Network) -> some View {
        let runs = networkRuns(net)
        let mem = NetworkHistoryStore.memory(for: net, displayName: store.displayName(for: net.id), runs: runs)
        let comp: NetworkComparison? = {
            if isCurrent(net), let latest = coordinator.monitor.latest {
                return NetworkHistoryStore.compare(sample: latest, baseline: mem)
            }
            return nil
        }()
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                nameHeader(net)
                NetworkDetailCard(memory: mem, comparison: comp)
                controlsRow(net)
                if !net.bridgedFrom.isEmpty {
                    Text("includes: \(net.bridgedFrom.joined(separator: ", "))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Divider()
                checksList(net)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func nameHeader(_ net: HistoryDocument.Network) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if editingName {
                TextField("Network name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .onSubmit { commitRename(net) }
                Button("Save") { commitRename(net) }
                Button("Cancel") { editingName = false }
            } else {
                Text(store.displayName(for: net.id))
                    .font(.title3).fontWeight(.semibold)
                if isCurrent(net) {
                    Text("connected")
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.green.opacity(0.2), in: Capsule())
                }
                if net.synthesized {
                    Text("inferred")
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.secondary.opacity(0.18), in: Capsule())
                        .help("Grouped by inference — these runs predate network identity, or were bridged by matching gateway and ISP.")
                }
            }
        }
    }

    private func statsRow(_ net: HistoryDocument.Network) -> some View {
        // `checkCount` is nil for a CLI old enough to predate the key (see
        // `HistoryDocument.Network`'s doc comment), and the only number
        // left to show then is `runCount` — every stored record, including
        // --speed-only/--mtu-only/--wifi-only partials. Labeling that count
        // "Checks" was the bug: on this machine one network reports
        // run_count 32 against check_count 28, so the old label overcounted
        // by exactly the partial runs it didn't examine the network for.
        // The label switches to "Runs" whenever it's showing the
        // all-records total rather than the checks-only one, so it never
        // claims more than the number actually means.
        let checksCount = net.checkCount ?? net.runCount
        let checksLabel = net.checkCount != nil ? "Checks" : "Runs"
        return HStack(spacing: 24) {
            stat(checksLabel, "\(checksCount)")
            stat("Problems", "\(net.incidentCount)", detail: problemsDetail(net))
            stat("Median router RTT", medianRTT(net))
            stat("Seen", dateRange(net))
        }
        .font(.caption)
    }

    /// The "% of checks" caption under the Problems stat, or nil when
    /// `incidentRate` has no honest denominator to report against — see
    /// that property's doc comment for why it can be nil.
    private func problemsDetail(_ net: HistoryDocument.Network) -> String? {
        guard let rate = net.incidentRate else { return nil }
        return String(format: "%.0f%% of checks", rate * 100)
    }

    private func controlsRow(_ net: HistoryDocument.Network) -> some View {
        HStack(spacing: 12) {
            if !editingName {
                Button("Rename") {
                    editingName = true
                    draftName = store.displayName(for: net.id)
                }
                .buttonStyle(.link)
            }
            Button("Merge…") { mergeSource = net }
                .buttonStyle(.link)
            if store.manualMerges.values.contains(net.id) {
                Button("Unmerge") { unmergeInto(net) }.buttonStyle(.link)
            }
            Spacer()
        }
    }

    // MARK: - Checks list (inline, no navigation push)

    private func checksList(_ net: HistoryDocument.Network) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("CHECKS")
                    .font(.system(size: 9, weight: .semibold))
                    .kerning(0.5)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Scope", selection: $checkScope) {
                    ForEach(CheckScope.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(maxWidth: 190)

                Toggle("Problems only", isOn: $problemsOnly)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
            .padding(.bottom, 2)

            let runs = visibleRuns(for: net)
            let groups = RunGroup.coalesce(runs)
            let days = DaySection.group(groups)

            if days.isEmpty {
                if problemsOnly {
                    Text("No problems on this network")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else if checkScope == .fullOnly && !networkRuns(net).isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No full checks recorded yet.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("Show all checks (\(networkRuns(net).count) recorded)") {
                            checkScope = .all
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                    .padding(.vertical, 8)
                } else {
                    Text("No checks recorded for this network yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(days) { day in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(day.label.uppercased())
                                .font(.system(size: 10, weight: .semibold))
                                .kerning(0.5)
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)

                            ForEach(day.groups) { group in
                                runGroupRow(group, net)
                            }
                        }
                    }
                }
            }
        }
    }

    private func runGroupRow(_ group: RunGroup, _ net: HistoryDocument.Network) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if group.isSingle {
                checkRow(group.leadRun, net)
            } else {
                coalescedGroupHeader(group, net)
                if expandedGroupIDs.contains(group.id) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(group.runs) { run in
                            checkRow(run, net, isNested: true)
                        }
                    }
                    .padding(.leading, 26)
                    .padding(.top, 2)
                    .padding(.bottom, 4)
                }
            }
        }
    }

    private func coalescedGroupHeader(_ group: RunGroup, _ net: HistoryDocument.Network) -> some View {
        let isExpanded = expandedGroupIDs.contains(group.id)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: group.health.symbol)
                .foregroundStyle(group.health.tint)
                .frame(width: 16)
            Text(group.timeDescription)
                .monospacedDigit()
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(minWidth: 80, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(checkHeadline(for: group.leadRun))
                        .foregroundStyle(group.leadRun.diagnosisCount == 0 ? .secondary : .primary)
                        .lineLimit(1)
                    Text("· \(group.count) identical checks")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if !group.rules.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(group.rules, id: \.self) { rule in
                            RuleChip(ruleID: rule)
                        }
                    }
                }
            }
            Spacer()
            Button {
                if isExpanded {
                    expandedGroupIDs.remove(group.id)
                } else {
                    expandedGroupIDs.insert(group.id)
                }
            } label: {
                HStack(spacing: 3) {
                    Text(isExpanded ? "Hide" : "\(group.count) runs")
                        .font(.caption2)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if isExpanded {
                expandedGroupIDs.remove(group.id)
            } else {
                expandedGroupIDs.insert(group.id)
            }
        }
    }

    private func checkRow(_ run: HistoryDocument.Run, _ net: HistoryDocument.Network, isNested: Bool = false) -> some View {
        Group {
            if let runID = run.runID {
                Button {
                    selectedRunRoute = RunRoute(runID: runID, networkID: net.id)
                } label: {
                    checkRowContent(run, isNested: isNested)
                }
                .buttonStyle(.plain)
            } else {
                checkRowContent(run, isNested: isNested)
                    .help("This check can't be opened — the netdiag CLI that recorded it predates run IDs.")
            }
        }
    }

    private func checkRowContent(_ run: HistoryDocument.Run, isNested: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: run.health.symbol)
                .foregroundStyle(run.health.tint)
                .frame(width: 16)
            Text(run.date.formatted(date: .omitted, time: .shortened))
                .monospacedDigit()
                .font(isNested ? .caption2 : .body)
                .foregroundStyle(isNested ? .secondary : .primary)
                .frame(width: 76, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(checkHeadline(for: run))
                    .foregroundStyle(run.diagnosisCount == 0 ? .secondary : .primary)
                    .lineLimit(1)
                if !run.rules.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(run.rules, id: \.self) { rule in
                            RuleChip(ruleID: rule)
                        }
                    }
                }
            }
            Spacer()
            if let mode = run.modeBadge {
                Text(mode)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private func checkHeadline(for run: HistoryDocument.Run) -> String {
        if !run.rules.isEmpty,
           let worst = NetdiagCoordinator.worstRule(among: run.rules, catalog: coordinator.rulesCatalog.catalog),
           let title = worst.title, !title.isEmpty {
            return title
        }
        if run.diagnosisCount == 0 {
            return "No problems found"
        }
        return run.headline
    }

    // MARK: - Check detail (inline, with back button)

    private func checkDetail(_ route: RunRoute) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    selectedRunRoute = nil
                } label: {
                    Label("All checks", systemImage: "chevron.left")
                }
                .buttonStyle(.link)
                Spacer()
            }
            .padding(8)
            Divider()
            RunDetailView(route: route)
        }
    }

    // MARK: - Helpers

    /// Default to the current network so the right pane is immediately
    /// useful rather than showing "Select a network". Joined on the
    /// history group key so this actually finds the row — the raw sample
    /// id never matches a group. Never overrides a selection the user
    /// made, and never re-selects after they deliberately deselect.
    private func selectCurrentNetworkIfNeeded() {
        guard selectedNetworkID == nil, !userDeselected,
              let currentID = coordinator.monitor.latest?.network.historyJoinID else { return }
        selectedNetworkID = store.canonicalID(currentID)
    }

    private func stat(_ label: String, _ value: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).foregroundStyle(.secondary)
            Text(value).fontWeight(.medium)
            if let detail { Text(detail).font(.caption2).foregroundStyle(.tertiary) }
        }
    }

    private func medianRTT(_ net: HistoryDocument.Network) -> String {
        guard let median = store.median(metric: "gateway_rtt_ms", networkID: net.id) else {
            return "no data"
        }
        return String(format: "%.1f ms", median)
    }

    private func dateRange(_ net: HistoryDocument.Network) -> String {
        guard let first = net.firstSeenDate, let last = net.lastSeenDate else { return "—" }
        let f = DateFormatter()
        f.dateFormat = "d MMM yy"
        return first == last ? f.string(from: first)
            : "\(f.string(from: first)) – \(f.string(from: last))"
    }

    private func isCurrent(_ net: HistoryDocument.Network) -> Bool {
        guard let id = coordinator.monitor.latest?.network.historyJoinID else { return false }
        return store.canonicalID(id) == net.id
    }

    private func visibleRuns(for net: HistoryDocument.Network) -> [HistoryDocument.Run] {
        var runs = networkRuns(net).sorted { $0.date > $1.date }
        if checkScope == .fullOnly {
            runs = runs.filter { $0.runMode == "full" || $0.runMode == nil }
        }
        if problemsOnly {
            runs = runs.filter(isProblem)
        }
        return runs
    }

    private func networkRuns(_ net: HistoryDocument.Network) -> [HistoryDocument.Run] {
        // Filtered to `isCheck`, matching `HistoryStore.recentChecks` (Home's
        // "Recent checks" card) and the "CHECKS" section header this list
        // sits under. `store.runs(networkID:window:)` applies no such
        // filter on its own, so a --speed-only reading used to show up here
        // but not on Home — the same run reading two different ways
        // depending on which list was showing it. Filtering here also makes
        // this list's length agree with `statsRow`'s checksCount, which
        // is the same `check_count` population once `checkCount` is
        // present.
        store.runs(networkID: net.id, window: .all).filter(\.isCheck)
    }

    private func isProblem(_ run: HistoryDocument.Run) -> Bool {
        run.severity == "warn" || run.severity == "critical"
    }

    private func commitRename(_ net: HistoryDocument.Network) {
        store.rename(net.id, to: draftName)
        editingName = false
    }

    private func unmergeInto(_ net: HistoryDocument.Network) {
        for (source, destination) in store.manualMerges where destination == net.id {
            store.unmerge(source)
        }
    }
}

/// Pick the group to merge into. Deliberately a deliberate action with a
/// visible list — the automatic heuristic already took every case it could
/// decide, so anything reaching this sheet is a judgement only the user can
/// make.
struct MergeSheet: View {
    @Environment(NetdiagCoordinator.self) private var coordinator
    let source: HistoryDocument.Network
    let onMerge: (String) -> Void
    let onCancel: () -> Void
    @State private var destination: String?

    /// "28 checks" where the CLI told us how many of the records were
    /// checks, "32 runs" where it did not — never "checks" over a number
    /// that counts partials too. Same fallback and same honesty as
    /// `NetworksView.statsRow`.
    private static func recordCount(_ net: HistoryDocument.Network) -> String {
        if let checks = net.checkCount {
            return "\(checks) check\(checks == 1 ? "" : "s")"
        }
        return "\(net.runCount) run\(net.runCount == 1 ? "" : "s")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Merge \"\(coordinator.history.displayName(for: source.id))\"")
                .font(.headline)
            // `runCount` is every stored record, including --speed-only and
            // the other partials; `check_count` is the ones that examined
            // the network. This sheet said "checks" over the former, the
            // same conflation the stats row above carried — and here it
            // misstates what the user is about to move.
            Text("Its \(Self.recordCount(source)) will be shown as part of the network you pick. This only changes how history is grouped in this app — nothing is deleted, and you can undo it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List(selection: $destination) {
                ForEach(coordinator.history.mergedNetworksByRecency.filter { $0.id != source.id }) { net in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(coordinator.history.displayName(for: net.id))
                        Text("\(Self.recordCount(net)) · \(net.gateways.joined(separator: ", "))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .tag(net.id)
                }
            }
            .frame(height: 200)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Merge") { if let destination { onMerge(destination) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(destination == nil)
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}
