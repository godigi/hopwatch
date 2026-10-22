import SwiftUI
import AppKit
import CoreWLAN
import UniformTypeIdentifiers

/// Layer two of four: the dropdown status menu (redesigned per docs/design/hopwatch-menu.mockup.html).
///
/// Complete information in a cohesive, compact visual hierarchy:
/// 1. Header: Brand mark, title, status pill ("Watching" / "Degraded" / "Paused"), settings gear.
/// 2. Update banner: Conditional non-intrusive update bar when an update is available or downloading.
/// 3. Status hero: Bold headline and everyday consequence ("Connection is unstable", "All good — watching").
/// 4. Connection route: The 3-hop route (This Mac → Router → Internet with country flag and dual packet loss readings).
/// 5. Experience grid: 3-column "What this feels like" summary (Calls, Gaming, Streaming).
/// 6. Speed summary: Download & upload metrics with age and before-VPN context.
/// 7. Recent activity: Teaser of the most recent network incident with "View all" link to Activity.
/// 8. Primary actions: "Open dashboard" and "Run full check".
/// 9. Footer: SSID/interface name, Pause/Resume monitoring, Share diagnostics menu, Quit.
struct DropdownView: View {
    @Environment(HopwatchCoordinator.self) private var coordinator
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.openWindow) private var openWindow

    @State private var coreWLANRSSI: Int?
    @State private var didShare = false
    @State private var shareFeedback: String?

    var body: some View {
        VStack(spacing: 0) {
            headerSection

            updateBanner

            if let feedback = shareFeedback {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.ColorToken.green)
                        .font(.system(size: 11))
                    Text(feedback)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.ColorToken.ink)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Theme.ColorToken.nodeBackground)
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(Theme.ColorToken.line, lineWidth: 1))
                .shadow(color: Color.black.opacity(0.08), radius: 3, y: 1)
                .padding(.vertical, 4)
            }

            VStack(spacing: 12) {
                statusHeroSection

                connectionRouteSection

                heartbeatSection

                experienceSection

                speedSection

                activitySection

                actionsSection
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 15)

            footerSection
        }
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.ColorToken.dropdownBackground)
        .background(DropdownWindowAnchor())
        .contextMenu {
            Button("Copy Redacted Report") { copyShareableReport() }.disabled(!coordinator.supportsShare)
            Button("Copy for Support") { copySupportSummary() }
            Divider()
            Button("Save as Markdown (.md)…") { saveMarkdownReport() }.disabled(!coordinator.supportsShare)
            Button("Save Redacted JSON (.json)…") { saveJSONReport() }.disabled(!coordinator.supportsShare)
        }
        .task {
            coordinator.refreshLocationState()
            if coordinator.history.document.runs.isEmpty {
                await coordinator.history.load()
            }
        }
        .task(id: coordinator.liveSample?.seq) {
            refreshCoreWLANRSSIIfNeeded()
        }
        .onAppear {
            coordinator.refreshLocationState()
            if appSettings.monitoringEnabled && !coordinator.heartbeat.isRunning && !coordinator.heartbeat.isPaused {
                coordinator.heartbeat.start()
            }
        }
    }

    // MARK: - 1. Header

    private var headerSection: some View {
        MenuHeaderView(
            statusPillText: statusPillText,
            statusPillColor: statusPillColor,
            onOpenSettings: {
                coordinator.requestedDestination = .settings
                openWindow(id: WindowID.dashboard)
                NSApp.activate(ignoringOtherApps: true)
            }
        )
    }

    private var statusPillText: String {
        if coordinator.isScanning { return "Checking" }
        if coordinator.monitor.isPausedForAnyReason || !appSettings.monitoringEnabled { return "Paused" }
        // Not a "Watching" over a monitor that has stopped reporting.
        if coordinator.latestSampleIsStale && !coordinator.linkIsDown { return "Not reporting" }
        if coordinator.liveSample == nil { return "Checking" }
        if coordinator.liveSample?.status.severity == "critical" { return "Problem" }
        if coordinator.liveSample?.status.severity == "warn" { return "Degraded" }
        return "Watching"
    }

    private var statusPillColor: Color {
        if coordinator.isScanning { return Theme.ColorToken.blue }
        if coordinator.monitor.isPausedForAnyReason || !appSettings.monitoringEnabled { return Theme.ColorToken.muted }
        if coordinator.latestSampleIsStale && !coordinator.linkIsDown { return Theme.ColorToken.amber }
        if coordinator.liveSample == nil { return Theme.ColorToken.muted }
        if coordinator.liveSample?.status.severity == "critical" { return .red }
        if coordinator.liveSample?.status.severity == "warn" { return Theme.ColorToken.amber }
        return Theme.ColorToken.green
    }

    // MARK: - 2. Update Banner

    @ViewBuilder
    private var updateBanner: some View {
        let checker = coordinator.updateChecker
        if checker.hasUpdate || checker.isDownloading {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: checker.isPreloaded ? "checkmark.circle.fill" : "arrow.up.circle.fill")
                        .foregroundStyle(checker.isPreloaded ? .green : .orange)
                        .font(.system(size: 13))
                    Text(checker.isDownloading ? checker.statusMessage : (checker.isPreloaded ? "Update ready: v\(checker.availableRelease?.cleanVersion ?? "")" : "Update available: v\(checker.availableRelease?.cleanVersion ?? "")"))
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    if !checker.isDownloading {
                        Button {
                            coordinator.showSoftwareUpdate()
                        } label: {
                            Text("Review…")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button {
                            checker.downloadAndInstallUpdate()
                        } label: {
                            Text(checker.isPreloaded ? "Restart" : "Update")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(checker.isPreloaded ? .green : .orange)
                        .controlSize(.small)
                    }
                }

                if checker.isDownloading {
                    VStack(alignment: .leading, spacing: 3) {
                        ProgressView(value: checker.downloadProgress)
                            .progressViewStyle(.linear)
                        HStack {
                            Text(checker.statusMessage)
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int(checker.downloadProgress * 100))%")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if let notes = checker.availableRelease?.shortReleaseNotes {
                    Button {
                        coordinator.showSoftwareUpdate()
                    } label: {
                        HStack(spacing: 4) {
                            Text(notes)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text("Details ›")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Theme.ColorToken.blue)
                        }
                    }
                    .buttonStyle(.plain)
                }

                if let err = checker.errorMessage {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.system(size: 10))
                        Text(err)
                            .font(.system(size: 9))
                            .foregroundStyle(.red)
                        Spacer()
                        Button("Download Page") {
                            checker.openReleasePage()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.orange)
                    }
                }
            }
            .padding(Theme.Spacing.sm)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .strokeBorder(Color.orange.opacity(0.3), lineWidth: 1)
            )
            .padding(.horizontal, 20)
            .padding(.bottom, 6)
        }
    }

    // MARK: - 3. Status Hero Section

    private var degradedExperience: StageResolver.DegradedSnapshot? {
        SuitabilityEngine.synthesizeDegradedExperience(
            items: suitabilityItems,
            monitorSample: coordinator.liveSample,
            currentJitter: coordinator.currentJitter,
            effectiveLoss: coordinator.effectiveLoss,
            lossFiltering: coordinator.lossFiltering
        )
    }

    private var stage: StageResolver.Stage {
        let degraded = degradedExperience
        return StageResolver.resolve(.init(
            isScanning: coordinator.isScanning,
            isArrivalCheck: coordinator.isArrivalCheck,
            monitoringEnabled: appSettings.monitoringEnabled,
            isPausedForAnyReason: coordinator.monitor.isPausedForAnyReason,
            pauseReason: coordinator.monitor.pauseReason,
            lastError: coordinator.monitor.lastError,
            monitorRunning: coordinator.monitor.isRunning,
            activeAlert: coordinator.alerts.urgentActiveSorted.first.map {
                StageResolver.AlertSnapshot(
                    title: $0.title, body: $0.body,
                    raisedAt: $0.raisedAt, rules: $0.rules,
                    severityRank: $0.rules
                        .map(coordinator.severityRank(forRuleID:)).max() ?? 0,
                    id: $0.id,
                    isUrgent: $0.isUrgent)
            },
            severity: coordinator.liveSample?.status.severity ?? "ok",
            linkUp: !linkDown,
            sampleStale: coordinator.latestSampleIsStale,
            // A sample that predates a stop or pause is not a measurement.
            measurementState: coordinator.liveSample?.status.measurement ?? "unknown",
            activeResolution: coordinator.activeResolution?.snapshot,
            degradedExperience: degraded,
            settling: coordinator.isSettling
        ))
    }

    @ViewBuilder
    private var statusHeroSection: some View {
        switch stage {
        case .healthy:
            MenuStatusHeroView(
                iconName: "checkmark.circle.fill",
                iconTint: Theme.ColorToken.green,
                iconBackground: Theme.ColorToken.greenWash,
                headline: "All good — watching",
                subtitle: quietLine
            )
        case .degraded(let deg):
            MenuStatusHeroView(
                iconName: deg.isCritical ? "exclamationmark.triangle.fill" : "exclamationmark.triangle",
                iconTint: deg.isCritical ? .red : Theme.ColorToken.amber,
                iconBackground: deg.isCritical ? Color.red.opacity(0.12) : Theme.ColorToken.amberWash,
                headline: deg.headline,
                subtitle: deg.subtitle
            )
        case .resolved(let res):
            MenuStatusHeroView(
                iconName: res.icon,
                iconTint: Theme.ColorToken.green,
                iconBackground: Theme.ColorToken.greenWash,
                headline: res.title,
                subtitle: res.message
            )
        case .noLink:
            let offline = coordinator.liveSample?.link.offline ?? coordinator.monitor.latest?.link.offline
            let rules = coordinator.monitor.latest?.status.rules ?? []
            let isPortal = rules.contains("CP-1")
                || (coordinator.currentNetworkRequiresPortal && (offline?.reason == "no-route" || rules.contains("N1c")))
                || coordinator.isSystemCaptiveActive()

            let headline: String = {
                if isPortal {
                    return coordinator.wifiDisplayName.map { "Sign in to \($0)" } ?? "Sign in to Wi-Fi network"
                } else if rules.contains("N1c") {
                    return coordinator.rulesCatalog.catalog?["N1c"]?.title ?? "No route to internet"
                } else if rules.contains("DH-3") {
                    return coordinator.rulesCatalog.catalog?["DH-3"]?.title ?? NoLinkCopy.headline
                } else if rules.contains("WJ-1") {
                    return coordinator.rulesCatalog.catalog?["WJ-1"]?.title ?? NoLinkCopy.headline
                } else if rules.contains("WF-1") {
                    return coordinator.rulesCatalog.catalog?["WF-1"]?.title ?? NoLinkCopy.headline
                } else {
                    return NoLinkCopy.headline
                }
            }()

            let subtitle: String = {
                if isPortal {
                    var text = "This network requires you to sign in before you can access the internet."
                    if coordinator.hasCustomDNS {
                        text += "\nCustom DNS is configured; if the portal doesn't open, your custom DNS may be blocking it."
                    }
                    return text
                }
                if rules.contains("N1c") {
                    var text = coordinator.rulesCatalog.catalog?["N1c"]?.blurb
                        ?? "Your Mac is associated with this network, but has no route to the internet."
                    if coordinator.hasCustomDNS {
                        text += "\nCustom DNS is configured; if this network has a captive portal, custom DNS may prevent the sign-in page from opening."
                    }
                    return text
                }
                var subtitleParts: [String] = []
                if let line = offline?.statusLine {
                    subtitleParts.append(line)
                }

                // The CLI's own sentence about what preceded the drop, or
                // nothing: it also decides when a more specific rule
                // (DH-3) makes that sentence the wrong one to show.
                if let summary = offline?.precursorSummary, !summary.isEmpty {
                    subtitleParts.append(summary)
                } else {
                    subtitleParts.append(coordinator.headline)
                }

                return subtitleParts.joined(separator: "\n")
            }()
            // The CLI decides which finding offers the repair (the catalog's
            // per-rule `repairs`); the card draws the button for whichever
            // firing rule that names, and only once the catalog has loaded.
            let reconnectRule = coordinator.reconnectRule(amongFiring: rules)
            let canReconnect = reconnectRule != nil
            let actionTitle: String = {
                if isPortal {
                    return "Open Sign-In Page"
                } else if canReconnect {
                    return coordinator.isRepairing ? "Reconnecting…" : "Reconnect Wi-Fi"
                } else {
                    return "Open Wi-Fi Settings"
                }
            }()
            let secTitle: String? = (isPortal || canReconnect) ? "Open Wi-Fi Settings" : nil

            MenuStatusHeroView(
                iconName: isPortal ? "lock.shield" : NoLinkCopy.icon,
                iconTint: isPortal ? Theme.ColorToken.amber : .red,
                iconBackground: isPortal ? Theme.ColorToken.amberWash : Color.red.opacity(0.12),
                headline: headline,
                subtitle: subtitle,
                actionTitle: actionTitle,
                onAction: {
                    if isPortal {
                        coordinator.openPortalPage()
                    } else if let reconnectRule {
                        coordinator.reconnectWiFi(ruleID: reconnectRule)
                    } else if let url = URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension") ?? URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                },
                secondaryActionTitle: secTitle,
                onSecondaryAction: {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension") ?? URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
            )
        case .watching(let sev):
            let isCritical = sev == .critical
            MenuStatusHeroView(
                iconName: isCritical ? "exclamationmark.triangle.fill" : "exclamationmark.triangle",
                iconTint: isCritical ? .red : Theme.ColorToken.amber,
                iconBackground: isCritical ? Color.red.opacity(0.12) : Theme.ColorToken.amberWash,
                headline: isCritical ? "Connection is unstable" : "Connection needs attention",
                subtitle: coordinator.headline.isEmpty
                    ? (isCritical ? "Confirming before notifying you…" : "Will alert if this keeps up.")
                    : coordinator.headline
            )
        case .alerted(let alert):
            let isCritical = alert.severityRank >= 3
            let isCaptive = isCaptivePortalAlert(alert)
            let isRouter = isRouterAlert(alert)

            let alertSubtitle: String = {
                if isCaptive {
                    var text = "This network requires you to sign in before you can access the internet."
                    if coordinator.hasCustomDNS {
                        text += "\nCustom DNS is configured; if the portal doesn't open, your custom DNS may be blocking it."
                    }
                    return text
                }
                let text = alert.body.isEmpty ? "Network problem detected" : alert.body
                return text
            }()

            MenuStatusHeroView(
                iconName: isCaptive ? "lock.shield" : (isCritical ? "exclamationmark.triangle.fill" : "exclamationmark.triangle"),
                iconTint: isCaptive ? Theme.ColorToken.amber : (isCritical ? .red : Theme.ColorToken.amber),
                iconBackground: isCaptive ? Theme.ColorToken.amberWash : (isCritical ? Color.red.opacity(0.12) : Theme.ColorToken.amberWash),
                headline: isCaptive ? (coordinator.wifiDisplayName.map { "Sign in to \($0)" } ?? "Sign in to Wi-Fi network") : alert.title,
                subtitle: alertSubtitle,
                actionTitle: isCaptive ? "Open Sign-In Page" : (isRouter && routerAdminURL != nil ? "Open Router Admin Page" : nil),
                onAction: isCaptive ? {
                    coordinator.openPortalPage()
                } : (isRouter && routerAdminURL != nil ? {
                    if let url = routerAdminURL {
                        NSWorkspace.shared.open(url)
                    }
                } : nil)
            )
        case .notReporting:
            MenuStatusHeroView(
                iconName: "exclamationmark.triangle",
                iconTint: Theme.ColorToken.amber,
                iconBackground: Theme.ColorToken.amberWash,
                headline: StaleSampleCopy.headline,
                subtitle: StaleSampleCopy.subtitle
            )
        case .checking:
            MenuStatusHeroView(
                iconName: "circle.dashed",
                iconTint: Theme.ColorToken.blue,
                iconBackground: Theme.ColorToken.neutralWash,
                headline: "Checking connection…",
                subtitle: "Waiting for a live router and internet reading",
                isChecking: true
            )
        case .testing:
            MenuStatusHeroView(
                iconName: "circle.dashed",
                iconTint: Theme.ColorToken.blue,
                iconBackground: Theme.ColorToken.neutralWash,
                headline: "Running full check…",
                subtitle: "Pinging route and checking services…",
                isChecking: true
            )
        case .arrived:
            MenuStatusHeroView(
                iconName: "circle.dashed",
                iconTint: Theme.ColorToken.blue,
                iconBackground: Theme.ColorToken.neutralWash,
                headline: coordinator.wifiDisplayName.map { "Checking new network: \($0)" } ?? "Checking new network",
                subtitle: "Pinging route and checking services…",
                isChecking: true
            )
        case .paused(let reason):
            MenuStatusHeroView(
                iconName: "pause.circle.fill",
                iconTint: Theme.ColorToken.muted,
                iconBackground: Theme.ColorToken.neutralWash,
                headline: "Monitoring paused",
                subtitle: reason ?? "Monitoring is currently paused"
            )
        case .skewed(let msg):
            MenuStatusHeroView(
                iconName: "exclamationmark.triangle",
                iconTint: Theme.ColorToken.amber,
                iconBackground: Theme.ColorToken.amberWash,
                headline: "Hopwatch needs attention",
                subtitle: msg
            )
        }
    }

    private func isCaptivePortalAlert(_ alert: StageResolver.AlertSnapshot) -> Bool {
        alert.id == "captive-portal"
            || alert.rules.contains("CP-1")
            || alert.title.localizedCaseInsensitiveContains("sign in")
            || alert.title.localizedCaseInsensitiveContains("captive")
            || (coordinator.liveSample?.publicInfo.captivePortal == true)
    }

    private var quietLine: String {
        var parts: [String] = []
        if let since = NetworkEvent.timeSinceLast(coordinator.currentNetworkEvents, now: .now) {
            if since < 60 {
                parts.append("Nothing has changed in under a minute")
            } else {
                let f = DateComponentsFormatter()
                f.allowedUnits = since >= 3600 ? [.hour, .minute] : [.minute]
                f.unitsStyle = .abbreviated
                if let s = f.string(from: since) {
                    parts.append("Nothing has changed in \(s)")
                }
            }
        } else {
            parts.append("Watching for changes")
        }
        if let name = coordinator.wifiDisplayName { parts.append("on \(name)") }
        return parts.joined(separator: " · ")
    }

    // MARK: - 4. Connection Route Section

    /// The newest monitor sample says there is no link. Every reading
    /// below that comes from the sample, an older sample or the last scan
    /// is void while this holds — a down link has no router ping, no
    /// internet ping, no jitter and no public-IP country.
    private var linkDown: Bool { coordinator.linkIsDown }

    private var routeWarningResult: RouteWarningResolver.Result {
        guard coordinator.liveSample != nil else {
            return .init(isWifiLaggy: false, macStatusGood: false, routerWarn: false, internetWarn: false)
        }
        // A monitor that has stopped reporting has no readings to judge; the
        // zeros below would read as a Wi-Fi fault (see HomeView).
        if coordinator.latestSampleIsStale && !linkDown {
            return .init(isWifiLaggy: false, macStatusGood: false,
                         routerWarn: false, internetWarn: false)
        }
        let isWiFi = coordinator.linkIsWiFi
        let linkUp = !linkDown
        let inetLoss = coordinator.liveSample?.internet.lossPct ?? 0
        let inetPing = coordinator.liveSample?.internet.rttAvgMs ?? 0
        let inetJitter = currentJitter ?? coordinator.liveSample?.internet.rttJitterMs ?? 0
        let gwLoss = coordinator.liveSample?.gateway.lossPct ?? 0
        let gwPing = coordinator.liveSample?.gateway.rttAvgMs ?? 0
        let gwJitter = coordinator.liveSample?.gateway.rttJitterMs ?? 0

        return RouteWarningResolver.resolve(
            linkUp: linkUp,
            isWiFi: isWiFi,
            stage: stage,
            firedCategories: firedCategories,
            gwLoss: gwLoss,
            gwPing: gwPing,
            gwJitter: gwJitter,
            inetLoss: inetLoss,
            inetPing: inetPing,
            inetJitter: inetJitter,
            hasRecentRoam: coordinator.hasRecentRoam,
            wifiRuleTint: wifiRuleTint,
            gatewayPingFiltered: lossFiltering.filters(.gateway)
        )
    }

    private var isWifiLaggy: Bool {
        routeWarningResult.isWifiLaggy
    }

    private var macStatusGood: Bool {
        routeWarningResult.macStatusGood
    }

    private var resolvedBand: String? {
        if let band = coordinator.freshNetworkRunSnapshot?.wifiScan?.currentBand {
            return band
        }
        if let chStr = coordinator.liveSample?.wifi?.channel {
            if chStr.contains("2.4") { return "2.4 GHz" }
            if chStr.contains("5 GHz") || chStr.contains("5GHz") { return "5 GHz" }
            if chStr.contains("6 GHz") || chStr.contains("6GHz") { return "6 GHz" }
            let firstDigits = chStr.components(separatedBy: CharacterSet.decimalDigits.inverted).first { !$0.isEmpty }
            if let firstDigits, let ch = Int(firstDigits) {
                if ch <= 14 { return "2.4 GHz" }
                if ch >= 32 { return "5 GHz" }
            }
        }
        return nil
    }

    private var macDetailText: String {
        if linkDown {
            let offline = coordinator.liveSample?.link.offline ?? coordinator.monitor.latest?.link.offline
            // The CLI's caption for the reason, or the neutral one.
            return offline?.knownReasonLabel ?? NoLinkCopy.macDetail
        }
        guard coordinator.liveSample != nil else { return "Checking…" }
        let isWiFi = coordinator.liveSample?.link.isWiFi ?? true
        guard isWiFi else {
            return coordinator.liveSample?.link.ip ?? "Ethernet"
        }
        if let rssi = resolvedRSSI {
            let guidance = SignalScale.distanceGuidance(forRSSI: rssi)
            if let guidance {
                if let band = resolvedBand {
                    return "\(guidance) · \(band)"
                }
                return "\(guidance) · \(rssi) dBm"
            }
            if let band = resolvedBand {
                return "\(rssi) dBm · \(band)"
            }
            return "\(rssi) dBm"
        }
        return coordinator.liveSample?.link.ip ?? "Wi-Fi link"
    }

    private var isWifiSignalWeak: Bool {
        guard let rssi = resolvedRSSI else { return false }
        return rssi < -75 || (wifiRuleTint != nil && wifiRuleTint != .green)
    }

    private var isGatewayJitterDominant: Bool {
        let gwJitter = coordinator.liveSample?.gateway.rttJitterMs ?? 0
        return gwJitter >= 20.0
    }

    private var jitterLabel: String {
        "Jitter"
    }

    private var connectionRouteSection: some View {
        let isWiFi = coordinator.linkIsWiFi
        let linkUp = !linkDown
        let cadence = coordinator.liveSample?.status.cadenceS ?? Defaults.fastInterval

        return ConnectionRouteView(
            wifiReadingLabel: !linkUp ? "Network link" : (isWiFi ? "Wi-Fi signal" : "Interface link"),
            wifiReadingValue: !linkUp ? NoLinkCopy.linkReading : (isWiFi ? wifiCell.value : (coordinator.liveSample == nil ? "—" : "Connected")),
            wifiReadingTint: !linkUp ? .red : (isWiFi ? wifiCell.tint : (coordinator.liveSample == nil ? Theme.ColorToken.muted : Theme.ColorToken.green)),
            macIcon: !linkUp ? "laptopcomputer" : (isWiFi ? "laptopcomputer" : "cable.connector"),
            macStatusGood: macStatusGood && coordinator.liveSample != nil,
            macDetail: macDetailText,
            routerPingValue: routerPingText,
            routerPingTint: routerPingTint,
            routerStatusGood: !linkDown && !routerWarn && coordinator.liveSample?.gateway.rttAvgMs != nil,
            routerDetail: routerDetailText,
            routerWarn: !linkDown && routerWarn,
            internetPingValue: internetPingText,
            internetPingTint: internetPingTint,
            internetStatusGood: !linkDown && !internetWarn &&
                (coordinator.liveSample?.internet.rttAvgMs != nil || coordinator.liveSample?.tcp.anyOk == true),
            countryFlag: countryFlagEmoji,
            countryName: countryNameString,
            publicIP: linkDown ? nil : publicIP,
            internetDetail: internetDetailText,
            internetWarn: !linkDown && internetWarn,
            firstLinkLabel: !linkUp ? NoLinkCopy.nodeDetail : (isWiFi ? (isWifiLaggy ? "Wi-Fi (Laggy)" : "Wi-Fi") : "Wired"),
            secondLinkLabel: !linkUp ? "" : "Broadband",
            wifiWarning: !linkDown && isWiFi && isWifiSignalWeak,
            isWifiLaggy: !linkDown && isWiFi && isWifiLaggy,
            routerAdminURL: linkDown ? nil : routerAdminURL,
            routerAdminAvailable: !linkDown && coordinator.routerAdminAvailable,
            jitterLabel: jitterLabel,
            jitterMs: linkDown ? nil : currentJitter,
            jitterWarn: !linkDown && (currentJitter ?? 0) >= 30.0 || (isGatewayJitterDominant && (currentJitter ?? 0) >= 20.0),
            jitterDescription: jitterDescriptionText,
            linkDown: linkDown,
            vpnActive: vpnActive,
            vpnKnown: coordinator.liveSample != nil,
            vpnName: vpnName,
            vpnFreshness: coordinator.vpnFreshness,
            cadenceText: coordinator.latestSampleIsStale
                ? "Not reporting"
                : (coordinator.monitor.isPausedForAnyReason ? "Monitoring paused"
                   : coordinator.monitor.isRunning
                    ? "Live · every \(cadence) seconds"
                    : "Monitoring off")
        )
    }

    private var routerPingText: String {
        if linkDown { return NoLinkCopy.unknownValue }
        guard let sample = coordinator.liveSample else { return "—" }
        guard let rtt = sample.gateway.rttAvgMs else {
            if let loss = sample.gateway.lossPct, loss >= 100 { return "no reply" }
            return "—"
        }
        return "\(Int(rtt.rounded())) ms"
    }

    private var routerPingTint: Color {
        if linkDown { return Theme.ColorToken.muted }
        if lossFiltering.filters(.gateway) || coordinator.liveSample?.gateway.rttAvgMs == nil {
            return Theme.ColorToken.muted
        }
        let rtt = coordinator.liveSample?.gateway.rttAvgMs ?? 0
        if routerWarn || rtt >= 25.0 {
            return Theme.ColorToken.amber
        }
        return Theme.ColorToken.ink
    }

    private var internetPingText: String {
        if linkDown { return NoLinkCopy.unknownValue }
        guard !coordinator.monitor.isPaused, !coordinator.isScanning else { return "—" }
        if PingReadout.internetShowsTCPOk(rtt: coordinator.liveSample?.internet.rttAvgMs,
                                          filtering: lossFiltering) { return "TCP ok" }
        guard let rtt = coordinator.liveSample?.internet.rttAvgMs else {
            if let loss = coordinator.liveSample?.internet.lossPct, loss >= 100 { return "no reply" }
            return "—"
        }
        return "\(Int(rtt.rounded())) ms"
    }

    private var internetPingTint: Color {
        if linkDown { return Theme.ColorToken.muted }
        if internetWarn {
            return Theme.ColorToken.amber
        }
        return Theme.ColorToken.ink
    }

    private var routerWarn: Bool {
        routeWarningResult.routerWarn
    }

    private var internetWarn: Bool {
        routeWarningResult.internetWarn
    }

    private var routerDetailText: String {
        if linkDown { return NoLinkCopy.nodeDetail }
        if coordinator.latestSampleIsStale { return StaleSampleCopy.unknownValue }
        if lossFiltering.filters(.gateway) {
            return "Ping blocked"
        }
        if coordinator.hasRecentRoam && (coordinator.liveSample?.gateway.lossPct ?? 0) < 10.0 {
            return "Wi-Fi roamed"
        }
        let inetLoss = coordinator.liveSample?.internet.lossPct ?? 0
        if let loss = coordinator.liveSample?.gateway.lossPct, loss > 0 {
            if inetLoss <= 1.0 && loss < 20.0 {
                return routerGatewayIP ?? "default gateway"
            }
            return LossFormatter.formatPacketLoss(loss)
        }
        if routerWarn {
            let gwJitter = coordinator.liveSample?.gateway.rttJitterMs ?? 0
            let gwRtt = coordinator.liveSample?.gateway.rttAvgMs ?? 0
            if gwJitter >= 20.0 {
                return String(format: "±%.0f ms jitter", gwJitter)
            }
            if gwRtt >= 30.0 {
                return String(format: "%.0f ms latency", gwRtt)
            }
            return "Router latency"
        }
        return routerGatewayIP ?? "default gateway"
    }

    private var internetDetailText: String {
        if linkDown { return NoLinkCopy.nodeDetail }
        if coordinator.latestSampleIsStale { return StaleSampleCopy.unknownValue }
        guard coordinator.liveSample?.internet.lossPct != nil else {
            return coordinator.liveSample?.tcp.anyOk == true ? "Web reachable" : "Checking…"
        }
        let loss = coordinator.liveSample?.internet.lossPct ?? 0
        let jitter = currentJitter ?? coordinator.liveSample?.internet.rttJitterMs ?? 0
        let ping = coordinator.liveSample?.internet.rttAvgMs ?? 0

        // Only the filtered leg's hop says "Ping blocked"; its loss figure
        // describes the probe, not the link.
        if lossFiltering.filters(.internet) {
            return "Ping blocked"
        }
        if loss > 0 && jitter >= 30.0 {
            return "\(LossFormatter.formatLoss(loss)) · \(Int(round(jitter)))ms jit"
        }
        if loss > 0 {
            return LossFormatter.formatPacketLoss(loss)
        }
        if jitter >= 30.0 && !isGatewayJitterDominant {
            return String(format: "%.0f ms jitter", jitter)
        }
        if internetWarn {
            if ping >= 120.0 {
                return String(format: "%.0f ms latency", ping)
            }
            if jitter >= 20.0 {
                return String(format: "%.0f ms jitter", jitter)
            }
            if let degHeadline = degradedExperience?.headline {
                return degHeadline
            }
            return "Connection degraded"
        }
        return "0% packet loss"
    }

    private var countryFlagEmoji: String? {
        if linkDown { return nil }
        return Flag.emoji(forISOCode: countryISO)
    }

    private var countryNameString: String? {
        if linkDown { return nil }
        return coordinator.currentPublicInfo?.country
    }

    private var jitterDescriptionText: String {
        if linkDown { return NoLinkCopy.nodeDetail }
        guard let j = currentJitter else { return "Checking…" }
        if j >= 30.0 {
            return "Uneven response times"
        }
        return "Stable response times"
    }

    // MARK: - 4b. Heartbeat Section

    private var heartbeatSection: some View {
        PingHeartbeatView(heartbeat: coordinator.heartbeat)
    }

    // MARK: - 5. Experience Grid Section

    private var experienceSection: some View {
        ExperienceGridView(
            calls: callsExperience,
            gaming: gamingExperience,
            streaming: streamingExperience,
            browsing: browsingExperience
        )
    }

    private var suitabilityItems: [SuitabilityEngine.Item] {
        let snap = coordinator.freshNetworkRunSnapshot
        let inputs = SuitabilityEngine.Inputs(
            monitorSample: coordinator.liveSample,
            speedTest: coordinator.currentSuitabilitySpeed,
            savedSuitability: snap?.suitability,
            catalog: coordinator.rulesCatalog.catalog,
            firedRules: Array(firedRules),
            isLinkUp: coordinator.liveSample?.link.up ?? true,
            isDoubleNat: snap?.wan.doubleNat.detected ?? false,
            mtu: snap?.mtu.effective ?? snap?.mtu.pathSize,
            vpnActive: coordinator.liveSample?.vpn.active ?? snap?.vpn.active ?? false,
            vpnName: coordinator.liveSample?.vpn.name ?? snap?.vpn.name,
            currentJitter: coordinator.currentJitter,
            effectiveLoss: coordinator.effectiveLoss,
            lossFiltering: coordinator.lossFiltering
        )
        return SuitabilityEngine.evaluateAll(inputs)
    }

    private var callsExperience: ExperienceGridView.ExperienceStatus {
        if let item = suitabilityItems.first(where: { $0.id == "calls" }) {
            return .init(label: item.status, tint: item.tint, metric: item.metric, helpText: item.helpText)
        }
        return .init(label: "Clear audio", tint: Theme.ColorToken.green, metric: "0% loss", helpText: "Clear audio for voice & video calls")
    }

    private var gamingExperience: ExperienceGridView.ExperienceStatus {
        if let item = suitabilityItems.first(where: { $0.id == "gaming" }) {
            return .init(label: item.status, tint: item.tint, metric: item.metric, helpText: item.helpText)
        }
        return .init(label: "Smooth", tint: Theme.ColorToken.green, metric: "Low ping", helpText: "Stable latency and jitter for online multiplayer gaming")
    }

    private var streamingExperience: ExperienceGridView.ExperienceStatus {
        if let item = suitabilityItems.first(where: { $0.id == "streaming" }) {
            return .init(label: item.status, tint: item.tint, metric: item.metric, helpText: item.helpText)
        }
        return .init(label: "HD ready", tint: Theme.ColorToken.green, metric: "Clean link", helpText: "Sufficient bandwidth for smooth streaming")
    }

    private var browsingExperience: ExperienceGridView.ExperienceStatus {
        if let item = suitabilityItems.first(where: { $0.id == "browsing" }) {
            return .init(label: item.status, tint: item.tint, metric: item.metric, helpText: item.helpText)
        }
        return .init(label: "Fast", tint: Theme.ColorToken.green, metric: "TCP 443 ok", helpText: "Fast DNS resolution and reliable HTTPS connectivity")
    }

    // MARK: - 6. Speed Test Section

    private var speedSection: some View {
        MenuSpeedView(
            downMbps: speedValues.down,
            upMbps: speedValues.up,
            meta: speedMetaText
        )
    }

    private var speedMetaText: String {
        if let age = speedValues.age {
            if linkDown {
                return "\(age) · before outage"
            }
            return vpnActive ? "\(age) · before VPN" : age
        }
        return "not tested yet"
    }

    // MARK: - 7. Activity Section

    private var activitySection: some View {
        MenuActivitySnippetView(
            event: recentActivityEvent,
            onOpenActivity: { openActivity() }
        )
    }

    private var recentActivityEvent: ActivityEntry? {
        ActivityEntry.fold(timelineEvents).first
    }

    // MARK: - 8. Actions Section

    private var actionsSection: some View {
        VStack(spacing: 8) {
            if coordinator.currentHealth == .warning || coordinator.currentHealth == .critical {
                Button(action: { copySupportSummary() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Copy 1-Click IT / Support Ticket")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(Theme.ColorToken.amberWash)
                    .foregroundStyle(Theme.ColorToken.amber)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Theme.ColorToken.amber.opacity(0.3), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }

            MenuActionsView(
                isScanning: coordinator.isScanning,
                onOpenDashboard: { openDashboard() },
                onRunFullCheck: { coordinator.runFullCheck() },
                onCancelScan: { coordinator.cancelScan() }
            )
        }
    }

    // MARK: - 9. Footer Section

    private var footerSection: some View {
        MenuFooterView(
            networkName: currentNetworkDisplayName,
            linkDown: linkDown,
            isWiFi: isWiFiConnection,
            monitoringEnabled: appSettings.monitoringEnabled,
            onToggleMonitoring: { toggleMonitoring() },
            onCopyReport: { copyShareableReport() },
            onCopySupport: { copySupportSummary() },
            onSaveMarkdown: { saveMarkdownReport() },
            onSaveJSON: { saveJSONReport() },
            onQuit: {
                coordinator.stop()
                NSApp.terminate(nil)
            },
            canShare: coordinator.supportsShare
        )
    }

    private var currentNetworkDisplayName: String? {
        // No link: no interface, so no "Ethernet" either. The monitor's
        // `link.type` in a down sample is only the CLI's default.
        if linkDown { return coordinator.wifiDisplayName }
        return coordinator.wifiDisplayName
            ?? (coordinator.liveSample?.link.isWiFi == false
                ? (coordinator.liveSample?.link.interface ?? "Ethernet")
                : nil)
    }

    private var isWiFiConnection: Bool {
        coordinator.linkIsWiFi
    }

    private func toggleMonitoring() {
        let enabled = !appSettings.monitoringEnabled
        appSettings.monitoringEnabled = enabled
        coordinator.setMonitoring(enabled: enabled)
    }

    private func openDashboard() {
        coordinator.requestedDestination = .home
        openWindow(id: WindowID.dashboard)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openActivity() {
        coordinator.requestedDestination = .activity
        openWindow(id: WindowID.dashboard)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Helpers & Models

    private var firedCategories: Set<String> {
        guard let catalog = coordinator.rulesCatalog.catalog else { return [] }
        return Set(firedRules.compactMap { ruleID in
            guard let entry = catalog[ruleID], entry.severity != "info" else { return nil }
            return entry.category
        })
    }

    private var firedRules: Set<String> {
        var rules = Set(coordinator.liveSample?.status.rules ?? [])
        if let snapRules = coordinator.freshNetworkRunSnapshot?.diagnosis.compactMap(\.rule) {
            rules.formUnion(snapRules)
        }
        return rules
    }

    private var currentJitter: Double? {
        coordinator.currentJitter
    }

    private var stability: ConnectionStability {
        coordinator.currentStability
    }

    /// Which ping legs the live sample says are unmeasurable. Empty while
    /// paused or scanning, when the cells show "—" rather than a reading.
    private var lossFiltering: EffectiveLoss.Filtering {
        guard !coordinator.monitor.isPaused, !coordinator.isScanning else { return .none }
        return EffectiveLoss.filtering(sample: coordinator.liveSample)
    }

    private var resolvedRSSI: Int? {
        coordinator.liveSample?.wifi?.rssi ?? coreWLANRSSI
    }

    private var wifiCell: (value: String, unit: String?, tint: Color) {
        guard let sample = coordinator.liveSample else {
            return ("—", nil, Theme.ColorToken.muted)
        }
        if !sample.link.up {
            return ("disconnected", nil, .red)
        }
        guard sample.link.isWiFi else {
            return ("wired", nil, .secondary)
        }
        let content = SignalScale.cellContent(rssi: resolvedRSSI, scale: coordinator.signalScale.scale)
        return (content.value, content.unit, wifiRuleTint ?? content.tint)
    }

    private var wifiRuleTint: Color? {
        guard let catalog = coordinator.rulesCatalog.catalog else { return nil }
        let hits = firedRules.compactMap { catalog[$0] }
            .filter { $0.categories.contains("wifi") }
        guard !hits.isEmpty else { return nil }
        if hits.contains(where: { $0.severity == "critical" }) { return .red }
        if hits.contains(where: { $0.severity == "warn" }) { return .yellow }
        if hits.contains(where: { $0.severity == "varies" }) {
            return coordinator.liveSample?.status.severity == "critical" ? .red : .yellow
        }
        return nil
    }

    private func refreshCoreWLANRSSIIfNeeded() {
        guard coordinator.liveSample?.link.isWiFi == true,
              coordinator.liveSample?.wifi?.rssi == nil,
              coordinator.locationPermissions.isAuthorized,
              let live = CWWiFiClient.shared().interface()?.rssiValue(),
              live != 0 else {
            coreWLANRSSI = nil
            return
        }
        coreWLANRSSI = live
    }

    private var speedValues: (down: String, up: String, age: String?) {
        // Already scoped to this network by the coordinator (see
        // `currentSpeedTest`); the unscoped store lookup that used to follow
        // took the "newest anywhere" branch whenever no sample had arrived.
        if let current = coordinator.currentSpeedTest {
            let speed = current.speed
            let age = current.at.map { RelativeTime.string(from: $0) }
            return (speed.downMbps.map { String(Int($0.rounded())) } ?? "—",
                    speed.upMbps.map { String(Int($0.rounded())) } ?? "—",
                    age)
        }
        return ("—", "—", nil)
    }

    private var timelineEvents: [NetworkEvent] {
        let events = coordinator.currentNetworkEvents
        guard case .alerted(let alert) = stage else { return events }
        return events.filter { !($0.kind == "alert" && $0.summary == alert.title) }
    }

    private func copySupportSummary() {
        let text: String
        let sampleCandidate = coordinator.liveSample ?? coordinator.monitor.latest
        let snapshotCandidate = coordinator.currentRunResult?.snapshot
            ?? coordinator.latestRun?.snapshot
            ?? coordinator.hydratedReport?.run
        let owned = coordinator.history.isOwned(
            networkID: sampleCandidate?.network.id ?? snapshotCandidate?.network.id
        )
        let activeAlert: StageResolver.AlertSnapshot? = {
            if case .alerted(let stageAlert) = stage {
                return stageAlert
            }
            return coordinator.alerts.urgentActiveSorted.first.map {
                StageResolver.AlertSnapshot(
                    title: $0.title, body: $0.body,
                    raisedAt: $0.raisedAt, rules: $0.rules,
                    severityRank: $0.rules.map(coordinator.severityRank(forRuleID:)).max() ?? 0,
                    id: $0.id,
                    isUrgent: $0.isUrgent
                )
            }
        }()
        if let latestSample = sampleCandidate {
            text = SupportSummaryFormatter.format(
                sample: latestSample,
                alert: activeAlert,
                catalog: coordinator.rulesCatalog.catalog,
                networkIsOwned: owned,
                fallbackNetworkName: coordinator.wifiDisplayName,
                fallbackRSSI: resolvedRSSI,
                fallbackChannel: resolvedBand,
                fallbackSnapshot: snapshotCandidate
            )
        } else if let snapshot = snapshotCandidate {
            text = SupportSummaryFormatter.format(
                snapshot: snapshot,
                catalog: coordinator.rulesCatalog.catalog,
                networkIsOwned: owned
            )
        } else {
            text = SupportSummaryFormatter.format(
                SupportSummaryFormatter.Parameters(
                    networkName: coordinator.wifiDisplayName ?? "Unknown Network",
                    signalQuality: resolvedRSSI.flatMap {
                        SupportSummaryFormatter.describeSignal(rssi: $0, channel: resolvedBand)
                    },
                    observedProblem: activeAlert.map { "\($0.title): \($0.body)" } ?? "Network issue detected",
                    localVerification: "Local link is idle and healthy; issue is upstream on network/router",
                    concreteAction: owned
                        ? "Restart the router (unplug for 15 seconds, then plug back in)."
                        : "Please consider restarting the local Wi-Fi router / access point for this area."
                )
            )
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Task { @MainActor in
            shareFeedback = "Support summary copied"
            didShare = true
            try? await Task.sleep(for: .seconds(2))
            shareFeedback = nil
            didShare = false
        }
    }

    private func copyShareableReport() {
        Task { @MainActor in
            do {
                let text = try await coordinator.shareCurrentReportText()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                shareFeedback = "Diagnostic report copied"
                didShare = true
                try? await Task.sleep(for: .seconds(2))
                shareFeedback = nil
                didShare = false
            } catch {
                shareFeedback = "Couldn't build report"
                try? await Task.sleep(for: .seconds(2))
                shareFeedback = nil
                didShare = false
            }
        }
    }

    private func saveMarkdownReport() {
        Task { @MainActor in
            do {
                let text = try await coordinator.shareCurrentReportText()
                let name = DiagnosticReportSharing.defaultFileName(extension: "md", timestamp: coordinator.latestRun?.snapshot.timestamp)
                let mdType = UTType(filenameExtension: "md") ?? .plainText
                DiagnosticReportSharing.saveFile(content: text, defaultName: name, contentType: mdType)
            } catch {}
        }
    }

    private func saveJSONReport() {
        Task { @MainActor in
            do {
                let json = try await coordinator.shareCurrentReportJSON()
                let name = DiagnosticReportSharing.defaultFileName(extension: "json", timestamp: coordinator.latestRun?.snapshot.timestamp)
                DiagnosticReportSharing.saveFile(content: json, defaultName: name, contentType: .json)
            } catch {}
        }
    }

    private var isNetworkOwned: Bool {
        coordinator.history.isOwned(networkID: coordinator.liveSample?.network.id)
            || (coordinator.liveSample?.network.isMine ?? false)
    }

    private var routerGatewayIP: String? {
        coordinator.liveSample?.link.gateway
            ?? coordinator.freshNetworkRunSnapshot?.gateway.ip
    }

    private var routerAdminURL: URL? {
        guard isNetworkOwned else { return nil }
        return IPAddressValidation.routerAdminURL(for: routerGatewayIP)
    }

    private func isRouterAlert(_ alert: StageResolver.AlertSnapshot) -> Bool {
        for ruleID in alert.rules {
            let rule = coordinator.rulesCatalog.catalog?[ruleID]
            if rule?.fixTarget == "your_router" || rule?.category == "router" || ruleID.hasPrefix("G") || ruleID.hasPrefix("B") {
                return true
            }
        }
        return false
    }

    private var publicIP: String? {
        let ip = coordinator.currentPublicInfo?.ip
        return (ip?.isEmpty ?? true) ? nil : ip
    }

    private var countryISO: String? {
        coordinator.currentPublicInfo?.countryISO
    }

    private var vpnActive: Bool {
        coordinator.liveSample?.vpn.active
            ?? coordinator.freshNetworkRunSnapshot?.vpn.active ?? false
    }

    private var vpnName: String? {
        coordinator.liveSample?.vpn.name
            ?? coordinator.freshNetworkRunSnapshot?.vpn.name
    }
}

/// Menu-like hover highlight for dropdown rows.
struct HighlightingButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .fill(hovering ? Color.accentColor.opacity(0.12) : .clear)
                    .padding(.horizontal, 4)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Anchors the borderless `MenuBarExtra(.window)` panel to its exact SwiftUI fitting height
/// and keeps its top edge (`maxY`) pinned directly beneath the macOS menu bar when content height changes.
private struct DropdownWindowAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> DropdownWindowAnchorView {
        DropdownWindowAnchorView()
    }

    func updateNSView(_ nsView: DropdownWindowAnchorView, context: Context) {
        nsView.scheduleSync()
    }
}

final class DropdownWindowAnchorView: NSView {
    private var pinnedMaxY: CGFloat?
    private var isAdjusting = false
    private var syncScheduled = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let window, !window.styleMask.contains(.titled) else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidChange(_:)),
            name: NSWindow.didResizeNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidChange(_:)),
            name: NSWindow.didMoveNotification,
            object: window
        )
        scheduleSync()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        scheduleSync()
    }

    func scheduleSync() {
        guard window != nil, !syncScheduled else { return }
        syncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.syncScheduled = false
            self.syncWindowFrame()
        }
    }

    @objc private func windowDidChange(_ notification: Notification) {
        syncWindowFrame()
    }

    func syncWindowFrame() {
        guard let window, !window.styleMask.contains(.titled), !isAdjusting else { return }
        let fitting = window.contentView?.fittingSize ?? .zero
        let targetHeight = fitting.height > 100 ? fitting.height : bounds.height
        let targetWidth = fitting.width > 100 ? fitting.width : bounds.width
        guard targetHeight > 100, targetWidth > 100 else { return }

        if let screenMaxY = (window.screen ?? NSScreen.main)?.visibleFrame.maxY {
            pinnedMaxY = screenMaxY - 2
        } else if pinnedMaxY == nil {
            pinnedMaxY = window.frame.maxY
        }

        guard let topY = pinnedMaxY else { return }
        var frame = window.frame
        let heightChanged = abs(frame.size.height - targetHeight) > 0.5
        let widthChanged = abs(frame.size.width - targetWidth) > 0.5
        let topDrifted = abs(frame.maxY - topY) > 0.5
        guard heightChanged || widthChanged || topDrifted else { return }

        isAdjusting = true
        defer { isAdjusting = false }

        frame.size.width = targetWidth
        frame.size.height = targetHeight
        frame.origin.y = topY - targetHeight
        window.setFrame(frame, display: true)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

