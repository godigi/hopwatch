import SwiftUI
import CoreLocation

/// First run, in plain language.
///
/// Three asks, and only the first is required. Each one says what it is
/// for in terms of what the user gets, not in terms of what the app wants —
/// "unlocks real Wi-Fi names" rather than "requires Location Services
/// authorization". The app has to work fully when the two optional ones are
/// declined, and it does: gateway-MAC identity plus renaming already
/// deliver network grouping without Location, and history simply grows more
/// slowly without the background job.
struct OnboardingView: View {
    @Environment(HopwatchCoordinator.self) private var coordinator
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Hopwatch watches your connection").font(.title2).bold()
                Text("It sits in your menu bar, checks your network every few seconds, and tells you in plain English when something breaks — and what to do about it.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            step(number: 1,
                 title: "Let Hopwatch notify you",
                 detail: coordinator.alerts.notificationsDenied
                     ? "Disabled in System Settings. Click Open Settings to allow Hopwatch to alert you when something goes wrong."
                     : "Required. Without this, Hopwatch can watch your connection but has no way to tell you when something goes wrong.",
                 done: coordinator.alerts.notificationsAuthorized,
                 action: coordinator.alerts.notificationsDenied ? "Open Settings" : "Allow notifications") {
                if coordinator.alerts.notificationsDenied {
                    coordinator.alerts.openSystemSettings()
                } else {
                    Task { await coordinator.alerts.requestOrOpenSettings() }
                }
            }

            step(number: 2,
                 title: "Show real Wi-Fi network names",
                 detail: "Optional. macOS hides Wi-Fi names from apps unless you grant location access. Hopwatch never uses your location for anything else, and works fine without this — you can name your networks yourself instead.",
                 done: coordinator.locationPermissions.isAuthorized,
                 action: coordinator.locationPermissions.isDeniedOrRestricted ? "Open Settings" : "Allow") {
                if coordinator.locationPermissions.isDeniedOrRestricted {
                    coordinator.locationPermissions.openSystemSettings()
                } else {
                    coordinator.locationPermissions.requestOrOpenSettings()
                }
            }

            step(number: 3,
                 title: "Record a check every 15 minutes",
                 detail: "Optional. Installs a small background job so your history builds up over time. Without it, history only grows when a check actually runs.",
                 done: coordinator.watcher.isInstalled,
                 action: "Turn on") {
                Task { await coordinator.watcher.install() }
            }

            step(number: 4,
                 title: "Start Hopwatch when your Mac boots",
                 detail: "Recommended. Keeps Hopwatch running in your menu bar so you are always warned when your connection drops or degrades.",
                 done: appSettings.launchAtLogin,
                 action: "Turn on") {
                appSettings.launchAtLogin = true
            }

            Spacer()

            HStack(alignment: .firstTextBaseline) {
                // Never a dead end. Disabling this until notifications are
                // granted would trap anyone who declined the system prompt
                // in a window they cannot dismiss — and declining is a
                // perfectly reasonable answer that leaves the dashboard,
                // the history and the manual checks fully working.
                Text(coordinator.alerts.notificationsAuthorized
                     ? "You can change any of this later in Settings."
                     : "Without notifications Hopwatch still watches and records everything — it just can't interrupt you. You can turn them on later in Settings.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button(coordinator.alerts.notificationsAuthorized
                       ? "Get started" : "Continue without alerts") {
                    appSettings.hasOnboarded = true
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .fixedSize()
            }
        }
        .padding(24)
        .frame(width: 560)
        .task {
            await coordinator.alerts.refreshAuthorization()
            await coordinator.watcher.refresh()
            coordinator.locationPermissions.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                await coordinator.alerts.refreshAuthorization()
                await coordinator.watcher.refresh()
                coordinator.locationPermissions.refresh()
            }
        }
        .onAppear { coordinator.windowAppeared() }
        .onDisappear { coordinator.windowDisappeared() }
    }

    private func step(number: Int, title: String, detail: String,
                      done: Bool, action: String,
                      perform: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(done ? Color.green : Color.secondary.opacity(0.25))
                    .frame(width: 24, height: 24)
                if done {
                    Image(systemName: "checkmark").font(.caption).bold()
                        .foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.caption).bold()
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !done {
                Button(action, action: perform)
            }
        }
    }
}
