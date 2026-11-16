import Foundation
import Testing
@testable import HopwatchGUI

@Suite struct StoreDiskCacheAndCapabilitiesTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HopwatchStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func capabilityProbeDistinguishesMissingBash5FromLegacyCLI() {
        let bash5 = CapabilityStore.classifyCapabilitiesResult(
            stdout: "",
            stderr: "hopwatch: requires bash 5+. Install with: brew install bash\n",
            status: 3
        )
        if case .missingBash5 = bash5 {
            // Expected
        } else {
            Issue.record("Expected .missingBash5, got \(String(describing: bash5))")
        }

        let legacy = CapabilityStore.classifyCapabilitiesResult(
            stdout: "",
            stderr: "hopwatch: unknown flag --capabilities\n",
            status: 3
        )
        #expect(legacy == nil, "Unknown flag exit 3 should fall back to legacy --progress probe")
    }

    @Test func bash5ErrorMessageGuidesBrewInstall() {
        let msg = HopwatchError.bash5Required.localizedDescription
        #expect(msg.contains("Bash 5"))
        #expect(msg.contains("brew install bash"))
    }

    @Test func historyAndRunDetailDiskCacheRespectStoreFingerprint() throws {
        let dir = try makeTempDir()
        let logDir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: logDir)
        }

        let liveFile = logDir.appendingPathComponent("baseline.jsonl")
        try Data("{\"id\":\"run-1\"}\n".utf8).write(to: liveFile)

        let fp1 = StoreDiskCache.currentFingerprint(
            logDirectory: logDir,
            cliVersion: "1.23.1",
            binaryPath: "/Applications/Hopwatch.app/Contents/Resources/cli/bin/hopwatch"
        )
        let unwrapped1 = try #require(fp1)

        let historyBytes = Data("{\"schema\":2}".utf8)
        StoreDiskCache.writeHistory(historyBytes, fingerprint: unwrapped1, in: dir)
        #expect(StoreDiskCache.readHistory(in: dir, expectedFingerprint: unwrapped1) == historyBytes)

        let detailJSON = "{\"schema\":1,\"id\":\"run-1\"}"
        StoreDiskCache.writeRunDetail(detailJSON, id: "run-1", fingerprint: unwrapped1, in: dir)
        #expect(StoreDiskCache.readRunDetail(id: "run-1", in: dir, expectedFingerprint: unwrapped1) == detailJSON)

        // Appending a new record to baseline.jsonl changes size and invalidates both caches.
        try Data("{\"id\":\"run-1\"}\n{\"id\":\"run-2\"}\n".utf8).write(to: liveFile)
        let fp2 = try #require(StoreDiskCache.currentFingerprint(
            logDirectory: logDir,
            cliVersion: "1.23.1",
            binaryPath: "/Applications/Hopwatch.app/Contents/Resources/cli/bin/hopwatch"
        ))
        #expect(fp2 != unwrapped1)
        #expect(StoreDiskCache.readHistory(in: dir, expectedFingerprint: fp2) == nil)
        #expect(StoreDiskCache.readRunDetail(id: "run-1", in: dir, expectedFingerprint: fp2) == nil)
    }

    @Test func logDirectoryResolutionPrefersHopwatchOverLegacyNetDiag() throws {
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }

        let legacy = home.appendingPathComponent("net-diag", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        #expect(
            StoreDiskCache.resolveLogDirectory(environment: [:], homeDirectory: home.path).lastPathComponent
                == "net-diag"
        )

        let modern = home.appendingPathComponent("hopwatch", isDirectory: true)
        try FileManager.default.createDirectory(at: modern, withIntermediateDirectories: true)
        #expect(
            StoreDiskCache.resolveLogDirectory(environment: [:], homeDirectory: home.path).lastPathComponent
                == "hopwatch"
        )

        let overrideDir = home.appendingPathComponent("custom-dir", isDirectory: true)
        #expect(
            StoreDiskCache.resolveLogDirectory(
                environment: ["HOPWATCH_LOG_DIR": overrideDir.path],
                homeDirectory: home.path
            ).path == overrideDir.path
        )
    }
}
