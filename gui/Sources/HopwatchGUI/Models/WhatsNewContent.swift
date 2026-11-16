import SwiftUI
import Foundation
import AppKit

/// A single feature highlight displayed in the "What's New" sheet.
struct WhatsNewFeature: Identifiable, Sendable, Equatable, Hashable {
    let id: String
    let icon: String
    let color: Color
    let title: String
    let description: String
    let summary: String
    let details: String?
    let category: String?

    init(
        id: String? = nil,
        icon: String,
        color: Color,
        title: String,
        description: String,
        summary: String? = nil,
        details: String? = nil,
        category: String? = nil
    ) {
        self.id = id ?? title
        self.icon = icon
        self.color = color
        self.title = title
        self.description = description
        self.summary = summary ?? description
        self.details = details
        self.category = category
    }
}

/// Content payload backing the "What's New" presentation for a given Hopwatch release.
struct WhatsNewContent: Equatable, Sendable {
    let version: String
    let releaseDate: String?
    let subtitle: String
    let features: [WhatsNewFeature]
    let isCuratedFallback: Bool

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
        releaseDate: String? = nil,
        subtitle: String = "Here is what changed in this version",
        features: [WhatsNewFeature],
        isCuratedFallback: Bool = false
    ) {
        self.version = version
        self.releaseDate = releaseDate
        self.subtitle = subtitle
        self.features = features
        self.isCuratedFallback = isCuratedFallback
    }

    /// Resolves what's new for the given version:
    /// 1. Uses explicit releaseNotes if provided
    /// 2. Checks cached releaseNotes in Defaults for this version
    /// 3. Reads section for this version from bundled or local CHANGELOG.md
    /// 4. Falls back to curated highlights if no notes are found
    static func current(
        version: String = Defaults.appVersion,
        releaseNotes: String? = nil
    ) -> WhatsNewContent {
        let clean = version.trimmingCharacters(in: CharacterSet(charactersIn: "vV \t\r\n"))

        // 1. Explicit release notes passed in
        if let releaseNotes, !releaseNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let parsed = parse(releaseNotes: releaseNotes, version: clean)
            if !parsed.features.isEmpty {
                return parsed
            }
        }

        // 2. Cached release notes stored during update download
        if let cached = Defaults.releaseNotes(for: clean), !cached.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let parsed = parse(releaseNotes: cached, version: clean)
            if !parsed.features.isEmpty {
                return parsed
            }
        }

        // 3. Bundled or local CHANGELOG.md section
        if let section = ChangelogReader.section(for: clean) {
            let parsed = parse(releaseNotes: section.content, version: clean, releaseDate: section.date)
            if !parsed.features.isEmpty {
                return parsed
            }
        }

        // 4. Curated highlights fallback
        return curatedHighlights(version: clean)
    }

    /// Static curated highlights fallback when release notes are completely unavailable.
    static func curatedHighlights(version: String = Defaults.appVersion) -> WhatsNewContent {
        WhatsNewContent(
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
            ],
            isCuratedFallback: true
        )
    }

    /// Formats an ISO date string (e.g. "2026-11-07") into a friendly human-readable date.
    static func formatReleaseDate(_ isoDate: String) -> String {
        let parts = isoDate.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              month >= 1 && month <= 12 else {
            return isoDate
        }
        let months = [
            "January", "February", "March", "April", "May", "June",
            "July", "August", "September", "October", "November", "December"
        ]
        return "\(months[month - 1]) \(day), \(year)"
    }

    /// Strips Markdown formatting (bold, italic, backticks, links, PR tags) to produce clean readable text.
    static func cleanMarkdown(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove conventional commit prefixes like "fix(ui): " or "feat: "
        if let prefixMatch = s.range(of: #"^(fix|feat|chore|perf|refactor|docs)(\([^)]+\))?!?:[ \t]*"#, options: .regularExpression) {
            s.removeSubrange(prefixMatch)
            if let first = s.first {
                s = first.uppercased() + s.dropFirst()
            }
        }

        // Bold and italic: **text**, __text__, *text*, _text_
        s = s.replacingOccurrences(of: #"\*\*(.*?)\*\*"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"__(.*?)__"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?<!\*)\*(?!\*)(.*?)(?<!\*)\*(?!\*)"#, with: "$1", options: .regularExpression)

        // Inline code backticks: `code` -> code
        s = s.replacingOccurrences(of: #"`(.*?)`"#, with: "$1", options: .regularExpression)

        // Markdown links: [label](url) -> label
        s = s.replacingOccurrences(of: #"\[(.*?)\]\([^)]+\)"#, with: "$1", options: .regularExpression)

        // Strip PR links: (#123) or by @user in https://...
        s = s.replacingOccurrences(of: #"\s*\(#[0-9]+\)"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s*by\s+@[a-zA-Z0-9_-]+.*$"#, with: "", options: .regularExpression)

        // Clean trailing colons, dashes or periods
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix(":") || s.hasSuffix("—") || s.hasSuffix("-") {
            s = String(s.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return s
    }

    /// Splits a description into a concise summary sentence and optional detailed context.
    static func splitSummaryAndDetails(_ text: String) -> (summary: String, details: String?) {
        let cleaned = cleanMarkdown(text)
        guard cleaned.count > 110 else {
            return (summary: cleaned, details: nil)
        }

        // Avoid splitting on common abbreviations like "e.g. ", "i.e. ", "etc. ", "vs. "
        var searchIndex = cleaned.startIndex
        while let periodRange = cleaned[searchIndex...].range(of: ". ") {
            let prefix = String(cleaned[..<periodRange.lowerBound])
            let lower = prefix.lowercased()
            if lower.hasSuffix("e.g") || lower.hasSuffix("i.e") || lower.hasSuffix("etc") || lower.hasSuffix("vs") || lower.hasSuffix("v") {
                searchIndex = periodRange.upperBound
                continue
            }

            let firstSentence = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
            if firstSentence.count >= 30 && firstSentence.count < cleaned.count {
                return (summary: firstSentence + ".", details: cleaned)
            }
            searchIndex = periodRange.upperBound
        }

        return (summary: cleaned, details: nil)
    }

    /// Generates a clean Markdown representation of the release notes for copying to clipboard.
    func toMarkdown() -> String {
        var lines: [String] = []
        let releaseTitle = releaseDate != nil ? "What’s New in Hopwatch \(displayVersion) (\(Self.formatReleaseDate(releaseDate!)))" : title
        lines.append("# \(releaseTitle)")
        lines.append("")

        let categories = ["New", "Improved", "Fix", "Security"]
        for cat in categories {
            let inCategory = features.filter { $0.category == cat }
            guard !inCategory.isEmpty else { continue }
            let heading: String = switch cat {
            case "New": "### Added"
            case "Fix": "### Fixed"
            case "Improved": "### Improvements"
            case "Security": "### Security"
            default: "### Changes"
            }
            lines.append(heading)
            for f in inCategory {
                lines.append("- **\(f.title)**: \(f.description)")
            }
            lines.append("")
        }

        let uncategorized = features.filter { $0.category == nil || !categories.contains($0.category!) }
        if !uncategorized.isEmpty {
            lines.append("### Changes")
            for f in uncategorized {
                lines.append("- **\(f.title)**: \(f.description)")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parses release notes text (e.g. GitHub release body or CHANGELOG section) into structured features.
    static func parse(
        releaseNotes: String,
        version: String = Defaults.appVersion,
        releaseDate: String? = nil
    ) -> WhatsNewContent {
        let lines = releaseNotes.components(separatedBy: .newlines)

        var currentCategory: String? = nil
        var parsed: [WhatsNewFeature] = []

        let defaultPalette: [(icon: String, color: Color)] = [
            ("sparkles", Theme.ColorToken.blue),
            ("bolt.fill", Theme.ColorToken.amber),
            ("checkmark.seal.fill", Theme.ColorToken.green),
            ("arrow.triangle.2.circlepath.circle.fill", Theme.ColorToken.blue),
            ("speedometer", Theme.ColorToken.green),
            ("waveform.path.ecg", Theme.ColorToken.blue)
        ]

        var currentItemTitle: String? = nil
        var currentItemCategory: String? = nil
        var currentItemDescParts: [String] = []

        func flushCurrentItem() {
            guard let rawTitle = currentItemTitle else { return }
            let title = cleanMarkdown(rawTitle)
            guard !title.isEmpty else {
                currentItemTitle = nil
                currentItemCategory = nil
                currentItemDescParts = []
                return
            }

            let combinedDesc = currentItemDescParts
                .map { cleanMarkdown($0) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")

            let finalDesc = combinedDesc.isEmpty ? title : combinedDesc
            let (summary, details) = splitSummaryAndDetails(finalDesc)
            let style = smartIconAndColor(forTitle: title, description: finalDesc, category: currentItemCategory)
                ?? defaultPalette[parsed.count % defaultPalette.count]

            parsed.append(
                WhatsNewFeature(
                    id: "\(title)-\(parsed.count)",
                    icon: style.icon,
                    color: style.color,
                    title: title,
                    description: finalDesc,
                    summary: summary,
                    details: details,
                    category: currentItemCategory
                )
            )

            currentItemTitle = nil
            currentItemCategory = nil
            currentItemDescParts = []
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            // Category headings (e.g. "### Added", "### Fixed", "### Changed")
            if line.hasPrefix("#") {
                flushCurrentItem()
                let headingText = line.replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression).lowercased()
                if headingText.contains("added") || headingText.contains("new") {
                    currentCategory = "New"
                } else if headingText.contains("fixed") || headingText.contains("bug") {
                    currentCategory = "Fix"
                } else if headingText.contains("changed") || headingText.contains("improved") || headingText.contains("improvements") {
                    currentCategory = "Improved"
                } else if headingText.contains("security") {
                    currentCategory = "Security"
                } else {
                    currentCategory = nil
                }
                continue
            }

            // Detect top-level bullet point (starts with -, *, •, or \d+.) with <= 1 leading space
            let isIndented = rawLine.hasPrefix("  ") || rawLine.hasPrefix("\t")
            let hasBulletPrefix = line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ")
                || line.range(of: #"^\d+\.\s*"#, options: .regularExpression) != nil

            if hasBulletPrefix && !isIndented {
                // Starting a new top-level bullet item
                flushCurrentItem()

                var content = line
                if content.hasPrefix("- ") || content.hasPrefix("* ") || content.hasPrefix("• ") {
                    content = String(content.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                } else if let match = content.range(of: #"^\d+\.\s*"#, options: .regularExpression) {
                    content = String(content[match.upperBound...]).trimmingCharacters(in: .whitespaces)
                }

                // Check for bold title pattern: **Title**: Description or **Title** - Description
                if let boldMatch = content.range(of: #"^\*\*([^*]+)\*\*[:\s—-]*(.*)$"#, options: .regularExpression) {
                    let full = content[boldMatch]
                    // Extract text between asterisks
                    if let firstAsterisks = full.range(of: "**"),
                       let secondAsterisks = full[firstAsterisks.upperBound...].range(of: "**") {
                        let extractedTitle = String(full[firstAsterisks.upperBound..<secondAsterisks.lowerBound])
                        let remainder = String(full[secondAsterisks.upperBound...])
                            .trimmingCharacters(in: CharacterSet(charactersIn: ": \t\r\n—-"))

                        currentItemTitle = extractedTitle
                        currentItemCategory = currentCategory
                        if !remainder.isEmpty {
                            currentItemDescParts.append(remainder)
                        }
                    } else {
                        currentItemTitle = content
                        currentItemCategory = currentCategory
                    }
                } else if let colonRange = content.range(of: ": ") {
                    let before = String(content[..<colonRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                    let after = String(content[colonRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                    currentItemTitle = before
                    currentItemCategory = currentCategory
                    if !after.isEmpty {
                        currentItemDescParts.append(after)
                    }
                } else if let dashRange = content.range(of: " — ") ?? content.range(of: " - ") {
                    let before = String(content[..<dashRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                    let after = String(content[dashRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                    currentItemTitle = before
                    currentItemCategory = currentCategory
                    if !after.isEmpty {
                        currentItemDescParts.append(after)
                    }
                } else {
                    currentItemTitle = content
                    currentItemCategory = currentCategory
                }
            } else if isIndented && currentItemTitle != nil {
                // Sub-bullet or continuation line belonging to the active bullet item
                var sub = line
                if sub.hasPrefix("- ") || sub.hasPrefix("* ") || sub.hasPrefix("• ") {
                    sub = String(sub.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                }
                if !sub.isEmpty {
                    currentItemDescParts.append(sub)
                }
            } else if currentItemTitle != nil {
                // Continuation text
                currentItemDescParts.append(line)
            }
        }

        flushCurrentItem()

        if parsed.isEmpty {
            return curatedHighlights(version: version)
        }

        let formattedSubtitle: String
        if let releaseDate, !releaseDate.isEmpty {
            formattedSubtitle = "Released \(formatReleaseDate(releaseDate)) • Here’s what changed in this version"
        } else {
            formattedSubtitle = "Here is what changed in this version"
        }

        return WhatsNewContent(
            version: version,
            releaseDate: releaseDate,
            subtitle: formattedSubtitle,
            features: parsed,
            isCuratedFallback: false
        )
    }

    private static func smartIconAndColor(forTitle title: String, description: String, category: String? = nil) -> (icon: String, color: Color)? {
        let titleLower = title.lowercased()

        // 1. Prioritize high-signal title keywords
        if titleLower.contains("arrival") || titleLower.contains("recovery") || titleLower.contains("reconnect") || titleLower.contains("retry") {
            return ("arrow.triangle.2.circlepath.circle.fill", Theme.ColorToken.blue)
        }
        if titleLower.contains("wifi") || titleLower.contains("wi-fi") || titleLower.contains("wireless") || titleLower.contains("ssid") || titleLower.contains("roam") {
            return ("wifi", Theme.ColorToken.blue)
        }
        if titleLower.contains("battery") || titleLower.contains("power") || titleLower.contains("cadence") {
            return ("battery.100.bolt", Theme.ColorToken.amber)
        }
        if titleLower.contains("menu bar") || titleLower.contains("status bar") || titleLower.contains("dynamic menu") {
            return ("menubar.arrow.up.rectangle", Theme.ColorToken.green)
        }
        if titleLower.contains("speed") || titleLower.contains("bandwidth") || titleLower.contains("bufferbloat") {
            return ("speedometer", Theme.ColorToken.green)
        }
        if titleLower.contains("ping") || titleLower.contains("latency") || titleLower.contains("jitter") || titleLower.contains("heartbeat") {
            return ("waveform.path.ecg", Theme.ColorToken.blue)
        }
        if titleLower.contains("firewall") || titleLower.contains("shield") {
            return ("shield.checkerboard", Theme.ColorToken.blue)
        }
        if titleLower.contains("dns") || titleLower.contains("resolver") {
            return ("globe", Theme.ColorToken.blue)
        }
        if titleLower.contains("torrent") || titleLower.contains("flow") || titleLower.contains("conn-1") || titleLower.contains("sock-1") {
            return ("app.connected.to.app.below.fill", Theme.ColorToken.amber)
        }
        if titleLower.contains("report") || titleLower.contains("incident") || titleLower.contains("export") || titleLower.contains("dispatch") {
            return ("doc.text.fill", Theme.ColorToken.green)
        }
        if titleLower.contains("clock") || titleLower.contains("time") || titleLower.contains("timestamp") || titleLower.contains("relative") {
            return ("clock.fill", Theme.ColorToken.muted)
        }
        if titleLower.contains("audio") || titleLower.contains("chime") || titleLower.contains("sound") {
            return ("speaker.wave.2.fill", Theme.ColorToken.amber)
        }
        if titleLower.contains("shortcut") || titleLower.contains("hotkey") || titleLower.contains("keyboard") {
            return ("keyboard.fill", Color.purple)
        }
        if titleLower.contains("sleep") {
            return ("moon.fill", Color.purple)
        }
        if titleLower.contains("portal") || titleLower.contains("captive") {
            return ("lock.shield", Theme.ColorToken.amber)
        }
        if titleLower.contains("harness") || titleLower.contains("verify") || titleLower.contains("test") {
            return ("checkmark.shield.fill", Theme.ColorToken.blue)
        }
        if titleLower.contains("privacy") || titleLower.contains("redact") {
            return ("eye.slash.fill", Color.purple)
        }
        if titleLower.contains("suitability") || titleLower.contains("scoring") {
            return ("gauge.with.needle.fill", Theme.ColorToken.blue)
        }

        // 2. Secondary description keywords
        let combined = "\(title) \(description)".lowercased()
        if combined.contains("audio") || combined.contains("chime") || combined.contains("sound") {
            return ("speaker.wave.2.fill", Theme.ColorToken.amber)
        }
        if combined.contains("battery") || combined.contains("power") || combined.contains("cadence") {
            return ("battery.100.bolt", Theme.ColorToken.amber)
        }
        if combined.contains("sleep") {
            return ("moon.fill", Color.purple)
        }
        if combined.contains("menu bar") || combined.contains("status bar") {
            return ("menubar.arrow.up.rectangle", Theme.ColorToken.green)
        }
        if combined.contains("wifi") || combined.contains("wi-fi") || combined.contains("wireless") {
            return ("wifi", Theme.ColorToken.blue)
        }
        if combined.contains("firewall") || combined.contains("shield") {
            return ("shield.checkerboard", Theme.ColorToken.blue)
        }
        if combined.contains("speed") || combined.contains("bufferbloat") {
            return ("speedometer", Theme.ColorToken.green)
        }
        if combined.contains("ping") || combined.contains("latency") || combined.contains("jitter") {
            return ("waveform.path.ecg", Theme.ColorToken.blue)
        }
        if combined.contains("report") || combined.contains("incident") || combined.contains("export") {
            return ("doc.text.fill", Theme.ColorToken.green)
        }
        if combined.contains("update") || combined.contains("restart") {
            return ("arrow.triangle.2.circlepath.circle.fill", Theme.ColorToken.blue)
        }

        // 3. Category fallback
        if let category {
            switch category {
            case "New":
                return ("sparkles", Theme.ColorToken.blue)
            case "Fix":
                return ("checkmark.seal.fill", Theme.ColorToken.green)
            case "Improved":
                return ("arrow.triangle.2.circlepath", Theme.ColorToken.blue)
            default:
                break
            }
        }

        return nil
    }
}
