import Testing
import Foundation
@testable import NetdiagGUI

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
        #expect(target.path.hasSuffix("Netdiag.app"))
    }
}
