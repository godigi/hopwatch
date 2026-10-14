import Foundation
import Darwin

/// One CLI child, spawned into its **own process group**, with the plumbing
/// `HopwatchRunner.execute` needs and `Foundation.Process` cannot give.
///
/// Why not `Process`:
///
/// 1. **Cancel has to reach the grandchildren.** `bin/hopwatch` is a bash
///    script that forks `curl`, `speedtest`, `mtr` and friends. `Process`
///    only knows the script's PID, so `terminate()` stops the script and
///    leaves a bufferbloat `curl` saturating the link. `Process` offers no
///    way to put the child in its own group; `posix_spawn` with
///    `POSIX_SPAWN_SETPGROUP` does, and then `kill(-pgid, …)` reaches all
///    of them.
/// 2. **Exit must not wait on grandchildren.** The old termination handler
///    called `availableData` on the pipes, which blocks until *every*
///    holder of the write end closes it. A surviving grandchild kept the
///    handler parked, so `isScanning` stayed true and the monitor stayed
///    paused. Here the reader threads poll, and once the child has exited
///    they stop as soon as the pipe has nothing left to give.
///
/// The type is deliberately small and synchronous inside; `HopwatchRunner`
/// wraps it in the async/cancellation shell.
final class ChildProcess: @unchecked Sendable {

    struct Result: Sendable {
        var stdout: Data
        var stderr: Data
        /// Shell convention: the exit code, or 128 + signal number when the
        /// child was killed by a signal. `Process.terminationStatus` reports
        /// the bare signal number instead, which is indistinguishable from
        /// an exit code of the same value.
        var status: Int32
    }

    enum SpawnError: Error { case failed(Int32), pipe(Int32) }

    let pid: pid_t
    private let lock = NSLock()
    private var cancelRequested = false
    private var finished = false
    private var stdinFD: Int32

    /// Spawns `path` in a fresh process group (`pgid == pid`).
    ///
    /// SIGPIPE is reset to its default disposition in the child even though
    /// the app ignores it: an ignored signal survives `exec`, and a CLI that
    /// silently stopped dying on `cmd | head` would behave differently under
    /// the app than in a terminal.
    init(path: String, arguments: [String], environment: [String: String],
         feedsStdin: Bool,
         onStdout: @escaping @Sendable (Data) -> Void,
         onStderr: @escaping @Sendable (Data) -> Void,
         onExit: @escaping @Sendable (Int32) -> Void) throws {

        var inFDs: [Int32] = [-1, -1], outFDs: [Int32] = [-1, -1], errFDs: [Int32] = [-1, -1]
        func closeAll() { for fd in inFDs + outFDs + errFDs where fd >= 0 { close(fd) } }
        if feedsStdin, pipe(&inFDs) != 0 { throw SpawnError.pipe(errno) }
        if pipe(&outFDs) != 0 { let e = errno; closeAll(); throw SpawnError.pipe(e) }
        if pipe(&errFDs) != 0 { let e = errno; closeAll(); throw SpawnError.pipe(e) }
        // Parent ends must not leak into unrelated children spawned later.
        for fd in [inFDs[1], outFDs[0], errFDs[0]] where fd >= 0 {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }
        // A write to a child that already exited must fail with EPIPE, not
        // deliver SIGPIPE to the app — whatever the process-wide disposition.
        if inFDs[1] >= 0 { _ = fcntl(inFDs[1], F_SETNOSIGPIPE, 1) }

        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if feedsStdin {
            posix_spawn_file_actions_adddup2(&actions, inFDs[0], 0)
        } else {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, outFDs[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errFDs[1], 2)

        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        var defaults = sigset_t()
        sigemptyset(&defaults)
        sigaddset(&defaults, SIGPIPE)
        posix_spawnattr_setsigdefault(&attr, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attr, &mask)
        posix_spawnattr_setpgroup(&attr, 0)
        // CLOEXEC_DEFAULT: the child gets 0/1/2 and nothing else.
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF
            | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT
        posix_spawnattr_setflags(&attr, Int16(flags))

        let argv: [UnsafeMutablePointer<CChar>?] =
            ([path] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] =
            environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for p in argv { free(p) }
            for p in envp { free(p) }
        }

        var childPID: pid_t = 0
        let rc = posix_spawn(&childPID, path, &actions, &attr, argv, envp)
        // The child's ends are no longer ours to hold, success or not.
        for fd in [inFDs[0], outFDs[1], errFDs[1]] where fd >= 0 { close(fd) }
        guard rc == 0 else {
            for fd in [inFDs[1], outFDs[0], errFDs[0]] where fd >= 0 { close(fd) }
            throw SpawnError.failed(rc)
        }

        self.pid = childPID
        self.stdinFD = inFDs[1]

        let exitFlag = ExitFlag()
        let readers = DispatchGroup()
        let outFD = outFDs[0], errFD = errFDs[0]
        for (fd, sink) in [(outFD, onStdout), (errFD, onStderr)] {
            readers.enter()
            Thread.detachNewThread {
                Self.drain(fd: fd, exited: exitFlag, sink: sink)
                close(fd)
                readers.leave()
            }
        }

        let pid = childPID
        Thread.detachNewThread { [self] in
            var raw: Int32 = 0
            while waitpid(pid, &raw, 0) < 0 && errno == EINTR {}
            let status: Int32
            if raw & 0x7f == 0 { status = (raw >> 8) & 0xff }          // WIFEXITED
            else { status = 128 + (raw & 0x7f) }                       // WIFSIGNALED
            self.lock.lock(); self.finished = true; self.lock.unlock()
            self.closeStdin()
            exitFlag.set()
            // Readers stop once the pipes run dry — they do not wait for a
            // lingering grandchild to let go of the write end.
            readers.notify(queue: .global(qos: .userInitiated)) { onExit(status) }
        }
    }

    // MARK: - Reading

    private final class ExitFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        private var at: UInt64 = 0
        func set() {
            lock.lock()
            if !value { value = true; at = DispatchTime.now().uptimeNanoseconds }
            lock.unlock()
        }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        /// Seconds since `set()`, or 0 while the child is still running.
        var secondsSinceSet: Double {
            lock.lock(); defer { lock.unlock() }
            guard value else { return 0 }
            return Double(DispatchTime.now().uptimeNanoseconds &- at) / 1_000_000_000
        }
    }

    /// How long readers keep draining after the child has exited. Long enough
    /// for everything the child wrote before exiting to be read; short enough
    /// that a grandchild which keeps writing cannot hold `onExit` forever.
    private static let drainGrace: Double = 0.25

    /// Reads until EOF, or until the child has exited and the pipe is empty.
    private static func drain(fd: Int32, exited: ExitFlag, sink: @Sendable (Data) -> Void) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if exited.secondsSinceSet > drainGrace { return }
            // Sampled *before* polling: data written before the exit is in
            // the pipe by now, so an empty pipe after this point is final.
            let wasExited = exited.isSet
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let n = poll(&pfd, 1, 100)
            if n < 0 {
                if errno == EINTR { continue }
                return
            }
            if n == 0 {
                if wasExited { return }
                continue
            }
            let got = read(fd, &buffer, buffer.count)
            if got > 0 {
                sink(Data(buffer[0..<got]))
            } else if got == 0 {
                return                                   // EOF
            } else if errno != EINTR && errno != EAGAIN {
                return
            }
        }
    }

    // MARK: - Writing

    /// Writes `data` to the child's stdin on a background thread and closes
    /// it. EPIPE (the child has already gone) is expected and swallowed.
    func feed(_ data: Data) {
        // Ownership of the descriptor moves to the writer, atomically with
        // clearing `stdinFD`. After this `closeStdin()` is a no-op, so no one
        // else can close the fd number while the writer still holds it (and
        // a recycled number can never receive this payload). A write stuck on
        // a full pipe is released by EPIPE once the child — or, on cancel,
        // its killed process group — drops the read end.
        lock.lock(); let fd = stdinFD; stdinFD = -1; lock.unlock()
        guard fd >= 0 else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if n > 0 { offset += n; continue }
                    if n < 0 && errno == EINTR { continue }
                    break                                // EPIPE or worse: give up quietly
                }
            }
            close(fd)
        }
    }

    /// Closes stdin if no `feed` has taken ownership of it; otherwise the
    /// writer closes it itself when it finishes.
    func closeStdin() {
        lock.lock()
        let fd = stdinFD
        stdinFD = -1
        lock.unlock()
        if fd >= 0 { close(fd) }
    }

    // MARK: - Cancelling

    var wasCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelRequested }

    /// SIGTERM to the whole group, then SIGKILL after `grace` if anything in
    /// it is still alive. Idempotent.
    func cancel(grace: TimeInterval = 3) {
        lock.lock()
        let already = cancelRequested
        cancelRequested = true
        let done = finished
        lock.unlock()
        guard !already else { return }
        closeStdin()
        // After the leader is reaped its pid may be recycled, but a group id
        // stays reserved while any member lives, so signalling `-pid` is only
        // ever wrong if the whole group is gone — and then it finds no one.
        if !done || kill(-pid, 0) == 0 { kill(-pid, SIGTERM) }
        let pgid = pid
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
            if kill(-pgid, 0) == 0 { kill(-pgid, SIGKILL) }
        }
    }
}
