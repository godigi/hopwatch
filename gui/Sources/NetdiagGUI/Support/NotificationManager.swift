import Foundation
import UserNotifications
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
final class NotificationManager {

    private(set) var isAuthorized = false
    var notificationsEnabled: Bool = true
    var scope: NotificationScope = .all

    /// Internal tracking for rate limiting (cooldown per alert key)
    private var lastNotifiedAt: [String: Date] = [:]
    /// Tracks active faults that were announced via notification
    private(set) var announcedFaults: Set<String> = []

    /// Notification posting handler, overridable for testing
    var onPostNotification: ((_ id: String, _ title: String, _ body: String, _ isSilent: Bool) -> Void)?
    var onRemoveNotification: ((_ id: String) -> Void)?

    private let log = Logger(subsystem: "me.brianfreeman.netdiag", category: "notifications")

    init(notificationsEnabled: Bool = true, scope: NotificationScope = .all) {
        self.notificationsEnabled = notificationsEnabled
        self.scope = scope
    }

    // MARK: - Permission

    func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()
        do {
            isAuthorized = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            log.error("Notification authorization request failed: \(error.localizedDescription, privacy: .public)")
            isAuthorized = false
        }
    }

    func refreshAuthorization() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        isAuthorized = settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
    }

    /// For testing: set authorized state directly
    func setAuthorizedForTesting(_ authorized: Bool) {
        isAuthorized = authorized
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
