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
    var actionButtonTitle: String? = nil
    var onAction: (() -> Void)? = nil

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
            if let actionButtonTitle, let onAction {
                Button(actionButtonTitle, action: onAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.vertical, 2)
            } else if isCaptivePortal {
                Button("Open Login Page") {
                    if let url = URL(string: "http://captive.apple.com/hotspot-detect.html") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .padding(.vertical, 2)
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

    private var isCaptivePortal: Bool {
        alert.id == "captive-portal"
            || alert.rules.contains("CP-1")
            || alert.title.localizedCaseInsensitiveContains("sign in")
            || alert.title.localizedCaseInsensitiveContains("captive")
    }
}

// MARK: - Instrument grid cell

struct InstrumentCell: View {
    let label: String
    let value: String
    var unit: String? = nil
    var tint: Color = .primary
    var help: String? = nil

    private var resolvedHelp: String {
        if let help, !help.isEmpty { return help }
        return MetricGlossary.entry(for: label)?.fullHelp ?? ""
    }

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
        .help(resolvedHelp)
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
    @Environment(NetdiagCoordinator.self) private var coordinator
    let event: NetworkEvent

    private var tint: Color {
        EventStyle.tint(for: event.kind,
                        severity: event.ruleID.flatMap {
                            coordinator.rulesCatalog.catalog?[$0]?.severity
                        })
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: EventStyle.symbol(for: event.kind))
                .font(.system(size: 10))
                .foregroundStyle(tint)
                .frame(width: 18, height: 18)
                .background(tint.opacity(0.12), in: Circle())
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

// MARK: - Activity row

/// One folded episode, for the Activity screen.
///
/// The sibling of `EventRow`, not a replacement: the dropdown's teaser
/// shows the last few *transitions* on a 360pt panel, where "it just
/// cleared" is the useful thing. A full-screen history is read differently
/// — the question there is how long and how often, which is what
/// `ActivityEntry` folds for and this renders.
struct ActivityRow: View {
    @Environment(NetdiagCoordinator.self) private var coordinator
    let entry: ActivityEntry

    private var severity: String? {
        entry.ruleID.flatMap { coordinator.rulesCatalog.catalog?[$0]?.severity }
    }

    private var tint: Color {
        EventStyle.tint(for: entry.kind, severity: severity)
    }

    private var tagText: String? {
        if entry.kind == "rule-cleared" { return "Resolved" }
        if let sev = severity {
            switch sev {
            case "warn", "warning": return "Warning"
            case "critical": return "Disruption"
            case "info": return "Notice"
            default: return nil
            }
        }
        if entry.kind == "vpn-disconnected" { return "Warning" }
        if entry.kind.hasPrefix("vpn-") || entry.kind.hasPrefix("wifi-") { return "Change" }
        return nil
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: EventStyle.symbol(for: entry.kind))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(tint.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.summary)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if let tag = tagText {
                        Text(tag)
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(tint.opacity(0.15), in: Capsule())
                            .foregroundStyle(tint)
                    }
                }

                if let detail = entry.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if entry.notified {
                Image(systemName: "bell.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .help("You were notified about this")
            }

            Spacer(minLength: 8)

            RelativeTimeText(date: entry.latest)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .layoutPriority(1)
        }
        .padding(.vertical, 3)
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

    /// `severity` is the CLI's own word for the rule behind this event
    /// (`RulesCatalog`'s `severity`), or nil when the event has no rule or
    /// the catalog has not loaded.
    ///
    /// Keying colour on `kind` alone — which is all this did — painted
    /// every `rule-fired` critical-red, so a warn-level "Minor packet loss
    /// to router" was indistinguishable from a critical "No network
    /// connection at all", and a history of the former read as a history
    /// of outages. This is the same defect `VerifyMode`'s alert-attribution
    /// note records fixing for `AlertStageCard`; the timeline rows kept it.
    ///
    /// An unknown severity stays red on purpose. The catalog resolving late
    /// is the common case at launch, and quietly greying out a real fault
    /// until a fetch completes is the worse of the two errors.
    static func tint(for kind: String, severity: String? = nil) -> Color {
        switch kind {
        case "rule-fired", "alert":
            switch severity {
            case "warn", "warning": return .orange
            case "info": return .blue
            default: return .red
            }
        case "rule-cleared": return .green
        case "vpn-disconnected": return .orange
        default: return .secondary
        }
    }
}
