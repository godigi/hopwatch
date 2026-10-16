import SwiftUI
import AppKit

/// Sleek modal sheet displaying highlights of the current or new Hopwatch release.
struct WhatsNewView: View {
    @Environment(\.dismiss) private var dismiss

    let content: WhatsNewContent
    let dismissButtonTitle: String
    let onDismiss: () -> Void

    init(
        content: WhatsNewContent = .current(),
        dismissButtonTitle: String = "Got it",
        onDismiss: @escaping () -> Void = {}
    ) {
        self.content = content
        self.dismissButtonTitle = dismissButtonTitle
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            header
            featureList
            footer
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 480)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: Theme.Spacing.sm) {
            AppBrandMark(size: 48)

            VStack(spacing: Theme.Spacing.xs) {
                Text(content.title)
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(Theme.ColorToken.ink)

                Text(content.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Theme.ColorToken.muted)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.top, Theme.Spacing.xs)
    }

    // MARK: - Feature List

    private var featureList: some View {
        ScrollView(.vertical, showsIndicators: content.features.count > 5) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(content.features) { feature in
                    featureRow(feature)
                }
            }
            .padding(.vertical, Theme.Spacing.xs)
        }
        .frame(maxHeight: 320)
    }

    private func featureRow(_ feature: WhatsNewFeature) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .fill(feature.color.opacity(0.12))
                    .frame(width: 36, height: 36)

                Image(systemName: feature.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(feature.color)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(feature.title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.ColorToken.ink)

                Text(feature.description)
                    .font(.caption)
                    .foregroundStyle(Theme.ColorToken.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
            }

            Spacer(minLength: 0)
        }
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

            Button {
                if let url = URL(string: "https://github.com/godigi/hopwatch/releases") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                HStack(spacing: 4) {
                    Text("View Full Changelog on GitHub")
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .font(.caption)
                .foregroundStyle(Theme.ColorToken.muted)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, Theme.Spacing.xs)
    }

    private func handleDismiss() {
        onDismiss()
        dismiss()
    }
}
