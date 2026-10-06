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
    /// When the monitor's own burst (an investigation it started on an
    /// ok→bad edge, or a latency test asked for by signal) expires, or nil
    /// when there isn't one. Read from the sample's `status.burst`: the
    /// CLI owns the burst and its deadline, so this holds no timer and a
    /// restart cannot desynchronise it. Public so the Live section can say
    /// out loud that what it is drawing is temporary.
    var burstUntil: Date? {
        guard isRunning, let burst = latest?.status.burst,
              let until = FastISO8601.parse(burst.until), until > Date() else { return nil }
        return until
    }

    /// The burst's sampling interval as the CLI reports it, for the
    /// "sampling every 2s" copy. `nil` when no burst is running.
    var burstIntervalS: Int? {
        burstUntil == nil ? nil : latest?.status.burst?.intervalS
    }

    private var process: Process?
    /// The monitor's stdout pipe, held separately from `process` so `stop()`
    /// can close the reading end on purpose. A `Process` alone keeps its
    /// `standardOutput` pipe alive internally, and the reader task that
    /// pulls lines from it dies with the task — but the file descriptor
    /// under it stays open, which is how a stopped monitor's writer ends
    /// up blocked forever. See `stop()`.
    private var readPipe: Pipe?
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

    private let log = Logger(subsystem: "com.godigi.hopwatch", category: "monitor")
    private let decoder = JSONDecoder()
    private static let recentCapacity = 360

    /// Called for every decoded sample. The alert engine subscribes here.
    var onSample: ((MonitorSample) -> Void)?

    // MARK: - Recording agent check

    /// True when a durable journal writer is already running outside this
    /// app: the launchd recorder agent (`com.hopwatch.recorder`, with the
    /// legacy `com.netdiag.recorder` label before the install layout
    /// changed). Both agents append transitions to the same
    /// `events.jsonl` the GUI's own `--journal` would write, and the
    /// evidence that two writers are one too many is `seq` running
    /// backwards 212 times in a single day's journal.
    ///
    /// Detection is the cheap one the plan sanctions — the plist file
    /// rather than `launchctl print`. A watcher plist lives under
    /// `~/Library/LaunchAgents`, is loaded by `RunAtLoad`/`KeepAlive` the
    /// moment it exists, and `uninstall_recorder_run` removes the plist
    /// file itself, so "file exists" tracks "job loaded" through every
    /// supported install and uninstall path. A plist unloaded by hand is
    /// outside that model, and the price of the false positive — the
    /// journal records transitions only while the recorder is expected to
    /// be running — is the safe side to miss on: the alternative is two
    /// writers interleaving appends.
    static var recorderAgentLoaded: Bool {
        let launchAgents = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents")
        for label in ["com.hopwatch.recorder", "com.netdiag.recorder"] {
            if FileManager.default.fileExists(
                atPath: launchAgents.appendingPathComponent("\(label).plist").path) {
                return true
            }
        }
        return false
    }

    // MARK: - Launch sweep

    /// Whether this launch has already swept for orphaned monitor
    /// processes, from a previous app instance that crashed or was
    /// force-quit with the stop path never reached. Once per launch: a
    /// mid-session restart must not sweep whatever was born since (and a
    /// second sweep against orphans would be redundant — the fixed
    /// `stop()` is what keeps the current child's children orphan-free).
    private var launchSweepDone = false

    func sweepOrphanedMonitors() {
        guard !launchSweepDone else { return }
        launchSweepDone = true
        Task.detached(priority: .utility) {
            // Pass 1: the monitor shells themselves — full command line
            // `…/bin/hopwatch --monitor … --monitor-fast-interval …`
            // whose parent is already launchd (pid 1), i.e. re-parented
            // leftovers. Two guards matter here. The argv one is what
            // keeps the recorder agent's own `--monitor` child alive: the
            // launchd plist spawns it without interval flags, so it is
            // never matched. The parentage one is what keeps a legit
            // terminal `hopwatch --monitor` — owned by a live shell — out
            // of the sweep; the app's *current* child is equally safe,
            // its parent is this app.
            let shells = Self.pgrepPids(parentPid: 1,
                                        pattern: "monitor .*--monitor-fast-interval")
            for pid in shells { kill(pid, SIGTERM) }
            // TERM is delivered to bash between commands, which can wait
            // out a probe cycle; the interval flags' deadline is a second
            // open prefix. Bash exit re-parents its wedged sample writer
            // to launchd — the settle below is what makes pass 2 see it.
            try? await Task.sleep(for: .seconds(1.0))
            for pid in shells where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
            // Pass 2: the wedged `monitor_sample.py` writers themselves.
            // These are the 8 leak-report writers: blocked inside write()
            // against a pipe whose reader is long gone, invisible to pass
            // 1 because their argv names python, not the CLI. The ppid
            // guard is what spares a live monitor's writer — it is
            // parented to that monitor's bash, not to launchd.
            let writers = Self.pgrepPids(parentPid: 1,
                                         pattern: "monitor_sample\\.py$",
                                         matchFull: false)
            for pid in writers { kill(pid, SIGKILL) }
            if !shells.isEmpty || !writers.isEmpty {
                Logger(subsystem: "com.godigi.hopwatch", category: "monitor")
                    .info("launch sweep reaped \(shells.count) monitor shell(s) and \(writers.count) wedged writer(s)")
            }
        }
    }

    /// `/usr/bin/pgrep` wrapped in a Process — the app already shells out
    /// for every probe, and this runs once per launch. Empty output is the
    /// normal no-orphans case, not an error.
    private nonisolated static func pgrepPids(parentPid: Int32, pattern: String, matchFull: Bool = true) -> [pid_t] {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = matchFull
            ? ["-P", String(parentPid), "-f", pattern]
            : ["-P", String(parentPid), pattern]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        do { try pgrep.run() } catch { return [] }
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        pgrep.waitUntilExit()
        return (String(data: out, encoding: .utf8) ?? "")
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0) }
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning, startTask == nil else { return }
        // Fail-fast only — the path spawned later is re-resolved after
        // the gate, not this one. See startAfterCapabilityCheck.
        guard BinaryLocator.resolve() != nil else {
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
            lastError = BinaryLocator.missingBinaryMessage
            return
        }
        spawn(binary: binary)
    }

    /// The process itself, split out of `start()` so the capability check
    /// above can sit ahead of it without duplicating any of this.
    private func spawn(binary: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        // Bursts are the monitor's own now (SIGURG/SIGWINCH), so the
        // process is started with the user's cadence settings and never
        // restarted to change them for a burst.
        let fast = Defaults.fastInterval
        let degraded = Defaults.degradedInterval
        var arguments = [
            "--monitor",
            "--monitor-fast-interval",     String(fast),
            "--monitor-degraded-interval", String(degraded),
            "--monitor-medium-interval",   String(Defaults.mediumInterval),
            "--monitor-slow-interval",     String(Defaults.slowInterval),
        ]
        if Self.recorderAgentLoaded {
            // See `recorderAgentLoaded` for the whole story. This re-checks
            // on every spawn, which is the natural place this app observes
            // a change: monitoring respawns at launch and on every cadence
            // change, so an agent uninstalled
            // (or installed) between spins of the monitor gates becomes
            // visible at the next respawn without a filesystem watcher.
            log.info("recorder agent present under LaunchAgents — withholding --journal (one journal writer)")
        } else {
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
            try? FileManager.default.createDirectory(at: journalDir, withIntermediateDirectories: true)
            let journalPath = journalDir.appendingPathComponent("events.jsonl").path
            arguments.insert(contentsOf: ["--journal", journalPath], at: 1)
        }
        proc.arguments = arguments
        proc.environment = BinaryLocator.environment()

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

        // Hold the pipe so `stop()` can close the read end by name; the
        // child side of it is the one a wedged writer would block on.
        readPipe = pipe

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
        guard let proc = process else {
            finishStop()
            return
        }
        let pid = proc.processIdentifier

        // ── 1. Close the read handle first ────────────────────────────
        // The reader has just been cancelled, which leaves a pipe nobody
        // reads. The monitor writes one sample per cycle into it, so its
        // monitor_sample.py would block forever inside write() once the
        // 64 KB buffer filled — the eighth wedged writers in the leak
        // report were exactly that. Closing the read end turns that next
        // write into EPIPE/SIGPIPE; the emit fails, and monitor_run's
        // `_mon_emit || break` tears the monitor down from the inside. No
        // signal ordering can do this job — a SIGTERM delivered to a bash
        // wedged behind a python that is still holding the pipe write end
        // leaves the python orphaned and blocked. The pipe close comes
        // before the signals on purpose.
        if let pipe = readPipe {
            pipe.fileHandleForReading.closeFile()
        }

        // ── 2. SIGTERM the process group ──────────────────────────────
        // The child is its own group leader — Darwin's NSTask spawns via
        // posix_spawn with a fresh process group whose pgid equals the
        // child's pid (verified live: getpgid(child) == child pid, and the
        // probe subprocesses monitor_sample.py and the pings inherit that
        // group, since bash scripts run without job control). A group TERM
        // therefore reaches the whole tree — bash, the sample writer, the
        // in-flight pings and with_timeout's killer subshells reach them
        // too. terminate() singles out the bash and leaves the rest of the
        // tree to the pipe close, so it is the fallback for a child that
        // somehow ended up sharing this app's group: group-signalling that
        // group would signal the app itself.
        if proc.isRunning {
            if getpgid(pid) == pid {
                kill(-pid, SIGTERM)
            } else {
                proc.terminate()
            }
            // ── 3. Escalate to SIGKILL after 2 s, then reap ───────────
            // `_mon_emit`'s failure break and the TERM trap land between
            // shell commands, so the exit can cost a cycle; the ping
            // subprocesses die on the group signal itself. Two seconds is
            // well clear of the longest single probe. After that nothing
            // in the tree is needed — kill the group so a zombie sample
            // writer cannot outlive bash — then reap so the Process
            // wrapper agrees with the OS about what died.
            // Off the main actor: waiting on an in-flight probe must not
            // freeze the menu bar — same reasoning as before this change,
            // which is what waitUntilExit already did.
            Task.detached(priority: .utility) {
                let escalateAt = Date().addingTimeInterval(2.0)
                while proc.isRunning, Date() < escalateAt {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                if proc.isRunning {
                    if getpgid(pid) == pid { kill(-pid, SIGKILL) } else { kill(pid, SIGKILL) }
                }
                proc.waitUntilExit()
            }
        }

        finishStop()
    }

    /// The bookkeeping half of `stop()`, shared by both exit paths so a
    /// child-less stop resets exactly the same state.
    private func finishStop() {
        readPipe = nil
        process = nil
        isRunning = false
        isPaused = false
        pauseHolders.removeAll()
        pauseReason = nil
        trapsReady = false
        pauseSignalPending = false
    }

    /// Same child, new arguments. Only a change to the user's cadence
    /// SETTINGS needs this (the intervals are command-line arguments); a
    /// burst never does. A restart discards every rolling window,
    /// confirmation streak and fired rule in the process, so it is for
    /// settings changes and nothing else. The pause holders are carried
    /// across, because `stop()` clears state that the *reasons* for it
    /// outlive: a cadence change applied mid-scan would otherwise hand
    /// back a running monitor probing the link that scan is measuring.
    func restart() {
        let holders = pauseHolders
        stop()
        restartAttempts = 0
        start()
        for reason in holders { pause(reason: reason) }
    }

    // MARK: - Burst cadence
    //
    // The dropdown's "Latency test" is this and nothing else. It does not
    // shell out: a second `netdiag --monitor` would contend with this one
    // for the very link it was started to measure, and the two would report
    // each other's traffic as latency.
    //
    // The burst itself runs inside the monitor process (lib/monitor.sh):
    // it starts one by itself on its own ok→warn/critical edge, and these
    // two signals start and end a manual one. Nothing here restarts the
    // process, so the rolling windows, streaks and fired rules the warning
    // being investigated lives in survive it — which the old restart-based
    // burst did not, and a warning that vanished four seconds after it
    // appeared was the result.

    var isBursting: Bool { burstUntil != nil }

    /// Ask the monitor for a latency test (SIGURG). Both signals default to
    /// "ignore", so a monitor that predates them, or one still before its
    /// traps, simply carries on.
    func beginBurst() {
        guard isRunning, !isPaused, let process, process.isRunning else { return }
        kill(process.processIdentifier, SIGURG)
        log.debug("latency test signaled (SIGURG)")
    }

    /// End the burst early and fall back to the normal cadence (SIGWINCH).
    /// Idempotent: the monitor ends bursts itself at their deadline.
    func endBurst() {
        guard isRunning, let process, process.isRunning else { return }
        kill(process.processIdentifier, SIGWINCH)
        log.debug("burst end signaled (SIGWINCH)")
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
    func forceRefresh() {
        guard let process, process.isRunning, !isPaused else { return }
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
                if Task.isCancelled { return }
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
        }
        // A sample proves the process is alive and producing, which is the
        // only evidence that matters for backoff.
        restartAttempts = 0
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

    /// Populates synthetic sample data for GalleryMode previews without running a child process.
    func adoptGallerySample(_ sample: MonitorSample, historical: [MonitorSample] = []) {
        self.latest = sample
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

