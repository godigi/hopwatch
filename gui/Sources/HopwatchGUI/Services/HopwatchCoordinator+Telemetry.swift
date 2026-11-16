import CoreWLAN
import Foundation

// MARK: - Sample Freshness, Suitability, Health & Sharing

extension HopwatchCoordinator {

    var latestSampleIsStale: Bool {
        _ = staleEpoch
        return computeSampleIsStale(now: Date())
    }

    func computeSampleIsStale(now: Date) -> Bool {
        guard !stalenessSuspended, let sample = monitor.latest else { return false }
        let reference = max(
            sample.timestamp,
            monitor.awaitingSince ?? .distantPast,
            monitor.lastSpawnedAt ?? .distantPast
        )
        return SampleFreshness.isWatchdogStale(
            sampleAge: now.timeIntervalSince(reference),
            cadenceS: sample.status.cadenceS,
            observing: Defaults.monitoringEnabled && !monitor.isPausedForAnyReason,
            samplePaused: sample.status.paused)
    }

    var liveSample: MonitorSample? {
        _ = staleEpoch
        if Defaults.monitoringEnabled,
           !monitor.isPaused(besides: Self.scanPauseReason),
           let sample = monitor.latest,
           !monitor.isAwaitingFirstSample,
           !sample.status.paused {
            let reference = max(sample.timestamp, monitor.lastSpawnedAt ?? .distantPast)
            guard stalenessSuspended
                  || Date().timeIntervalSince(reference)
                     <= SampleFreshness.watchdogWindow(cadenceS: sample.status.cadenceS)
            else { return nil }
            return sample
        }
        if !linkIsDown,
           !isArrivalCheck,
           Defaults.monitoringEnabled,
           !monitor.isPaused(besides: Self.scanPauseReason),
           (isScanning || monitor.isAwaitingFirstSample),
           let cached = preScanSample,
           cached.link.up,
           stalenessSuspended || Date().timeIntervalSince(cached.timestamp) <= 180 {
            return cached
        }
        return nil
    }

    var confirmedNetworkID: String? {
        if let sample = liveSample { return resolvedNetworkID(for: sample) }
        guard let identity = scanIdentity,
              Date().timeIntervalSince(identity.finishedAt) <= SampleFreshness.window(cadenceS: nil),
              identity.startedAt >= max(connectionChangedAt ?? .distantPast, monitor.awaitingSince ?? .distantPast)
        else { return nil }
        return identity.id
    }

    var currentSamples: [MonitorSample] {
        guard let id = confirmedNetworkID ?? (monitor.isAwaitingFirstSample ? nil : resolvedNetworkID(for: monitor.latest)) else { return [] }
        let canonical = history.canonicalID(id)
        return monitor.recent.filter {
            !$0.status.paused && (resolvedNetworkID(for: $0).map(history.canonicalID) == canonical || $0.network.historyJoinID.map(history.canonicalID) == canonical)
        }
    }

    var currentNetworkEvents: [NetworkEvent] { currentNetworkEvents(withinHours: 24) }

    func currentNetworkEvents(withinHours hours: Double?) -> [NetworkEvent] {
        guard let id = confirmedNetworkID ?? (monitor.isAwaitingFirstSample ? nil : resolvedNetworkID(for: monitor.latest)) else { return [] }
        let canonical = history.canonicalID(id)
        let pool = hours.map { eventLog.within(hours: $0) } ?? eventLog.events
        return pool.filter { event in
            if event.network.flatMap(NetworkIdentity.canonical).map(history.canonicalID) == canonical
                || event.network.map(history.canonicalID) == canonical {
                return true
            }
            if let net = event.network, NetworkIdentity.isPrivateOrLocalGateway(net) {
                if let liveSsid = liveSSID, (canonical == "ssid:\(liveSsid)" || canonical == history.canonicalID("ssid:\(liveSsid)")) {
                    return true
                }
            }
            return false
        }
    }

    func clearEventLog() {
        eventLog.clear()
    }

    func exportActivityCSV(currentNetworkOnly: Bool) -> String {
        let events = currentNetworkOnly ? currentNetworkEvents(withinHours: nil) : eventLog.events
        return EventStore.exportCSV(from: events)
    }

    func exportActivityMarkdown(currentNetworkOnly: Bool) -> String {
        let events = currentNetworkOnly ? currentNetworkEvents(withinHours: nil) : eventLog.events
        let netName = currentNetworkOnly ? (wifiDisplayName ?? (linkIsWiFi ? "Wi-Fi" : "Ethernet")) : nil
        return EventStore.exportMarkdown(from: events, network: netName)
    }

    var latestCurrentNetworkEvent: NetworkEvent? {
        NetworkEvent.latestCondition(in: currentNetworkEvents)
    }

    var liveAvailability: AvailabilityEngine.Result {
        let events = currentNetworkEvents
        let result = AvailabilityEngine.evaluate(
            networkEvents: events,
            allRecentEvents: eventLog.within(hours: 24),
            currentRunAvailability: currentRunResult?.snapshot.availability,
            heartbeatMisses: heartbeat.missCount,
            heartbeatTotal: heartbeat.totalCount,
            networkConnectedAt: connectionChangedAt
        )
        _ = DataSanityWatchdog.checkAvailability(
            result: result,
            events: events,
            heartbeatMisses: heartbeat.missCount
        )
        return result
    }

    var vpnFreshness: String {
        if !Defaults.monitoringEnabled || monitor.isPaused(besides: Self.scanPauseReason) {
            return "Monitoring paused"
        }
        if latestSampleIsStale { return "Not reporting" }
        guard let sample = liveSample else { return "Awaiting reading" }
        let age = Date().timeIntervalSince(sample.timestamp)
        return age >= 0 && age < 5 ? "Checked just now"
            : "Checked \(RelativeTime.string(from: sample.timestamp))"
    }

    func startStaleWatch() {
        staleWatchTask?.cancel()
        staleWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { return }
                self.tickAgeDrivenState()
            }
        }
    }

    func tickAgeDrivenState() { staleEpoch += 1 }

    var hasRecentRoam: Bool {
        if monitor.latest?.changes.contains(where: { $0.kind == "wifi-roamed" }) == true {
            return true
        }
        let windowSamples = monitor.recent.suffix(10)
        return windowSamples.contains { sample in
            sample.changes.contains { $0.kind == "wifi-roamed" }
        }
    }

    var effectiveLoss: Double? {
        if linkIsDown { return nil }
        return EffectiveLoss.compute(
            internetLoss: liveSample?.internet.lossPct
                ?? freshNetworkRunSnapshot?.internetLatency.lossPct,
            gatewayLoss: liveSample?.gateway.lossPct
                ?? freshNetworkRunSnapshot?.gateway.lossPct,
            filtering: lossFiltering,
            hasRecentRoam: hasRecentRoam
        )
    }

    var activeFiredRules: Set<String> {
        let liveRules = Set(liveSample?.status.rules ?? [])
        guard let snap = freshNetworkRunSnapshot else { return liveRules }
        let snapRules = snap.diagnosis.compactMap(\.rule)
        guard liveSample != nil else { return Set(snapRules) }

        let catalog = rulesCatalog.catalog
        var combined = liveRules
        for ruleID in snapRules {
            let isMonitored: Bool
            if let scope = catalog?[ruleID]?.scope {
                isMonitored = (scope == "both" || scope == "monitor")
            } else {
                isMonitored = ruleID == "SOCK-1" || ruleID == "CONN-1" || ruleID == "HOG-1"
                    || ruleID == "D1" || ruleID.hasPrefix("P") || ruleID.hasPrefix("G")
                    || ruleID == "N1" || ruleID == "N1c" || ruleID == "WJ-1"
                    || ruleID == "WF-1" || ruleID == "DH-3" || ruleID.hasPrefix("CP")
            }
            if !isMonitored {
                combined.insert(ruleID)
            }
        }
        return combined
    }

    var activeScanProgressSubtitle: String? {
        guard isScanning else { return nil }
        if progress.isSpeedTesting, let speed = progress.speed {
            let arrow = speed.directionSymbol.map { "\($0) " } ?? ""
            let stage = speed.stage.isEmpty ? "Speed test" : PhaseLabel.humanised(speed.stage)
            if let mbps = speed.mbps {
                return String(format: "%@%@ · %.1f Mbps", arrow, stage, mbps)
            }
            return "\(arrow)\(stage)…"
        }
        if let bb = progress.bufferbloat, bb.stage != "" {
            return "Testing bufferbloat & latency under load…"
        }
        if let running = progress.runningPhase {
            return "\(running.label)…"
        }
        return nil
    }

    var lossFiltering: EffectiveLoss.Filtering {
        EffectiveLoss.filtering(
            icmpFilteredFlag: liveSample?.status.icmpFiltered == true,
            ruleIDs: Array(activeFiredRules)
        )
    }

    var linkIsDown: Bool {
        _ = staleEpoch
        return LinkState.isDown(sample: monitor.latest)
    }

    var linkIsWiFi: Bool {
        if linkIsDown { return CWWiFiClient.shared().interface()?.powerOn() ?? true }
        return monitor.latest?.link.isWiFi ?? true
    }

    var currentJitter: Double? {
        if linkIsDown { return nil }
        guard let live = liveSample else { return nil }
        if currentSamples.count < 2, (live.liveJitterMs ?? 0) >= 30.0 {
            return nil
        }
        if let jitter = live.liveJitterMs { return jitter }
        return MonitorSeries.movingJitter(samples: currentSamples)
    }

    var currentSuitabilityItems: [SuitabilityEngine.Item] {
        let snap = freshNetworkRunSnapshot
        let sample = liveSample
        let paused = !Defaults.monitoringEnabled || monitor.isPaused(besides: Self.scanPauseReason)
        let inputs = SuitabilityEngine.Inputs(
            monitorSample: sample,
            speedTest: currentSuitabilitySpeed,
            savedSuitability: snap?.suitability,
            catalog: rulesCatalog.catalog,
            firedRules: Array(activeFiredRules),
            isLinkUp: sample?.link.up ?? true,
            isDoubleNat: snap?.wan.doubleNat.detected ?? false,
            mtu: snap?.mtu.effective ?? snap?.mtu.pathSize,
            vpnActive: sample?.vpn.active ?? snap?.vpn.active ?? false,
            vpnName: sample?.vpn.name ?? snap?.vpn.name,
            currentJitter: currentJitter,
            effectiveLoss: effectiveLoss,
            lossFiltering: lossFiltering,
            isSettling: isSettling,
            isArrivalCheck: isArrivalCheck,
            isPaused: paused,
            isStale: latestSampleIsStale
        )
        return SuitabilityEngine.evaluateAll(inputs)
    }

    var currentDegradedExperience: StageResolver.DegradedSnapshot? {
        SuitabilityEngine.synthesizeDegradedExperience(
            items: currentSuitabilityItems,
            monitorSample: liveSample,
            currentJitter: currentJitter,
            effectiveLoss: effectiveLoss,
            lossFiltering: lossFiltering
        )
    }

    func currentStage(monitoringEnabled: Bool = Defaults.monitoringEnabled) -> StageResolver.Stage {
        let sample = liveSample
        return StageResolver.resolve(.init(
            isScanning: isScanning,
            isArrivalCheck: isArrivalCheck,
            isBackgroundScan: isBackgroundInvestigating,
            monitoringEnabled: monitoringEnabled,
            isPausedForAnyReason: monitor.isPaused(besides: Self.scanPauseReason),
            pauseReason: monitor.pauseReason,
            lastError: monitor.lastError,
            monitorRunning: monitor.isRunning,
            activeAlert: alerts.urgentActiveSorted.first.map {
                StageResolver.AlertSnapshot(
                    title: $0.title, body: $0.body,
                    raisedAt: $0.raisedAt, rules: $0.rules,
                    severityRank: $0.rules.map(severityRank(forRuleID:)).max() ?? 0,
                    id: $0.id,
                    isUrgent: $0.isUrgent)
            },
            severity: sample?.status.severity ?? "ok",
            linkUp: !linkIsDown,
            sampleStale: latestSampleIsStale,
            measurementState: sample?.status.measurement ?? "unknown",
            activeResolution: activeResolution?.snapshot,
            degradedExperience: currentDegradedExperience,
            settling: isSettling
        ))
    }

    var currentStability: ConnectionStability {
        if linkIsDown { return .noLink }
        let rtt = liveSample?.internet.rttAvgMs ?? liveSample?.gateway.rttAvgMs
            ?? freshNetworkRunSnapshot?.internetLatency.rttAvgMs ?? freshNetworkRunSnapshot?.gateway.rttAvgMs
        return ConnectionStability.evaluate(rtt: rtt, jitter: currentJitter, loss: effectiveLoss)
    }

    var currentHealth: Health {
        let activeSnapshot = alerts.urgentActiveSorted.first.map {
            StageResolver.AlertSnapshot(
                title: $0.title, body: $0.body,
                raisedAt: $0.raisedAt, rules: $0.rules,
                severityRank: $0.rules.compactMap(severityRank(forRuleID:)).max() ?? 0,
                id: $0.id,
                isUrgent: $0.isUrgent)
        }
        let currentRunHealth = monitor.latest == nil
            ? currentNetworkRun?.snapshot.worstSeverity : nil

        let isDetermining = isSettling
            || monitor.isAwaitingFirstSample
            || (isScanning && isArrivalCheck)
            || (liveSample != nil && liveSample?.status.measurement != "measured")
            || (liveSample == nil && freshNetworkRunSnapshot == nil)

        let sampleSeverity = liveSample?.status.severity ?? "ok"
        let effectiveDegradedIsCritical: Bool? =
            (sampleSeverity != "critical" && sampleSeverity != "warn")
            ? currentDegradedExperience?.isCritical
            : nil

        return HealthResolver.resolve(.init(
            isScanning: isScanning,
            isArrivalCheck: isArrivalCheck,
            monitoringEnabled: Defaults.monitoringEnabled,
            isPausedForAnyReason: monitor.isPaused(besides: Self.scanPauseReason),
            monitorRunning: monitor.isRunning,
            activeAlert: activeSnapshot,
            sampleHealth: liveSample?.health,
            runHealth: currentRunHealth,
            linkDown: linkIsDown,
            sampleStale: latestSampleIsStale,
            isChecking: isDetermining,
            degradedIsCritical: effectiveDegradedIsCritical))
    }

    func severityRank(forRuleID ruleID: String) -> Int {
        Self.severityRank(rulesCatalog.catalog?[ruleID]?.severity)
    }

    static func severityRank(_ severity: String?) -> Int {
        switch severity {
        case "critical": return 3
        case "warn", "warning": return 2
        case "info": return 1
        default: return 0
        }
    }

    private static func tieBreakWeight(forRuleID id: String) -> Int {
        switch id {
        case "G1", "G2", "G3": return 3
        case "W1", "W2", "W3", "W4", "WS-1": return 2
        case "L1", "L2": return 0
        default: return 1
        }
    }

    static func worstRule(among ruleIDs: [String],
                          catalog: RulesCatalog?) -> RulesCatalog.Rule? {
        guard let catalog else { return nil }
        var best: RulesCatalog.Rule?
        var bestRank = Int.min
        var bestTieWeight = Int.min
        for id in ruleIDs {
            guard let rule = catalog[id] else { continue }
            let rank = severityRank(rule.severity)
            let tieWeight = tieBreakWeight(forRuleID: id)
            if rank > bestRank || (rank == bestRank && tieWeight > bestTieWeight) {
                best = rule
                bestRank = rank
                bestTieWeight = tieWeight
            }
        }
        return best
    }

    static func headlineText(forRulesIn ruleIDs: [String],
                             catalog: RulesCatalog?) -> String? {
        guard let worst = worstRule(among: ruleIDs, catalog: catalog) else { return nil }
        if let blurb = worst.blurb, !blurb.isEmpty { return blurb }
        if let title = worst.title, !title.isEmpty { return title }
        return nil
    }

    var headline: String {
        if isScanning && !isBackgroundInvestigating { return "Running a network check…" }
        if !Defaults.monitoringEnabled { return "Monitoring is off." }
        if monitor.isPaused(besides: Self.scanPauseReason) {
            guard let reason = monitor.pauseReason else { return "Monitoring is paused." }
            return "Monitoring is paused — \(reason)."
        }
        if let error = monitor.lastError, !monitor.isRunning {
            return "The netdiag command needs attention — \(error)"
        }
        if linkIsDown {
            let offline = liveSample?.link.offline ?? monitor.latest?.link.offline
            let firing = monitor.latest?.status.rules ?? []
            if let summary = offline?.precursorSummary, !summary.isEmpty {
                return summary
            }
            if firing.contains("DH-3"),
               let text = Self.headlineText(forRulesIn: ["DH-3"], catalog: rulesCatalog.catalog) {
                return text
            }
            return Self.headlineText(forRulesIn: firing,
                                     catalog: rulesCatalog.catalog)
                ?? NoLinkCopy.fallbackSubtitle
        }
        if let alert = alerts.urgentActiveSorted.first {
            return alert.body.isEmpty ? alert.title : alert.body
        }
        if !monitor.isRunning {
            return "Reconnecting to the connection monitor…"
        }
        if latestSampleIsStale { return StaleSampleCopy.subtitle }
        if let sample = monitor.latest, liveSample == nil || sample.status.measurement != "measured" {
            return "Checking your connection — a live internet reading is not available yet."
        }
        if let sample = monitor.latest, sample.status.severity == "critical" || sample.status.severity == "warn" {
            if let text = Self.headlineText(forRulesIn: sample.status.rules,
                                            catalog: rulesCatalog.catalog) {
                return text
            }
        }
        if let res = activeResolution {
            return res.message.isEmpty ? res.title : "\(res.title) — \(res.message)"
        }
        if let sample = liveSample {
            let snap = currentNetworkRun?.snapshot
            let items = SuitabilityEngine.evaluateAll(.init(
                monitorSample: sample,
                speedTest: currentSuitabilitySpeed,
                savedSuitability: snap?.suitability,
                catalog: rulesCatalog.catalog,
                firedRules: sample.status.rules,
                isLinkUp: sample.link.up,
                isDoubleNat: snap?.wan.doubleNat.detected ?? false,
                mtu: snap?.mtu.effective ?? snap?.mtu.pathSize ?? 1500,
                vpnActive: sample.vpn.active,
                vpnName: sample.vpn.name,
                currentJitter: currentJitter,
                effectiveLoss: effectiveLoss,
                lossFiltering: lossFiltering,
                isSettling: isSettling,
                isArrivalCheck: isArrivalCheck
            ))
            if let degraded = SuitabilityEngine.synthesizeDegradedExperience(
                items: items,
                monitorSample: sample,
                currentJitter: currentJitter,
                effectiveLoss: effectiveLoss,
                lossFiltering: lossFiltering
            ) {
                return "\(degraded.headline) — \(degraded.subtitle)"
            }
        }
        let currentSnapshot = currentNetworkRun?.snapshot
        if let cause = currentSnapshot?.mostLikelyRootCause, !cause.isEmpty {
            let isLocationNotice = cause.localizedCaseInsensitiveContains("location services")
                || cause.localizedCaseInsensitiveContains("generic name")
                || cause.localizedCaseInsensitiveContains("not telling netdiag")
            if !isLocationNotice {
                return cause
            }
        }
        if monitor.latest == nil && currentNetworkRun == nil { return "Starting up…" }
        return "Nothing obviously wrong — your network looks healthy."
    }

    var isCurrentNetworkOwned: Bool {
        let candidate = confirmedNetworkID
            ?? resolvedNetworkID(for: liveSample ?? monitor.latest)
            ?? liveSample?.network.historyJoinID
            ?? monitor.latest?.network.historyJoinID
            ?? liveSample?.network.id
            ?? monitor.latest?.network.id
        guard let candidate else { return false }
        return history.isOwned(networkID: candidate)
    }

    var wifiDisplayName: String? {
        if let live = liveSSID, !live.isEmpty,
           !live.contains("<redacted>"), !live.contains("hidden by macOS") {
            if let custom = history.customName(for: "ssid:\(live)"), !custom.isEmpty,
               !custom.contains("<redacted>"), !custom.contains("hidden by macOS"),
               !Self.isRawNetworkKey(custom),
               custom != live {
                return custom
            }
            return live
        }

        if let id = monitor.latest?.network.historyJoinID, !id.starts(with: "gw:"),
           !NetworkIdentity.isPrivateOrLocalGateway(id) {
            if let custom = history.customName(for: id), !custom.isEmpty,
               !custom.contains("<redacted>"), !custom.contains("hidden by macOS"),
               !Self.isRawNetworkKey(custom) {
                return custom
            }
        }

        if let id = monitor.latest?.network.historyJoinID, !id.starts(with: "gw:"),
           !NetworkIdentity.isPrivateOrLocalGateway(id) {
            let hist = history.displayName(for: id)
            if !hist.isEmpty, hist != id, !hist.contains("<redacted>"),
               !hist.contains("hidden by macOS"), !Self.isRawNetworkKey(hist) {
                return hist
            }
        }
        let raw = monitor.latest?.network.label ?? currentNetworkRun?.snapshot.network.label
        guard let raw, !raw.isEmpty else { return nil }
        if raw.contains("<redacted>") || raw.contains("hidden by macOS")
            || Self.isRawNetworkKey(raw) {
            return nil
        }
        return raw
    }

    // MARK: - Sharing

    var currentReportRawJSON: String? {
        currentNetworkRun?.result.rawJSON
    }

    func shareCurrentReportText() async throws -> String {
        try await NetdiagRunner.share(rawJSON: currentReportRawJSON)
    }

    func shareCurrentReportJSON() async throws -> String {
        try await NetdiagRunner.shareJSON(rawJSON: currentReportRawJSON)
    }
}
