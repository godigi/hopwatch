import SwiftUI
import Charts

/// The last hour of the monitor stream, drawn.
///
/// This is the only section that needs no CLI run at all:
/// `MonitorStream.recent` has been holding an hour of samples since the
/// stream existed and nothing drew them. The Trends section charts *stored
/// runs* — sparse, minutes to days apart; this charts the live stream at
/// whatever cadence it is actually running.
///
/// The rule that shapes it: **gaps are drawn as gaps.** See
/// `MonitorSeries` for why, and for how a gap is told apart from a slow
/// cadence without hardcoding either.
struct LiveView: View {
    @Environment(HopwatchCoordinator.self) private var coordinator
    @Environment(AppSettings.self) private var appSettings

    /// As far back as `recent` is bounded to hold at the default cadence.
    private static let window: TimeInterval = 3600

    private var monitor: MonitorStream { coordinator.monitor }

    private var samples: [MonitorSample] {
        let cutoff = Date().addingTimeInterval(-Self.window)
        return monitor.recent.filter { $0.timestamp >= cutoff }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                purposeSubtitle
                stateBanner
                currentValues
                let samples = samples
                chart(title: "Router round-trip",
                      titleHelpKey: "router",
                      subtitle: subtitle(catalogKey: "monitor_gateway_rtt",
                                        fallback: Self.routerSubtitleFallback),
                      series: MonitorSeries.build(samples, tier: "fast") {
                          $0.gateway.rttAvgMs
                      },
                      absent: "No router round-trip has been measured in the last hour.",
                      unit: "ms",
                      advice: "Flat lines near the bottom are ideal. Spikes indicate Wi-Fi noise or router load.")
                chart(title: "Internet round-trip",
                      titleHelpKey: "internet",
                      subtitle: subtitle(catalogKey: "monitor_internet_tcp",
                                        fallback: Self.internetSubtitleFallback),
                      caption: internetHostsCaption,
                      series: MonitorSeries.build(samples, tier: "medium",
                                                  value: Self.internetMs),
                      absent: "No internet round-trip has been measured in the last hour.",
                      unit: "ms",
                      advice: "Measures core internet targets. Spikes with a flat router line point to ISP congestion.")
                chart(title: "Router packet loss",
                      titleHelpKey: "packet_loss",
                      subtitle: subtitle(catalogKey: "monitor_gateway_loss",
                                        fallback: Self.lossSubtitleFallback),
                      series: MonitorSeries.build(samples, tier: "fast") {
                          $0.gateway.lossPct
                      },
                      absent: "No packet-loss measurement in the last hour.",
                      unit: "%",
                      advice: "0% loss is expected. Non-zero loss causes robotic audio or dropped calls.")
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Purpose

    /// Wayfinding copy about this screen itself, not a claim about the CLI
    /// — permanent, unlike everything below it that depends on state. See
    /// `TrendsView.purposeSubtitle` for the same split applied to the
    /// other tab.
    private var purposeSubtitle: some View {
        Text("What your connection is doing right now — small probes every few seconds, kept for an hour, never saved.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - State

    /// Monitoring off, paused, or bursting. Never a blank chart with no
    /// explanation: an empty chart and a stopped monitor look identical,
    /// and only one of them is the user's problem to fix.
    @ViewBuilder
    private var stateBanner: some View {
        if !appSettings.monitoringEnabled {
            banner("Monitoring is off",
                   "Nothing is being sampled, so this chart will not move. Resume monitoring from the menu-bar icon.",
                   systemImage: "pause.circle")
        } else if let reason = monitor.pauseReason {
            // Verbatim from the monitor's own pause bookkeeping, which is
            // reference-counted by reason — so this names every hold, not
            // just the most recent one.
            banner("Paused — \(reason)",
                   "Samples resume automatically. The stretch this covers is left blank rather than drawn through.",
                   systemImage: "pause.circle")
        } else if let error = monitor.lastError {
            banner("Monitoring stopped", error, systemImage: "exclamationmark.triangle")
        } else if let until = monitor.burstUntil {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Latency test — sampling every \(appSettings.latencyTestInterval)s")
                        .font(.callout)
                    Text("Back to the usual cadence at \(until.formatted(date: .omitted, time: .standard)).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("Stop") { coordinator.stopLatencyTest() }
            }
            .padding(12)
            .cardStyle()
        } else if isCaptivePortal {
            captivePortalCard
        } else {
            connectedCard
        }
    }

    /// Monitoring on, not paused, not errored, not bursting — the state
    /// this chart-only screen used to say nothing about at all. Reads
    /// `coordinator.headline` and `coordinator.currentHealth` verbatim,
    /// the exact path `HomeView`'s header and the dropdown's stage card
    /// already read, so this card can never describe the moment
    /// differently than either of them — no verdict is composed here.
    /// The caption is the newest CLI-reported change this app has logged,
    /// if any; it is not a claim that nothing has happened, only what the
    /// event log knows about.
    private var connectedCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(coordinator.currentHealth.tint)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(coordinator.headline)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if let latest = coordinator.eventLog.latestNetworkEvent {
                    HStack(spacing: 4) {
                        Text(latest.summary)
                        Text("·")
                        RelativeTimeText(date: latest.date)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .cardStyle()
    }

    private var isCaptivePortal: Bool {
        monitor.latest?.publicInfo.captivePortal == true
            || (monitor.latest?.status.rules.contains("CP-1") ?? false)
            || coordinator.alerts.active["captive-portal"] != nil
    }

    private var captivePortalCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 4) {
                Text("This network needs you to sign in")
                    .font(.callout).fontWeight(.semibold)
                Text("Open the sign-in page to access the internet.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Login Page") {
                    if let url = URL(string: "http://captive.apple.com/hotspot-detect.html") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .cardStyle()
    }

    private func banner(_ title: String, _ detail: String,
                        systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .cardStyle()
    }

    // MARK: - Current values (Live Instrument Gauges)

    private var currentValues: some View {
        HStack(alignment: .top, spacing: 10) {
            gaugeTile(
                icon: "network",
                iconColor: routerTint,
                label: "Router Ping",
                value: latestGateway,
                detail: routerDetail
            )

            gaugeTile(
                icon: "globe",
                iconColor: internetTint,
                label: "Internet (TCP)",
                value: latestInternet,
                detail: "Target connect time"
            )

            gaugeTile(
                icon: stability.icon,
                iconColor: stability.tint,
                label: "Stability",
                value: stability.label,
                detail: jitterDetail
            )

            gaugeTile(
                icon: "shield.checkerboard",
                iconColor: lossTint,
                label: "Packet Loss",
                value: latestLoss,
                detail: lossDetail
            )
        }
    }

    private func gaugeTile(
        icon: String,
        iconColor: Color,
        label: String,
        value: String,
        detail: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(iconColor)
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
            Text(detail)
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

    private var routerMs: Double? {
        monitor.latest?.gateway.rttAvgMs
    }

    private var latestGateway: String {
        guard let ms = routerMs else { return "—" }
        return String(format: "%.0f ms", ms)
    }

    private var routerTint: Color {
        guard let ms = routerMs else { return .secondary }
        if ms < 5 { return .green }
        if ms < 15 { return .yellow }
        return .red
    }

    private var routerDetail: String {
        guard let ms = routerMs else { return "No probe yet" }
        if ms < 4 { return "Normal local link" }
        if ms < 15 { return "Moderate latency" }
        return "High router ping"
    }

    private var internetMsValue: Double? {
        guard let sample = monitor.latest else { return nil }
        return Self.internetMs(sample)
    }

    private var latestInternet: String {
        guard let ms = internetMsValue else { return "—" }
        return String(format: "%.0f ms", ms)
    }

    private var internetTint: Color {
        guard let ms = internetMsValue else { return .secondary }
        if ms < 40 { return .green }
        if ms < 100 { return .yellow }
        return .red
    }

    private var currentJitter: Double? {
        if let live = monitor.latest?.liveJitterMs { return live }
        return MonitorSeries.movingJitter(samples: monitor.recent)
    }

    private var stability: ConnectionStability {
        let rtt = monitor.latest?.internet.rttAvgMs ?? monitor.latest?.gateway.rttAvgMs
        let loss = monitor.latest?.internet.lossPct ?? monitor.latest?.gateway.lossPct
        return ConnectionStability.evaluate(rtt: rtt, jitter: currentJitter, loss: loss)
    }

    private var jitterDetail: String {
        if let j = currentJitter {
            return String(format: "±%.1f ms jitter", j)
        }
        return stability.description
    }

    private var currentLossPct: Double? {
        monitor.latest?.gateway.lossPct
    }

    private var latestLoss: String {
        guard let l = currentLossPct else { return "—" }
        return String(format: "%.0f%%", l)
    }

    private var lossTint: Color {
        guard let l = currentLossPct else { return .secondary }
        if l == 0 { return .green }
        if l <= 2.0 { return .yellow }
        return .red
    }

    private var lossDetail: String {
        guard let l = currentLossPct else { return "Measuring" }
        if l == 0 { return "0 drops" }
        if l <= 2.0 { return "Minor loss" }
        return "Frequent drops"
    }

    /// The cadence the stream reports about itself, plus the tier it is on.
    /// "degraded" is the monitor's own word for its faster tier and carries
    /// no verdict of this app's.
    private var cadenceLabel: String {
        guard let status = monitor.latest?.status, let cadence = status.cadenceS else {
            return monitor.isRunning ? "starting…" : "stopped"
        }
        if monitor.isBursting { return "every \(cadence)s · test" }
        return status.degraded ? "every \(cadence)s · degraded" : "every \(cadence)s"
    }

    /// The monitor has no ICMP probe past the gateway; its reading on the
    /// internet is how long a TCP connection to a well-known host takes to
    /// open. The fastest of the targets, because a single slow *host* is a
    /// fact about that host, not about the link.
    private static func internetMs(_ sample: MonitorSample) -> Double? {
        sample.tcp.targets.filter(\.ok).compactMap(\.elapsedMs).min()
    }

    /// "Currently: host1, host2" — which hosts the medium tier is actually
    /// probing right now, separated out from the subtitle so the subtitle
    /// itself can be catalog prose (a fixed sentence about the
    /// *measurement*) rather than a sentence that has to be rebuilt around
    /// live data. Same host-naming logic the old inline subtitle used:
    /// named hosts when the latest sample has them, else the generic
    /// "well-known hosts".
    private var internetHostsCaption: String {
        let hosts = monitor.latest?.tcp.targets.compactMap(\.host) ?? []
        let named = hosts.isEmpty ? "well-known hosts" : hosts.joined(separator: ", ")
        return "Currently: \(named)"
    }

    private static let routerSubtitleFallback = "Gateway ping, every cycle of the fast tier."
    private static let internetSubtitleFallback =
        "Time to open a TCP connection to well-known hosts. Measured on the medium tier, so it is sparser than the router line."
    private static let lossSubtitleFallback = "Share of the gateway ping's packets that got no reply."

    /// The catalog's own `help` text for a `monitor_*` glossary key,
    /// verbatim, or the byte-for-byte fallback above when the catalog
    /// hasn't loaded, predates schema `4`, or doesn't recognise the key.
    private func subtitle(catalogKey: String, fallback: String) -> String {
        guard let help = coordinator.rulesCatalog.catalog?.metric(catalogKey)?.help,
              !help.isEmpty else { return fallback }
        return help
    }

    // MARK: - Charts

    @ViewBuilder
    private func chart(title: String, titleHelpKey: String, subtitle: String,
                       caption: String? = nil,
                       series: MonitorSeries.Result, absent: String,
                       unit: String,
                       advice: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                Text(title).font(.headline)
                HelpHint(key: titleHelpKey)
                Text(sampleLabel(series.points.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                Spacer()
                Text("Last 60m")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Text(subtitle).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let caption {
                Text(caption).font(.caption2).foregroundStyle(.tertiary)
            }

            if series.isEmpty {
                empty(absent)
            } else {
                LiveChart(series: series, unit: unit)

                HStack {
                    if let advice {
                        Label(advice, systemImage: "info.circle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !series.gaps.isEmpty {
                        Text(gapNote(series.gaps.count))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
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

    private func empty(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(text, systemImage: "waveform.path.ecg")
                .font(.callout)
            Text(appSettings.monitoringEnabled
                 ? "Samples appear here as the monitor takes them — the first one lands within a cycle."
                 : "Monitoring is off, so nothing is being sampled.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 160, alignment: .leading)
        .padding(14)
        .cardStyle()
    }

    private func gapNote(_ count: Int) -> String {
        let plural = count == 1 ? "1 gap" : "\(count) gaps"
        return "\(plural) — the monitor stops sampling while a check runs and while your Mac or display sleeps. Nothing was measured in the shaded stretches."
    }

    private func sampleLabel(_ count: Int) -> String {
        switch count {
        case 0:  return "no samples"
        case 1:  return "1 sample"
        default: return "\(count) samples"
        }
    }
}

/// The chart body of `LiveView`'s panels, with a hover readout.
///
/// Extracted from `LiveView.chart(...)` so it can own its own selection
/// state — one `@State` per panel, rather than one shared across three
/// charts that would cross-talk. Hovering (or dragging) anywhere along the
/// x-axis snaps a highlight to the nearest measured point and shows its
/// value and timestamp; moving off the chart clears it. The highlight is a
/// larger white point mark drawn over the accent one, so it reads against
/// any chart background.
struct LiveChart: View {
    let series: MonitorSeries.Result
    let unit: String
    @State private var selectedDate: Date?

    /// Nearest measured point to the cursor's x, or nil when the cursor is
    /// off the chart. O(points) on each move — the window is bounded to one
    /// hour, which is at most a few hundred samples, so the linear scan is
    /// cheaper than maintaining an index would be.
    private var hovered: MonitorSeries.Point? {
        guard let selectedDate else { return nil }
        return series.points.min(by: {
            abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate))
        })
    }

    var body: some View {
        Chart {
            // Shaded rather than merely blank, because "the line stops
            // here" and "the value went off the top" look alike at a glance.
            ForEach(series.gaps) { gap in
                RectangleMark(xStart: .value("From", gap.start),
                              xEnd: .value("To", gap.end))
                    .foregroundStyle(.quaternary.opacity(0.5))
            }
            // One series per segment, so no line is drawn across a stretch
            // where nothing was measured.
            ForEach(Array(series.segments.enumerated()), id: \.offset) { index, segment in
                ForEach(segment) { point in
                    LineMark(x: .value("Time", point.date),
                             y: .value("Value", point.value),
                             series: .value("segment", index))
                        .foregroundStyle(Color.accentColor)
                    PointMark(x: .value("Time", point.date),
                              y: .value("Value", point.value))
                        .foregroundStyle(Color.accentColor)
                        .symbolSize(segment.count > 120 ? 4 : 14)
                }
            }
            if let hovered {
                PointMark(x: .value("Time", hovered.date),
                          y: .value("Value", hovered.value))
                    .foregroundStyle(.white)
                    .symbolSize(40)
                    .annotation(position: .top, spacing: 4) {
                        HoverLabel(value: hovered.value, unit: unit, date: hovered.date)
                    }
            }
        }
        .chartYAxis { AxisMarks(position: .leading) }
        .chartXSelection(value: $selectedDate)
        .frame(height: 180)
    }
}

/// The floating readout above the hovered point: value with unit, and the
/// wall-clock time it was measured. Kept compact so it does not overrun the
/// chart's top margin on the narrow panels.
struct HoverLabel: View {
    let value: Double
    let unit: String
    let date: Date

    var body: some View {
        VStack(spacing: 1) {
            Text(String(format: "%.0f %@", value, unit))
                .font(.caption.weight(.semibold))
                .monospacedDigit()
            Text(date.formatted(date: .omitted, time: .standard))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
    }
}