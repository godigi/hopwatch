import SwiftUI

struct NetworkDetailCard: View {
    let memory: NetworkMemory
    let comparison: NetworkComparison?
    var showHeader: Bool
    var showCardTitle: Bool

    init(memory: NetworkMemory, comparison: NetworkComparison? = nil, showHeader: Bool = true, showCardTitle: Bool = false) {
        self.memory = memory
        self.comparison = comparison
        self.showHeader = showHeader
        self.showCardTitle = showCardTitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header if enabled
            if showHeader {
                headerRow
            } else if showCardTitle {
                cardTitleRow
            }

            // Performance metrics grid
            metricsGrid

            // Today vs Typical comparison if available
            if let comp = comparison {
                Divider()
                todayVsTypicalSection(comp)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                )
        )
    }

    private var cardTitleRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.xyaxis.line")
                .foregroundStyle(.blue)
                .font(.system(size: 13, weight: .semibold))
            Text("Typical Performance Baseline")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if let last = memory.lastSeenDate {
                Text("Last seen \(RelativeTime.string(from: last))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var headerRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "memorychip")
                    .foregroundStyle(.blue)
                    .font(.system(size: 14, weight: .semibold))
                Text("Network Memory")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let last = memory.lastSeenDate {
                    Text("Last seen \(RelativeTime.string(from: last))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Text(memory.displayName)
                .font(.title3.weight(.bold))

            if !memory.gateways.isEmpty || !memory.isps.isEmpty {
                Text([memory.gateways.joined(separator: ", "),
                      memory.isps.joined(separator: ", ")]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var metricsGrid: some View {
        HStack(alignment: .top, spacing: 12) {
            // Throughput
            metricTile(
                icon: "arrow.up.arrow.down",
                iconColor: .blue,
                label: "Throughput",
                primary: speedDisplay,
                secondary: peakSpeedDisplay
            )

            // Latency & Jitter
            metricTile(
                icon: "gauge.with.needle",
                iconColor: .purple,
                label: "Latency & Jitter",
                primary: latencyDisplay,
                secondary: jitterDisplay
            )

            // Reliability
            metricTile(
                icon: "shield.checkerboard",
                iconColor: reliabilityTint,
                label: "Reliability",
                primary: reliabilityDisplay,
                secondary: "\(memory.checkCount) checks"
            )
        }
    }

    private func metricTile(
        icon: String,
        iconColor: Color,
        label: String,
        primary: String,
        secondary: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(iconColor)
                Text(label)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            Text(primary)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .lineLimit(1)
            if let sec = secondary {
                Text(sec)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
                )
        )
    }

    private func todayVsTypicalSection(_ comp: NetworkComparison) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.swap")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue)
                Text("Today vs Typical for this network")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text("Live Comparison")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.blue.opacity(0.12), in: Capsule())
            }

            HStack(spacing: 10) {
                if let curGW = comp.currentGatewayLatencyMs {
                    comparisonChip(
                        icon: "gauge.with.needle",
                        title: "Latency",
                        value: String(format: "%.0f ms", curGW),
                        verdict: comp.gatewayLatencyVerdict,
                        detail: latencyDeltaText(comp)
                    )
                }

                if let curLoss = comp.currentLossPct {
                    comparisonChip(
                        icon: "antenna.radiowaves.left.and.right",
                        title: "Loss",
                        value: String(format: "%.0f%%", curLoss),
                        verdict: comp.lossVerdict,
                        detail: curLoss == 0 ? "Clean link" : "Loss detected"
                    )
                }

                if let curDown = comp.currentDownMbps {
                    comparisonChip(
                        icon: "arrow.down.circle",
                        title: "Download",
                        value: String(format: "%.0f Mbps", curDown),
                        verdict: comp.downSpeedVerdict ?? .normal,
                        detail: speedRatioText(comp)
                    )
                }
            }
        }
    }

    private func comparisonChip(
        icon: String,
        title: String,
        value: String,
        verdict: NetworkComparison.MetricVerdict,
        detail: String?
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: verdictIcon(for: verdict, defaultIcon: icon))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint(for: verdict))

            VStack(alignment: .leading, spacing: 1) {
                Text("\(title): \(value)")
                    .font(.caption2.weight(.medium))
                if let d = detail {
                    Text(d)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(tint(for: verdict))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(tint(for: verdict).opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(tint(for: verdict).opacity(0.2), lineWidth: 1)
                )
        )
    }

    private func verdictIcon(for verdict: NetworkComparison.MetricVerdict, defaultIcon: String) -> String {
        switch verdict {
        case .faster:   return "arrow.up.right.circle.fill"
        case .normal:   return "checkmark.circle.fill"
        case .slower:   return "arrow.down.right.circle.fill"
        case .degraded: return "exclamationmark.triangle.fill"
        }
    }

    private func tint(for verdict: NetworkComparison.MetricVerdict) -> Color {
        switch verdict {
        case .faster:   return .green
        case .normal:   return .blue
        case .slower:   return .orange
        case .degraded: return .red
        }
    }

    private func latencyDeltaText(_ comp: NetworkComparison) -> String? {
        guard let delta = comp.gatewayLatencyDeltaMs else { return nil }
        let rounded = abs(round(delta))
        if delta <= -3 { return "\(Int(rounded)) ms faster" }
        if delta >= 5 { return "\(Int(rounded)) ms slower" }
        return "Typical"
    }

    private func speedRatioText(_ comp: NetworkComparison) -> String? {
        guard let cur = comp.currentDownMbps, let base = comp.baselineDownMbps, base > 0 else { return nil }
        let pct = Int(round((cur / base) * 100))
        return "\(pct)% of typical"
    }

    // Displays
    private var speedDisplay: String {
        if let down = memory.typicalDownMbps {
            if let up = memory.typicalUpMbps {
                return String(format: "%.0f / %.0f Mbps", down, up)
            }
            return String(format: "%.0f Mbps", down)
        }
        return "Unmeasured"
    }

    private var peakSpeedDisplay: String? {
        if let peak = memory.peakDownMbps, let typical = memory.typicalDownMbps, peak > typical {
            return String(format: "Peak: %.0f Mbps", peak)
        }
        return nil
    }

    private var latencyDisplay: String {
        if let lat = memory.typicalGatewayLatencyMs {
            return String(format: "%.1f ms", lat)
        }
        if let lat = memory.typicalInternetLatencyMs {
            return String(format: "%.1f ms (net)", lat)
        }
        return "—"
    }

    private var jitterDisplay: String? {
        if let j = memory.typicalGatewayJitterMs {
            return String(format: "±%.1f ms jitter", j)
        }
        return nil
    }

    private var reliabilityDisplay: String {
        if let rel = memory.reliabilityPercent {
            return String(format: "%.0f%%", rel)
        }
        return "—"
    }

    private var reliabilityTint: Color {
        switch memory.reliabilityGrade {
        case "Excellent", "Good": return .green
        case "Fair":              return .orange
        default:                  return .red
        }
    }
}
