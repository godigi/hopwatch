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

    private var updateCheckTask: Task<Void, Never>?
    private(set) var latestRun: RunResult?
    /// Home's fallback for a session that has not run a scan yet.
    /// See `reportSource` for why this is a separate property rather than
    /// a second way to set `latestRun`, and `hydrateFromHistoryIfNeeded`
    /// for how it gets populated.
    private(set) var hydratedReport: RunDetail?
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
    private(set) var scanStartedAt: Date?
    private(set) var lastRunError: String?
    /// The last `--speed-only` result, kept apart from `latestRun`. A speed
    /// test measures one thing and diagnoses nothing, so letting it become
    /// the current report would replace a full diagnosis with a card that
    /// has no verdict on it — Part B of the spec, in the app's own terms.
    private(set) var latestSpeedTest: RunSnapshot.Speedtest?
    private(set) var latestSpeedTestAt: Date?
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
            self?.handleAlertFired(def, firingRules: firingRules)
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
        if Defaults.monitoringEnabled { monitor.start() }

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
        if latestRun == nil, hydratedReport == nil {
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
            if let st = hydratedReport?.run.speedtest, st.downMbps != nil {
                latestSpeedTest = st
                latestSpeedTestAt = hydratedReport?.run.timestamp.flatMap { HistoryDocument.iso.date(from: $0) }
            } else if let speed = history.latestSpeedTest() {
                latestSpeedTest = RunSnapshot.Speedtest(downMbps: speed.down, upMbps: speed.up)
                latestSpeedTestAt = speed.date
            }
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
        // silently spanning the restart with a "+".
        if sample.seq == 1 {
            eventLog.record(
                kind: "monitor-started",
                summary: "Monitoring started",
                network: sample.network.id,
                date: sample.timestamp)
        }

        for change in sample.changes {
            eventLog.record(
                kind: change.kind,
                summary: change.summary,
                ruleID: change.field == "status.rules"
                    ? (change.to ?? change.from) : nil,
                network: sample.network.id,
                date: sample.timestamp)
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
        if case .pathChanged(let satisfied, _) = event, !satisfied { return }
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

    /// Returns `true` once the scan has actually been handed to a `Task` —
    /// `false` when the guard below declined it. That distinction is the
    /// whole point of the return value: a caller that only finds out a scan
    /// *would* run by checking `isScanning` beforehand has a race between
    /// the check and this call, where the return value has none, since both
    /// happen on the same synchronous call.
    @discardableResult
    private func launch(depth: NetdiagRunner.Depth, reason: String,
                        target: String?, adoptAsReport: Bool) -> Bool {
        guard !isScanning else {
            log.debug("scan already running, ignoring request: \(reason, privacy: .public)")
            return false
        }
        isScanning = true
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
                self.scanStartedAt = nil
                self.scanWasAlertTriggered = false
                self.alerts.scanInProgress = false
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

    // MARK: - Latency test

    func stopLatencyTest() { monitor.endBurst() }

    func consumeRequestedDestination() -> MainDestination? {
        defer { requestedDestination = nil }
        return requestedDestination
    }

    /// An alert fired. Run a scan so the notification can be replaced with
    /// the CLI's own explanation — that in-place update is the entire point
    /// of the trigger.
    private func handleAlertFired(_ def: AlertDefinition, firingRules: Set<String>) {
        // Recorded regardless of scanOnAlert: the timeline's job is to
        // show every *live* alert that fired, not just the ones the
        // auto-scan preference happened to act on. (Scan-only alerts never
        // reach here — see the `!def.scanOnly` guard in `AlertEngine.step`
        // — so the five of those are absent from the timeline by design.)
        //
        // `firingRules.sorted().first`, never `def.rules.first`: the latter
        // reads an arbitrary element of an unordered Set of everything the
        // alert *listens* for, which is why one L2 condition was logged as
        // "rule=L1" and the next identical one as "rule=L2".
        eventLog.record(kind: "alert", summary: def.title,
                        ruleID: firingRules.sorted().first,
                        network: monitor.latest?.network.id)
        guard Defaults.scanOnAlert else { return }
        // Loop guard, two clauses. A scan started by an alert never starts
        // another, and no scan starts while one is running. Between them
        // there is no path from "alert fires" back to "alert fires".
        guard !scanWasAlertTriggered, !isScanning else {
            log.debug("loop guard: not scanning for \(def.id, privacy: .public)")
            return
        }
        scanWasAlertTriggered = true
        // .alertTriggered skips bufferbloat and the speed test. Both
        // deliberately saturate the link, and running a load test on a
        // connection that is *already* failing makes the user's situation
        // worse in the middle of whatever broke.
        runScan(depth: .alertTriggered, reason: "checking \(def.title.lowercased())")
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

    /// Refresh `liveSSID` from CoreWLAN. Called once per monitor sample
    /// rather than from a view body: a `CWWiFiClient` read is a real
    /// syscall, and `wifiDisplayName` is read on every redraw of an
    /// always-visible menu. Returns nil when Location is not authorized —
    /// CoreWLAN returns a redacted `<SSID>` / nil in that state, and
    /// passing that through would surface a raw placeholder as a name.
    private func refreshLiveWiFi() {
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
        let current = history.displayName(for: id)
        let currentIsUgly = current.isEmpty || current == id
            || current.contains("<redacted>") || current.contains("hidden by macOS")
            || Self.isRawNetworkKey(current)
        guard currentIsUgly, current != live else { return }
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
    var reportSource: ReportSource? {
        if let latestRun { return .live(latestRun) }
        if let hydratedReport { return .stored(hydratedReport) }
        return nil
    }

    /// Whichever report is currently active (live or stored), as a `RunResult`.
    var currentRunResult: RunResult? {
        switch reportSource {
        case .live(let run):        return run
        case .stored(let detail):   return detail.asRunResult
        case nil:                   return nil
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
    var effectiveLoss: Double? {
        let isIcmpFiltered = (monitor.latest?.status.icmpFiltered == true)
            || (latestRun?.snapshot.diagnosis.contains(where: { $0.rule == "TCP-1" || $0.rule == "ICMP-1" }) == true)
            || (currentRunResult?.snapshot.diagnosis.contains(where: { $0.rule == "TCP-1" || $0.rule == "ICMP-1" }) == true)

        let inetLoss: Double? = isIcmpFiltered ? nil : (monitor.latest?.internet.lossPct
            ?? latestRun?.snapshot.internetLatency.lossPct
            ?? currentRunResult?.snapshot.internetLatency.lossPct)

        let gwLoss = monitor.latest?.gateway.lossPct
            ?? latestRun?.snapshot.gateway.lossPct
            ?? currentRunResult?.snapshot.gateway.lossPct

        var candidateGW = gwLoss
        if hasRecentRoam, let gw = candidateGW, gw < 10.0 {
            // Handover blip: suppress attributing to persistent connection loss if internet is intact
            candidateGW = inetLoss ?? 0.0
        }

        if let inetLoss, let candidateGW {
            return max(inetLoss, candidateGW)
        }
        return inetLoss ?? candidateGW
    }

    /// Effective instantaneous or moving RFC 3550 jitter.
    var currentJitter: Double? {
        if let live = monitor.latest?.liveJitterMs {
            return live
        }
        return MonitorSeries.movingJitter(samples: monitor.recent)
    }

    /// Overall connection stability rating evaluated from current RTT, jitter, and packet loss.
    var currentStability: ConnectionStability {
        let rtt = monitor.latest?.internet.rttAvgMs ?? monitor.latest?.gateway.rttAvgMs
            ?? latestRun?.snapshot.internetLatency.rttAvgMs ?? latestRun?.snapshot.gateway.rttAvgMs
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
        let currentRunHealth = latestRun?.snapshot.worstSeverity
            ?? currentRunResult?.snapshot.worstSeverity

        return HealthResolver.resolve(.init(
            isScanning: isScanning,
            monitoringEnabled: Defaults.monitoringEnabled,
            isPausedForAnyReason: monitor.isPausedForAnyReason,
            monitorRunning: monitor.isRunning,
            activeAlert: activeSnapshot,
            sampleHealth: monitor.latest?.health,
            runHealth: currentRunHealth))
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
    /// monitor, then an active alert, then link-down, then
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
        if let alert = alerts.activeSorted.first {
            return alert.body.isEmpty ? alert.title : alert.body
        }
        if let sample = monitor.latest, !sample.link.up {
            return "Your Mac has no network connection at all."
        }
        if !monitor.isRunning {
            return "Reconnecting to the connection monitor…"
        }
        if let sample = monitor.latest, sample.status.measurement != "measured" {
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
        let currentSnapshot = latestRun?.snapshot ?? currentRunResult?.snapshot
        if let cause = currentSnapshot?.mostLikelyRootCause, !cause.isEmpty {
            return cause
        }
        if monitor.latest == nil && latestRun == nil && hydratedReport == nil { return "Starting up…" }
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
            let custom = history.displayName(for: id)
            if !custom.isEmpty, custom != id, !custom.contains("<redacted>"),
               !custom.contains("hidden by macOS"), !Self.isRawNetworkKey(custom) {
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
        // Without Location and without a rename, the CLI's raw label is a
        // MAC-keyed string nobody recognises; hide it rather than show
        // furniture that reads as a bug.
        let raw = monitor.latest?.network.label ?? latestRun?.snapshot.network.label
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
        latestRun?.rawJSON ?? hydratedReport?.rawJSON
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

