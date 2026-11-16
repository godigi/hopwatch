import Testing
import Foundation
import SwiftUI
@testable import HopwatchGUI

@Suite("WhatsNewTests")
struct WhatsNewTests {

    @Test("curated highlights contains expected 6 features")
    func curatedHighlightsContainsExpectedFeatures() {
        let content = WhatsNewContent.curatedHighlights(version: "1.17.1")

        #expect(content.version == "1.17.1")
        #expect(content.cleanVersion == "1.17.1")
        #expect(content.displayVersion == "v1.17.1")
        #expect(content.title == "What’s New in Hopwatch v1.17.1")
        #expect(content.subtitle == "Here is what changed in this version")
        #expect(content.features.count == 6)
        #expect(content.isCuratedFallback == true)

        // 1. Plain English Mode
        let f1 = content.features[0]
        #expect(f1.title == "Plain English Mode")
        #expect(f1.description == "Understand network diagnostics in plain language.")
        #expect(!f1.icon.isEmpty)

        // 2. Global Shortcut
        let f2 = content.features[1]
        #expect(f2.title == "Global Shortcut (⌥⌘N)")
        #expect(f2.description == "Summon the Hopwatch menu bar popup from anywhere with a single keystroke.")
        #expect(!f2.icon.isEmpty)

        // 3. Dynamic Menu Bar
        let f3 = content.features[2]
        #expect(f3.title == "Dynamic Menu Bar")
        #expect(f3.description == "Minimal dot that expands with latency and packet loss only when degraded.")
        #expect(!f3.icon.isEmpty)

        // 4. Audio Chimes
        let f4 = content.features[3]
        #expect(f4.title == "Audio Chimes")
        #expect(f4.description == "Audible alert when your connection drops and when it recovers.")
        #expect(!f4.icon.isEmpty)

        // 5. Zero-Wait Updates
        let f5 = content.features[4]
        #expect(f5.title == "Zero-Wait Updates")
        #expect(f5.description == "Background update pre-caching and instant restart.")
        #expect(!f5.icon.isEmpty)

        // 6. 1-Click IT Dispatch
        let f6 = content.features[5]
        #expect(f6.title == "1-Click IT Dispatch")
        #expect(f6.description == "Easily copy clean, formatted support summaries for front desks and helpdesks.")
        #expect(!f6.icon.isEmpty)
    }

    @Test("current content default version loads real changelog")
    func currentContentDefaultVersion() {
        let content = WhatsNewContent.current()
        #expect(content.version == Defaults.appVersion)
        #expect(!content.displayVersion.isEmpty)
        #expect(content.title.contains("What’s New in Hopwatch"))
        #expect(!content.features.isEmpty)
        #expect(content.isCuratedFallback == false)
    }

    @Test("current content loads actual changelog section for 1.23.1")
    func currentContentLoadsChangelogFor1231() {
        let content = WhatsNewContent.current(version: "1.23.1")
        #expect(content.cleanVersion == "1.23.1")
        #expect(content.displayVersion == "v1.23.1")
        #expect(content.title == "What’s New in Hopwatch v1.23.1")
        #expect(content.subtitle.contains("November 7, 2026"))
        #expect(!content.features.isEmpty)
        #expect(content.isCuratedFallback == false)

        // Real changelog items from 1.23.1
        let first = content.features.first
        #expect(first?.title == "Automatic Arrival Full Check Recovery on Unhealthy Link Clearance")
        #expect(first?.category == "Fix")
        #expect(first?.description.contains("Hopwatch now automatically retries the full check") == true)
    }

    @Test("current content loads actual changelog section for 1.23.0")
    func currentContentLoadsChangelogFor1230() {
        let content = WhatsNewContent.current(version: "1.23.0")
        #expect(content.cleanVersion == "1.23.0")
        #expect(content.subtitle.contains("November 1, 2026"))
        #expect(content.isCuratedFallback == false)

        // Verify feature categorization
        let addedFeature = content.features.first(where: { $0.title == "Smart Battery-Saver Cadence" })
        #expect(addedFeature != nil)
        #expect(addedFeature?.category == "New")
        #expect(addedFeature?.icon == "battery.100.bolt")
    }

    @Test("version string formatting handles prefixes and empty strings")
    func versionFormatting() {
        let vPrefixed = WhatsNewContent.current(version: "v1.18.0")
        #expect(vPrefixed.cleanVersion == "1.18.0")
        #expect(vPrefixed.displayVersion == "v1.18.0")
        #expect(vPrefixed.title == "What’s New in Hopwatch v1.18.0")

        let vClean = WhatsNewContent.current(version: "1.18.0")
        #expect(vClean.cleanVersion == "1.18.0")
        #expect(vClean.displayVersion == "v1.18.0")
        #expect(vClean.title == "What’s New in Hopwatch v1.18.0")

        let vEmpty = WhatsNewContent(version: "", features: [])
        #expect(vEmpty.cleanVersion.isEmpty)
        #expect(vEmpty.displayVersion.isEmpty)
        #expect(vEmpty.title == "What’s New in Hopwatch")
    }

    @Test("release notes parser extracts markdown bullets and descriptions")
    func releaseNotesParsing() {
        let notes = """
        ## What's Changed
        * Audio Chimes: Audible sound cues when connection status shifts.
        * Dynamic Menu Bar - Adaptive display in the macOS status bar.
        * 1-Click IT Dispatch: Formatted diagnostics summary for support desks.
        """

        let content = WhatsNewContent.parse(releaseNotes: notes, version: "1.18.0")
        #expect(content.version == "1.18.0")
        #expect(content.features.count == 3)

        #expect(content.features[0].title == "Audio Chimes")
        #expect(content.features[0].description == "Audible sound cues when connection status shifts.")
        #expect(content.features[0].icon == "speaker.wave.2.fill")

        #expect(content.features[1].title == "Dynamic Menu Bar")
        #expect(content.features[1].description == "Adaptive display in the macOS status bar.")
        #expect(content.features[1].icon == "menubar.arrow.up.rectangle")

        #expect(content.features[2].title == "1-Click IT Dispatch")
        #expect(content.features[2].description == "Formatted diagnostics summary for support desks.")
        #expect(content.features[2].icon == "doc.text.fill")
    }

    @Test("markdown cleaning removes bold, code backticks, links, and commit prefixes")
    func markdownCleaning() {
        let input = "fix(core): **Router Discovery**: Check `arp -an` and [read docs](https://example.com) (#42) by @alice in https://github.com"
        let cleaned = WhatsNewContent.cleanMarkdown(input)
        #expect(cleaned == "Router Discovery: Check arp -an and read docs")
    }

    @Test("date formatting converts ISO date to friendly English date")
    func dateFormatting() {
        #expect(WhatsNewContent.formatReleaseDate("2026-11-07") == "November 7, 2026")
        #expect(WhatsNewContent.formatReleaseDate("2026-01-15") == "January 15, 2026")
        #expect(WhatsNewContent.formatReleaseDate("invalid-date") == "invalid-date")
    }

    @Test("changelog reader extracts specific section from raw changelog")
    func changelogReaderSectionExtraction() {
        let sample = """
        # Changelog

        ## [2.0.0] - 2026-12-01

        ### Added
        - **Major Feature**: Exciting new capability.

        ## [1.0.0] - 2026-01-01

        ### Fixed
        - Bug fix item.
        """

        let section2 = ChangelogReader.section(for: "2.0.0", in: sample)
        #expect(section2?.version == "2.0.0")
        #expect(section2?.date == "2026-12-01")
        #expect(section2?.content.contains("Major Feature") == true)

        let section1 = ChangelogReader.section(for: "1.0.0", in: sample)
        #expect(section1?.version == "1.0.0")
        #expect(section1?.date == "2026-01-01")
        #expect(section1?.content.contains("Bug fix item") == true)

        let nonexistent = ChangelogReader.section(for: "9.9.9", in: sample)
        #expect(nonexistent == nil)
    }

    @Test("changelog reader lists available released versions in chronological order")
    func changelogReaderAvailableVersions() {
        let sample = """
        # Changelog

        ## [Unreleased]
        - Pending work

        ## [2.1.0] - 2026-12-10
        - Feature 2

        ## [2.0.0] - 2026-11-20
        - Feature 1
        """

        let versions = ChangelogReader.availableVersions(in: sample)
        #expect(versions.count == 2)
        #expect(versions[0].version == "2.1.0")
        #expect(versions[0].date == "2026-12-10")
        #expect(versions[1].version == "2.0.0")
        #expect(versions[1].date == "2026-11-20")
    }

    @Test("summary and details splitter splits multi-sentence descriptions")
    func summaryAndDetailsSplitter() {
        let longText = "First important sentence that gives users a quick takeaway. Second sentence with deep technical detail that explains the exact underlying mechanism and parameters."
        let (summary, details) = WhatsNewContent.splitSummaryAndDetails(longText)

        #expect(summary == "First important sentence that gives users a quick takeaway.")
        #expect(details != nil)
        #expect(details?.contains("Second sentence") == true)

        // Abbreviation test (e.g. should not be split)
        let abbrText = "Feature handling various scenarios (e.g. low latency or packet loss) properly. More technical details follow here in the second sentence."
        let (abbrSummary, abbrDetails) = WhatsNewContent.splitSummaryAndDetails(abbrText)
        #expect(abbrSummary.contains("(e.g. low latency or packet loss)"))
        #expect(abbrDetails != nil)

        let shortText = "Quick simple fix."
        let (shortSummary, shortDetails) = WhatsNewContent.splitSummaryAndDetails(shortText)
        #expect(shortSummary == "Quick simple fix.")
        #expect(shortDetails == nil)
    }

    @Test("markdown generation formats clean structured notes for clipboard")
    func toMarkdownFormatting() {
        let feature1 = WhatsNewFeature(icon: "wifi", color: .blue, title: "Wi-Fi Polish", description: "Better mesh handoffs.", category: "New")
        let feature2 = WhatsNewFeature(icon: "wrench", color: .green, title: "Crash Fix", description: "Resolved nil unwrap.", category: "Fix")

        let content = WhatsNewContent(
            version: "2.0.0",
            releaseDate: "2026-11-07",
            features: [feature1, feature2]
        )

        let md = content.toMarkdown()
        #expect(md.contains("# What’s New in Hopwatch v2.0.0 (November 7, 2026)"))
        #expect(md.contains("### Added"))
        #expect(md.contains("- **Wi-Fi Polish**: Better mesh handoffs."))
        #expect(md.contains("### Fixed"))
        #expect(md.contains("- **Crash Fix**: Resolved nil unwrap."))
    }

    @Test("release notes parser falls back to curated highlights if notes are empty")
    func releaseNotesEmptyFallback() {
        let emptyNotes = """
        # Release Notes

        
        """
        let content = WhatsNewContent.current(version: "99.99.99", releaseNotes: emptyNotes)
        #expect(content.features.count == 6)
        #expect(content.features[0].title == "Plain English Mode")
        #expect(content.isCuratedFallback == true)
    }

    @Test("feature model properties and identity")
    func featureModelProperties() {
        let feature = WhatsNewFeature(
            icon: "star.fill",
            color: .yellow,
            title: "Super Feature",
            description: "Does amazing things.",
            category: "New"
        )

        #expect(feature.id == "Super Feature")
        #expect(feature.icon == "star.fill")
        #expect(feature.title == "Super Feature")
        #expect(feature.description == "Does amazing things.")
        #expect(feature.category == "New")

        let customIDFeature = WhatsNewFeature(
            id: "custom-id",
            icon: "star.fill",
            color: .yellow,
            title: "Super Feature",
            description: "Does amazing things."
        )
        #expect(customIDFeature.id == "custom-id")
        #expect(customIDFeature.category == nil)
    }

    @Test("view instantiation and dismissal callback")
    func viewInstantiationAndDismiss() {
        var didDismiss = false
        let view = WhatsNewView(
            content: .curatedHighlights(version: "1.17.1"),
            dismissButtonTitle: "Continue",
            onDismiss: { didDismiss = true }
        )

        #expect(view.dismissButtonTitle == "Continue")

        view.onDismiss()
        #expect(didDismiss == true)
    }
}
