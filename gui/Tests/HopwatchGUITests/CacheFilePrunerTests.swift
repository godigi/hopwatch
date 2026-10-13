import Foundation
import Testing
@testable import HopwatchGUI

@Suite struct CacheFilePrunerTests {

    /// A fresh directory under the system temp dir; never Application Support.
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CacheFilePrunerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func touch(_ name: String, in dir: URL) throws {
        try Data("{}".utf8).write(to: dir.appendingPathComponent(name))
    }

    private func names(in dir: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
    }

    @Test func removesOldVersionsOfBothKindsAndKeepsCurrent() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for v in ["1.0.0", "1.1.0", "2.0.0"] {
            try touch("rules-catalog-\(v).json", in: dir)
            try touch("signal-scale-\(v).json", in: dir)
        }
        let removed = CacheFilePruner.prune(in: dir, keeping: "2.0.0")
        #expect(removed.count == 4)
        #expect(try names(in: dir) == ["rules-catalog-2.0.0.json", "signal-scale-2.0.0.json"])
    }

    @Test func leavesNonMatchingFilesAndDirectoriesAlone() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let untouched = [
            "rules-catalog-2.0.0.json.bak", "rules-catalog-old.json.bak",
            "rules-catalog-.json", "rules-catalog.json", "signal-scale.json",
            "xrules-catalog-1.0.0.json", "settings.json", "rules-catalog-1.0.0.txt",
        ]
        for n in untouched { try touch(n, in: dir) }
        // A directory whose name matches the pattern must survive too.
        let sub = dir.appendingPathComponent("rules-catalog-0.9.0.json", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try touch("inner.json", in: sub)
        try touch("rules-catalog-1.0.0.json", in: dir)

        let removed = CacheFilePruner.prune(in: dir, keeping: "2.0.0")
        #expect(removed == ["rules-catalog-1.0.0.json"])
        #expect(try names(in: dir) == Set(untouched + ["rules-catalog-0.9.0.json"]))
        #expect(FileManager.default.fileExists(atPath: sub.appendingPathComponent("inner.json").path))
    }

    @Test func doesNotFollowOrRemoveSymlinks() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: target) }
        try touch("precious.json", in: target)
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("signal-scale-0.1.0.json"),
            withDestinationURL: target.appendingPathComponent("precious.json"))

        let removed = CacheFilePruner.prune(in: dir, keeping: "2.0.0")
        #expect(removed.isEmpty)
        #expect(try names(in: dir) == ["signal-scale-0.1.0.json"])
        #expect(try names(in: target) == ["precious.json"])
    }

    @Test func missingDirectoryDoesNotCrash() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("CacheFilePrunerTests-missing-\(UUID().uuidString)", isDirectory: true)
        #expect(CacheFilePruner.prune(in: missing, keeping: "1.0.0").isEmpty)
    }
}
