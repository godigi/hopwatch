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

/// Delivers system notifications via UNUserNotificationCenter.
///
/// Prevents notification fatigue through four mechanisms, only the first
/// two of which are this file's:
/// 1. Respects user-configured scope (all degradation vs complete outages only).
/// 2. Sends an immediate, reassuring restoration notification when the network stabilizes,
///    clearing stale degradation banners from Notification Center.
/// 3. `AlertEngine` notifies only on state transitions (e.g. Healthy -> Outage).
/// 4. `AlertEngine` waits out each alert's own `AlertDefinition.cooldown`
///    before notifying it again. That is the one authority on how often an
///    alert repeats, and the Settings captions state its values. This layer
///    used to keep a second, fixed 30-minute cooldown of its own, which
///    overrode the definitions (an alert defined to repeat after five
///    minutes could only repeat after thirty) and dropped the in-place
///    update that swaps the holding line for the CLI's sentence. What is
///    left is `minimumRepeatInterval`, a storm guard that sits below every
///    definition's cooldown and so never contradicts one.
///
/// An in-place update (`replacing: true`) is not a new interruption: it
/// rewrites a notification this layer already delivered, silently, and so
/// it is neither rate-limited nor counted against the storm guard. With no
/// delivered notification to rewrite it is dropped rather than posted as a
/// fresh one.
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

    /// The shortest gap between two *new* notifications for one alert id,
    /// whatever the engine asks for. A storm guard and nothing more: how
    /// often an alert may repeat is `AlertDefinition.cooldown`, enforced by
    /// `AlertEngine` before it gets here, and this must stay below the
    /// smallest of those (60 s) so it can never contradict one.
    static let minimumRepeatInterval: TimeInterval = 30

    /// Internal tracking for the storm guard (last new notification per alert key)
    private var lastNotifiedAt: [String: Date] = [:]
    /// Tracks active faults that were announced via notification
    private(set) var announcedFaults: Set<String> = []
    /// The subset of `announcedFaults` that was an outage. Only these may be
    /// followed by a "Restored" notice: a degradation that clears is told
    /// with its own "— resolved", and "Wi-Fi Restored" over a slow-but-up
    /// link claims a reconnect that never happened.
    private(set) var announcedOutages: Set<String> = []

    static let captivePortalCategoryID = "CAPTIVE_PORTAL"
    static let openPortalActionID = "OPEN_PORTAL_ACTION"

    /// Notification posting handler, overridable for testing
    var onPostNotification: ((_ id: String, _ title: String, _ body: String, _ isSilent: Bool) -> Void)?
    var onRemoveNotification: ((_ id: String) -> Void)?
    var onOpenSystemSettings: (() -> Void)?
    var onFetchSettings: (() async -> UNAuthorizationStatus)?
    var onRequestAuthorization: ((UNAuthorizationOptions) async throws -> Bool)?
    var onNotificationResponse: (() -> Void)?
    var onNotificationAction: ((_ id: String, _ actionIdentifier: String) -> Void)?

    private let log = Logger(subsystem: "com.godigi.hopwatch", category: "notifications")

    init(notificationsEnabled: Bool = true, scope: NotificationScope = .all) {
        self.notificationsEnabled = notificationsEnabled
        self.scope = scope
        super.init()
        if Bundle.main.bundleIdentifier != nil {
            let center = UNUserNotificationCenter.current()
            center.delegate = self
            let openAction = UNNotificationAction(
                identifier: Self.openPortalActionID,
                title: "Open Sign-In Page",
                options: [.foreground]
            )
            let category = UNNotificationCategory(
                identifier: Self.captivePortalCategoryID,
                actions: [openAction],
                intentIdentifiers: [],
                options: []
            )
            center.setNotificationCategories([category])
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.notification.request.identifier
        let actionIdentifier = response.actionIdentifier
        Task { @MainActor in
            self.onNotificationAction?(identifier, actionIdentifier)
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

    /// Determines whether a notification can be posted according to user
    /// settings and the storm guard. `replacing` marks an in-place update of
    /// a notification already delivered under this id.
    func canNotify(id: String, isOutage: Bool, now: Date = Date(),
                   replacing: Bool = false) -> (allowed: Bool, reason: String?) {
        guard notificationsEnabled else {
            return (false, "Notifications disabled by user preference")
        }
        guard isAuthorized else {
            return (false, "Notifications not authorized by macOS")
        }
        if scope == .outagesOnly && !isOutage {
            return (false, "Suppressed by outages-only filter")
        }
        if replacing {
            guard announcedFaults.contains(id) else {
                return (false, "No delivered notification to update")
            }
            return (true, nil)
        }
        if let last = lastNotifiedAt[id], now.timeIntervalSince(last) < Self.minimumRepeatInterval {
            return (false, "Suppressed by the \(Int(Self.minimumRepeatInterval))s storm guard (\(Int(Self.minimumRepeatInterval - now.timeIntervalSince(last)))s remaining)")
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
        replacing: Bool = false,
        announce: Bool = true
    ) -> Bool {
        let check = canNotify(id: id, isOutage: isOutage, now: now, replacing: replacing)
        guard check.allowed else {
            log.debug("Degradation alert \(id) suppressed: \(check.reason ?? "unknown", privacy: .public)")
            return false
        }

        if !replacing { lastNotifiedAt[id] = now }
        // `announce: false` is for an event: something that happened and is
        // over (public IP changed). It has no fault to clear and no
        // resolution to announce, so recording it here would let the next
        // healthy sample "restore" it: a false "Wi-Fi Restored", and the
        // event's own notification deleted from Notification Centre.
        if announce {
            announcedFaults.insert(id)
            if isOutage { announcedOutages.insert(id) }
        }

        if let handler = onPostNotification {
            handler("netdiag.\(id)", title, body, replacing)
        } else {
            let content = UNMutableNotificationContent()
            content.title = title
            if !body.isEmpty { content.body = body }
            content.sound = replacing ? nil : .default
            if id == "captive-portal" {
                content.categoryIdentifier = Self.captivePortalCategoryID
            }

            let request = UNNotificationRequest(identifier: "netdiag.\(id)", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }

        log.info("Delivered degradation notification: \(id, privacy: .public)")
        return true
    }

    /// Delivers an immediate recovery notification when the network stabilizes,
    /// but only if an outage was previously announced.
    ///
    /// Either way it also retires what the engine no longer holds: any
    /// announced fault whose id is not in `activeIDs` (an alert that cleared
    /// without a "resolved" notice — one that does not `resolves`, or one
    /// dropped when monitoring paused) has its delivered banner removed and
    /// its record dropped. Left alone, such an entry would sit in
    /// `announcedFaults` forever, keep its banner in Notification Centre, and
    /// make the caller ask again on every healthy sample.
    @discardableResult
    func deliverRestored(
        networkName: String,
        latencyMs: Double? = nil,
        activeIDs: Set<String> = [],
        now: Date = Date()
    ) -> Bool {
        let stale = announcedFaults.subtracting(activeIDs)
        let hadOutage = !announcedOutages.subtracting(activeIDs).isEmpty
        guard hadOutage else {
            // No outage to announce the end of; just tidy up.
            for faultID in stale { removeNotification(id: "netdiag.\(faultID)") }
            announcedFaults.subtract(stale)
            announcedOutages.subtract(stale)
            return false
        }
        guard notificationsEnabled && isAuthorized else {
            announcedFaults.subtract(stale)
            announcedOutages.subtract(stale)
            return false
        }

        // Clean up previously announced degradation banners
        for faultID in stale {
            removeNotification(id: "netdiag.\(faultID)")
        }
        announcedFaults.subtract(stale)
        announcedOutages.subtract(stale)

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
        announcedOutages.remove(id)

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
        announcedOutages.removeAll()
    }
}
