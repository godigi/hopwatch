import SwiftUI
import AppKit

/// SettingsView — Integrated dashboard tab for Hopwatch preferences,
/// check intervals, notification rules, system permissions, and diagnostics engine.
///
/// Organized into 4 focused categories:
/// 1. General (Monitoring, cadences, battery, menu bar & dock, Wi-Fi recovery)
/// 2. Alerts & Automation (System permissions, notifications, automatic scans, alert catalog)
/// 3. Diagnostics & CLI (hopwatch CLI path, data storage in ~/hopwatch, setup tour)
/// 4. Updates & System (Version checks, CLI capabilities handshake, crash telemetry)
struct SettingsView: View {
    @Environment(HopwatchCoordinator.self) private var coordinator
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.openWindow) private var openWindow

    enum Tab: String, CaseIterable, Identifiable {
        case general = "General"
        case alerts = "Alerts & Automation"
        case diagnostics = "Diagnostics & CLI"
        case about = "Updates & System"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .general:     return "gearshape.fill"
            case .alerts:      return "bell.badge.fill"
            case .diagnostics: return "terminal.fill"
            case .about:       return "info.circle.fill"
            }
        }
    }

    @State private var selectedTab: Tab = .general
    @State private var capabilities: CapabilityState?
    @State private var isRechecking = false
    @State private var alertSearchText = ""
    @State private var selectedAlertCategory: AlertCategory = .all
    @State private var copiedPathToast: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            Divider()

            ScrollView {
                VStack(spacing: 24) {
                    switch selectedTab {
                    case .general:
                        generalSection
                    case .alerts:
                        alertsSection
                    case .diagnostics:
                        diagnosticsSection
                    case .about:
                        aboutSection
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .background(Theme.ColorToken.cardBackground.opacity(0.35))
        .task {
            capabilities = await CapabilityStore.shared.current()
            await coordinator.alerts.refreshAuthorization()
            coordinator.locationPermissions.refresh()
        }
        .onAppear {
            coordinator.windowAppeared()
        }
        .onDisappear {
            coordinator.windowDisappeared()
            coordinator.applyCadenceSettings()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                await coordinator.alerts.refreshAuthorization()
                coordinator.locationPermissions.refresh()
            }
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Settings")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Theme.ColorToken.ink)
                    Text("Configure monitoring frequency, desktop alerts, system integration, and diagnostics.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.ColorToken.muted)
                }
                Spacer()
            }

            // Custom Segmented Pill Tab Bar
            HStack(spacing: 6) {
                ForEach(Tab.allCases) { tab in
                    tabButton(tab)
                }
            }
            .padding(3)
            .background(Theme.ColorToken.nodeBackground)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(Theme.ColorToken.line, lineWidth: 1)
            )
        }
        .padding(.horizontal, 32)
        .padding(.top, 20)
        .padding(.bottom, 14)
        .background(Theme.ColorToken.nodeBackground.opacity(0.8))
    }

    private func tabButton(_ tab: Tab) -> some View {
        let isSelected = selectedTab == tab
        let hasBadge = tabBadgeIndicator(tab)

        return Button {
            withAnimation(.snappy(duration: 0.18)) {
                selectedTab = tab
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: tab.icon)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))

                Text(tab.rawValue)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))

                if hasBadge {
                    Circle()
                        .fill(tabBadgeColor(tab))
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(isSelected ? Theme.ColorToken.ink : Theme.ColorToken.muted)
            .background(isSelected ? Theme.ColorToken.nodeBackground : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .shadow(color: isSelected ? Color.black.opacity(0.06) : Color.clear, radius: 2, y: 1)
        }
        .buttonStyle(.plain)
    }

    private func tabBadgeIndicator(_ tab: Tab) -> Bool {
        switch tab {
        case .alerts:
            return !coordinator.alerts.notificationsAuthorized || !coordinator.locationPermissions.isAuthorized
        case .about:
            return coordinator.updateChecker.hasUpdate
        default:
            return false
        }
    }

    private func tabBadgeColor(_ tab: Tab) -> Color {
        switch tab {
        case .alerts:
            return Theme.ColorToken.amber
        case .about:
            return Theme.ColorToken.blue
        default:
            return .clear
        }
    }

    // MARK: - 1. General Section

    private var generalSection: some View {
        @Bindable var appSettings = appSettings
        return VStack(spacing: 18) {
            // Master Monitoring Switch
            SettingsCard {
                VStack(spacing: 14) {
                    HStack(alignment: .center) {
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(appSettings.monitoringEnabled ? Theme.ColorToken.greenWash : Theme.ColorToken.neutralWash)
                                    .frame(width: 34, height: 34)
                                Image(systemName: "waveform.path.ecg")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(appSettings.monitoringEnabled ? Theme.ColorToken.green : Theme.ColorToken.muted)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Continuous Network Monitoring")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Theme.ColorToken.ink)
                                Text("Periodically checks default gateway, latency, DNS lookups, and Wi-Fi link health in the background.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.ColorToken.muted)
                            }
                        }

                        Spacer()

                        Toggle("", isOn: Binding(
                            get: { appSettings.monitoringEnabled },
                            set: { newValue in
                                appSettings.monitoringEnabled = newValue
                                coordinator.setMonitoring(enabled: newValue)
                            }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }

                    if appSettings.monitoringEnabled {
                        HStack(spacing: 8) {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(monitoringStatusColor)
                                    .frame(width: 6, height: 6)
                                Text(monitoringStatusSummary)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Theme.ColorToken.ink)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Theme.ColorToken.nodeBackground)
                            .clipShape(Capsule())

                            Spacer()

                            Text("Applies to both Wi-Fi and wired Ethernet")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.ColorToken.quiet)
                        }
                    }
                }
            }

            // Cadence Frequencies
            SettingsCard(title: "Check Cadences & Intervals", icon: "timer", subtitle: "Customize how frequently Hopwatch queries different network tiers.") {
                VStack(spacing: 16) {
                    cadenceRow(
                        title: "Default Gateway / Router Ping",
                        description: "Sends lightweight pings to your router to immediately detect Wi-Fi drops, jitter, and packet loss.",
                        value: appSettings.fastInterval,
                        range: 2...60,
                        step: 1,
                        binding: intervalBinding(\.fastInterval),
                        presets: [
                            (label: "5s (Fast)", value: 5),
                            (label: "10s (Default)", value: 10),
                            (label: "30s (Relaxed)", value: 30)
                        ]
                    )

                    Divider()

                    cadenceRow(
                        title: "DNS & Wi-Fi Telemetry",
                        description: "Queries local DNS resolvers and inspects Wi-Fi RSSI signal strength, noise, and radio channel status.",
                        value: appSettings.mediumInterval,
                        range: 15...600,
                        step: 5,
                        binding: intervalBinding(\.mediumInterval),
                        presets: [
                            (label: "30s", value: 30),
                            (label: "60s (Default)", value: 60),
                            (label: "120s", value: 120)
                        ]
                    )

                    Divider()

                    cadenceRow(
                        title: "Public IP & WAN Verification",
                        description: "Checks your public IP and country from an external service to identify VPN switches and ISP routing changes.",
                        value: appSettings.slowInterval,
                        range: 60...1800,
                        step: 30,
                        binding: intervalBinding(\.slowInterval),
                        presets: [
                            (label: "180s", value: 180),
                            (label: "300s (Default)", value: 300),
                            (label: "600s", value: 600)
                        ]
                    )

                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.ColorToken.muted)
                        Text("Faster checks notice problems sooner. Public IP lookups stay slow on purpose to respect outside rate limits.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.ColorToken.muted)
                        Spacer()
                    }
                    .padding(.top, 4)
                }
            }

            // Battery & Power
            SettingsCard(title: "Battery & Energy Optimization", icon: "battery.100.bolt", subtitle: "Prevent unneeded wakeups when on battery or asleep.") {
                VStack(spacing: 12) {
                    SettingsToggleRow(
                        title: "Pause while display is asleep",
                        description: "Avoids reporting false connectivity drop alerts while your Mac is sleeping and saves power.",
                        isOn: $appSettings.pauseOnDisplaySleep
                    )

                    Divider()

                    SettingsToggleRow(
                        title: "Pause on low battery",
                        description: "Temporarily suspends background network monitoring when your battery drops below 20%.",
                        isOn: $appSettings.pauseOnBattery
                    )
                }
            }

            // Menu Bar & Appearance
            SettingsCard(title: "Menu Bar & System Presence", icon: "menubar.dock.rectangle", subtitle: "Control how Hopwatch looks on screen and at startup.") {
                VStack(spacing: 14) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Menu bar display")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.ColorToken.ink)
                            Text("Choose what information appears in your macOS menu bar.")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.ColorToken.muted)
                        }

                        Spacer()

                        Picker("", selection: $appSettings.menuBarStyle) {
                            ForEach(MenuBarStyle.allCases) { style in
                                Text(style.label).tag(style)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 210)
                    }

                    // Simulated live preview of menu bar item
                    menuBarPreviewCard

                    if hasNotchScreen {
                        HStack(spacing: 6) {
                            Image(systemName: "laptopcomputer")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.ColorToken.amber)
                            Text("On MacBook displays with a camera notch, macOS automatically hides menu bar items when space is limited. Choosing a shorter style keeps Hopwatch visible.")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.ColorToken.muted)
                        }
                        .padding(.top, 2)
                    }

                    Divider()

                    SettingsToggleRow(
                        title: "Show Hopwatch in Dock & App Switcher",
                        description: "Keeps Hopwatch accessible in your macOS Dock and ⌘⇥ App Switcher at all times.",
                        isOn: $appSettings.showInDock
                    )

                    Divider()

                    SettingsToggleRow(
                        title: "Launch Hopwatch at login",
                        description: "Starts monitoring in the background whenever you log in to your Mac.",
                        isOn: $appSettings.launchAtLogin
                    )
                }
            }

            // Wi-Fi Self-Healing
            SettingsCard(title: "Wi-Fi Self-Healing & Recovery", icon: "arrow.triangle.2.circlepath", subtitle: "Automatic link recovery when connections stall.") {
                SettingsToggleRow(
                    title: "Automatically reconnect Wi-Fi",
                    description: "Off by default. When on, Hopwatch turns Wi-Fi off and on without asking if your router stops answering and Wi-Fi does not come back, if your network never hands your Mac an address, or if the router stops responding despite a strong signal. It does not do this if you switched Wi-Fi off yourself.",
                    isOn: $appSettings.autoReconnectWiFi
                )
            }
        }
    }

    private var monitoringStatusColor: Color {
        if coordinator.monitor.isBursting { return Theme.ColorToken.blue }
        if coordinator.monitor.isPausedForAnyReason { return Theme.ColorToken.amber }
        if !coordinator.monitor.isRunning { return Theme.ColorToken.muted }
        return Theme.ColorToken.green
    }

    private var monitoringStatusSummary: String {
        if coordinator.monitor.isBursting { return "Testing latency · every \(appSettings.latencyTestInterval)s" }
        if let reason = coordinator.monitor.pauseReason { return "Paused (\(reason))" }
        if !coordinator.monitor.isRunning { return "Monitoring stopped" }
        return "Active · router checked every \(appSettings.fastInterval)s"
    }

    private var menuBarPreviewCard: some View {
        HStack(spacing: 12) {
            Text("Preview:")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.ColorToken.muted)

            HStack(spacing: 4) {
                Circle()
                    .fill(Theme.ColorToken.green)
                    .frame(width: 8, height: 8)

                switch appSettings.menuBarStyle {
                case .dotOnly:
                    EmptyView()
                case .dotAndFlag:
                    Text("🇺🇸")
                        .font(.system(size: 12))
                case .dotFlagAndIP:
                    Text("🇺🇸")
                        .font(.system(size: 12))
                    Text("198.51.100.1")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.ColorToken.ink)
                case .dotAndPing:
                    Text("12ms")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.ColorToken.ink)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Theme.ColorToken.nodeBackground)
            .clipShape(Capsule())
            .overlay(
                Capsule().strokeBorder(Theme.ColorToken.line, lineWidth: 1)
            )

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.ColorToken.nodeBackground.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func cadenceRow(
        title: String,
        description: String,
        value: Int,
        range: ClosedRange<Double>,
        step: Double,
        binding: Binding<Double>,
        presets: [(label: String, value: Int)]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.ColorToken.ink)
                    Text(description)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ColorToken.muted)
                }
                Spacer()

                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(value)")
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.ColorToken.ink)
                    Text("s")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.ColorToken.muted)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Theme.ColorToken.nodeBackground)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            HStack(spacing: 12) {
                Slider(value: binding, in: range, step: step) { editing in
                    if !editing { coordinator.applyCadenceSettings() }
                }

                HStack(spacing: 5) {
                    ForEach(presets, id: \.value) { preset in
                        Button(preset.label) {
                            binding.wrappedValue = Double(preset.value)
                            coordinator.applyCadenceSettings()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: value == preset.value ? .bold : .medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(value == preset.value ? Theme.ColorToken.blueWash : Theme.ColorToken.nodeBackground)
                        .foregroundStyle(value == preset.value ? Theme.ColorToken.blue : Theme.ColorToken.muted)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(value == preset.value ? Theme.ColorToken.blue.opacity(0.4) : Theme.ColorToken.line, lineWidth: 1)
                        )
                    }
                }
            }
        }
    }

    private func intervalBinding(_ keyPath: ReferenceWritableKeyPath<AppSettings, Int>) -> Binding<Double> {
        Binding(
            get: { Double(appSettings[keyPath: keyPath]) },
            set: { appSettings[keyPath: keyPath] = Int($0) }
        )
    }

    // MARK: - 2. Alerts & Automation Section

    private var alertsSection: some View {
        @Bindable var appSettings = appSettings
        return VStack(spacing: 18) {
            // Permissions Card
            SettingsCard(title: "macOS System Permissions", icon: "lock.shield", subtitle: "Permissions required for background alerts and radio diagnostics.") {
                VStack(spacing: 12) {
                    // Notifications Permission
                    permissionRow(
                        title: "macOS Desktop Notifications",
                        description: "Enables instant alert banners when connectivity drops or packets are lost.",
                        isAuthorized: coordinator.alerts.notificationsAuthorized,
                        isDenied: coordinator.alerts.notificationsDenied,
                        onFix: {
                            if coordinator.alerts.notificationsDenied {
                                coordinator.alerts.openSystemSettings()
                            } else {
                                Task { await coordinator.alerts.requestOrOpenSettings() }
                            }
                        }
                    )

                    Divider()

                    // Location / CoreWLAN Permission
                    permissionRow(
                        title: "Wi-Fi & Location Access",
                        description: "macOS CoreWLAN requires Location authorization to reveal your Wi-Fi SSID network name and channel telemetry.",
                        isAuthorized: coordinator.locationPermissions.isAuthorized,
                        isDenied: coordinator.locationPermissions.isDeniedOrRestricted,
                        onFix: {
                            if coordinator.locationPermissions.isDeniedOrRestricted {
                                coordinator.locationPermissions.openSystemSettings()
                            } else {
                                coordinator.locationPermissions.requestOrOpenSettings()
                            }
                        }
                    )
                }
            }

            // Notification Delivery Options
            SettingsCard(title: "Notification Delivery & Scope", icon: "bell", subtitle: "Filter notification frequency and sensitivity.") {
                VStack(spacing: 14) {
                    SettingsToggleRow(
                        title: "Deliver desktop notifications for connectivity drops",
                        description: "Sends native macOS alert notifications when your connection drops, Wi-Fi degrades, or the router stops responding.",
                        isOn: Binding(
                            get: { appSettings.notificationsEnabled },
                            set: { newValue in
                                appSettings.notificationsEnabled = newValue
                                coordinator.notifications.notificationsEnabled = newValue
                            }
                        )
                    )

                    if appSettings.notificationsEnabled {
                        Divider()

                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Alert sensitivity scope")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Theme.ColorToken.ink)
                                Text("Choose which severity of events should trigger notifications.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.ColorToken.muted)
                            }

                            Spacer()

                            Picker("", selection: Binding(
                                get: { appSettings.notificationScope },
                                set: { newValue in
                                    appSettings.notificationScope = newValue
                                    coordinator.notifications.scope = newValue
                                }
                            )) {
                                ForEach(NotificationScope.allCases) { scope in
                                    Text(scope.label).tag(scope)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 220)
                        }

                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.ColorToken.green)
                            Text("Ongoing faults are announced once. An immediate notification confirms when the network recovers.")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.ColorToken.muted)
                        }
                        .padding(.top, 2)
                    }
                }
            }

            // Automation
            SettingsCard(title: "Automated Diagnostic Checks", icon: "bolt.badge.automatic", subtitle: "Self-running network diagnostics on incidents.") {
                VStack(spacing: 12) {
                    SettingsToggleRow(
                        title: "Run diagnostic check automatically when an alert fires",
                        description: "Captures a full hop-by-hop diagnosis trace the moment a drop or loss begins. Skips the speed test so it won't congest an already struggling network.",
                        isOn: $appSettings.scanOnAlert
                    )

                    Divider()

                    SettingsToggleRow(
                        title: "Run benchmark check the first time I join a network",
                        description: "Runs one full benchmark check including a speed test when you connect to an unfamiliar network. Runs once per network, ever.",
                        isOn: $appSettings.scanOnNewNetwork
                    )
                }
            }

            // Alert Definitions Catalog
            alertCatalogCard
        }
    }

    private func permissionRow(
        title: String,
        description: String,
        isAuthorized: Bool,
        isDenied: Bool,
        onFix: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.ColorToken.ink)

                    if isAuthorized {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10))
                            Text("Allowed")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Theme.ColorToken.greenWash)
                        .foregroundStyle(Theme.ColorToken.green)
                        .clipShape(Capsule())
                    } else if isDenied {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                            Text("Restricted")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Theme.ColorToken.redWash)
                        .foregroundStyle(Theme.ColorToken.red)
                        .clipShape(Capsule())
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "questionmark.circle")
                                .font(.system(size: 10))
                            Text("Not Set")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Theme.ColorToken.amberWash)
                        .foregroundStyle(Theme.ColorToken.amber)
                        .clipShape(Capsule())
                    }
                }

                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ColorToken.muted)
            }

            Spacer()

            if !isAuthorized {
                Button(isDenied ? "Open Settings" : "Turn On") {
                    onFix()
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            }
        }
    }

    enum AlertCategory: String, CaseIterable, Identifiable {
        case all = "All Alerts"
        case connectivity = "Connectivity"
        case performance = "Performance"
        case routing = "Routing & DNS"
        case system = "System"

        var id: String { rawValue }
    }

    private var alertCatalogCard: some View {
        SettingsCard(title: "Alert Rules Catalog", icon: "checklist", subtitle: "Select which individual fault types generate notifications. Cooldowns prevent repetitive alerts.") {
            VStack(spacing: 14) {
                // Filter bar
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.ColorToken.muted)
                        TextField("Filter alert types…", text: $alertSearchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Theme.ColorToken.nodeBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.ColorToken.line, lineWidth: 1))

                    Spacer()

                    Picker("", selection: $selectedAlertCategory) {
                        ForEach(AlertCategory.allCases) { cat in
                            Text(cat.rawValue).tag(cat)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 140)
                }

                // List of filtered alerts
                let filtered = filteredAlerts
                VStack(spacing: 10) {
                    ForEach(filtered) { def in
                        alertDefinitionRow(def)
                        if def.id != filtered.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var filteredAlerts: [AlertDefinition] {
        AlertDefinition.all.filter { def in
            let matchesCategory: Bool = switch selectedAlertCategory {
            case .all: true
            case .connectivity:
                def.id.contains("loss") || def.id.contains("lost") || def.id.contains("vpn")
            case .performance:
                def.id.contains("latency") || def.id.contains("wifi") || def.id.contains("slower")
            case .routing:
                def.id.contains("dns") || def.id.contains("portal") || def.id.contains("ip") || def.id.contains("network") || def.id.contains("nat")
            case .system:
                def.id.contains("browser") || def.id.contains("clock") || def.id.contains("lease") || def.id.contains("conflict")
            }

            guard matchesCategory else { return false }
            if alertSearchText.trimmingCharacters(in: .whitespaces).isEmpty { return true }
            let query = alertSearchText.lowercased()
            return def.title.lowercased().contains(query) || def.caption.lowercased().contains(query)
        }
    }

    private func alertDefinitionRow(_ def: AlertDefinition) -> some View {
        let isEnabled = !appSettings.disabledAlerts.contains(def.id)

        return HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(isEnabled ? Theme.ColorToken.blueWash : Theme.ColorToken.neutralWash)
                    .frame(width: 28, height: 28)
                Image(systemName: alertIcon(for: def))
                    .font(.system(size: 12))
                    .foregroundStyle(isEnabled ? Theme.ColorToken.blue : Theme.ColorToken.muted)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(def.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.ColorToken.ink)

                    if !def.rules.isEmpty {
                        Text(def.rules.sorted().joined(separator: ", "))
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(Theme.ColorToken.quiet)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Theme.ColorToken.neutralWash)
                            .clipShape(Capsule())
                    }
                }

                Text(def.caption)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ColorToken.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { !appSettings.disabledAlerts.contains(def.id) },
                set: { on in
                    var set = appSettings.disabledAlerts
                    if on { set.remove(def.id) } else { set.insert(def.id) }
                    appSettings.disabledAlerts = set
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        }
        .padding(.vertical, 3)
    }

    private func alertIcon(for def: AlertDefinition) -> String {
        if def.id.contains("loss") || def.id.contains("lost") { return "antenna.radiowaves.left.and.right.slash" }
        if def.id.contains("latency") { return "stopwatch" }
        if def.id.contains("wifi") { return "wifi.exclamationmark" }
        if def.id.contains("dns") { return "globe.badge.chevron.backward" }
        if def.id.contains("vpn") { return "shield.slash" }
        if def.id.contains("portal") { return "lock.open" }
        if def.id.contains("ip") { return "network" }
        if def.id.contains("browser") { return "arrow.triangle.2.circlepath.circle" }
        if def.id.contains("clock") { return "clock.badge.exclamationmark" }
        return "bell"
    }

    // MARK: - 3. Diagnostics & CLI Section

    private var diagnosticsSection: some View {
        VStack(spacing: 18) {
            // CLI Executable Location
            SettingsCard(title: "hopwatch CLI Tool", icon: "terminal", subtitle: "The core diagnostic engine executing measurements and tests.") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        let isResolved = BinaryLocator.resolve() != nil
                        HStack(spacing: 5) {
                            Circle()
                                .fill(isResolved ? Theme.ColorToken.green : Theme.ColorToken.red)
                                .frame(width: 6, height: 6)
                            Text(isResolved ? "Connected" : "Missing")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(isResolved ? Theme.ColorToken.green : Theme.ColorToken.red)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(isResolved ? Theme.ColorToken.greenWash : Theme.ColorToken.redWash)
                        .clipShape(Capsule())

                        Spacer()

                        if !appSettings.binaryPath.isEmpty {
                            Button("Reset to Bundled CLI") {
                                appSettings.binaryPath = ""
                            }
                            .controlSize(.small)
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.ColorToken.blue)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Resolved CLI Path:")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.ColorToken.muted)

                        HStack(spacing: 8) {
                            Text(BinaryLocator.resolve() ?? BinaryLocator.missingBinaryMessage)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.ColorToken.ink)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.ColorToken.nodeBackground)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.ColorToken.line, lineWidth: 1))
                                .textSelection(.enabled)

                            if let resolved = BinaryLocator.resolve() {
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(resolved, forType: .string)
                                    copiedPathToast = "Copied!"
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedPathToast = nil }
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: copiedPathToast != nil ? "checkmark" : "doc.on.doc")
                                        Text(copiedPathToast ?? "Copy")
                                    }
                                    .font(.system(size: 11))
                                }
                                .controlSize(.small)
                            }

                            Button("Choose…") {
                                chooseBinary()
                            }
                            .controlSize(.small)
                        }
                    }

                    Text("Hopwatch.app doesn't diagnose anything itself — every measurement, threshold, and explanation comes directly from the hopwatch CLI tool.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ColorToken.muted)
                }
            }

            // Reports & History Storage
            SettingsCard(title: "Data & Reports Directory", icon: "folder", subtitle: "Location where network check history, fingerprints, and reports are saved.") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(reportsDirectoryDisplay)
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Theme.ColorToken.ink)
                            Text("Stores run snapshots, network IDs, and offline metrics.")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.ColorToken.muted)
                        }

                        Spacer()

                        HStack(spacing: 8) {
                            Button("Copy Path") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(reportsDirectoryURL.path, forType: .string)
                            }
                            .controlSize(.small)

                            Button("Open in Finder") {
                                NSWorkspace.shared.open(reportsDirectoryURL)
                            }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }

            // Welcome Assistant
            SettingsCard(title: "Setup & Onboarding", icon: "sparkles", subtitle: "Re-run the initial three-step onboarding walkthrough.") {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Welcome Setup Assistant")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.ColorToken.ink)
                        Text("Reopens the setup guide for notifications, location permissions, and launch at login.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.ColorToken.muted)
                    }

                    Spacer()

                    Button("Show Welcome Tour") {
                        openWindow(id: WindowID.onboarding)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private func chooseBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            appSettings.binaryPath = url.path
        }
    }

    private var reportsDirectoryURL: URL {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let hopwatch = home.appendingPathComponent("hopwatch")
        let netdiag = home.appendingPathComponent("net-diag")
        if FileManager.default.fileExists(atPath: hopwatch.path) {
            return hopwatch
        } else if FileManager.default.fileExists(atPath: netdiag.path) {
            return netdiag
        }
        return hopwatch
    }

    private var reportsDirectoryDisplay: String {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let hopwatch = home.appendingPathComponent("hopwatch")
        let netdiag = home.appendingPathComponent("net-diag")
        if FileManager.default.fileExists(atPath: hopwatch.path) {
            return "~/hopwatch"
        } else if FileManager.default.fileExists(atPath: netdiag.path) {
            return "~/net-diag"
        }
        return "~/hopwatch"
    }

    // MARK: - 4. Updates & System Section

    private var aboutSection: some View {
        @Bindable var appSettings = appSettings
        return VStack(spacing: 18) {
            // Software Updates
            SettingsCard(title: "Hopwatch Software Updates", icon: "arrow.triangle.2.circlepath.circle", subtitle: "Check for new releases and manage update automation.") {
                VStack(spacing: 14) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text("Hopwatch v\(AppVersion.display)")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(Theme.ColorToken.ink)

                                if coordinator.updateChecker.hasUpdate {
                                    Text("Update Available")
                                        .font(.system(size: 10, weight: .bold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Theme.ColorToken.amberWash)
                                        .foregroundStyle(Theme.ColorToken.amber)
                                        .clipShape(Capsule())
                                } else {
                                    Text("Up to date")
                                        .font(.system(size: 10, weight: .semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Theme.ColorToken.greenWash)
                                        .foregroundStyle(Theme.ColorToken.green)
                                        .clipShape(Capsule())
                                }
                            }

                            Text(coordinator.updateChecker.statusMessage)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.ColorToken.muted)

                            if let last = coordinator.updateChecker.lastCheckedDate {
                                Text("Last checked: \(RelativeTime.string(from: last))")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.ColorToken.quiet)
                            }
                        }

                        Spacer()

                        if coordinator.updateChecker.isChecking {
                            ProgressView().controlSize(.small)
                        } else if coordinator.updateChecker.isDownloading {
                            ProgressView(value: coordinator.updateChecker.downloadProgress)
                                .progressViewStyle(.linear)
                                .frame(width: 90)
                        } else if coordinator.updateChecker.hasUpdate {
                            Button("Install Update") {
                                coordinator.updateChecker.downloadAndInstallUpdate()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        } else {
                            Button("Check Now") {
                                coordinator.updateChecker.checkForUpdates(manual: true)
                            }
                            .controlSize(.small)
                        }
                    }

                    if let err = coordinator.updateChecker.errorMessage {
                        Text(err)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.ColorToken.red)
                    }

                    Divider()

                    SettingsToggleRow(
                        title: "Automatically check for updates daily",
                        description: "Notifies you quietly when a new version of Hopwatch is ready to install.",
                        isOn: $appSettings.autoCheckUpdates
                    )
                }
            }

            // CLI Capabilities & Toolchain
            SettingsCard(title: "CLI Toolchain & Capabilities", icon: "cpu", subtitle: "Dependencies detected during the capabilities handshake.") {
                VStack(spacing: 14) {
                    capabilitiesContent

                    Divider()

                    HStack {
                        Text("Re-probing the CLI environment reloads rule catalogs and restarts active monitors if updated.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.ColorToken.muted)

                        Spacer()

                        if isRechecking {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Re-check Environment") {
                                recheckCapabilities()
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }

            // Privacy & Telemetry
            SettingsCard(title: "Privacy & Crash Telemetry", icon: "hand.raised", subtitle: "Hopwatch is built with an absolute privacy commitment.") {
                VStack(alignment: .leading, spacing: 14) {
                    SettingsToggleRow(
                        title: "Share anonymous crash reports",
                        description: "Sends anonymized crash stack traces to help resolve unexpected terminations. Personal usernames, file paths, and IPs are redacted.",
                        isOn: $appSettings.crashReportingEnabled
                    )

                    VStack(alignment: .leading, spacing: 6) {
                        privacyBullet(icon: "checkmark.shield", text: "Zero tracking of visited URLs, DNS hostnames, or packet payloads.")
                        privacyBullet(icon: "checkmark.shield", text: "Wi-Fi network names and location data remain strictly local on your device.")
                        privacyBullet(icon: "checkmark.shield", text: "Diagnostic export reports mask IP addresses and sensitive identifiers.")
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    private func privacyBullet(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(Theme.ColorToken.green)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Theme.ColorToken.muted)
        }
    }

    @ViewBuilder
    private var capabilitiesContent: some View {
        switch capabilities {
        case nil:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Probing hopwatch toolchain capabilities…")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ColorToken.muted)
            }
        case .unavailable:
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(Theme.ColorToken.red)
                Text("Could not communicate with the hopwatch command to verify capabilities.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ColorToken.red)
            }
        case .legacy:
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(Theme.ColorToken.amber)
                Text("This hopwatch CLI predates the modern version handshake. Run an update for full capabilities.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ColorToken.muted)
            }
        case .modern(let caps):
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                capabilityItem(title: "CLI Version", value: caps.version.map { "v\($0)" } ?? "unknown", isAvailable: true)
                capabilityItem(title: "Speed Test", value: speedtestLabel(caps.deps.speedtest), isAvailable: caps.deps.speedtest != nil)
                capabilityItem(title: "bash", value: caps.deps.bash ?? "unknown", isAvailable: caps.deps.bash != nil)
                capabilityItem(title: "python3", value: caps.deps.python3 ?? "not installed", isAvailable: caps.deps.python3 != nil)
                capabilityItem(title: "jq", value: boolLabel(caps.deps.jq), isAvailable: caps.deps.jq == true)
                capabilityItem(title: "mtr", value: boolLabel(caps.deps.mtr), isAvailable: caps.deps.mtr == true)
                capabilityItem(title: "gping", value: boolLabel(caps.deps.gping), isAvailable: caps.deps.gping == true)
                if let schemas = caps.schemas, !schemas.isEmpty {
                    capabilityItem(title: "Schemas", value: schemas.keys.sorted().joined(separator: ", "), isAvailable: true)
                }
            }
        }
    }

    private func capabilityItem(title: String, value: String, isAvailable: Bool) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.ColorToken.muted)

            Spacer()

            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(isAvailable ? Theme.ColorToken.ink : Theme.ColorToken.quiet)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(isAvailable ? Theme.ColorToken.nodeBackground : Theme.ColorToken.neutralWash)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.ColorToken.nodeBackground.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.ColorToken.line, lineWidth: 1))
    }

    private func speedtestLabel(_ value: String?) -> String {
        switch value {
        case "ookla": return "Ookla speedtest"
        case "cli":   return "speedtest-cli"
        default:      return "Not installed"
        }
    }

    private func boolLabel(_ value: Bool?) -> String {
        switch value {
        case true?:  return "Installed"
        case false?: return "Not installed"
        case nil:    return "Unknown"
        }
    }

    private func recheckCapabilities() {
        Task {
            isRechecking = true
            capabilities = await CapabilityStore.shared.recheck()
            if case .modern = capabilities,
               appSettings.monitoringEnabled,
               !coordinator.monitor.isRunning {
                coordinator.monitor.restartNow()
            }
            await coordinator.refreshShareSupport()
            await coordinator.rulesCatalog.refresh()
            isRechecking = false
        }
    }

    private var hasNotchScreen: Bool {
        NSScreen.screens.contains { $0.auxiliaryTopRightArea != nil }
    }
}

// MARK: - Reusable Settings Components

struct SettingsCard<Content: View>: View {
    var title: String? = nil
    var icon: String? = nil
    var subtitle: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        if let icon {
                            Image(systemName: icon)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.ColorToken.blue)
                        }
                        Text(title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.ColorToken.ink)
                    }

                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.ColorToken.muted)
                    }
                }
                .padding(.bottom, 2)
            }

            content()
        }
        .padding(16)
        .background(Theme.ColorToken.nodeBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Theme.ColorToken.line, lineWidth: 1)
        )
    }
}

struct SettingsToggleRow: View {
    let title: String
    let description: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ColorToken.ink)
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ColorToken.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }
}
