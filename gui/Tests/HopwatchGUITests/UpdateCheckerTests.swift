import Testing
import Foundation
@testable import HopwatchGUI

@Suite("UpdateCheckerTests")
struct UpdateCheckerTests {

    @Test("semantic version parsing and ordering")
    func semanticVersionOrdering() {
        let v0_14_0 = SemanticVersion("0.14.0")
        let v0_14_1 = SemanticVersion("v0.14.1")
        let v0_15_0 = SemanticVersion("V0.15.0")
        let v1_0_0 = SemanticVersion("1.0.0")

        #expect(v0_14_0 < v0_14_1)
        #expect(v0_14_1 < v0_15_0)
        #expect(v0_15_0 < v1_0_0)
        #expect(SemanticVersion("v0.14.0") == v0_14_0)
        #expect(v1_0_0 > v0_15_0)

        // Pre-release or malformed tails
        let vWithTail = SemanticVersion("0.14.0-beta.1")
        #expect(vWithTail == v0_14_0)
    }

    @Test("github release JSON decoding and short notes extraction")
    func releaseDecodingAndNotes() throws {
        let json = """
        {
            "tag_name": "v0.15.0",
            "name": "Netdiag 0.15.0 - Network Memory & Faster Scans",
            "body": "## What's Changed\\n* Added Network Memory historical comparisons\\n* Polished auto updater",
            "html_url": "https://github.com/godigi/netdiag/releases/tag/v0.15.0",
            "assets": [
                {
                    "id": 12345,
                    "name": "Netdiag-0.15.0.dmg",
                    "browser_download_url": "https://github.com/godigi/netdiag/releases/download/v0.15.0/Netdiag-0.15.0.dmg",
                    "size": 14500000,
                    "content_type": "application/x-apple-diskimage"
                },
                {
                    "id": 12346,
                    "name": "checksums.txt",
                    "browser_download_url": "https://github.com/godigi/netdiag/releases/download/v0.15.0/checksums.txt",
                    "size": 256,
                    "content_type": "text/plain"
                }
            ]
        }
        """

        let decoder = JSONDecoder()
        let release = try decoder.decode(GitHubRelease.self, from: json.data(using: .utf8)!)

        #expect(release.cleanVersion == "0.15.0")
        #expect(release.assets.count == 2)
        #expect(release.assets[0].isInstallableArchive)
        #expect(!release.assets[1].isInstallableArchive)
        #expect(release.shortReleaseNotes == "* Added Network Memory historical comparisons")
    }

    @Test("target app URL resolution")
    @MainActor
    func targetAppURLResolution() {
        let checker = UpdateChecker()
        let target = checker.targetAppURL
        #expect(target.path.hasSuffix("Netdiag.app") || target.path.hasSuffix("Hopwatch.app"))
    }

    @Test("asset selection prefers zip archive over dmg")
    func assetSelectionPrefersZip() throws {
        let json = """
        {
            "tag_name": "v1.2.1",
            "assets": [
                {
                    "id": 1,
                    "name": "Netdiag-1.2.1.dmg",
                    "browser_download_url": "https://example.com/Netdiag-1.2.1.dmg"
                },
                {
                    "id": 2,
                    "name": "Netdiag-1.2.1.zip",
                    "browser_download_url": "https://example.com/Netdiag-1.2.1.zip"
                }
            ]
        }
        """
        let decoder = JSONDecoder()
        let release = try decoder.decode(GitHubRelease.self, from: json.data(using: .utf8)!)

        let chosen = release.assets.first(where: { $0.name.lowercased().hasSuffix(".zip") })
            ?? release.assets.first(where: { $0.isInstallableArchive })

        #expect(chosen?.name == "Netdiag-1.2.1.zip")
        #expect(chosen?.browserDownloadUrl.absoluteString == "https://example.com/Netdiag-1.2.1.zip")
    }

    @Test("notification manager delivers update notifications")
    @MainActor
    func notificationManagerUpdateDelivery() {
        let nm = NotificationManager(notificationsEnabled: true, scope: .all)
        nm.setAuthorizedForTesting(true)

        var deliveredID: String?
        var deliveredTitle: String?
        var deliveredBody: String?
        nm.onPostNotification = { id, title, body, _ in
            deliveredID = id
            deliveredTitle = title
            deliveredBody = body
        }

        let sent = nm.deliverUpdateNotification(version: "1.2.1", shortNotes: "Fix latency jitter")
        #expect(sent == true)
        #expect(deliveredID == "netdiag.update.1.2.1")
        #expect(deliveredTitle == "netdiag Update Available")
        #expect(deliveredBody?.contains("1.2.1") == true)
        #expect(deliveredBody?.contains("Fix latency jitter") == true)
    }
}
