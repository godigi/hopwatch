import Foundation
import AppKit
import CoreWLAN
import SystemConfiguration
import os

/// The one object that owns the others and decides when they act.
///
/// Everything stateful in this app is reachable from here, which keeps the
/// interesting question — *what causes what* — answerable by reading one
/// type rather than by tracing five observers. Feature-specific methods are
/// organized across `HopwatchCoordinator+*.swift` extensions:
/// - `+Hydration.swift` — cold-launch hydration, live SSID adoption, report scoping
/// - `+Arrival.swift` — new-network arrival policy & state machine
/// - `+Scans.swift` — scan execution, cancellation, network events, resolutions
/// - `+Repairs.swift` — repairs, auto-reconnect, captive portal & custom DNS
/// - `+Telemetry.swift` — freshness, suitability, stage/health/headline, sharing
/// - `+GalleryFixtures.swift` — visual-audit and `--verify` state fixtures
@MainActor
@Observable
final class HopwatchCoordinator {

    let monitor = MonitorStream()
    let events = NetworkEventWatcher()
    let history = HistoryStore()
    let details = RunDetailStore()
    let notifications = NotificationManager()
    let alerts = AlertEngine()
    let watcher = WatcherControl()
    let rulesCatalog = RulesCatalogStore()
    private(set) var supportsShare = true

    func refreshShareSupport() async {
        supportsShare = await CapabilityStore.shared.supports(.share)
    }

    let signalScale = SignalScaleStore()
    let appSettings = AppSettings()
    let updateChecker = UpdateChecker()
    let heartbeat = PingHeartbeat()
    var onOpenSoftwareUpdate: (() -> Void)?
    let locationPermissions = LocationPermissionStore()
    let progress = ScanProgress()
    let eventLog: EventStore

    /// How a repair is actually run. The default shells out to
    /// `hopwatch --repair=…`; tests inject a recorder, because the real one
    /// power-cycles this Mac's Wi-Fi.
    typealias RepairRunner = @Sendable (_ id: String, _ params: [String: String]) async throws -> NetdiagRunner.RepairResult
    let repairRunner: RepairRunner

    init(repairRunner: @escaping RepairRunner = { id, params in
             try await NetdiagRunner.repair(id: id, params: params)
         },
         eventLog: EventStore? = nil) {
        self.repairRunner = repairRunner
        self.eventLog = eventLog ?? EventStore()
        locationPermissions.onAuthorizationChange = { [weak self] _ in
            self?.refreshLocationState()
        }
    }

    private var updateCheckTask: Task<Void, Never>?
    var lastAssociatedSSID: String?
    var lastKnownPublicInfo: MonitorSample.PublicInfo?
    var latestRun: RunResult?
    var hydratedReport: RunDetail? {
        didSet {
            cachedHydratedRunResult = hydratedReport?.asRunResult
        }
    }
    var cachedHydratedRunResult: RunResult?
    var liveSSID: String?
    var isTestingLiveSSID = false
    var isScanning = false
    var activeScanDepth: NetdiagRunner.Depth?
    var scanStartedAt: Date?
    var lastRunError: String?

    var isSpeedTestOnly: Bool {
        isScanning && activeScanDepth == .speedOnly
    }

    var isSpeedTesting: Bool {
        isSpeedTestOnly || progress.isSpeedTesting
    }

    var latestSpeedTest: RunSnapshot.Speedtest?
    var latestSpeedTestAt: Date?
    var latestSpeedTestNetwork: String?
    var requestedDestination: MainDestination?
    var scanWasAlertTriggered = false
    var preScanSample: MonitorSample?
    var lastAlertTriggeredScanAt: Date?
    var healthyRecoverySince: Date?
    private static let alertTriggeredScanCooldown: TimeInterval = 600

    /// True while a quiet, alert-triggered diagnostic scan is running in the background.
    var isBackgroundInvestigating: Bool {
        isScanning && activeScanDepth == .alertTriggered && scanWasAlertTriggered
    }

    func isAlertTriggeredScanInCooldown(at now: Date? = nil) -> Bool {
        guard let lastScan = lastAlertTriggeredScanAt else { return false }
        let clockNow = now ?? alerts.now()
        return clockNow.timeIntervalSince(lastScan) < Self.alertTriggeredScanCooldown
    }

    var canStartAlertTriggeredScanForTesting: Bool {
        Defaults.scanOnAlert && !scanWasAlertTriggered && !isScanning && !isAlertTriggeredScanInCooldown()
    }

    var scanTask: Task<Void, Never>?
    var lastNetworkID: String?
    var didHydrateForNetwork = false
    var arrivalState: ArrivalState = .unchecked
    var arrivalNetworkID: String?
    var arrivalIntent: ArrivalCopy.Intent = .starting
    var routerAdminAvailable = false
    var lastProbedRouterIP: String?
    var arrivalAttempts = 0
    var nextArrivalAttemptAt: Date?
    var pendingArrivalNetworkID: String?
    var pendingArrivalDepth: ArrivalDepth?
    var pendingArrivalDecline: DeclineReason?
    /// Arrival state for networks known only by a private/link-local
    /// gateway IP (`gw:192.168.1.1`). Never persisted — see
    /// `setArrivalState` — and emptied at every connection boundary
    /// (`invalidateCurrentConnection`), so the verdict for "the network
    /// behind 192.168.1.1" cannot leak onto a different one that shares the
    /// address.
    var sessionArrivalStates: [String: ArrivalState] = [:]
    var heartbeatSeedMinSeq: Int = 0
    var lastSeverity: String = "ok"

    // MARK: - Remediation Resolution Feedback (TASK-027)

    struct ResolutionEvent: Sendable, Equatable, Identifiable {
        let id: UUID
        let title: String
        let message: String
        let timestamp: Date
        let icon: String
        var dismissed: Bool

        init(id: UUID = UUID(), title: String, message: String, timestamp: Date = Date(), icon: String = "checkmark.circle.fill", dismissed: Bool = false) {
            self.id = id
            self.title = title
            self.message = message
            self.timestamp = timestamp
            self.icon = icon
            self.dismissed = dismissed
        }

        var snapshot: StageResolver.ResolutionSnapshot {
            StageResolver.ResolutionSnapshot(title: title, message: message, timestamp: timestamp, icon: icon)
        }

        var isCurrent: Bool {
            !dismissed && Date().timeIntervalSince(timestamp) < 45.0
        }
    }

    var recentResolutions: [ResolutionEvent] = []
    var lastSample: MonitorSample?
    private(set) var connectionGeneration = 0
    var connectionChangedAt: Date?
    var scanIdentity: (id: String, startedAt: Date, finishedAt: Date)?
    var lastUnhealthySample: MonitorSample?
    var previousActiveAlerts: [String: AlertEngine.ActiveAlert] = [:]

    var activeResolution: ResolutionEvent? {
        recentResolutions.last(where: { $0.isCurrent })
    }

    func dismissActiveResolution() {
        for idx in recentResolutions.indices where recentResolutions[idx].isCurrent {
            recentResolutions[idx].dismissed = true
        }
    }

    var isSettling: Bool {
        if let connectionChangedAt, Date().timeIntervalSince(connectionChangedAt) < 15 {
            return true
        }
        return events.withinGracePeriod(15)
    }

    func recordResolution(title: String, message: String, icon: String = "checkmark.circle.fill") {
        let event = ResolutionEvent(title: title, message: message, timestamp: Date(), icon: icon)
        recentResolutions.append(event)
        if recentResolutions.count > 10 {
            recentResolutions.removeFirst(recentResolutions.count - 10)
        }
        log.info("resolution recorded: \(title, privacy: .public) — \(message, privacy: .public)")
    }

    var repairOutcome: RepairOutcome?
    var repairTask: Task<Void, Never>?
    var staleEpoch = 0
    var staleWatchTask: Task<Void, Never>?
    var stalenessSuspended = false

    let log = Logger(subsystem: "com.godigi.hopwatch", category: "coordinator")

    func advanceConnectionGeneration() {
        connectionGeneration += 1
    }

    // MARK: - Lifecycle

    func start() {
        Defaults.migrateArrivalStatesIfNeeded()
        alerts.notificationManager = notifications
        notifications.notificationsEnabled = appSettings.notificationsEnabled
        notifications.scope = appSettings.notificationScope
        alerts.inNetworkGracePeriod = { [weak events] in
            events?.withinGracePeriod() ?? false
        }
        alerts.liveSSID = { [weak self] in
            self?.wifiDisplayName ?? self?.liveSSID
        }
        alerts.hasCustomDNS = { [weak self] in self?.hasCustomDNS ?? false }
        alerts.onAlertFired = { [weak self] def, firingRules in
            self?.handleAlertFired(def, firingRules: firingRules) ?? false
        }
        monitor.onSample = { [weak self] sample in
            self?.handleSample(sample)
        }
        events.onEvent = { [weak self] event in
            self?.handleNetworkEvent(event)
        }

        events.start()
        observeWorkspace()
        NotificationCenter.default.addObserver(
            forName: .netdiagWillTerminate, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stop()
                self?.eventLog.flush()
            }
        }

        Task {
            await alerts.refreshAuthorization()
            await watcher.refresh()
            if watcher.isInstalled {
                log.info("Uninstalling legacy 15-minute background watcher")
                await watcher.uninstall()
            }
            await refreshShareSupport()
            await history.load()
            await hydrateFromHistoryIfNeeded()
        }
        rulesCatalog.ensureLoaded()
        signalScale.ensureLoaded()
        Task { [weak self] in
            await self?.rulesCatalog.refresh()
            guard let self else { return }
            self.eventLog.rephraseLegacyRuleEvents { [weak self] ruleID in
                self?.rulesCatalog.catalog?[ruleID]?.title
            }
        }
        alerts.severityRank = { [weak self] ruleID in
            self?.severityRank(forRuleID: ruleID) ?? 0
        }
        alerts.ruleText = { [weak self] ruleID in
            guard let blurb = self?.rulesCatalog.catalog?[ruleID]?.blurb, !blurb.isEmpty else { return nil }
            return blurb
        }
        if Defaults.monitoringEnabled {
            monitor.start()
            heartbeat.start()
        }
        syncAlertPauseState()
        startStaleWatch()

        updateChecker.onUpdateFound = { [weak self] release in
            guard let self else { return }
            self.notifications.deliverUpdateNotification(
                version: release.cleanVersion,
                shortNotes: release.shortReleaseNotes
            )
        }

        startPeriodicUpdateChecks()
    }

    func stop() {
        updateCheckTask?.cancel()
        staleWatchTask?.cancel()
        scanTask?.cancel()
        monitor.stop()
        events.stop()
        heartbeat.stop()
    }

    private func startPeriodicUpdateChecks() {
        updateCheckTask?.cancel()
        updateCheckTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.updateChecker.performDailyCheck()

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 14_400_000_000_000)
                guard !Task.isCancelled else { break }
                self?.updateChecker.performDailyCheck()
            }
        }
    }

    // MARK: - Window activation policy

    private var openWindowCount = 0

    func windowAppeared() {
        openWindowCount += 1
        applyActivationPolicy()
    }

    func windowDisappeared() {
        if openWindowCount > 0 { openWindowCount -= 1 }
        applyActivationPolicy()
    }

    func applyActivationPolicy() {
        let hasWindows = openWindowCount > 0
        let regular = hasWindows || Defaults.showInDock
        NSApp?.setActivationPolicy(regular ? .regular : .accessory)
        if hasWindows { NSApp?.activate(ignoringOtherApps: true) }
    }

    // MARK: - Monitoring toggle

    func setMonitoring(enabled: Bool) {
        Defaults.monitoringEnabled = enabled
        if enabled {
            monitor.start()
            heartbeat.start()
        } else {
            monitor.stop()
            heartbeat.stop()
        }
        syncAlertPauseState()
    }

    static let scanPauseReason = "a check is running"

    func syncAlertPauseState() {
        alerts.monitoringPaused = !Defaults.monitoringEnabled
            || monitor.isPaused(besides: Self.scanPauseReason)
    }

    func applyCadenceSettings() {
        guard Defaults.monitoringEnabled, monitor.isRunning else { return }
        monitor.restart()
    }

    // MARK: - Samples

    func resolvedNetworkID(for sample: MonitorSample?) -> String? {
        guard let sample, let id = sample.network.historyJoinID else { return nil }
        if (sample.link.isWiFi || liveSSID != nil), NetworkIdentity.isPrivateOrLocalGateway(id) {
            if let ssid = liveSSID ?? Self.readableSSID(sample.link.ssid) {
                return "ssid:\(ssid)"
            }
        }
        return id
    }

    @discardableResult
    func reconcileNetworkIdentity(for sample: MonitorSample) -> Bool {
        guard !sample.status.paused, let id = resolvedNetworkID(for: sample) else { return false }
        guard id != lastNetworkID else { return false }
        if let previous = lastNetworkID {
            if history.canonicalID(previous) == history.canonicalID(id) {
                lastNetworkID = id
                return false
            }
            if previous.hasPrefix("gw:"), id.hasPrefix("ssid:"),
               sample.network.historyJoinID == previous {
                lastNetworkID = id
                if arrivalNetworkID == previous {
                    arrivalNetworkID = id
                }
                return false
            }
            invalidateCurrentConnection(preserving: sample)
        }
        lastNetworkID = id
        return true
    }

    func handleSample(_ sample: MonitorSample) {
        guard !sample.status.paused else { return }
        if sample.link.up {
            preScanSample = sample
        } else {
            preScanSample = nil
        }
        refreshLiveWiFi()
        let previousNetworkID = lastNetworkID
        let identityChanged = reconcileNetworkIdentity(for: sample)
        if identityChanged {
            lastAssociatedSSID = nil
            lastKnownPublicInfo = nil
        }
        if sample.publicInfo.captivePortal == true {
            lastKnownPublicInfo = nil
        } else if sample.publicInfo.ok == true && !(sample.publicInfo.countryISO ?? "").isEmpty {
            lastKnownPublicInfo = sample.publicInfo
        }
        adoptLiveSSIDAsNameIfNeeded(for: sample)
        if let ssid = Self.readableSSID(sample.link.ssid) ?? liveSSID {
            lastAssociatedSSID = ssid
        }
        let isPortalConfirmed = sample.publicInfo.captivePortal == true ||
            sample.status.rules.contains("CP-1") ||
            isSystemCaptiveActive()
        // Evidence the internet is reachable: a reply was measured, or the
        // public lookup / a TCP probe got through. A reply is enough; this
        // is no verdict on loss, so no loss cutoff of this app's own (it
        // used to be "< 50 %") belongs here.
        let internetHealthy = sample.internet.rttAvgMs != nil
            || sample.publicInfo.ip != nil
            || sample.tcp.anyOk == true
        if isPortalConfirmed {
            learnCurrentNetworkRequiresPortal()
        } else if sample.publicInfo.captivePortal == false && internetHealthy {
            unlearnCurrentNetworkPortal()
        }
        alerts.evaluate(sample: sample)
        if sample.health == .healthy && alerts.active.isEmpty && !isScanning && currentDegradedExperience == nil {
            let now = alerts.now()
            if let healthyRecoverySince {
                if now.timeIntervalSince(healthyRecoverySince) >= 120 {
                    lastAlertTriggeredScanAt = nil
                }
            } else {
                healthyRecoverySince = now
            }
        } else {
            healthyRecoverySince = nil
        }
        if alerts.active.isEmpty && !notifications.announcedFaults.isEmpty && sample.health == .healthy {
            notifications.deliverRestored(
                networkName: liveSSID ?? sample.network.label ?? "Network",
                latencyMs: sample.gateway.rttAvgMs ?? sample.internet.rttAvgMs,
                activeIDs: Set(alerts.active.keys)
            )
            if appSettings.audioChimesEnabled {
                NSSound(named: "Glass")?.play()
            }
        }
        evaluateResolutions(sample: sample)
        considerInvestigationBurst(sample)
        considerAutoReconnect(sample)

        let isTargetFiltered: Bool = {
            if let gw = sample.link.gateway, !gw.isEmpty, heartbeat.target == gw {
                return lossFiltering.filters(.gateway)
            }
            return lossFiltering.filters(.internet)
        }()
        heartbeat.setFiltered(isTargetFiltered)

        if heartbeat.beats.isEmpty {
            let eligible = currentSamples.filter { ($0.seq ?? 0) >= heartbeatSeedMinSeq }
            heartbeat.seedFromSamples(eligible)
        }

        if sample.seq == 1 {
            eventLog.record(
                kind: "monitor-started",
                summary: "Monitoring started",
                network: sample.network.id,
                date: sample.timestamp,
                continuesPrevious: NetworkEvent.continuesPrevious(
                    appRestarted: monitor.childContinuesPrevious,
                    previousNetwork: previousNetworkID,
                    currentNetwork: resolvedNetworkID(for: sample) ?? sample.network.historyJoinID))
        }

        for change in sample.changes {
            var extra: String? = nil
            if change.kind == "public-ip-changed" {
                if let isp = sample.publicInfo.isp, !isp.isEmpty {
                    extra = isp
                }
            } else if change.kind == "isp-changed" {
                if let ip = sample.publicInfo.ip, !ip.isEmpty {
                    extra = "IP: \(ip)"
                }
            }
            eventLog.record(
                kind: change.kind,
                summary: change.summary,
                ruleID: change.field == "status.rules"
                    ? (change.to ?? change.from) : nil,
                network: sample.network.id,
                date: sample.timestamp,
                continuesPrevious: false,
                evidence: change.evidence,
                fromValue: change.from,
                toValue: change.to,
                extraDetail: extra)
        }

        if let gwIP = sample.link.gateway, gwIP != lastProbedRouterIP {
            lastProbedRouterIP = gwIP
            routerAdminAvailable = false
            let generation = connectionGeneration
            Task { [weak self] in
                let available = await RouterAdminProbeStore.shared.checkAvailability(
                    for: gwIP, generation: generation)
                await MainActor.run {
                    guard self?.connectionGeneration == generation,
                          self?.liveSample?.link.gateway == gwIP else { return }
                    self?.routerAdminAvailable = available
                }
            }
        }

        guard let id = resolvedNetworkID(for: sample) else { return }

        if !didHydrateForNetwork, latestRun == nil, hydratedReport == nil {
            Task { await hydrateFromHistoryIfNeeded() }
        }

        if identityChanged {
            if latestSpeedTestNetwork.map({ history.canonicalID($0) }) != history.canonicalID(id) || latestSpeedTest == nil {
                adoptStoredSpeedTest(for: id)
            }
            if currentNetworkRun == nil { Task { await hydrateFromHistoryIfNeeded() } }
            alerts.networkChanged(to: id)
            log.info("now on network \(id, privacy: .public)")
            arrivalAttempts = 0
            nextArrivalAttemptAt = nil
        } else if latestSpeedTest == nil {
            adoptStoredSpeedTest(for: id)
        }

        considerArrival(for: id, sample: sample)
    }

    // MARK: - Latency test & Alerts

    func stopLatencyTest() { monitor.endBurst() }

    func consumeRequestedDestination() -> MainDestination? {
        defer { requestedDestination = nil }
        return requestedDestination
    }

    @discardableResult
    private func handleAlertFired(_ def: AlertDefinition, firingRules: Set<String>) -> Bool {
        var alertExtra: String? = nil
        var alertTo: String? = nil
        if def.id == "public-ip-changed" {
            alertExtra = monitor.latest?.publicInfo.isp
            alertTo = monitor.latest?.publicInfo.ip
        }
        eventLog.record(kind: "alert", summary: def.title,
                        ruleID: firingRules.min() ?? (def.isEvent ? def.id : nil),
                        network: monitor.latest?.network.id,
                        toValue: alertTo,
                        extraDetail: alertExtra)
        if appSettings.audioChimesEnabled {
            NSSound(named: "Basso")?.play()
        }
        guard Defaults.scanOnAlert else { return false }
        guard !scanWasAlertTriggered, !isScanning else {
            log.debug("loop guard: not scanning for \(def.id, privacy: .public)")
            return false
        }
        if isAlertTriggeredScanInCooldown() {
            log.debug("cooldown guard: not scanning for \(def.id, privacy: .public)")
            return false
        }
        scanWasAlertTriggered = true
        return runScan(depth: .alertTriggered, reason: "checking \(def.title.lowercased())")
    }

    // MARK: - Power

    private func observeWorkspace() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard Defaults.pauseOnDisplaySleep else { return }
                self?.monitor.pause(reason: "the display is asleep")
                self?.heartbeat.pause()
                self?.syncAlertPauseState()
            }
        }
        nc.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.events.markSettling()
                self?.monitor.resume(reason: "the display is asleep")
                self?.heartbeat.resume()
                self?.syncAlertPauseState()
            }
        }
        nc.addObserver(forName: NSWorkspace.willSleepNotification,
                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.monitor.pause(reason: "your Mac is asleep")
                self?.heartbeat.pause()
                self?.syncAlertPauseState()
            }
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification,
                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.events.markSettling()
                self?.invalidateCurrentConnection()
                self?.monitor.resume(reason: "your Mac is asleep")
                self?.heartbeat.resume()
                if Defaults.monitoringEnabled { self?.monitor.restart() }
                self?.syncAlertPauseState()
                await self?.history.load()
            }
        }
        NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.evaluateBatteryPauseState()
                if Defaults.batterySaverCadence {
                    self?.applyCadenceSettings()
                }
            }
        }
    }

    func evaluateBatteryPauseState() {
        let shouldPause = Defaults.pauseOnBattery && PowerSourceHelper.isLowBattery
        if shouldPause {
            monitor.pause(reason: "low battery")
            heartbeat.pause()
        } else {
            monitor.resume(reason: "low battery")
            if !monitor.isPausedForAnyReason {
                heartbeat.resume()
            }
        }
        syncAlertPauseState()
    }
}

typealias NetdiagCoordinator = HopwatchCoordinator
