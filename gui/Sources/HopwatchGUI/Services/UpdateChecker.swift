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

    /// Downloads the latest release asset and initiates automatic in-place upgrade.
    func installUpdate() {
        guard let release = availableRelease else {
            openReleasePage()
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

                let archivePath = tempDir.appendingPathComponent(asset?.name ?? "update.zip")
                try FileManager.default.moveItem(at: downloadedURL, to: archivePath)

                // Unpack archive
                let extractDir = tempDir.appendingPathComponent("Extracted")
                try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

                let ext = archivePath.pathExtension.lowercased()
                var appPath: String?

                if ext == "zip" {
                    let ditto = Process()
                    ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                    ditto.arguments = ["-xk", archivePath.path, extractDir.path]
                    try ditto.run()
                    ditto.waitUntilExit()

                    appPath = findApp(in: extractDir)
                } else if ext == "dmg" {
                    // Mount DMG without user interaction
                    let mountPoint = tempDir.appendingPathComponent("Volume")
                    try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)

                    let hdiutil = Process()
                    hdiutil.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                    hdiutil.arguments = ["attach", archivePath.path, "-mountpoint", mountPoint.path, "-nobrowse", "-quiet", "-noautoopen"]
                    try hdiutil.run()
                    hdiutil.waitUntilExit()

                    defer {
                        // Unmount when finished
                        let detach = Process()
                        detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                        detach.arguments = ["detach", mountPoint.path, "-force", "-quiet"]
                        try? detach.run()
                        detach.waitUntilExit()
                    }

                    if let sourceApp = findApp(in: mountPoint) {
                        let sourceURL = URL(fileURLWithPath: sourceApp)
                        let copiedApp = extractDir.appendingPathComponent(sourceURL.lastPathComponent)
                        try? FileManager.default.removeItem(at: copiedApp)
                        try FileManager.default.copyItem(at: sourceURL, to: copiedApp)
                        appPath = copiedApp.path
                    }
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

        let script = """
        PARENT_PID="\(currentPID)"
        # Wait up to 10 seconds for current app process to exit
        for i in {1..50}; do
            if ! kill -0 "$PARENT_PID" 2>/dev/null; then
                break
            fi
            sleep 0.2
        done
        sleep 0.3

        TARGET="\(targetPath)"
        NEW_APP="\(newAppPath)"
        TARGET_DIR="\(targetDir)"

        mkdir -p "$TARGET_DIR" 2>/dev/null || true
        TMP_STAGING="${TARGET}.new.$$"
        BACKUP="${TARGET}.old.$$"

        rm -rf "$TMP_STAGING" "$BACKUP"
        # Preserve all code signatures, extended attributes, and permissions with ditto
        /usr/bin/ditto "$NEW_APP" "$TMP_STAGING" || exit 1

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
            exit 1
        fi

        # Ensure target is clean and executable
        xattr -cr "$TARGET" 2>/dev/null || true
        open "$TARGET"
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        try? process.run()

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
