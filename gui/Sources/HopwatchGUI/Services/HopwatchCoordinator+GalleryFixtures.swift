import Foundation

// MARK: - Gallery & Test Fixtures

extension HopwatchCoordinator {

    /// Stand in for the arrival state the monitor would have established,
    /// for `GalleryMode` only. Writes nothing to `Defaults`.
    func adoptGalleryArrivalState(networkID: String?) {
        arrivalNetworkID = networkID.flatMap(HopwatchGUI.NetworkIdentity.canonical)
        arrivalState = .checked(depth: .full, at: Date(), runID: nil)
        arrivalIntent = .starting
    }

    /// Sets up a synthetic healthy sample for GalleryMode previews.
    func adoptGalleryMonitorSample(networkID: String?, displayName: String?) {
        let name = displayName ?? "Home Wi-Fi"
        self.liveSSID = name
        self.stalenessSuspended = true

        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var historySamples: [MonitorSample] = []
        let baselineGwRtt = 3.2
        let baselineInetRtt = 17.8

        for i in (0..<30).reversed() {
            let sampleDate = now.addingTimeInterval(-Double(i * 10))
            let gwJitter = Double((i * 7) % 5) * 0.2 - 0.4
            let inetJitter = Double((i * 13) % 7) * 0.4 - 1.2
            let s = MonitorSample(
                schema: 2,
                version: AppVersion.display,
                ts: formatter.string(from: sampleDate),
                seq: 100 - i,
                gapS: 0,
                jitterMs: 1.2,
                refreshed: ["fast", "medium", "slow"],
                link: .init(
                    up: true,
                    interface: "en0",
                    type: "wifi",
                    ip: "192.168.1.142",
                    gateway: "192.168.1.1",
                    gatewayMAC: "14:91:82:aa:bb:cc",
                    ssid: name,
                    bssid: "14:91:82:aa:bb:cc"
                ),
                network: .init(
                    id: networkID ?? "wifi:ssid=\(name)",
                    label: name,
                    groupId: networkID ?? "mac:14:91:82:aa:bb:cc"
                ),
                vpn: .init(
                    active: false,
                    type: nil,
                    name: nil
                ),
                gateway: .init(
                    lossPct: 0.0,
                    rttAvgMs: max(1.0, baselineGwRtt + gwJitter),
                    rttJitterMs: 0.4
                ),
                internet: .init(
                    lossPct: 0.0,
                    rttAvgMs: max(10.0, baselineInetRtt + inetJitter),
                    rttJitterMs: 1.2
                ),
                wifi: .init(
                    rssi: -52,
                    noise: -92,
                    snr: 40,
                    channel: "149 (5 GHz, 80 MHz)"
                ),
                dns: .init(
                    ok: true,
                    resolver: "192.168.1.1",
                    elapsedMs: 8.4
                ),
                tcp: .init(
                    anyOk: true,
                    targets: [
                        .init(host: "1.1.1.1", port: 443, ok: true, elapsedMs: 16.2),
                        .init(host: "8.8.8.8", port: 443, ok: true, elapsedMs: 18.1)
                    ]
                ),
                publicInfo: .init(
                    ok: true,
                    ip: "198.51.100.42",
                    isp: "Fiber Broadband",
                    asn: "AS13335",
                    city: "San Francisco",
                    country: "United States",
                    countryISO: "US",
                    captivePortal: false
                ),
                status: .init(
                    severity: "ok",
                    measurement: "measured",
                    rules: [],
                    icmpFiltered: false,
                    degraded: false,
                    paused: false,
                    cadenceS: 10
                ),
                changes: []
            )
            historySamples.append(s)
        }

        if let latestSample = historySamples.last {
            monitor.adoptGallerySample(latestSample, historical: historySamples)
        }
    }

    /// `--verify` only: put the session's report and speed test in place
    /// without running a scan or touching the CLI.
    func adoptSessionStateForTesting(latestRun: RunResult? = nil, hydrated: RunDetail? = nil,
                                     speed: RunSnapshot.Speedtest? = nil, speedAt: Date? = nil,
                                     speedNetwork: String? = nil) {
        self.latestRun = latestRun
        self.scanIdentity = nil
        if let latestRun { adoptAcceptedScanIdentity(latestRun) }
        self.hydratedReport = hydrated
        self.latestSpeedTest = speed
        self.latestSpeedTestAt = speedAt
        self.latestSpeedTestNetwork = speedNetwork
    }

    func handleSampleForTesting(_ sample: MonitorSample) {
        handleSample(sample)
        if heartbeat.beats.isEmpty {
            heartbeat.adoptTestBeat(latencyMs: 18.5, isMiss: false, seq: 1)
            heartbeat.adoptTestBeat(latencyMs: 22.1, isMiss: false, seq: 2)
            heartbeat.adoptTestBeat(latencyMs: 19.0, isMiss: false, seq: 3)
            heartbeat.adoptTestBeat(latencyMs: nil, isMiss: true, seq: 4)
            heartbeat.adoptTestBeat(latencyMs: 45.2, isMiss: false, seq: 5)
            heartbeat.adoptTestBeat(latencyMs: 18.5, isMiss: false, seq: 6)
        }
    }

    /// Gallery / visual audit helper: puts a synthetic scan state in place without spawning a child CLI.
    func adoptGalleryScanState(isScanning: Bool, depth: NetdiagRunner.Depth?, currentStep: String? = nil, alertTriggered: Bool? = nil) {
        if isScanning && depth != .quick {
            self.preScanSample = self.liveSample ?? self.preScanSample
        }
        self.isScanning = isScanning
        self.activeScanDepth = depth
        self.scanStartedAt = isScanning ? Date() : nil
        self.scanWasAlertTriggered = isScanning && (alertTriggered ?? (depth == .alertTriggered))
        progress.reset()
        if let currentStep, isScanning {
            let safeStep = currentStep.replacingOccurrences(of: "\"", with: "")
            progress.ingest(line: "{\"t\":\"phase\",\"name\":\"\(safeStep)\",\"state\":\"start\"}")
        }
    }

    func adoptGalleryLastAlertScanAt(_ date: Date?) {
        self.lastAlertTriggeredScanAt = date
    }

    /// Gallery / visual audit helper: settles arrival / connection grace state on a
    /// pre-joined simulated network so subsequent scenarios reflect live monitoring.
    func adoptGalleryArrivalSettled() {
        pendingArrivalNetworkID = nil
        connectionChangedAt = nil
        arrivalState = .checked(depth: .full, at: Date(), runID: nil)
        if isScanning {
            isScanning = false
            activeScanDepth = nil
            scanStartedAt = nil
            scanWasAlertTriggered = false
            scanTask?.cancel()
            scanTask = nil
            monitor.resume(reason: Self.scanPauseReason)
        }
    }

    /// Gallery / visual audit helper: adopts an active resolution banner for rendered inspection.
    func adoptGalleryResolution(_ res: ResolutionEvent?) {
        recentResolutions.removeAll()
        if let res {
            recentResolutions.append(res)
        }
    }

    /// Gallery / visual audit helper: resets alert and coordinator history cleanly between scenario renders.
    func resetGalleryState() {
        isScanning = false
        activeScanDepth = nil
        scanStartedAt = nil
        scanWasAlertTriggered = false
        pendingArrivalNetworkID = nil
        connectionChangedAt = nil
        arrivalState = .checked(depth: .full, at: Date(), runID: nil)
        scanTask?.cancel()
        scanTask = nil
        preScanSample = nil
        lastAlertTriggeredScanAt = nil
        healthyRecoverySince = nil
        lastUnhealthySample = nil
        lastSample = nil
        lastNetworkID = nil
        previousActiveAlerts.removeAll()
        recentResolutions.removeAll()
        alerts.invalidateConnection()
        heartbeat.reset()
        heartbeat.setFiltered(false)
        liveSSID = nil
        isTestingLiveSSID = false
        hydratedReport = nil
        latestRun = nil
        latestSpeedTest = nil
        latestSpeedTestAt = nil
        latestSpeedTestNetwork = nil
        stalenessSuspended = true
    }

    func setLiveSSIDForTesting(_ ssid: String?) {
        liveSSID = ssid
        isTestingLiveSSID = (ssid != nil)
    }

    /// Gallery fixture for the moved-network state (`--gallery-moved`).
    func adoptGalleryMovedNetwork() {
        guard var moved = monitor.latest else { return }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        moved.ts = formatter.string(from: Date())
        moved.network = .init(id: "wifi:ssid=Corner Cafe", label: "Corner Cafe", groupId: "ssid:corner-cafe")
        moved.link.ssid = "Corner Cafe"
        moved.publicInfo = .init()
        moved.gateway = .init()
        moved.internet = .init()
        moved.jitterMs = nil
        moved.dns = .init()
        moved.tcp = .init()
        moved.wifi = nil
        moved.status.measurement = "unknown"
        liveSSID = "Corner Cafe"
        monitor.adoptGallerySample(moved, historical: monitor.recent.dropLast() + [moved])
    }

    /// Gallery fixture for the stale-monitor state (`--gallery-stale`).
    func adoptGalleryStaleSample() {
        guard var old = monitor.latest else { return }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        old.ts = formatter.string(from: Date().addingTimeInterval(-300))
        monitor.adoptGallerySample(old, historical: monitor.recent.dropLast() + [old])
        stalenessSuspended = false
    }

    static let galleryPrecursorSummary =
        "Your router stopped responding right before Wi-Fi dropped, which usually means it restarted."
    static let galleryReasonLabel = "Not connected"

    /// Gallery fixture for the no-link state (`--gallery-no-link`).
    func adoptGalleryNoLinkSample(restarted: Bool = false) {
        guard var down = monitor.latest else { return }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        down.ts = formatter.string(from: Date())
        down.seq = (down.seq ?? 0) + 1
        down.link = .init(up: false, interface: nil, type: "wired", ip: nil, gateway: nil,
                          gatewayMAC: nil, ssid: nil, bssid: nil,
                          offline: .init(reason: "wifi-not-joined", downSince: nil,
                                         downDurationS: restarted ? 10 : 252,
                                         lastNetwork: restarted ? nil : "Home",
                                         precursor: restarted ? nil : "router-unreachable",
                                         precursorSummary: restarted ? nil : Self.galleryPrecursorSummary,
                                         reasonLabel: Self.galleryReasonLabel))
        down.gateway.lossPct = 10
        down.gateway.rttJitterMs = 3
        down.status = .init(severity: "critical", measurement: "link-down", rules: ["N1"],
                            icmpFiltered: false, degraded: true, paused: false, cadenceS: 5)
        monitor.adoptGallerySample(down, historical: monitor.recent + [down])
    }
}
