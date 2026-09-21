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

                // 3. What Should Work (Suitability Strip)
                suitabilityStripSection

                // 4. Connection Path Panel
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

                // 5. Main 2-Column Dashboard Grid
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

                // 5. Connection Reliability Strip
                reliabilityStripSection

                // 6. Bottom 2-Column Grid
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

                // 7. Technical Detail Disclosure Panel
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

    // MARK: - Reliability Strip Section

    private var reliabilityStripSection: some View {
        let avail = currentRunResult?.snapshot.availability
        let unobserved = avail?.unobservedPct.map { "\($0)%" } ?? "0%"
        let outages = avail?.outages.map { "\($0) outages" } ?? "0 outages"
        let downtime = avail?.downtimeS.map { formatSeconds($0) } ?? "0s"
        let longest = avail?.longestOutageS.map { formatSeconds($0) } ?? "0s"

        return DashboardReliabilityStrip(
            unobservedFraction: unobserved,
            outageCount: outages,
            totalDowntime: downtime,
            longestOutage: longest
        )
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

        // 1. Router
        let gwRtt = snap?.gateway.rttAvgMs ?? coordinator.monitor.latest?.gateway.rttAvgMs
        let gwLoss = snap?.gateway.lossPct ?? coordinator.monitor.latest?.gateway.lossPct ?? 0
        let gwUsual = mem?.typicalGatewayLatencyMs.map { String(format: "%.1f ms", $0) } ?? "—"
        let isRoamBlip = coordinator.hasRecentRoam && gwLoss < 10.0
        let gwText = gwRtt != nil ? (isRoamBlip ? "\(Int(round(gwRtt!))) ms · roamed" : "\(Int(round(gwRtt!))) ms · \(Int(round(gwLoss)))% loss") : "—"
        rows.append(.init(
            id: "router",
            icon: (!isRoamBlip && gwLoss >= 3.0) ? "exclamationmark.triangle.fill" : "network",
            label: "Router",
            measured: gwText,
            subvalue: nil,
            usual: gwUsual,
            isWarning: !isRoamBlip && gwLoss >= 3.0,
            isGood: (isRoamBlip || gwLoss < 1.0) && gwRtt != nil
        ))

        // 2. Internet
        let inetRtt = snap?.internetLatency.rttAvgMs ?? coordinator.monitor.latest?.internet.rttAvgMs
        let inetJitter = snap?.internetLatency.rttJitterMs ?? coordinator.currentJitter ?? 0
        let inetUsual = mem?.typicalInternetLatencyMs.map { String(format: "%.1f ms", $0) } ?? "—"
        let inetText = inetRtt != nil ? "\(Int(round(inetRtt!))) ms · \(Int(round(inetJitter))) ms jitter" : "—"
        rows.append(.init(
            id: "internet",
            icon: inetRtt != nil && inetRtt! > 120 ? "exclamationmark.triangle.fill" : "globe",
            label: "Internet",
            measured: inetText,
            subvalue: nil,
            usual: inetUsual,
            isWarning: inetRtt != nil && inetRtt! > 120,
            isGood: inetRtt != nil && inetRtt! <= 120
        ))

        // 3. Internet packet loss
        let loss1 = snap?.internetLatency.lossPct ?? coordinator.monitor.latest?.internet.lossPct ?? 0
        let loss2 = snap?.internetLatency.lossPctAlt ?? loss1
        let lossText = String(format: "%.0f%% / %.0f%%", loss1, loss2)
        rows.append(.init(
            id: "loss",
            icon: loss1 >= 3.0 ? "exclamationmark.triangle.fill" : "checkmark",
            label: "Internet packet loss",
            measured: lossText,
            subvalue: nil,
            usual: "0%",
            isWarning: loss1 >= 3.0,
            isGood: loss1 < 1.0
        ))

        // 4. DNS
        let dnsTotal = snap?.dns.count ?? 0
        let dnsOk = snap?.dns.filter(\.ok).count ?? 0
        let dnsText = dnsTotal > 0 ? "\(dnsOk) of \(dnsTotal) resolvers OK" : "All lookups healthy"
        rows.append(.init(
            id: "dns",
            icon: dnsTotal > 0 && dnsOk < dnsTotal ? "exclamationmark.triangle.fill" : "checkmark",
            label: "Name lookups (DNS)",
            measured: dnsText,
            subvalue: nil,
            usual: "—",
            isWarning: dnsTotal > 0 && dnsOk < dnsTotal,
            isGood: dnsTotal == 0 || dnsOk == dnsTotal
        ))

        // 5. Wi-Fi signal / noise
        let rssi = resolvedRSSI
        let snr = snap?.wifi?.snr
        let wifiUsual = "−62 dBm"
        let wifiText: String = {
            if let r = rssi, let s = snr {
                return "\(r) dBm · SNR \(s) dB"
            } else if let r = rssi {
                return "\(r) dBm"
            }
            return isConnectedToWiFi ? "Connected" : "Ethernet wired"
        }()
        rows.append(.init(
            id: "wifi",
            icon: isConnectedToWiFi ? "wifi" : "cable.connector",
            label: isConnectedToWiFi ? "Wi-Fi signal / noise" : "Ethernet link",
            measured: wifiText,
            subvalue: nil,
            usual: isConnectedToWiFi ? wifiUsual : "—",
            isWarning: rssi != nil && rssi! < -75,
            isGood: rssi != nil && rssi! >= -70
        ))

        // 6. Lag under load (Bufferbloat)
        let bb = snap?.bufferbloat
        let bbRouterGrade = bb?.gwGrade ?? "A"
        let bbRouterAdded = bb?.gwDeltaMs.map { String(format: "+%.0f ms", $0) } ?? "+3 ms"
        let bbInetGrade = bb?.inetGrade ?? "A"
        let bbInetAdded = bb?.inetDeltaMs.map { String(format: "+%.0f ms", $0) } ?? "+15 ms"
        rows.append(.init(
            id: "bufferbloat",
            icon: bbInetGrade == "D" || bbInetGrade == "F" ? "exclamationmark.triangle.fill" : "checkmark",
            label: "Lag under load",
            measured: "Router \(bbRouterGrade) (\(bbRouterAdded))",
            subvalue: "Internet \(bbInetGrade) (\(bbInetAdded))",
            usual: "+3 ms router",
            isWarning: bbInetGrade == "D" || bbInetGrade == "F",
            isGood: bbInetGrade != "D" && bbInetGrade != "F"
        ))

        // 7. Packet size (MTU)
        let mtu = snap?.mtu.effective ?? snap?.mtu.pathSize ?? 1500
        rows.append(.init(
            id: "mtu",
            icon: "checkmark",
            label: "Packet size (MTU)",
            measured: "\(mtu) bytes",
            subvalue: nil,
            usual: "—",
            isWarning: false,
            isGood: true
        ))

        // 8. IPv6
        let ipv6Avail = snap?.ipv6.available ?? false
        rows.append(.init(
            id: "ipv6",
            icon: "globe",
            label: "IPv6",
            measured: ipv6Avail ? "Available" : "Not available",
            subvalue: ipv6Avail ? nil : "IPv4-only connection",
            usual: "—",
            isWarning: false,
            isGood: ipv6Avail
        ))

        // 9. Web connections
        let webOk = snap?.tcpReach.first?.ok ?? true
        rows.append(.init(
            id: "web",
            icon: webOk ? "checkmark" : "exclamationmark.triangle.fill",
            label: "Web connections",
            measured: webOk ? "TCP 443 reachable" : "TCP 443 blocked",
            subvalue: nil,
            usual: "—",
            isWarning: !webOk,
            isGood: webOk
        ))

        // 10. VPN
        rows.append(.init(
            id: "vpn",
            icon: "shield",
            label: "VPN",
            measured: vpnActive ? "On · \(vpnProviderName ?? "Active")" : "Off",
            subvalue: nil,
            usual: "—",
            isWarning: false,
            isGood: true
        ))

        // 11. Clock
        let drift = snap?.ntp.driftSeconds.map { String(format: "%+.2f s drift", $0) } ?? "+0.01 s drift"
        rows.append(.init(
            id: "clock",
            icon: "checkmark",
            label: "Clock",
            measured: drift,
            subvalue: nil,
            usual: "+0.01 s",
            isWarning: false,
            isGood: true
        ))

        // 12. Speed test
        let speedDown = snap?.speedtest?.downMbps ?? coordinator.latestSpeedTest?.downMbps
        let speedUp = snap?.speedtest?.upMbps ?? coordinator.latestSpeedTest?.upMbps
        let speedText: String = {
            if let d = speedDown, let u = speedUp {
                return String(format: "↓ %.0f · ↑ %.0f Mbps", d, u)
            }
            return "Skipped in this check"
        }()
        rows.append(.init(
            id: "speed",
            icon: "waveform.path.ecg",
            label: "Speed test",
            measured: speedText,
            subvalue: nil,
            usual: "—",
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
