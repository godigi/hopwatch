import Foundation
import AppKit
import CoreWLAN
import os

/// The one object that owns the others and decides when they act.
///
/// Everything stateful in this app is reachable from here, which keeps the
/// interesting question — *what causes what* — answerable by reading one
/// file rather than by tracing five observers.
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
    /// The CLI's rules catalog — see that store's header for why it's
    /// `@Observable` rather than an actor like `CapabilityStore`. Every
    /// `RuleChip` and every category-driven report row reads
    /// `rulesCatalog.catalog` directly rather than awaiting anything.
    let rulesCatalog = RulesCatalogStore()
    /// The CLI's Wi-Fi signal scale — see that store's header. Same
    /// synchronous-read shape as `rulesCatalog`: the Wi-Fi cell on Home and
    /// in the dropdown reads `signalScale.scale` directly from a view body.
    let signalScale = SignalScaleStore()
    /// The observable face of `Defaults` — see `AppSettings`'s header.
    /// Owned here so one instance is shared by every view via the
    /// environment, instead of each view reading `Defaults` for itself.
    let appSettings = AppSettings()
    /// Automated update checker against GitHub releases.
    let updateChecker = UpdateChecker()
    /// macOS Location Services permission manager.
    let locationPermissions = LocationPermissionStore()
    /// The run in flight, phase by phase. Reset at the start of every run
    /// and fed from the child's fd-3 stream as it arrives.
    let progress = ScanProgress()
    /// Durable history of CLI-reported changes (monitor `changes` entries
    /// and fired alerts) — the dropdown's timeline and its
    /// time-since-last-change headline both read this. Named `eventLog`
    /// rather than `events` because that name is already `events:
    /// NetworkEventWatcher` above, a different thing (CoreWLAN/NWPath
    /// notifications, not stored history).
    let eventLog = EventStore()

    init() {
        locationPermissions.onAuthorizationChange = { [weak self] _ in
            self?.refreshLocationState()
        }
    }

    private var updateCheckTask: Task<Void, Never>?
    private(set) var latestRun: RunResult?
    /// Home's fallback for a session that has not run a scan yet.
    /// See `reportSource` for why this is a separate property rather than
    /// a second way to set `latestRun`, and `hydrateFromHistoryIfNeeded`
    /// for how it gets populated.
    private(set) var hydratedReport: RunDetail? {
        didSet {
            cachedHydratedRunResult = hydratedReport?.asRunResult
        }
    }
    private var cachedHydratedRunResult: RunResult?
    /// Live SSID read from CoreWLAN — the GUI's own source, not the CLI's.
    /// The bundled CLI reads the SSID via `ipconfig getsummary`, but TCC
    /// attributes that call to `/usr/sbin/ipconfig` rather than this .app,
    /// so a Location Services grant to netdiag unredacts the GUI's own
    /// CoreWLAN `ssid()` call but leaves the CLI's reading empty/redacted.
    /// Without this, a user who has granted Location sees "WiFi (SSID
    /// hidden by macOS)" in the dropdown even though the permission is
    /// live. Refreshed once per monitor sample (see `handleSample`) so a
    /// view body never pays for the CoreWLAN syscall.
    private(set) var liveSSID: String?
    private(set) var isScanning = false
    private(set) var activeScanDepth: NetdiagRunner.Depth?
    private(set) var scanStartedAt: Date?
    private(set) var lastRunError: String?

    var isSpeedTestOnly: Bool {
        isScanning && activeScanDepth == .speedOnly
    }

    var isSpeedTesting: Bool {
        isSpeedTestOnly || progress.isSpeedTesting
    }
    /// The last `--speed-only` result, kept apart from `latestRun`. A speed
    /// test measures one thing and diagnoses nothing, so letting it become
    /// the current report would replace a full diagnosis with a card that
    /// has no verdict on it — Part B of the spec, in the app's own terms.
    ///
    /// Keyed by the network it was measured on (`latestSpeedTestNetwork`)
    /// and read through `currentSpeedTest`, never directly: a throughput
    /// figure belongs to one network, and carrying the home fibre's 480/40
    /// into a café is how the Streaming tile came to read "4K ready" there.
    private(set) var latestSpeedTest: RunSnapshot.Speedtest?
    private(set) var latestSpeedTestAt: Date?
    private(set) var latestSpeedTestNetwork: String?
    /// A section (or a stored run) another surface has asked the main
    /// window to show. Consumed by `MainWindow`, which may not exist yet at
    /// the moment of asking — see `consumeRequestedDestination()`.
    var requestedDestination: MainDestination?
    /// Set while a scan started *by an alert* is in flight. The loop guard:
    /// a scan started this way must never start another. Without it, a
    /// scan's own bufferbloat and speed phases can raise the very alert
    /// that triggers the next scan, forever.
    private(set) var scanWasAlertTriggered = false

    private var scanTask: Task<Void, Never>?
    private var lastNetworkID: String?
    /// Whether cold-launch hydration has run against an *identified*
    /// network. Hydration is scoped to the network we are on, and `start()`
    /// kicks it off before the monitor has produced a sample — so the first
    /// attempt normally has no network to scope to and does nothing. This
    /// latches on the first attempt that had one, so `handleSample` can
    /// retry until the network is known without spawning a task on every
    /// sample forever afterwards.
    private var didHydrateForNetwork = false
    /// The current network's arrival state, mirrored into observable
    /// storage so the arrival card re-renders when it changes. `Defaults`
    /// is the source of truth; this is the copy SwiftUI can see.
    private(set) var arrivalState: ArrivalState = .unchecked
    /// The canonical id `arrivalState` describes. Views read this to name
    /// the network on the arrival card.
    private(set) var arrivalNetworkID: String?
    /// What the app will do next about an unchecked network — see
    /// `arrivalIntent(now:)` for why "unchecked" alone is not enough for
    /// the card to render honestly.
    private(set) var arrivalIntent: ArrivalCopy.Intent = .starting
    /// Consecutive declined arrival attempts for the current network, held
    /// in memory only: a backoff that survived relaunch would punish a
    /// user for quitting the app. Reset when the network changes or an
    /// attempt starts.
    private(set) var routerAdminAvailable = false
    private var lastProbedRouterIP: String?
    private var arrivalAttempts = 0
    private var nextArrivalAttemptAt: Date?
    /// Carried from `attemptArrival` to the scan's completion, which is
    /// where the terminal arrival state is written. Nil when the in-flight
    /// scan is not an arrival check.
    private var pendingArrivalNetworkID: String?
    private var pendingArrivalDepth: ArrivalDepth?
    private var pendingArrivalDecline: DeclineReason?
    /// The severity seen on the previous sample, used by `handleSample` to
    /// detect the ok/info → warn/critical edge that auto-starts an
    /// investigation burst. Stored on the coordinator rather than read back
    /// from the monitor so the transition is exact even when a burst
    /// restart resets the monitor's own sample window.
    private var lastSeverity: String = "ok"

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

    private(set) var recentResolutions: [ResolutionEvent] = []
    private var lastSample: MonitorSample?
    private var lastUnhealthySample: MonitorSample?
    private var previousActiveAlerts: [String: AlertEngine.ActiveAlert] = [:]

    var activeResolution: ResolutionEvent? {
        recentResolutions.last(where: { $0.isCurrent })
    }

    func dismissActiveResolution() {
        for idx in recentResolutions.indices where recentResolutions[idx].isCurrent {
            recentResolutions[idx].dismissed = true
        }
    }

    func recordResolution(title: String, message: String, icon: String = "checkmark.circle.fill") {
        let event = ResolutionEvent(title: title, message: message, timestamp: Date(), icon: icon)
        recentResolutions.append(event)
        if recentResolutions.count > 10 {
            recentResolutions.removeFirst(recentResolutions.count - 10)
        }
        log.info("resolution recorded: \(title, privacy: .public) — \(message, privacy: .public)")
    }

    private let log = Logger(subsystem: "com.godigi.hopwatch", category: "coordinator")

    // MARK: - Lifecycle

    func start() {
        // First, before anything reads a network id: a build that saw a
        // sample before migrating would treat every already-seen network
        // as unchecked and re-baseline the world.
        Defaults.migrateArrivalStatesIfNeeded()
        alerts.notificationManager = notifications
        notifications.notificationsEnabled = appSettings.notificationsEnabled
        notifications.scope = appSettings.notificationScope
        alerts.inNetworkGracePeriod = { [weak events] in
            events?.withinGracePeriod() ?? false
        }
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
        // Reap the monitor on quit. Without this the child is re-parented
        // to launchd and goes on pinging the gateway every ten seconds
        // after the app is gone — the exact misbehaviour that gets an
        // always-on app uninstalled.
        NotificationCenter.default.addObserver(
            forName: .netdiagWillTerminate, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }

        Task {
            await alerts.refreshAuthorization()
            await watcher.refresh()
            if watcher.isInstalled {
                log.info("Uninstalling legacy 15-minute background watcher")
                await watcher.uninstall()
            }
            await history.load()
            await hydrateFromHistoryIfNeeded()
        }
        // Its own task, not folded into the one above: the catalog gates
        // on a *different* capability (`rulesCatalog`, not `history`) and
        // has nothing to sequence after — chips and report rows render
        // fine before it resolves, they just show the inert fallback until
        // it does.
        rulesCatalog.ensureLoaded()
        // Same shape, same reasoning as rulesCatalog.ensureLoaded() above:
        // its own capability gate, nothing to sequence after.
        signalScale.ensureLoaded()
        // Events stored before the CLI phrased rule changes from the
        // catalog read "Issue G2 cleared". Rewrite them once the catalog
        // is in hand so an upgrade doesn't leave rule IDs in a timeline
        // whose whole point is plain language.
        Task { [weak self] in
            await self?.rulesCatalog.refresh()
            guard let self else { return }
            self.eventLog.rephraseLegacyRuleEvents { [weak self] ruleID in
                self?.rulesCatalog.catalog?[ruleID]?.title
            }
        }
        // Lets AlertEngine.activeSorted rank alerts by the CLI's own
        // severity instead of raise order — read live off the catalog each
        // call, so a rank asked for before the catalog resolves degrades to
        // 0 (raised-time order) rather than needing a second wiring step
        // once the fetch completes. `headline` below needs the identical
        // ranking to pick the worst *firing* rule rather than the first one
        // in evaluation order, so the rank itself lives in one method
        // (`severityRank(forRuleID:)`) both this closure and `headline`
        // call, instead of two copies of the same switch drifting apart.
        alerts.severityRank = { [weak self] ruleID in
            self?.severityRank(forRuleID: ruleID) ?? 0
        }
        // The settled text of an alert whose scan never produced a sentence
        // of its own: the catalog's blurb for the rule that fired, verbatim.
        // Read live for the same reason as `severityRank` — an alert settled
        // before the catalog loads is upgraded on the next sample.
        alerts.ruleText = { [weak self] ruleID in
            guard let blurb = self?.rulesCatalog.catalog?[ruleID]?.blurb, !blurb.isEmpty else { return nil }
            return blurb
        }
        if Defaults.monitoringEnabled { monitor.start() }
        startStaleWatch()

        // Wire update notification hook
        updateChecker.onUpdateFound = { [weak self] release in
            guard let self else { return }
            self.notifications.deliverUpdateNotification(
                version: release.cleanVersion,
                shortNotes: release.shortReleaseNotes
            )
        }

        // Start recurring periodic background update checks
        startPeriodicUpdateChecks()
    }

    func stop() {
        updateCheckTask?.cancel()
        staleWatchTask?.cancel()
        scanTask?.cancel()
        monitor.stop()
        events.stop()
    }

    private func startPeriodicUpdateChecks() {
        updateCheckTask?.cancel()
        updateCheckTask = Task { [weak self] in
            // Initial check after startup
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.updateChecker.performDailyCheck()

            // Periodic check loop (every 4 hours = 14,400 seconds)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 14_400_000_000_000)
                guard !Task.isCancelled else { break }
                self?.updateChecker.performDailyCheck()
            }
        }
    }

    // MARK: - Window activation policy

    /// How many of the app's real `Window` scenes (dashboard, settings,
    /// onboarding) are currently on screen. The app ships as `LSUIElement`
    /// — no Dock icon, no app-switcher slot, which is right for an always-on
    /// menu-bar monitor. But a window the user opened on purpose should
    /// behave like a normal window while it is on screen: the policy flips
    /// to `.regular` the moment the first one appears (Dock icon + Cmd-Tab
    /// slot) and back to `.accessory` the instant the last one closes (Dock
    /// icon vanishes, menu-bar dot stays). Driven by `onAppear`/`onDisappear`
    /// on each window's root view rather than by `NSWindow` notifications,
    /// which fire unreliably for SwiftUI `Window` scenes and left the Dock
    /// icon stuck or the switcher slot missing.
    private var openWindowCount = 0

    func windowAppeared() {
        openWindowCount += 1
        applyActivationPolicy()
    }

    func windowDisappeared() {
        if openWindowCount > 0 { openWindowCount -= 1 }
        applyActivationPolicy()
    }

    private func applyActivationPolicy() {
        let regular = openWindowCount > 0
        NSApp?.setActivationPolicy(regular ? .regular : .accessory)
        // Activating on open is what makes the window arrive in front
        // rather than behind whatever was frontmost, and is also the nudge
        // the app switcher needs to pick up a policy that just changed to
        // `.regular` at runtime.
        if regular { NSApp?.activate(ignoringOtherApps: true) }
    }

    // MARK: - Cold-launch hydration
    //
    // Home used to render nothing until the first scan of the session
    // finished, even on a machine with ~2,000 runs already in
    // `~/net-diag`. This fills that gap once, right after launch, without
    // ever letting the fallback be mistaken for a live measurement.

    /// Picks the newest run **on the network this machine is currently on**
    /// that counts as a check (`HistoryDocument.Run.isCheck` — the
    /// `run_mode` predicate docs/JSON-SCHEMA.md documents and
    /// `helpers/history.py` applies identically) and has an id `--show` can
    /// open, then fetches its full record via `details.detail(for:)`.
    ///
    /// The network predicate is the fix for a real bug. This used to take
    /// the newest stored check *anywhere*, and Home renders a hydrated
    /// report through the same `RunReportView` as a live one, with nothing
    /// on screen saying otherwise — so arriving somewhere new showed the
    /// previous building's report as if it were this network's, which is
    /// where a phantom "Wi-Fi over the last hour" warning at the top of a
    /// brand-new network's dashboard came from. Having no run for this
    /// network is the correct empty state: the arrival card is already
    /// saying a check is on its way.
    ///
    /// A nil current network means "not identified yet", never "any network
    /// will do" — hydrating from an arbitrary run there would reintroduce
    /// exactly this bug on a slow start. It is also the *ordinary* state at
    /// the moment `start()` first calls this: `monitor.start()` runs after
    /// this task is created, and the monitor's first sample costs a child
    /// process where `history.load()` is a local file read. So the first
    /// attempt normally finds no network and deliberately does nothing, and
    /// `handleSample` retries on the sample that finally names one — see
    /// `didHydrateForNetwork`. The one exception is monitoring being
    /// switched off, where no sample is ever coming and "wait" would mean
    /// "never"; the body says what happens there and why it is still safe.
    ///
    /// Silent on failure: a pruned run (the store rolls into an archive and
    /// is eventually trimmed) or a `netdiag` older than `--show` must fall
    /// back to the ordinary empty state, not an error banner for something
    /// the user never asked to happen. Called once, from `start()`, before
    /// any scan can plausibly have finished — but if one lands anyway while
    /// the `await` below is in flight, the assignment after it is
    /// deliberately not re-guarded: `reportSource` prefers `.live`
    /// regardless of which of the two was written last, so a hydrated
    /// report landing a moment after a real one is inert, not a race worth
    /// closing.
    /// Internal rather than private only so `GalleryMode` can reproduce the
    /// same state `start()` reaches without also starting the monitor —
    /// this is a read, and the screenshot harness needs Home to render the
    /// report a real launch would show rather than its empty state.
    ///
    /// - Parameter explicitNetworkID: The network to scope to, for a caller
    ///   with no live monitor to read one from. `GalleryMode` is the only
    ///   one: it deliberately never starts the monitor, so the live id is
    ///   always nil there and a strictly-scoped hydration would put the
    ///   empty state in every screenshot.
    func hydrateFromHistoryIfNeeded(explicitNetworkID: String? = nil) async {
        // "Nothing to show for this network", not "nothing in memory": after
        // a move, the previous network's report is still held but is out of
        // scope (`currentNetworkRun`), and this is how the new network gets
        // its own stored one rather than an empty Home until the next scan.
        if currentNetworkRun == nil {
            let current = explicitNetworkID ?? monitor.latest?.network.historyJoinID
            let id: String?
            if let current {
                // Latched on the first attempt that had a network at all,
                // so the `handleSample` retry stops once this has really
                // run.
                didHydrateForNetwork = true
                id = newestCheckID(onNetwork: current)
            } else if !Defaults.monitoringEnabled {
                // With monitoring off there will never be a sample, so
                // "wait for the monitor to name the network" leaves Home
                // empty forever rather than briefly — a different situation
                // from a slow start, and a regression against the behaviour
                // this had before it was scoped. So this one case keeps the
                // old fallback: the newest check anywhere.
                //
                // Safe, because it cannot produce the unlabelled report the
                // scoping exists to prevent. `HomeView.storedProvenance`
                // captions any report the live monitor cannot confirm is
                // about the network you are on, and with monitoring off it
                // can confirm nothing — so a report hydrated here always
                // arrives saying which network and when it came from.
                didHydrateForNetwork = true
                id = history.recentChecks(limit: 1).compactMap(\.runID).first
            } else {
                id = nil
            }
            if let id {
                do {
                    hydratedReport = try await details.detail(for: id)
                } catch {
                    log.debug("cold-launch hydration skipped: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        if latestSpeedTest == nil {
            // Scoped to the network we are on, or nothing: the unscoped
            // "newest speed test anywhere" is what put another network's
            // throughput on a cold launch's first screen. With no network
            // identified yet there is nothing to scope to, and `handleSample`
            // calls `adoptStoredSpeedTest(for:)` the moment one is.
            let current = explicitNetworkID ?? monitor.latest?.network.historyJoinID
            if let current { adoptStoredSpeedTest(for: current) }
        }
    }

    /// Replaces the in-memory speed test with the newest stored one *on this
    /// network* — a hydrated report's own if it is for this network, else the
    /// store's — or clears it when there is none. The only two writers of
    /// `latestSpeedTest` besides a finished scan, and both pass a network.
    private func adoptStoredSpeedTest(for networkID: String) {
        let hydratedID = hydratedReport.flatMap { $0.context.networkID ?? $0.run.network.historyJoinID }
        if let st = hydratedReport?.run.speedtest, st.downMbps != nil,
           let hydratedID,
           RunScope.isSameNetwork(run: hydratedID, live: networkID, canonical: history.canonicalID) {
            latestSpeedTest = st
            latestSpeedTestAt = hydratedReport?.run.timestamp.flatMap { FastISO8601.parse($0) }
            latestSpeedTestNetwork = networkID
        } else if let speed = history.latestSpeedTest(for: networkID) {
            latestSpeedTest = RunSnapshot.Speedtest(downMbps: speed.down, upMbps: speed.up)
            latestSpeedTestAt = speed.date
            latestSpeedTestNetwork = networkID
        } else {
            latestSpeedTest = nil
            latestSpeedTestAt = nil
            latestSpeedTestNetwork = nil
        }
    }

    /// The newest run on one network that counts as a check and carries an
    /// id `--show` can open.
    ///
    /// `history.runs(networkID:window:)` rather than a hand-rolled filter
    /// because it canonicalises *both* sides of the comparison through the
    /// store's own `canonicalID`, which follows manual merges — comparing
    /// raw ids would miss every run the user has merged into this network.
    ///
    /// Ordering matches `recentChecks`: newest first on the raw `ts`
    /// string, which docs/JSON-SCHEMA.md fixes at ISO 8601 UTC with no
    /// fractional seconds, so lexicographic order is already chronological
    /// order and the parse can be skipped.
    private func newestCheckID(onNetwork networkID: String) -> String? {
        history.runs(networkID: networkID, window: .all)
            .filter { $0.isCheck && $0.runID != nil }
            .max { ($0.ts ?? "") < ($1.ts ?? "") }?
            .runID
    }

    // MARK: - Monitoring toggle

    func setMonitoring(enabled: Bool) {
        Defaults.monitoringEnabled = enabled
        alerts.monitoringPaused = !enabled
        if enabled { monitor.start() } else { monitor.stop() }
    }

    /// Apply changed cadence settings. A restart rather than a signal,
    /// because the intervals are command-line arguments — the process has
    /// no way to be told about new ones.
    func applyCadenceSettings() {
        guard Defaults.monitoringEnabled, monitor.isRunning else { return }
        monitor.restart()
    }

    // MARK: - Samples

    private func handleSample(_ sample: MonitorSample) {
        refreshLiveWiFi()
        adoptLiveSSIDAsNameIfNeeded()
        alerts.evaluate(sample: sample)
        if alerts.active.isEmpty && !notifications.announcedFaults.isEmpty && sample.health == .healthy {
            notifications.deliverRestored(
                networkName: liveSSID ?? sample.network.label ?? "Network",
                latencyMs: sample.gateway.rttAvgMs ?? sample.internet.rttAvgMs
            )
        }
        evaluateResolutions(sample: sample)
        considerInvestigationBurst(sample)

        // The first cycle of a monitor process records monitor-started, matching
        // the event journal (helpers/monitor_sample.py:256). ActivityEntry.fold
        // uses this boundary to close open episodes as lower bounds rather than
        // silently spanning the restart with a "+" — except where this app
        // restarted its own monitor, which it knows, and the network is not
        // known to have changed. That one is marked and stepped over: it is
        // no evidence a fault ended. `lastNetworkID` still names the network
        // of the previous process here; it is advanced further down.
        if sample.seq == 1 {
            eventLog.record(
                kind: "monitor-started",
                summary: "Monitoring started",
                network: sample.network.id,
                date: sample.timestamp,
                continuesPrevious: NetworkEvent.continuesPrevious(
                    appRestarted: monitor.childContinuesPrevious,
                    previousNetwork: lastNetworkID,
                    currentNetwork: sample.network.historyJoinID))
        }

        for change in sample.changes {
            eventLog.record(
                kind: change.kind,
                summary: change.summary,
                ruleID: change.field == "status.rules"
                    ? (change.to ?? change.from) : nil,
                network: sample.network.id,
                date: sample.timestamp,
                evidence: change.evidence)
        }

        if let gwIP = sample.link.gateway, gwIP != lastProbedRouterIP {
            lastProbedRouterIP = gwIP
            Task { [weak self] in
                let available = await RouterAdminProbeStore.shared.checkAvailability(for: gwIP)
                await MainActor.run {
                    self?.routerAdminAvailable = available
                }
            }
        }

        // Not identified yet — the CLI has no group and no usable record
        // id. Decide nothing: `nil` here has never meant "a new network".
        guard let id = sample.network.historyJoinID else { return }

        // The sample that finally names a network is also the first moment
        // cold-launch hydration can be scoped to one — `start()` runs it
        // well before this, when there is nothing to scope to. See
        // `didHydrateForNetwork`.
        if !didHydrateForNetwork, latestRun == nil, hydratedReport == nil {
            Task { await hydrateFromHistoryIfNeeded() }
        }

        if id != lastNetworkID {
            lastNetworkID = id
            // A throughput figure is about one network. Swap it for this
            // network's own stored one (or none) before any view can draw
            // the previous network's under the new name.
            if latestSpeedTestNetwork.map({ history.canonicalID($0) }) != history.canonicalID(id) {
                adoptStoredSpeedTest(for: id)
            }
            if currentNetworkRun == nil { Task { await hydrateFromHistoryIfNeeded() } }
            alerts.networkChanged(to: id)
            log.info("now on network \(id, privacy: .public)")
            // A different network's backoff is meaningless.
            arrivalAttempts = 0
            nextArrivalAttemptAt = nil
        }

        // Deliberately outside the id-changed guard above. The previous
        // version attempted the arrival scan *inside* it, having already
        // advanced `lastNetworkID` — so a scan declined for being busy
        // could never be retried, because every later sample returned at
        // the guard. Its comment promised "the next sighting retries";
        // there is no next sighting while you stay on the network. A live
        // install had "SB Airbnb" named in `networkNames` and absent from
        // `seenNetworks`, which is only reachable that way.
        considerArrival(for: id, sample: sample)
    }

    // MARK: - Arrival

    /// The one automatic check, and the reason there is no timed one:
    /// joining a network for the first time is exactly when a baseline of
    /// what it can do — throughput, bufferbloat, path MTU — is worth
    /// having. Monitoring covers the continuous question; this covers the
    /// one-off one. See CLAUDE.md's three-depth table.
    private func considerArrival(for id: String, sample: MonitorSample) {
        let state = Defaults.arrivalStates[id] ?? .unchecked
        // Assigned only on a real change. Under `@Observable` a write
        // invalidates every observer whether or not the value differs, and
        // this runs once per monitor sample — every 5 s on the fast tier.
        // Unguarded, the arrival card would redraw on a timer for as long
        // as the app is open.
        if arrivalNetworkID != id { arrivalNetworkID = id }
        if arrivalState != state { arrivalState = state }

        // Published before the guards below, because the card renders what
        // is *not* going to happen as carefully as what is. An `.unchecked`
        // network whose automatic check is switched off, or is queued
        // behind a running scan, must not wear the same spinner as one
        // being measured right now.
        let intent = arrivalIntent(now: Date())
        if arrivalIntent != intent { arrivalIntent = intent }

        guard Defaults.scanOnNewNetwork else { return }
        let now = Date()
        guard state.needsAttempt(now: now) else { return }
        if let next = nextArrivalAttemptAt, now < next { return }

        switch ArrivalPolicy.decide(hasSample: true,
                                    severity: sample.status.severity,
                                    isExpensive: events.pathIsExpensive,
                                    isConstrained: events.pathIsConstrained) {
        case .wait:
            // Unreachable from here — we hold a sample. Kept exhaustive
            // rather than defaulted so a future case cannot be silently
            // swallowed into "do nothing".
            return

        case .full:
            attemptArrival(id: id, depth: .full, reason: "new network")

        case .quick(let why):
            // A decision, not a failure: recorded so it does not retry,
            // and rendered as a button rather than a spinner.
            attemptArrival(id: id, depth: .quick,
                           reason: "new network (\(why.rawValue))",
                           declineWith: why)
        }
    }

    /// Try to start an arrival check, and record what happened.
    ///
    /// `launch()` silently declines while another scan is in flight. That
    /// decline must leave the state `.unchecked` so the next sample tries
    /// again — the bug being fixed here is precisely a decline that was
    /// recorded as nothing and never retried.
    private func attemptArrival(id: String, depth: ArrivalDepth, reason: String,
                                declineWith: DeclineReason? = nil) {
        let now = Date()
        guard runScan(depth: depth.runnerDepth, reason: reason) else {
            arrivalAttempts += 1
            // 30 s doubling, capped at five minutes. In memory only.
            let delay = min(30 * pow(2, Double(arrivalAttempts - 1)), 300)
            nextArrivalAttemptAt = now.addingTimeInterval(delay)
            log.debug("arrival check for \(id, privacy: .public) declined — a scan is running; retrying in \(delay, format: .fixed(precision: 0))s")
            return
        }

        arrivalAttempts = 0
        nextArrivalAttemptAt = nil

        // `.checking` while it runs, so Home shows progress rather than a
        // stale report. The scan's completion writes the terminal state.
        setArrivalState(.checking(depth: depth, startedAt: now), for: id)
        pendingArrivalNetworkID = id
        pendingArrivalDepth = depth
        pendingArrivalDecline = declineWith
    }

    /// Stand in for the arrival state the monitor would have established,
    /// for `GalleryMode` only.
    ///
    /// The gallery never starts the monitor, so without this every Home
    /// screenshot renders the arrival card over a report the app has
    /// plainly already got — "New network: this network", above a header
    /// naming the network, above a full set of measurements. That is not
    /// what a launch on a known network looks like, and the gallery exists
    /// to show what the app looks like.
    ///
    /// `.checked` rather than the real stored state: the ordinary case
    /// this screenshot stands for is a network already known, and the
    /// arrival card's own states have seven dedicated renders from
    /// `--verify`. Writes nothing to `Defaults` — a screenshot run must
    /// not mutate arrival history, which is the same contract
    /// `GalleryMode.hydrate` keeps for the monitor and the event log.
    func adoptGalleryArrivalState(networkID: String?) {
        arrivalNetworkID = networkID.flatMap(HopwatchGUI.NetworkIdentity.canonical)
        arrivalState = .checked(depth: .full, at: Date(), runID: nil)
        arrivalIntent = .starting
    }

    /// Sets up a synthetic healthy sample for GalleryMode previews.
    func adoptGalleryMonitorSample(networkID: String?, displayName: String?) {
        let name = displayName ?? "Home Wi-Fi"
        self.liveSSID = name
        self.stalenessSuspended = true

        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // Create a realistic sequence of ~20 samples for sparklines and live charts
        var historySamples: [MonitorSample] = []
        let baselineGwRtt = 3.2
        let baselineInetRtt = 17.8

        for i in (0..<30).reversed() {
            let sampleDate = now.addingTimeInterval(-Double(i * 10))
            let gwJitter = Double((i * 7) % 5) * 0.2 - 0.4
            let inetJitter = Double((i * 13) % 7) * 0.4 - 1.2
            let s = MonitorSample(
                schema: 2,
                version: AppVersion.display,
                ts: formatter.string(from: sampleDate),
                seq: 100 - i,
                gapS: 0,
                jitterMs: 1.2,
                refreshed: ["fast", "medium", "slow"],
                link: .init(
                    up: true,
                    interface: "en0",
                    type: "wifi",
                    ip: "192.168.1.142",
                    gateway: "192.168.1.1",
                    gatewayMAC: "14:91:82:aa:bb:cc",
                    ssid: name,
                    bssid: "14:91:82:aa:bb:cc"
                ),
                network: .init(
                    id: networkID ?? "wifi:ssid=\(name)",
                    label: name,
                    groupId: networkID ?? "mac:14:91:82:aa:bb:cc"
                ),
                vpn: .init(
                    active: false,
                    type: nil,
                    name: nil
                ),
                gateway: .init(
                    lossPct: 0.0,
                    rttAvgMs: max(1.0, baselineGwRtt + gwJitter),
                    rttJitterMs: 0.4
                ),
                internet: .init(
                    lossPct: 0.0,
                    rttAvgMs: max(10.0, baselineInetRtt + inetJitter),
                    rttJitterMs: 1.2
                ),
                wifi: .init(
                    rssi: -52,
                    noise: -92,
                    snr: 40,
                    channel: "149 (5 GHz, 80 MHz)"
                ),
                dns: .init(
                    ok: true,
                    resolver: "192.168.1.1",
                    elapsedMs: 8.4
                ),
                tcp: .init(
                    anyOk: true,
                    targets: [
                        .init(host: "1.1.1.1", port: 443, ok: true, elapsedMs: 16.2),
                        .init(host: "8.8.8.8", port: 443, ok: true, elapsedMs: 18.1)
                    ]
                ),
                publicInfo: .init(
                    ok: true,
                    ip: "198.51.100.42",
                    isp: "Fiber Broadband",
                    asn: "AS13335",
                    city: "San Francisco",
                    country: "United States",
                    countryISO: "US",
                    captivePortal: false
                ),
                status: .init(
                    severity: "ok",
                    measurement: "measured",
                    rules: [],
                    icmpFiltered: false,
                    degraded: false,
                    paused: false,
                    cadenceS: 10
                ),
                changes: []
            )
            historySamples.append(s)
        }

        if let latestSample = historySamples.last {
            monitor.adoptGallerySample(latestSample, historical: historySamples)
        }
    }


    /// `--verify` only: put the session's report and speed test in place
    /// without running a scan or touching the CLI.
    func adoptSessionStateForTesting(latestRun: RunResult? = nil, hydrated: RunDetail? = nil,
                                     speed: RunSnapshot.Speedtest? = nil, speedAt: Date? = nil,
                                     speedNetwork: String? = nil) {
        self.latestRun = latestRun
        self.hydratedReport = hydrated
        self.latestSpeedTest = speed
        self.latestSpeedTestAt = speedAt
        self.latestSpeedTestNetwork = speedNetwork
    }

    /// Gallery fixture for the moved-network state (`--gallery-moved`): the
    /// monitor now says the Mac is on a network the hydrated report and the
    /// stored speed test are *not* about, and its public lookup came back
    /// empty (a portal blocking it) — the case where an unscoped fallback
    /// chain fills the flag, IP and ISP from the previous network.
    func adoptGalleryMovedNetwork() {
        guard var moved = monitor.latest else { return }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        moved.ts = formatter.string(from: Date())
        moved.network = .init(id: "wifi:ssid=Corner Cafe", label: "Corner Cafe", groupId: "ssid:corner-cafe")
        moved.link.ssid = "Corner Cafe"
        moved.publicInfo = .init()
        liveSSID = "Corner Cafe"
        monitor.adoptGallerySample(moved, historical: monitor.recent.dropLast() + [moved])
    }

    /// Gallery fixture for the stale-monitor state (`--gallery-stale`): the
    /// healthy sample, aged past the freshness window, with staleness
    /// checking switched back on (the other fixtures suspend it, because they
    /// are written once and rendered over many seconds).
    func adoptGalleryStaleSample() {
        guard var old = monitor.latest else { return }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        old.ts = formatter.string(from: Date().addingTimeInterval(-300))
        monitor.adoptGallerySample(old, historical: monitor.recent.dropLast() + [old])
        stalenessSuspended = false
    }

    /// Gallery fixture for the no-link state (`--gallery-no-link`): the
    /// newest sample says `link.up == false` while still *carrying* the last
    /// healthy sample's measurements — stale router loss, jitter, public
    /// country, and the CLI's default `type: "wired"` — over a rolling
    /// window of healthy samples. That is the worst case the GUI has to
    /// survive whatever the monitor emits (a CLI that nulls a down sample
    /// makes it easier, never harder), and it is what the original
    /// screenshots showed.
    func adoptGalleryNoLinkSample() {
        guard var down = monitor.latest else { return }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        down.ts = formatter.string(from: Date())
        down.seq = (down.seq ?? 0) + 1
        down.link = .init(up: false, interface: nil, type: "wired", ip: nil, gateway: nil,
                          gatewayMAC: nil, ssid: nil, bssid: nil)
        down.gateway.lossPct = 10
        down.gateway.rttJitterMs = 3
        down.status = .init(severity: "critical", measurement: "link-down", rules: ["N1"],
                            icmpFiltered: false, degraded: true, paused: false, cadenceS: 5)
        monitor.adoptGallerySample(down, historical: monitor.recent + [down])
    }

    /// What the app is about to do on its own about an unchecked network.
    ///
    /// Exists because "unchecked" alone cannot tell a user whether to wait
    /// or to press something. Three outcomes, and the card renders each
    /// differently: a check is imminent, a check is queued behind one
    /// already running, or no automatic check is coming at all because the
    /// Settings toggle is off. Before this, all three showed the same
    /// spinner and the same "Starting a check." — so a user who had turned
    /// the feature off saw a permanent promise of work that would never
    /// arrive.
    private func arrivalIntent(now: Date) -> ArrivalCopy.Intent {
        guard Defaults.scanOnNewNetwork else { return .notAutomatic }
        // A backoff is only ever set by a decline for busy-ness, and the
        // longest is five minutes — far too long to keep claiming a check
        // is "starting".
        if let next = nextArrivalAttemptAt, now < next { return .waitingForAnotherCheck }
        if isScanning, !isArrivalCheck { return .waitingForAnotherCheck }
        return .starting
    }

    /// Write one network's arrival state to both the store and the
    /// observable mirror, so the two cannot disagree.
    private func setArrivalState(_ state: ArrivalState, for id: String) {
        var all = Defaults.arrivalStates
        all[id] = state
        Defaults.arrivalStates = all
        if id == arrivalNetworkID { arrivalState = state }
    }

    /// Write the terminal arrival state for a scan that has just landed.
    ///
    /// `.declined` when the policy chose the quick check for a reason the
    /// user can override, `.checked` otherwise. Both are terminal: neither
    /// retries. A check that failed or was cancelled never reaches here and
    /// stays `.unchecked`, so the next sample tries again.
    ///
    /// `measured` is the network the finished run actually describes. When
    /// it disagrees with the network the check was started for, the user
    /// changed networks mid-scan and this result belongs to neither: the
    /// run may have measured the new network for most of its length, so
    /// crediting it to the old one would either file a report labelled B
    /// under A, or — on an early switch — mark A checked having never
    /// measured it, silently spending its one automatic baseline. Both
    /// networks are left `.unchecked` instead, and both retry.
    private func finishArrivalIfPending(runID: String?, measured: String?) {
        guard let id = pendingArrivalNetworkID, let depth = pendingArrivalDepth else { return }
        let decline = pendingArrivalDecline
        clearPendingArrival()

        // `measured == nil` is "the run could not name its network", not
        // "a different network" — treat it as agreeing, since the check
        // did run and refusing it would retry forever.
        guard measured == nil || measured == id else {
            log.info("arrival check for \(id, privacy: .public) landed after a network change — left unchecked so it retries")
            return
        }

        if let decline {
            setArrivalState(.declined(depth: depth, reason: decline, at: Date()), for: id)
        } else {
            setArrivalState(.checked(depth: depth, at: Date(), runID: runID), for: id)
        }
        log.info("arrival check for \(id, privacy: .public) finished at \(depth.rawValue, privacy: .public)")
    }

    /// Forget the in-flight arrival check without writing a terminal
    /// state. Used when a scan fails or is cancelled: the network stays
    /// `.unchecked`, so the next sample retries. That retry is the entire
    /// point of this change.
    private func clearPendingArrival() {
        pendingArrivalNetworkID = nil
        pendingArrivalDepth = nil
        pendingArrivalDecline = nil
    }

    /// Whether the in-flight scan (if any) is an arrival check.
    var isArrivalCheck: Bool { pendingArrivalNetworkID != nil }

    /// The arrival card's override button: run the full check the policy
    /// declined, and record it as this network's arrival check.
    func runDeclinedFullCheck() {
        guard let id = arrivalNetworkID else { return }
        guard runScan(depth: .full, reason: "you asked for the full check anyway") else { return }
        setArrivalState(.checking(depth: .full, startedAt: Date()), for: id)
        pendingArrivalNetworkID = id
        pendingArrivalDepth = .full
        pendingArrivalDecline = nil
    }

    /// Auto-start a short, fast-cadence "investigation" burst the moment
    /// the CLI's verdict turns from ok/info to warn/critical — before an
    /// alert's dwell has elapsed and before any triggered scan lands. The
    /// user's mental model is that the app starts pinging constantly and
    /// fast the instant something looks wrong, and this is what delivers
    /// it: the monitor restarts at the 2 s latency-test floor for 60 s, so
    /// gateway and internet ping arrive every 2 s rather than every 5 s
    /// while the problem is being confirmed. After the burst, sustained
    /// degraded (3 s) takes over for as long as severity stays warn/
    /// critical — `MON_DEGRADED` follows severity in `lib/monitor.sh`'s
    private func evaluateResolutions(sample: MonitorSample) {
        // If an active resolution exists, verify it remains valid under the new sample.
        // If packet loss has returned or new alerts/faults appeared, dismiss it immediately.
        if activeResolution != nil {
            let hasLoss = (sample.gateway.lossPct ?? 0) >= 3.0 || (sample.internet.lossPct ?? 0) >= 3.0
            if !sample.link.up || sample.status.severity != "ok" || !alerts.active.isEmpty || hasLoss {
                dismissActiveResolution()
            }
        }

        // Only evaluate resolutions if the link is up and the connection is currently healthy
        guard sample.link.up, sample.status.severity == "ok", alerts.active.isEmpty else {
            if sample.status.severity == "critical" || sample.status.severity == "warn" || sample.publicInfo.captivePortal == true || !alerts.active.isEmpty {
                lastUnhealthySample = sample
            }
            previousActiveAlerts = alerts.active
            lastSample = sample
            return
        }

        // We are currently healthy. Check if we just transitioned from an unhealthy state
        if let prev = lastUnhealthySample {
            // Case 1: Captive Portal Authentication Succeeded
            if prev.publicInfo.captivePortal == true && sample.publicInfo.captivePortal == false {
                recordResolution(
                    title: "Online",
                    message: "Captive portal authentication succeeded. Internet access active.",
                    icon: "checkmark.circle.fill"
                )
            }
            // Case 2: Wi-Fi Band Switch (2.4 GHz to 5 GHz / 6 GHz)
            else if let prevCh = prev.wifi?.channel, let prevChNum = Int(prevCh), prevChNum <= 14,
                    let currCh = sample.wifi?.channel, let currChNum = Int(currCh), currChNum >= 32 {
                recordResolution(
                    title: "Wi-Fi Improved",
                    message: "Moved from 2.4 GHz to 5 GHz (Ch \(currCh)). Negotiated higher throughput.",
                    icon: "wifi"
                )
            }
            // Case 3: Wi-Fi Signal Restored
            else if let prevRssi = prev.wifi?.rssi, prevRssi <= -75,
                    let currRssi = sample.wifi?.rssi, currRssi >= -65 {
                recordResolution(
                    title: "Signal Restored",
                    message: "Wi-Fi signal jumped from \(prevRssi) dBm to \(currRssi) dBm (Excellent).",
                    icon: "wifi"
                )
            }
            // Case 4: Network Packet Loss Stabilized
            else if (prev.gateway.lossPct ?? 0) >= 3.0 || (prev.internet.lossPct ?? 0) >= 3.0,
                    (sample.gateway.lossPct ?? 0) < 1.0 && (sample.internet.lossPct ?? 0) < 1.0 {
                let ping = sample.internet.rttAvgMs ?? sample.gateway.rttAvgMs
                let pingText = ping.map { "\(Int($0.rounded())) ms ping" } ?? "low latency"
                recordResolution(
                    title: "Network Stabilized",
                    message: "Packet loss resolved (0% loss, \(pingText)).",
                    icon: "checkmark.circle.fill"
                )
            }
            // Case 5: Previous active alert cleared
            else if let clearedAlert = previousActiveAlerts.values.first {
                recordResolution(
                    title: "Issue Resolved",
                    message: "\(clearedAlert.title) is back to normal.",
                    icon: "checkmark.circle.fill"
                )
            }
            // Reset lastUnhealthySample now that it's been resolved
            lastUnhealthySample = nil
        } else if let clearedAlert = previousActiveAlerts.values.first {
            // Even if lastUnhealthySample wasn't retained, an alert cleared
            recordResolution(
                title: "Issue Resolved",
                message: "\(clearedAlert.title) is back to normal.",
                icon: "checkmark.circle.fill"
            )
        }

        previousActiveAlerts = alerts.active
        lastSample = sample
    }

    /// `_mon_rules`. Fires only on the genuine ok/info → warn/critical
    /// edge, not on every warn/critical sample, so a sustained outage
    /// gets one surge at onset and a steady 3 s after, not a restart
    /// every minute. A burst already running is not re-triggered; a scan
    /// in progress blocks it (a scan pauses the monitor and saturates the
    /// link, and a burst's 2 s samples would be measuring the scan's own
    /// traffic); a paused or stopped monitor has nothing to burst.
    private func considerInvestigationBurst(_ sample: MonitorSample) {
        let sev = sample.status.severity
        defer { lastSeverity = sev }
        let turnedBad = (sev == "warn" || sev == "critical")
            && lastSeverity != "warn" && lastSeverity != "critical"
        guard turnedBad,
              !sample.status.paused,
              monitor.isRunning, !monitor.isPaused,
              !isScanning,
              !monitor.isBursting,
              Defaults.monitoringEnabled else { return }
        monitor.beginBurst(interval: Defaults.latencyTestInterval,
                           duration: Defaults.latencyTestDuration)
        log.info("severity turned \(sev, privacy: .public) — started 2s investigation burst")
    }

    private func handleNetworkEvent(_ event: NetworkEventWatcher.Event) {
        // CoreWLAN and NWPathMonitor are near-instant where the monitor
        // loop is up to a cadence behind. The monitor is the fallback, not
        // the primary detector — so nudge it to resample now rather than
        // letting the flag and public IP sit stale for ten seconds.
        //
        // A path going unsatisfied is the loudest of these and used to be
        // the one that returned early, so a disconnect waited for the next
        // monitor tick (5 s degraded, 10 s otherwise) before the dot and
        // the card changed. The resample is local and cheap, so it happens
        // for every event. What stays skipped when the path is gone is the
        // part that needs a network: the history reload and the update
        // check. The alert engine's grace window is not touched here — it
        // is opened by `NetworkEventWatcher.emit` before this handler runs —
        // so the resample cannot make a disconnect alert fire early.
        if case .pathChanged(let satisfied, _) = event, !satisfied {
            log.debug("network path lost — forcing monitor refresh")
            monitor.forceRefresh()
            return
        }
        log.debug("network event — refreshing history and forcing monitor refresh")
        monitor.forceRefresh()
        Task { await history.load() }
        updateChecker.performDailyCheck()
    }

    // MARK: - Scans

    /// Returns whether the scan actually started, as opposed to being
    /// silently declined because one was already in flight — see
    /// `launch(depth:reason:target:adoptAsReport:)` for the guard, and the
    /// first-sighting trigger in `handleSample` for the caller that has to
    /// tell the two apart. Every other caller uses this as a plain
    /// fire-and-forget action, which is why the result is
    /// `@discardableResult`.
    @discardableResult
    func runScan(depth: NetdiagRunner.Depth, reason: String, target: String? = nil) -> Bool {
        launch(depth: depth, reason: reason, target: target, adoptAsReport: true)
    }

    /// Whether the "Full check" action should be offered as runnable right
    /// now. Read by the views to disable the control and say why.
    var fullCheckIsSafe: Bool {
        FullCheckPolicy.isSafe(severity: monitor.latest?.status.severity ?? "")
    }

    /// The full battery: bufferbloat, the MTU probe, per-hop loss and a
    /// speed test — none of which any other depth produces, and all of
    /// which the Report card, the Trends charts and the dropdown's
    /// throughput cells are built to display.
    ///
    /// Refuses while the CLI's verdict is critical, and falls back to the
    /// alert-triggered depth instead of doing nothing: someone who pressed
    /// this button wants a check, and the lighter one is still worth
    /// running. See `FullCheckPolicy` for why bufferbloat is the specific
    /// hazard.
    ///
    /// Returns whether a scan actually started (full depth, or the
    /// `alertTriggered` fallback) — see `runScan` for why this is a
    /// `Bool` rather than `Void`.
    @discardableResult
    func runFullCheck(reason: String = "you asked for a full check") -> Bool {
        guard fullCheckIsSafe else {
            return runScan(depth: .alertTriggered, reason: reason)
        }
        return runScan(depth: .full, reason: reason)
    }

    /// Runs a focused speed test (--speed-only) to measure download, upload,
    /// latency and jitter without running a full diagnostic check.
    /// Updates latestSpeedTest and reloads history.
    @discardableResult
    func runSpeedTest(reason: String = "speed test requested") -> Bool {
        launch(depth: .speedOnly, reason: reason, target: nil, adoptAsReport: false)
    }

    /// Returns `true` once the scan has actually been handed to a `Task` —
    /// `false` when the guard below declined it. That distinction is the
    /// whole point of the return value: a caller that only finds out a scan
    /// *would* run by checking `isScanning` beforehand has a race between
    /// the check and this call, where the return value has none, since both
    /// happen on the same synchronous call.
    @discardableResult
    private func launch(depth: NetdiagRunner.Depth, reason: String,
                        target: String? = nil, adoptAsReport: Bool) -> Bool {
        guard !isScanning else {
            log.debug("scan already running, ignoring request: \(reason, privacy: .public)")
            return false
        }
        isScanning = true
        activeScanDepth = depth
        scanStartedAt = Date()
        lastRunError = nil
        progress.reset()

        // Both halves matter. Pausing the monitor keeps the scan's speed
        // test and bufferbloat probe from poisoning the samples and
        // flipping the cadence to "degraded"; holding alerts keeps the app
        // from notifying about latency it caused itself. And the scan's own
        // loss probe needs a quiet link — the same constraint that forbids
        // parallelising it with bufferbloat inside the CLI.
        //
        // The pause is SIGUSR1, not SIGSTOP. See MonitorStream for why the
        // obvious mechanism kills the process 2 s in.
        monitor.pause(reason: "a check is running")
        alerts.scanInProgress = true

        scanTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isScanning = false
                self.activeScanDepth = nil
                self.scanStartedAt = nil
                self.scanWasAlertTriggered = false
                self.alerts.scanInProgress = false
                // After `evaluate(run:)` had its chance (the success path
                // above ran it already), so this only reaches an alert whose
                // scan failed, was cancelled, or never landed — the banner
                // must not go on saying it is checking once the child is gone.
                self.alerts.scanEnded()
                self.monitor.resume(reason: "a check is running")
                // Whatever happened — a clean exit, a crash, Cancel — the
                // child is gone, so no phase can report again. Without this
                // a cancelled run leaves its rows spinning forever.
                self.progress.processEnded(exit: nil)
            }
            do {
                let result = try await NetdiagRunner.run(depth: depth, target: target,
                                                         progress: self.progress)
                guard !Task.isCancelled else {
                    // Cancelled between the child exiting and this line.
                    // The run may well have completed, but nothing here
                    // adopted it, so claiming the network was checked
                    // would record a baseline the user cannot open.
                    self.clearPendingArrival()
                    return
                }
                if adoptAsReport {
                    self.latestRun = result
                    self.hydratedReport = nil
                    self.alerts.evaluate(run: result.snapshot)
                }
                if let st = result.snapshot.speedtest, st.downMbps != nil {
                    self.latestSpeedTest = st
                    self.latestSpeedTestAt = result.finishedAt
                    self.latestSpeedTestNetwork = result.snapshot.network.historyJoinID
                        ?? self.monitor.latest?.network.historyJoinID
                }
                // The run appended itself to baseline.jsonl, so the charts
                // and the network list are one record out of date until
                // this reload.
                await self.history.load()
                self.finishArrivalIfPending(runID: result.snapshot.runID,
                                            measured: result.snapshot.network.historyJoinID)
                self.log.info("\(reason, privacy: .public) finished in \(result.duration, format: .fixed(precision: 1))s, exit \(result.exitCode)")
            } catch is CancellationError {
                self.clearPendingArrival()
                self.log.debug("scan cancelled")
            } catch {
                self.clearPendingArrival()
                self.lastRunError = error.localizedDescription
                self.log.error("scan failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return true
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
    }

    // MARK: - Repairs

    /// Where the repair the user last pressed has got to; `nil` once
    /// dismissed. One at a time: a second repair while one is in flight is
    /// refused rather than queued.
    private(set) var repairOutcome: RepairOutcome?
    private var repairTask: Task<Void, Never>?

    var isRepairing: Bool { repairOutcome?.isInFlight == true }

    /// Whether a finding's repair buttons may be shown. They are for the
    /// network you are on *now*, so they require a scan from this session
    /// — never a report hydrated from history, which may be from another
    /// network and hours old — and, when the monitor has a sample, that the
    /// monitor still sees the rule firing. A button offering to quit an app
    /// for a fault that has already cleared is a button that does nothing.
    func repairsAreCurrent(forRule ruleID: String?) -> Bool {
        guard let ruleID, latestRun != nil else { return false }
        if let rules = monitor.latest?.status.rules { return rules.contains(ruleID) }
        return true
    }

    func dismissRepairOutcome() {
        guard !isRepairing else { return }
        repairOutcome = nil
    }

    /// Run a repair the user has just confirmed, then find out whether it
    /// worked. Only ever called from a button the user pressed — never from
    /// a timer, an arrival or an alert (CLAUDE.md, Read-only).
    ///
    /// The repair itself is `hopwatch --repair=…`: this app only invokes
    /// it. Afterwards, for a repair whose effect is immediate, the existing
    /// quick depth re-checks (non-saturating, the same depth an arrival
    /// uses; deliberately not a button), and the answer is whether the
    /// finding's own rule still fires. A repair the user has to finish
    /// (sign in) or that ends the session (restart) is not judged: the CLI's
    /// message is shown, and the monitor keeps watching as it always does.
    func runRepair(_ repair: RunSnapshot.Diagnosis.Repair, forRule ruleID: String) {
        guard !isRepairing else { return }
        repairOutcome = RepairOutcome(ruleID: ruleID, label: repair.label,
                                      phase: .working, detail: nil)
        repairTask = Task { [weak self] in
            await self?.performRepair(repair, forRule: ruleID)
        }
    }

    private func performRepair(_ repair: RunSnapshot.Diagnosis.Repair,
                               forRule ruleID: String) async {
        func finish(_ phase: RepairOutcome.Phase, _ detail: String? = nil) {
            repairOutcome = RepairOutcome(ruleID: ruleID, label: repair.label,
                                          phase: phase, detail: detail)
        }
        let result: NetdiagRunner.RepairResult
        do {
            result = try await NetdiagRunner.repair(repair)
        } catch NetdiagError.scriptError(let reason) {
            finish(.failed, reason)
            return
        } catch {
            finish(.failed, error.localizedDescription)
            return
        }
        eventLog.record(kind: "repair", summary: result.message, ruleID: ruleID,
                        network: monitor.latest?.network.id)
        guard result.ok else {
            finish(.failed, result.message)
            return
        }
        guard repair.recheck == "now" else {
            finish(.done, result.message)
            return
        }

        finish(.checking)
        // A scan already running is waited out rather than raced: its
        // result may predate the repair.
        if isScanning { await scanTask?.value }
        let startedAt = Date()
        guard runScan(depth: .quick, reason: "checking whether that helped") else {
            finish(.failed, "Hopwatch couldn't re-check just now.")
            return
        }
        await scanTask?.value
        guard lastRunError == nil, let run = latestRun, run.startedAt >= startedAt else {
            finish(.failed, "Hopwatch couldn't re-check just now.")
            return
        }
        if run.snapshot.diagnosis.contains(where: { $0.rule == ruleID }) {
            finish(.didntHelp, repair.ifUnfixed)
        } else {
            finish(.fixed)
        }
    }

    // MARK: - Latency test

    func stopLatencyTest() { monitor.endBurst() }

    func consumeRequestedDestination() -> MainDestination? {
        defer { requestedDestination = nil }
        return requestedDestination
    }

    /// An alert fired. Run a scan so the notification can be replaced with
    /// the CLI's own explanation — that in-place update is the entire point
    /// of the trigger.
    ///
    /// Returns whether a scan was actually started, because the answer is
    /// what decides whether the alert's banner may say it is checking: every
    /// early `return false` below is a path where nothing is running, and
    /// `AlertEngine` settles the banner's text on it rather than leaving the
    /// holding line up for a check that does not exist.
    @discardableResult
    private func handleAlertFired(_ def: AlertDefinition, firingRules: Set<String>) -> Bool {
        // Recorded regardless of scanOnAlert: the timeline's job is to
        // show every *live* alert that fired, not just the ones the
        // auto-scan preference happened to act on. (Scan-only alerts never
        // reach here — see the `!def.scanOnly` guard in `AlertEngine.step`
        // — so the five of those are absent from the timeline by design.)
        //
        // `firingRules.min()`, never `def.rules.first`: the latter
        // reads an arbitrary element of an unordered Set of everything the
        // alert *listens* for, which is why one L2 condition was logged as
        // "rule=L1" and the next identical one as "rule=L2".
        eventLog.record(kind: "alert", summary: def.title,
                        ruleID: firingRules.min(),
                        network: monitor.latest?.network.id)
        guard Defaults.scanOnAlert else { return false }
        // Loop guard, two clauses. A scan started by an alert never starts
        // another, and no scan starts while one is running. Between them
        // there is no path from "alert fires" back to "alert fires".
        guard !scanWasAlertTriggered, !isScanning else {
            log.debug("loop guard: not scanning for \(def.id, privacy: .public)")
            return false
        }
        scanWasAlertTriggered = true
        // .alertTriggered skips bufferbloat and the speed test. Both
        // deliberately saturate the link, and running a load test on a
        // connection that is *already* failing makes the user's situation
        // worse in the middle of whatever broke.
        return runScan(depth: .alertTriggered, reason: "checking \(def.title.lowercased())")
    }

    // MARK: - Power

    /// Display sleep and battery, from NSWorkspace. These events arrive
    /// here for free; asking bash to poll pmset for the same information
    /// would cost a process spawn per cycle, forever. Energy is the main UX
    /// risk of an always-on app, and this is where the awareness belongs.
    private func observeWorkspace() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard Defaults.pauseOnDisplaySleep else { return }
                self?.monitor.pause(reason: "the display is asleep")
                self?.alerts.monitoringPaused = true
            }
        }
        nc.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.monitor.resume(reason: "the display is asleep")
                self?.alerts.monitoringPaused = self?.monitor.isPausedForAnyReason ?? false
            }
        }
        // System sleep pauses regardless of the display-sleep preference:
        // the machine is going away, and a frozen child is what makes the
        // wake instantaneous instead of costing a fresh bash startup.
        nc.addObserver(forName: NSWorkspace.willSleepNotification,
                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.monitor.pause(reason: "your Mac is asleep")
                self?.alerts.monitoringPaused = true
            }
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification,
                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.monitor.resume(reason: "your Mac is asleep")
                self?.alerts.monitoringPaused = self?.monitor.isPausedForAnyReason ?? false
                // The world may be entirely different after a wake, and
                // the monitor's own timers do not know that.
                await self?.history.load()
            }
        }
    }

    // MARK: - Presentation helpers

    /// Refreshes Location Services authorization and unredacts Wi-Fi details
    /// if newly granted.
    func refreshLocationState() {
        locationPermissions.refresh()
        if locationPermissions.isAuthorized {
            refreshLiveWiFi()
            adoptLiveSSIDAsNameIfNeeded()
        }
    }

    /// Refresh `liveSSID` from CoreWLAN. Called once per monitor sample
    /// rather than from a view body: a `CWWiFiClient` read is a real
    /// syscall, and `wifiDisplayName` is read on every redraw of an
    /// always-visible menu. Returns nil when Location is not authorized —
    /// CoreWLAN returns a redacted `<SSID>` / nil in that state, and
    /// passing that through would surface a raw placeholder as a name.
    func refreshLiveWiFi() {
        // CoreWLAN's `interface()` returns the current Wi-Fi interface, but
        // has been observed returning nil on some builds even when
        // associated; fall back to the first power-on interface from
        // `interfaces()` before giving up.
        guard locationPermissions.isAuthorized else {
            if liveSSID != nil { log.debug("wifi: location not authorized — SSID unavailable") }
            liveSSID = nil
            return
        }
        let client = CWWiFiClient.shared()
        let iface = client.interface() ?? client.interfaces()?.first { $0.powerOn() }
        guard let iface else {
            log.debug("wifi: no CoreWLAN interface (on ethernet, or WiFi off)")
            liveSSID = nil
            return
        }
        let name = iface.ssid()
        if let name, !name.isEmpty {
            log.debug("wifi: live SSID read OK")
        } else {
            log.debug("wifi: CoreWLAN interface present but ssid() returned nil — location grant may be provisional or revoked")
        }
        liveSSID = (name?.isEmpty ?? true) ? nil : name
    }

    /// Adopt the live SSID as the current network's display name when no
    /// real name is recorded yet. The CLI records networks in
    /// baseline.jsonl with a MAC-keyed id and a redacted label (TCC
    /// attributes `ipconfig getsummary` to `/usr/sbin/ipconfig`, not this
    /// .app), so without this a network the user has granted Location for
    /// still shows up as "wifi:mac=…" in the Networks tab and in search
    /// forever. The GUI's CoreWLAN `ssid()` *does* see the real name, so
    /// the moment we have it we record it as the network's custom name —
    /// the same store `displayName` and the Networks-tab search already
    /// read. Joins on `historyJoinID` (the `--history` group key), not the
    /// raw sample id: the rename has to land on the same key the Networks
    /// tab renders by, or the name shows on Home and not there — the exact
    /// bug this replace fixed. Never overwrites a name that is not ugly
    /// (a user rename, or a real SSID the CLI captured under sudo), and
    /// writes at most once per network per name change rather than every
    /// sample.
    private func adoptLiveSSIDAsNameIfNeeded() {
        guard let live = liveSSID, !live.isEmpty,
              !live.contains("<redacted>"), !live.contains("hidden by macOS"),
              let id = monitor.latest?.network.historyJoinID else { return }
        // If the user has assigned their own custom name (and it's not a placeholder), don't overwrite it
        if let custom = history.customName(for: id), !custom.isEmpty,
           !custom.contains("<redacted>"), !custom.contains("hidden by macOS"),
           !Self.isRawNetworkKey(custom) {
            return
        }
        let current = history.displayName(for: id)
        guard current != live else { return }
        history.rename(id, to: live)
        log.info("adopted live SSID as name for \(id, privacy: .public)")
    }

    /// True when a "name" is actually a raw network key rather than
    /// anything a person wrote or recognised — `wifi:mac=AA:BB:…` (the
    /// record format), `mac:aa:bb:…` / `gw:…` / `ssid:…` (the history
    /// group format). Both spellings must be caught here: renames can
    /// predate the group-id join, and the group key is what a network with
    /// no name at all falls back to in `displayName`.
    static func isRawNetworkKey(_ s: String) -> Bool {
        s.starts(with: "wifi:mac=") || s.starts(with: "lan:mac=")
            || s.starts(with: "wifi:ssid=") || s.starts(with: "lan:gw=")
            || s.starts(with: "mac:") || s.starts(with: "gw:")
            || s.starts(with: "ssid:")
    }

    /// What `HomeView` has to render: either the run that finished in
    /// this session, or a historical one fetched to fill the screen before
    /// any scan has run this launch. See `reportSource` for how the choice
    /// between the two is made and what it does and doesn't mean.
    enum ReportSource {
        case live(RunResult)
        case stored(RunDetail)
    }

    /// `.live` always wins: `launch()` clears `hydratedReport` the moment a
    /// scan lands, and this checks `latestRun` first regardless, so the two
    /// can never be shown in the wrong order even if that clear were ever
    /// missed.
    ///
    /// Deliberately not read by `currentHealth`, `headline`, or the alert
    /// engine — all three read `latestRun` directly, unaffected by this
    /// property's existence. A hydrated report is a *display* fallback for
    /// a screen that would otherwise be empty; it is not a fresh
    /// measurement, and nothing that judges the network's current state is
    /// allowed to treat it as one.
    ///
    /// Scoped like `currentNetworkRun`: a report about another network is
    /// not offered, so Home shows its "Awaiting check" state rather than the
    /// living room's report in a café.
    var reportSource: ReportSource? {
        let live = monitor.latest?.network.historyJoinID
        if let latestRun, runIsForNetwork(latestRun.snapshot.network.historyJoinID, live: live) {
            return .live(latestRun)
        }
        if let hydratedReport,
           runIsForNetwork(hydratedReport.context.networkID ?? hydratedReport.run.network.historyJoinID, live: live) {
            return .stored(hydratedReport)
        }
        return nil
    }

    private func runIsForNetwork(_ runNetwork: String?, live: String?) -> Bool {
        RunScope.isSameNetwork(run: runNetwork, live: live, canonical: history.canonicalID)
    }

    /// The one place a stored or session run becomes "the report for the
    /// network I am on" — and the only door the display fallback chains
    /// (public IP, country, flag, ISP, gateway, the check table, the
    /// technical panel, findings, the reliability card, the last-scan loss
    /// and RTT) go through.
    ///
    /// Returns the session's scan, else the hydrated report, whichever is
    /// about the network the monitor's newest sample names (`RunScope`), with
    /// its age; `nil` when the only run in hand is provably another
    /// network's. With no live network identified — before the monitor's
    /// first sample, or monitoring off — the run is returned: it cannot be
    /// shown to be wrong, hydration scoped it when it could, and Home
    /// captions a report it cannot confirm (`lastCheckedCaption`).
    ///
    /// Identity comes from `monitor.latest` even when that sample is stale:
    /// a monitor that has gone quiet still last saw *some* network, and
    /// that is the best evidence there is. (The few seconds after resuming
    /// on a different network, before the first fresh sample, are the one
    /// gap — see `liveSample`.)
    var currentNetworkRun: CurrentNetworkRun? {
        let live = monitor.latest?.network.historyJoinID
        if let latestRun, runIsForNetwork(latestRun.snapshot.network.historyJoinID, live: live) {
            return CurrentNetworkRun(result: latestRun, isLive: true)
        }
        if let hydratedReport,
           runIsForNetwork(hydratedReport.context.networkID ?? hydratedReport.run.network.historyJoinID, live: live) {
            return CurrentNetworkRun(result: cachedHydratedRunResult ?? hydratedReport.asRunResult, isLive: false)
        }
        return nil
    }

    /// Whichever report is currently active (live or stored), as a
    /// `RunResult` — only if it is about the network we are on.
    var currentRunResult: RunResult? {
        currentNetworkRun?.result
    }

    /// The scoped run, when it is recent enough to stand in for a live
    /// measurement: a scan that finished within one sample-freshness window.
    /// For loss, RTT and stability — figures that describe the link *now* —
    /// so a report from an hour ago, or from this morning's cold launch,
    /// never answers "how is the connection". `currentNetworkRun` is for
    /// things that describe the network (its ISP, its country, its findings).
    private var freshNetworkRunSnapshot: RunSnapshot? {
        guard let run = currentNetworkRun,
              run.age() <= SampleFreshness.window(cadenceS: monitor.latest?.status.cadenceS)
        else { return nil }
        return run.snapshot
    }

    /// The throughput last measured on the network we are on, with when.
    /// `nil` on another network (or none yet): the in-memory figure is
    /// keyed to the network it was measured on and dropped on a change
    /// (`adoptStoredSpeedTest`), and this re-checks at read time so a view
    /// drawn before the first sample of the new network cannot beat it.
    var currentSpeedTest: (speed: RunSnapshot.Speedtest, at: Date?)? {
        guard let speed = latestSpeedTest else { return nil }
        let live = monitor.latest?.network.historyJoinID
        guard runIsForNetwork(latestSpeedTestNetwork, live: live) else { return nil }
        return (speed, latestSpeedTestAt)
    }

    // MARK: - Sample freshness

    /// Bumped by the watchdog when `latestSampleIsStale` flips, so views
    /// that read it are invalidated by a *lack* of samples — which, being
    /// the absence of an event, nothing else would ever notify.
    private(set) var staleEpoch = 0
    private var staleWatchTask: Task<Void, Never>?
    private var lastObservedStale = false
    /// Gallery fixtures are written once and rendered for as long as the
    /// run takes; they would age past the window mid-render.
    private var stalenessSuspended = false

    /// The monitor is supposed to be reporting and its newest sample is
    /// older than `SampleFreshness` allows. False while monitoring is off or
    /// held by any pause (those have their own states, and a paused monitor
    /// is meant to be quiet), when there is no sample yet (that is "not
    /// measured", not "late"), and for a sample that is itself a paused
    /// one. Does not mask no-link: the resolvers test `linkIsDown` first.
    var latestSampleIsStale: Bool {
        _ = staleEpoch
        return computeSampleIsStale(now: Date())
    }

    func computeSampleIsStale(now: Date) -> Bool {
        guard !stalenessSuspended, let sample = monitor.latest else { return false }
        let reference = max(sample.timestamp, monitor.awaitingSince ?? .distantPast)
        return SampleFreshness.isStale(
            sampleAge: now.timeIntervalSince(reference),
            cadenceS: sample.status.cadenceS,
            observing: Defaults.monitoringEnabled && !monitor.isPausedForAnyReason,
            samplePaused: sample.status.paused)
    }

    /// The newest monitor sample, if it can be believed to describe the
    /// network now: not stale, and not one that predates a stop or a pause
    /// (`MonitorStream.awaitingSince` — after a lid-close in one place and
    /// an open in another, `latest` is from the other place until the first
    /// fresh sample, and it used to read "Live" for those seconds).
    ///
    /// This is the gate for *readings* — router and internet ping, loss,
    /// jitter, public IP, country, flag, ISP. It is deliberately not
    /// `running && !paused`: a pause is held for the whole length of every
    /// full check, and blanking every tile for a minute and a half each time
    /// would trade one misleading display for another; the paused states
    /// already say so out loud. `MonitorStream.stop()` still keeps `latest`
    /// itself, because a "no link" sample must survive a monitor restart.
    var liveSample: MonitorSample? {
        guard let sample = monitor.latest,
              !monitor.isAwaitingFirstSample,
              !latestSampleIsStale else { return nil }
        return sample
    }

    private func startStaleWatch() {
        staleWatchTask?.cancel()
        staleWatchTask = Task { [weak self] in
            // A sample not arriving is not an event anything observes, so
            // something has to look. One main-actor wake every few seconds
            // that writes only when the answer flips — no existing tick
            // (the 4-hourly update check aside) wakes the app in between.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { return }
                let stale = self.computeSampleIsStale(now: Date())
                if stale != self.lastObservedStale {
                    self.lastObservedStale = stale
                    self.staleEpoch += 1
                }
            }
        }
    }

    /// True if any monitor sample in the rolling loss window (~last 10 probes / 100s) recorded a Wi-Fi roam event.
    var hasRecentRoam: Bool {
        if monitor.latest?.changes.contains(where: { $0.kind == "wifi-roamed" }) == true {
            return true
        }
        let windowSamples = monitor.recent.suffix(10)
        return windowSamples.contains { sample in
            sample.changes.contains { $0.kind == "wifi-roamed" }
        }
    }

    /// Unified effective packet loss across internet and gateway probes.
    /// Evaluates whichever is worse so loss on either leg is visible and accounted for.
    ///
    /// A leg the CLI says ping cannot measure (TCP-1 / `icmp_filtered` for the
    /// gateway, ICMP-1 for the internet) is excluded — see `EffectiveLoss`.
    var effectiveLoss: Double? {
        // No link: neither the null probes in the sample nor the last scan's
        // figures say anything about the link now. The `latestRun` fallbacks
        // below are how a router "10% packet loss" survived a disconnect.
        if linkIsDown { return nil }
        // The fallback is a scan of *this* network that finished within the
        // freshness window — not any run in memory. A report from another
        // network, or from this morning, is not a measurement of the link.
        return EffectiveLoss.compute(
            internetLoss: liveSample?.internet.lossPct
                ?? freshNetworkRunSnapshot?.internetLatency.lossPct,
            gatewayLoss: liveSample?.gateway.lossPct
                ?? freshNetworkRunSnapshot?.gateway.lossPct,
            filtering: lossFiltering,
            hasRecentRoam: hasRecentRoam
        )
    }

    /// Which loss legs are unmeasurable by ping, from the live sample and any
    /// run diagnosis in view. Pass this to `SuitabilityEngine` alongside
    /// `effectiveLoss` so "filtered, unknown" is not mistaken for "not yet
    /// measured".
    var lossFiltering: EffectiveLoss.Filtering {
        EffectiveLoss.filtering(
            icmpFilteredFlag: monitor.latest?.status.icmpFiltered == true,
            ruleIDs: (monitor.latest?.status.rules ?? [])
                + (currentNetworkRun?.snapshot.diagnosis.compactMap(\.rule) ?? [])
        )
    }

    /// The newest monitor sample says there is no link, and is recent enough
    /// to believe. The one answer the dot, both stage cards and every tile
    /// read — see `LinkState`.
    var linkIsDown: Bool { LinkState.isDown(sample: monitor.latest) }

    /// Whether the Mac's connection is Wi-Fi, for icons and captions.
    /// With no link the monitor's `link.type` is only the CLI's default
    /// ("wired" when there is no interface to ask), so it is not read; the
    /// question falls through to whether the Wi-Fi radio is on, which is what
    /// a person on Wi-Fi who lost their network would expect it to say.
    var linkIsWiFi: Bool {
        if linkIsDown { return CWWiFiClient.shared().interface()?.powerOn() ?? true }
        return monitor.latest?.link.isWiFi ?? true
    }

    /// Effective instantaneous or moving RFC 3550 jitter.
    ///
    /// Nil with no link. The fallback below averages `monitor.recent`, which
    /// at the moment of a drop is made entirely of samples from before it —
    /// so the dropdown said "Jitter 3 ms · Stable response times" over a
    /// card reading "no network connection".
    var currentJitter: Double? {
        if linkIsDown { return nil }
        // No believable newest sample, no jitter: the averaged fallback
        // below is only meaningful as "the last few seconds of this link".
        guard let live = liveSample else { return nil }
        if let jitter = live.liveJitterMs { return jitter }
        // `movingJitter` keeps only samples from this network, link up, not
        // paused and within a few cadences of the newest — not the hour the
        // buffer holds.
        return MonitorSeries.movingJitter(samples: monitor.recent)
    }

    /// Overall connection stability rating evaluated from current RTT, jitter, and packet loss.
    var currentStability: ConnectionStability {
        if linkIsDown { return .noLink }
        let rtt = liveSample?.internet.rttAvgMs ?? liveSample?.gateway.rttAvgMs
            ?? freshNetworkRunSnapshot?.internetLatency.rttAvgMs ?? freshNetworkRunSnapshot?.gateway.rttAvgMs
        return ConnectionStability.evaluate(rtt: rtt, jitter: currentJitter, loss: effectiveLoss)
    }

    /// The menu-bar dot. Thin wrapper over `HealthResolver.resolve` — see
    /// that file for the precedence and for why a paused app no longer
    /// reports the last reading from before it stopped looking.
    var currentHealth: Health {
        let activeSnapshot = alerts.activeSorted.first.map {
            StageResolver.AlertSnapshot(
                title: $0.title, body: $0.body,
                raisedAt: $0.raisedAt, rules: $0.rules,
                severityRank: $0.rules.compactMap(severityRank(forRuleID:)).max() ?? 0,
                id: $0.id)
        }
        // A run is the dot's answer only when there is no sample at all
        // (a cold launch before the first one). Once the monitor has spoken
        // and `liveSample` is nil, the sample is awaiting a fresh one or is
        // stale, and an older scan must not turn the dot green in its place.
        let currentRunHealth = monitor.latest == nil
            ? currentNetworkRun?.snapshot.worstSeverity : nil

        return HealthResolver.resolve(.init(
            isScanning: isScanning,
            monitoringEnabled: Defaults.monitoringEnabled,
            isPausedForAnyReason: monitor.isPausedForAnyReason,
            monitorRunning: monitor.isRunning,
            activeAlert: activeSnapshot,
            sampleHealth: liveSample?.health,
            runHealth: currentRunHealth,
            linkDown: linkIsDown,
            sampleStale: latestSampleIsStale))
    }

    /// The CLI's severity for one rule ID, ranked so the worst of a set can
    /// be picked out — higher is worse. The single place both
    /// `alerts.severityRank` (ranking *active alerts*, each of which can
    /// back more than one rule) and `headline` (ranking the rule IDs on one
    /// sample) ask this question, so the two never drift into disagreeing
    /// about which of two rules is worse. Degrades to 0 before the catalog
    /// loads, or for a rule the catalog doesn't name, so an unranked rule
    /// sorts as least urgent rather than winning a comparison by default.
    func severityRank(forRuleID ruleID: String) -> Int {
        Self.severityRank(rulesCatalog.catalog?[ruleID]?.severity)
    }

    /// The catalog's severity as a comparable rank, higher being worse.
    /// Static and total: an unknown or absent severity ranks 0 rather than
    /// throwing, so a rule this build has never heard of sorts below every
    /// rule it has.
    static func severityRank(_ severity: String?) -> Int {
        switch severity {
        case "critical": return 3
        case "warn", "warning": return 2
        case "info": return 1
        default: return 0
        }
    }

    /// The worst rule among `ruleIDs`, by the catalog's own severity.
    ///
    /// Pure, static, and separated from `headline` for one reason: the
    /// behaviour it encodes — worst wins, not first — is the fix for a bug
    /// that is invisible on inspection (`lib/monitor.sh` appends rules in
    /// evaluation order, so an info-level VPN-1 can precede a critical L1),
    /// and a computed property on an object that spawns a monitor and reads
    /// history cannot be checked. `--verify` calls this directly.
    ///
    /// Ties keep the earliest rule, which is the CLI's own evaluation
    /// order — arbitrary between equals, but stable, so the same sample
    /// never produces two different headlines.
    static func worstRule(among ruleIDs: [String],
                          catalog: RulesCatalog?) -> RulesCatalog.Rule? {
        guard let catalog else { return nil }
        var best: RulesCatalog.Rule?
        var bestRank = Int.min
        for id in ruleIDs {
            guard let rule = catalog[id] else { continue }
            let rank = severityRank(rule.severity)
            if rank > bestRank {
                best = rule
                bestRank = rank
            }
        }
        return best
    }

    /// What `headline` shows for a firing rule: its blurb, else its title,
    /// else nothing. Static alongside `worstRule` and for the same reason.
    static func headlineText(forRulesIn ruleIDs: [String],
                             catalog: RulesCatalog?) -> String? {
        guard let worst = worstRule(among: ruleIDs, catalog: catalog) else { return nil }
        if let blurb = worst.blurb, !blurb.isEmpty { return blurb }
        if let title = worst.title, !title.isEmpty { return title }
        return nil
    }

    /// The one sentence the dropdown leads with.
    ///
    /// Every branch here either states an observable fact about the app's
    /// own state ("Monitoring is off") or hands back prose the CLI wrote.
    /// The healthy line is the only exception, and it is the CLI's own
    /// wording from lib/diagnosis.sh's `ok()` branch.
    ///
    /// The guard order below is deliberately the same order
    /// `StageResolver.resolve` uses for the dropdown's stage card: scanning,
    /// then monitoring-off, then paused-for-any-reason, then a skewed
    /// monitor, then link-down, then an active alert, then
    /// not-yet-measured, then severity. Before this fix the two orders
    /// disagreed — scanning and "paused" were missing here entirely, and
    /// the active-alert check ran ahead of the skewed-monitor check — so
    /// the header (this property, read by `HomeView`) and the dropdown's
    /// stage card (`StageResolver`, fed the same underlying state) could
    /// describe the same moment two different ways. The concrete case: the
    /// display sleeps, `monitoringEnabled` stays true so this used to fall
    /// through the first guard, and a stale `activeSorted.first` from
    /// before the sleep kept being shown here while the dropdown correctly
    /// said "Monitoring paused — the display is asleep."
    var headline: String {
        if isScanning { return "Running a network check…" }
        if !Defaults.monitoringEnabled { return "Monitoring is off." }
        if monitor.isPausedForAnyReason {
            guard let reason = monitor.pauseReason else { return "Monitoring is paused." }
            return "Monitoring is paused — \(reason)."
        }
        // A monitor that died leaves `monitor.latest` holding whatever it
        // last measured, which can still read "healthy" — checking this
        // before `activeAlert` and the sample-based branches below is what
        // stops a crashed monitor from being reported as a quiet network.
        if let error = monitor.lastError, !monitor.isRunning {
            return "The netdiag command needs attention — \(error)"
        }
        // Ahead of the active alert, like `StageResolver`'s `.noLink`: the
        // subtitle under "No network connection" must be about the missing
        // link, not an older alert's body. The sentence is the CLI's own N1
        // text from the rules catalog; the literal is only the fallback for
        // a catalog that has not loaded.
        if linkIsDown {
            return Self.headlineText(forRulesIn: monitor.latest?.status.rules ?? [],
                                     catalog: rulesCatalog.catalog)
                ?? NoLinkCopy.fallbackSubtitle
        }
        if let alert = alerts.activeSorted.first {
            return alert.body.isEmpty ? alert.title : alert.body
        }
        if !monitor.isRunning {
            return "Reconnecting to the connection monitor…"
        }
        // The process is up and its last line is old: say so, rather than
        // the last thing it said.
        if latestSampleIsStale { return StaleSampleCopy.subtitle }
        // `liveSample == nil` here means the newest sample predates a stop
        // or a pause (the stale case returned above).
        if let sample = monitor.latest, liveSample == nil || sample.status.measurement != "measured" {
            return "Checking your connection — a live internet reading is not available yet."
        }
        if let sample = monitor.latest, sample.status.severity == "critical" || sample.status.severity == "warn" {
            // Worst rule wins, not first rule: `lib/monitor.sh`'s
            // `_mon_rules` appends rules in the order it evaluates them
            // (TCP-1, then the G-loss rules, then P-reach, D1, CP-1, VPN-1,
            // ICMP-1, then the L-loss rules) — not by severity. An
            // informational VPN-1 notice can therefore sit ahead of a
            // critical L1 in `sample.status.rules`. Picking "the first rule
            // with a catalog entry" used to mean a VPN user losing most of
            // their packets got a red "Detecting a network problem" card
            // whose body read "A VPN is carrying your traffic right now."
            if let text = Self.headlineText(forRulesIn: sample.status.rules,
                                            catalog: rulesCatalog.catalog) {
                return text
            }
        }
        if let res = activeResolution {
            return res.message.isEmpty ? res.title : "\(res.title) — \(res.message)"
        }
        if let sample = liveSample {
            let snap = currentNetworkRun?.snapshot
            let items = SuitabilityEngine.evaluateAll(.init(
                monitorSample: sample,
                speedTest: snap?.speedtest ?? currentSpeedTest?.speed,
                savedSuitability: snap?.suitability,
                catalog: rulesCatalog.catalog,
                firedRules: sample.status.rules,
                isLinkUp: sample.link.up,
                isDoubleNat: snap?.wan.doubleNat.detected ?? false,
                mtu: snap?.mtu.effective ?? snap?.mtu.pathSize ?? 1500,
                vpnActive: sample.vpn.active,
                vpnName: sample.vpn.name,
                currentJitter: currentJitter,
                effectiveLoss: effectiveLoss,
                lossFiltering: lossFiltering
            ))
            if let degraded = SuitabilityEngine.synthesizeDegradedExperience(
                items: items,
                monitorSample: sample,
                currentJitter: currentJitter,
                effectiveLoss: effectiveLoss,
                lossFiltering: lossFiltering
            ) {
                return "\(degraded.headline) — \(degraded.subtitle)"
            }
        }
        let currentSnapshot = currentNetworkRun?.snapshot
        if let cause = currentSnapshot?.mostLikelyRootCause, !cause.isEmpty {
            let isLocationNotice = cause.localizedCaseInsensitiveContains("location services")
                || cause.localizedCaseInsensitiveContains("generic name")
                || cause.localizedCaseInsensitiveContains("not telling netdiag")
            if !isLocationNotice {
                return cause
            }
        }
        if monitor.latest == nil && currentNetworkRun == nil { return "Starting up…" }
        return "Nothing obviously wrong — your network looks healthy."
    }

    /// A displayable network name, or `nil` when there isn't a clean one —
    /// never the raw `network.id`/`network.label` a redacted or
    /// not-yet-permitted record can carry (`"wifi:mac=…"`,
    /// `"<redacted>"`, `"hidden by macOS"`). Shared by `DropdownView`'s
    /// quiet-line caption and `HomeView`'s Wi-Fi row — one place, so the
    /// two can't describe the same network two different ways.
    ///
    /// Without Location Services, macOS never hands this app a real SSID,
    /// so the only name worth showing is one the user typed themselves in
    /// `HistoryStore.displayName` — a raw `network.id` in that state is a
    /// MAC-keyed string nobody recognizes, not a name.
    var wifiDisplayName: String? {
        // A user-assigned rename wins over everything — it is the name the
        // user themselves typed, so it is the name they expect to see.
        // Looked up by the history group key so a rename made anywhere
        // (the Networks tab, the adopt-as-name path) is found from here
        // too.
        if let id = monitor.latest?.network.historyJoinID {
            if let custom = history.customName(for: id), !custom.isEmpty,
               !custom.contains("<redacted>"), !custom.contains("hidden by macOS"),
               !Self.isRawNetworkKey(custom) {
                return custom
            }
        }
        // CoreWLAN's live SSID, available only with Location Services. The
        // CLI's own SSID reading is redacted by TCC even when the app is
        // granted (see `liveSSID`'s header), so this is the primary source
        // for the current network's real name — not a fallback.
        if let live = liveSSID, !live.isEmpty,
           !live.contains("<redacted>"), !live.contains("hidden by macOS") {
            return live
        }
        // Without live SSID or custom rename, check if HistoryStore has a
        // recorded SSID from a past scan.
        if let id = monitor.latest?.network.historyJoinID {
            let hist = history.displayName(for: id)
            if !hist.isEmpty, hist != id, !hist.contains("<redacted>"),
               !hist.contains("hidden by macOS"), !Self.isRawNetworkKey(hist) {
                return hist
            }
        }
        // Without Location and without a rename, the CLI's raw label is a
        // MAC-keyed string nobody recognises; hide it rather than show
        // furniture that reads as a bug.
        let raw = monitor.latest?.network.label ?? currentNetworkRun?.snapshot.network.label
        guard let raw, !raw.isEmpty else { return nil }
        if raw.contains("<redacted>") || raw.contains("hidden by macOS")
            || Self.isRawNetworkKey(raw) {
            return nil
        }
        return raw
    }

    // MARK: - Sharing

    /// Raw JSON for the active report (either the live run or the hydrated stored report).
    var currentReportRawJSON: String? {
        currentNetworkRun?.result.rawJSON
    }

    /// Shares the current report (or newest stored run) as redacted plain text.
    func shareCurrentReportText() async throws -> String {
        try await NetdiagRunner.share(rawJSON: currentReportRawJSON)
    }

    /// Shares the current report (or newest stored run) as redacted JSON.
    func shareCurrentReportJSON() async throws -> String {
        try await NetdiagRunner.shareJSON(rawJSON: currentReportRawJSON)
    }
}

typealias NetdiagCoordinator = HopwatchCoordinator
