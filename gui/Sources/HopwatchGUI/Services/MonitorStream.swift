import Foundation
import os

/// Owns the long-lived `netdiag --monitor` child: spawns it, reads stdout
/// line by line into an `AsyncStream`, restarts it with backoff if it dies,
/// and pauses it with SIGUSR1/SIGUSR2.
///
/// ── Why pause rather than kill ─────────────────────────────────────────
/// A pause suspends probing without losing the process, so it costs nothing
/// and a resume loses nothing. Killing and respawning would pay ~1 s of
/// bash startup plus a full probe cycle each time, and the three things
/// that pause the monitor — display sleep, low battery, and a scan in
/// progress — all happen often enough for that to matter.
///
/// ── Why not SIGSTOP ────────────────────────────────────────────────────
/// SIGSTOP was the obvious mechanism and it is actively unsafe here. POSIX
/// sends SIGHUP followed by SIGCONT to a process group that becomes newly
/// orphaned while any member is stopped. A stopped monitor still has live
/// children — the two-second gateway ping, with_timeout's killer subshells
/// — and the moment one exits, the group orphans and the SIGHUP kills it.
///
/// Measured, not theorised: under this app as parent the monitor died
/// 2.1 s into every pause, exactly one ping probe's length, and the app
/// dutifully restarted it *during the scan the pause existed to protect*.
/// It never reproduced from a terminal, because a controlling terminal
/// keeps the group non-orphaned — which is exactly how it would have
/// shipped. lib/monitor.sh now traps SIGUSR1/SIGUSR2 and suspends its own
/// probing instead.
///
/// ── Why a scan pauses it ───────────────────────────────────────────────
/// This is not politeness. A full scan runs a speed test that deliberately
/// saturates the link and a bufferbloat probe that does the same; samples
/// taken during either would show invented latency and loss, flip the
/// monitor into its 5-second "degraded" cadence, and could fire a WiFi
/// alert *caused by the app's own traffic*. The scan's own loss probe needs
/// a quiet link too — the same constraint that forbids parallelising it
/// with bufferbloat inside the CLI.
@MainActor
@Observable
final class MonitorStream {

    private(set) var latest: MonitorSample?
    private(set) var isRunning = false
    private(set) var isPaused = false
    /// Why it is paused, for the dropdown's status line. The user should
    /// never see a stopped indicator with no explanation.
    private(set) var pauseReason: String?
    private(set) var lastError: String?
    /// Rolling window for the expert layer's sparklines. Bounded because
    /// this process runs for days: at the 10 s cadence 360 samples is an
    /// hour, which is as far back as a live sparkline is worth reading.
    private(set) var recent: [MonitorSample] = []
    /// When the on-demand latency test's faster cadence expires, or nil
    /// when there isn't one. Public so the Live section can say out loud
    /// that what it is drawing is temporary.
    private(set) var burstUntil: Date?
    /// Set when `latest` stopped being the newest word on the network and a
    /// fresh sample has not yet replaced it: the monitor was switched off
    /// (`stop()`) or came back from a pause (`resume()`), and `latest` still
    /// holds whatever it measured before — possibly on another network, as
    /// the Mac was carried somewhere else meanwhile. Cleared by the first
    /// real (non-paused) sample.
    ///
    /// Not cleared by `restart()`, which is the app replacing its own child
    /// for a cadence change or an investigation burst: that child is probing
    /// the same link, and blanking every reading each time severity turned
    /// bad would hide exactly the numbers the burst exists to show.
    ///
    /// This is why `latest` itself is *not* cleared on stop/start: stopping
    /// a monitor whose last sample says "no link" must keep that fact (the
    /// dot stays red between a crash and its replacement), and `restart()`
    /// is stop-then-start. Readers that draw measurements read
    /// `HopwatchCoordinator.liveSample`, which honours this flag.
    private(set) var awaitingSince: Date?
    var isAwaitingFirstSample: Bool { awaitingSince != nil }

    /// A connection boundary invalidates both readings and identity. Retained
    /// samples are history, never evidence about the newly connected path.
    func invalidateConnection(preserving sample: MonitorSample? = nil) {
        latest = sample
        recent = sample.map { [$0] } ?? []
        awaitingSince = sample == nil ? Date() : nil
    }

    private var process: Process?
    private var readTask: Task<Void, Never>?
    /// The capability-gate half of `start()`, tracked so `stop()` can
    /// cancel it. Without this a `stop()` that lands while the handshake
    /// is still in flight would do nothing to it, and the gate would go
    /// on to spawn a monitor the user just asked to turn off the moment
    /// the check finally resolved.
    private var startTask: Task<Void, Never>?
    /// Bumped by every `start()`. Lets the task tail and the post-await
    /// guards tell "I am still the current start" from "a newer start or
    /// a stop superseded me" — a cancelled elder task resuming late must
    /// not clear a newer task's handle or spawn over its process.
    private var startGeneration = 0
    private var restartAttempts = 0
    private var pauseHolders: Set<String> = []
    /// True once the current child has produced a sample — the only
    /// evidence its USR1/USR2 traps are installed. See `spawn()`.
    private var trapsReady = false
    /// A pause requested before `trapsReady` — recorded, and replayed by
    /// `ingest()` on the first sample.
    private var pauseSignalPending = false
    /// A `forceRefresh()` requested before `trapsReady`, replayed by
    /// `ingest()` on the first sample. The same no-signal-before-evidence
    /// rule as the pause: SIGALRM's default disposition *terminates* the
    /// child, and `lib/monitor.sh` only traps it inside `monitor_run`.
    private var refreshSignalPending = false
    /// Test seam (`--verify`): spawn this executable directly instead of the
    /// resolved CLI, skipping the capability handshake and the journal
    /// directory. Nil in the app.
    private var binaryOverrideForTesting: String?
    private var burstInterval: Int?
    private var burstTimer: Task<Void, Never>?
    /// Set by `restart()` and consumed by the next `spawn()`: the child about
    /// to start replaces one this app stopped itself, a moment ago, on
    /// purpose. Cleared by `stop()` and by every path that gives up on
    /// spawning, so a later start the user or a crash recovery makes cannot
    /// inherit it.
    private var restartPending = false
    /// Whether the current child replaced one this app restarted itself
    /// (a cadence change, the start or end of an investigation burst) rather
    /// than being the first, a user's switch-off and on, or a crash
    /// recovery. Read for the child's first sample, to say whether its
    /// `monitor-started` is evidence of anything: see
    /// `NetworkEvent.continuesPrevious`.
    private(set) var childContinuesPrevious = false

    private let log = Logger(subsystem: "com.godigi.hopwatch", category: "monitor")
    private let decoder = JSONDecoder()
    private static let recentCapacity = 360

    /// Called for every decoded sample. The alert engine subscribes here.
    var onSample: ((MonitorSample) -> Void)?

    // MARK: - Lifecycle

    func start() {
        guard !isRunning, startTask == nil else { return }
        if let override = binaryOverrideForTesting {
            spawn(binary: override)
            return
        }
        // Fail-fast only — the path spawned later is re-resolved after
        // the gate, not this one. See startAfterCapabilityCheck.
        guard BinaryLocator.resolve() != nil else {
            restartPending = false
            lastError = BinaryLocator.missingBinaryMessage
            return
        }
        // Gated behind the capabilities handshake, not spawned straight
        // away: an old CLI's `--monitor` exits 3 on flags it has never
        // seen — the cadence flags below among them — the same failure
        // mode `--progress` already guards against in `NetdiagRunner`.
        // Checking first means `lastError` reads the actionable
        // `cliTooOld` message instead of the generic "died immediately"
        // a doomed child would otherwise produce.
        startGeneration += 1
        let generation = startGeneration
        startTask = Task { [weak self] in
            await self?.startAfterCapabilityCheck(generation: generation)
            // Clear only our own handle. A cancelled elder task resuming
            // here must not null a newer start's handle — a later stop()
            // would then find nothing to cancel, and the newer task would
            // go on to spawn a monitor the user had already turned off.
            if let self, self.startGeneration == generation { self.startTask = nil }
        }
    }

    /// The async half of `start()`. Re-checks cancellation, `isRunning`
    /// and its own generation after the one `await`, because `stop()`
    /// cancels `startTask` but has no way to interrupt an in-flight actor
    /// call directly — and a superseded elder task resuming late must not
    /// spawn over a newer start's process.
    private func startAfterCapabilityCheck(generation: Int) async {
        guard !isRunning else { return }
        do {
            try await CapabilityStore.shared.requireSupport(for: .monitor)
        } catch {
            guard !Task.isCancelled, startGeneration == generation else { return }
            restartPending = false
            lastError = error.localizedDescription
            log.error("monitor not started: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard !Task.isCancelled, !isRunning, startGeneration == generation else { return }
        // Resolve again now that the gate has passed. The gate re-resolves
        // internally, so spawning a path captured before the await would
        // let an override changed mid-handshake validate one binary and
        // launch another.
        guard let binary = BinaryLocator.resolve() else {
            restartPending = false
            lastError = BinaryLocator.missingBinaryMessage
            return
        }
        spawn(binary: binary)
    }

    /// The process itself, split out of `start()` so the capability check
    /// above can sit ahead of it without duplicating any of this.
    private func spawn(binary: String) {
        // Consumed here even if `run()` below throws: a retry after a failed
        // launch is a recovery, not the app's own quick restart.
        childContinuesPrevious = restartPending
        restartPending = false
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        // A burst overrides the degraded tier as well as the fast one.
        // Leaving degraded at its own setting would make a struggling link
        // sample *slower* during a latency test than a healthy one — the
        // opposite of what the user asked for by starting the test.
        let fast = burstInterval ?? Defaults.fastInterval
        let degraded = burstInterval ?? Defaults.degradedInterval
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let hopwatchDir = home.appendingPathComponent("hopwatch")
        let netdiagDir = home.appendingPathComponent("net-diag")
        let journalDir: URL
        if FileManager.default.fileExists(atPath: hopwatchDir.path) {
            journalDir = hopwatchDir
        } else if FileManager.default.fileExists(atPath: netdiagDir.path) {
            journalDir = netdiagDir
        } else {
            journalDir = hopwatchDir
        }
        if binaryOverrideForTesting == nil {
            try? FileManager.default.createDirectory(at: journalDir, withIntermediateDirectories: true)
        }
        let journalPath = journalDir.appendingPathComponent("events.jsonl").path
        proc.arguments = [
            "--monitor",
            "--journal",                   journalPath,
            "--monitor-fast-interval",     String(fast),
            "--monitor-degraded-interval", String(degraded),
            "--monitor-medium-interval",   String(Defaults.mediumInterval),
            "--monitor-slow-interval",     String(Defaults.slowInterval),
        ]
        proc.environment = binaryOverrideForTesting == nil
            ? BinaryLocator.environment() : ProcessInfo.processInfo.environment

        let pipe = Pipe()
        proc.standardOutput = pipe
        // stderr goes nowhere: the monitor writes progress and warnings
        // there, and an unread pipe that fills would block the child
        // forever. /dev/null is the only safe choice for a process meant to
        // run for days.
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            lastError = "Couldn't start monitoring: \(error.localizedDescription)"
            scheduleRestart()
            return
        }

        process = proc
        isRunning = true
        lastError = nil
        // No signal may reach this child until it proves its USR1/USR2
        // traps are installed. lib/monitor.sh installs them inside
        // monitor_run — after the re-exec into bash 5 and all of lib/ has
        // been sourced — and before that, SIGUSR1's default disposition
        // *terminates* the child (measured: a signal sent immediately
        // after launch killed it three runs in three, and the resulting
        // EOF→restart→signal cycle looped for as long as the holder was
        // held). So a pause that predates this spawn — restart()
        // replaying its holders, a scan starting mid-handshake — is only
        // recorded here; ingest() replays it on the first sample, which
        // is the evidence the traps exist.
        trapsReady = false
        pauseSignalPending = !pauseHolders.isEmpty
        refreshSignalPending = false
        isPaused = false
        log.info("monitor started, pid \(proc.processIdentifier)")

        readTask = Task { [weak self] in
            await self?.consume(pipe: pipe, process: proc)
        }
    }

    func stop() {
        startTask?.cancel()
        startTask = nil
        readTask?.cancel()
        readTask = nil
        if let process, process.isRunning {
            // Resume first: a paused monitor handles SIGTERM promptly
            // either way, but leaving it paused-then-terminated makes the
            // shutdown path depend on trap ordering for no benefit.
            kill(process.processIdentifier, SIGUSR2)
            process.terminate()
            // `terminate()` only sends SIGTERM; without a wait the exited
            // child remains unreaped, and a quick restart can briefly leave
            // two monitors probing the same link. Reap off the main actor so
            // an in-flight ping cannot freeze the menu bar while it exits.
            Task.detached(priority: .utility) {
                process.waitUntilExit()
            }
        }
        process = nil
        isRunning = false
        isPaused = false
        awaitingSince = Date()
        restartPending = false
        pauseHolders.removeAll()
        pauseReason = nil
        trapsReady = false
        pauseSignalPending = false
        refreshSignalPending = false
        // Stopping is the end of the test too. A burst cadence that
        // survived into the next `start()` would be a faster sample rate
        // the user never asked for, with nothing on screen to explain it.
        burstTimer?.cancel()
        burstTimer = nil
        burstInterval = nil
        burstUntil = nil
    }

    /// Same child, new arguments. Both the pause holders and any burst
    /// window are carried across, because `stop()` clears state that the
    /// *reasons* for it outlive: a cadence change applied mid-scan would
    /// otherwise hand back a running monitor probing the link that scan is
    /// measuring, and cancel a latency test the user is watching.
    func restart() {
        let holders = pauseHolders
        let interval = burstInterval
        let until = burstUntil
        let wasRunning = isRunning
        let wasAwaiting = awaitingSince
        stop()
        awaitingSince = wasAwaiting
        burstInterval = interval
        burstUntil = until
        restartAttempts = 0
        // After `stop()`, which clears it. Only a monitor that was actually
        // running is being replaced; restarting one that was not is a start.
        restartPending = wasRunning
        start()
        for reason in holders { pause(reason: reason) }
    }

    // MARK: - Burst cadence
    //
    // The dropdown's "Latency test" is this and nothing else. It does not
    // shell out: a second `netdiag --monitor` would contend with this one
    // for the very link it was started to measure, and the two would report
    // each other's traffic as latency.

    var isBursting: Bool { burstUntil != nil }

    /// Sample the fast tier faster, for a bounded window.
    ///
    /// A restart rather than a signal, because the intervals are
    /// command-line arguments — the same path `applyCadenceSettings` uses.
    func beginBurst(interval: Int, duration: TimeInterval) {
        guard isRunning else { return }
        burstInterval = interval
        burstUntil = Date().addingTimeInterval(duration)
        restart()

        burstTimer?.cancel()
        burstTimer = Task { [weak self] in
            // `Task.sleep` measures on the continuous clock, which keeps
            // counting while the Mac is asleep — so a machine that sleeps
            // mid-test wakes with the deadline already past and restores
            // immediately, rather than owing the user the remainder.
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.endBurst()
        }
    }

    /// Restore the configured cadence. Idempotent, and reachable from four
    /// directions — the timer, a user pressing stop, the next sample's
    /// deadline check, and monitoring being switched off — because a fast
    /// cadence that outlives its window is a battery cost the user never
    /// agreed to and would have no way to find.
    func endBurst() {
        guard burstUntil != nil else { return }
        burstUntil = nil
        burstInterval = nil
        burstTimer?.cancel()
        burstTimer = nil
        guard isRunning else { return }
        restart()
    }

    // MARK: - Pause / resume
    //
    // Reference-counted by reason, because the holders overlap: a scan
    // started from the dropdown while the display sleeps would otherwise
    // have whichever finished first resume the monitor while the other was
    // still relying on it being paused.

    func pause(reason: String) {
        pauseHolders.insert(reason)
        pauseReason = pauseHolders.sorted().joined(separator: ", ")
        guard trapsReady else {
            // Pre-trap window, or no child at all: record the intent and
            // let ingest()'s first-sample replay deliver it — the same
            // no-signal-before-evidence rule spawn() documents.
            pauseSignalPending = true
            return
        }
        guard let process, process.isRunning, !isPaused else { return }
        kill(process.processIdentifier, SIGUSR1)
        isPaused = true
        log.debug("monitor paused: \(reason, privacy: .public)")
    }

    func resume(reason: String) {
        pauseHolders.remove(reason)
        guard pauseHolders.isEmpty else {
            pauseReason = pauseHolders.sorted().joined(separator: ", ")
            return
        }
        pauseReason = nil
        // Whatever `latest` holds was measured before the pause, and the
        // Mac may have moved since (a lid closed in one place and opened
        // in another). Do not let it pass as live until a sample proves it.
        // A scan can hold this reason when monitoring is switched off. In
        // that case there is no child sample to await, and a scan that just
        // finished is itself the freshest available identity evidence.
        if process?.isRunning == true, awaitingSince == nil { awaitingSince = Date() }
        guard trapsReady else {
            // Every holder released before the child proved its traps:
            // nothing was ever signaled, so there is nothing to undo.
            pauseSignalPending = false
            return
        }
        guard let process, process.isRunning, isPaused else { return }
        kill(process.processIdentifier, SIGUSR2)
        isPaused = false
        log.debug("monitor resumed")
    }

    var isPausedForAnyReason: Bool { !pauseHolders.isEmpty }

    /// Sends `SIGALRM` to force an immediate cycle refresh without waiting for timers.
    ///
    /// Held back until the child has produced a sample, like the pause
    /// signals, and for the same reason: before `monitor_run` installs its
    /// traps SIGALRM kills the child. Measured: a SIGALRM sent 0–30 ms after
    /// spawn exits the monitor with status 142. Network events arrive in
    /// bursts exactly when a link drops — CoreWLAN's SSID, BSSID and link
    /// callbacks within milliseconds of each other — and the drop is also
    /// what makes `considerInvestigationBurst` restart the child, so this
    /// is the moment a refresh is most likely to land on a child that has
    /// not finished starting. The child's death leaves `isRunning` false
    /// until the restart backoff elapses, which is what the dot and the
    /// card header ("Monitoring off") read as a dead monitor.
    func forceRefresh() {
        guard let process, process.isRunning, !isPaused else { return }
        guard trapsReady else {
            refreshSignalPending = true
            return
        }
        kill(process.processIdentifier, SIGALRM)
        log.debug("monitor refresh signaled (SIGALRM)")
    }

    // MARK: - Reading

    /// Reads the pipe on a detached task and hands whole lines back to the
    /// main actor. `bytes.lines` handles the framing; the monitor flushes
    /// after every sample so a line arrives as soon as it is written rather
    /// than when a 4 KB buffer fills.
    private func consume(pipe: Pipe, process proc: Process) async {
        let handle = pipe.fileHandleForReading
        do {
            for try await line in handle.bytes.lines {
                if Task.isCancelled || process !== proc { return }
                guard let data = line.data(using: .utf8) else { continue }
                guard let sample = try? decoder.decode(MonitorSample.self, from: data) else {
                    // One malformed line must not end the session. Log and
                    // keep reading: the next sample is 10 seconds away and
                    // is probably fine.
                    log.error("undecodable monitor line: \(line.prefix(200), privacy: .public)")
                    continue
                }
                ingest(sample)
            }
        } catch {
            log.error("monitor read failed: \(error.localizedDescription, privacy: .public)")
        }
        // Falling out of the loop means EOF: the child exited.
        if !Task.isCancelled {
            isRunning = false
            log.info("monitor exited status=\(proc.terminationStatus) reason=\(proc.terminationReason == .uncaughtSignal ? "signal" : "exit", privacy: .public)")
            scheduleRestart()
        }
    }

    private func ingest(_ sample: MonitorSample) {
        if !trapsReady {
            // First sample from this child: monitor_run is live, so its
            // traps are installed and a deferred pause can now be signaled
            // without landing in the pre-trap window spawn() describes.
            trapsReady = true
            if pauseSignalPending, let process, process.isRunning {
                kill(process.processIdentifier, SIGUSR1)
                isPaused = true
                log.debug("monitor paused (deferred until first sample)")
            }
            pauseSignalPending = false
            if refreshSignalPending, !isPaused, let process, process.isRunning {
                kill(process.processIdentifier, SIGALRM)
                log.debug("monitor refresh signaled (deferred until first sample)")
            }
            refreshSignalPending = false
        }
        // A sample proves the process is alive and producing, which is the
        // only evidence that matters for backoff.
        restartAttempts = 0
        // A paused sample carries values from before the pause; it is the
        // monitor saying it is not looking, not a reading.
        if let awaitingSince, sample.timestamp < awaitingSince { return }
        if !sample.status.paused { awaitingSince = nil }
        // Backstop for the burst deadline. The timer is the normal path;
        // this catches the case where it was lost with a cancelled task
        // tree, which would otherwise leave the machine sampling every two
        // seconds indefinitely.
        if let until = burstUntil, Date() >= until { endBurst() }
        latest = sample
        recent.append(sample)
        if recent.count > Self.recentCapacity {
            recent.removeFirst(recent.count - Self.recentCapacity)
        }
        onSample?(sample)
    }

    /// Exponential backoff, capped. An unbounded retry loop against a
    /// binary that has been deleted or a bash that has been uninstalled
    /// would spawn a process per second forever — visible in Activity
    /// Monitor as exactly the kind of misbehaviour that gets an always-on
    /// app switched off.
    private func scheduleRestart() {
        guard Defaults.monitoringEnabled else { return }
        restartAttempts += 1
        let delay = min(pow(2.0, Double(min(restartAttempts, 6))), 60.0)
        log.info("restarting monitor in \(delay, format: .fixed(precision: 0))s (attempt \(self.restartAttempts))")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, Defaults.monitoringEnabled else { return }
            self.start()
        }
    }

    /// `--verify` only: point this stream at a stand-in executable.
    func useBinaryForTesting(_ path: String) { binaryOverrideForTesting = path }

    /// Populates synthetic sample data for GalleryMode previews without running a child process.
    func adoptGallerySample(_ sample: MonitorSample, historical: [MonitorSample] = []) {
        self.latest = sample
        self.awaitingSince = nil
        self.isRunning = true
        self.isPaused = false
        self.pauseReason = nil
        self.lastError = nil
        if historical.isEmpty {
            self.recent = [sample]
        } else {
            self.recent = historical
        }
    }
}
