import Foundation
import Testing
@testable import HopwatchGUI

@Suite struct NotificationManagerTests {

    @Test @MainActor func permissionsAndUserPreferenceGuards() {
        let mgr = NotificationManager()
        mgr.setAuthorizedForTesting(false)
        mgr.notificationsEnabled = true

        let unauth = mgr.canNotify(id: "test", isOutage: true)
        #expect(!unauth.allowed)
        #expect(unauth.reason?.contains("not authorized") == true)

        mgr.setAuthorizedForTesting(true)
        mgr.notificationsEnabled = false
        let disabled = mgr.canNotify(id: "test", isOutage: true)
        #expect(!disabled.allowed)
        #expect(disabled.reason?.contains("disabled by user") == true)

        mgr.notificationsEnabled = true
        let allowed = mgr.canNotify(id: "test", isOutage: true)
        #expect(allowed.allowed)
        #expect(allowed.reason == nil)
    }

    @Test @MainActor func outagesOnlyFilterBehavior() {
        let mgr = NotificationManager()
        mgr.setAuthorizedForTesting(true)
        mgr.notificationsEnabled = true
        mgr.scope = .outagesOnly

        // Non-outage degradation alert should be suppressed
        let degradation = mgr.canNotify(id: "wifi-unstable", isOutage: false)
        #expect(!degradation.allowed)
        #expect(degradation.reason?.contains("outages-only") == true)

        // Complete outage should be permitted
        let outage = mgr.canNotify(id: "connection-lost", isOutage: true)
        #expect(outage.allowed)

        // Switching scope back to all permits degradation
        mgr.scope = .all
        let allPermitted = mgr.canNotify(id: "wifi-unstable", isOutage: false)
        #expect(allPermitted.allowed)
    }

    @Test @MainActor func stormGuardNeverOutlastsAnAlertsOwnCooldown() {
        let mgr = NotificationManager()
        mgr.setAuthorizedForTesting(true)
        mgr.notificationsEnabled = true

        var delivered: [(id: String, silent: Bool)] = []
        mgr.onPostNotification = { id, _, _, silent in delivered.append((id, silent)) }

        let floor = NotificationManager.minimumRepeatInterval
        let t0 = Date()
        #expect(mgr.deliverDegradation(id: "wifi-unstable", title: "Wi-Fi Unstable", body: "High packet loss", isOutage: false, now: t0))
        #expect(mgr.announcedFaults.contains("wifi-unstable"))

        // A burst inside the storm guard is dropped.
        #expect(!mgr.deliverDegradation(id: "wifi-unstable", title: "Wi-Fi Unstable", body: "High packet loss", isOutage: false, now: t0.addingTimeInterval(floor / 2)))

        // Different id: independent.
        #expect(mgr.deliverDegradation(id: "dns-failing", title: "DNS Failing", body: "Lookups failing", isOutage: false, now: t0.addingTimeInterval(floor / 2)))

        // Five minutes on (the engine has already applied the definition's
        // own cooldown by the time it asks): permitted, not held for 30.
        #expect(mgr.deliverDegradation(id: "wifi-unstable", title: "Wi-Fi Unstable", body: "High packet loss", isOutage: false, now: t0.addingTimeInterval(300)))

        // An in-place update of a delivered notification: silent, and not
        // rate-limited.
        delivered.removeAll()
        #expect(mgr.deliverDegradation(id: "wifi-unstable", title: "Wi-Fi Unstable", body: "sentence", isOutage: false, now: t0.addingTimeInterval(301), replacing: true))
        #expect(delivered.count == 1 && delivered[0].silent)

        // Nothing delivered under this id, so nothing to update.
        #expect(!mgr.deliverDegradation(id: "vpn-dropped", title: "VPN", body: "sentence", isOutage: false, now: t0, replacing: true))
    }

    @Test @MainActor func restorationNotificationCleansUpAndAnnouncesRecovery() {
        let mgr = NotificationManager()
        mgr.setAuthorizedForTesting(true)
        mgr.notificationsEnabled = true

        var delivered: [(id: String, title: String, body: String)] = []
        var removed: [String] = []

        mgr.onPostNotification = { id, title, body, _ in
            delivered.append((id, title, body))
        }
        mgr.onRemoveNotification = { id in
            removed.append(id)
        }

        // With no previous degradation, deliverRestored is a no-op (no spam on ordinary reconnect)
        let noOpRestored = mgr.deliverRestored(networkName: "HomeNet", latencyMs: 14.0)
        #expect(!noOpRestored)
        #expect(delivered.isEmpty)

        // Deliver a degradation fault
        mgr.deliverDegradation(id: "connection-lost", title: "No Internet", body: "Gateway unreachable", isOutage: true)
        #expect(delivered.count == 1)
        #expect(mgr.announcedFaults.contains("connection-lost"))

        // Connection restored
        let didRestore = mgr.deliverRestored(networkName: "HomeNet 5G", latencyMs: 14.2)
        #expect(didRestore)
        #expect(removed.contains("netdiag.connection-lost"))
        #expect(mgr.announcedFaults.isEmpty)
        #expect(delivered.count == 2)

        let lastDelivered = delivered.last!
        #expect(lastDelivered.id == "netdiag.restored")
        #expect(lastDelivered.title == "Wi-Fi Restored")
        #expect(lastDelivered.body.contains("Reconnected to HomeNet 5G"))
        #expect(lastDelivered.body.contains("14ms latency"))
    }

    @Test @MainActor func authorizationStatusAndDeniedHandling() {
        let mgr = NotificationManager()
        #expect(!mgr.isAuthorized)
        #expect(!mgr.isDenied)
        #expect(mgr.authorizationStatus == .notDetermined)

        mgr.setAuthorizationStatusForTesting(.denied)
        #expect(!mgr.isAuthorized)
        #expect(mgr.isDenied)

        mgr.setAuthorizationStatusForTesting(.authorized)
        #expect(mgr.isAuthorized)
        #expect(!mgr.isDenied)

        mgr.setAuthorizationStatusForTesting(.provisional)
        #expect(mgr.isAuthorized)
        #expect(!mgr.isDenied)
    }

    @Test @MainActor func requestOrOpenSettingsWhenDeniedOpensSettings() async {
        let mgr = NotificationManager()
        mgr.setAuthorizationStatusForTesting(.denied)

        var openedSettings = false
        mgr.onOpenSystemSettings = {
            openedSettings = true
        }

        await mgr.requestOrOpenSettings()
        #expect(openedSettings)
    }

    @Test @MainActor func systemSettingsURLsTargetBundleID() {
        let modernURL = NotificationManager.systemSettingsURL(bundleID: "com.godigi.hopwatch")
        #expect(modernURL?.absoluteString == "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.godigi.hopwatch")

        let fallbackURL = NotificationManager.systemSettingsFallbackURL(bundleID: "com.godigi.hopwatch")
        #expect(fallbackURL?.absoluteString == "x-apple.systempreferences:com.apple.preference.notifications?id=com.godigi.hopwatch")
    }

    @Test @MainActor func notificationResponseInvokesHandler() {
        let mgr = NotificationManager()
        var openedDashboard = false
        mgr.onNotificationResponse = {
            openedDashboard = true
        }
        mgr.onNotificationResponse?()
        #expect(openedDashboard)
    }
}
