import SwiftUI
import AppKit

/// Building blocks for the dropdown's fixed sections. Dumb views over
/// CLI-sourced values: anything resembling a verdict arrived here as a
/// rule ID, a severity, or CLI prose.

// MARK: - Alert stage card

/// The dropdown's stage card for an alert that has crossed its dwell.
///
/// Lives here rather than inline in `DropdownView` so the `--verify`
/// harness can render *this exact view* for each severity instead of a
/// hand-maintained stand-in — the previous snapshot only ever drew the
/// critical case, which is precisely why every alert wearing critical-red
/// went unnoticed.
struct AlertStageCard: View {
    let alert: StageResolver.AlertSnapshot
    /// How many *other* alerts are active. Folded into the button's label
    /// rather than shown as a second caption: one more active alert is a
    /// fact about this button's destination, not a second thing competing
    /// for the attention the worst alert already has.
    var moreCount: Int = 0
    /// Nil where the card is already at the destination the button would
    /// navigate to — Activity's "Active now" list renders the same card and
    /// a "See all alerts" link pointing at itself would be furniture.
    var onOpen: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: look.icon)
                    .foregroundStyle(look.tint)
                Text(alert.title)
                    .font(.callout).fontWeight(.semibold)
                    .lineLimit(2)
            }
            // CLI prose verbatim — the interim body until a scan enriches
            // it, then diagnosis[].summary.
            if !alert.body.isEmpty {
                Text(alert.body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(attribution)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                // "See all alerts", not "See full report": the destination
                // is the Activity view, which lists what is firing now and
                // the change history behind it. It is not the report card
                // — that lives on Home — and a button promising "+2" more
                // findings has to land somewhere those two are actually
                // listed.
                if let onOpen {
                    Button(moreCount > 0 ? "See all alerts (+\(moreCount))" : "See all alerts",
                           action: onOpen)
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
        .padding(Theme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(look.tint.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    /// Icon and tint from the CLI's own severity for the firing rule.
    ///
    /// The `rules.isEmpty` branch is load-bearing: rank 0 means two
    /// different things, and only one of them is "not serious". The four
    /// event-driven alerts (VPN dropped, public IP changed, captive
    /// portal, different network) carry no rule *by construction* and are
    /// genuinely informational. A rule-backed alert can also rank 0 —
    /// transiently, before the rules catalog finishes loading, or for a
    /// rule this build has never heard of — and there the safe reading is
    /// the severe one, so it keeps the red it has always had.
    private var look: (icon: String, tint: Color) {
        if alert.rules.isEmpty { return ("info.circle.fill", .blue) }
        switch alert.severityRank {
        case 3:  return ("exclamationmark.triangle.fill", .red)
        case 2:  return ("exclamationmark.triangle", .orange)
        case 1:  return ("info.circle.fill", .blue)
        default: return ("exclamationmark.triangle.fill", .red)
        }
    }

    /// "rule G2 · 3m ago". Omits the rule segment cleanly for the alerts
    /// that carry none, rather than printing "rule  · 3m ago".
    private var attribution: String {
        guard let rule = alert.rules.sorted().first else {
            return RelativeTime.string(from: alert.raisedAt)
        }
        return "rule \(rule) · \(RelativeTime.string(from: alert.raisedAt))"
    }
}

// MARK: - Instrument grid cell

struct InstrumentCell: View {
    let label: String
    let value: String
    var unit: String? = nil
    var tint: Color = .primary

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9))
                .textCase(.uppercase)
                .kerning(0.5)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let unit {
                Text(unit)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Location cell (flag; hover reveals IP; click copies)

struct LocationCell: View {
    let countryISO: String?
    let publicIP: String?

    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        VStack(spacing: 2) {
            Text("Location")
                .font(.system(size: 9))
                .textCase(.uppercase)
                .kerning(0.5)
                .foregroundStyle(.secondary)
            Text(Flag.emoji(forISOCode: countryISO) ?? "🌐")
                .font(.system(size: 15))
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { copyIP() }
        .overlay(alignment: .top) {
            if hovering, let publicIP {
                Text(copied ? "Copied" : "\(publicIP) · click to copy")
                    .font(Theme.Font.compactMonospace)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.regularMaterial,
                                in: RoundedRectangle(cornerRadius: 6))
                    .fixedSize()
                    .offset(y: -26)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .help(publicIP == nil ? "Location unknown" : "Click to copy your public IP")
        .accessibilityLabel("Location" + (countryISO.map { ", \($0)" } ?? ", unknown"))
        .accessibilityAction(named: "Copy public IP") { copyIP() }
    }

    private func copyIP() {
        guard let publicIP else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(publicIP, forType: .string)
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
    }
}

// MARK: - Heartbeat strip

/// A thin live sparkline of fast-tier internet-side RTT. Its job is to
/// prove monitoring is alive, not to be read precisely — Live has the real
/// charts.
struct HeartbeatStrip: View {
    let samples: [MonitorSample]
    var flatlined = false

    private var points: [Double] {
        samples.suffix(60).compactMap { $0.internet.rttAvgMs }
    }

    var body: some View {
        Canvas { context, size in
            let values = flatlined ? [] : points
            guard values.count > 1 else {
                var line = Path()
                line.move(to: CGPoint(x: 0, y: size.height / 2))
                line.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                context.stroke(line, with: .color(.secondary.opacity(0.4)),
                               lineWidth: 1)
                return
            }
            let maxV = max(values.max() ?? 1, 1)
            let minV = values.min() ?? 0
            let span = max(maxV - minV, 1)
            var path = Path()
            for (i, v) in values.enumerated() {
                let x = size.width * CGFloat(i) / CGFloat(values.count - 1)
                let y = size.height - size.height *
                    CGFloat((v - minV) / span) * 0.8 - size.height * 0.1
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(path, with: .color(.green.opacity(0.7)),
                           lineWidth: 1)
        }
        .frame(height: 12)
        .background(.quaternary.opacity(Theme.cardOpacity),
                    in: RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Event row

struct EventRow: View {
    let event: NetworkEvent

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: EventStyle.symbol(for: event.kind))
                .font(.system(size: 10))
                .foregroundStyle(EventStyle.tint(for: event.kind))
                .frame(width: 18, height: 18)
                .background(EventStyle.tint(for: event.kind).opacity(0.12),
                            in: Circle())
            Text(event.summary)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            // Not a plain `Text(RelativeTime.string(...))`: see
            // `RelativeTimeText`'s header for why a static leaf view like
            // this row freezes at whatever age it first rendered otherwise.
            RelativeTimeText(date: event.date)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .layoutPriority(1)
        }
    }
}

// MARK: - Kind → presentation mapping (identity, not judgment)

enum EventStyle {
    static func symbol(for kind: String) -> String {
        switch kind {
        case "vpn-connected", "vpn-disconnected", "vpn-name-changed":
            return "lock.fill"
        case "public-ip-changed", "country-changed", "isp-changed":
            return "globe"
        case "wifi-network-changed", "wifi-roamed":
            return "wifi"
        case "interface-changed":
            return "cable.connector"
        case "rule-fired", "alert":
            return "exclamationmark.triangle.fill"
        case "rule-cleared":
            return "checkmark.circle.fill"
        default:
            return "circle.fill"
        }
    }

    static func tint(for kind: String) -> Color {
        switch kind {
        case "rule-fired", "alert": return .red
        case "rule-cleared": return .green
        case "vpn-disconnected": return .orange
        default: return .secondary
        }
    }
}
