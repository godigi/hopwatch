import SwiftUI
import AppKit
import CoreWLAN
import UniformTypeIdentifiers

/// Layer two of four: the dropdown status menu.
///
/// One swappable "stage" over a fixed instrument grid:
/// 1. Stage — a single card whose content is a function of app state
///    (healthy / alerted / testing / paused / skewed). Everything below it
///    never moves.
/// 2. One primary CTA: the occasional full check, directly under the stage.
/// 3. Heartbeat strip — a thin live sparkline of internet ping, labeled
///    with min/avg/max, directly under the CTA, proving monitoring is alive.
/// 4. Instrument grid — fixed 4x2: internet ping, internet loss, download,
///    upload / router, Wi-Fi, VPN, location. Cells never disappear; an
///    unmeasured value renders as "—".
/// 5. Change timeline — "LAST 24 HOURS" header, an "Activity" button into
///    the dashboard's Activity view, and the most recent events, sourced
///    from `coordinator.eventLog`.
/// 6. Footer: Open Dashboard, Pause/Resume Monitoring, Settings, Quit,
///    version.
struct DropdownView: View {
    @Environment(HopwatchCoordinator.self) private var coordinator
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.openWindow) private var openWindow
    /// The Wi-Fi cell's CoreWLAN fallback, cached rather than read inside
    /// `wifiCell` — see `resolvedRSSI`'s header. Refreshed by the `.task`
    /// below, at most once per incoming monitor sample.
    @State private var coreWLANRSSI: Int?
    @State private var didShare = false
    @State private var shareFeedback: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            stageSection
                .padding(.horizontal, Theme.Spacing.md)

            updateBanner

            performanceCard
                .padding(.horizontal, Theme.Spacing.md)

            connectionPathStrip
                .padding(.horizontal, Theme.Spacing.md)

            Divider().padding(.vertical, Theme.Spacing.xs)

            timelineSection
                .padding(.horizontal, Theme.Spacing.md)

            Divider().padding(.vertical, Theme.Spacing.xs)

            controlsSection
        }
        .padding(.vertical, Theme.Spacing.sm)
        .contextMenu {
            Button("Copy Redacted Report") { copyShareableReport() }
            Button("Copy for Support") { copySupportSummary() }
            Divider()
            Button("Save as Markdown (.md)…") { saveMarkdownReport() }
            Button("Save Redacted JSON (.json)…") { saveJSONReport() }
        }
        .task {
            if coordinator.history.document.runs.isEmpty {
                await coordinator.history.load()
            }
        }
        // A live CoreWLAN read on every render would make the Wi-Fi cell
        // cost a syscall per redraw of an always-visible menu; keying the
        // task on the sample sequence number throttles it to once per
        // incoming sample instead — the fast tier's own cadence (10 s,
        // 5 s degraded) is throttle enough.
        .task(id: coordinator.monitor.latest?.seq) {
            refreshCoreWLANRSSIIfNeeded()
        }
    }

    // MARK: - Stage

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
                    // Worst of the rules that actually fired, ranked by the
                    // CLI's own catalog — the same call `activeSorted` uses
                    // to order alerts, so the card's colour and the choice
                    // of *which* alert to show can't disagree.
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
    private var stageSection: some View {
        switch stage {
        case .healthy: healthyStage
        case .resolved(let res): resolvedStage(res)
        case .watching(let sev): watchingStage(sev)
        case .alerted(let alert): alertStage(alert)
        case .checking: checkingStage
        case .testing: testingStage
        case .arrived: arrivedStage
        case .paused(let reason): pausedStage(reason)
        case .skewed(let message): skewedStage(message)
        }
    }

    private func resolvedStage(_ res: StageResolver.ResolutionSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: Theme.Spacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: res.icon)
                            .foregroundStyle(.green)
                            .imageScale(.medium)
                        Text(res.title)
                            .font(.callout).fontWeight(.semibold)
                            .foregroundStyle(.green)
                    }
                    Text(res.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Button {
                    coordinator.dismissActiveResolution()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(4)
                .contentShape(Rectangle())
                .help("Dismiss")
            }
        }
        .padding(Theme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    private var healthyStage: some View {
        VStack(spacing: 4) {
            HStack(alignment: .center, spacing: Theme.Spacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .imageScale(.medium)
                        Text("All good — watching")
                            .font(.callout).fontWeight(.semibold)
                    }
                    Text(quietLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button {
                    coordinator.runFullCheck()
                } label: {
                    Label(FullCheckPolicy.controlLabel(isSafe: coordinator.fullCheckIsSafe),
                          systemImage: "stethoscope")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(coordinator.isScanning)
                .help(FullCheckPolicy.controlHelp(isSafe: coordinator.fullCheckIsSafe))
            }
            if let lastCheck = lastCheckLine {
                HStack {
                    Text("Last check \(lastCheck.relative)\(lastCheck.badge.map { " · \($0)" } ?? "")")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    if let detail = statusDetail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            } else if let detail = statusDetail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(Theme.Spacing.sm)
        .frame(maxWidth: .infinity)
        .cardStyle()
    }

    private var checkingStage: some View {
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking connection…")
                    .font(.callout).fontWeight(.semibold)
            }
            Text("Waiting for a live router and internet reading")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Wi‑Fi signal bars alone cannot verify internet access")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.sm)
        .cardStyle()
    }

    /// The card that shows the moment the CLI's verdict turns but before an
    /// alert's dwell has elapsed — the state that used to be silently
    /// `.healthy` for up to 15–25 s while the timeline below already showed
    /// the drop. `critical` reads red, `warn` reads amber; the body is the
    /// CLI's own blurb for the worst firing rule (sourced via
    /// `coordinator.headline`, the same path the menu-bar headline already
    /// uses), never a verdict authored in Swift. The tertiary line tells
    /// the user why no alert has fired yet — "confirming before notifying
    /// you" — so a red card with no banner notification is not read as a
    /// bug.
    private func watchingStage(_ sev: StageResolver.WatchingSeverity) -> some View {
        let isCritical = sev == .critical
        let tint: Color = isCritical ? .red : .orange
        let title = isCritical ? "Detecting a network problem"
                               : "Watching — needs attention"
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: Theme.Spacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: isCritical ? "exclamationmark.triangle.fill"
                                                     : "exclamationmark.triangle")
                            .foregroundStyle(tint)
                        Text(title)
                            .font(.callout).fontWeight(.semibold)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    Text(coordinator.headline)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                Button {
                    coordinator.runFullCheck()
                } label: {
                    Label("Run Check", systemImage: "stethoscope")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(coordinator.isScanning)
            }
            if let latest = coordinator.monitor.latest {
                HopAttributionCompactView(result: HopAttributionResolver.resolve(sample: latest, fallbackRSSI: coreWLANRSSI))
                    .padding(.top, 2)
            }
            Text(isCritical ? "Confirming before notifying you…"
                            : "Will alert if this keeps up.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(Theme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    /// "Nothing has changed in 3 h 12 m · on HomeNet 5G" — the headline
    /// reassurance metric. Time comes from the event store, name from
    /// the CLI-derived network identity.
    private var quietLine: String {
        var parts: [String] = []
        if let since = NetworkEvent.timeSinceLast(coordinator.eventLog.events,
                                                  now: .now) {
            // DateComponentsFormatter with minute granularity renders any
            // span under 60 s as "0m" — literally true, uselessly so seconds
            // after an event lands. Below a minute the honest string is the
            // bound, not the rounding.
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

    private func alertStage(_ alert: StageResolver.AlertSnapshot) -> some View {
        var actionTitle: String? = nil
        var action: (() -> Void)? = nil

        if alert.rules.contains("CP-1") || alert.title.localizedCaseInsensitiveContains("sign in") || alert.title.localizedCaseInsensitiveContains("captive") || (coordinator.monitor.latest?.publicInfo.captivePortal == true) {
            actionTitle = "Open Login Page"
            action = {
                if let url = URL(string: "http://captive.apple.com/hotspot-detect.html") {
                    NSWorkspace.shared.open(url)
                }
            }
        } else if isRouterAlert(alert), let routerURL = routerAdminURL {
            actionTitle = "Open Router Admin Page"
            action = {
                NSWorkspace.shared.open(routerURL)
            }
        }

        return VStack(spacing: 6) {
            AlertStageCard(
                alert: alert,
                moreCount: max(coordinator.alerts.activeSorted.count - 1, 0),
                onOpen: openActivity,
                actionButtonTitle: actionTitle,
                onAction: action
            )
            if let latest = coordinator.monitor.latest {
                HopAttributionCompactView(result: HopAttributionResolver.resolve(sample: latest, fallbackRSSI: coreWLANRSSI))
                    .padding(.horizontal, Theme.Spacing.xs)
            }
        }
    }

    private var testingStage: some View {
        VStack(alignment: .leading, spacing: 4) {
            scanningRow
        }
        .padding(.vertical, Theme.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    /// `.testing`'s card with one line added in front of it. Same
    /// container, same progress row, same Cancel button — the only thing
    /// that differs between an arrival check and a user-started one is who
    /// asked for it, so that is the only thing the card says differently.
    /// It names the network for the same reason `ArrivalCard` does: the
    /// two surfaces have to describe one moment one way.
    ///
    /// Mechanism only, like every other line here: which check is running
    /// and why it started, never what it has found.
    private var arrivedStage: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(coordinator.wifiDisplayName.map { "Checking a new network: \($0)" }
                    ?? "Checking a new network")
                .font(.callout).fontWeight(.semibold)
            scanningRow
        }
        .padding(.vertical, Theme.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func pausedStage(_ reason: String?) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "pause.circle.fill")
                    .foregroundStyle(.secondary)
                Text("Monitoring paused")
                    .font(.callout).fontWeight(.semibold)
            }
            if let reason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            if !appSettings.monitoringEnabled {
                Button("Resume monitoring") {
                    appSettings.monitoringEnabled = true
                    coordinator.setMonitoring(enabled: true)
                }
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.sm)
        .cardStyle()
    }

    private func skewedStage(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.yellow)
                Text("The hopwatch command needs attention")
                    .font(.callout).fontWeight(.semibold)
            }
            Text(message)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Settings") { openWindow(id: WindowID.settings) }
                .controlSize(.small)
        }
        .padding(Theme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: - Update Banner

    @ViewBuilder
    private var updateBanner: some View {
        let checker = coordinator.updateChecker
        if checker.hasUpdate || checker.isDownloading {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 13))
                    Text(checker.isDownloading ? checker.statusMessage : "Update available: v\(checker.availableRelease?.cleanVersion ?? "")")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    if !checker.isDownloading {
                        Button {
                            checker.downloadAndInstallUpdate()
                        } label: {
                            Text("Update & Relaunch")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
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
                    Text(notes)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
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
            .padding(.horizontal, Theme.Spacing.md)
        }
    }

    // MARK: - Performance & Live Heartbeat (Unified Card)

    private var performanceCard: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            // Left: Live Internet Latency, Loss & Sparkline
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: Theme.Spacing.sm) {
                    InstrumentCell(label: "Internet", value: internetValue.text,
                                   tint: internetValue.tint)
                    InstrumentCell(label: "Loss", value: lossValue.text,
                                   tint: lossValue.tint)
                }
                HeartbeatStrip(samples: coordinator.monitor.recent,
                               flatlined: !coordinator.monitor.isRunning
                                          || coordinator.monitor.isPaused)
                    .help("Live ping to internet over the last minute. Proves monitoring is alive.")
                HStack {
                    if coordinator.monitor.isRunning && !coordinator.monitor.isPaused {
                        let cadence = coordinator.monitor.latest?.status.cadenceS
                            ?? Defaults.fastInterval
                        Text(coordinator.monitor.isBursting
                             ? "every \(cadence)s · test"
                             : "every \(cadence)s")
                        if let stats = heartbeatStats {
                            Text("· min \(stats.min) · avg \(stats.avg) · max \(stats.max) ms")
                        }
                    } else {
                        Text("monitoring off")
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)

                if coordinator.monitor.isRunning && !coordinator.monitor.isPaused {
                    HStack(spacing: 4) {
                        Image(systemName: stability.icon)
                            .font(.system(size: 8))
                            .foregroundStyle(stability.tint)
                        Text(stability.label)
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(stability.tint)
                        if let jitter = currentJitter {
                            Text("· \(String(format: "%.0f ms jitter", jitter))")
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 1)
                    .help(stability.description)
                }
            }
            .frame(maxWidth: .infinity)

            Divider()

            // Right: Speeds
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: Theme.Spacing.sm) {
                    InstrumentCell(label: "Down", value: speedValues.down, unit: "Mbps")
                    InstrumentCell(label: "Up", value: speedValues.up, unit: "Mbps")
                }
                if let age = speedValues.age {
                    Text("speeds from test \(age)")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                } else {
                    Text("not speed tested")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(Theme.Spacing.sm)
        .cardStyle()
    }

    // MARK: - Connection Path & Context Strip (Router, Wi-Fi, VPN, Location)

    private var connectionPathStrip: some View {
        HStack(spacing: Theme.Spacing.xs) {
            InstrumentCell(label: "Router",
                           value: routerInfo?.ping ?? "—",
                           tint: routerTint)
            InstrumentCell(label: "Wi-Fi signal",
                           value: wifiCell.value,
                           unit: wifiCell.unit,
                           tint: wifiCell.tint)
            InstrumentCell(label: "VPN",
                           value: vpnActive ? (vpnName ?? "on") : "off",
                           tint: vpnActive ? .primary : .secondary)
            LocationCell(countryISO: countryISO, publicIP: publicIP)
        }
        .padding(.vertical, Theme.Spacing.xs)
        .padding(.horizontal, Theme.Spacing.xs)
        .background(.quaternary.opacity(Theme.cardOpacity),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    /// Categories of the currently fired rules, resolved through the
    /// CLI's own catalog — the CLI names the rule, the catalog names
    /// what the rule is about, and this view only maps "about" to a
    /// cell. No rule list is hardcoded here to drift out of date.
    private var firedCategories: Set<String> {
        guard let catalog = coordinator.rulesCatalog.catalog else { return [] }
        return Set(firedRules.compactMap { catalog[$0]?.category })
    }

    private var firedRules: Set<String> {
        Set(coordinator.monitor.latest?.status.rules ?? [])
    }

    private var currentJitter: Double? {
        coordinator.currentJitter
    }

    private var stability: ConnectionStability {
        coordinator.currentStability
    }

    private var internetValue: (text: String, tint: Color) {
        guard !coordinator.monitor.isPaused, !coordinator.isScanning else {
            return ("—", .primary)
        }
        if icmpFiltered { return ("n/a", .secondary) }
        guard let rtt = coordinator.monitor.latest?.internet.rttAvgMs else {
            // Total loss has no average RTT — every packet that would have
            // contributed one was dropped — so an em dash here reads as "we
            // did not look" on precisely the cycle we looked hardest. The
            // loss figure beside it is the measurement; say so.
            if let loss = coordinator.monitor.latest?.internet.lossPct, loss >= 100 {
                return ("no reply", .red)
            }
            return ("—", .primary)
        }
        return ("\(Int(rtt.rounded())) ms",
                firedCategories.contains("internet") ? .red : .primary)
    }

    /// Green here means something the other cells never claim: the CLI's
    /// own severity, not this view's opinion of a number. Available only
    /// once the catalog has loaded — without it there is no way to tell
    /// "no rule fired" from "the catalog to check against never arrived",
    /// so the safer read is no tint at all rather than a false all-clear.
    /// The CLI's own statement that ping is being dropped by policy on this
    /// network, so its loss and latency numbers describe the probe rather
    /// than the link. `statusDetail` already prints the sentence ("This
    /// network blocks ping — real connections are fine"); these cells stop
    /// printing figures that contradict it. Read from the sample, never
    /// inferred here — see CLAUDE.md on where diagnosis lives.
    private var icmpFiltered: Bool {
        !coordinator.monitor.isPaused && !coordinator.isScanning
            && coordinator.monitor.latest?.status.icmpFiltered == true
    }

    private var lossValue: (text: String, tint: Color) {
        guard !coordinator.monitor.isPaused, !coordinator.isScanning else {
            return ("—", .primary)
        }
        if icmpFiltered { return ("n/a", .secondary) }
        guard let loss = coordinator.monitor.latest?.internet.lossPct else {
            return ("—", .primary)
        }
        let text = String(format: "%.1f%%", loss)
        if firedCategories.contains("internet") { return (text, .red) }
        guard coordinator.rulesCatalog.catalog != nil else { return (text, .primary) }
        // Severity `ok` is necessary but not sufficient for green. On an
        // ICMP-filtering network the CLI is right that nothing is wrong, and
        // "100.0%" painted green is still the wrong sentence to put in front
        // of someone. `loss == 0` is not a threshold — it is the absence of
        // loss — so this stays a rendering rule, not a second opinion.
        let allClear = coordinator.monitor.latest?.status.severity == "ok" && loss == 0
        return (text, allClear ? .green : .primary)
    }

    private var routerTint: Color {
        firedCategories.contains("router") ? .red : .primary
    }

    /// RSSI arrives from the monitor's medium tier (`_mon_probe_wifi_signal`,
    /// 60 s cadence) — but that probe needs `sudo -n`, which the ordinary
    /// unprivileged GUI does not have, so `wifi.rssi` stays null for the
    /// entire session in the common case. A live CoreWLAN read (gated on
    /// Location Services, the same gate `--wifi-only` uses) is therefore
    /// the PRIMARY source for most users; the monitor's own value is used
    /// whenever it is present (a `sudo netdiag`-launched app, or a future
    /// privileged helper). `rssiValue() == 0` is CoreWLAN's own
    /// "unavailable", not a real reading. The read itself is cached in
    /// `coreWLANRSSI` rather than taken here — see that property and the
    /// view's `.task(id:)` for why a per-render syscall would be wrong.
    private var resolvedRSSI: Int? {
        coordinator.monitor.latest?.wifi?.rssi ?? coreWLANRSSI
    }

    /// The Wi-Fi cell's (value, unit, tint) — the CLI's own word as the
    /// value and the raw dBm underneath (`SignalScale.cellContent`,
    /// shared with `HomeView`'s Wi-Fi row), with one override on top: the
    /// severity of a fired Wi-Fi rule outranks the instantaneous signal
    /// band. A warning stays yellow; a critical or disconnected link is
    /// red; otherwise the scale's own green/yellow tint is rendered.
    private var wifiCell: (value: String, unit: String?, tint: Color) {
        if coordinator.monitor.latest?.link.up == false {
            return ("disconnected", nil, .red)
        }
        guard coordinator.monitor.latest?.link.isWiFi == true else {
            return ("wired", nil, .secondary)
        }
        let content = SignalScale.cellContent(rssi: resolvedRSSI, scale: coordinator.signalScale.scale)
        return (content.value, content.unit, wifiRuleTint ?? content.tint)
    }

    /// Colour mapping only: which rules fired and what severity the CLI's
    /// catalog gives them are already decided outside the GUI. `varies`
    /// uses the incident-specific severity carried by this monitor sample.
    private var wifiRuleTint: Color? {
        guard let catalog = coordinator.rulesCatalog.catalog else { return nil }
        let hits = firedRules.compactMap { catalog[$0] }
            .filter { $0.categories.contains("wifi") }
        guard !hits.isEmpty else { return nil }
        if hits.contains(where: { $0.severity == "critical" }) { return .red }
        if hits.contains(where: { $0.severity == "warn" }) { return .yellow }
        if hits.contains(where: { $0.severity == "varies" }) {
            return coordinator.monitor.latest?.status.severity == "critical" ? .red : .yellow
        }
        // Informational Wi-Fi rules (for example, a hidden network name)
        // say nothing about radio strength and must not replace its colour.
        return nil
    }

    private func refreshCoreWLANRSSIIfNeeded() {
        guard coordinator.monitor.latest?.link.isWiFi == true,
              coordinator.monitor.latest?.wifi?.rssi == nil,
              coordinator.locationPermissions.isAuthorized,
              let live = CWWiFiClient.shared().interface()?.rssiValue(),
              live != 0 else {
            coreWLANRSSI = nil
            return
        }
        coreWLANRSSI = live
    }

    private var speedValues: (down: String, up: String, age: String?) {
        if let speed = coordinator.latestSpeedTest {
            let age = coordinator.latestSpeedTestAt
                .map { RelativeTime.string(from: $0) }
            return (speed.downMbps.map { String(Int($0.rounded())) } ?? "—",
                    speed.upMbps.map { String(Int($0.rounded())) } ?? "—",
                    age)
        }
        if let stored = coordinator.history.latestSpeedTest(
            for: coordinator.monitor.latest?.network.historyJoinID) {
            return (String(Int(stored.down.rounded())),
                    stored.up.map { String(Int($0.rounded())) } ?? "—",
                    RelativeTime.string(from: stored.date))
        }
        return ("—", "—", nil)
    }

    /// Same 60-sample window `HeartbeatStrip` plots, summarized as
    /// min/avg/max so the strip's shape has numbers beside it. Hidden
    /// below two points: a min/avg/max of one number is not a range.
    private var heartbeatStats: (min: Int, avg: Int, max: Int)? {
        let values = coordinator.monitor.recent.suffix(60)
            .compactMap { $0.internet.rttAvgMs }
        guard values.count >= 2, let minV = values.min(), let maxV = values.max()
        else { return nil }
        let avgV = values.reduce(0, +) / Double(values.count)
        return (Int(minV.rounded()), Int(avgV.rounded()), Int(maxV.rounded()))
    }

    // MARK: - Timeline (Recent Activity)

    private var timelineSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack {
                Text("RECENT ACTIVITY")
                    .font(.system(size: 9, weight: .semibold))
                    .kerning(0.5)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Activity") { openActivity() }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            }
            // Folded into episodes before being truncated to three, for the
            // same reason Activity folds: unfolded, a single flapping rule
            // ate all three rows of the app's most space-constrained
            // surface — "Minor packet loss to router", "Resolved: Minor
            // packet loss to router", "Minor packet loss to router" — three
            // lines that between them said one thing and never said how
            // long it lasted. Folded, that is one line carrying the count
            // and the duration, and the other two rows go to the next two
            // things that actually happened.
            let recent = Array(ActivityEntry.fold(timelineEvents).prefix(3))
            if recent.isEmpty {
                Text("No changes in the last 24 hours")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 3) {
                    ForEach(recent) { ActivityRow(entry: $0) }
                }
            }
        }
    }

    /// The last 24 hours, minus whatever the stage card directly above is
    /// already saying.
    ///
    /// `AlertEngine` firing writes an `alert` event whose summary is the
    /// alert's own title (`NetdiagCoordinator.handleAlertFired`), and the
    /// stage card renders that same title. Unfiltered, one incident
    /// therefore printed twice on one 360pt panel — "Internet connection
    /// degraded" as a red card, and "Internet connection degraded" again as
    /// a red timeline row 150pt below, carrying a *different* timestamp
    /// (the event is stamped when the dwell elapses, the card counts from
    /// `raisedAt`). Two areas, two ages, one problem.
    ///
    /// Only the exact echo is dropped, and only from this three-row teaser:
    /// the `rule-fired` row beneath it is the CLI's own words for what
    /// fired ("Moderate internet packet loss") and says something the
    /// category label does not, and Activity still lists every event
    /// including this one. Nothing is deleted — this is a rendering rule,
    /// not a change to what gets recorded.
    private var timelineEvents: [NetworkEvent] {
        let events = coordinator.eventLog.within(hours: 24)
        guard case .alerted(let alert) = stage else { return events }
        return events.filter { !($0.kind == "alert" && $0.summary == alert.title) }
    }

    // MARK: - System Controls & Footer

    private var controlsSection: some View {
        VStack(spacing: 2) {
            dropdownButton("Open Dashboard", icon: "rectangle.on.rectangle") {
                // Explicit, not just "whatever the window happens to be
                // showing": without this, a single earlier trip to Activity
                // (via `openActivity()` below) would leave every later
                // "Open Dashboard" landing back on Activity forever — this
                // row's whole point is Home. `MainWindow` applies the
                // request whether it's opening the window fresh (`.task`)
                // or the window is already open (`.onChange`).
                coordinator.requestedDestination = .home
                openWindow(id: WindowID.dashboard)
                // Opened from a menu-bar extra the window arrives behind
                // whatever is frontmost; every other window-opening row
                // here activates for the same reason.
                NSApp.activate(ignoringOtherApps: true)
            }

            dropdownButton(appSettings.monitoringEnabled ? "Pause Monitoring" : "Resume Monitoring",
                           icon: appSettings.monitoringEnabled ? "pause" : "play") {
                let enabled = !appSettings.monitoringEnabled
                appSettings.monitoringEnabled = enabled
                coordinator.setMonitoring(enabled: enabled)
            }

            if let routerURL = routerAdminURL {
                dropdownButton("Open Router Admin Page", icon: "network") {
                    NSWorkspace.shared.open(routerURL)
                }
            }

            // Open Dashboard + Pause/Resume above the line, Share Diagnostics +
            // Settings + Quit below — the same horizontal inset the rows
            // themselves use (via `dropdownButton`) so it doesn't run flush to
            // the panel edge the way an unpadded Divider would.
            Divider()
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.xs)

            Menu {
                Button("Copy Redacted Report") {
                    copyShareableReport()
                }
                Button("Copy for Support") {
                    copySupportSummary()
                }
                Divider()
                Button("Save as Markdown (.md)…") {
                    saveMarkdownReport()
                }
                Button("Save Redacted JSON (.json)…") {
                    saveJSONReport()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: didShare ? "checkmark" : "square.and.arrow.up")
                        .frame(width: 16)
                    Text(shareFeedback ?? "Share Diagnostics…")
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, 5)
            }
            .menuStyle(.borderlessButton)

            dropdownButton("Settings…", icon: "gearshape") {
                openWindow(id: WindowID.settings)
                NSApp.activate(ignoringOtherApps: true)
            }

            dropdownButton("Quit Hopwatch", icon: "power") {
                coordinator.stop()
                NSApp.terminate(nil)
            }

            HStack {
                Text("Hopwatch v\(Defaults.appVersion)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)

                if coordinator.updateChecker.hasUpdate {
                    Text("·")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Button {
                        coordinator.updateChecker.downloadAndInstallUpdate()
                    } label: {
                        HStack(spacing: 2) {
                            Text("Update available (\(coordinator.updateChecker.availableRelease?.cleanVersion ?? "new"))")
                            Image(systemName: "arrow.up.circle.fill")
                        }
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.top, 4)
        }
    }

    private func dropdownButton(_ title: String, icon: String,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).frame(width: 16)
                Text(title)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(HighlightingButtonStyle())
    }

    private func copySupportSummary() {
        let text: String
        let owned = coordinator.history.isOwned(networkID: coordinator.monitor.latest?.network.id)
        if let latestSample = coordinator.monitor.latest {
            text = SupportSummaryFormatter.format(
                sample: latestSample,
                alert: coordinator.alerts.activeSorted.first.map {
                    StageResolver.AlertSnapshot(
                        title: $0.title, body: $0.body,
                        raisedAt: $0.raisedAt, rules: $0.rules,
                        severityRank: $0.rules.map(coordinator.severityRank(forRuleID:)).max() ?? 0
                    )
                },
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
                _ = try await coordinator.shareCurrentReportText()
                shareFeedback = "Diagnostic report copied"
                didShare = true
                try? await Task.sleep(for: .seconds(2))
                shareFeedback = nil
                didShare = false
            } catch {
                shareFeedback = "Couldn't build report"
                try? await Task.sleep(for: .seconds(2))
                shareFeedback = nil
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
        coordinator.history.isOwned(networkID: coordinator.monitor.latest?.network.id)
            || (coordinator.monitor.latest?.network.isMine ?? false)
    }

    private var routerGatewayIP: String? {
        coordinator.monitor.latest?.link.gateway
            ?? coordinator.latestRun?.snapshot.gateway.ip
            ?? coordinator.hydratedReport?.run.gateway.ip
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

    // MARK: - Kept glance values (unchanged from the pre-redesign dropdown)

    /// Only two branches survive here: every other case `statusDetail` used
    /// to cover (scanning, paused, monitoring off, a skewed CLI) now has its
    /// own stage above `healthyStage` and can no longer reach this code —
    /// `stage` returns `.healthy` only once scanning, paused-for-any-reason,
    /// monitoring-off and skewed have all tested false.
    private var statusDetail: String? {
        if coordinator.monitor.isBursting {
            return "Latency test running — sampling every \(appSettings.latencyTestInterval)s."
        }
        if let sample = coordinator.monitor.latest, sample.status.icmpFiltered {
            return "This network blocks ping — real connections are fine."
        }
        return nil
    }

    private var scanningRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                ScanProgressLine(progress: coordinator.progress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            Button("Cancel check") { coordinator.cancelScan() }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func openActivity() {
        coordinator.requestedDestination = .activity
        openWindow(id: WindowID.dashboard)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var publicIP: String? {
        let ip = coordinator.monitor.latest?.publicInfo.ip
            ?? coordinator.latestRun?.snapshot.publicInfo.ip
            ?? coordinator.hydratedReport?.run.publicInfo.ip
        return (ip?.isEmpty ?? true) ? nil : ip
    }

    private var countryISO: String? {
        coordinator.monitor.latest?.publicInfo.countryISO
            ?? coordinator.latestRun?.snapshot.publicInfo.countryISO
            ?? coordinator.hydratedReport?.run.publicInfo.countryISO
    }

    private var routerInfo: (ping: String, ip: String?)? {
        // The monitor is paused during a scan, and its last sample is then a
        // stale pre-scan reading. A stored run is useful history but must not
        // be presented as the router's current latency.
        guard !coordinator.monitor.isPaused, !coordinator.isScanning,
              let sample = coordinator.monitor.latest else { return nil }
        let ip = sample.link.gateway
        let rtt = sample.gateway.rttAvgMs
        let loss = sample.gateway.lossPct

        guard let current = rtt else {
            guard let ip else { return nil }
            // Ping blocked by policy, total loss, or simply not measured
            // yet — three different statements, and an em dash for all
            // three is how a dead router came to look like an idle one.
            if icmpFiltered { return ("n/a", ip) }
            if let loss, loss >= 100 { return ("no reply", ip) }
            return ("—", ip)
        }
        let pingStr: String
        if let loss, loss > 0 {
            pingStr = String(format: "%.0f ms · %.0f%% loss", current, loss)
        } else {
            pingStr = String(format: "%.0f ms", current)
        }
        return (pingStr, ip)
    }

    private var vpnActive: Bool {
        coordinator.monitor.latest?.vpn.active
            ?? coordinator.latestRun?.snapshot.vpn.active
            ?? coordinator.hydratedReport?.run.vpn.active ?? false
    }

    private var vpnName: String? {
        coordinator.monitor.latest?.vpn.name
            ?? coordinator.latestRun?.snapshot.vpn.name
            ?? coordinator.hydratedReport?.run.vpn.name
    }

    /// The badge says where the report came from, never why the scan ran.
    /// `coordinator.scanKind` is the `reason` string passed to `launch`, and
    /// for an alert-triggered scan that string is "checking <alert title>" —
    /// so the card rendered "Last check 36m ago · checking internet
    /// connection degraded" over a green all-clear, naming an alert that was
    /// already listed, with its own timestamp, in the activity list directly
    /// below. Two places showing the same event, one of them stale and
    /// phrased in the present tense.
    ///
    /// The stage card states the present condition; the activity list holds
    /// the history. A scan's motive belongs to the alert that caused it.
    private var lastCheckLine: (relative: String, badge: String?)? {
        switch coordinator.reportSource {
        case .live(let run):
            return (RelativeTime.string(from: run.finishedAt), nil)
        case .stored(let detail):
            return (RelativeTime.string(from: detail.run.date), "from history")
        case .none:
            return nil
        }
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
