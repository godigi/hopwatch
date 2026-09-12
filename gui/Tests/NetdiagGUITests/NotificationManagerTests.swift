import Foundation
import Testing
@testable import NetdiagGUI

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

    @Test @MainActor func thirtyMinuteCooldownRateLimiting() {
        let mgr = NotificationManager()
        mgr.setAuthorizedForTesting(true)
        mgr.notificationsEnabled = true

        var delivered: [(id: String, title: String, body: String)] = []
        mgr.onPostNotification = { id, title, body, _ in
            delivered.append((id, title, body))
        }

        let t0 = Date()
        let didPost1 = mgr.deliverDegradation(id: "wifi-unstable", title: "Wi-Fi Unstable", body: "High packet loss", isOutage: false, now: t0)
        #expect(didPost1)
        #expect(delivered.count == 1)
        #expect(mgr.announcedFaults.contains("wifi-unstable"))

        // Attempt 5 minutes later (300s): should be suppressed by cooldown
        let t1 = t0.addingTimeInterval(300)
        let didPost2 = mgr.deliverDegradation(id: "wifi-unstable", title: "Wi-Fi Unstable", body: "High packet loss", isOutage: false, now: t1)
        #expect(!didPost2)
        #expect(delivered.count == 1)

        // Different fault id at t1: should be permitted
        let didPostOther = mgr.deliverDegradation(id: "dns-failing", title: "DNS Failing", body: "Lookups failing", isOutage: false, now: t1)
        #expect(didPostOther)
        #expect(delivered.count == 2)

        // Attempt original fault after 30 minutes (1801s): should be permitted
        let t2 = t0.addingTimeInterval(1801)
        let didPost3 = mgr.deliverDegradation(id: "wifi-unstable", title: "Wi-Fi Unstable", body: "High packet loss", isOutage: false, now: t2)
        #expect(didPost3)
        #expect(delivered.count == 3)
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
}
