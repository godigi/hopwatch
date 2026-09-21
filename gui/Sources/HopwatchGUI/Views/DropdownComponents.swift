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
    @Environment(HopwatchCoordinator.self) private var coordinator
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
    @Environment(HopwatchCoordinator.self) private var coordinator
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

// MARK: - Redesign Menu Components (hopwatch-menu.mockup.html)

struct AppBrandMark: View {
    var size: CGFloat = 32

    var body: some View {
        if let appIcon = NSApp.applicationIconImage {
            Image(nsImage: appIcon)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else if let bundleIcon = Bundle.main.image(forResource: "AppIcon") {
            Image(nsImage: bundleIcon)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.ColorToken.blue)
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: size * 0.55, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
        }
    }
}

struct MenuHeaderView: View {
    let statusPillText: String
    let statusPillColor: Color
    let onOpenSettings: () -> Void

    var body: some View {
        HStack {
            HStack(spacing: 8) {
                AppBrandMark(size: 28)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("Hopwatch")
                        .font(.system(size: 17, weight: .bold))
                        .kerning(-0.5)
                        .foregroundStyle(Theme.ColorToken.ink)
                    Text("v\(AppVersion.display)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.ColorToken.muted)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(statusPillColor)
                        .frame(width: 6, height: 6)
                    Text(statusPillText)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.ColorToken.ink)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Theme.ColorToken.neutralWash, in: Capsule())

                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.ColorToken.muted)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Settings")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 11)
    }
}

struct MenuStatusHeroView: View {
    let iconName: String
    let iconTint: Color
    let iconBackground: Color
    let headline: String
    let subtitle: String
    var isChecking: Bool = false
    var actionTitle: String? = nil
    var onAction: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.statusIcon)
                    .fill(iconBackground)
                    .frame(width: 30, height: 30)

                if isChecking {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: iconName)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(iconTint)
                }
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 4) {
                Text(headline)
                    .font(.system(size: 18, weight: .semibold))
                    .kerning(-0.45)
                    .foregroundStyle(Theme.ColorToken.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ColorToken.muted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let actionTitle, let onAction {
                    Button(actionTitle, action: onAction)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .padding(.top, 4)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .overlay(alignment: .top) {
            Divider().foregroundStyle(Theme.ColorToken.line)
        }
    }
}

struct ConnectionRouteView: View {
    let wifiReadingLabel: String
    let wifiReadingValue: String
    let wifiReadingTint: Color
    let macIcon: String
    let macStatusGood: Bool
    let macDetail: String

    let routerPingValue: String
    let routerPingTint: Color
    let routerStatusGood: Bool
    let routerDetail: String
    let routerWarn: Bool

    let internetPingValue: String
    let internetPingTint: Color
    let internetStatusGood: Bool
    let countryFlag: String?
    let countryName: String?
    let publicIP: String?
    let internetDetail: String
    let internetWarn: Bool

    let firstLinkLabel: String
    let secondLinkLabel: String

    let jitterMs: Double?
    let jitterWarn: Bool
    let jitterDescription: String

    let vpnActive: Bool
    let vpnName: String?
    let vpnFreshness: String

    let cadenceText: String

    var body: some View {
        VStack(spacing: 0) {
            // Meta header row
            HStack {
                Text("Your connection")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.ColorToken.muted)
                Spacer()
                Text(cadenceText)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.ColorToken.muted)
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 6)

            // 3-Hop Route
            ZStack(alignment: .top) {
                // Connecting dashed lines and labels
                GeometryReader { geo in
                    let w = geo.size.width
                    let x1 = w * (1.0 / 6.0)
                    let x2 = w * (3.0 / 6.0)
                    let x3 = w * (5.0 / 6.0)
                    let lineY: CGFloat = 85

                    // Hop 1 -> Hop 2 line
                    Path { path in
                        path.move(to: CGPoint(x: x1 + 28, y: lineY))
                        path.addLine(to: CGPoint(x: x2 - 28, y: lineY))
                    }
                    .stroke(
                        routerWarn ? Theme.ColorToken.amber : Theme.ColorToken.line,
                        style: StrokeStyle(lineWidth: 2, dash: [4, 4])
                    )

                    // Hop 2 -> Hop 3 line
                    Path { path in
                        path.move(to: CGPoint(x: x2 + 28, y: lineY))
                        path.addLine(to: CGPoint(x: x3 - 28, y: lineY))
                    }
                    .stroke(
                        internetWarn ? Theme.ColorToken.amber : Theme.ColorToken.line,
                        style: StrokeStyle(lineWidth: 2, dash: [4, 4])
                    )

                    // First link label
                    Text(firstLinkLabel)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.ColorToken.muted)
                        .position(x: (x1 + x2) / 2.0, y: lineY + 12)

                    // Second link label
                    Text(secondLinkLabel)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.ColorToken.muted)
                        .position(x: (x2 + x3) / 2.0, y: lineY + 12)
                }

                HStack(alignment: .top, spacing: 0) {
                    // Hop 1: This Mac
                    VStack(spacing: 4) {
                        VStack(spacing: 2) {
                            Text(wifiReadingLabel)
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.ColorToken.muted)
                            Text(wifiReadingValue)
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(wifiReadingTint)
                                .lineLimit(1)
                        }
                        .frame(height: 52)

                        hopNode(
                            icon: macIcon,
                            isWarning: false,
                            statusGood: macStatusGood,
                            flag: nil
                        )

                        Text("This Mac")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.ColorToken.ink)
                            .padding(.top, 6)

                        Text(macDetail)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.ColorToken.muted)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)

                    // Hop 2: Router
                    VStack(spacing: 4) {
                        VStack(spacing: 2) {
                            Text("Router ping")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.ColorToken.muted)
                            pingReadingText(routerPingValue, tint: routerPingTint)
                        }
                        .frame(height: 52)

                        hopNode(
                            icon: "network",
                            isWarning: routerWarn,
                            statusGood: routerStatusGood,
                            flag: nil
                        )

                        Text("Router")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.ColorToken.ink)
                            .padding(.top, 6)

                        Text(routerDetail)
                            .font(.system(size: 10))
                            .foregroundStyle(routerWarn ? Theme.ColorToken.amber : Theme.ColorToken.muted)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)

                    // Hop 3: Internet
                    VStack(spacing: 4) {
                        VStack(spacing: 2) {
                            Text("Internet ping")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.ColorToken.muted)
                            pingReadingText(internetPingValue, tint: internetPingTint)
                        }
                        .frame(height: 52)

                        hopNode(
                            icon: "globe",
                            isWarning: internetWarn,
                            statusGood: internetStatusGood,
                            flag: countryFlag
                        )

                        Text("Internet")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.ColorToken.ink)
                            .padding(.top, 6)

                        if let countryName, !countryName.isEmpty {
                            Text(countryName)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.ColorToken.ink)
                                .lineLimit(1)
                            Text("Public IP country")
                                .font(.system(size: 8))
                                .foregroundStyle(Theme.ColorToken.muted)
                        }

                        if internetWarn {
                            Text(internetDetail)
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.ColorToken.amber)
                                .lineLimit(1)
                        } else if countryName == nil {
                            Text(internetDetail)
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.ColorToken.muted)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            // Jitter line
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 12))
                        .foregroundStyle(jitterWarn ? Theme.ColorToken.amber : Theme.ColorToken.muted)
                    Text("Internet jitter")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ColorToken.muted)
                    if let jitter = jitterMs {
                        Text(String(format: "%.0f ms", jitter))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(jitterWarn ? Theme.ColorToken.amber : Theme.ColorToken.ink)
                    } else {
                        Text("—")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.ColorToken.muted)
                    }
                }
                Spacer()
                Text(jitterDescription)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.ColorToken.muted)
            }
            .padding(.top, 11)
            .padding(.horizontal, 4)
            .overlay(alignment: .top) {
                Divider().foregroundStyle(Theme.ColorToken.line)
            }

            // VPN context line
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(vpnActive ? Theme.ColorToken.blue : Theme.ColorToken.muted)
                    if vpnActive {
                        Text("VPN on")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.ColorToken.blue)
                        if let name = vpnName, !name.isEmpty {
                            Text("· \(name)")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.ColorToken.muted)
                        }
                    } else {
                        Text("VPN off")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.ColorToken.muted)
                    }
                }
                Spacer()
                Text(vpnFreshness)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.ColorToken.muted)
            }
            .padding(.top, 9)
            .padding(.horizontal, 4)
            .overlay(alignment: .top) {
                Divider().foregroundStyle(Theme.ColorToken.line)
            }
        }
        .padding(12)
        .background(Theme.ColorToken.cardBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.routeCard))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.routeCard)
                .strokeBorder(Theme.ColorToken.line, lineWidth: 1)
        )
    }

    private func pingReadingText(_ value: String, tint: Color) -> some View {
        let parts = value.split(separator: " ")
        return HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(parts.first.map(String.init) ?? value)
                .font(.system(size: 22, weight: .bold))
                .kerning(-0.5)
                .foregroundStyle(tint)
            if parts.count > 1 {
                Text(parts.dropFirst().joined(separator: " "))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.ColorToken.muted)
            }
        }
        .lineLimit(1)
    }

    private func hopNode(icon: String, isWarning: Bool, statusGood: Bool, flag: String?) -> some View {
        ZStack {
            Circle()
                .fill(isWarning ? Theme.ColorToken.amberWash : Theme.ColorToken.nodeBackground)
                .frame(width: 56, height: 56)
                .shadow(color: Color.black.opacity(0.04), radius: 3, y: 1)
                .overlay(
                    Circle()
                        .strokeBorder(isWarning ? Color(red: 0xe9/255.0, green: 0xc4/255.0, blue: 0x86/255.0) : Theme.ColorToken.line, lineWidth: 1)
                )

            Image(systemName: icon)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(isWarning ? Theme.ColorToken.amber : (statusGood ? Theme.ColorToken.green : Theme.ColorToken.muted))

            // Status badge bottom-right
            Circle()
                .fill(statusGood ? Theme.ColorToken.green : Theme.ColorToken.amber)
                .frame(width: 17, height: 17)
                .overlay(
                    Circle().strokeBorder(Color.white, lineWidth: 2)
                )
                .overlay(
                    Text(statusGood ? "✓" : "!")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(.white)
                )
                .offset(x: 20, y: 20)

            // Country flag badge top-right
            if let flag {
                Text(flag)
                    .font(.system(size: 14))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Theme.ColorToken.nodeBackground)
                            .shadow(color: Color.black.opacity(0.1), radius: 2, y: 1)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Theme.ColorToken.line, lineWidth: 1)
                    )
                    .offset(x: 21, y: -20)
            }
        }
        .frame(width: 56, height: 56)
    }
}

struct ExperienceGridView: View {
    let calls: ExperienceStatus
    let gaming: ExperienceStatus
    let streaming: ExperienceStatus

    struct ExperienceStatus {
        let label: String
        let tint: Color
        var metric: String? = nil

        init(label: String, tint: Color, metric: String? = nil) {
            self.label = label
            self.tint = tint
            self.metric = metric
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("What this feels like")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.ColorToken.ink)

            HStack(spacing: 0) {
                item(title: "Calls", icon: "video", status: calls)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Divider()
                    .frame(height: 32)
                    .padding(.horizontal, 8)

                item(title: "Gaming", icon: "gamecontroller", status: gaming)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Divider()
                    .frame(height: 32)
                    .padding(.horizontal, 8)

                item(title: "Streaming", icon: "play.rectangle", status: streaming)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 4)
    }

    private func item(title: String, icon: String, status: ExperienceStatus) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ColorToken.muted)
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ColorToken.muted)
            }

            Text(status.label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(status.tint)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            if let metric = status.metric {
                Text(metric)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.ColorToken.muted)
                    .lineLimit(1)
            }
        }
    }
}

struct MenuSpeedView: View {
    let downMbps: String
    let upMbps: String
    let meta: String

    var body: some View {
        HStack(alignment: .center) {
            HStack(spacing: 16) {
                HStack(spacing: 3) {
                    Text("↓ \(downMbps)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.ColorToken.ink)
                    Text("Mbps")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.ColorToken.muted)
                }
                HStack(spacing: 3) {
                    Text("↑ \(upMbps)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.ColorToken.ink)
                    Text("Mbps")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.ColorToken.muted)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("Last speed test")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.ColorToken.muted)
                Text(meta)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.ColorToken.ink)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .top) {
            Divider().foregroundStyle(Theme.ColorToken.line)
        }
        .overlay(alignment: .bottom) {
            Divider().foregroundStyle(Theme.ColorToken.line)
        }
    }
}

struct MenuActivitySnippetView: View {
    let event: ActivityEntry?
    let onOpenActivity: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Recent activity")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ColorToken.ink)
                Spacer()
                Button("View all") {
                    onOpenActivity()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.ColorToken.blue)
            }

            if let event {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(EventStyle.tint(for: event.kind))
                            .frame(width: 7, height: 7)
                        Text(event.summary)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.ColorToken.ink)
                            .lineLimit(1)
                        Spacer()
                        RelativeTimeText(date: event.latest)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.ColorToken.muted)
                    }
                    if let detail = event.detail {
                        Text(detail)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.ColorToken.muted)
                            .padding(.leading, 15)
                    }
                }
            } else {
                Text("No changes in the last 24 hours")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ColorToken.muted)
                    .padding(.vertical, 2)
            }
        }
        .padding(.vertical, 4)
    }
}

struct MenuActionsView: View {
    let isScanning: Bool
    let onOpenDashboard: () -> Void
    let onRunFullCheck: () -> Void
    let onCancelScan: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Button(action: onOpenDashboard) {
                HStack(spacing: 7) {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Open dashboard")
                        .font(.system(size: 12, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(Theme.ColorToken.blue, in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            if isScanning {
                Button(action: onCancelScan) {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Cancel check")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Theme.ColorToken.line, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            } else {
                Button(action: onRunFullCheck) {
                    HStack(spacing: 7) {
                        Image(systemName: "stethoscope")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.ColorToken.muted)
                        Text("Run full check")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.ColorToken.ink)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Theme.ColorToken.nodeBackground)
                            .shadow(color: Color.black.opacity(0.04), radius: 2, y: 1)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Theme.ColorToken.line, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct MenuFooterView: View {
    let networkName: String?
    let isWiFi: Bool
    let monitoringEnabled: Bool
    let onToggleMonitoring: () -> Void
    let onCopyReport: () -> Void
    let onCopySupport: () -> Void
    let onSaveMarkdown: () -> Void
    let onSaveJSON: () -> Void
    let onQuit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: isWiFi ? "wifi" : "cable.connector")
                    .font(.system(size: 11))
                Text(networkName ?? "DISCONNECTED")
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(Theme.ColorToken.muted)

            Spacer()

            HStack(spacing: 10) {
                Button(action: onToggleMonitoring) {
                    HStack(spacing: 4) {
                        Image(systemName: monitoringEnabled ? "pause.fill" : "play.fill")
                            .font(.system(size: 9))
                        Text(monitoringEnabled ? "Pause" : "Resume")
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(Theme.ColorToken.muted)
                }
                .buttonStyle(.plain)

                Menu {
                    Button("Copy Redacted Report", action: onCopyReport)
                    Button("Copy for Support", action: onCopySupport)
                    Divider()
                    Button("Save as Markdown (.md)…", action: onSaveMarkdown)
                    Button("Save Redacted JSON (.json)…", action: onSaveJSON)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ColorToken.muted)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Text("v\(AppVersion.display)")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.ColorToken.muted.opacity(0.8))

                Button("Quit", action: onQuit)
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.ColorToken.muted)
            }
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 10)
        .background(Theme.ColorToken.footerBackground)
        .overlay(alignment: .top) {
            Divider().foregroundStyle(Theme.ColorToken.line)
        }
    }
}

