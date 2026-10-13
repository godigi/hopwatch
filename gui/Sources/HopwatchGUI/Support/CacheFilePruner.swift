import Foundation
import os

/// Keeps the per-version CLI caches in Application Support from piling up.
///
/// `RulesCatalogStore` and `SignalScaleStore` each write one file per CLI
/// version (`rules-catalog-<version>.json`, `signal-scale-<version>.json`)
/// and, before this, never removed any, so every upgrade left two more
/// behind. Only the current version's file of each kind is ever read again
/// (a different CLI version has its own file written on first use), so
/// everything else of that shape is dead weight.
///
/// Deliberately narrow: a file is only touched when its name is exactly
/// `<kind>-<non-empty anything>.json`, it is a regular file (a symlink or
/// directory is left alone and never followed), and it is not the current
/// version's file of that kind. `rules-catalog-1.2.3.json.bak`, unrelated
/// files and subdirectories are never candidates. Pure and failure-tolerant:
/// a missing directory or an undeletable file is logged and skipped, never
/// thrown.
enum CacheFilePruner {

    private static let log = Logger(subsystem: "com.godigi.hopwatch", category: "cacheprune")

    /// The file-name prefixes this pruner owns, one per cache kind.
    static let kinds: [String] = ["rules-catalog-", "signal-scale-"]

    private static let suffix = ".json"

    /// Delete every stale `rules-catalog-*.json` / `signal-scale-*.json` in
    /// `directory`, keeping only `rules-catalog-<version>.json` and
    /// `signal-scale-<version>.json`. Returns the names removed (empty when
    /// the directory is missing or nothing was stale).
    @discardableResult
    static func prune(in directory: URL, keeping version: String) -> [String] {
        let fm = FileManager.default
        let names: [String]
        do {
            names = try fm.contentsOfDirectory(atPath: directory.path)
        } catch {
            // Missing directory is the normal first-launch case.
            return []
        }

        var removed: [String] = []
        for name in names where isCacheFileName(name) {
            let keep = kinds.contains { name == "\($0)\(version)\(suffix)" }
            if keep { continue }

            let url = directory.appendingPathComponent(name, isDirectory: false)
            // attributesOfItem does not follow symlinks, so a link (or a
            // directory) that happens to carry a matching name is skipped.
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  (attrs[.type] as? FileAttributeType) == .typeRegular else { continue }
            do {
                try fm.removeItem(at: url)
                removed.append(name)
            } catch {
                log.error("could not prune \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        if !removed.isEmpty {
            log.debug("pruned \(removed.count) stale cache file(s), kept version \(version, privacy: .public)")
        }
        return removed
    }

    /// `<kind>-<at least one character>.json`, nothing else.
    private static func isCacheFileName(_ name: String) -> Bool {
        guard name.hasSuffix(suffix) else { return false }
        return kinds.contains { name.hasPrefix($0) && name.count > $0.count + suffix.count }
    }
}
