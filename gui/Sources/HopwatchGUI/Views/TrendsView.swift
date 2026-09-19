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
    @Environment(HopwatchCoordinator.self) private var coordinator

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
                baselineDigest
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
    /// any state, per the redesign's split.
    private var purposeSubtitle: some View {
        Text("What this network is usually like — one point per saved check, over weeks. Live samples are not stored here.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .proseWidth()
            .padding(.horizontal, 12)
    }

    private var defaultNetworkID: String? {
        guard let raw = coordinator.monitor.latest?.network.historyJoinID else { return nil }
        let canonical = store.canonicalID(raw)
        return store.mergedNetworks.contains(where: { $0.id == canonical }) ? canonical : nil
    }

    // MARK: - Baseline Digest

    @ViewBuilder
    private var baselineDigest: some View {
        if let mem = selectedNetworkMemory {
            HStack(spacing: 10) {
                digestTile(
                    icon: "arrow.up.arrow.down",
                    iconColor: .blue,
                    title: "Typical Speeds",
                    value: speedText(mem),
                    subcaption: speedSubcaption(mem)
                )

                digestTile(
                    icon: "gauge.with.needle",
                    iconColor: .purple,
                    title: "Typical Ping",
                    value: latencyText(mem),
                    subcaption: jitterText(mem)
                )

                digestTile(
                    icon: "shield.checkerboard",
                    iconColor: reliabilityColor(mem),
                    title: "Reliability",
                    value: reliabilityText(mem),
                    subcaption: "\(mem.checkCount) checks · \(mem.incidentCount) issues"
                )
            }
            .padding(.horizontal, 12)
        }
    }

    private var selectedNetworkMemory: NetworkMemory? {
        guard let id = networkID else { return nil }
        guard let net = store.mergedNetworks.first(where: { $0.id == id }) else { return nil }
        let runs = store.runs(networkID: net.id, window: window)
        return NetworkHistoryStore.memory(for: net, displayName: store.displayName(for: net.id), runs: runs)
    }

    private func digestTile(
        icon: String,
        iconColor: Color,
        title: String,
        value: String,
        subcaption: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(iconColor)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .lineLimit(1)
            Text(subcaption)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    private func speedText(_ mem: NetworkMemory) -> String {
        if let down = mem.typicalDownMbps {
            if let up = mem.typicalUpMbps {
                return String(format: "%.0f / %.0f Mbps", down, up)
            }
            return String(format: "%.0f Mbps", down)
        }
        return "No speed tests"
    }

    private func speedSubcaption(_ mem: NetworkMemory) -> String {
        if let peak = mem.peakDownMbps, let typ = mem.typicalDownMbps, peak > typ {
            return String(format: "Peak: %.0f Mbps", peak)
        }
        return "Download / Upload"
    }

    private func latencyText(_ mem: NetworkMemory) -> String {
        if let lat = mem.typicalGatewayLatencyMs {
            return String(format: "%.1f ms", lat)
        }
        if let lat = mem.typicalInternetLatencyMs {
            return String(format: "%.1f ms", lat)
        }
        return "—"
    }

    private func jitterText(_ mem: NetworkMemory) -> String {
        if let j = mem.typicalGatewayJitterMs {
            return String(format: "±%.1f ms jitter", j)
        }
        return "Gateway latency baseline"
    }

    private func reliabilityText(_ mem: NetworkMemory) -> String {
        if let pct = mem.reliabilityPercent {
            return String(format: "%.0f%% (%@)", pct, mem.reliabilityGrade)
        }
        return "—"
    }

    private func reliabilityColor(_ mem: NetworkMemory) -> Color {
        switch mem.reliabilityGrade {
        case "Excellent", "Good": return .green
        case "Fair": return .orange
        default: return .red
        }
    }

    // MARK: - Verdict

    @ViewBuilder
    private var verdictCard: some View {
        if let networkID {
            if let judged = store.judged(networkID: networkID),
               let summary = judged.summary, !summary.isEmpty {
                let health = verdictHealth(judged.overall)
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: health == .healthy ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(health?.tint ?? .secondary)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary)
                            .font(.callout.weight(.medium))
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
    private func friendlyMetricLabel(_ m: HistoryDocument.MetricDescriptor) -> String {
        let name: String
        switch m.key {
        case "gateway_rtt_ms":
            name = "Router Ping"
        case "internet_rtt_ms":
            name = "Internet Ping"
        case "bufferbloat_gw_delta_ms":
            name = "Bufferbloat (Router)"
        case "bufferbloat_inet_delta_ms":
            name = "Bufferbloat (Internet)"
        case "speedtest_down_mbps":
            name = "Download Speed"
        case "speedtest_up_mbps":
            name = "Upload Speed"
        case "wifi_rssi":
            name = "Wi-Fi Signal Strength"
        default:
            name = m.label
        }
        let samples: Int
        if let networkID, let net = store.mergedNetworks.first(where: { $0.id == networkID }) {
            samples = net.metricSamples[m.key] ?? 0
        } else {
            samples = m.samples
        }
        return "\(name) (\(samples))"
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Network", selection: $networkID) {
                Text("All networks").tag(String?.none)
                ForEach(store.mergedNetworks) { net in
                    Text(store.displayName(for: net.id)).tag(String?.some(net.id))
                }
            }
            .frame(maxWidth: 220)

            Picker("Metric", selection: $metricKey) {
                ForEach(store.document.metrics) { m in
                    Text(verbatim: friendlyMetricLabel(m)).tag(m.key)
                }
            }
            .frame(maxWidth: 260)

            Picker("Window", selection: $window) {
                ForEach(HistoryWindow.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 180)

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
                // A single outlier was setting the whole scale: 2371 gateway
                // RTT samples that live between 2 and 8 ms were being drawn
                // against a 0–3000 ms axis because one reading hit 2.8 s,
                // flattening every real variation into a line on the floor.
                // See `Clamp` for what is done about it and why nothing is
                // hidden by it.
                let clamp = Clamp.forValues(points.map(\.1), p90: stat?.p90)
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
                        let value = clamp?.apply(point.1) ?? point.1
                        LineMark(x: .value("When", point.0),
                                 y: .value(descriptor?.label ?? "", value))
                            .interpolationMethod(.monotone)
                        // Points as well as a line: with 38 samples spread
                        // over two months, a line alone implies a
                        // continuous measurement that was never taken.
                        PointMark(x: .value("When", point.0),
                                  y: .value(descriptor?.label ?? "", value))
                            .symbolSize(count > 200 ? 4 : 18)
                        // A reading drawn at the ceiling rather than at its
                        // real height gets its own mark, so "pegged" can
                        // never be mistaken for "measured this value".
                        if let clamp, clamp.exceeds(point.1) {
                            PointMark(x: .value("When", point.0),
                                      y: .value(descriptor?.label ?? "", clamp.upper))
                                .symbol(.triangle)
                                .symbolSize(40)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .chartYDomain(clamp.map { 0...$0.upper })
                .chartYAxis { AxisMarks(position: .leading) { plainCountLabel($0) } }
                .frame(height: 220)

                if hasBand {
                    Text("Shaded: this network's typical range, from its saved checks.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                // Required, not decorative: the axis stops below the real
                // maximum, and a chart that quietly rescales past its own
                // outliers tells the same comfortable lie as a smooth line
                // through an outage — the thing `MonitorSeries` refuses to
                // draw. If the top of the range is not the top of the data,
                // the chart has to say so.
                if let clamp {
                    Text(verbatim: clamp.note(unit: descriptor?.unit))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .proseWidth()
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                )
        )
    }

    /// Y-axis labels without the locale's thousands separator.
    ///
    /// Swift Charts formats axis values through the current locale, so the
    /// incident chart's count axis rendered 2000 as "2.000" — which reads
    /// as *two* against an axis whose other labels are 0, 500 and 1.500.
    /// The same defect as the `LocalizedStringKey` count interpolations
    /// fixed elsewhere in this file, arriving by a different route: the app
    /// is English throughout, so its numbers should be spelled one way.
    @AxisMarkBuilder
    private func plainCountLabel(_ value: AxisValue) -> some AxisMark {
        AxisGridLine()
        AxisTick()
        AxisValueLabel {
            if let number = value.as(Double.self) {
                Text(verbatim: number == number.rounded()
                     ? String(Int(number))
                     : String(format: "%g", number))
            }
        }
    }

    /// A y-axis bound that keeps one extreme reading from flattening every
    /// other one, without hiding it.
    ///
    /// The store this was written against holds 2371 gateway RTT samples
    /// that sit between about 2 and 8 ms, plus a single 2.8 s spike. Charted
    /// against their own range, the axis ran 0–3000 ms and the other 2370
    /// points drew as a flat line on the floor: the chart contained all the
    /// data and conveyed none of it.
    ///
    /// So the axis is clamped just above the highest reading that is not
    /// part of the extreme tail — the top 1% of samples, or the single
    /// highest one in a series too short to have a 1% — and out-of-range
    /// readings are drawn pinned to the ceiling with their own orange
    /// triangle, above a caption naming how many there are and how high the
    /// highest actually went. Nothing is dropped, and nothing is drawn at a
    /// height it was not measured at without saying so — the same standard
    /// `MonitorSeries` applies when it refuses to draw a line across a gap,
    /// because a chart that silently rescales past its outliers is
    /// reassuring in exactly the way that one would be.
    ///
    /// These numbers scale an axis; they decide nothing about the network.
    /// The cutoffs that judge a reading live in `lib/thresholds.sh` and
    /// reach this screen as the CLI's own `judged` verdict, which this view
    /// renders verbatim and does not compute.
    struct Clamp {
        let upper: Double
        let outliers: Int
        let maximum: Double

        func exceeds(_ value: Double) -> Bool { value > upper }
        func apply(_ value: Double) -> Double { min(value, upper) }

        /// `nil` when the data's own range is already readable — the common
        /// case, and the one where clamping would be meddling.
        static func forValues(_ values: [Double], p90: Double?) -> Clamp? {
            let finite = values.filter { $0.isFinite }
            guard finite.count >= 10, let maximum = finite.max(), maximum > 0
            else { return nil }
            let sorted = finite.sorted()
            // The tail is set aside by *count*, not located by a
            // percentile index, and that distinction is the whole of this
            // function's history. Written as `sorted[floor(n * 0.99)]` it
            // was correct only above 100 samples: for every n from 10 to
            // 100 that index is `n - 1`, so "the 99th percentile" was the
            // maximum itself, the extreme-tail guard below reduced to
            // `maximum > maximum * 2`, and the clamp silently never
            // engaged on any series a day of runs actually produces. It
            // fails the same way at any size once a spike repeats: 24
            // equal spikes in 2371 samples put the index inside the tail.
            //
            // Below 100 readings there is genuinely no 1% to take, and no
            // element sits strictly under the 99th percentile — so a
            // percentile is the wrong instrument at that size and the
            // floor of one reading is the honest reading of it: set the
            // single highest sample aside and compare it to the rest.
            // The cost of that floor is that two *equal* extremes in a
            // short series are treated as spread rather than as a tail,
            // which is the right call — two of thirty-eight is 5% of the
            // data, and pinning 5% of a chart to its ceiling hides more
            // than it reveals.
            let tail = max(1, Int((Double(sorted.count) * 0.01).rounded(.up)))
            guard sorted.count > tail else { return nil }
            let bulkMaximum = sorted[sorted.count - tail - 1]
            guard bulkMaximum > 0 else { return nil }
            // Only step in for a genuinely extreme tail. A series whose
            // maximum is merely twice the rest of the data has a real
            // spread worth seeing at full height.
            guard maximum > bulkMaximum * 2 else { return nil }
            // Never clamp below the typical band the chart also draws, or
            // the shading would run off the top of its own axis.
            var upper = bulkMaximum * 1.15
            if let p90, p90 > 0 { upper = max(upper, p90 * 1.2) }
            guard upper < maximum else { return nil }
            return Clamp(upper: upper,
                         outliers: finite.filter { $0 > upper }.count,
                         maximum: maximum)
        }

        func note(unit: String?) -> String {
            let suffix = (unit?.isEmpty == false) ? " \(unit!)" : ""
            let peak = Self.trim(maximum) + suffix
            return outliers == 1
                ? "1 reading is above this range and is drawn at the top edge — it actually reached \(peak)."
                : "\(outliers) readings are above this range and are drawn at the top edge — the highest reached \(peak)."
        }

        /// Two significant-ish decimals without trailing zeros, so a 2.8 s
        /// spike reads "2800" rather than "2800.000000001".
        private static func trim(_ value: Double) -> String {
            value == value.rounded()
                ? String(Int(value))
                : String(format: "%.2f", value)
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
                .chartYAxis { AxisMarks(position: .leading) { plainCountLabel($0) } }
                .frame(height: 160)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                )
        )
    }

    private struct DayBucket: Identifiable {
        var id: Date { day }
        var key: String { "\(day.timeIntervalSince1970)" }
        let day: Date
        var counts: [String: Int]
    }

    private func bucketByDay(_ runs: [HistoryDocument.Run]) -> [DayBucket] {
        var out: [Date: [String: Int]] = [:]
        let calendar = Calendar.current
        for run in runs {
            let day = calendar.startOfDay(for: run.date)
            let severity = run.severity == "info" ? "ok" : run.severity
            out[day, default: [:]][severity, default: 0] += 1
        }
        return out.map { DayBucket(day: $0.key, counts: $0.value) }
            .sorted { $0.day < $1.day }
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
            Text(verbatim: "\(counts.runs) run\(counts.runs == 1 ? "" : "s") across \(counts.networks) network\(counts.networks == 1 ? "" : "s"), read from baseline history and its archive.")
                .font(.caption).foregroundStyle(.secondary)
            if counts.redactedDropped > 0 {
                Text(verbatim: "\(counts.redactedDropped) run\(counts.redactedDropped == 1 ? " was" : "s were") skipped: they were recorded with --redact, so their network identity was masked and they can't be attributed to any network.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if counts.duplicatesDropped > 0 {
                Text(verbatim: "\(counts.duplicatesDropped) duplicate record\(counts.duplicatesDropped == 1 ? " was" : "s were") merged.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        // The widest prose on this screen, and — before this cap — the
        // single view setting the whole tab's ideal width. See
        // `proseWidth`.
        .proseWidth(520)
    }
}

private extension View {
    /// `chartYScale(domain:)` takes a range, not an optional, and applying
    /// it unconditionally would force a fixed axis on every metric — so the
    /// "no clamp needed" case, which is most of them, needs to leave the
    /// chart's own auto-scaling alone rather than pass it a sentinel.
    @ViewBuilder
    func chartYDomain(_ range: ClosedRange<Double>?) -> some View {
        if let range { chartYScale(domain: range) } else { self }
    }
}
