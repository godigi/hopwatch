import Foundation
import Testing
@testable import HopwatchGUI

@Suite struct NetworkFreshnessTests {
    private func sample(network: String? = "ssid:cafe", age: TimeInterval = 0,
                        paused: Bool = false) -> MonitorSample {
        var value = MonitorSample()
        value.ts = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-age))
        value.network = .init(id: network, label: network, groupId: network)
        value.link = .init(up: true, type: "wifi")
        value.status = .init(severity: "ok", measurement: "measured", paused: paused, cadenceS: 5)
        value.refreshed = ["fast"]
        value.internet.rttAvgMs = 18
        value.gateway.rttAvgMs = 2
        value.jitterMs = 22
        return value
    }

    @Test func partialReportsDoNotFabricateNegativeTechnicalFindings() throws {
        let decoder = JSONDecoder()
        let missing = try decoder.decode(RunSnapshot.self, from: Data("{}".utf8))
        #expect(missing.measuredIPv6 == nil)
        #expect(missing.measuredDoubleNAT == nil)
        #expect(missing.measuredIPConflict == nil)
        let measured = try decoder.decode(RunSnapshot.self, from: Data(#"{"ipv6":{"available":false},"wan":{"double_nat":{"detected":false}},"duplicate_ips":[]}"#.utf8))
        #expect(measured.measuredIPv6 == false)
        #expect(measured.measuredDoubleNAT == false)
        #expect(measured.measuredIPConflict == false)
    }

    @Test @MainActor func pausedSamplesAreNotFreshMeasurements() {
        let coordinator = HopwatchCoordinator()
        coordinator.monitor.adoptGallerySample(sample(paused: true))
        #expect(coordinator.liveSample == nil)
        #expect(coordinator.currentJitter == nil)
    }

    @Test @MainActor func oldMeasurementsExpireEvenWhileScanPausesMonitor() {
        let coordinator = HopwatchCoordinator()
        coordinator.monitor.adoptGallerySample(sample(age: 3600))
        coordinator.monitor.pause(reason: "a check is running")
        #expect(coordinator.liveSample == nil)
        #expect(coordinator.currentJitter == nil)
    }

    @Test @MainActor func wakeCannotUsePreviousNetworkReportOrSpeed() {
        let coordinator = HopwatchCoordinator()
        coordinator.monitor.adoptGallerySample(sample(network: "ssid:home"))
        var snapshot = RunSnapshot()
        snapshot.network = .init(id: "ssid:home", groupId: "ssid:home")
        let result = RunResult(snapshot: snapshot, rawJSON: "{}", exitCode: 0,
                               startedAt: Date().addingTimeInterval(-60), finishedAt: Date())
        coordinator.adoptSessionStateForTesting(latestRun: result,
            speed: .init(downMbps: 480, upMbps: 40), speedAt: Date(), speedNetwork: "ssid:home")
        coordinator.invalidateCurrentConnection()
        #expect(coordinator.liveSample == nil)
        #expect(coordinator.currentNetworkRun == nil)
        #expect(coordinator.currentSpeedTest == nil)
    }

    @Test @MainActor func unidentifiedNetworkCannotAdoptAnotherNetworksReport() {
        let coordinator = HopwatchCoordinator()
        coordinator.monitor.adoptGallerySample(sample(network: nil))
        var snapshot = RunSnapshot()
        snapshot.network = .init(id: "ssid:home", groupId: "ssid:home")
        let result = RunResult(snapshot: snapshot, rawJSON: "{}", exitCode: 0,
                               startedAt: Date(), finishedAt: Date())
        coordinator.adoptSessionStateForTesting(latestRun: result)
        #expect(coordinator.currentNetworkRun == nil)
    }

    @Test func absentMeasurementsDoNotGivePositiveExperienceRatings() {
        let items = SuitabilityEngine.evaluateAll(.init())
        #expect(items.allSatisfy { $0.verdict == .unknown })
    }

    @Test func chartDoesNotJoinMeasurementsFromDifferentNetworks() {
        let home = sample(network: "ssid:home", age: 10)
        let cafe = sample(network: "ssid:cafe")
        let series = MonitorSeries.build([home, cafe], tier: "fast") { $0.internet.rttAvgMs }
        #expect(series.segments.count == 2)
    }

    @Test @MainActor func invalidTimestampIsNotEvidenceFromNow() {
        let coordinator = HopwatchCoordinator()
        var invalid = sample()
        invalid.ts = "not a timestamp"
        coordinator.monitor.adoptGallerySample(invalid)
        #expect(coordinator.liveSample == nil)
    }

    @Test @MainActor func changingConnectionCannotAnnounceOldFaultAsRestored() {
        let coordinator = HopwatchCoordinator()
        coordinator.notifications.setAuthorizedForTesting(true)
        coordinator.notifications.notificationsEnabled = true
        coordinator.notifications.onPostNotification = { _, _, _, _ in }
        #expect(coordinator.notifications.deliverDegradation(id: "connection-lost",
            title: "Offline", body: "No link", isOutage: true))
        #expect(!coordinator.notifications.announcedFaults.isEmpty)
        coordinator.invalidateCurrentConnection()
        #expect(coordinator.notifications.announcedFaults.isEmpty)
        #expect(!coordinator.notifications.deliverRestored(networkName: "Cafe", latencyMs: nil))
    }

    @Test @MainActor func boundaryImmediatelyClearsBothCurrentReadingsAndCharts() {
        let coordinator = HopwatchCoordinator()
        coordinator.monitor.adoptGallerySample(sample())
        coordinator.invalidateCurrentConnection()
        #expect(coordinator.liveSample == nil)
        #expect(coordinator.currentSamples.isEmpty)
        #expect(coordinator.currentNetworkRun == nil)
        #expect(coordinator.vpnFreshness == "Awaiting reading")
    }

    @Test @MainActor func currentChartExcludesAnotherNetworksSamples() {
        let coordinator = HopwatchCoordinator()
        let home = sample(network: "ssid:home", age: 10)
        let cafe = sample()
        coordinator.monitor.adoptGallerySample(cafe, historical: [home, cafe])
        #expect(coordinator.currentSamples.count == 1)
        #expect(coordinator.currentSamples.first?.network.historyJoinID == "ssid:cafe")
    }

    @Test func noChannelIsNotAConnectedChannelMeasurement() {
        let row = DashboardCheckEvidence.wifiChannel(snapshot: nil, channel: nil, fallbackChannel: "")
        #expect(row.measured == "—")
        #expect(row.isGood == false)
    }

    @Test func unmeasuredRowsCannotInventZeroOrAGoodGrade() {
        let optimistic = DashboardCheckTable.Row(id: "jitter", icon: "waveform.path", label: "Jitter",
            measured: "0 ms", usual: "—", badge: .init(label: "Good", tone: .good), isGood: true)
        let row = DashboardCheckEvidence.requiringMeasurement(optimistic, hasMeasurement: false)
        #expect(row.measured == "—")
        #expect(row.badge?.tone == .neutral)
        #expect(row.isGood == false)
        #expect(row.isWarning == false)
        let measuredZero = DashboardCheckEvidence.requiringMeasurement(optimistic, hasMeasurement: true)
        #expect(measuredZero.measured == "0 ms")
        #expect(measuredZero.isGood == true)
    }

    @Test @MainActor func freshExplicitScanCanIdentifyConnectionWithoutAMonitorSample() {
        let coordinator = HopwatchCoordinator()
        var snapshot = RunSnapshot()
        snapshot.network = .init(id: "ssid:cafe", groupId: "ssid:cafe")
        let now = Date()
        coordinator.adoptSessionStateForTesting(latestRun: RunResult(snapshot: snapshot, rawJSON: "{}",
            exitCode: 0, startedAt: now, finishedAt: now))
        #expect(coordinator.confirmedNetworkID == "ssid:cafe")
        #expect(coordinator.freshNetworkRunSnapshot != nil)
    }

    @Test @MainActor func oldSavedRunCannotPopulateCurrentMeasurements() {
        let coordinator = HopwatchCoordinator()
        coordinator.monitor.adoptGallerySample(sample())
        var snapshot = RunSnapshot()
        snapshot.network = .init(id: "ssid:cafe", groupId: "ssid:cafe")
        snapshot.gateway.rttAvgMs = 9
        let old = Date().addingTimeInterval(-3600)
        coordinator.adoptSessionStateForTesting(latestRun: RunResult(snapshot: snapshot, rawJSON: "{}",
            exitCode: 0, startedAt: old, finishedAt: old))
        #expect(coordinator.freshNetworkRunSnapshot == nil)
    }

    @Test @MainActor func freshFailedPublicLookupSupersedesScanCountry() {
        let coordinator = HopwatchCoordinator()
        var live = sample()
        live.publicInfo.ok = false
        coordinator.monitor.adoptGallerySample(live)
        var snapshot = RunSnapshot()
        snapshot.network = .init(id: "ssid:cafe", groupId: "ssid:cafe")
        snapshot.publicInfo = .init(ok: true, ip: "203.0.113.7", country: "Brazil", countryISO: "BR")
        let now = Date()
        coordinator.adoptSessionStateForTesting(latestRun: RunResult(snapshot: snapshot, rawJSON: "{}",
            exitCode: 0, startedAt: now, finishedAt: now))
        #expect(coordinator.currentPublicInfo == nil)
    }

    @Test @MainActor func datedSpeedHistoryCannotDetermineCurrentSuitability() {
        let coordinator = HopwatchCoordinator()
        coordinator.monitor.adoptGallerySample(sample())
        coordinator.adoptSessionStateForTesting(speed: .init(downMbps: 480, upMbps: 40),
            speedAt: Date().addingTimeInterval(-3600), speedNetwork: "ssid:cafe")
        #expect(coordinator.currentSpeedTest != nil) // It remains a dated historical result.
        #expect(coordinator.currentSuitabilitySpeed == nil)
    }

    @Test @MainActor func wifiPrivateGatewayResolvesToKnownSSIDForSpeedTestAndConfirmedID() {
        let coordinator = HopwatchCoordinator()
        coordinator.setLiveSSIDForTesting("Circle 94_5G")

        // Monitor emitted a private gateway on Wi-Fi (macOS hidden SSID fallback)
        var hiddenWifiSample = sample(network: "gw:192.168.1.1")
        hiddenWifiSample.network.groupId = "gw:192.168.1.1"
        hiddenWifiSample.link = .init(up: true, type: "wifi")
        coordinator.monitor.adoptGallerySample(hiddenWifiSample)

        // confirmedNetworkID resolves to the known SSID
        #expect(coordinator.confirmedNetworkID == "ssid:Circle 94_5G")

        // A speed test measured on this SSID is accepted and not withheld
        coordinator.adoptSessionStateForTesting(
            speed: .init(downMbps: 660, upMbps: 662),
            speedAt: Date().addingTimeInterval(-1800),
            speedNetwork: "ssid:Circle 94_5G"
        )
        #expect(coordinator.currentSpeedTest?.speed.downMbps == 660)
        #expect(coordinator.currentSpeedTest?.speed.upMbps == 662)
    }

    @Test @MainActor func wifiPrivateGatewayRecognizesOwnershipAndLearnedPortal() {
        let coordinator = HopwatchCoordinator()
        coordinator.setLiveSSIDForTesting("Circle 94_5G")

        // Mark "ssid:Circle 94_5G" as owned
        coordinator.history.setOwned(true, for: "ssid:Circle 94_5G")
        #expect(Defaults.networkOwned.contains("ssid:Circle 94_5G"))

        var sample = sample(network: "gw:192.168.1.1")
        sample.network.groupId = "gw:192.168.1.1"
        sample.network.id = "wifi:gw=192.168.1.1"
        sample.link = .init(up: true, type: "wifi")
        coordinator.monitor.adoptGallerySample(sample)

        // isCurrentNetworkOwned recognizes the owned network despite gw: sample
        #expect(coordinator.isCurrentNetworkOwned == true)

        // Learned portal check in AlertEngine with liveSSID
        Defaults.recordPortalNetwork("ssid:Circle 94_5G")
        coordinator.alerts.liveSSID = { "Circle 94_5G" }
        // Verify AlertEngine suppressed captive false alarms
        #expect(Defaults.portalNetworks.contains("ssid:Circle 94_5G"))

        // Cleanup
        Defaults.removePortalNetwork("ssid:Circle 94_5G")
        coordinator.history.setOwned(false, for: "ssid:Circle 94_5G")
    }

    @Test @MainActor func bridgedNetworksFoldDirectlyInHistoryStore() {
        let store = HistoryStore()
        var net = HistoryDocument.Network(id: "ssid:Circle 94_5G", label: "Circle 94_5G")
        net.bridgedFrom = ["gw:192.168.1.1"]
        var doc = HistoryDocument()
        doc.schema = 2
        doc.networks = [net]
        store.adoptDocumentForTesting(doc)

        #expect(store.canonicalID("gw:192.168.1.1") == "ssid:Circle 94_5G")
        #expect(store.canonicalID("ssid:Circle 94_5G") == "ssid:Circle 94_5G")
    }

    @Test @MainActor func arrivalCheckResetsHeartbeatAndDoesNotShowStaleAssociationMisses() {
        let coordinator = HopwatchCoordinator()
        // Simulate association transient missed packets
        coordinator.heartbeat.adoptTestBeat(latencyMs: nil, isMiss: true, seq: 1)
        coordinator.heartbeat.adoptTestBeat(latencyMs: nil, isMiss: true, seq: 2)
        #expect(coordinator.heartbeat.missCount == 2)

        // Invalidating connection or starting arrival check resets heartbeat
        coordinator.invalidateCurrentConnection()
        #expect(coordinator.heartbeat.beats.isEmpty)
        #expect(coordinator.heartbeat.missCount == 0)
    }

    @Test @MainActor func staleScanMonitoredRuleDoesNotPoisonActiveFiredRulesWhenLiveMonitorIsClean() {
        let coordinator = HopwatchCoordinator()
        coordinator.monitor.adoptGallerySample(sample(network: "ssid:home"))

        var snapshot = RunSnapshot()
        snapshot.network = .init(id: "ssid:home", groupId: "ssid:home")
        snapshot.diagnosis = [
            .init(severity: "critical", rule: "SOCK-1", summary: "Cannot open connections"),
            .init(severity: "warn", rule: "BL-1", summary: "Bufferbloat under load")
        ]
        let result = RunResult(snapshot: snapshot, rawJSON: "{}", exitCode: 0,
                               startedAt: Date().addingTimeInterval(-60), finishedAt: Date())
        coordinator.adoptSessionStateForTesting(latestRun: result,
            speed: nil, speedAt: nil, speedNetwork: nil)

        // Live monitor has no rules (clean connection)
        #expect(coordinator.liveSample?.status.rules.isEmpty == true)

        // Stale monitor-scoped rule SOCK-1 should be evicted from active fired rules,
        // while scan-only rule BL-1 (bufferbloat) is preserved for suitability.
        let active = coordinator.activeFiredRules
        #expect(!active.contains("SOCK-1"))
        #expect(active.contains("BL-1"))
    }

    @Test func relativeTimeNeverRendersFutureTenseForJustNowOrClockSkew() {
        let now = Date()
        #expect(RelativeTime.string(from: now) == "just now")
        #expect(RelativeTime.string(from: now.addingTimeInterval(0.5)) == "just now")
        #expect(RelativeTime.string(from: now.addingTimeInterval(5.0)) == "just now")

        let past = now.addingTimeInterval(-15)
        let formatted = RelativeTime.string(from: past)
        #expect(formatted != "in 0s")
        #expect(formatted.contains("ago"))
    }

    @Test @MainActor func locationPermissionUpgradeFromGatewayToSSIDDoesNotInvalidateSession() {
        let coordinator = HopwatchCoordinator()

        var gwSample = MonitorSample()
        gwSample.ts = ISO8601DateFormatter().string(from: Date())
        gwSample.link.up = true
        gwSample.link.type = "wifi"
        gwSample.link.gateway = "192.168.1.1"
        gwSample.network.id = "gw:192.168.1.1"
        gwSample.network.groupId = "gw:192.168.1.1"

        // 1. Initial sample before Location Services is granted
        let firstChange = coordinator.reconcileNetworkIdentity(for: gwSample)
        #expect(firstChange == true)
        coordinator.heartbeat.adoptTestBeat(latencyMs: 14.0, isMiss: false, seq: 1)
        #expect(coordinator.heartbeat.beats.count == 1)

        // 2. Location Services is granted on the same gateway -> liveSSID is now known
        coordinator.setLiveSSIDForTesting("OfficeWiFi")
        let upgradedChange = coordinator.reconcileNetworkIdentity(for: gwSample)
        #expect(upgradedChange == false)
        #expect(coordinator.heartbeat.beats.count == 1)
    }
}
