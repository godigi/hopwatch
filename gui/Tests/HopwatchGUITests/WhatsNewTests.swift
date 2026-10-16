import Testing
import Foundation
import SwiftUI
@testable import HopwatchGUI

@Suite("WhatsNewTests")
struct WhatsNewTests {

    @Test("curated highlights for current release contains expected 5 features")
    func currentContentCuratedHighlights() {
        let content = WhatsNewContent.current(version: "1.17.1")

        #expect(content.version == "1.17.1")
        #expect(content.cleanVersion == "1.17.1")
        #expect(content.displayVersion == "v1.17.1")
        #expect(content.title == "What’s New in Hopwatch v1.17.1")
        #expect(content.subtitle == "Here is what changed in this version")
        #expect(content.features.count == 6)

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

    @Test("current content default version uses Defaults.appVersion")
    func currentContentDefaultVersion() {
        let content = WhatsNewContent.current()
        #expect(content.version == Defaults.appVersion)
        #expect(!content.displayVersion.isEmpty)
        #expect(content.title.contains("What’s New in Hopwatch"))
        #expect(content.features.count == 6)
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

    @Test("release notes parser falls back to curated highlights if notes are empty")
    func releaseNotesEmptyFallback() {
        let emptyNotes = """
        # Release Notes

        
        """
        let content = WhatsNewContent.current(version: "1.17.1", releaseNotes: emptyNotes)
        #expect(content.features.count == 6)
        #expect(content.features[0].title == "Plain English Mode")
    }

    @Test("feature model properties and identity")
    func featureModelProperties() {
        let feature = WhatsNewFeature(
            icon: "star.fill",
            color: .yellow,
            title: "Super Feature",
            description: "Does amazing things."
        )

        #expect(feature.id == "Super Feature")
        #expect(feature.icon == "star.fill")
        #expect(feature.title == "Super Feature")
        #expect(feature.description == "Does amazing things.")

        let customIDFeature = WhatsNewFeature(
            id: "custom-id",
            icon: "star.fill",
            color: .yellow,
            title: "Super Feature",
            description: "Does amazing things."
        )
        #expect(customIDFeature.id == "custom-id")
    }

    @Test("view instantiation and dismissal callback")
    func viewInstantiationAndDismiss() {
        var didDismiss = false
        let view = WhatsNewView(
            content: .current(version: "1.17.1"),
            dismissButtonTitle: "Continue",
            onDismiss: { didDismiss = true }
        )

        #expect(view.content.version == "1.17.1")
        #expect(view.dismissButtonTitle == "Continue")

        view.onDismiss()
        #expect(didDismiss == true)
    }
}
