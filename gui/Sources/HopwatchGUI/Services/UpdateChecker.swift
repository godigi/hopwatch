import Foundation
import SwiftUI
import os.log

/// Automatic update checker and installer for Netdiag GUI.
///
/// Periodically (or on-demand) queries GitHub Releases API for `godigi/netdiag`,
/// evaluates whether a newer semantic version is available, and provides
/// one-click downloading, installation, and relaunching.
@MainActor
@Observable
final class UpdateChecker {
    private let log = Logger(subsystem: "com.godigi.hopwatch", category: "UpdateChecker")
    private let releaseAPI = URL(string: "https://api.github.com/repos/godigi/hopwatch/releases/latest")!
    private let releaseWebFallback = URL(string: "https://github.com/godigi/hopwatch/releases/latest")!

    var isChecking = false
    var isDownloading = false
    var isPreloaded = false
    private var preloadedAppPath: String?
    private var preloadTask: Task<Void, Never>?
    var downloadProgress: Double = 0.0
    var hasUpdate = false
    var availableRelease: GitHubRelease?
    var statusMessage: String = "Up to date"
    var lastCheckedDate: Date? { Defaults.lastUpdateCheck }
    var errorMessage: String?
    var onUpdateFound: ((GitHubRelease) -> Void)?

    init() {
        if let last = Defaults.lastUpdateCheck {
            log.debug("UpdateChecker initialized. Last checked: \(last.description, privacy: .public)")
        }
    }

    /// Checks for updates against GitHub Releases.
    /// - Parameter manual: If true, updates statusMessage explicitly for user feedback.
    func checkForUpdates(manual: Bool = false) {
        guard !isChecking else { return }
        isChecking = true
        errorMessage = nil
        if manual { statusMessage = "Checking for updates…" }

        Task { [weak self] in
            guard let self else { return }
            defer { self.isChecking = false }
            do {
                var request = URLRequest(url: self.releaseAPI)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("Netdiag-App/\(Defaults.appVersion)", forHTTPHeaderField: "User-Agent")
                request.timeoutInterval = 10

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }

                if http.statusCode == 404 {
                    // No releases published yet on the repo
                    self.hasUpdate = false
                    self.statusMessage = "You're up to date! (v\(Defaults.appVersion))"
                    Defaults.lastUpdateCheck = Date()
                    return
                }

                guard (200...299).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }

                let decoder = JSONDecoder()
                let release = try decoder.decode(GitHubRelease.self, from: data)

                Defaults.lastUpdateCheck = Date()

                let remoteVersion = SemanticVersion(release.cleanVersion)
                let localVersion = SemanticVersion(Defaults.appVersion)

                if remoteVersion > localVersion {
                    let hasArchive = release.assets.contains(where: { $0.isInstallableArchive })
                    if hasArchive {
                        self.availableRelease = release
                        self.hasUpdate = true
                        self.statusMessage = "New version available: v\(release.cleanVersion)"
                        self.log.notice("Update available: v\(release.cleanVersion, privacy: .public)")
                        if Defaults.lastNotifiedUpdateVersion != release.cleanVersion {
                            Defaults.lastNotifiedUpdateVersion = release.cleanVersion
                            self.onUpdateFound?(release)
                        }
                        if !self.isDownloading && !self.isPreloaded {
                            self.startBackgroundPreload(for: release)
                        }
                    } else {
                        // Release tag exists but packaging is still in progress in CI
                        self.availableRelease = nil
                        self.hasUpdate = false
                        if manual {
                            self.statusMessage = "v\(release.cleanVersion) published (packaging in progress…)"
                        } else {
                            self.statusMessage = "Up to date (v\(Defaults.appVersion))"
                        }
                        self.log.info("Release v\(release.cleanVersion) has no installable assets yet; waiting for packaging.")
                    }
                } else {
                    self.availableRelease = nil
                    self.hasUpdate = false
                    self.statusMessage = "Up to date (v\(Defaults.appVersion))"
                    self.log.debug("Current version is up to date.")
                }
            } catch {
                self.log.error("Update check failed: \(error.localizedDescription, privacy: .public)")
                if manual {
                    self.errorMessage = "Failed to check for updates."
                    self.statusMessage = "Check failed"
                }
            }
        }
    }

    /// Background check executed daily if enabled in settings.
    func performDailyCheck() {
        guard Defaults.autoCheckUpdates else { return }
        let now = Date()
        if let last = Defaults.lastUpdateCheck {
            let elapsed = now.timeIntervalSince(last)
            // 24 hours = 86,400 seconds
            if elapsed < 86_400 {
                return
            }
        }
        checkForUpdates(manual: false)
    }

    /// Downloads and installs the latest release update, then relaunches the app.
    func downloadAndInstallUpdate() {
        installUpdate()
    }

    /// Preloads update in background quietly so subsequent install is instantaneous.
    func startBackgroundPreload(for release: GitHubRelease) {
        guard !isDownloading, !isPreloaded, preloadTask == nil else { return }
        let asset = release.assets.first(where: { $0.name.lowercased().hasSuffix(".zip") })
            ?? release.assets.first(where: { $0.isInstallableArchive })
        guard let downloadURL = asset?.browserDownloadUrl else { return }

        preloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("HopwatchPreload-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                let downloader = FileDownloader()
                let downloadedURL = try await downloader.download(from: downloadURL) { _ in }
                guard let ext = Self.archiveExtension(forAssetNamed: asset?.name) else { return }
                let archivePath = tempDir.appendingPathComponent("update.\(ext)")
                try FileManager.default.moveItem(at: downloadedURL, to: archivePath)

                let extractDir = tempDir.appendingPathComponent("Extracted")
                try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

                var appPath: String?
                if ext == "zip" {
                    try await Self.runTool("/usr/bin/ditto", ["-xk", archivePath.path, extractDir.path])
                    appPath = self.findApp(in: extractDir)
                } else if ext == "dmg" {
                    let mountPoint = tempDir.appendingPathComponent("Volume")
                    try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
                    try await Self.runTool("/usr/bin/hdiutil", [
                        "attach", archivePath.path, "-mountpoint", mountPoint.path,
                        "-nobrowse", "-quiet", "-noautoopen"])
                    do {
                        if let sourceApp = self.findApp(in: mountPoint) {
                            let copiedApp = extractDir.appendingPathComponent(
                                URL(fileURLWithPath: sourceApp).lastPathComponent)
                            try await Self.runTool("/usr/bin/ditto", [sourceApp, copiedApp.path])
                            appPath = copiedApp.path
                        }
                    } catch {
                        try? await Self.runTool("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force", "-quiet"])
                        throw error
                    }
                    try? await Self.runTool("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force", "-quiet"])
                }

                if let appPath {
                    self.preloadedAppPath = appPath
                    self.isPreloaded = true
                    self.statusMessage = "v\(release.cleanVersion) ready to install"
                    self.log.notice("Update v\(release.cleanVersion) preloaded and ready to install.")
                }
            } catch {
                self.log.debug("Background preload failed: \(error.localizedDescription)")
            }
        }
    }

    /// Downloads the latest release asset and initiates automatic in-place upgrade.
    func installUpdate() {
        guard let release = availableRelease else {
            openReleasePage()
            return
        }

        // Fast path: use already preloaded app bundle
        if isPreloaded, let preloadedAppPath, FileManager.default.fileExists(atPath: preloadedAppPath) {
            self.downloadProgress = 1.0
            self.statusMessage = "Relaunching…"
            self.replaceAndRelaunch(withAppAt: preloadedAppPath)
            return
        }

        // Look for installable asset (preferring direct .zip archive, falling back to .dmg)
        let asset = release.assets.first(where: { $0.name.lowercased().hasSuffix(".zip") })
            ?? release.assets.first(where: { $0.isInstallableArchive })
        guard let downloadURL = asset?.browserDownloadUrl else {
            // No direct archive asset attached: open release page directly
            openReleasePage()
            return
        }

        guard !isDownloading else { return }
        isDownloading = true
        downloadProgress = 0.05
        statusMessage = "Connecting…"

        Task { [weak self] in
            guard let self else { return }
            defer { self.isDownloading = false }
            do {
                let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("HopwatchUpdate-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

                self.statusMessage = "Downloading v\(release.cleanVersion)…"
                let downloader = FileDownloader()
                let downloadedURL = try await downloader.download(from: downloadURL) { [weak self] progress in
                    Task { @MainActor in
                        self?.downloadProgress = progress
                    }
                }

                self.downloadProgress = 0.9
                self.statusMessage = "Extracting update…"

                // The asset name comes from the release JSON and is attacker-
                // influenced if the release were ever tampered with: a name
                // like "../../x.zip" would have walked out of the temp
                // directory. Only the extension is used; the file name is ours.
                guard let ext = Self.archiveExtension(forAssetNamed: asset?.name) else {
                    self.openReleasePage()
                    return
                }
                let archivePath = tempDir.appendingPathComponent("update.\(ext)")
                try FileManager.default.moveItem(at: downloadedURL, to: archivePath)

                // Unpack archive
                let extractDir = tempDir.appendingPathComponent("Extracted")
                try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

                var appPath: String?

                // `ditto`, `hdiutil` and the app copy all run off the main
                // actor (a 30 MB unzip used to freeze the UI and the menu bar
                // dot) and each exit status is checked: a failed unpack used
                // to fall through to "no .app found" with no cause logged.
                if ext == "zip" {
                    try await Self.runTool("/usr/bin/ditto", ["-xk", archivePath.path, extractDir.path])
                    appPath = findApp(in: extractDir)
                } else if ext == "dmg" {
                    // Mount DMG without user interaction
                    let mountPoint = tempDir.appendingPathComponent("Volume")
                    try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
                    try await Self.runTool("/usr/bin/hdiutil", [
                        "attach", archivePath.path, "-mountpoint", mountPoint.path,
                        "-nobrowse", "-quiet", "-noautoopen"])
                    do {
                        if let sourceApp = findApp(in: mountPoint) {
                            let copiedApp = extractDir.appendingPathComponent(
                                URL(fileURLWithPath: sourceApp).lastPathComponent)
                            try await Self.runTool("/usr/bin/ditto", [sourceApp, copiedApp.path])
                            appPath = copiedApp.path
                        }
                    } catch {
                        try? await Self.runTool("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force", "-quiet"])
                        throw error
                    }
                    try? await Self.runTool("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force", "-quiet"])
                }

                if let appPath {
                    self.downloadProgress = 1.0
                    self.statusMessage = "Relaunching…"
                    self.replaceAndRelaunch(withAppAt: appPath)
                    return
                }

                // If unpack did not locate a direct .app, open release page
                self.openReleasePage()
            } catch {
                self.log.error("Installation failed: \(error.localizedDescription, privacy: .public)")
                self.errorMessage = "Failed to install update."
                self.openReleasePage()
            }
        }
    }

    /// The archive kind to unpack, taken from a release asset's name, or nil
    /// when it is not one this installer can open. Only the extension is
    /// trusted: the name itself is release metadata and never becomes a path.
    nonisolated static func archiveExtension(forAssetNamed name: String?) -> String? {
        guard let name else { return nil }
        let lower = name.lowercased()
        if lower.hasSuffix(".zip") { return "zip" }
        if lower.hasSuffix(".dmg") { return "dmg" }
        return nil
    }

    struct ToolFailure: LocalizedError {
        let tool: String
        let status: Int32
        var errorDescription: String? { "\(tool) exited with status \(status)" }
    }

    /// Runs a system tool to completion on a background thread and throws
    /// unless it exits 0. Output is discarded: these tools are run with
    /// `-quiet`, and an unread pipe would stall them.
    nonisolated static func runTool(_ path: String, _ arguments: [String]) async throws {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw ToolFailure(tool: (path as NSString).lastPathComponent,
                                  status: process.terminationStatus)
            }
        }.value
    }

    /// Determines the installation destination for the updated app bundle.
    /// Prefers the currently running bundle if it is an installed .app, otherwise
    /// checks /Applications, then ~/Applications.
    var targetAppURL: URL {
        let currentBundle = Bundle.main.bundleURL
        let appName = (currentBundle.pathExtension == "app") ? currentBundle.lastPathComponent : "Hopwatch.app"

        if currentBundle.pathExtension == "app" {
            let parent = currentBundle.deletingLastPathComponent()
            if FileManager.default.isWritableFile(atPath: currentBundle.path) ||
               FileManager.default.isWritableFile(atPath: parent.path) {
                return currentBundle
            }
        }

        let sysApps = URL(fileURLWithPath: "/Applications/\(appName)")
        let userApps = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/\(appName)")

        if FileManager.default.isWritableFile(atPath: "/Applications") {
            return sysApps
        } else if FileManager.default.isWritableFile(atPath: userApps.deletingLastPathComponent().path) {
            return userApps
        }
        return sysApps
    }

    /// Helper to locate Hopwatch.app (or legacy Netdiag.app) in a directory or its immediate children
    private func findApp(in directory: URL) -> String? {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: directory.path) else { return nil }
        for appName in ["Hopwatch.app", "Netdiag.app"] {
            if contents.contains(appName) {
                return directory.appendingPathComponent(appName).path
            }
        }
        for item in contents {
            let sub = directory.appendingPathComponent(item)
            if sub.lastPathComponent == "Hopwatch.app" || sub.lastPathComponent == "Netdiag.app" {
                return sub.path
            }
        }
        return nil
    }

    /// Opens the GitHub release page in default browser.
    func openReleasePage() {
        let url = availableRelease?.htmlUrl ?? releaseWebFallback
        NSWorkspace.shared.open(url)
    }

    /// Spawns a background script that waits for current process to exit, atomically swaps
    /// the target app bundle with automatic rollback, strips Gatekeeper quarantine flags, and relaunches.
    private func replaceAndRelaunch(withAppAt newAppPath: String) {
        let targetPath = targetAppURL.path
        let targetDir = (targetPath as NSString).deletingLastPathComponent

        // Pre-flight: verify write access before terminating
        let fm = FileManager.default
        let isDirWritable = fm.isWritableFile(atPath: targetDir)
        let isTargetWritable = fm.fileExists(atPath: targetPath) ? fm.isWritableFile(atPath: targetPath) : true

        guard isDirWritable && isTargetWritable else {
            self.log.error("Target directory or app is not writable: \(targetPath, privacy: .public)")
            self.errorMessage = "Permission denied: unable to write to \(targetDir). Please update manually."
            self.openReleasePage()
            return
        }

        let currentPID = ProcessInfo.processInfo.processIdentifier

        // Every path reaches the script as a positional argument ($1..$3),
        // never as text spliced into it: an app name or install location
        // containing a quote, `$(`, or a newline would otherwise be
        // executed rather than copied.
        let script = """
        PARENT_PID="$1"
        TARGET="$2"
        NEW_APP="$3"
        TARGET_DIR="$(dirname "$TARGET")"

        # Wait up to 10 seconds for current app process to exit
        for i in {1..50}; do
            if ! kill -0 "$PARENT_PID" 2>/dev/null; then
                break
            fi
            sleep 0.2
        done
        sleep 0.3

        mkdir -p "$TARGET_DIR" 2>/dev/null || true
        TMP_STAGING="${TARGET}.new.$$"
        BACKUP="${TARGET}.old.$$"

        rm -rf "$TMP_STAGING" "$BACKUP"
        # Preserve all code signatures, extended attributes, and permissions with ditto
        if ! /usr/bin/ditto "$NEW_APP" "$TMP_STAGING"; then
            rm -rf "$TMP_STAGING"
            # The old app is untouched: put the user back in it.
            open "$TARGET"
            exit 1
        fi

        # Strip Gatekeeper quarantine & provenance attributes recursively
        xattr -cr "$TMP_STAGING" 2>/dev/null || true

        if [ -d "$TARGET" ]; then
            mv "$TARGET" "$BACKUP" 2>/dev/null || rm -rf "$TARGET"
        fi

        if mv "$TMP_STAGING" "$TARGET" 2>/dev/null; then
            rm -rf "$BACKUP" 2>/dev/null || true
        elif [ -d "$BACKUP" ]; then
            # Rollback if move failed
            mv "$BACKUP" "$TARGET" 2>/dev/null || true
            open "$TARGET"
            exit 1
        fi

        # Ensure target is clean and executable
        xattr -cr "$TARGET" 2>/dev/null || true
        open "$TARGET"
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        // "hopwatch-update" is $0; the three values follow as $1, $2, $3.
        process.arguments = ["-c", script, "hopwatch-update",
                             String(currentPID), targetPath, newAppPath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            // Quitting now would leave the user with no app and nothing
            // running to bring one back. Stay open and say so.
            self.log.error("Could not start the update script: \(error.localizedDescription, privacy: .public)")
            self.errorMessage = "Couldn't start the installer. Please update manually."
            self.statusMessage = "Update failed"
            self.openReleasePage()
            return
        }

        NSApp.terminate(nil)
    }
}

/// Helper delegate for downloading files with real progress reporting.
private final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    var onProgress: (@Sendable (Double) -> Void)?
    private var continuation: CheckedContinuation<URL, Error>?

    func download(from url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        self.onProgress = progress
        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            let config = URLSessionConfiguration.default
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            let task = session.downloadTask(with: url)
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let tempTarget = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: tempTarget)
            continuation?.resume(returning: tempTarget)
        } catch {
            continuation?.resume(throwing: error)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        onProgress?(min(0.95, max(0.05, fraction)))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
        }
    }
}
