import SwiftUI
import Charts

/// Charts over the whole run store.
///
/// The design constraint that shapes every decision here: **sparse series
/// are the normal case, not an edge case.** In the store this was written
/// against, `gateway.rtt_avg_ms` has 1,959 samples, `bufferbloat.gw_delta_ms`
/// has 38, `wifi.rssi` has 1, and `speedtest.down_mbps` has none at all.
///
/// So every metric shows its sample count, and a metric with no samples in
/// the selected window renders an explicit "no data" panel rather than an
/// empty axis. An empty axis is indistinguishable from a flat line at
/// zero — which, for a download-speed chart, reads as two months of a dead
/// connection.
struct TrendsView: View {
    @Environment(NetdiagCoordinator.self) private var coordinator

    // Gateway RTT and incident count are the defaults because they are the
    // only two series with real depth here. Picking a prettier default that
    // happened to be empty would make the feature look broken on first open.
    @State private var metricKey = "gateway_rtt_ms"
    @State private var window = HistoryWindow.all
    @State private var networkID: String?

    private var store: HistoryStore { coordinator.history }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                controls
                purposeSubtitle
                verdictCard
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    metricChart
                    incidentChart
                    coverageNote
                }
                .padding(16)
            }
        }
        .task {
            if store.document.runs.isEmpty { await store.load() }
            // Default to the current network, once, on open — never
            // overriding a choice the user makes afterward within this
            // same view lifetime, since this only runs at first appear.
            // Falls back to "All networks" (`networkID` stays `nil`) when
            // there is no live sample yet or its network hasn't reached
            // the store.
            if networkID == nil, let current = defaultNetworkID { networkID = current }
        }
    }

    // MARK: - Purpose

    /// Wayfinding copy about this screen itself — permanent, not tied to
    /// any state, per the redesign's split (CLAUDE.md: claims about *CLI*
    /// behavior belong in the rules catalog; what this app's own view is
    /// for is fine to say in Swift).
    private var purposeSubtitle: some View {
        Text("What this network is usually like — one point per saved check, over weeks. Live samples are not stored here.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .proseWidth()
            .padding(.horizontal, 12)
    }

    /// The current network, canonicalized, for defaulting `networkID` when
    /// the picker first appears — the same monitor→history join
    /// `NetdiagCoordinator.wifiDisplayName` and `AlertEngine.networkChanged`
    /// use (`historyJoinID`), passed through `canonicalID` so a manually
    /// merged network resolves to the group the user actually merged it
    /// into. `nil` before any monitor sample has landed, or when that
    /// network hasn't appeared in the loaded store yet — both cases the
    /// picker already handles by staying on "All networks".
    private var defaultNetworkID: String? {
        guard let raw = coordinator.monitor.latest?.network.historyJoinID else { return nil }
        let canonical = store.canonicalID(raw)
        return store.mergedNetworks.contains(where: { $0.id == canonical }) ? canonical : nil
    }

    // MARK: - Verdict

    /// The CLI's own verdict for the selected network — `judged.summary`
    /// verbatim, tinted from `judged.overall`. Shown only for a single
    /// selected network that maps onto exactly one raw `--history` group
    /// (`HistoryStore.judged(networkID:)` already encodes that rule); "All
    /// networks" gets a plain wayfinding line instead, and a network with
    /// no verdict (a manual merge, or an old CLI) gets neither — this app
    /// does not compose a substitute verdict of its own.
    @ViewBuilder
    private var verdictCard: some View {
        if let networkID {
            if let judged = store.judged(networkID: networkID),
               let summary = judged.summary, !summary.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(verdictHealth(judged.overall)?.tint ?? .secondary)
                        .frame(width: 8, height: 8)
                        .padding(.top, 5)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Judged by netdiag, not the app")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(12)
                .cardStyle()
                .padding(.horizontal, 12)
            }
        } else {
            Text("Pick a network to see what it's usually like.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
        }
    }

    /// `judged.overall`'s three CLI-defined values, translated to a colour
    /// — the same string-to-`Health` mapping `HistoryDocument.Run.health`
    /// already does, not a judgement of this view's own. `nil` for the
    /// insufficient-data case (`overall == nil`), which the caller renders
    /// in a neutral tint rather than guessing a severity.
    private func verdictHealth(_ overall: String?) -> Health? {
        switch overall {
        case "critical": return .critical
        case "warn":     return .warning
        case "ok":       return .healthy
        default:         return nil
        }
    }

    // MARK: - Controls

    /// The three filters plus reload.
    ///
    /// The widths are deliberately tighter than the values they hold. A
    /// macOS pop-up reports the width of its widest menu item as its
    /// ideal, so the Network picker alone — whose items are ISP-derived
    /// names like "SOMOS NETWORKS COLOMBIA S.A.S. BIC via 192.168.68.1" —
    /// would otherwise set this row's ideal width from whichever network
    /// happens to have the longest name. That number feeds the window
    /// width at which the sidebar collapses (see `View.proseWidth`), so
    /// an unlucky ISP name was a layout input. Network keeps the most
    /// room of the three because its values are the longest and the least
    /// guessable when truncated; Window needs least, its four values are
    /// fixed and short.
    private var controls: some View {
        HStack {
            Picker("Metric", selection: $metricKey) {
                ForEach(store.document.metrics) { m in
                    // The sample count is in the picker itself, so choosing
                    // an empty metric is an informed choice rather than a
                    // dead end the user has to discover by selecting it.
                    Text("\(m.label) (\(m.samples))").tag(m.key)
                }
            }
            .frame(maxWidth: 220)

            Picker("Window", selection: $window) {
                ForEach(HistoryWindow.allCases) { Text($0.rawValue).tag($0) }
            }
            .frame(maxWidth: 130)

            Picker("Network", selection: $networkID) {
                Text("All networks").tag(String?.none)
                ForEach(store.mergedNetworks) { net in
                    Text(store.displayName(for: net.id)).tag(String?.some(net.id))
                }
            }
            .frame(maxWidth: 240)

            Spacer()

            if store.isLoading {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await store.load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Reload history")
            }
        }
        .padding(12)
    }

    // MARK: - Metric chart

    @ViewBuilder
    private var metricChart: some View {
        let descriptor = store.metric(metricKey)
        let points = store.series(metric: metricKey, networkID: networkID, window: window)
        let count = points.count
        // Only for a single selected network — the same gate as
        // `verdictCard` — and only when the CLI actually had enough
        // samples to compute one (`stat` is `nil` below the sample floor,
        // for a manual merge, and against an old CLI).
        let stat = networkID.flatMap { store.stat(metric: metricKey, networkID: $0) }
        let hasBand = stat?.p10 != nil && stat?.p90 != nil

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                // The unit belongs on the metric's name — "Gateway RTT
                // (ms) · 2027 samples" — not on the sample count, where
                // "(ms)" reads as the unit of "samples".
                Text(chartTitle).font(.headline)
                HelpHint(key: metricKey)
                Text(sampleLabel(count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let descriptor, count > 0 {
                    Text(descriptor.higherIsBetter ? "higher is better" : "lower is better")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if count == 0 {
                noData(descriptor)
            } else {
                Chart {
                    // Drawn first, so the line and points sit on top of it.
                    if hasBand, let p10 = stat?.p10, let p90 = stat?.p90,
                       let first = points.first?.0, let last = points.last?.0 {
                        RectangleMark(xStart: .value("From", first), xEnd: .value("To", last),
                                     yStart: .value("Typical low", p10),
                                     yEnd: .value("Typical high", p90))
                            .foregroundStyle(.quaternary.opacity(0.5))
                        if let median = stat?.median {
                            RuleMark(y: .value("Typical median", median))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(points, id: \.0) { point in
                        LineMark(x: .value("When", point.0),
                                 y: .value(descriptor?.label ?? "", point.1))
                            .interpolationMethod(.monotone)
                        // Points as well as a line: with 38 samples spread
                        // over two months, a line alone implies a
                        // continuous measurement that was never taken.
                        PointMark(x: .value("When", point.0),
                                  y: .value(descriptor?.label ?? "", point.1))
                            .symbolSize(count > 200 ? 4 : 18)
                    }
                }
                .chartYAxis { AxisMarks(position: .leading) }
                .frame(height: 220)

                if hasBand {
                    Text("Shaded: this network's typical range, from its saved checks.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// The explicit empty state. Says which metric has no data, in this
    /// window, and — where the catalog can say why — hands off to its
    /// `why_absent` prose verbatim rather than composing a claim about CLI
    /// behavior itself (CLAUDE.md). No catalog entry, or an old CLI whose
    /// catalog doesn't carry one at all, leaves the neutral count sentence
    /// standing alone.
    private func noData(_ descriptor: HistoryDocument.MetricDescriptor?) -> some View {
        let whyAbsent = descriptor.flatMap { coordinator.rulesCatalog.catalog?.metric($0.key)?.whyAbsent }
            .flatMap { $0.isEmpty ? nil : $0 }
        return VStack(alignment: .leading, spacing: 6) {
            Label("No data for this metric in this window",
                  systemImage: "chart.line.downtrend.xyaxis")
                .font(.callout)
            if let descriptor {
                Text(descriptor.samples == 0
                     ? "No run in your history has ever recorded \(descriptor.label.lowercased())."
                     : "\(descriptor.samples) run\(descriptor.samples == 1 ? "" : "s") elsewhere in your history recorded it — try a longer window or a different network.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if descriptor.samples == 0, let whyAbsent {
                    Text(whyAbsent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Full check") { coordinator.runFullCheck() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 200, alignment: .leading)
        .padding(14)
        .cardStyle()
    }

    private var chartTitle: String {
        let label = store.metric(metricKey)?.label ?? metricKey
        guard let unit = store.metric(metricKey)?.unit, !unit.isEmpty else { return label }
        return "\(label) (\(unit))"
    }

    private func sampleLabel(_ count: Int) -> String {
        switch count {
        case 0:  return "no samples"
        case 1:  return "1 sample"
        default: return "\(count) samples"
        }
    }

    // MARK: - Incidents

    /// Runs per day, split by the worst severity each one found. The second
    /// series with real depth, and the one that answers "is this getting
    /// worse?" without needing any single metric to be dense.
    private var incidentChart: some View {
        let runs = store.runs(networkID: networkID, window: window)
        let buckets = bucketByDay(runs)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Checks and problems found").font(.headline)
                Text(sampleLabel(runs.count)).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            if buckets.isEmpty {
                Text("No checks in this window.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
                    .padding(14)
                    .cardStyle()
            } else {
                Chart(buckets, id: \.key) { bucket in
                    ForEach(["critical", "warn", "ok"], id: \.self) { severity in
                        BarMark(x: .value("Day", bucket.day, unit: .day),
                                y: .value("Checks", bucket.counts[severity] ?? 0))
                            .foregroundStyle(by: .value("Result", severity))
                    }
                }
                .chartForegroundStyleScale([
                    "critical": Color.red, "warn": Color.yellow, "ok": Color.green,
                ])
                // Leading, matching the metric chart above — one chart
                // reading from the left and the next from the right reads
                // as two different apps stacked.
                .chartYAxis { AxisMarks(position: .leading) }
                .frame(height: 160)
            }
        }
    }

    private struct DayBucket {
        let key: String
        let day: Date
        var counts: [String: Int]
    }

    private func bucketByDay(_ runs: [HistoryDocument.Run]) -> [DayBucket] {
        var out: [String: DayBucket] = [:]
        let calendar = Calendar.current
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        for run in runs {
            let day = calendar.startOfDay(for: run.date)
            let key = formatter.string(from: day)
            var bucket = out[key] ?? DayBucket(key: key, day: day, counts: [:])
            let severity = run.severity == "info" ? "ok" : run.severity
            bucket.counts[severity, default: 0] += 1
            out[key] = bucket
        }
        return out.values.sorted { $0.day < $1.day }
    }

    // MARK: - Coverage

    /// What the history actually contains, stated plainly. A chart is only
    /// as honest as the reader's understanding of its gaps, and this store
    /// has a big one — 1,915 runs on one day, then two months of nothing.
    private var coverageNote: some View {
        let counts = store.document.counts
        return VStack(alignment: .leading, spacing: 4) {
            Text("About this history").font(.headline)
            // A load failure would otherwise render as "0 runs across 0
            // network(s)" — indistinguishable from a genuinely empty
            // store, with the actionable message (a too-old CLI names the
            // fix) swallowed. This is the only surface that reads
            // `HistoryStore.lastError`.
            if let error = store.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("\(counts.runs) run\(counts.runs == 1 ? "" : "s") across \(counts.networks) network\(counts.networks == 1 ? "" : "s"), read from ~/net-diag/baseline.jsonl and its archive.")
                .font(.caption).foregroundStyle(.secondary)
            if counts.redactedDropped > 0 {
                Text("\(counts.redactedDropped) run\(counts.redactedDropped == 1 ? " was" : "s were") skipped: they were recorded with --redact, so their network identity was masked and they can't be attributed to any network.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if counts.duplicatesDropped > 0 {
                Text("\(counts.duplicatesDropped) duplicate record\(counts.duplicatesDropped == 1 ? " was" : "s were") merged.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !coordinator.watcher.isInstalled {
                Text("Turn on background checks in Settings to record a run every 15 minutes — history gets much more useful with them.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // The widest prose on this screen, and — before this cap — the
        // single view setting the whole tab's ideal width. See
        // `proseWidth`.
        .proseWidth(520)
    }
}
