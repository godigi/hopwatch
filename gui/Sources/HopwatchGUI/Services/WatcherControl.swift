import Foundation

/// Manages legacy launchd watcher state — `hopwatch --uninstall-watcher` —
/// and reports whether a legacy agent is loaded so it can be uninstalled.
///
/// Historical baselines are recorded automatically on network arrival and
/// on-demand full checks. This control ensures any legacy 15-minute launchd
/// daemon from prior versions can be detected and cleanly unloaded.
@MainActor
@Observable
final class WatcherControl {

    private(set) var isInstalled = false
    private(set) var isBusy = false
    private(set) var lastError: String?

    private static let label = "com.hopwatch.watcher"
    private static let legacyLabel = "com.netdiag.watcher"

    func refresh() async {
        isInstalled = await Self.isLoaded()
    }

    func install() async {
        await toggle(argument: "--install-watcher", expecting: true)
    }

    func uninstall() async {
        await toggle(argument: "--uninstall-watcher", expecting: false)
    }

    private func toggle(argument: String, expecting: Bool) async {
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await NetdiagRunner.run(depth: .quick, extraArguments: [argument])
        } catch {
            // Both watcher flags are mode dispatchers: they exit 0 before
            // the check battery runs, so --json never gets a chance to
            // print and the decode fails on success. Only a script error
            // (exit 3) is worth surfacing.
            if case NetdiagError.scriptError(let detail) = error {
                lastError = detail
                await refresh()
                return
            }
        }
        lastError = nil
        await refresh()
        // launchctl is not synchronous with the load; if the state hasn't
        // caught up, look once more rather than showing a stale toggle.
        if isInstalled != expecting {
            try? await Task.sleep(for: .milliseconds(400))
            await refresh()
        }
    }

    /// `launchctl list <label>` exits non-zero when the job is not loaded.
    /// Cheaper and more direct than parsing the full list, and it does not
    /// care whether the plist file happens to exist — a plist on disk that
    /// failed to load is exactly the state a "watcher installed" toggle
    /// must not claim.
    private static func isLoaded() async -> Bool {
        if await checkLoaded(label: label) { return true }
        return await checkLoaded(label: legacyLabel)
    }

    private static func checkLoaded(label: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["list", label]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { p in
                continuation.resume(returning: p.terminationStatus == 0)
            }
            do { try process.run() } catch { continuation.resume(returning: false) }
        }
    }
}
