import Foundation
import Testing
@testable import HopwatchGUI

@Suite struct DiagnosticReportSharingTests {

    @Test func generatesExpectedFileNames() {
        let mdName = DiagnosticReportSharing.defaultFileName(extension: "md", timestamp: "2026-08-25T12:00:00Z")
        #expect(mdName == "netdiag-report-2026-08-25-120000.md")

        let jsonName = DiagnosticReportSharing.defaultFileName(extension: "json", timestamp: "2026-08-25T12:00:00Z")
        #expect(jsonName == "netdiag-report-2026-08-25-120000.json")

        let nowName = DiagnosticReportSharing.defaultFileName(extension: "md", timestamp: nil)
        #expect(nowName.hasPrefix("netdiag-report-"))
        #expect(nowName.hasSuffix(".md"))

        let emptyTsName = DiagnosticReportSharing.defaultFileName(extension: "json", timestamp: "")
        #expect(emptyTsName.hasPrefix("netdiag-report-"))
        #expect(emptyTsName.hasSuffix(".json"))
    }

    @Test func redactsSharedTextAndJSON() async throws {
        // Only run child process test if netdiag binary is resolvable
        guard let _ = BinaryLocator.resolve() else { return }

        let sampleJSON = """
        {
          "timestamp": "2026-08-25T12:00:00Z",
          "run_id": "2026-08-25-120000",
          "network": {"id": "wifi:ssid=MySecretWiFi,mac=aa:bb:cc:dd:ee:ff"},
          "interface": {"name": "en0", "type": "Wi-Fi", "ip": "192.168.1.50"},
          "public": {"ip": "198.51.100.22", "city": "Springfield", "country": "US"}
        }
        """

        let sharedText = try await NetdiagRunner.share(rawJSON: sampleJSON)
        #expect(!sharedText.contains("198.51.100.22"))
        #expect(!sharedText.contains("MySecretWiFi"))
        #expect(!sharedText.contains("Springfield"))

        let sharedJSON = try await NetdiagRunner.shareJSON(rawJSON: sampleJSON)
        #expect(!sharedJSON.contains("198.51.100.22"))
        #expect(!sharedJSON.contains("MySecretWiFi"))
        #expect(!sharedJSON.contains("Springfield"))
        #expect(sharedJSON.contains("[redacted]"))
    }
}
