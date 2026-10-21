import Foundation

/// Structured metadata for a GitHub release.
struct GitHubRelease: Decodable, Sendable {
    var tagName: String
    var name: String?
    var body: String?
    var htmlUrl: URL?
    var publishedAt: String?
    var assets: [GitHubAsset] = []

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlUrl = "html_url"
        case publishedAt = "published_at"
        case assets
    }

    var cleanVersion: String {
        tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
    }

    /// Extract a concise release summary for banners (first non-empty line or bullet).
    var shortReleaseNotes: String? {
        guard let body = body, !body.isEmpty else { return nil }
        let lines = body.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        return lines.first
    }

    /// Formatted bullet points describing what's new in this release.
    var releaseBulletPoints: [String] {
        guard let body = body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ["Bug fixes and stability improvements."]
        }
        var bullets: [String] = []
        let lines = body.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            // Skip markdown headings
            if trimmed.hasPrefix("#") { continue }
            // Identify bulleted list items
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
                var content = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                // Strip conventional commit prefixes for cleaner user-facing release notes
                if let colon = content.range(of: "^(fix|feat|chore|perf|refactor|docs)(\\([^\\)]+\\))?!?:\\s*", options: .regularExpression) {
                    content.removeSubrange(colon)
                    if let first = content.first {
                        content = first.uppercased() + content.dropFirst()
                    }
                }
                // Strip PR/commit links and metadata e.g. "by @author in https://..." or "(#123)"
                if let prRange = content.range(of: "\\s+by\\s+@[a-zA-Z0-9_-]+.*$", options: .regularExpression) {
                    content.removeSubrange(prRange)
                }
                if let prNum = content.range(of: "\\s+\\(#[0-9]+\\)$", options: .regularExpression) {
                    content.removeSubrange(prNum)
                }
                if !content.isEmpty {
                    bullets.append(content)
                }
            } else if !trimmed.hasPrefix("http") && !trimmed.hasPrefix("[") && !trimmed.contains("Full Changelog") {
                if trimmed.count > 10 && trimmed.count < 300 {
                    bullets.append(trimmed)
                }
            }
        }
        return bullets.isEmpty ? ["Bug fixes and stability improvements."] : bullets
    }
}

/// A release asset attached to a GitHub release (e.g. `Netdiag.dmg`, `Netdiag.app.zip`).
struct GitHubAsset: Decodable, Sendable, Identifiable {
    var id: Int
    var name: String
    var browserDownloadUrl: URL
    var size: Int?
    var contentType: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case browserDownloadUrl = "browser_download_url"
        case size
        case contentType = "content_type"
    }

    var isInstallableArchive: Bool {
        let lower = name.lowercased()
        return lower.hasSuffix(".zip") || lower.hasSuffix(".dmg") || lower.hasSuffix(".tar.gz")
    }
}

/// Robust semantic version parser and comparator.
struct SemanticVersion: Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    let raw: String

    var description: String {
        "\(major).\(minor).\(patch)"
    }

    init(_ string: String) {
        self.raw = string
        let cleaned = string.trimmingCharacters(in: CharacterSet(charactersIn: "vV \t\n\r"))
        let components = cleaned.split(separator: ".").compactMap { Int($0.prefix(while: \.isNumber)) }
        self.major = components.count > 0 ? components[0] : 0
        self.minor = components.count > 1 ? components[1] : 0
        self.patch = components.count > 2 ? components[2] : 0
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        lhs.major == rhs.major && lhs.minor == rhs.minor && lhs.patch == rhs.patch
    }
}
