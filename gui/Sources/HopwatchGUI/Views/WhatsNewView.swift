import SwiftUI
import AppKit

/// Sleek modal sheet displaying highlights of the current or selected Hopwatch release.
struct WhatsNewView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var content: WhatsNewContent
    @State private var selectedCategory: String = "All"
    @State private var expandedFeatureIDs: Set<String> = []
    @State private var didCopy: Bool = false
    @State private var availableVersions: [(version: String, date: String?)] = []

    let dismissButtonTitle: String
    let onDismiss: () -> Void

    init(
        content: WhatsNewContent = .current(),
        dismissButtonTitle: String = "Got it",
        onDismiss: @escaping () -> Void = {}
    ) {
        _content = State(initialValue: content)
        self.dismissButtonTitle = dismissButtonTitle
        self.onDismiss = onDismiss
    }

    private var filteredFeatures: [WhatsNewFeature] {
        if selectedCategory == "All" {
            return content.features
        }
        return content.features.filter { $0.category == selectedCategory }
    }

    private var availableCategories: [String] {
        var cats = ["All"]
        let distinct = Set(content.features.compactMap(\.category))
        for c in ["New", "Fix", "Improved", "Security"] where distinct.contains(c) {
            cats.append(c)
        }
        return cats
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            header
            if availableCategories.count > 2 {
                categoryFilterBar
            }
            featureList
            footer
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 520)
        .task {
            loadAvailableVersions()
            if content.isCuratedFallback {
                await fetchRemoteReleaseNotes()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: Theme.Spacing.sm) {
            AppBrandMark(size: 46)

            VStack(spacing: Theme.Spacing.xs) {
                HStack(spacing: 6) {
                    Text(content.title)
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundStyle(Theme.ColorToken.ink)

                    if availableVersions.count > 1 {
                        versionMenu
                    }
                }

                Text(content.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Theme.ColorToken.muted)
                    .multilineTextAlignment(.center)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.top, Theme.Spacing.xs)
    }

    private var versionMenu: some View {
        Menu {
            ForEach(availableVersions, id: \.version) { item in
                Button {
                    switchToVersion(item.version)
                } label: {
                    HStack {
                        Text("v\(item.version)\(item.version == Defaults.appVersion ? " (Current)" : "")")
                        if item.version == content.cleanVersion {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.ColorToken.muted)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Theme.ColorToken.neutralWash)
                )
        }
        .buttonStyle(.plain)
        .help("Browse release notes for previous versions")
    }

    // MARK: - Category Filter Bar

    private var categoryFilterBar: some View {
        HStack(spacing: 6) {
            ForEach(availableCategories, id: \.self) { cat in
                let count = cat == "All" ? content.features.count : content.features.filter({ $0.category == cat }).count
                let isSelected = selectedCategory == cat

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selectedCategory = cat
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(categoryLabel(cat))
                            .fontWeight(isSelected ? .semibold : .regular)
                        Text("(\(count))")
                            .font(.system(size: 10, weight: .medium))
                            .opacity(isSelected ? 0.9 : 0.6)
                    }
                    .font(.caption)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(isSelected ? Theme.ColorToken.blue.opacity(0.16) : Theme.ColorToken.neutralWash)
                    )
                    .foregroundStyle(isSelected ? Theme.ColorToken.blue : Theme.ColorToken.ink)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 2)
        .padding(.top, 2)
    }

    private func categoryLabel(_ cat: String) -> String {
        switch cat {
        case "All": return "All"
        case "New": return "New"
        case "Fix": return "Fixes"
        case "Improved": return "Improvements"
        case "Security": return "Security"
        default: return cat
        }
    }

    // MARK: - Feature List

    private var featureList: some View {
        ScrollView(.vertical, showsIndicators: filteredFeatures.count > 3) {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(filteredFeatures) { feature in
                    featureCard(feature)
                }
            }
            .padding(.vertical, Theme.Spacing.xs)
            .padding(.horizontal, 2)
        }
        .defaultScrollAnchor(.top)
        .frame(maxHeight: 340)
    }

    private func featureCard(_ feature: WhatsNewFeature) -> some View {
        let isExpanded = expandedFeatureIDs.contains(feature.id)
        let hasMore = feature.details != nil

        return HStack(alignment: .top, spacing: Theme.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .fill(feature.color.opacity(0.12))
                    .frame(width: 36, height: 36)

                Image(systemName: feature.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(feature.color)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(feature.title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.ColorToken.ink)
                        .fixedSize(horizontal: false, vertical: true)

                    if let category = feature.category {
                        categoryBadge(category)
                    }
                }

                Text(isExpanded && hasMore ? feature.details! : feature.summary)
                    .font(.caption)
                    .foregroundStyle(Theme.ColorToken.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)

                if hasMore {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            if isExpanded {
                                expandedFeatureIDs.remove(feature.id)
                            } else {
                                expandedFeatureIDs.insert(feature.id)
                            }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text(isExpanded ? "Show less" : "More details")
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                        }
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(Theme.ColorToken.blue)
                        .padding(.top, 1)
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.5))
        )
    }

    @ViewBuilder
    private func categoryBadge(_ category: String) -> some View {
        let tint: Color = switch category {
        case "New": Theme.ColorToken.green
        case "Fix": Theme.ColorToken.amber
        case "Improved": Theme.ColorToken.blue
        case "Security": Color.red
        default: Theme.ColorToken.muted
        }

        Text(category)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(
                Capsule()
                    .fill(tint.opacity(0.12))
            )
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Button(action: handleDismiss) {
                Text(dismissButtonTitle)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)

            HStack {
                Button {
                    copyReleaseNotes()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10, weight: .semibold))
                        Text(didCopy ? "Copied to Clipboard" : "Copy Notes")
                    }
                    .font(.caption)
                    .foregroundStyle(didCopy ? Theme.ColorToken.green : Theme.ColorToken.muted)
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    let urlString: String
                    if content.cleanVersion.isEmpty {
                        urlString = "https://github.com/godigi/hopwatch/releases"
                    } else {
                        urlString = "https://github.com/godigi/hopwatch/releases/tag/v\(content.cleanVersion)"
                    }
                    if let url = URL(string: urlString) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("View on GitHub")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .font(.caption)
                    .foregroundStyle(Theme.ColorToken.muted)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 4)
        }
        .padding(.top, Theme.Spacing.xs)
    }

    private func handleDismiss() {
        onDismiss()
        dismiss()
    }

    private func copyReleaseNotes() {
        let markdown = content.toMarkdown()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(markdown, forType: .string)

        withAnimation {
            didCopy = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation {
                didCopy = false
            }
        }
    }

    private func loadAvailableVersions() {
        availableVersions = ChangelogReader.availableVersions()
    }

    private func switchToVersion(_ version: String) {
        selectedCategory = "All"
        expandedFeatureIDs.removeAll()
        content = WhatsNewContent.current(version: version)
        if content.isCuratedFallback {
            Task { await fetchRemoteReleaseNotes() }
        }
    }

    private func fetchRemoteReleaseNotes() async {
        let tag = content.cleanVersion.isEmpty ? "latest" : "tags/v\(content.cleanVersion)"
        guard let url = URL(string: "https://api.github.com/repos/godigi/hopwatch/releases/\(tag)") else { return }

        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Hopwatch-App/\(Defaults.appVersion)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 8

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let release = try? JSONDecoder().decode(GitHubRelease.self, from: data),
              let body = release.body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        Defaults.setReleaseNotes(body, for: content.cleanVersion)
        let pubDate = release.publishedAt.flatMap { String($0.prefix(10)) }
        let updated = WhatsNewContent.parse(
            releaseNotes: body,
            version: content.cleanVersion,
            releaseDate: pubDate
        )
        if !updated.features.isEmpty {
            self.content = updated
        }
    }
}
