import SwiftUI
import AppKit

/// Native macOS software update dialog modeled after Sparkle / Tungsten Edge.
///
/// Displays the available version vs installed version, an inset list of
/// user-facing release notes with clean bullet points, and provides
/// one-click install, remind later, and skip version options.
struct SoftwareUpdateView: View {
    @Environment(HopwatchCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    var explicitRelease: GitHubRelease?
    var onDismiss: (() -> Void)?

    @State private var autoInstallUpdates: Bool = Defaults.autoDownloadAndInstallUpdates

    private var activeRelease: GitHubRelease {
        if let explicitRelease {
            return explicitRelease
        }
        if let available = coordinator.updateChecker.availableRelease {
            return available
        }
        // Fallback for preview or harness testing
        return GitHubRelease(
            tagName: "v\(Defaults.appVersion)",
            name: "Hopwatch \(Defaults.appVersion)",
            body: """
            - Fixed taskbar icons not updating after an app's icon is changed in Finder.
            - Fixed pinned network cards flickering while being reordered.
            - Filtered non-urgent background advisories out of the mini menu status bar.
            - Enhanced 3-hop router attribution when ICMP ping is filtered.
            - Streamlined background update caching and instant restart.
            """,
            htmlUrl: URL(string: "https://github.com/godigi/hopwatch/releases"),
            publishedAt: nil,
            assets: []
        )
    }

    private var currentVersion: String {
        Defaults.appVersion
    }

    private var availableVersion: String {
        activeRelease.cleanVersion
    }

    private var bullets: [String] {
        activeRelease.releaseBulletPoints
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            headerRow

            releaseNotesCard

            automaticUpdatesToggle

            if let error = coordinator.updateChecker.errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.red)
                        .font(.system(size: 11))
                    Text(error)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.red)
                }
            }

            buttonRow
        }
        .padding(22)
        .frame(width: 530)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            autoInstallUpdates = Defaults.autoDownloadAndInstallUpdates
        }
        .onDisappear {
            onDismiss?()
        }
        .onChange(of: autoInstallUpdates) { _, newValue in
            Defaults.autoDownloadAndInstallUpdates = newValue
        }
    }

    // MARK: - 1. Header (Icon + Title + Subtitle)

    private var headerRow: some View {
        HStack(alignment: .top, spacing: 16) {
            AppBrandMark(size: 52)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .shadow(color: Color.black.opacity(0.12), radius: 3, x: 0, y: 1.5)

            VStack(alignment: .leading, spacing: 4) {
                Text("A new version of Hopwatch is available!")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.ColorToken.ink)

                Text("Hopwatch \(availableVersion) is now available—you have \(currentVersion). Would you like to download it now?")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.ColorToken.muted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 2. Release Notes Inset Card

    private var releaseNotesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What’s new in \(availableVersion)")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.ColorToken.ink)

            ScrollView(.vertical, showsIndicators: bullets.count > 5) {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(bullets.indices, id: \.self) { idx in
                        HStack(alignment: .top, spacing: 8) {
                            Text("•")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Color.secondary)

                            Text(bullets[idx])
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.ColorToken.ink)
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 4)
            }
            .frame(minHeight: 110, maxHeight: 180)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.65))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    // MARK: - 3. Checkbox Option

    private var automaticUpdatesToggle: some View {
        Toggle("Automatically download and install updates in the future", isOn: $autoInstallUpdates)
            .toggleStyle(.checkbox)
            .font(.system(size: 12))
            .foregroundStyle(Theme.ColorToken.ink)
    }

    // MARK: - 4. Action Buttons

    private var buttonRow: some View {
        HStack(spacing: 12) {
            Button("Skip This Version") {
                skipVersion()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

            Spacer()

            Button("Remind Me Later") {
                closeWindow()
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.cancelAction)
            .controlSize(.regular)

            installActionButton
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private var installActionButton: some View {
        let checker = coordinator.updateChecker
        Button {
            installUpdate()
        } label: {
            if checker.isDownloading {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Downloading \(Int(checker.downloadProgress * 100))%…")
                }
            } else if checker.isPreloaded {
                Text("Restart & Install")
            } else {
                Text("Install Update")
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.ColorToken.blue)
        .keyboardShortcut(.defaultAction)
        .controlSize(.regular)
        .disabled(checker.isDownloading)
    }

    // MARK: - Actions

    private func skipVersion() {
        coordinator.updateChecker.skipVersion(availableVersion)
        closeWindow()
    }

    private func installUpdate() {
        coordinator.updateChecker.downloadAndInstallUpdate()
    }

    private func closeWindow() {
        if let onDismiss {
            onDismiss()
        } else {
            dismiss()
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains(WindowID.softwareUpdate) == true }) {
                window.close()
            }
        }
    }
}
