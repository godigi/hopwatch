import Foundation
import os

// MARK: - Scans, Network Events & Resolution Evaluation

extension HopwatchCoordinator {

    func evaluateResolutions(sample: MonitorSample) {
        if activeResolution != nil {
            let hasLoss = (sample.gateway.lossPct ?? 0) >= 3.0 || (sample.internet.lossPct ?? 0) >= 3.0
            if !sample.link.up || sample.status.severity != "ok" || !alerts.active.isEmpty || hasLoss {
                dismissActiveResolution()
            }
        }

        guard sample.link.up, sample.status.severity == "ok", alerts.active.isEmpty, currentDegradedExperience == nil else {
            if sample.status.severity == "critical" || sample.status.severity == "warn" || sample.publicInfo.captivePortal == true || !alerts.active.isEmpty {
                lastUnhealthySample = sample
            }
            previousActiveAlerts = alerts.active
            lastSample = sample
            return
        }

        if let prev = lastUnhealthySample {
            if prev.publicInfo.captivePortal == true && sample.publicInfo.captivePortal == false {
                recordResolution(
                    title: "Online",
                    message: "Captive portal authentication succeeded. Internet access active.",
                    icon: "checkmark.circle.fill"
                )
            } else if let prevCh = prev.wifi?.channel, let prevChNum = Int(prevCh.prefix(while: { $0.isNumber })), prevChNum <= 14,
                      let currCh = sample.wifi?.channel, let currChNum = Int(currCh.prefix(while: { $0.isNumber })), currChNum >= 32 {
                recordResolution(
                    title: "Wi-Fi Improved",
                    message: "Moved from 2.4 GHz to 5 GHz (Ch \(currCh)). Negotiated higher throughput.",
                    icon: "wifi"
                )
            } else if let prevRssi = prev.wifi?.rssi, prevRssi <= -75,
                      let currRssi = sample.wifi?.rssi, currRssi >= -65 {
                recordResolution(
                    title: "Signal Restored",
                    message: "Wi-Fi signal jumped from \(prevRssi) dBm to \(currRssi) dBm (Excellent).",
                    icon: "wifi"
                )
            } else if (prev.gateway.lossPct ?? 0) >= 3.0 || (prev.internet.lossPct ?? 0) >= 3.0,
                      (sample.gateway.lossPct ?? 0) < 1.0 && (sample.internet.lossPct ?? 0) < 1.0 {
                let ping = sample.internet.rttAvgMs ?? sample.gateway.rttAvgMs
                let pingText = ping.map { "\(Int($0.rounded())) ms ping" } ?? "low latency"
                recordResolution(
                    title: "Network Stabilized",
                    message: "Packet loss resolved (0% loss, \(pingText)).",
                    icon: "checkmark.circle.fill"
                )
            } else if let clearedAlert = previousActiveAlerts.values.first {
                recordResolution(
                    title: "Issue Resolved",
                    message: "\(clearedAlert.title) is back to normal.",
                    icon: "checkmark.circle.fill"
                )
            }
            lastUnhealthySample = nil
        } else if let clearedAlert = previousActiveAlerts.values.first {
            recordResolution(
                title: "Issue Resolved",
                message: "\(clearedAlert.title) is back to normal.",
                icon: "checkmark.circle.fill"
            )
        }

        previousActiveAlerts = alerts.active
        lastSample = sample
    }

    /// `_mon_rules` in `lib/monitor.sh` automatically switches the running
    /// monitor from the fast cadence (5 s) to the degraded cadence (3 s) the
    /// instant severity becomes `warn` or `critical`.
    func considerInvestigationBurst(_ sample: MonitorSample) {
        let sev = sample.status.severity
        defer { lastSeverity = sev }
        let turnedBad = (sev == "warn" || sev == "critical")
            && lastSeverity != "warn" && lastSeverity != "critical"
        guard turnedBad,
              !sample.status.paused,
              monitor.isRunning, !monitor.isPaused,
              !isScanning,
              !monitor.isBursting,
              Defaults.monitoringEnabled else { return }
        log.info("severity turned \(sev, privacy: .public) — monitor entering degraded cadence")
    }

    func handleNetworkEvent(_ event: NetworkEventWatcher.Event) {
        switch event {
        case .bssidChanged, .linkChanged:
            log.debug("same-network roam or link change — forcing monitor refresh only")
            monitor.forceRefresh()
            return
        case .pathChanged(let satisfied, _):
            log.debug("network path changed (satisfied=\(satisfied)) — forcing monitor refresh")
            monitor.forceRefresh()
            return
        case .ssidChanged(let newSSID):
            let readable = Self.readableSSID(newSSID)
            let knownSSID = self.liveSSID ?? self.lastAssociatedSSID
            guard let readable, readable != knownSSID else {
                log.debug("ssidDidChange without a new SSID — refreshing Wi-Fi and forcing monitor refresh only")
                refreshLiveWiFi()
                monitor.forceRefresh()
                return
            }
            lastAssociatedSSID = readable
            liveSSID = readable
        }
        invalidateCurrentConnection()
        if Defaults.monitoringEnabled {
            if monitor.isRunning {
                monitor.forceRefresh()
            } else {
                monitor.start()
            }
        }
        log.debug("network event — refreshing history")
        Task { await history.load() }
        updateChecker.performDailyCheck()
    }

    func invalidateCurrentConnection(preserving sample: MonitorSample? = nil) {
        if isScanning {
            cancelScan()
            clearPendingArrival()
        }
        if sample == nil {
            lastNetworkID = nil
        }
        advanceConnectionGeneration()
        connectionChangedAt = Date()
        monitor.invalidateConnection(preserving: sample)
        hydratedReport = nil
        latestRun = nil
        scanIdentity = nil
        latestSpeedTest = nil
        latestSpeedTestAt = nil
        latestSpeedTestNetwork = nil
        lastKnownPublicInfo = nil
        didHydrateForNetwork = false
        routerAdminAvailable = false
        lastProbedRouterIP = nil
        lastSample = nil
        preScanSample = nil
        lastAlertTriggeredScanAt = nil
        healthyRecoverySince = nil
        lastUnhealthySample = nil
        lastSeverity = "ok"
        previousActiveAlerts = [:]
        alerts.invalidateConnection()
        heartbeatSeedMinSeq = 0
        heartbeat.reset()
        notifications.clearAnnouncedFaults()
        dismissActiveResolution()
        events.markSettling()
        refreshLiveWiFi()
    }

    // MARK: - Scans

    @discardableResult
    func runScan(depth: NetdiagRunner.Depth, reason: String, target: String? = nil) -> Bool {
        launch(depth: depth, reason: reason, target: target, adoptAsReport: true)
    }

    /// Whether the "Full check" action should be offered as runnable right
    /// now. Read by the views to disable the control and say why.
    var fullCheckIsSafe: Bool {
        FullCheckPolicy.isSafe(severity: monitor.latest?.status.severity ?? "")
    }

    /// The full battery: bufferbloat, the MTU probe, per-hop loss and a
    /// speed test. Refuses while the CLI's verdict is critical, falling back
    /// to `.alertTriggered`.
    @discardableResult
    func runFullCheck(reason: String = "you asked for a full check") -> Bool {
        guard fullCheckIsSafe else {
            return runScan(depth: .alertTriggered, reason: reason)
        }
        return runScan(depth: .full, reason: reason)
    }

    /// Runs a focused speed test (`--speed-only`) to measure download, upload,
    /// latency and jitter without running a full diagnostic check.
    @discardableResult
    func runSpeedTest(reason: String = "speed test requested") -> Bool {
        launch(depth: .speedOnly, reason: reason, target: nil, adoptAsReport: false)
    }

    @discardableResult
    private func launch(depth: NetdiagRunner.Depth, reason: String,
                        target: String? = nil, adoptAsReport: Bool) -> Bool {
        guard !isScanning else {
            log.debug("scan already running, ignoring request: \(reason, privacy: .public)")
            return false
        }
        isScanning = true
        activeScanDepth = depth
        scanStartedAt = Date()
        lastRunError = nil
        progress.reset()
        let generation = connectionGeneration
        let scanNetwork = confirmedNetworkID
        let wasArrival = isArrivalCheck
        if wasArrival {
            preScanSample = nil
            heartbeatSeedMinSeq = (monitor.latest?.seq ?? 0) + 1
            heartbeat.reset()
        } else {
            preScanSample = liveSample ?? preScanSample
        }

        monitor.pause(reason: Self.scanPauseReason)
        heartbeat.pause()
        alerts.scanInProgress = true

        scanTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.scanWasAlertTriggered {
                    self.lastAlertTriggeredScanAt = Date()
                }
                self.isScanning = false
                self.activeScanDepth = nil
                self.scanStartedAt = nil
                self.scanWasAlertTriggered = false
                self.alerts.scanInProgress = false
                self.alerts.scanEnded()
                self.monitor.resume(reason: Self.scanPauseReason)
                if wasArrival {
                    self.heartbeatSeedMinSeq = (self.monitor.latest?.seq ?? 0) + 1
                    self.heartbeat.reset()
                }
                self.heartbeat.resume()
                self.syncAlertPauseState()
                self.progress.processEnded(exit: nil)
            }
            do {
                let result = try await NetdiagRunner.run(depth: depth, target: target,
                                                         progress: self.progress)
                guard !Task.isCancelled else {
                    self.clearPendingArrival(failed: true)
                    return
                }
                let measured = result.snapshot.network.historyJoinID
                let matches = scanNetwork == nil || measured == nil || self.networkMatches(scanNetwork: scanNetwork, measured: measured!, snapshot: result.snapshot)
                guard generation == self.connectionGeneration, matches else {
                    self.clearPendingArrival(failed: true)
                    await self.history.load()
                    return
                }
                self.adoptAcceptedScanIdentity(result)
                if adoptAsReport {
                    self.latestRun = result
                    self.hydratedReport = nil
                    self.alerts.evaluate(run: result.snapshot)
                }
                await self.history.load()
                if self.latestSpeedTest == nil, let current = self.confirmedNetworkID {
                    self.adoptStoredSpeedTest(for: current)
                }
                guard generation == self.connectionGeneration else { return }
                self.finishArrivalIfPending(runID: result.snapshot.runID,
                                            measured: result.snapshot.network.historyJoinID)
                self.log.info("\(reason, privacy: .public) finished in \(result.duration, format: .fixed(precision: 1))s, exit \(result.exitCode)")
            } catch is CancellationError {
                self.clearPendingArrival(failed: true)
                self.log.debug("scan cancelled")
            } catch {
                self.clearPendingArrival(failed: true)
                self.lastRunError = error.localizedDescription
                self.log.error("scan failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return true
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
    }

    /// A successful speed-only check establishes identity even though it
    /// does not replace the full diagnostic report in `latestRun`.
    func adoptAcceptedScanIdentity(_ result: RunResult) {
        guard let id = result.snapshot.network.historyJoinID else { return }
        scanIdentity = (id, result.startedAt, result.finishedAt)
        if let speed = result.snapshot.speedtest, speed.downMbps != nil {
            latestSpeedTest = speed
            latestSpeedTestAt = result.finishedAt
            latestSpeedTestNetwork = id
        }
    }
}
