import CryptoKit
import Foundation
import os

/// Disk cache for `hopwatch --history` and `hopwatch --show=<id>` payloads,
/// keyed by a fingerprint of the underlying JSONL store (`baseline.jsonl` and
/// `baseline-archive.jsonl` file sizes + modification timestamps), CLI version,
/// and resolved binary path.
///
/// Whenever a scan or external CLI invocation appends to `baseline.jsonl`, the
/// fingerprint changes immediately, guaranteeing cache misses rather than stale
/// network statistics or run comparisons. On warm launches and repeated clicks,
/// the GUI avoids spawning `bash` + `python3` over megabytes of JSONL.
enum StoreDiskCache {

    private static let log = Logger(subsystem: "com.godigi.hopwatch", category: "storecache")
    private static let maxRunDetailEntries = 50

    /// Mirrors `bin/hopwatch`'s `LOG_DIR` resolution so the fingerprint watches
    /// the exact JSONL files the CLI reads.
    static func resolveLogDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory()
    ) -> URL {
        for key in ["HOPWATCH_LOG_DIR", "NETDIAG_LOG_DIR", "LOG_DIR"] {
            if let value = environment[key], !value.isEmpty {
                return URL(fileURLWithPath: value, isDirectory: true)
            }
        }
        let fm = FileManager.default
        let hopwatchDir = URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent("hopwatch", isDirectory: true)
        if fm.fileExists(atPath: hopwatchDir.path) {
            return hopwatchDir
        }
        let legacyDir = URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent("net-diag", isDirectory: true)
        if fm.fileExists(atPath: legacyDir.path) {
            return legacyDir
        }
        return hopwatchDir
    }

    /// Computes a deterministic fingerprint for the current JSONL store and CLI
    /// build. Returns `nil` when `cliVersion` or `binaryPath` is unavailable,
    /// or when running outside an app bundle without an explicit test directory.
    static func currentFingerprint(
        logDirectory: URL = resolveLogDirectory(),
        cliVersion: String?,
        binaryPath: String?
    ) -> String? {
        guard let cliVersion, !cliVersion.isEmpty,
              let binaryPath, !binaryPath.isEmpty else {
            return nil
        }
        let liveURL = logDirectory.appendingPathComponent("baseline.jsonl", isDirectory: false)
        let archiveURL = logDirectory.appendingPathComponent("baseline-archive.jsonl", isDirectory: false)
        let liveStamp = fileStamp(at: liveURL)
        let archiveStamp = fileStamp(at: archiveURL)
        return "v=\(cliVersion)|bin=\(binaryPath)|live=\(liveStamp)|arch=\(archiveStamp)"
    }

    private static func fileStamp(at url: URL) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return "absent"
        }
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size):\(String(format: "%.6f", mtime))"
    }

    /// Default Application Support cache directory for the running app bundle.
    /// Returns `nil` when unbundled (e.g. `swift test`) unless callers inject an
    /// explicit temporary directory.
    static func defaultCacheDirectory() -> URL? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        return appSupport
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.godigi.hopwatch", isDirectory: true)
            .appendingPathComponent("cli-cache-v1", isDirectory: true)
    }

    // MARK: - History document cache

    static func readHistory(in directory: URL?, expectedFingerprint: String) -> Data? {
        guard let directory else { return nil }
        let metaURL = directory.appendingPathComponent("history-doc.meta", isDirectory: false)
        let dataURL = directory.appendingPathComponent("history-doc.json", isDirectory: false)
        guard let stored = try? String(contentsOf: metaURL, encoding: .utf8),
              stored == expectedFingerprint,
              let data = try? Data(contentsOf: dataURL),
              !data.isEmpty else {
            return nil
        }
        return data
    }

    static func writeHistory(_ data: Data, fingerprint: String, in directory: URL?) {
        guard let directory, !data.isEmpty else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let dataURL = directory.appendingPathComponent("history-doc.json", isDirectory: false)
        let metaURL = directory.appendingPathComponent("history-doc.meta", isDirectory: false)
        do {
            try data.write(to: dataURL, options: .atomic)
            try fingerprint.write(to: metaURL, atomically: true, encoding: .utf8)
        } catch {
            log.debug("failed to persist history disk cache: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Run detail cache

    private static func detailKey(for id: String) -> String {
        let digest = SHA256.hash(data: Data(id.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func readRunDetail(id: String, in directory: URL?, expectedFingerprint: String) -> String? {
        guard let directory else { return nil }
        let dir = directory.appendingPathComponent("run-details", isDirectory: true)
        let key = detailKey(for: id)
        let metaURL = dir.appendingPathComponent("\(key).meta", isDirectory: false)
        let jsonURL = dir.appendingPathComponent("\(key).json", isDirectory: false)
        guard let stored = try? String(contentsOf: metaURL, encoding: .utf8),
              stored == expectedFingerprint,
              let raw = try? String(contentsOf: jsonURL, encoding: .utf8),
              !raw.isEmpty else {
            return nil
        }
        return raw
    }

    static func writeRunDetail(_ rawJSON: String, id: String, fingerprint: String, in directory: URL?) {
        guard let directory, !rawJSON.isEmpty else { return }
        let dir = directory.appendingPathComponent("run-details", isDirectory: true)
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let key = detailKey(for: id)
        let jsonURL = dir.appendingPathComponent("\(key).json", isDirectory: false)
        let metaURL = dir.appendingPathComponent("\(key).meta", isDirectory: false)
        do {
            try rawJSON.write(to: jsonURL, atomically: true, encoding: .utf8)
            try fingerprint.write(to: metaURL, atomically: true, encoding: .utf8)
            pruneRunDetails(in: dir, keeping: maxRunDetailEntries)
        } catch {
            log.debug("failed to persist run detail cache: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func pruneRunDetails(in dir: URL, keeping limit: Int) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let jsonFiles = entries.filter { $0.pathExtension == "json" }
        guard jsonFiles.count > limit else { return }

        let sorted = jsonFiles.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da > db
        }
        for stale in sorted.dropFirst(limit) {
            try? fm.removeItem(at: stale)
            let meta = stale.deletingPathExtension().appendingPathExtension("meta")
            try? fm.removeItem(at: meta)
        }
    }
}
