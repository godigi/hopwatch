import SwiftUI
import Foundation

/// A single feature highlight displayed in the "What's New" sheet.
struct WhatsNewFeature: Identifiable, Sendable, Equatable, Hashable {
    let id: String
    let icon: String
    let color: Color
    let title: String
    let description: String

    init(
        id: String? = nil,
        icon: String,
        color: Color,
        title: String,
        description: String
    ) {
        self.id = id ?? title
        self.icon = icon
        self.color = color
        self.title = title
        self.description = description
    }
}

/// Content payload backing the "What's New" presentation for a given Hopwatch release.
struct WhatsNewContent: Equatable, Sendable {
    let version: String
    let subtitle: String
    let features: [WhatsNewFeature]

    /// Clean version tag without prefix (e.g. "1.17.1").
    var cleanVersion: String {
        version.trimmingCharacters(in: CharacterSet(charactersIn: "vV \t\r\n"))
    }

    /// Display version string (e.g. "v1.17.1").
    var displayVersion: String {
        let clean = cleanVersion
        return clean.isEmpty ? "" : "v\(clean)"
    }

    /// Formatted header title (e.g. "What's New in Hopwatch v1.17.1").
    var title: String {
        let display = displayVersion
        return display.isEmpty ? "What’s New in Hopwatch" : "What’s New in Hopwatch \(display)"
    }

    init(
        version: String,
        subtitle: String = "Here is what changed in this version",
        features: [WhatsNewFeature]
    ) {
        self.version = version
        self.subtitle = subtitle
        self.features = features
    }

    /// Curated release highlights for the current release or parsed release notes.
    static func current(
        version: String = Defaults.appVersion,
        releaseNotes: String? = nil
    ) -> WhatsNewContent {
        if let releaseNotes, !releaseNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return parse(releaseNotes: releaseNotes, version: version)
        }

        return WhatsNewContent(
            version: version,
            subtitle: "Here is what changed in this version",
            features: [
                WhatsNewFeature(
                    icon: "text.bubble.fill",
                    color: Theme.ColorToken.blue,
                    title: "Plain English Mode",
                    description: "Understand network diagnostics in plain language."
                ),
                WhatsNewFeature(
                    icon: "keyboard.fill",
                    color: Color.purple,
                    title: "Global Shortcut (⌥⌘N)",
                    description: "Summon the Hopwatch menu bar popup from anywhere with a single keystroke."
                ),
                WhatsNewFeature(
                    icon: "menubar.arrow.up.rectangle",
                    color: Theme.ColorToken.green,
                    title: "Dynamic Menu Bar",
                    description: "Minimal dot that expands with latency and packet loss only when degraded."
                ),
                WhatsNewFeature(
                    icon: "speaker.wave.2.fill",
                    color: Theme.ColorToken.amber,
                    title: "Audio Chimes",
                    description: "Audible alert when your connection drops and when it recovers."
                ),
                WhatsNewFeature(
                    icon: "arrow.triangle.2.circlepath.circle.fill",
                    color: Theme.ColorToken.blue,
                    title: "Zero-Wait Updates",
                    description: "Background update pre-caching and instant restart."
                ),
                WhatsNewFeature(
                    icon: "doc.text.fill",
                    color: Theme.ColorToken.green,
                    title: "1-Click IT Dispatch",
                    description: "Easily copy clean, formatted support summaries for front desks and helpdesks."
                )
            ]
        )
    }

    /// Parses release notes text (e.g. GitHub release body or CHANGELOG bullets) into structured features.
    static func parse(releaseNotes: String, version: String = Defaults.appVersion) -> WhatsNewContent {
        let lines = releaseNotes.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        var parsed: [WhatsNewFeature] = []

        let defaultPalette: [(icon: String, color: Color)] = [
            ("sparkles", Theme.ColorToken.blue),
            ("bolt.fill", Theme.ColorToken.amber),
            ("checkmark.seal.fill", Theme.ColorToken.green),
            ("arrow.triangle.2.circlepath.circle.fill", Theme.ColorToken.blue),
            ("speedometer", Theme.ColorToken.green),
            ("waveform.path.ecg", Theme.ColorToken.blue)
        ]

        for (index, line) in lines.enumerated() {
            var raw = line
            if raw.hasPrefix("* ") || raw.hasPrefix("- ") || raw.hasPrefix("• ") {
                raw = String(raw.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            } else if let match = raw.range(of: #"^\d+\.\s*"#, options: .regularExpression) {
                raw = String(raw[match.upperBound...]).trimmingCharacters(in: .whitespaces)
            }

            guard !raw.isEmpty else { continue }

            let title: String
            let desc: String

            if let colonRange = raw.range(of: ":") {
                title = String(raw[..<colonRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                desc = String(raw[colonRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else if let dashRange = raw.range(of: " — ") ?? raw.range(of: " - ") {
                title = String(raw[..<dashRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                desc = String(raw[dashRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else {
                title = raw
                desc = ""
            }

            let style = smartIconAndColor(forTitle: title, description: desc) ?? defaultPalette[index % defaultPalette.count]

            parsed.append(
                WhatsNewFeature(
                    id: "\(title)-\(index)",
                    icon: style.icon,
                    color: style.color,
                    title: title,
                    description: desc.isEmpty ? title : desc
                )
            )
        }

        if parsed.isEmpty {
            return current(version: version)
        }

        return WhatsNewContent(
            version: version,
            subtitle: "Here is what changed in this version",
            features: parsed
        )
    }

    private static func smartIconAndColor(forTitle title: String, description: String) -> (icon: String, color: Color)? {
        let combined = "\(title) \(description)".lowercased()
        if combined.contains("audio") || combined.contains("chime") || combined.contains("sound") {
            return ("speaker.wave.2.fill", Theme.ColorToken.amber)
        }
        if combined.contains("menu") || combined.contains("bar") || combined.contains("status") {
            return ("menubar.arrow.up.rectangle", Theme.ColorToken.green)
        }
        if combined.contains("update") || combined.contains("pre-cache") || combined.contains("restart") {
            return ("arrow.triangle.2.circlepath.circle.fill", Theme.ColorToken.blue)
        }
        if combined.contains("dispatch") || combined.contains("it support") || combined.contains("helpdesk") || combined.contains("ticket") {
            return ("doc.text.fill", Theme.ColorToken.green)
        }
        if combined.contains("plain english") || combined.contains("language") || combined.contains("explain") {
            return ("text.bubble.fill", Theme.ColorToken.blue)
        }
        if combined.contains("wifi") || combined.contains("wireless") || combined.contains("roam") {
            return ("wifi", Theme.ColorToken.blue)
        }
        if combined.contains("speed") || combined.contains("latency") || combined.contains("ping") {
            return ("speedometer", Theme.ColorToken.green)
        }
        return nil
    }
}
