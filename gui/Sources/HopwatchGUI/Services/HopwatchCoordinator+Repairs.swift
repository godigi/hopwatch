import AppKit
import Foundation
import SystemConfiguration
import os

// MARK: - Repairs, Auto-Reconnect, Captive Portal & Custom DNS

extension HopwatchCoordinator {

    /// A name worth passing to a rejoin: present, and not one of the
    /// placeholders macOS or the CLI substitutes when it will not say.
    static func readableSSID(_ name: String?) -> String? {
        guard let name, !name.isEmpty,
              !name.contains("<redacted>"),
              !name.contains("hidden by macOS") else { return nil }
        return name
    }

    func reconnectTarget(forRule ruleID: String) -> String? {
        switch ruleID {
        case "WJ-1", "WF-1": return lastAssociatedSSID
        default:             return liveSSID
        }
    }

    func considerAutoReconnect(_ sample: MonitorSample) {
        guard appSettings.autoReconnectWiFi,
              let decision = sample.status.autoReconnect,
              !isRepairing else { return }
        let ruleID = decision.rule ?? "WJ-1"
        var params: [String: String] = [:]
        if let target = reconnectTarget(forRule: ruleID) { params["network"] = target }
        let attempt = decision.attempt ?? 1
        let of = decision.maxAttempts.map { "/\($0)" } ?? ""
        log.info("Auto-reconnecting Wi-Fi: \(decision.reason, privacy: .public) (\(ruleID, privacy: .public), attempt \(attempt)\(of, privacy: .public))")
        repairOutcome = RepairOutcome(ruleID: ruleID, label: "Reconnect Wi-Fi",
                                      phase: .working, detail: nil)
        let summary = "Auto-reconnect Wi-Fi (\(decision.reason), attempt \(attempt)\(of))"
        repairTask = Task { [weak self] in
            await self?.performAutoReconnect(ruleID: ruleID, params: params, summary: summary)
        }
    }

    private func performAutoReconnect(ruleID: String, params: [String: String],
                                      summary: String) async {
        do {
            let result = try await repairRunner("reconnect-wifi", params)
            eventLog.record(kind: "repair", summary: "\(summary): \(result.message)", ruleID: ruleID,
                            network: monitor.latest?.network.id)
            repairOutcome = RepairOutcome(ruleID: ruleID, label: "Reconnect Wi-Fi",
                                          phase: result.ok ? .done : .failed,
                                          detail: result.message)
        } catch {
            log.error("Auto-reconnect Wi-Fi failed: \(error.localizedDescription)")
            eventLog.record(kind: "repair", summary: "\(summary): failed — \(error.localizedDescription)",
                            ruleID: ruleID, network: monitor.latest?.network.id)
            repairOutcome = RepairOutcome(ruleID: ruleID, label: "Reconnect Wi-Fi",
                                          phase: .failed, detail: error.localizedDescription)
        }
    }

    /// Lets a test wait for the repair a sample just started.
    func awaitRepairForTesting() async {
        await repairTask?.value
    }

    var isRepairing: Bool { repairOutcome?.isInFlight == true }

    func repairsAreCurrent(forRule ruleID: String?) -> Bool {
        guard let ruleID, latestRun != nil else { return false }
        if let rules = monitor.latest?.status.rules { return rules.contains(ruleID) }
        return true
    }

    func dismissRepairOutcome() {
        guard !isRepairing else { return }
        repairOutcome = nil
    }

    func reconnectRule(amongFiring rules: [String]) -> String? {
        rulesCatalog.catalog?.firstRule(offering: "reconnect-wifi", among: rules)
    }

    func reconnectWiFi(ruleID: String = "WJ-1") {
        guard !isRepairing else { return }
        var params: [String: String] = [:]
        if let target = reconnectTarget(forRule: ruleID) { params["network"] = target }
        repairOutcome = RepairOutcome(ruleID: ruleID, label: "Reconnect Wi-Fi",
                                      phase: .working, detail: nil)
        repairTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.repairRunner("reconnect-wifi", params)
                self.eventLog.record(kind: "repair", summary: result.message, ruleID: ruleID,
                                     network: self.monitor.latest?.network.id)
                self.repairOutcome = RepairOutcome(ruleID: ruleID, label: "Reconnect Wi-Fi",
                                                   phase: result.ok ? .done : .failed,
                                                   detail: result.message)
            } catch {
                self.repairOutcome = RepairOutcome(ruleID: ruleID, label: "Reconnect Wi-Fi",
                                                   phase: .failed, detail: error.localizedDescription)
            }
        }
    }

    // MARK: - Captive Portal & Custom DNS Support

    var offlineReason: String? {
        liveSample?.link.offline?.reason ?? monitor.latest?.link.offline?.reason
    }

    var customDNSServers: [String] {
        guard let store = SCDynamicStoreCreate(nil, "Hopwatch" as CFString, nil, nil) else { return [] }
        guard let primaryIface = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let serviceID = primaryIface["PrimaryService"] as? String else { return [] }
        if let customDNS = SCDynamicStoreCopyValue(store, "Setup:/Network/Service/\(serviceID)/DNS" as CFString) as? [String: Any],
           let servers = customDNS["ServerAddresses"] as? [String], !servers.isEmpty {
            return servers
        }
        return []
    }

    var hasCustomDNS: Bool {
        !customDNSServers.isEmpty
    }

    func isSystemCaptiveActive() -> Bool {
        if liveSample?.publicInfo.captivePortal == false || monitor.latest?.publicInfo.captivePortal == false {
            return false
        }
        guard let store = SCDynamicStoreCreate(nil, "Hopwatch" as CFString, nil, nil) else { return false }
        let iface = monitor.latest?.link.interface ?? "en0"
        if let dict = SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(iface)/CaptiveNetwork" as CFString) as? [String: Any] {
            if let waiting = dict["WaitingOnUI"] as? Bool, waiting { return true }
            if let waitingNum = dict["WaitingOnUI"] as? Int, waitingNum != 0 { return true }
            if let stage = dict["Stage"] as? String {
                let s = stage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if s == "captive" || s == "redirect" { return true }
            }
        }
        return false
    }

    var currentNetworkRequiresPortal: Bool {
        if liveSample?.publicInfo.captivePortal == false || monitor.latest?.publicInfo.captivePortal == false {
            return false
        }
        let internetHealthy = (liveSample?.internet.rttAvgMs ?? monitor.latest?.internet.rttAvgMs) != nil
            || liveSample?.publicInfo.ip != nil || monitor.latest?.publicInfo.ip != nil
            || liveSample?.tcp.anyOk == true || monitor.latest?.tcp.anyOk == true
        if internetHealthy && (liveSample?.internet.rttAvgMs != nil || monitor.latest?.internet.rttAvgMs != nil || liveSample?.tcp.anyOk == true) {
            return false
        }
        if let id = monitor.latest?.network.historyJoinID, Defaults.portalNetworks.contains(id) {
            return true
        }
        if let key = monitor.latest?.network.id, Defaults.portalNetworks.contains(key) {
            return true
        }
        if let ssid = wifiDisplayName, Defaults.portalNetworks.contains("ssid:\(ssid)") {
            return true
        }
        if let lastSSID = lastAssociatedSSID, Defaults.portalNetworks.contains("ssid:\(lastSSID)") {
            return true
        }
        return false
    }

    func learnCurrentNetworkRequiresPortal() {
        if let id = monitor.latest?.network.historyJoinID, !id.isEmpty {
            Defaults.recordPortalNetwork(id)
        }
        if let key = monitor.latest?.network.id, !key.isEmpty {
            Defaults.recordPortalNetwork(key)
        }
        if let ssid = wifiDisplayName, !ssid.isEmpty {
            Defaults.recordPortalNetwork("ssid:\(ssid)")
        }
        if let lastSSID = lastAssociatedSSID, !lastSSID.isEmpty {
            Defaults.recordPortalNetwork("ssid:\(lastSSID)")
        }
    }

    func unlearnCurrentNetworkPortal() {
        if let id = monitor.latest?.network.historyJoinID, !id.isEmpty {
            Defaults.removePortalNetwork(id)
        }
        if let key = monitor.latest?.network.id, !key.isEmpty {
            Defaults.removePortalNetwork(key)
        }
        if let ssid = wifiDisplayName, !ssid.isEmpty {
            Defaults.removePortalNetwork("ssid:\(ssid)")
        }
        if let lastSSID = lastAssociatedSSID, !lastSSID.isEmpty {
            Defaults.removePortalNetwork("ssid:\(lastSSID)")
        }
    }

    func showSoftwareUpdate() {
        onOpenSoftwareUpdate?()
    }

    func openPortalPage() {
        if liveSample?.publicInfo.captivePortal == true ||
           monitor.latest?.status.rules.contains("CP-1") == true ||
           isSystemCaptiveActive() {
            learnCurrentNetworkRequiresPortal()
        }

        if let urlStr = liveSample?.publicInfo.captivePortalURL,
           let url = URL(string: urlStr) {
            NSWorkspace.shared.open(url)
            eventLog.record(kind: "repair", summary: "Opened captive portal sign-in page", ruleID: "CP-1",
                            network: monitor.latest?.network.id)
            return
        }

        let cnaPath = "/System/Library/CoreServices/Captive Network Assistant.app"
        if FileManager.default.fileExists(atPath: cnaPath) {
            let cnaURL = URL(fileURLWithPath: cnaPath)
            NSWorkspace.shared.openApplication(at: cnaURL, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
            eventLog.record(kind: "repair", summary: "Launched Captive Network Assistant", ruleID: "CP-1",
                            network: monitor.latest?.network.id)
            return
        }

        if hasCustomDNS, let gw = liveSample?.link.gateway ?? monitor.latest?.link.gateway, !gw.isEmpty,
           let gwURL = URL(string: "http://\(gw)") {
            NSWorkspace.shared.open(gwURL)
            eventLog.record(kind: "repair", summary: "Opened gateway HTTP sign-in page", ruleID: "CP-1",
                            network: monitor.latest?.network.id)
            return
        }

        if let detectURL = URL(string: "http://captive.apple.com/hotspot-detect.html") {
            NSWorkspace.shared.open(detectURL)
        }

        eventLog.record(kind: "repair", summary: "Opened captive portal sign-in page", ruleID: "CP-1",
                        network: monitor.latest?.network.id)
    }

    func runRepair(_ repair: RunSnapshot.Diagnosis.Repair, forRule ruleID: String) {
        guard !isRepairing else { return }
        repairOutcome = RepairOutcome(ruleID: ruleID, label: repair.label,
                                      phase: .working, detail: nil)
        repairTask = Task { [weak self] in
            await self?.performRepair(repair, forRule: ruleID)
        }
    }

    private func performRepair(_ repair: RunSnapshot.Diagnosis.Repair,
                               forRule ruleID: String) async {
        func finish(_ phase: RepairOutcome.Phase, _ detail: String? = nil) {
            repairOutcome = RepairOutcome(ruleID: ruleID, label: repair.label,
                                          phase: phase, detail: detail)
        }
        let result: NetdiagRunner.RepairResult
        do {
            result = try await repairRunner(repair.id, repair.params)
        } catch NetdiagError.scriptError(let reason) {
            finish(.failed, reason)
            return
        } catch {
            finish(.failed, error.localizedDescription)
            return
        }
        eventLog.record(kind: "repair", summary: result.message, ruleID: ruleID,
                        network: monitor.latest?.network.id)
        guard result.ok else {
            finish(.failed, result.message)
            return
        }
        guard repair.recheck == "now" else {
            finish(.done, result.message)
            return
        }

        finish(.checking)
        if isScanning { await scanTask?.value }
        let startedAt = Date()
        guard runScan(depth: .quick, reason: "checking whether that helped") else {
            finish(.failed, "Hopwatch couldn't re-check just now.")
            return
        }
        await scanTask?.value
        guard lastRunError == nil, let run = latestRun, run.startedAt >= startedAt else {
            finish(.failed, "Hopwatch couldn't re-check just now.")
            return
        }
        if run.snapshot.diagnosis.contains(where: { $0.rule == ruleID }) {
            finish(.didntHelp, repair.ifUnfixed)
        } else {
            finish(.fixed)
        }
    }
}
