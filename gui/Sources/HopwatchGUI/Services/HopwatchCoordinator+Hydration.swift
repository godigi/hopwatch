import Foundation
import CoreWLAN
import os

// MARK: - Cold-launch hydration & display scoping

extension HopwatchCoordinator {

    /// Picks the newest run **on the network this machine is currently on**
    /// that counts as a check (`HistoryDocument.Run.isCheck` — the
    /// `run_mode` predicate docs/JSON-SCHEMA.md documents and
    /// `helpers/history.py` applies identically) and has an id `--show` can
    /// open, then fetches its full record via `details.detail(for:)`.
    ///
    /// - Parameter explicitNetworkID: The network to scope to, for a caller
    ///   with no live monitor to read one from (`GalleryMode`).
    func hydrateFromHistoryIfNeeded(explicitNetworkID: String? = nil) async {
        let generation = connectionGeneration
        if currentNetworkRun == nil {
            let current = explicitNetworkID ?? confirmedNetworkID
            let id: String?
            if let current {
                didHydrateForNetwork = true
                id = newestCheckID(onNetwork: current)
            } else if !Defaults.monitoringEnabled {
                didHydrateForNetwork = true
                id = history.recentChecks(limit: 1).compactMap(\.runID).first
            } else {
                id = nil
            }
            if let id {
                do {
                    let detail = try await details.detail(for: id)
                    guard generation == connectionGeneration,
                          explicitNetworkID != nil || current.map(history.canonicalID) == confirmedNetworkID.map(history.canonicalID)
                    else { return }
                    hydratedReport = detail
                } catch {
                    log.debug("cold-launch hydration skipped: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        if latestSpeedTest == nil {
            let current = explicitNetworkID ?? resolvedNetworkID(for: monitor.latest) ?? monitor.latest?.network.historyJoinID
            if let current { adoptStoredSpeedTest(for: current) }
        }
    }

    /// Replaces the in-memory speed test with the newest stored one *on this
    /// network* — a hydrated report's own if it is for this network, else the
    /// store's — or clears it when there is none.
    func adoptStoredSpeedTest(for networkID: String) {
        let hydratedID = hydratedReport.flatMap { $0.context.networkID ?? $0.run.network.historyJoinID }
        if let st = hydratedReport?.run.speedtest, st.downMbps != nil,
           let hydratedID,
           runIsForNetwork(hydratedID, live: networkID) {
            latestSpeedTest = st
            latestSpeedTestAt = hydratedReport?.run.timestamp.flatMap { FastISO8601.parse($0) }
            latestSpeedTestNetwork = networkID
        } else if let speed = history.latestSpeedTest(for: networkID) {
            latestSpeedTest = RunSnapshot.Speedtest(downMbps: speed.down, upMbps: speed.up)
            latestSpeedTestAt = speed.date
            latestSpeedTestNetwork = networkID
        } else {
            latestSpeedTest = nil
            latestSpeedTestAt = nil
            latestSpeedTestNetwork = nil
        }
    }

    /// The newest run on one network that counts as a check and carries an
    /// id `--show` can open.
    private func newestCheckID(onNetwork networkID: String) -> String? {
        var runs = history.runs(networkID: networkID, window: .all)
        if runs.isEmpty, let liveSsid = liveSSID, !liveSsid.isEmpty {
            runs = history.runs(networkID: "ssid:\(liveSsid)", window: .all)
        }
        return runs
            .filter { $0.isCheck && $0.runID != nil }
            .max { ($0.ts ?? "") < ($1.ts ?? "") }?
            .runID
    }

    // MARK: - Live Wi-Fi & Presentation Scoping

    /// Refreshes Location Services authorization and unredacts Wi-Fi details
    /// if newly granted.
    func refreshLocationState() {
        locationPermissions.refresh()
        if locationPermissions.isAuthorized {
            refreshLiveWiFi()
            adoptLiveSSIDAsNameIfNeeded()
        }
    }

    /// Refresh `liveSSID` from CoreWLAN. Called once per monitor sample
    /// rather than from a view body.
    func refreshLiveWiFi() {
        guard !isTestingLiveSSID else { return }
        guard locationPermissions.isAuthorized else {
            if liveSSID != nil { log.debug("wifi: location not authorized — SSID unavailable") }
            liveSSID = nil
            return
        }
        let client = CWWiFiClient.shared()
        let iface = client.interface() ?? client.interfaces()?.first { $0.powerOn() }
        guard let iface else {
            log.debug("wifi: no CoreWLAN interface (on ethernet, or WiFi off)")
            liveSSID = nil
            return
        }
        let name = iface.ssid()
        if let name, !name.isEmpty, !name.contains("<redacted>"), !name.contains("hidden by macOS") {
            log.debug("wifi: live SSID read OK")
            liveSSID = name
        } else {
            log.debug("wifi: CoreWLAN interface present but ssid() returned nil — location grant may be provisional or revoked")
            liveSSID = nil
        }
    }

    /// Adopt the live SSID as the current network's display name when no
    /// real name is recorded yet.
    func adoptLiveSSIDAsNameIfNeeded(for sample: MonitorSample? = nil) {
        guard let live = liveSSID, !live.isEmpty,
              !live.contains("<redacted>"), !live.contains("hidden by macOS") else { return }
        let currentSample = sample ?? monitor.latest
        guard let s = currentSample, !s.status.paused, s.link.up, s.link.isWiFi else { return }
        guard let id = s.network.historyJoinID, id.starts(with: "mac:") else { return }
        if let boundary = connectionChangedAt {
            guard s.timestamp >= boundary else { return }
        }
        if let sampleSSID = Self.readableSSID(s.link.ssid), !sampleSSID.isEmpty {
            guard sampleSSID == live else { return }
        }
        if let custom = history.customName(for: id), !custom.isEmpty,
           !custom.contains("<redacted>"), !custom.contains("hidden by macOS"),
           !Self.isRawNetworkKey(custom) {
            return
        }
        let current = history.displayName(for: id)
        guard current != live else { return }
        history.rename(id, to: live)
        log.info("adopted live SSID as name for \(id, privacy: .public)")
    }

    /// True when a "name" is actually a raw network key rather than
    /// anything a person wrote or recognised.
    static func isRawNetworkKey(_ s: String) -> Bool {
        s.starts(with: "wifi:mac=") || s.starts(with: "lan:mac=")
            || s.starts(with: "wifi:ssid=") || s.starts(with: "lan:gw=")
            || s.starts(with: "mac:") || s.starts(with: "gw:")
            || s.starts(with: "ssid:")
    }

    /// What `HomeView` has to render: either the run that finished in
    /// this session, or a historical one fetched to fill the screen before
    /// any scan has run this launch.
    enum ReportSource {
        case live(RunResult)
        case stored(RunDetail)
    }

    var reportSource: ReportSource? {
        let live = confirmedNetworkID
        if let latestRun, runIsForNetwork(latestRun.snapshot.network.historyJoinID, live: live) {
            return .live(latestRun)
        }
        if let hydratedReport,
           runIsForNetwork(hydratedReport.context.networkID ?? hydratedReport.run.network.historyJoinID, live: live) {
            return .stored(hydratedReport)
        }
        return nil
    }

    private func runIsForNetwork(_ runNetwork: String?, live: String?) -> Bool {
        guard let runNetwork, let live else { return false }
        if RunScope.isSameNetwork(run: runNetwork, live: live, canonical: history.canonicalID) {
            return true
        }
        if let liveSsid = liveSSID, !liveSsid.isEmpty {
            let liveTarget = "ssid:\(liveSsid)"
            if (runNetwork == liveTarget || history.canonicalID(runNetwork) == liveTarget) &&
                (NetworkIdentity.isPrivateOrLocalGateway(live) || live == liveTarget) {
                return true
            }
            if (live == liveTarget || history.canonicalID(live) == liveTarget) &&
                (NetworkIdentity.isPrivateOrLocalGateway(runNetwork) || runNetwork == liveTarget) {
                return true
            }
        }
        return false
    }

    var currentNetworkRun: CurrentNetworkRun? {
        guard let live = confirmedNetworkID else { return nil }
        if let latestRun, runIsForNetwork(latestRun.snapshot.network.historyJoinID, live: live) {
            return CurrentNetworkRun(result: latestRun, isLive: true)
        }
        if let hydratedReport,
           runIsForNetwork(hydratedReport.context.networkID ?? hydratedReport.run.network.historyJoinID, live: live) {
            return CurrentNetworkRun(result: cachedHydratedRunResult ?? hydratedReport.asRunResult, isLive: false)
        }
        return nil
    }

    var currentRunResult: RunResult? {
        currentNetworkRun?.result
    }

    var freshNetworkRunSnapshot: RunSnapshot? {
        _ = staleEpoch
        guard let run = currentNetworkRun,
              run.age() <= SampleFreshness.window(cadenceS: monitor.latest?.status.cadenceS),
              connectionChangedAt.map({ run.result.startedAt >= $0 }) ?? true
        else { return nil }
        return run.snapshot
    }

    var currentSpeedTest: (speed: RunSnapshot.Speedtest, at: Date?)? {
        guard let speed = latestSpeedTest else { return nil }
        guard let live = confirmedNetworkID ?? (monitor.isAwaitingFirstSample ? nil : resolvedNetworkID(for: monitor.latest)) else { return nil }
        guard runIsForNetwork(latestSpeedTestNetwork, live: live) else { return nil }
        return (speed, latestSpeedTestAt)
    }

    var currentSuitabilitySpeed: RunSnapshot.Speedtest? {
        if let speed = freshNetworkRunSnapshot?.speedtest { return speed }
        guard let current = currentSpeedTest, let date = current.at,
              Date().timeIntervalSince(date) <= SampleFreshness.window(cadenceS: liveSample?.status.cadenceS)
        else { return nil }
        return current.speed
    }

    var currentPublicInfo: MonitorSample.PublicInfo? {
        guard !linkIsDown else { return nil }
        if let sample = liveSample, sample.publicInfo.captivePortal == true {
            return nil
        }
        if let sample = liveSample, sample.publicInfo.ok == true, !(sample.publicInfo.countryISO ?? "").isEmpty {
            return sample.publicInfo
        }
        if let last = lastKnownPublicInfo {
            return last
        }
        if let sample = liveSample, sample.publicInfo.ok == false {
            return nil
        }
        let info = freshNetworkRunSnapshot?.publicInfo
        return info?.ok == false ? nil : info
    }
}
