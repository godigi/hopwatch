import SwiftUI

/// Where another surface can send the main window: a sidebar section, or a
/// specific stored run to open in place. Declared outside the view — the
/// same shape the old tab-shell's selector type used — so the coordinator
/// can hold one without the window having to exist yet.
enum MainDestination: Equatable {
    case home, live, activity, trends, networks
    /// Selects Home (see `MainWindow.handle`) with this run pushed onto its
    /// navigation path, rather than a dedicated presentation: a stored run
    /// is a deeper look at "is my network OK?", the question Home already
    /// answers, not a sixth question that needs its own section.
    case run(RunRoute)
}

/// The sidebar's five rows. A separate type from `MainDestination` because
/// a destination can also name "a specific run", which isn't a row —
/// folding the two together would leave `List(selection:)` holding a case
/// it has no row to represent.
enum SidebarSection: String, CaseIterable, Identifiable {
    case home, live, activity, trends, networks

    var id: String { rawValue }

    var label: String {
        switch self {
        case .home:     return "Overview"
        case .live:     return "Live monitoring"
        case .activity: return "Activity"
        case .trends:   return "Trends"
        case .networks: return "Networks"
        }
    }

    var icon: String {
        switch self {
        case .home:     return "macwindow"
        case .live:     return "waveform.path.ecg"
        case .activity: return "bell"
        case .trends:   return "chart.xyaxis.line"
        case .networks: return "wifi"
        }
    }
}

/// The main window: a sidebar of the questions a user actually has ("is my
/// network OK right now, and why?", "what's happening live?", "what
/// changed?", "which networks have I been on?") replacing the four
/// segmented tabs `DashboardWindow` used to show. Built from
/// `nimbalyst-local/mockups/netdiag-main-window.mockup.html` and redesigned per
/// `docs/design/hopwatch-dashboard.mockup.html`.
struct MainWindow: View {
    @Environment(HopwatchCoordinator.self) private var coordinator
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.openWindow) private var openWindow
    @State private var selection: SidebarSection? = .home
    /// Home's own navigation path, owned here rather than inside `HomeView`
    /// so a `.run(route)` request — which may arrive before this window
    /// exists at all — can push straight onto it without a second channel
    /// back down into the view that owns the list.
    @State private var homePath = NavigationPath()

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                toolbarRightContent
            }
        }
        .task {
            // Both paths are needed: `.task` catches a request made while
            // the window did not exist yet, `.onChange` catches one made
            // while it was already open behind another app — the same
            // two-path shape `DashboardWindow` used before this replaced
            // it.
            if let requested = coordinator.consumeRequestedDestination() { handle(requested) }
            await coordinator.history.load()
        }
        .onChange(of: coordinator.requestedDestination) { _, new in
            guard new != nil, let requested = coordinator.consumeRequestedDestination() else { return }
            handle(requested)
        }
        .onAppear { coordinator.windowAppeared() }
        .onDisappear { coordinator.windowDisappeared() }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            // Brand header
            HStack(spacing: 8) {
                AppBrandMark()
                    .frame(width: 24, height: 24)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("Hopwatch")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.ColorToken.ink)
                    Text("v\(AppVersion.display)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.ColorToken.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            List(selection: $selection) {
                ForEach(SidebarSection.allCases) { section in
                    row(section).tag(section)
                }
            }
            .listStyle(.sidebar)

            Divider()

            // Mini network card
            sidebarNetworkCard

            // Settings button
            Button {
                openWindow(id: WindowID.settings)
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                    Text("Settings")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(Theme.ColorToken.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)

            monitoringStatusLine
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.sm)
        }
    }

    private var sidebarNetworkCard: some View {
        let isWiFi = coordinator.monitor.latest?.link.isWiFi ?? true
        let name = coordinator.wifiDisplayName
            ?? coordinator.monitor.latest?.link.ssid
            ?? coordinator.latestRun?.snapshot.wifi?.ssid
            ?? "Disconnected"

        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: isWiFi ? "wifi" : "cable.connector")
                    .font(.system(size: 12))
                Text(name)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(Theme.ColorToken.ink)

            Text("Current network")
                .font(.system(size: 10))
                .foregroundStyle(Theme.ColorToken.muted)
                .padding(.leading, 18)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var toolbarRightContent: some View {
        HStack(spacing: 12) {
            Text(updatedAgeText)
                .font(.system(size: 11))
                .foregroundStyle(Theme.ColorToken.muted)

            HStack(spacing: 5) {
                Circle()
                    .fill(statusPillColor)
                    .frame(width: 6, height: 6)
                Text(statusPillText)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(statusPillColor)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(statusPillBackground)
            .clipShape(Capsule())

            Button {
                let enabled = !appSettings.monitoringEnabled
                appSettings.monitoringEnabled = enabled
                coordinator.setMonitoring(enabled: enabled)
            } label: {
                Image(systemName: appSettings.monitoringEnabled ? "pause.fill" : "play.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ColorToken.muted)
            }
            .buttonStyle(.plain)
            .help(appSettings.monitoringEnabled ? "Pause monitoring" : "Resume monitoring")
        }
    }

    private var updatedAgeText: String {
        guard let ts = coordinator.monitor.latest?.timestamp else { return "Waiting for first sample" }
        return "Updated \(RelativeTime.string(from: ts))"
    }

    private var statusPillText: String {
        if coordinator.isScanning { return "Checking" }
        if coordinator.monitor.isPausedForAnyReason || !appSettings.monitoringEnabled { return "Paused" }
        if coordinator.monitor.latest?.status.severity == "critical" { return "Problem" }
        if coordinator.monitor.latest?.status.severity == "warn" { return "Degraded" }
        return "Watching"
    }

    private var statusPillColor: Color {
        if coordinator.isScanning { return Theme.ColorToken.blue }
        if coordinator.monitor.isPausedForAnyReason || !appSettings.monitoringEnabled { return Theme.ColorToken.muted }
        if coordinator.monitor.latest?.status.severity == "critical" { return .red }
        if coordinator.monitor.latest?.status.severity == "warn" { return Theme.ColorToken.amber }
        return Theme.ColorToken.green
    }

    private var statusPillBackground: Color {
        if coordinator.isScanning { return Theme.ColorToken.blueWash }
        if coordinator.monitor.isPausedForAnyReason || !appSettings.monitoringEnabled { return Theme.ColorToken.neutralWash }
        if coordinator.monitor.latest?.status.severity == "critical" { return Theme.ColorToken.redWash }
        if coordinator.monitor.latest?.status.severity == "warn" { return Theme.ColorToken.amberWash }
        return Theme.ColorToken.greenWash
    }

    @ViewBuilder
    private func row(_ section: SidebarSection) -> some View {
        // Activity's badge counts alerts already active right now — the
        // same `activeSorted` the dropdown's banner reads — never a stored
        // history, which doesn't exist until T13 builds it.
        if section == .activity, !coordinator.alerts.activeSorted.isEmpty {
            Label {
                HStack {
                    Text(section.label)
                    Spacer()
                    Text("\(coordinator.alerts.activeSorted.count)")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.red, in: Capsule())
                        .foregroundStyle(.white)
                }
            } icon: {
                Image(systemName: section.icon)
            }
        } else {
            Label(section.label, systemImage: section.icon)
        }
    }

    /// "Monitoring · every 10s". `DropdownView.stage` is the single source
    /// of truth for which of these states shows — scanning, off, paused,
    /// or a stale error; `DropdownView.statusDetail` no longer covers any
    /// of them, it only distinguishes bursting from ICMP-filtered inside
    /// the healthy state. This line reads the same underlying
    /// `MonitorStream`/`AppSettings` state rather than deriving a verdict
    /// of its own, so the sidebar and the dropdown never say two different
    /// things about why monitoring looks the way it does. Its check order
    /// (bursting, then a pause reason, then off, then a stale error)
    /// differs from `stage`'s (off before pause), but `pauseReason` is nil
    /// whenever monitoring is off — `MonitorStream.stop()` clears it — so
    /// the two never actually disagree. Unlike `stage` this line has no
    /// case for a scan in progress (a check running is a separate action,
    /// not a monitoring state) and never mentions ICMP-filtered — it
    /// states one fact, cadence and whether the app is watching at all,
    /// never a verdict about what the cadence found.
    private var monitoringStatusLine: some View {
        HStack(spacing: 6) {
            Circle().fill(monitoringDotColor).frame(width: 7, height: 7)
            Text(monitoringLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var monitoringLabel: String {
        if coordinator.monitor.isBursting {
            return "Latency test · every \(appSettings.latencyTestInterval)s"
        }
        if let reason = coordinator.monitor.pauseReason { return "Paused — \(reason)" }
        guard appSettings.monitoringEnabled else { return "Monitoring is off" }
        if let error = coordinator.monitor.lastError { return error }
        if !coordinator.monitor.isRunning { return "Starting…" }
        return "Monitoring · every \(appSettings.fastInterval)s"
    }

    private var monitoringDotColor: Color {
        guard appSettings.monitoringEnabled, coordinator.monitor.isRunning else { return .secondary }
        return coordinator.monitor.isPausedForAnyReason ? .yellow : .green
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .home {
        case .home:
            NavigationStack(path: $homePath) {
                HomeView()
                    .navigationDestination(for: RunRoute.self) { route in
                        RunDetailView(route: route)
                    }
            }
        case .live:     LiveView()
        case .activity: ActivityView()
        case .trends:   TrendsView()
        case .networks:
            // Keeps its own internal NavigationStack (Browse checks →
            // RunDetail) exactly as it was — see NetworksView's header.
            NetworksView()
        }
    }

    // MARK: - Routing

    private func handle(_ destination: MainDestination) {
        switch destination {
        case .home:     selection = .home; homePath = NavigationPath()
        case .live:     selection = .live
        case .activity: selection = .activity
        case .trends:   selection = .trends
        case .networks: selection = .networks
        case .run(let route):
            selection = .home
            homePath = NavigationPath([route])
        }
    }
}
