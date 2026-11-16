import Foundation

/// Reader and parser for Hopwatch's `CHANGELOG.md` file.
///
/// Looks for the bundled `CHANGELOG.md` inside `Contents/Resources`, or in
/// project source directories during development and testing. Extracts version-specific
/// release sections so "What's New in Hopwatch" always reflects genuine release changes.
enum ChangelogReader {

    struct Section: Sendable, Equatable {
        let version: String
        let date: String?
        let content: String

        init(version: String, date: String?, content: String) {
            self.version = version
            self.date = date
            self.content = content
        }
    }

    /// Candidate paths where CHANGELOG.md can be located.
    private static var candidateURLs: [URL] {
        var urls: [URL] = []

        if let bundled = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md") {
            urls.append(bundled)
        }
        if let res = Bundle.main.resourceURL?.appendingPathComponent("CHANGELOG.md"),
           FileManager.default.fileExists(atPath: res.path) {
            urls.append(res)
        }
        let appRes = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/CHANGELOG.md")
        if FileManager.default.fileExists(atPath: appRes.path) {
            urls.append(appRes)
        }

        // Development and test paths
        let workingDir = FileManager.default.currentDirectoryPath
        let relativePaths = [
            "CHANGELOG.md",
            "../CHANGELOG.md",
            "../../CHANGELOG.md",
            "../../../CHANGELOG.md"
        ]

        for rel in relativePaths {
            let u = URL(fileURLWithPath: rel, relativeTo: URL(fileURLWithPath: workingDir)).standardizedFileURL
            if FileManager.default.fileExists(atPath: u.path) {
                urls.append(u)
            }
        }

        return urls
    }

    /// Reads the raw content of CHANGELOG.md from the first available location.
    static func loadChangelog() -> String? {
        for url in candidateURLs {
            if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
                return text
            }
        }
        return nil
    }

    /// Resolves the newest released version documented in CHANGELOG.md.
    static func latestVersion(in text: String? = nil) -> String? {
        availableVersions(in: text).first?.version
    }

    /// Lists all released versions documented in CHANGELOG.md in chronological order (newest first).
    static func availableVersions(in text: String? = nil) -> [(version: String, date: String?)] {
        guard let changelog = text ?? loadChangelog() else { return [] }
        let headingRegex = try? NSRegularExpression(
            pattern: #"^##\s*\[([^\]]+)\](?:\s*-\s*([0-9]{4}-[0-9]{2}-[0-9]{2}|\S+))?\s*$"#,
            options: []
        )
        var results: [(version: String, date: String?)] = []
        for line in changelog.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let match = headingRegex?.firstMatch(in: trimmed, options: [], range: NSRange(location: 0, length: trimmed.utf16.count)),
               let r1 = Range(match.range(at: 1), in: trimmed) {
                let ver = String(trimmed[r1]).trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
                if ver.lowercased() != "unreleased" {
                    var date: String? = nil
                    if match.numberOfRanges > 2, match.range(at: 2).location != NSNotFound,
                       let r2 = Range(match.range(at: 2), in: trimmed) {
                        date = String(trimmed[r2])
                    }
                    results.append((version: ver, date: date))
                }
            }
        }
        return results
    }

    /// Extracts the release section for a specific version from CHANGELOG text.
    static func section(for version: String, in text: String? = nil) -> Section? {
        guard let changelog = text ?? loadChangelog() else { return nil }

        let targetVersion = version.trimmingCharacters(in: CharacterSet(charactersIn: "vV \t\r\n"))
        let lines = changelog.components(separatedBy: .newlines)

        let headingRegex = try? NSRegularExpression(
            pattern: #"^##\s*\[([^\]]+)\](?:\s*-\s*([0-9]{4}-[0-9]{2}-[0-9]{2}|\S+))?\s*$"#,
            options: []
        )

        var sections: [(version: String, date: String?, lines: [String])] = []
        var current: (version: String, date: String?, lines: [String])? = nil

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let match = headingRegex?.firstMatch(in: trimmed, options: [], range: NSRange(location: 0, length: trimmed.utf16.count)) {
                if let cur = current {
                    sections.append(cur)
                }

                var ver = ""
                var date: String? = nil

                if let r1 = Range(match.range(at: 1), in: trimmed) {
                    ver = String(trimmed[r1])
                }
                if match.numberOfRanges > 2, match.range(at: 2).location != NSNotFound,
                   let r2 = Range(match.range(at: 2), in: trimmed) {
                    date = String(trimmed[r2])
                }

                current = (version: ver, date: date, lines: [])
                continue
            }

            // End parsing on document footer (link definitions or comment)
            if trimmed.hasPrefix("[") && trimmed.contains("]: http") {
                break
            }
            if trimmed == "<!--" {
                break
            }

            if current != nil {
                current?.lines.append(line)
            }
        }

        if let cur = current {
            sections.append(cur)
        }

        // Match requested version (exact or clean)
        if let found = sections.first(where: {
            $0.version.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")) == targetVersion
        }) {
            let body = found.lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return Section(version: found.version, date: found.date, content: body)
        }

        // If target version is unreleased or not yet tagged, check [Unreleased]
        if targetVersion.lowercased() == "unreleased",
           let found = sections.first(where: { $0.version.lowercased() == "unreleased" }) {
            let body = found.lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return Section(version: found.version, date: found.date, content: body)
        }

        return nil
    }
}
