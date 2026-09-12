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
    private let log = Logger(subsystem: "com.godigi.netdiag", category: "UpdateChecker")
    private let releaseAPI = URL(string: "https://api.github.com/repos/godigi/netdiag/releases/latest")!
    private let releaseWebFallback = URL(string: "https://github.com/godigi/netdiag/releases/latest")!

    var isChecking = false
    var isDownloading = false
    var downloadProgress: Double = 0.0
    var hasUpdate = false
    var availableRelease: GitHubRelease?
    var statusMessage: String = "Up to date"
    var lastCheckedDate: Date? { Defaults.lastUpdateCheck }
    var errorMessage: String?

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

                guard http.statusCode == 200 else {
                    throw URLError(.init(rawValue: http.statusCode))
                }

                let decoder = JSONDecoder()
                let release = try decoder.decode(GitHubRelease.self, from: data)
                let currentVersion = SemanticVersion(Defaults.appVersion)
                let remoteVersion = SemanticVersion(release.cleanVersion)

                Defaults.lastUpdateCheck = Date()

                if remoteVersion > currentVersion {
                    self.hasUpdate = true
                    self.availableRelease = release
                    self.statusMessage = "netdiag v\(release.cleanVersion) is available!"
                    self.log.info("New release found: v\(release.cleanVersion) (current: v\(Defaults.appVersion))")
                } else {
                    self.hasUpdate = false
                    self.availableRelease = nil
                    self.statusMessage = "You're up to date! (v\(Defaults.appVersion))"
                    self.log.debug("App is up to date: v\(Defaults.appVersion)")
                }
            } catch {
                self.log.error("Update check failed: \(error.localizedDescription, privacy: .public)")
                if manual {
                    self.errorMessage = "Could not check for updates."
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
        guard let release = availableRelease else {
            openReleasePage()
            return
        }

        // Look for installable asset (e.g. Netdiag.app.zip, Netdiag.zip, Netdiag.dmg)
        let asset = release.assets.first(where: { $0.isInstallableArchive })
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
                let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("NetdiagUpdate-\(UUID().uuidString)")
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
                        let copiedApp = extractDir.appendingPathComponent("Netdiag.app")
                        try? FileManager.default.removeItem(at: copiedApp)
                        try FileManager.default.copyItem(at: URL(fileURLWithPath: sourceApp), to: copiedApp)
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
        if currentBundle.pathExtension == "app" {
            let parent = currentBundle.deletingLastPathComponent()
            if FileManager.default.isWritableFile(atPath: currentBundle.path) ||
               FileManager.default.isWritableFile(atPath: parent.path) {
                return currentBundle
            }
        }

        let sysApps = URL(fileURLWithPath: "/Applications/Netdiag.app")
        let userApps = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Netdiag.app")

        if FileManager.default.isWritableFile(atPath: "/Applications") {
            return sysApps
        } else if FileManager.default.isWritableFile(atPath: userApps.deletingLastPathComponent().path) {
            return userApps
        }
        return sysApps
    }

    /// Helper to locate Netdiag.app in a directory or its immediate children
    private func findApp(in directory: URL) -> String? {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: directory.path) else { return nil }
        if contents.contains("Netdiag.app") {
            return directory.appendingPathComponent("Netdiag.app").path
        }
        for item in contents {
            let sub = directory.appendingPathComponent(item)
            if sub.lastPathComponent == "Netdiag.app" {
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

        let script = """
        sleep 1
        TARGET="\(targetPath)"
        NEW_APP="\(newAppPath)"
        TARGET_DIR="\(targetDir)"

        mkdir -p "$TARGET_DIR" 2>/dev/null || true
        TMP_STAGING="${TARGET}.new.$$"
        BACKUP="${TARGET}.old.$$"

        rm -rf "$TMP_STAGING" "$BACKUP"
        cp -R "$NEW_APP" "$TMP_STAGING" || exit 1

        # Strip all Gatekeeper quarantine & provenance attributes recursively
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
