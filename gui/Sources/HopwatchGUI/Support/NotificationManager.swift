import Foundation
import UserNotifications
import AppKit
import os

/// Sensitivity filter for macOS system notifications.
enum NotificationScope: String, CaseIterable, Identifiable, Sendable {
    case all = "all"
    case outagesOnly = "outages_only"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "Drops and degradation (recommended)"
        case .outagesOnly: return "Complete outages only"
        }
    }
}

/// Manages rate-limited system notifications via UNUserNotificationCenter.
///
/// Prevents notification fatigue through four mechanisms:
/// 1. Only notifies on state transitions (e.g. Healthy -> Outage, or Healthy -> High Packet Loss).
/// 2. Enforces a 30-minute cooldown timer per ongoing fault category.
/// 3. Respects user-configured scope (all degradation vs complete outages only).
/// 4. Sends an immediate, reassuring restoration notification when the network stabilizes,
///    clearing stale degradation banners from Notification Center.
@MainActor
@Observable
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {

    private(set) var isAuthorized = false
    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    var notificationsEnabled: Bool = true
    var scope: NotificationScope = .all

    var isDenied: Bool {
        authorizationStatus == .denied
    }

    /// Internal tracking for rate limiting (cooldown per alert key)
    private var lastNotifiedAt: [String: Date] = [:]
    /// Tracks active faults that were announced via notification
    private(set) var announcedFaults: Set<String> = []

    /// Notification posting handler, overridable for testing
    var onPostNotification: ((_ id: String, _ title: String, _ body: String, _ isSilent: Bool) -> Void)?
    var onRemoveNotification: ((_ id: String) -> Void)?
    var onOpenSystemSettings: (() -> Void)?
    var onFetchSettings: (() async -> UNAuthorizationStatus)?
    var onRequestAuthorization: ((UNAuthorizationOptions) async throws -> Bool)?
    var onNotificationResponse: (() -> Void)?

    private let log = Logger(subsystem: "com.godigi.hopwatch", category: "notifications")

    init(notificationsEnabled: Bool = true, scope: NotificationScope = .all) {
        self.notificationsEnabled = notificationsEnabled
        self.scope = scope
        super.init()
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            self.onNotificationResponse?()
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // MARK: - Permission

    func requestAuthorization() async {
        if let onRequestAuthorization {
            do {
                let granted = try await onRequestAuthorization([.alert, .sound])
                await refreshAuthorization()
                if !granted && authorizationStatus == .denied {
                    openSystemSettings()
                }
            } catch {
                log.error("Notification authorization request failed: \(error.localizedDescription, privacy: .public)")
                await refreshAuthorization()
                if authorizationStatus == .denied {
                    openSystemSettings()
                }
            }
            return
        }
        guard Bundle.main.bundleIdentifier != nil else {
            return
        }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        authorizationStatus = settings.authorizationStatus
        if settings.authorizationStatus == .denied {
            log.debug("notification authorization is denied; opening System Settings")
            openSystemSettings()
            return
        }
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            await refreshAuthorization()
            if !granted && authorizationStatus == .denied {
                log.debug("notification authorization was declined; opening System Settings")
                openSystemSettings()
            }
        } catch {
            log.error("Notification authorization request failed: \(error.localizedDescription, privacy: .public)")
            await refreshAuthorization()
            if authorizationStatus == .denied {
                openSystemSettings()
            }
        }
    }

    /// Requests authorization, or falls back to opening System Settings if
    /// authorization is denied or produces no visible prompt / grant.
    func requestOrOpenSettings() async {
        await refreshAuthorization()
        if isDenied {
            openSystemSettings()
            return
        }
        let statusBefore = authorizationStatus
        await requestAuthorization()
        if !isAuthorized && authorizationStatus == statusBefore {
            log.debug("notification authorization unchanged; opening System Settings")
            openSystemSettings()
        }
    }

    func refreshAuthorization() async {
        if let onFetchSettings {
            authorizationStatus = await onFetchSettings()
            isAuthorized = (authorizationStatus == .authorized || authorizationStatus == .provisional)
            return
        }
        guard Bundle.main.bundleIdentifier != nil else {
            return
        }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus
        isAuthorized = settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
    }

    /// Builds the modern System Settings URL directly for the app's notification pane.
    static func systemSettingsURL(bundleID: String? = Bundle.main.bundleIdentifier) -> URL? {
        let id = bundleID ?? "com.godigi.hopwatch"
        return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")
    }

    /// Builds the fallback System Settings URL with bundle ID for older/alternate macOS handlers.
    static func systemSettingsFallbackURL(bundleID: String? = Bundle.main.bundleIdentifier) -> URL? {
        let id = bundleID ?? "com.godigi.hopwatch"
        return URL(string: "x-apple.systempreferences:com.apple.preference.notifications?id=\(id)")
    }

    /// Opens macOS System Settings directly to Notifications for Hopwatch.
    func openSystemSettings() {
        if let onOpenSystemSettings {
            onOpenSystemSettings()
            return
        }
        let bundleID = Bundle.main.bundleIdentifier ?? "com.godigi.hopwatch"
        if let url = Self.systemSettingsURL(bundleID: bundleID), NSWorkspace.shared.open(url) {
            log.debug("opened System Settings -> Notifications for \(bundleID, privacy: .public) via modern URL")
            return
        }
        if let url = Self.systemSettingsFallbackURL(bundleID: bundleID), NSWorkspace.shared.open(url) {
            log.debug("opened System Settings -> Notifications for \(bundleID, privacy: .public) via fallback URL with ID")
            return
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"),
           NSWorkspace.shared.open(url) {
            log.debug("opened System Settings -> Notifications via modern URL")
            return
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
            log.debug("opened System Settings -> Notifications via fallback URL")
        }
    }

    /// For testing: set authorization status directly
    func setAuthorizationStatusForTesting(_ status: UNAuthorizationStatus) {
        authorizationStatus = status
        isAuthorized = (status == .authorized || status == .provisional)
    }

    /// For testing: set authorized state directly
    func setAuthorizedForTesting(_ authorized: Bool) {
        setAuthorizationStatusForTesting(authorized ? .authorized : .denied)
    }

    // MARK: - Evaluation & Delivery

    /// Determines whether a notification can be posted according to user settings and cooldown rules.
    func canNotify(id: String, isOutage: Bool, now: Date = Date()) -> (allowed: Bool, reason: String?) {
        guard notificationsEnabled else {
            return (false, "Notifications disabled by user preference")
        }
        guard isAuthorized else {
            return (false, "Notifications not authorized by macOS")
        }
        if scope == .outagesOnly && !isOutage {
            return (false, "Suppressed by outages-only filter")
        }
        if let last = lastNotifiedAt[id], now.timeIntervalSince(last) < 1800 {
            return (false, "Suppressed by 30-minute cooldown (\(Int(1800 - now.timeIntervalSince(last)))s remaining)")
        }
        return (true, nil)
    }

    /// Posts a degradation or outage notification if allowed.
    @discardableResult
    func deliverDegradation(
        id: String,
        title: String,
        body: String,
        isOutage: Bool,
        now: Date = Date(),
        replacing: Bool = false
    ) -> Bool {
        let check = canNotify(id: id, isOutage: isOutage, now: now)
        guard check.allowed else {
            log.debug("Degradation alert \(id) suppressed: \(check.reason ?? "unknown", privacy: .public)")
            return false
        }

        lastNotifiedAt[id] = now
        announcedFaults.insert(id)

        if let handler = onPostNotification {
            handler("netdiag.\(id)", title, body, replacing)
        } else {
            let content = UNMutableNotificationContent()
            content.title = title
            if !body.isEmpty { content.body = body }
            content.sound = replacing ? nil : .default

            let request = UNNotificationRequest(identifier: "netdiag.\(id)", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }

        log.info("Delivered degradation notification: \(id, privacy: .public)")
        return true
    }

    /// Delivers an immediate recovery notification when the network stabilizes,
    /// but only if an alert was previously announced.
    @discardableResult
    func deliverRestored(
        networkName: String,
        latencyMs: Double? = nil,
        now: Date = Date()
    ) -> Bool {
        guard !announcedFaults.isEmpty else { return false }
        guard notificationsEnabled && isAuthorized else {
            clearAnnouncedFaults()
            return false
        }

        // Clean up previously announced degradation banners
        for faultID in announcedFaults {
            removeNotification(id: "netdiag.\(faultID)")
        }
        announcedFaults.removeAll()

        let title = latencyMs != nil ? "Wi-Fi Restored" : "Network Restored"
        let body: String
        if let lat = latencyMs {
            body = "Reconnected to \(networkName) (\(Int(round(lat)))ms latency)"
        } else {
            body = "Reconnected to \(networkName)"
        }

        if let handler = onPostNotification {
            handler("netdiag.restored", title, body, true)
        } else {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = nil

            let request = UNNotificationRequest(identifier: "netdiag.restored", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }

        log.info("Delivered restored notification for \(networkName, privacy: .public)")
        return true
    }

    /// Delivers a notification when a new version of Netdiag is available.
    @discardableResult
    func deliverUpdateNotification(version: String, shortNotes: String?) -> Bool {
        guard notificationsEnabled else { return false }
        let id = "netdiag.update.\(version)"
        let title = "netdiag Update Available"
        let notesSnippet = (shortNotes != nil && !shortNotes!.isEmpty) ? " — \(shortNotes!)" : ""
        let body = "Version \(version) is available to install\(notesSnippet). Click to review."

        if let handler = onPostNotification {
            handler(id, title, body, false)
        } else {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default

            let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }

        log.info("Delivered update notification for v\(version, privacy: .public)")
        return true
    }

    /// Delivers a resolution notice for a specific alert and clears its banner.
    func deliverAlertResolved(id: String, title: String) {
        guard announcedFaults.contains(id) else { return }
        announcedFaults.remove(id)

        removeNotification(id: "netdiag.\(id)")

        guard notificationsEnabled && isAuthorized else { return }

        let resolvedTitle = "\(title) — resolved"
        if let handler = onPostNotification {
            handler("netdiag.\(id).resolved", resolvedTitle, "", true)
        } else {
            let content = UNMutableNotificationContent()
            content.title = resolvedTitle
            content.sound = nil
            let request = UNNotificationRequest(identifier: "netdiag.\(id).resolved", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }

    private func removeNotification(id: String) {
        if let handler = onRemoveNotification {
            handler(id)
        } else {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
        }
    }

    /// Reset tracking (e.g. on new network or session restart)
    func clearAnnouncedFaults() {
        announcedFaults.removeAll()
    }
}
