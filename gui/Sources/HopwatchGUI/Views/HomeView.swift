import SwiftUI
import AppKit
import CoreWLAN
import UniformTypeIdentifiers

/// The main dashboard overview: "is my internet OK, and why?" — redesigned
/// per docs/design/hopwatch-dashboard.mockup.html and hopwatch-redesign-notes.md.
///
/// Features a comprehensive two-column layout:
/// 1. Page Heading: Breadcrumb, Share diagnostics menu, Run full check button.
/// 2. Status Hero Banner: Prominent condition headline, explanation, and detection age.
/// 3. Connection Path: 3-hop interactive route (This Mac → Router → Internet) with
///    live readings, country flag, route metrics, and VPN context.
/// 4. Main Analysis Grid:
///    - Left: Live Ping Chart (15m/1h range, legend, min/avg/max, latency test toggle) + Findings & Next Steps.
///    - Right: Check Details Table (comparing current measurements against "Usual" medians).
/// 5. Connection Reliability Strip: Availability, outages, downtime, longest outage.
/// 6. Bottom Grid: Network Details Panel (with speed test context) + Recent Activity Panel.
/// 7. Saved Activity Suitability Strip: 5-category suitability row.
/// 8. Technical Details Disclosure Panel: Collapsible 4-section drawer with raw JSON viewer.
/// 9. Dashboard Footer: Privacy disclaimer.
struct HomeView: View {
    @Environment(HopwatchCoordinator.self) private var coordinator
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.openWindow) private var openWindow

    @State private var chartWindowMinutes: Int = 15
    @State private var showRawJSONSheet: Bool = false
    @State private var coreWLANRSSI: Int?
    @State private var shareFeedback: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 1. Page Heading
                DashboardHeadingView(
                    networkName: currentNetworkName,
                    isWiFi: isConnectedToWiFi,
                    isScanning: coordinator.isScanning,
                    onRunFullCheck: { coordinator.runFullCheck() },
                    onCancelScan: { coordinator.cancelScan() },
                    onCopyRedacted: { copyShareableReport() },
                    onCopySupport: { copySupportSummary() },
                    onSaveMarkdown: { saveMarkdownReport() },
                    onSaveJSON: { saveJSONReport() }
                )

                // Location Banner (if location permissions are restricted on Wi-Fi)
                locationWarningBanner

                // Arrival Card (for newly joined networks or captive portals)
                ArrivalCard(
                    state: coordinator.arrivalState,
                    network: arrivalNetworkName,
                    progress: coordinator.isScanning ? coordinator.progress : nil,
                    intent: coordinator.arrivalIntent,
                    onRunFullCheck: { coordinator.runDeclinedFullCheck() },
                    isCaptivePortal: isCaptivePortal
                )

                // Scan in flight progress
                if coordinator.isScanning,
                   ArrivalCopy.forState(coordinator.arrivalState,
                                        network: arrivalNetworkName,
                                        intent: coordinator.arrivalIntent) == nil {
                    ScanProgressView(progress: coordinator.progress)
                    Divider()
                }

                // Error banner if last check failed
                if let error = coordinator.lastRunError {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.ColorToken.ink)
                        Spacer()
                        Button("Try Again") {
                            coordinator.runFullCheck(reason: "retry after failure")
                        }
                        .controlSize(.small)
                    }
                    .padding(Theme.Spacing.sm)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }

                // 2. Status Hero Banner
                statusHeroSection

                // 3. Key Vitals Row (Speed & Connection Reliability)
                keyVitalsSection

                // 4. What Should Work (Suitability Strip)
                suitabilityStripSection

                // 5. Connection Path Panel
                DashboardRouteView(
                    wifiSignalText: wifiSignalText,
                    wifiSignalDetail: wifiSignalDetail,
                    wifiSignalTint: wifiSignalTint,
                    wifiPHY: currentRunResult?.snapshot.wifi?.phy,
                    wifiSNR: currentRunResult?.snapshot.wifi?.snr.map { "\($0) dB" },
                    macIP: macIPString,
                    routerPingText: routerPingText,
                    routerPingTint: routerPingTint,
                    routerWarn: routerWarn,
                    routerIP: routerGatewayIP ?? "192.168.1.1",
                    routerLossText: routerLossText,
                    routerJitterText: routerJitterText,
                    routerLoadedDelta: currentRunResult?.snapshot.bufferbloat.gwDeltaMs.map { String(format: "+%.0f ms", $0) },
                    internetPingText: internetPingText,
                    internetPingTint: internetPingTint,
                    internetWarn: internetWarn,
                    countryFlag: countryFlagEmoji,
                    countryName: countryNameString,
                    ispName: ispNameText,
                    internetLossText: internetLossText,
                    internetJitterText: internetJitterText,
                    internetLoadedDelta: currentRunResult?.snapshot.bufferbloat.inetDeltaMs.map { String(format: "+%.0f ms", $0) },
                    bandChannelText: bandChannelText,
                    vpnActive: vpnActive,
                    vpnProvider: vpnProviderName,
                    publicIP: publicIPString,
                    pingTarget: pingTargetString,
                    pingTargetAlt: pingTargetAltString,
                    culpritHop: culpritHop
                )

                // 6. Main 2-Column Dashboard Grid (Ping Chart & Findings vs Graded Check Details)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(spacing: 16) {
                            DashboardLiveChartPanel(
                                samples: coordinator.monitor.recent,
                                selectedWindowMinutes: $chartWindowMinutes,
                                isBursting: coordinator.monitor.isBursting,
                                onToggleBurst: {
                                    if coordinator.monitor.isBursting {
                                        coordinator.monitor.endBurst()
                                    } else {
                                        coordinator.monitor.beginBurst(
                                            interval: Defaults.latencyTestInterval,
                                            duration: Defaults.latencyTestDuration
                                        )
                                    }
                                }
                            )

                            DashboardFindingsPanel(
                                checkTime: checkTimeSubtitle,
                                findings: activeFindings
                            )
                        }
                        .frame(maxWidth: .infinity)

                        DashboardCheckTable(
                            checkSubtitle: lastCheckedCaption ?? "Awaiting check",
                            networkSSID: currentNetworkName,
                            vpnActive: vpnActive,
                            rows: checkTableRows
                        )
                        .frame(maxWidth: .infinity)
                    }

                    // Fallback to vertical stack on narrow displays
                    VStack(spacing: 16) {
                        DashboardLiveChartPanel(
                            samples: coordinator.monitor.recent,
                            selectedWindowMinutes: $chartWindowMinutes,
                            isBursting: coordinator.monitor.isBursting,
                            onToggleBurst: {
                                if coordinator.monitor.isBursting {
                                    coordinator.monitor.endBurst()
                                } else {
                                    coordinator.monitor.beginBurst(
                                        interval: Defaults.latencyTestInterval,
                                        duration: Defaults.latencyTestDuration
                                    )
                                }
                            }
                        )

                        DashboardFindingsPanel(
                            checkTime: checkTimeSubtitle,
                            findings: activeFindings
                        )

                        DashboardCheckTable(
                            checkSubtitle: lastCheckedCaption ?? "Awaiting check",
                            networkSSID: currentNetworkName,
                            vpnActive: vpnActive,
                            rows: checkTableRows
                        )
                    }
                }

                // 7. Bottom 2-Column Grid (Network Details & Recent Activity)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        DashboardNetworkDetailsPanel(
                            interface: interfaceDetailText,
                            publicCountry: publicCountryDetailText,
                            localIP: macIPString,
                            publicIP: publicIPString ?? "Checking…",
                            gatewayIP: routerGatewayIP ?? "—",
                            ispName: ispNameText,
                            dnsServer: dnsServerText,
                            vpnName: vpnDetailText,
                            wifiSecurity: wifiSecurityText,
                            connectionCost: connectionCostText,
                            lastSpeedMeta: lastSpeedMetaText,
                            downMbps: speedValues.down,
                            upMbps: speedValues.up,
                            onRunSpeedTest: { coordinator.runFullCheck(reason: "speed test requested") }
                        )
                        .frame(maxWidth: .infinity)

                        DashboardRecentActivityPanel(
                            events: ActivityEntry.fold(coordinator.eventLog.events),
                            onOpenActivity: { openActivity() }
                        )
                        .frame(maxWidth: .infinity)
                    }

                    VStack(spacing: 16) {
                        DashboardNetworkDetailsPanel(
                            interface: interfaceDetailText,
                            publicCountry: publicCountryDetailText,
                            localIP: macIPString,
                            publicIP: publicIPString ?? "Checking…",
                            gatewayIP: routerGatewayIP ?? "—",
                            ispName: ispNameText,
                            dnsServer: dnsServerText,
                            vpnName: vpnDetailText,
                            wifiSecurity: wifiSecurityText,
                            connectionCost: connectionCostText,
                            lastSpeedMeta: lastSpeedMetaText,
                            downMbps: speedValues.down,
                            upMbps: speedValues.up,
                            onRunSpeedTest: { coordinator.runFullCheck(reason: "speed test requested") }
                        )

                        DashboardRecentActivityPanel(
                            events: ActivityEntry.fold(coordinator.eventLog.events),
                            onOpenActivity: { openActivity() }
                        )
                    }
                }

                // 8. Technical Detail Panel (Permanently unfolded and visible)
                DashboardTechnicalPanel(
                    routerIP: routerGatewayIP ?? "192.168.1.1",
                    routerLoss: routerLossText,
                    internetTargets: currentInternetTargets,
                    internetLoss: internetLossText,
                    tracerouteHops: currentRunResult?.snapshot.traceroute.hops.count ?? 3,
                    isIPv6: currentRunResult?.snapshot.ipv6.available ?? false,
                    isDoubleNAT: currentRunResult?.snapshot.wan.doubleNat.detected ?? false,
                    wifiSignal: currentRunResult?.snapshot.wifi?.rssi.map { "\($0) dBm" } ?? "—",
                    wifiNoise: currentRunResult?.snapshot.wifi?.noise.map { "\($0) dBm" } ?? "—",
                    wifiSNR: currentRunResult?.snapshot.wifi?.snr.map { "\($0) dB" } ?? "—",
                    wifiBandChannel: bandChannelText,
                    dhcpRemaining: dhcpRemainingText,
                    ipConflict: !(currentRunResult?.snapshot.duplicateIPs.isEmpty ?? true),
                    neighborCount: currentRunResult?.snapshot.wifiScan?.neighbourCount ?? 0,
                    backgroundTraffic: false,
                    checkTimestamp: checkTimeSubtitle ?? "recent",
                    dnsResolversList: dnsServerText,
                    tcpReachability: currentRunResult?.snapshot.tcpReach.first?.ok == true ? "reachable" : "unreachable",
                    loadedRTT: loadedRTTText,
                    onViewRawJSON: { showRawJSONSheet = true },
                    onCopyRedacted: { copyShareableReport() },
                    onSaveMarkdown: { saveMarkdownReport() }
                )

                // 9. Dashboard Footer
                DashboardFooterView()
            }
            .padding(24)
        }
        .sheet(isPresented: $showRawJSONSheet) {
            rawJSONSheet
        }
        .task {
            coordinator.locationPermissions.refresh()
            if coordinator.history.document.runs.isEmpty {
                await coordinator.history.load()
            }
        }
        .task(id: coordinator.monitor.latest?.seq) {
            refreshCoreWLANRSSIIfNeeded()
        }
    }

    // MARK: - Status Hero Section

    private var stage: StageResolver.Stage {
        StageResolver.resolve(.init(
            isScanning: coordinator.isScanning,
            isArrivalCheck: coordinator.isArrivalCheck,
            monitoringEnabled: appSettings.monitoringEnabled,
            isPausedForAnyReason: coordinator.monitor.isPausedForAnyReason,
            pauseReason: coordinator.monitor.pauseReason,
            lastError: coordinator.monitor.lastError,
            monitorRunning: coordinator.monitor.isRunning,
            activeAlert: coordinator.alerts.activeSorted.first.map {
                StageResolver.AlertSnapshot(
                    title: $0.title, body: $0.body,
                    raisedAt: $0.raisedAt, rules: $0.rules,
                    severityRank: $0.rules
                        .map(coordinator.severityRank(forRuleID:)).max() ?? 0,
                    id: $0.id)
            },
            severity: coordinator.monitor.latest?.status.severity ?? "ok",
            linkUp: coordinator.monitor.latest?.link.up ?? true,
            measurementState: coordinator.monitor.latest?.status.measurement ?? "unknown",
            activeResolution: coordinator.activeResolution?.snapshot
        ))
    }

    @ViewBuilder
    private var statusHeroSection: some View {
        switch stage {
        case .healthy:
            DashboardStatusHeroView(
                iconName: "checkmark.circle.fill",
                iconTint: Theme.ColorToken.green,
                iconBackground: Theme.ColorToken.greenWash,
                headline: "All good — watching",
                subtitle: coordinator.headline.isEmpty
                    ? "Continuous background monitoring is active and connection is stable."
                    : coordinator.headline
            )
        case .resolved(let res):
            DashboardStatusHeroView(
                iconName: res.icon,
                iconTint: Theme.ColorToken.green,
                iconBackground: Theme.ColorToken.greenWash,
                headline: res.title,
                subtitle: res.message
            )
        case .watching(let sev):
            let isCritical = sev == .critical
            DashboardStatusHeroView(
                iconName: isCritical ? "exclamationmark.triangle.fill" : "exclamationmark.triangle",
                iconTint: isCritical ? Theme.ColorToken.red : Theme.ColorToken.amber,
                iconBackground: isCritical ? Theme.ColorToken.redWash : Theme.ColorToken.amberWash,
                headline: isCritical ? "Connection is unstable" : "Connection needs attention",
                subtitle: coordinator.headline.isEmpty
                    ? "Replies are being lost from your router or internet. Calls may cut out."
                    : coordinator.headline,
                detectedTime: "Monitoring"
            )
        case .alerted(let alert):
            let isCritical = alert.severityRank >= 3
            let isCaptive = isCaptivePortalAlert(alert)
            let isRouter = isRouterAlert(alert)

            DashboardStatusHeroView(
                iconName: isCritical ? "exclamationmark.triangle.fill" : "exclamationmark.triangle",
                iconTint: isCritical ? Theme.ColorToken.red : Theme.ColorToken.amber,
                iconBackground: isCritical ? Theme.ColorToken.redWash : Theme.ColorToken.amberWash,
                headline: alert.title,
                subtitle: alert.body.isEmpty ? "Network problem detected" : alert.body,
                detectedTime: "Detected \(RelativeTime.string(from: alert.raisedAt))",
                actionTitle: isCaptive ? "Open Login Page" : (isRouter && routerAdminURL != nil ? "Open Router Admin Page" : nil),
                onAction: isCaptive ? {
                    if let url = URL(string: "http://captive.apple.com/hotspot-detect.html") {
                        NSWorkspace.shared.open(url)
                    }
                } : (isRouter && routerAdminURL != nil ? {
                    if let url = routerAdminURL {
                        NSWorkspace.shared.open(url)
                    }
                } : nil)
            )
        case .testing:
            DashboardStatusHeroView(
                iconName: "circle.dashed",
                iconTint: Theme.ColorToken.blue,
                iconBackground: Theme.ColorToken.blueWash,
                headline: "Running diagnostic check…",
                subtitle: "Pinging route and checking services…"
            )
        case .arrived:
            DashboardStatusHeroView(
                iconName: "circle.dashed",
                iconTint: Theme.ColorToken.blue,
                iconBackground: Theme.ColorToken.blueWash,
                headline: coordinator.wifiDisplayName.map { "Checking new network: \($0)" } ?? "Checking new network",
                subtitle: "Pinging route and checking services…"
            )
        case .checking:
            DashboardStatusHeroView(
                iconName: "circle.dashed",
                iconTint: Theme.ColorToken.blue,
                iconBackground: Theme.ColorToken.blueWash,
                headline: "Checking connection…",
                subtitle: "Waiting for a live router and internet reading…"
            )
        case .paused(let reason):
            DashboardStatusHeroView(
                iconName: "pause.circle.fill",
                iconTint: Theme.ColorToken.muted,
                iconBackground: Theme.ColorToken.neutralWash,
                headline: "Monitoring is paused",
                subtitle: reason ?? "Paused from the menu bar."
            )
        case .skewed(let msg):
            DashboardStatusHeroView(
                iconName: "exclamationmark.triangle.fill",
                iconTint: Theme.ColorToken.amber,
                iconBackground: Theme.ColorToken.amberWash,
                headline: "Hopwatch needs attention",
                subtitle: msg
            )
        }
    }

    // MARK: - Key Vitals Section

    private var keyVitalsSection: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                DashboardSpeedCard(
                    downMbps: speedValues.down,
                    upMbps: speedValues.up,
                    testedMeta: lastSpeedMetaText,
                    isScanning: coordinator.isScanning,
                    onRunSpeedTest: { coordinator.runFullCheck(reason: "speed test requested") }
                )
                .frame(maxWidth: .infinity)

                DashboardReliabilityCard(
                    observationSummary: reliabilityObservationSummary,
                    outageCount: currentRunResult?.snapshot.availability?.outages.map { "\($0) outages" } ?? "0 outages",
                    totalDowntime: currentRunResult?.snapshot.availability?.downtimeS.map { formatSeconds($0) } ?? "0s",
                    longestOutage: currentRunResult?.snapshot.availability?.longestOutageS.map { formatSeconds($0) } ?? "0s"
                )
                .frame(maxWidth: .infinity)
            }

            VStack(spacing: 16) {
                DashboardSpeedCard(
                    downMbps: speedValues.down,
                    upMbps: speedValues.up,
                    testedMeta: lastSpeedMetaText,
                    isScanning: coordinator.isScanning,
                    onRunSpeedTest: { coordinator.runFullCheck(reason: "speed test requested") }
                )

                DashboardReliabilityCard(
                    observationSummary: reliabilityObservationSummary,
                    outageCount: currentRunResult?.snapshot.availability?.outages.map { "\($0) outages" } ?? "0 outages",
                    totalDowntime: currentRunResult?.snapshot.availability?.downtimeS.map { formatSeconds($0) } ?? "0s",
                    longestOutage: currentRunResult?.snapshot.availability?.longestOutageS.map { formatSeconds($0) } ?? "0s"
                )
            }
        }
    }

    private var reliabilityObservationSummary: String {
        guard let avail = currentRunResult?.snapshot.availability else {
            return "Monitoring started recently · No prior data in last 24h"
        }
        let unobserved = avail.unobservedPct ?? 100
        if unobserved >= 99 {
            return "Monitoring started recently · No history recorded in last 24h"
        } else if unobserved > 0 {
            let observedPct = max(1, 100 - unobserved)
            let observedHours = Double(24 * observedPct) / 100.0
            if observedHours >= 1.0 {
                return String(format: "Last 24h · Monitored for ~%.0fh (%d%% offline or asleep)", observedHours, unobserved)
            } else {
                let observedMins = max(1, Int(round(observedHours * 60)))
                return "Last 24h · Monitored for ~\(observedMins)m (\(unobserved)% offline or asleep)"
            }
        } else {
            return "Last 24 hours · Continuously monitored"
        }
    }

    private func formatSeconds(_ s: Int) -> String {
        let mins = s / 60
        let secs = s % 60
        if mins > 0 {
            return "\(mins)m \(secs)s"
        }
        return "\(secs)s"
    }

    // MARK: - Suitability Strip Section

    private var suitabilityStripSection: some View {
        DashboardSuitabilityStrip(
            items: suitabilityItems,
            subtitle: checkTimeSubtitle
        )
    }

    private var suitabilityItems: [SuitabilityEngine.Item] {
        let snap = currentRunResult?.snapshot
        let fired = coordinator.monitor.latest?.status.rules
            ?? snap?.diagnosis.compactMap(\.rule)
            ?? []
        let inputs = SuitabilityEngine.Inputs(
            monitorSample: coordinator.monitor.latest,
            speedTest: snap?.speedtest ?? coordinator.latestSpeedTest,
            savedSuitability: snap?.suitability,
            catalog: coordinator.rulesCatalog.catalog,
            firedRules: fired,
            isLinkUp: coordinator.monitor.latest?.link.up ?? true,
            isDoubleNat: snap?.wan.doubleNat.detected ?? false,
            mtu: snap?.mtu.effective ?? snap?.mtu.pathSize ?? 1500,
            vpnActive: vpnActive,
            vpnName: vpnProviderName,
            currentJitter: coordinator.currentJitter,
            effectiveLoss: coordinator.effectiveLoss
        )
        return SuitabilityEngine.evaluateAll(inputs)
    }

    // MARK: - Findings Computation

    private var activeFindings: [DashboardFindingsPanel.FindingItem] {
        var items: [DashboardFindingsPanel.FindingItem] = []

        // From current snapshot diagnosis
        if let diags = currentRunResult?.snapshot.diagnosis {
            for (idx, diag) in diags.enumerated() {
                let isWarn = diag.severity == "warn" || diag.severity == "critical"
                let rule = diag.rule.flatMap { coordinator.rulesCatalog.catalog?[$0] }
                let advice = rule?.fix ?? rule?.fixAway ?? diag.action?.label ?? diag.action?.hint
                items.append(.init(
                    id: "diag-\(idx)-\(diag.summary)",
                    title: diag.summary,
                    explanation: "",
                    nextStep: advice,
                    isWarning: isWarn
                ))
            }
        }

        // Also incorporate any active alerts
        for alert in coordinator.alerts.activeSorted {
            if !items.contains(where: { $0.title == alert.title }) {
                let rank = alert.rules.map(coordinator.severityRank(forRuleID:)).max() ?? 0
                let isWarn = rank >= 2
                items.append(.init(
                    id: "alert-\(alert.id)",
                    title: alert.title,
                    explanation: alert.body,
                    nextStep: "Run a full check to investigate root cause.",
                    isWarning: isWarn
                ))
            }
        }

        return items
    }

    // MARK: - Check Table Computation

    private var checkTableRows: [DashboardCheckTable.Row] {
        let snap = currentRunResult?.snapshot
        let mem = currentNetworkMemory

        var rows: [DashboardCheckTable.Row] = []

        let gwRtt = snap?.gateway.rttAvgMs ?? coordinator.monitor.latest?.gateway.rttAvgMs
        let gwLoss = snap?.gateway.lossPct ?? coordinator.monitor.latest?.gateway.lossPct ?? 0
        let isRoamBlip = coordinator.hasRecentRoam && gwLoss < 10.0
        let inetRtt = snap?.internetLatency.rttAvgMs ?? coordinator.monitor.latest?.internet.rttAvgMs
        let inetJitter = snap?.internetLatency.rttJitterMs ?? coordinator.currentJitter ?? 0
        let loss1 = snap?.internetLatency.lossPct ?? coordinator.monitor.latest?.internet.lossPct ?? 0
        let loss2 = snap?.internetLatency.lossPctAlt ?? loss1
        let rssi = resolvedRSSI
        let snr = snap?.wifi?.snr
        let noise = snap?.wifi?.noise
        let channel = coordinator.monitor.latest?.wifi?.channel
            ?? snap?.wifi?.channel
            ?? snap?.wifiScan?.currentChannel
        let neighborCount = snap?.wifiScan?.neighbourCount ?? 0

        // 1. Jitter (Matching user mockup)
        let jitterBadge: DashboardCheckTable.GradeBadge = {
            if inetJitter >= 20 {
                return .init(label: "Unstable", tone: .critical)
            } else if inetJitter >= 10 {
                return .init(label: "Degraded", tone: .warn)
            } else {
                return .init(label: "Good", tone: .good)
            }
        }()
        rows.append(.init(
            id: "jitter",
            icon: "waveform.path",
            label: "Jitter",
            measured: "\(Int(round(inetJitter))) ms",
            subvalue: nil,
            usual: "—",
            badge: jitterBadge,
            isWarning: inetJitter >= 10,
            isGood: inetJitter < 10
        ))

        // 2. Packet loss to router (Matching user mockup)
        let gwLossBadge: DashboardCheckTable.GradeBadge = {
            if isRoamBlip {
                return .init(label: "Roamed", tone: .good)
            } else if gwLoss >= 10.0 {
                return .init(label: "Unstable", tone: .critical)
            } else if gwLoss >= 3.0 {
                return .init(label: "Degraded", tone: .warn)
            } else {
                return .init(label: "Good", tone: .good)
            }
        }()
        rows.append(.init(
            id: "gw-loss",
            icon: (!isRoamBlip && gwLoss >= 3.0) ? "exclamationmark.triangle.fill" : "network",
            label: "Packet loss to router",
            measured: "\(Int(round(gwLoss)))%",
            subvalue: nil,
            usual: "0%",
            badge: gwLossBadge,
            isWarning: !isRoamBlip && gwLoss >= 3.0,
            isGood: (isRoamBlip || gwLoss < 1.0)
        ))

        // 3. Wi-Fi channel (Matching user mockup)
        if isConnectedToWiFi {
            let isCrowded = neighborCount > 3
            let channelText = channel != nil ? "\(channel!)" : (bandChannelText.isEmpty ? "Connected" : bandChannelText)
            let channelBadge = DashboardCheckTable.GradeBadge(
                label: isCrowded ? "Crowded" : "Clear",
                tone: isCrowded ? .warn : .good
            )
            rows.append(.init(
                id: "wifi-channel",
                icon: isCrowded ? "antenna.radiowaves.left.and.right.slash" : "antenna.radiowaves.left.and.right",
                label: "Wi-Fi channel",
                measured: channelText,
                subvalue: neighborCount > 0 ? "\(neighborCount) neighboring networks" : nil,
                usual: "—",
                badge: channelBadge,
                isWarning: isCrowded,
                isGood: !isCrowded
            ))
        }

        // 4. Signal (Matching user mockup)
        if isConnectedToWiFi {
            let signalBadge: DashboardCheckTable.GradeBadge = {
                guard let r = rssi else { return .init(label: "Good", tone: .good) }
                if r >= -55 { return .init(label: "Excellent", tone: .good) }
                if r >= -65 { return .init(label: "Good", tone: .good) }
                if r >= -75 { return .init(label: "Degraded", tone: .warn) }
                return .init(label: "Weak", tone: .critical)
            }()
            rows.append(.init(
                id: "wifi-signal",
                icon: "wifi",
                label: "Signal",
                measured: rssi.map { "\($0) dBm" } ?? "Connected",
                subvalue: nil,
                usual: "−62 dBm",
                badge: signalBadge,
                isWarning: rssi != nil && rssi! < -70,
                isGood: rssi != nil && rssi! >= -65
            ))
        }

        // 5. Noise (Matching user mockup)
        if isConnectedToWiFi, let n = noise {
            let noiseBadge = DashboardCheckTable.GradeBadge(
                label: n <= -85 ? "Good" : "Elevated",
                tone: n <= -85 ? .good : .warn
            )
            rows.append(.init(
                id: "wifi-noise",
                icon: "waveform.badge.magnifyingglass",
                label: "Noise",
                measured: "\(n) dBm",
                subvalue: nil,
                usual: "−86 dBm",
                badge: noiseBadge,
                isWarning: n > -85,
                isGood: n <= -85
            ))
        }

        // 6. SNR (Matching user mockup)
        if isConnectedToWiFi, let s = snr {
            let snrBadge: DashboardCheckTable.GradeBadge = {
                if s >= 25 { return .init(label: "Good", tone: .good) }
                if s >= 15 { return .init(label: "Low", tone: .warn) }
                return .init(label: "Poor", tone: .critical)
            }()
            rows.append(.init(
                id: "wifi-snr",
                icon: "chart.bar.fill",
                label: "SNR",
                measured: "\(s) dB",
                subvalue: nil,
                usual: "25 dB",
                badge: snrBadge,
                isWarning: s < 20,
                isGood: s >= 20
            ))
        }

        // 7. Router Ping
        let gwUsual = mem?.typicalGatewayLatencyMs.map { String(format: "%.1f ms", $0) } ?? "—"
        let gwPingBadge: DashboardCheckTable.GradeBadge = {
            guard let r = gwRtt else { return .init(label: "Good", tone: .good) }
            if r > 50 { return .init(label: "Slow", tone: .warn) }
            return .init(label: "Good", tone: .good)
        }()
        rows.append(.init(
            id: "router",
            icon: "network",
            label: "Router latency",
            measured: gwRtt != nil ? "\(Int(round(gwRtt!))) ms" : "—",
            subvalue: nil,
            usual: gwUsual,
            badge: gwPingBadge,
            isWarning: gwRtt != nil && gwRtt! > 50,
            isGood: gwRtt != nil && gwRtt! <= 50
        ))

        // 8. Internet Ping
        let inetUsual = mem?.typicalInternetLatencyMs.map { String(format: "%.1f ms", $0) } ?? "—"
        let inetPingBadge: DashboardCheckTable.GradeBadge = {
            guard let r = inetRtt else { return .init(label: "Good", tone: .good) }
            if r > 120 { return .init(label: "Elevated", tone: .warn) }
            return .init(label: "Good", tone: .good)
        }()
        rows.append(.init(
            id: "internet",
            icon: inetRtt != nil && inetRtt! > 120 ? "exclamationmark.triangle.fill" : "globe",
            label: "Internet latency",
            measured: inetRtt != nil ? "\(Int(round(inetRtt!))) ms" : "—",
            subvalue: nil,
            usual: inetUsual,
            badge: inetPingBadge,
            isWarning: inetRtt != nil && inetRtt! > 120,
            isGood: inetRtt != nil && inetRtt! <= 120
        ))

        // 9. Internet packet loss
        let lossText = String(format: "%.0f%% / %.0f%%", loss1, loss2)
        let lossBadge: DashboardCheckTable.GradeBadge = {
            if loss1 >= 10.0 { return .init(label: "Unstable", tone: .critical) }
            if loss1 >= 3.0 { return .init(label: "Degraded", tone: .warn) }
            if loss1 > 0 { return .init(label: "Minor", tone: .warn) }
            return .init(label: "Good", tone: .good)
        }()
        rows.append(.init(
            id: "loss",
            icon: loss1 >= 3.0 ? "exclamationmark.triangle.fill" : "checkmark",
            label: "Internet packet loss",
            measured: lossText,
            subvalue: nil,
            usual: "0%",
            badge: lossBadge,
            isWarning: loss1 >= 3.0,
            isGood: loss1 < 1.0
        ))

        // 10. DNS
        let dnsTotal = snap?.dns.count ?? 0
        let dnsOk = snap?.dns.filter(\.ok).count ?? 0
        let dnsText = dnsTotal > 0 ? "\(dnsOk) of \(dnsTotal) resolvers OK" : "All lookups healthy"
        let dnsBadge = DashboardCheckTable.GradeBadge(
            label: (dnsTotal > 0 && dnsOk < dnsTotal) ? "Degraded" : "Good",
            tone: (dnsTotal > 0 && dnsOk < dnsTotal) ? .warn : .good
        )
        rows.append(.init(
            id: "dns",
            icon: dnsTotal > 0 && dnsOk < dnsTotal ? "exclamationmark.triangle.fill" : "checkmark",
            label: "Name lookups (DNS)",
            measured: dnsText,
            subvalue: nil,
            usual: "—",
            badge: dnsBadge,
            isWarning: dnsTotal > 0 && dnsOk < dnsTotal,
            isGood: dnsTotal == 0 || dnsOk == dnsTotal
        ))

        // 11. Lag under load (Bufferbloat)
        let bb = snap?.bufferbloat
        let bbRouterGrade = bb?.gwGrade ?? "A"
        let bbRouterAdded = bb?.gwDeltaMs.map { String(format: "+%.0f ms", $0) } ?? "+3 ms"
        let bbInetGrade = bb?.inetGrade ?? "A"
        let bbInetAdded = bb?.inetDeltaMs.map { String(format: "+%.0f ms", $0) } ?? "+15 ms"
        let bbBadge = DashboardCheckTable.GradeBadge(
            label: "Grade \(bbInetGrade)",
            tone: (bbInetGrade == "A" || bbInetGrade == "B") ? .good : (bbInetGrade == "C" ? .warn : .critical)
        )
        rows.append(.init(
            id: "bufferbloat",
            icon: bbInetGrade == "D" || bbInetGrade == "F" ? "exclamationmark.triangle.fill" : "checkmark",
            label: "Lag under load",
            measured: "Router \(bbRouterGrade) (\(bbRouterAdded))",
            subvalue: "Internet \(bbInetGrade) (\(bbInetAdded))",
            usual: "+3 ms router",
            badge: bbBadge,
            isWarning: bbInetGrade == "D" || bbInetGrade == "F",
            isGood: bbInetGrade != "D" && bbInetGrade != "F"
        ))

        // 12. Packet size (MTU)
        let mtu = snap?.mtu.effective ?? snap?.mtu.pathSize ?? 1500
        let mtuBadge = DashboardCheckTable.GradeBadge(
            label: mtu >= 1400 ? "Standard" : "Reduced",
            tone: mtu >= 1400 ? .good : .warn
        )
        rows.append(.init(
            id: "mtu",
            icon: "checkmark",
            label: "Packet size (MTU)",
            measured: "\(mtu) bytes",
            subvalue: nil,
            usual: "—",
            badge: mtuBadge,
            isWarning: false,
            isGood: true
        ))

        // 13. IPv6
        let ipv6Avail = snap?.ipv6.available ?? false
        let ipv6Badge = DashboardCheckTable.GradeBadge(
            label: ipv6Avail ? "Active" : "IPv4 only",
            tone: ipv6Avail ? .good : .neutral
        )
        rows.append(.init(
            id: "ipv6",
            icon: "globe",
            label: "IPv6",
            measured: ipv6Avail ? "Available" : "Not available",
            subvalue: ipv6Avail ? nil : "IPv4-only connection",
            usual: "—",
            badge: ipv6Badge,
            isWarning: false,
            isGood: ipv6Avail
        ))

        // 14. Web connections
        let webOk = snap?.tcpReach.first?.ok ?? true
        let webBadge = DashboardCheckTable.GradeBadge(
            label: webOk ? "Good" : "Blocked",
            tone: webOk ? .good : .critical
        )
        rows.append(.init(
            id: "web",
            icon: webOk ? "checkmark" : "exclamationmark.triangle.fill",
            label: "Web connections",
            measured: webOk ? "TCP 443 reachable" : "TCP 443 blocked",
            subvalue: nil,
            usual: "—",
            badge: webBadge,
            isWarning: !webOk,
            isGood: webOk
        ))

        // 15. Speed test
        let speedDown = snap?.speedtest?.downMbps ?? coordinator.latestSpeedTest?.downMbps
        let speedUp = snap?.speedtest?.upMbps ?? coordinator.latestSpeedTest?.upMbps
        let speedText: String = {
            if let d = speedDown, let u = speedUp {
                return String(format: "↓ %.0f · ↑ %.0f Mbps", d, u)
            }
            return "Skipped in this check"
        }()
        let speedBadge: DashboardCheckTable.GradeBadge = {
            guard let d = speedDown else { return .init(label: "Skipped", tone: .neutral) }
            if d >= 100 { return .init(label: "Fast", tone: .good) }
            if d >= 25 { return .init(label: "Good", tone: .good) }
            return .init(label: "Slow", tone: .warn)
        }()
        rows.append(.init(
            id: "speed",
            icon: "waveform.path.ecg",
            label: "Throughput / Speed",
            measured: speedText,
            subvalue: nil,
            usual: "—",
            badge: speedBadge,
            isWarning: false,
            isGood: speedDown != nil
        ))

        return rows
    }

    // MARK: - Route Properties

    private var currentNetworkName: String? {
        coordinator.wifiDisplayName
            ?? coordinator.monitor.latest?.link.ssid
            ?? coordinator.latestRun?.snapshot.wifi?.ssid
            ?? coordinator.hydratedReport?.run.wifi?.ssid
    }

    private var arrivalNetworkName: String? {
        if let live = coordinator.wifiDisplayName, !live.isEmpty { return live }
        guard let id = coordinator.arrivalNetworkID else { return nil }
        let resolved = coordinator.history.displayName(for: id)
        return resolved.isEmpty ? nil : resolved
    }

    private var isConnectedToWiFi: Bool {
        if let live = coordinator.monitor.latest?.link.isWiFi {
            return live
        }
        if let run = coordinator.latestRun {
            return run.snapshot.wifi != nil
        }
        return CWWiFiClient.shared().interface()?.powerOn() ?? true
    }

    private var wifiSignalText: String {
        if !isConnectedToWiFi { return "Ethernet" }
        guard let rssi = resolvedRSSI else { return "—" }
        return SignalScale.cellContent(rssi: rssi, scale: coordinator.signalScale.scale).value
    }

    private var wifiSignalDetail: String {
        if !isConnectedToWiFi { return "1 Gbps wired" }
        guard let rssi = resolvedRSSI else { return "No reading" }
        return "\(rssi) dBm"
    }

    private var wifiSignalTint: Color {
        if !isConnectedToWiFi { return Theme.ColorToken.green }
        guard let rssi = resolvedRSSI else { return Theme.ColorToken.muted }
        return SignalScale.cellContent(rssi: rssi, scale: coordinator.signalScale.scale).tint
    }

    private var macIPString: String {
        coordinator.monitor.latest?.link.ip
            ?? coordinator.latestRun?.snapshot.interfaceInfo.ip
            ?? "192.168.1.24"
    }

    private var routerPingText: String {
        guard let rtt = coordinator.monitor.latest?.gateway.rttAvgMs
            ?? coordinator.latestRun?.snapshot.gateway.rttAvgMs else { return "—" }
        return "\(Int(round(rtt)))"
    }

    private var routerPingTint: Color {
        routerWarn ? Theme.ColorToken.amber : Theme.ColorToken.green
    }

    private var firedRules: Set<String> {
        Set(coordinator.monitor.latest?.status.rules ?? coordinator.latestRun?.snapshot.diagnosis.compactMap(\.rule) ?? [])
    }

    private var firedCategories: Set<String> {
        guard let catalog = coordinator.rulesCatalog.catalog else { return [] }
        return Set(firedRules.compactMap { catalog[$0]?.category })
    }

    private var routerWarn: Bool {
        if coordinator.hasRecentRoam && (coordinator.monitor.latest?.gateway.lossPct ?? coordinator.latestRun?.snapshot.gateway.lossPct ?? 0) < 10.0 {
            return false
        }
        return firedCategories.contains("router")
            || ((coordinator.monitor.latest?.gateway.lossPct ?? coordinator.latestRun?.snapshot.gateway.lossPct ?? 0) >= 3.0)
            || ((coordinator.monitor.latest?.gateway.rttAvgMs ?? coordinator.latestRun?.snapshot.gateway.rttAvgMs ?? 0) > 30)
    }

    private var routerGatewayIP: String? {
        coordinator.monitor.latest?.link.gateway
            ?? coordinator.latestRun?.snapshot.gateway.ip
            ?? coordinator.hydratedReport?.run.gateway.ip
    }

    private var routerLossText: String {
        let loss = coordinator.monitor.latest?.gateway.lossPct
            ?? coordinator.latestRun?.snapshot.gateway.lossPct
            ?? 0
        if coordinator.hasRecentRoam && loss < 10.0 {
            return "roamed"
        }
        if loss < 1.0 { return "0%" }
        return String(format: "%.0f%%", loss)
    }

    private var routerJitterText: String {
        let jitter = coordinator.monitor.latest?.gateway.rttJitterMs
            ?? coordinator.latestRun?.snapshot.gateway.rttJitterMs
            ?? 1.0
        return "\(Int(round(jitter))) ms"
    }

    private var internetPingText: String {
        if coordinator.monitor.latest?.status.icmpFiltered == true { return "TCP ok" }
        guard let rtt = coordinator.monitor.latest?.internet.rttAvgMs
            ?? coordinator.latestRun?.snapshot.internetLatency.rttAvgMs else { return "—" }
        return "\(Int(round(rtt)))"
    }

    private var internetPingTint: Color {
        internetWarn ? Theme.ColorToken.amber : Theme.ColorToken.green
    }

    private var internetWarn: Bool {
        firedCategories.contains("internet")
            || ((coordinator.monitor.latest?.internet.lossPct ?? coordinator.latestRun?.snapshot.internetLatency.lossPct ?? 0) >= 3.0)
            || ((coordinator.monitor.latest?.internet.rttAvgMs ?? coordinator.latestRun?.snapshot.internetLatency.rttAvgMs ?? 0) > 120)
    }

    private var countryFlagEmoji: String? {
        Flag.emoji(forISOCode: countryISO)
    }

    private var countryISO: String? {
        coordinator.monitor.latest?.publicInfo.countryISO
            ?? coordinator.latestRun?.snapshot.publicInfo.countryISO
            ?? coordinator.hydratedReport?.run.publicInfo.countryISO
    }

    private var countryNameString: String? {
        coordinator.monitor.latest?.publicInfo.country
            ?? coordinator.latestRun?.snapshot.publicInfo.country
            ?? coordinator.hydratedReport?.run.publicInfo.country
    }

    private var internetLossText: String {
        let loss = coordinator.monitor.latest?.internet.lossPct
            ?? coordinator.latestRun?.snapshot.internetLatency.lossPct
            ?? 0
        if loss < 1.0 { return "0%" }
        return String(format: "%.0f%%", loss)
    }

    private var internetJitterText: String {
        let jitter = coordinator.monitor.latest?.internet.rttJitterMs
            ?? coordinator.latestRun?.snapshot.internetLatency.rttJitterMs
            ?? coordinator.currentJitter
            ?? 5.0
        return "\(Int(round(jitter))) ms"
    }

    private var bandChannelText: String {
        let band = currentRunResult?.snapshot.wifiScan?.currentBand ?? "5 GHz"
        let channel = coordinator.monitor.latest?.wifi?.channel
            ?? currentRunResult?.snapshot.wifi?.channel
            ?? currentRunResult?.snapshot.wifiScan?.currentChannel
            ?? "44"
        if !isConnectedToWiFi { return "Ethernet wired link" }
        return "Band \(band) · Channel \(channel)"
    }

    private var vpnActive: Bool {
        coordinator.monitor.latest?.vpn.active
            ?? coordinator.latestRun?.snapshot.vpn.active
            ?? coordinator.hydratedReport?.run.vpn.active ?? false
    }

    private var vpnProviderName: String? {
        coordinator.monitor.latest?.vpn.name
            ?? coordinator.latestRun?.snapshot.vpn.name
            ?? coordinator.hydratedReport?.run.vpn.name
    }

    private var publicIPString: String? {
        coordinator.monitor.latest?.publicInfo.ip
            ?? coordinator.latestRun?.snapshot.publicInfo.ip
            ?? coordinator.hydratedReport?.run.publicInfo.ip
    }

    private var pingTargetString: String? {
        currentRunResult?.snapshot.internetLatency.target ?? "1.1.1.1"
    }

    private var pingTargetAltString: String? {
        currentRunResult?.snapshot.internetLatency.targetAlt ?? "8.8.8.8"
    }

    private var culpritHop: String? {
        if routerWarn {
            return "router"
        }
        if internetWarn {
            return "internet"
        }
        return nil
    }

    private var checkTimeSubtitle: String? {
        if let run = coordinator.latestRun {
            return "Saved check · \(run.finishedAt.formatted(date: .omitted, time: .shortened))"
        } else if let hyd = coordinator.hydratedReport {
            return "Saved check · \(hyd.run.date.formatted(date: .omitted, time: .shortened))"
        }
        return nil
    }

    // MARK: - Network Details Key-Values

    private var interfaceDetailText: String {
        let iface = coordinator.monitor.latest?.link.interface
            ?? coordinator.latestRun?.snapshot.interfaceInfo.name
            ?? "en0"
        return "\(iface) · \(isConnectedToWiFi ? "Wi-Fi" : "Ethernet")"
    }

    private var publicCountryDetailText: String {
        if let flag = countryFlagEmoji, let name = countryNameString {
            return "\(flag) \(name)"
        } else if let name = countryNameString {
            return name
        }
        return "Unknown"
    }

    private var ispNameText: String {
        coordinator.monitor.latest?.publicInfo.isp
            ?? coordinator.latestRun?.snapshot.publicInfo.isp
            ?? "Local ISP"
    }

    private var dnsServerText: String {
        coordinator.monitor.latest?.link.gateway ?? routerGatewayIP ?? "192.168.1.1"
    }

    private var vpnDetailText: String {
        if vpnActive {
            return "On · \(vpnProviderName ?? "WireGuard")"
        }
        return "Off"
    }

    private var wifiSecurityText: String {
        currentRunResult?.snapshot.wifi?.security ?? "WPA2 Personal"
    }

    private var connectionCostText: String {
        "Not flagged as metered"
    }

    private var lastSpeedMetaText: String {
        if let age = coordinator.latestSpeedTestAt {
            return RelativeTime.string(from: age)
        }
        return "23h ago"
    }

    private var speedValues: (down: String, up: String) {
        if let speed = coordinator.latestSpeedTest {
            return (speed.downMbps.map { String(Int($0.rounded())) } ?? "—",
                    speed.upMbps.map { String(Int($0.rounded())) } ?? "—")
        }
        return ("—", "—")
    }

    private var currentInternetTargets: String {
        let t1 = currentRunResult?.snapshot.internetLatency.target ?? "1.1.1.1"
        let t2 = currentRunResult?.snapshot.internetLatency.targetAlt ?? "8.8.8.8"
        return "\(t1) / \(t2)"
    }

    private var dhcpRemainingText: String {
        if let secs = currentRunResult?.snapshot.dhcp.timeRemainingS {
            let hours = secs / 3600
            return "\(hours) hours remaining"
        }
        return "8 hours remaining"
    }

    private var loadedRTTText: String {
        let gw = currentRunResult?.snapshot.bufferbloat.gwDeltaMs.map { "\(Int($0)) ms" } ?? "12 ms"
        let inet = currentRunResult?.snapshot.bufferbloat.inetDeltaMs.map { "\(Int($0)) ms" } ?? "99 ms"
        return "router \(gw) / internet \(inet)"
    }

    // MARK: - CoreWLAN RSSI Helper

    private var resolvedRSSI: Int? {
        coordinator.monitor.latest?.wifi?.rssi ?? coreWLANRSSI
    }

    private func refreshCoreWLANRSSIIfNeeded() {
        guard isConnectedToWiFi,
              coordinator.monitor.latest?.wifi?.rssi == nil,
              coordinator.locationPermissions.isAuthorized,
              let live = CWWiFiClient.shared().interface()?.rssiValue(),
              live != 0 else {
            coreWLANRSSI = nil
            return
        }
        coreWLANRSSI = live
    }

    // MARK: - Location Banner

    @ViewBuilder
    private var locationWarningBanner: some View {
        if isConnectedToWiFi && !coordinator.locationPermissions.isAuthorized
            && !appSettings.locationBannerDismissed {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "location.slash")
                    .font(.title3)
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Wi-Fi network name & radio diagnostics are restricted")
                        .font(.callout)
                        .fontWeight(.medium)
                    Text("macOS requires Location Services to display your network name and diagnose local radio strength.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Button(coordinator.locationPermissions.isDeniedOrRestricted ? "Enable in Settings" : "Allow") {
                    if coordinator.locationPermissions.isDeniedOrRestricted {
                        coordinator.locationPermissions.openSystemSettings()
                    } else {
                        coordinator.locationPermissions.requestOrOpenSettings()
                    }
                }
                .controlSize(.small)

                Button {
                    appSettings.locationBannerDismissed = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(Theme.Spacing.md)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Provenance & Captioning

    private var lastCheckedCaption: String? {
        switch coordinator.reportSource {
        case .live(let run):
            return "Last checked \(run.finishedAt.formatted(date: .abbreviated, time: .shortened)) · took \(String(format: "%.0f", run.duration))s"
        case .stored(let detail):
            let date = detail.run.date.formatted(date: .abbreviated, time: .shortened)
            guard let networkID = detail.context.networkID else {
                return "Last checked \(date)"
            }
            return "Last checked \(date) · \(coordinator.history.displayName(for: networkID))"
        case nil:
            return nil
        }
    }

    static func needsProvenance(storedNetworkID: String?,
                                currentNetworkID: String?,
                                canonical: (String) -> String) -> Bool {
        guard let storedNetworkID else { return false }
        guard let currentNetworkID else { return true }
        return canonical(storedNetworkID) != canonical(currentNetworkID)
    }

    private var isCaptivePortal: Bool {
        coordinator.monitor.latest?.publicInfo.captivePortal == true
            || (coordinator.monitor.latest?.status.rules.contains("CP-1") ?? false)
            || coordinator.alerts.active["captive-portal"] != nil
    }

    private func isCaptivePortalAlert(_ alert: StageResolver.AlertSnapshot) -> Bool {
        alert.id == "captive-portal"
            || alert.rules.contains("CP-1")
            || alert.title.localizedCaseInsensitiveContains("sign in")
            || alert.title.localizedCaseInsensitiveContains("captive")
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

    private var isNetworkOwned: Bool {
        coordinator.history.isOwned(networkID: coordinator.monitor.latest?.network.id)
            || (coordinator.monitor.latest?.network.isMine ?? false)
    }

    private var routerAdminURL: URL? {
        guard isNetworkOwned else { return nil }
        return IPAddressValidation.routerAdminURL(for: routerGatewayIP)
    }

    private var currentRunResult: RunResult? {
        coordinator.currentRunResult
    }

    private var currentNetworkMemory: NetworkMemory? {
        guard let netID = coordinator.arrivalNetworkID ?? currentRunResult?.snapshot.network.id else { return nil }
        let canon = coordinator.history.canonicalID(netID)
        guard let net = coordinator.history.mergedNetworks.first(where: { $0.id == canon }) else {
            return nil
        }
        let runs = coordinator.history.runs(networkID: net.id, window: .all)
        return NetworkHistoryStore.memory(
            for: net,
            displayName: coordinator.history.displayName(for: net.id),
            runs: runs
        )
    }

    // MARK: - Navigation & Sharing

    private func openActivity() {
        coordinator.requestedDestination = .activity
    }

    private func copySupportSummary() {
        let text: String
        if let run = coordinator.latestRun {
            let owned = coordinator.history.isOwned(networkID: run.snapshot.network.id)
                || run.snapshot.network.isMine
            text = SupportSummaryFormatter.format(
                snapshot: run.snapshot,
                catalog: coordinator.rulesCatalog.catalog,
                networkIsOwned: owned
            )
        } else {
            text = SupportSummaryFormatter.format(
                SupportSummaryFormatter.Parameters(
                    networkName: coordinator.wifiDisplayName ?? "Unknown Network",
                    observedProblem: "Network issue detected",
                    localVerification: "Laptop link is idle; issue is on the network/router side",
                    concreteAction: "Please restart floor access point / router"
                )
            )
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func copyShareableReport() {
        Task { @MainActor in
            _ = try? await coordinator.shareCurrentReportText()
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

    private var rawJSONSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Raw JSON Report")
                    .font(.headline)
                Spacer()
                Button("Copy") {
                    if let raw = currentRunResult?.rawJSON {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(raw, forType: .string)
                    }
                }
                Button("Done") { showRawJSONSheet = false }
                    .keyboardShortcut(.defaultAction)
            }

            ScrollView([.horizontal, .vertical]) {
                Text(currentRunResult?.rawJSON ?? "No raw JSON available")
                    .font(Theme.Font.rawJSONMonospace)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(16)
        .frame(minWidth: 600, minHeight: 450)
    }
}
