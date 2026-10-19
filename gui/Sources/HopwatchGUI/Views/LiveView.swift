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
        return coordinator.currentSamples.filter { $0.timestamp >= cutoff }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                purposeSubtitle
                stateBanner
                currentValues
                let samples = samples
                chart(title: "Internet round-trip",
                      titleHelpKey: "internet",
                      subtitle: "Fast-tier ping to core internet targets (1.1.1.1, 8.8.8.8) every cycle.",
                      caption: internetHostsCaption,
                      series: MonitorSeries.build(
                          samples,
                          tier: "fast",
                          isDrop: { sample in
                              !EffectiveLoss.filtering(sample: sample).internetLeg
                                  && ((sample.internet.lossPct ?? 0) >= 100 || sample.internet.rttAvgMs == nil)
                          },
                          value: { sample in
                              PingReadout.internetSeriesValue(for: sample)
                                  ?? (EffectiveLoss.filtering(sample: sample).internetLeg ? Self.internetMs(sample) : nil)
                          }
                      ),
                      emptyTitle: samples.isEmpty ? "Measuring internet round-trip…" : "All internet ping probes failed or timed out",
                      emptySubtitle: samples.isEmpty
                          ? "Samples appear here as the monitor takes them — the first one lands within seconds."
                          : "No response from core internet targets in the last hour. Check your router, modem, or ISP uplink.",
                      emptyIcon: samples.isEmpty ? "waveform.path.ecg" : "exclamationmark.triangle.fill",
                      unit: "ms",
                      advice: "Measures core internet targets. Spikes or dropped pings with a flat router line point to ISP congestion.")

                chart(title: "Router round-trip",
                      titleHelpKey: "router",
                      subtitle: subtitle(catalogKey: "monitor_gateway_rtt",
                                        fallback: Self.routerSubtitleFallback),
                      series: MonitorSeries.build(
                          samples,
                          tier: "fast",
                          isDrop: { sample in
                              !EffectiveLoss.filtering(sample: sample).gatewayLeg
                                  && ((sample.gateway.lossPct ?? 0) >= 100 || sample.gateway.rttAvgMs == nil)
                          },
                          value: { sample in
                              EffectiveLoss.filtering(sample: sample).gatewayLeg ? nil : sample.gateway.rttAvgMs
                          }
                      ),
                      emptyTitle: routerIsFiltered
                          ? "Router declines ICMP ping requests"
                          : (samples.isEmpty ? "Measuring router round-trip…" : "Router is unresponsive to ping"),
                      emptySubtitle: routerIsFiltered
                          ? "Your router (\(routerGatewayIP)) drops ping packets by security policy. This is common on hotel, public, and secure networks. Internet traffic still flows through it."
                          : (samples.isEmpty
                             ? "Samples appear here as the monitor takes them — the first one lands within a cycle."
                             : "All gateway ping probes timed out in the last hour. Verify your connection to the local router."),
                      emptyIcon: routerIsFiltered ? "shield.slash.fill" : (samples.isEmpty ? "waveform.path.ecg" : "exclamationmark.triangle.fill"),
                      unit: "ms",
                      advice: "Flat lines near the bottom are ideal. Spikes indicate Wi-Fi noise or router load.")

                chart(title: "Packet loss",
                      titleHelpKey: "packet_loss",
                      subtitle: "Share of ping packets that got no reply, measured across internet and router legs.",
                      series: MonitorSeries.build(samples, tier: "fast") { sample in
                          let filtering = EffectiveLoss.filtering(sample: sample)
                          return EffectiveLoss.compute(
                              internetLoss: sample.internet.lossPct,
                              gatewayLoss: sample.gateway.lossPct,
                              filtering: filtering,
                              hasRecentRoam: false
                          )
                      },
                      emptyTitle: "No packet-loss measurement in the last hour.",
                      emptySubtitle: "Measurements appear here as the monitor takes them.",
                      emptyIcon: "waveform.path.ecg",
                      unit: "%",
                      advice: "0% loss is expected. Non-zero loss causes robotic audio, buffering, or dropped calls.")
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
    private var connectedHeadline: String {
        if coordinator.currentHealth == .healthy {
            return "All good — watching"
        }
        return coordinator.headline
    }

    private var connectedCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(coordinator.currentHealth.tint)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(connectedHeadline)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if let latest = coordinator.latestCurrentNetworkEvent {
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
        coordinator.liveSample?.publicInfo.captivePortal == true
            || (coordinator.liveSample?.status.rules.contains("CP-1") ?? false)
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
                label: "Internet Ping",
                value: latestInternet,
                detail: internetDetail
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

    /// With no link the newest sample has nothing to read, and a stale
    /// reading carried in it (or an older cycle's) must not be drawn as
    /// current. See `LinkState`.
    private var linkDown: Bool { coordinator.linkIsDown }

    private var activeSample: MonitorSample? {
        coordinator.liveSample ?? coordinator.monitor.latest
    }

    private var routerIsFiltered: Bool {
        EffectiveLoss.filtering(sample: activeSample).gatewayLeg
    }

    private var routerGatewayIP: String {
        activeSample?.link.gateway ?? "gateway"
    }

    private var routerMs: Double? {
        if linkDown || routerIsFiltered { return nil }
        return activeSample?.gateway.rttAvgMs
    }

    private var latestGateway: String {
        if linkDown { return "—" }
        if routerIsFiltered { return "Blocked" }
        guard let ms = routerMs else { return "—" }
        return String(format: "%.0f ms", ms)
    }

    private var routerTint: Color {
        if linkDown || routerIsFiltered { return .secondary }
        guard let ms = routerMs else {
            return samples.isEmpty ? .secondary : .red
        }
        if ms < 5 { return .green }
        if ms < 15 { return .yellow }
        return .red
    }

    private var routerDetail: String {
        if linkDown { return NoLinkCopy.nodeDetail }
        if routerIsFiltered { return "ICMP blocked by router" }
        guard let ms = routerMs else {
            if samples.isEmpty { return "Measuring…" }
            return "Unresponsive to ping"
        }
        if ms < 4 { return "Normal local link" }
        if ms < 15 { return "Moderate latency" }
        return "High router ping"
    }

    private var internetIsFiltered: Bool {
        EffectiveLoss.filtering(sample: activeSample).internetLeg
    }

    private var internetMsValue: Double? {
        if linkDown { return nil }
        guard let sample = activeSample else { return nil }
        if !internetIsFiltered, let rtt = sample.internet.rttAvgMs {
            return rtt
        }
        return Self.internetMs(sample)
    }

    private var isUsingTCPFallback: Bool {
        guard let sample = activeSample else { return false }
        return (internetIsFiltered || sample.internet.rttAvgMs == nil) && Self.internetMs(sample) != nil
    }

    private var latestInternet: String {
        if linkDown { return "—" }
        guard let ms = internetMsValue else {
            if samples.isEmpty { return "—" }
            if (activeSample?.internet.lossPct ?? 0) >= 100 {
                return "Failed"
            }
            return "—"
        }
        return String(format: "%.0f ms", ms)
    }

    private var internetTint: Color {
        if linkDown { return .secondary }
        guard let ms = internetMsValue else {
            return samples.isEmpty ? .secondary : .red
        }
        if ms < 40 { return .green }
        if ms < 100 { return .yellow }
        return .red
    }

    private var internetDetail: String {
        if linkDown { return NoLinkCopy.nodeDetail }
        guard let ms = internetMsValue else {
            if samples.isEmpty { return "Measuring…" }
            return "No ping response"
        }
        if isUsingTCPFallback {
            return "TCP connect time (ICMP blocked)"
        }
        if ms < 40 { return "Fast connection" }
        if ms < 100 { return "Acceptable latency" }
        return "Elevated ping"
    }

    private var currentJitter: Double? {
        coordinator.currentJitter
    }

    private var stability: ConnectionStability {
        coordinator.currentStability
    }

    private var jitterDetail: String {
        if let j = currentJitter {
            return String(format: "±%.1f ms jitter", j)
        }
        return stability.description
    }

    private var currentLossPct: Double? {
        coordinator.effectiveLoss
    }

    private var latestLoss: String {
        guard let l = currentLossPct else { return "—" }
        return LossFormatter.formatPct(l)
    }

    private var lossTint: Color {
        guard let l = currentLossPct else { return .secondary }
        if l == 0 { return .green }
        if l <= 2.0 { return .yellow }
        return .red
    }

    private var lossDetail: String {
        if linkDown { return NoLinkCopy.nodeDetail }
        guard let l = currentLossPct else { return "Measuring" }
        if l == 0 { return "0 drops" }
        if l < 1.0 { return "\(LossFormatter.formatPct(l)) loss" }
        if l <= 2.0 { return "Minor loss" }
        return "Frequent drops"
    }

    /// The cadence the stream reports about itself, plus the tier it is on.
    /// "degraded" is the monitor's own word for its faster tier and carries
    /// no verdict of this app's.
    private var cadenceLabel: String {
        guard let status = coordinator.liveSample?.status, let cadence = status.cadenceS else {
            return monitor.isRunning ? "starting…" : "stopped"
        }
        if monitor.isBursting { return "every \(cadence)s · test" }
        return status.degraded ? "every \(cadence)s · degraded" : "every \(cadence)s"
    }

    /// Fallback TCP connection time to a well-known host when ICMP is blocked.
    private static func internetMs(_ sample: MonitorSample) -> Double? {
        sample.tcp.targets.filter(\.ok).compactMap(\.elapsedMs).min()
    }

    private var internetHostsCaption: String {
        if internetIsFiltered {
            let hosts = activeSample?.tcp.targets.compactMap(\.host) ?? []
            let named = hosts.isEmpty ? "1.1.1.1, 8.8.8.8" : hosts.joined(separator: ", ")
            return "Currently (TCP): \(named)"
        }
        return "Targets: 1.1.1.1, 8.8.8.8"
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
                       series: MonitorSeries.Result,
                       emptyTitle: String,
                       emptySubtitle: String,
                       emptyIcon: String = "waveform.path.ecg",
                       unit: String,
                       advice: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                Text(title).font(.headline)
                HelpHint(key: titleHelpKey)
                sampleLabel(points: series.points.count, drops: series.drops.count)
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
                empty(title: emptyTitle, subtitle: emptySubtitle, systemImage: emptyIcon)
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

    private func empty(title: String, subtitle: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.callout)
            Text(appSettings.monitoringEnabled ? subtitle : "Monitoring is off, so nothing is being sampled.")
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

    private func sampleLabel(points: Int, drops: Int) -> some View {
        let countText: String
        switch points {
        case 0:  countText = "no samples"
        case 1:  countText = "1 sample"
        default: countText = "\(points) samples"
        }

        return HStack(spacing: 4) {
            Text(countText)
            if drops > 0 {
                Text("·")
                Text("\(drops) \(drops == 1 ? "drop" : "drops")")
                    .foregroundStyle(.red)
                    .fontWeight(.medium)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(Color.secondary.opacity(0.12), in: Capsule())
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

    private var hoveredDrop: MonitorSeries.Drop? {
        guard let selectedDate else { return nil }
        guard let nearest = series.drops.min(by: {
            abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate))
        }) else { return nil }
        let dropDistance = abs(nearest.date.timeIntervalSince(selectedDate))
        if dropDistance <= 20 {
            if let h = hovered {
                if dropDistance < abs(h.date.timeIntervalSince(selectedDate)) {
                    return nearest
                }
                return nil
            }
            return nearest
        }
        return nil
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
            ForEach(series.identifiedSegments) { segment in
                ForEach(segment.points) { point in
                    LineMark(x: .value("Time", point.date),
                             y: .value("Value", point.value),
                             series: .value("segment", segment.id.timeIntervalSinceReferenceDate))
                        .foregroundStyle(Color.accentColor)
                    PointMark(x: .value("Time", point.date),
                              y: .value("Value", point.value))
                        .foregroundStyle(Color.accentColor)
                        .symbolSize(segment.points.count > 120 ? 4 : 14)
                }
            }
            // Dropped / timed-out pings drawn with red markers
            ForEach(series.drops) { drop in
                RuleMark(x: .value("Time", drop.date))
                    .foregroundStyle(Color.red.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                PointMark(x: .value("Time", drop.date),
                          y: .value("Value", 0))
                    .foregroundStyle(Color.red)
                    .symbol(.cross)
                    .symbolSize(36)
            }
            if let hoveredDrop {
                PointMark(x: .value("Time", hoveredDrop.date),
                          y: .value("Value", 0))
                    .foregroundStyle(.red)
                    .symbol(.cross)
                    .symbolSize(60)
                    .annotation(position: .top, spacing: 4) {
                        HoverLabel(value: nil, unit: unit, text: "Packet dropped / timeout", date: hoveredDrop.date)
                    }
            } else if let hovered {
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
    let value: Double?
    let unit: String
    var text: String? = nil
    let date: Date

    var body: some View {
        VStack(spacing: 1) {
            if let text {
                Text(text)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
            } else if let value {
                Text(String(format: "%.0f %@", value, unit))
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
            }
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