import AppKit
import Foundation
import SwiftUI

/// `--visual-audit[=DIR]` — automated live-simulation & visual verification harness.
///
/// Steps a real `HopwatchCoordinator` chronologically through 15 network states
/// and transitions (healthy, single-resolver burst rate-limiting + laggy router,
/// background alert-triggered check, user full check, severe loss, post-loss
/// degraded recovery, weak Wi-Fi, high jitter, DNS timeout, ICMP filtered,
/// captive portal, no link, paused, stale/not-reporting, resolved) while
/// evaluating UI/state invariants and capturing real offscreen light/dark
/// PNG screenshots of `DropdownView` and `MainWindow` to `DIR`.
@MainActor
enum VisualAuditMode {
    private static var outputDirPath: String? {
        for arg in CommandLine.arguments {
            if arg == "--visual-audit" || arg == "--gallery-scenarios" {
                return FileManager.default.temporaryDirectory
                    .appendingPathComponent("hopwatch-visual-audit").path
            }
            if arg.hasPrefix("--visual-audit=") {
                return String(arg.dropFirst("--visual-audit=".count))
            }
            if arg.hasPrefix("--gallery-scenarios=") {
                return String(arg.dropFirst("--gallery-scenarios=".count))
            }
        }
        return nil
    }

    static var isRequested: Bool {
        outputDirPath != nil
    }

    static func scheduleIfRequested() -> Bool {
        guard let dir = outputDirPath else { return false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            Task { @MainActor in
                let code = await run(outputDir: dir)
                exit(code)
            }
        }
        return true
    }

    struct ScenarioReport: Encodable {
        let id: String
        let title: String
        let stage: String
        let statusPill: String
        let pillTone: String
        let health: String
        let headline: String
        let routerPingMs: Double?
        let routerLossPct: Double?
        let internetPingMs: Double?
        let internetLossPct: Double?
        let jitterMs: Double?
        let backgroundInvestigating: Bool
        let isScanning: Bool
        let dropdownLight: String
        let extraScreenshots: [String]
        let checksPassed: [String]
        let failures: [String]
    }

    struct AuditManifest: Encodable {
        let generatedAt: String
        let totalScenarios: Int
        let totalChecks: Int
        let totalFailures: Int
        let scenarios: [ScenarioReport]
    }

    private static let simNetworkID = "mac:aa:bb:cc:dd:ee:01"
    private static let simNetworkName = "L2 2808"

    @MainActor
    static func run(outputDir: String) async -> Int32 {
        let outURL = URL(fileURLWithPath: outputDir, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)
        } catch {
            fputs("VisualAuditMode: failed to create output directory \(outputDir): \(error)\n", stderr)
            return 2
        }

        let coordinator = HopwatchCoordinator()
        coordinator.rulesCatalog.ensureLoaded()
        await coordinator.rulesCatalog.refresh()
        coordinator.resetGalleryState()

        var simNow = Date().addingTimeInterval(-35) // Fresh timestamps within LinkState 120s window
        coordinator.alerts.now = { simNow }
        var reports: [ScenarioReport] = []
        var totalChecks = 0
        var totalFailures = 0

        func makeSample(
            seq: Int,
            up: Bool = true,
            gwRtt: Double? = 6.0,
            gwLoss: Double? = 0.0,
            gwLastLoss: Double? = nil,
            gwJitter: Double? = 0.9,
            inetRtt: Double? = 22.0,
            inetLoss: Double? = 0.0,
            inetLossAlt: Double? = nil,
            inetLastLoss: Double? = nil,
            inetJitter: Double? = 1.6,
            topJitter: Double? = nil,
            rssi: Int? = -61,
            snr: Int? = 31,
            channel: String? = "44",
            txRate: Int? = 866,
            dnsOk: Bool? = true,
            dnsMs: Double? = 14.0,
            tcpOk: Bool? = true,
            icmpFiltered: Bool = false,
            captivePortal: Bool = false,
            captiveURL: String? = nil,
            severity: String = "ok",
            rules: [String] = [],
            offlineReason: String? = nil
        ) -> MonitorSample {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var s = MonitorSample()
            s.schema = 2
            s.ts = iso.string(from: simNow)
            s.seq = seq
            s.refreshed = ["fast", "medium", "slow"]
            s.jitterMs = topJitter ?? {
                switch (gwJitter, inetJitter) {
                case let (g?, i?): return max(g, i)
                case let (g?, nil): return g
                case let (nil, i?): return i
                case (nil, nil): return nil
                }
            }()
            s.link.up = up
            s.link.interface = up ? "en0" : nil
            s.link.type = "wifi"
            s.link.ip = up ? "192.168.1.42" : nil
            s.link.gateway = up ? "192.168.1.1" : nil
            s.link.gatewayMAC = up ? "aa:bb:cc:dd:ee:01" : nil
            s.link.ssid = up ? simNetworkName : nil
            s.network.id = up ? simNetworkID : nil
            s.network.label = up ? simNetworkName : nil
            s.network.groupId = up ? simNetworkID : nil
            if !up {
                var off = MonitorSample.OfflineContext()
                off.reason = offlineReason ?? "wifi-off"
                off.reasonLabel = offlineReason == "no-route" ? "Connected to Wi-Fi, no route" : "Wi-Fi is disconnected"
                off.downDurationS = 42
                off.lastNetwork = simNetworkName
                s.link.offline = off
            }
            s.gateway.rttAvgMs = up ? gwRtt : nil
            s.gateway.lossPct = up ? gwLoss : nil
            s.gateway.lastProbeLossPct = up ? (gwLastLoss ?? gwLoss) : nil
            s.gateway.rttJitterMs = up ? gwJitter : nil
            s.internet.rttAvgMs = up ? inetRtt : nil
            s.internet.lossPct = up ? inetLoss : nil
            s.internet.lossPctAlt = up ? inetLossAlt : nil
            s.internet.lastProbeLossPct = up ? (inetLastLoss ?? inetLoss) : nil
            s.internet.rttJitterMs = up ? inetJitter : nil
            if up, let rssi {
                s.wifi = MonitorSample.WiFi(rssi: rssi, noise: -92, snr: snr ?? 30, channel: channel ?? "44", txRate: txRate)
            }
            s.dns.ok = up ? dnsOk : nil
            s.dns.resolver = up ? "1.1.1.1" : nil
            s.dns.elapsedMs = up ? dnsMs : nil
            s.tcp.anyOk = up ? tcpOk : nil
            if up && tcpOk == true {
                s.tcp.targets = [
                    .init(host: "1.1.1.1", port: 443, ok: true, elapsedMs: inetRtt ?? 24.0),
                    .init(host: "8.8.8.8", port: 443, ok: true, elapsedMs: (inetRtt ?? 24.0) + 4.0)
                ]
            }
            if up && !captivePortal {
                s.publicInfo.ok = true
                s.publicInfo.ip = "118.69.120.44"
                s.publicInfo.isp = "Viettel Corporation"
                s.publicInfo.country = "Vietnam"
                s.publicInfo.countryISO = "VN"
            } else if up && captivePortal {
                s.publicInfo.ok = false
                s.publicInfo.captivePortal = true
                s.publicInfo.captivePortalURL = captiveURL ?? "http://captive.apple.com/hotspot-detect.html"
            }
            s.status.severity = severity
            s.status.measurement = up ? "measured" : "link-down"
            s.status.rules = rules
            s.status.icmpFiltered = icmpFiltered
            s.status.degraded = severity != "ok"
            s.status.cadenceS = severity == "ok" ? 12 : 3
            return s
        }

        func feed(_ sample: MonitorSample, beats: [(Double?, Bool)], warmPrev: MonitorSample? = nil) {
            let existing = coordinator.monitor.recent.filter { $0.link.up && $0.network.id == sample.network.id }
            var history = Array((existing + [sample]).suffix(60))
            if history.count < 2, sample.link.up {
                let prev = warmPrev ?? makeSample(
                    seq: max(0, (sample.seq ?? 1) - 1),
                    gwRtt: sample.gateway.rttAvgMs,
                    gwLoss: sample.gateway.lossPct,
                    gwJitter: sample.gateway.rttJitterMs,
                    inetRtt: sample.internet.rttAvgMs,
                    inetLoss: sample.internet.lossPct,
                    inetJitter: sample.internet.rttJitterMs,
                    topJitter: sample.jitterMs,
                    severity: sample.status.severity,
                    rules: sample.status.rules
                )
                history = [prev, sample]
            }
            coordinator.monitor.adoptGallerySample(sample, historical: history)
            coordinator.handleSampleForTesting(sample)
            coordinator.adoptGalleryArrivalSettled()
            coordinator.setLiveSSIDForTesting(sample.link.up ? simNetworkName : nil)
            coordinator.heartbeat.reset()
            coordinator.heartbeat.setFiltered(sample.status.icmpFiltered)
            for (idx, b) in beats.enumerated() {
                coordinator.heartbeat.adoptTestBeat(latencyMs: b.0, isMiss: b.1, seq: idx + 1)
            }
        }

        func smoothBeats(base: Double, jitter: Double = 2.0, missesAt: Set<Int> = []) -> [(Double?, Bool)] {
            (0..<20).map { idx in
                if missesAt.contains(idx) { return (nil, true) }
                let delta = Double((idx % 5) - 2) * jitter * 0.4
                return (max(4.0, base + delta), false)
            }
        }

        func capture(
            id: String,
            title: String,
            alsoDark: Bool = false,
            alsoHome: Bool = false,
            alsoFullHome: Bool = false,
            alsoDarkDashboard: Bool = false,
            extraTabs: [SidebarSection] = [],
            customRenders: (() -> [String])? = nil,
            checks: () -> [(String, Bool)]
        ) {
            let stage = coordinator.currentStage(monitoringEnabled: coordinator.appSettings.monitoringEnabled)
            let pill = StageResolver.statusPill(for: stage)
            let health = coordinator.currentHealth
            let results = checks()
            var passed: [String] = []
            var failures: [String] = []
            for (label, ok) in results {
                totalChecks += 1
                if ok {
                    passed.append(label)
                } else {
                    totalFailures += 1
                    failures.append(label)
                }
            }

            let lightFilename = "dropdown-\(id).png"
            _ = renderDropdownPNG(
                coordinator: coordinator,
                colorScheme: .light,
                appearance: NSAppearance(named: .aqua),
                to: outURL.appendingPathComponent(lightFilename)
            )
            var extras: [String] = []
            if alsoDark {
                let darkName = "dropdown-\(id)-dark.png"
                if renderDropdownPNG(
                    coordinator: coordinator,
                    colorScheme: .dark,
                    appearance: NSAppearance(named: .darkAqua),
                    to: outURL.appendingPathComponent(darkName)
                ) {
                    extras.append(darkName)
                }
            }
            var tabsToRender = extraTabs
            if alsoHome && !tabsToRender.contains(.home) {
                tabsToRender.insert(.home, at: 0)
            }
            for tab in tabsToRender {
                let prefix = tab == .home ? "home" : "tab-\(tab.rawValue)"
                let filename = "\(prefix)-\(id).png"
                if renderMainWindowPNG(
                    coordinator: coordinator,
                    section: tab,
                    to: outURL.appendingPathComponent(filename)
                ) {
                    extras.append(filename)
                }
                if alsoFullHome && tab == .home {
                    let fullName = "home-\(id)-full.png"
                    if renderMainWindowPNG(
                        coordinator: coordinator,
                        section: .home,
                        colorScheme: .light,
                        appearance: NSAppearance(named: .aqua),
                        height: 1580,
                        to: outURL.appendingPathComponent(fullName)
                    ) {
                        extras.append(fullName)
                    }
                }
                if alsoDarkDashboard {
                    let darkTabName = "\(prefix)-\(id)-dark.png"
                    if renderMainWindowPNG(
                        coordinator: coordinator,
                        section: tab,
                        colorScheme: .dark,
                        appearance: NSAppearance(named: .darkAqua),
                        height: (alsoFullHome && tab == .home) ? 1580 : 780,
                        to: outURL.appendingPathComponent(darkTabName)
                    ) {
                        extras.append(darkTabName)
                    }
                }
            }
            if let customRenders {
                extras.append(contentsOf: customRenders())
            }

            let sample = coordinator.liveSample
            let report = ScenarioReport(
                id: id,
                title: title,
                stage: stageLabel(stage),
                statusPill: pill.text,
                pillTone: toneLabel(pill.tone),
                health: "\(health)",
                headline: coordinator.headline,
                routerPingMs: sample?.gateway.rttAvgMs,
                routerLossPct: sample?.gateway.lossPct,
                internetPingMs: sample?.internet.rttAvgMs,
                internetLossPct: sample?.internet.lossPct,
                jitterMs: sample?.liveJitterMs,
                backgroundInvestigating: coordinator.isBackgroundInvestigating,
                isScanning: coordinator.isScanning,
                dropdownLight: lightFilename,
                extraScreenshots: extras,
                checksPassed: passed,
                failures: failures
            )
            reports.append(report)
            let mark = failures.isEmpty ? "PASS" : "FAIL"
            print("[\(mark)] \(id): pill=\(pill.text) (\(toneLabel(pill.tone))) health=\(health) stage=\(stageLabel(stage)) (\(passed.count)/\(results.count) checks)")
            for f in failures {
                print("   ✘ FAILED: \(f)")
            }
        }

        // Keep speedtest summary consistent across scenarios (like user's "Last speed test 4d ago")
        func attachSpeedBaseline() {
            let speed = RunSnapshot.Speedtest(
                downMbps: 420.0, upMbps: 67.0,
                latencyMs: 14.0, jitterMs: 1.5, server: "Viettel HCMC"
            )
            coordinator.adoptSessionStateForTesting(
                speed: speed,
                speedAt: simNow.addingTimeInterval(-4 * 86400),
                speedNetwork: simNetworkID
            )
        }

        // Populate authentic multi-network HistoryDocument + EventStore timeline so
        // Overview, Live monitoring, Activity, Trends, and Networks all render rich data.
        var timelineHistory: [MonitorSample] = []
        func buildSampleAt(_ ts: Date, seq: Int, gwRtt: Double?, gwLoss: Double?, gwJitter: Double?, inetRtt: Double?, inetLoss: Double?, inetJitter: Double?, severity: String = "ok", rules: [String] = []) -> MonitorSample {
            let saved = simNow
            simNow = ts
            let s = makeSample(
                seq: seq,
                gwRtt: gwRtt, gwLoss: gwLoss, gwJitter: gwJitter,
                inetRtt: inetRtt, inetLoss: inetLoss, inetJitter: inetJitter,
                severity: severity, rules: rules
            )
            simNow = saved
            return s
        }

        func seedMultiNetworkHistoryAndTimeline(endingAt base: Date = Date()) {
            // Build cadence-accurate live samples (12s nominal, 3s warn/critical, 1 deliberate 65s gap) for LiveView & HomeView charts
            timelineHistory.removeAll()
            var offset: Double = -12.0
            var timestamps = [Date](repeating: base, count: 40)
            for idx in stride(from: 39, through: 0, by: -1) {
                timestamps[idx] = base.addingTimeInterval(offset)
                if idx == 22 {
                    offset -= 65.0
                } else if (12...20).contains(idx) {
                    offset -= 3.0
                } else {
                    offset -= 12.0
                }
            }
            for idx in 0..<40 {
                let t = timestamps[idx]
                let wave: (Double, Double, Double, Double, Double, Double, String, [String]) = switch idx {
                case 12...16: (82, 0, 58, 56, 5, 22, "warn", ["L2"])
                case 17...20: (108, 26, 66, 138, 32, 74, "critical", ["L1", "G2"])
                case 21...23: (16, 0, 6, 36, 10, 8, "ok", [])
                default: (5 + Double(idx % 4), 0, 1.1, 18 + Double(idx % 6) * 2.0, 0, 1.8, "ok", [])
                }
                timelineHistory.append(buildSampleAt(
                    t, seq: 100 + idx,
                    gwRtt: wave.0, gwLoss: wave.1, gwJitter: wave.2,
                    inetRtt: wave.3, inetLoss: wave.4, inetJitter: wave.5,
                    severity: wave.6, rules: wave.7
                ))
            }

            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime]
            func isoDaysAgo(_ days: Double) -> String {
                iso.string(from: base.addingTimeInterval(-days * 86400))
            }

            // Build HistoryDocument JSON matching helpers/history.py schema v2
            let runsJSON: [[String: Any]] = [
                ["id": "\(isoDaysAgo(13)).aa110001", "ts": isoDaysAgo(13), "network_id": simNetworkID, "run_mode": "full", "severity": "ok", "diagnosis_count": 0, "rules": [], "metrics": ["gateway_rtt_ms": 5.2, "inet_rtt_ms": 18.4, "gateway_loss_pct": 0.0, "inet_loss_pct": 0.0, "gateway_jitter_ms": 1.1, "wifi_rssi_dbm": -58.0, "wifi_snr_db": 34.0, "bufferbloat_gw_ms": 4.0, "speed_down_mbps": 438.0, "speed_up_mbps": 71.0]],
                ["id": "\(isoDaysAgo(10)).aa110002", "ts": isoDaysAgo(10), "network_id": simNetworkID, "run_mode": "full", "severity": "ok", "diagnosis_count": 0, "rules": [], "metrics": ["gateway_rtt_ms": 6.1, "inet_rtt_ms": 20.1, "gateway_loss_pct": 0.0, "inet_loss_pct": 0.0, "gateway_jitter_ms": 1.5, "wifi_rssi_dbm": -60.0, "wifi_snr_db": 32.0, "bufferbloat_gw_ms": 6.0, "speed_down_mbps": 412.0, "speed_up_mbps": 66.0]],
                ["id": "\(isoDaysAgo(8)).aa110003", "ts": isoDaysAgo(8), "network_id": "mac:bb:cc:dd:ee:02", "run_mode": "full", "severity": "ok", "diagnosis_count": 0, "rules": [], "metrics": ["gateway_rtt_ms": 3.4, "inet_rtt_ms": 12.2, "gateway_loss_pct": 0.0, "inet_loss_pct": 0.0, "gateway_jitter_ms": 0.8, "speed_down_mbps": 780.0, "speed_up_mbps": 520.0]],
                ["id": "\(isoDaysAgo(6)).aa110004", "ts": isoDaysAgo(6), "network_id": simNetworkID, "run_mode": "no-speed", "severity": "warn", "diagnosis_count": 1, "rules": ["L2"], "root_cause": "L2", "metrics": ["gateway_rtt_ms": 22.0, "inet_rtt_ms": 54.0, "gateway_loss_pct": 0.0, "inet_loss_pct": 8.0, "gateway_jitter_ms": 19.0, "wifi_rssi_dbm": -63.0]],
                ["id": "\(isoDaysAgo(4)).aa110005", "ts": isoDaysAgo(4), "network_id": simNetworkID, "run_mode": "full", "severity": "ok", "diagnosis_count": 0, "rules": [], "metrics": ["gateway_rtt_ms": 5.4, "inet_rtt_ms": 19.2, "gateway_loss_pct": 0.0, "inet_loss_pct": 0.0, "gateway_jitter_ms": 1.2, "wifi_rssi_dbm": -61.0, "wifi_snr_db": 31.0, "bufferbloat_gw_ms": 5.0, "speed_down_mbps": 420.0, "speed_up_mbps": 67.0]],
                ["id": "\(isoDaysAgo(3)).aa110006", "ts": isoDaysAgo(3), "network_id": "mac:cc:dd:ee:ff:03", "run_mode": "quick", "severity": "warn", "diagnosis_count": 1, "rules": ["W1"], "root_cause": "W1", "metrics": ["gateway_rtt_ms": 48.0, "inet_rtt_ms": 84.0, "gateway_loss_pct": 6.0, "inet_loss_pct": 7.0, "gateway_jitter_ms": 26.0, "wifi_rssi_dbm": -82.0]],
                ["id": "\(isoDaysAgo(1)).aa110007", "ts": isoDaysAgo(1), "network_id": simNetworkID, "run_mode": "full", "severity": "warn", "diagnosis_count": 1, "rules": ["L2"], "root_cause": "L2", "metrics": ["gateway_rtt_ms": 91.0, "inet_rtt_ms": 60.0, "gateway_loss_pct": 0.0, "inet_loss_pct": 5.0, "gateway_jitter_ms": 61.0, "wifi_rssi_dbm": -61.0, "bufferbloat_gw_ms": 28.0]],
                ["id": "\(isoDaysAgo(0.05)).aa110008", "ts": isoDaysAgo(0.05), "network_id": simNetworkID, "run_mode": "full", "severity": "ok", "diagnosis_count": 0, "rules": [], "metrics": ["gateway_rtt_ms": 5.0, "inet_rtt_ms": 18.0, "gateway_loss_pct": 0.0, "inet_loss_pct": 0.0, "gateway_jitter_ms": 1.0, "wifi_rssi_dbm": -60.0, "speed_down_mbps": 425.0, "speed_up_mbps": 68.0]],
            ]
            let historyJSON: [String: Any] = [
                "schema": 2,
                "counts": ["records_read": 8, "duplicates_dropped": 0, "redacted_dropped": 0, "unparseable_dropped": 0, "runs": 8, "checks": 8, "networks": 3],
                "metrics": [
                    ["key": "gateway_rtt_ms", "label": "Router Ping", "unit": "ms", "direction": "lower_is_better", "samples": 8],
                    ["key": "inet_rtt_ms", "label": "Internet Ping", "unit": "ms", "direction": "lower_is_better", "samples": 8],
                    ["key": "inet_loss_pct", "label": "Internet Loss", "unit": "%", "direction": "lower_is_better", "samples": 8],
                    ["key": "gateway_jitter_ms", "label": "Router Jitter", "unit": "ms", "direction": "lower_is_better", "samples": 8],
                    ["key": "speed_down_mbps", "label": "Download Speed", "unit": "Mbps", "direction": "higher_is_better", "samples": 5],
                    ["key": "speed_up_mbps", "label": "Upload Speed", "unit": "Mbps", "direction": "higher_is_better", "samples": 5],
                ],
                "networks": [
                    [
                        "id": simNetworkID,
                        "label": simNetworkName,
                        "synthesized": false,
                        "bridged_from": [],
                        "first_seen": isoDaysAgo(13),
                        "last_seen": isoDaysAgo(0.05),
                        "run_count": 6,
                        "check_count": 6,
                        "gateways": ["192.168.1.1"],
                        "isps": ["Viettel Corporation"],
                        "ssids": [simNetworkName],
                        "metric_samples": ["gateway_rtt_ms": 6, "inet_rtt_ms": 6, "speed_down_mbps": 4],
                        "metric_stats": [
                            "gateway_rtt_ms": ["median": 5.8, "p10": 5.0, "p90": 91.0],
                            "inet_rtt_ms": ["median": 19.6, "p10": 18.0, "p90": 60.0],
                            "gateway_jitter_ms": ["median": 1.4, "p10": 1.0, "p90": 61.0],
                            "speed_down_mbps": ["median": 422.5, "p10": 412.0, "p90": 438.0],
                            "speed_up_mbps": ["median": 67.5, "p10": 66.0, "p90": 71.0],
                        ],
                        "severity_counts": ["ok": 4, "warn": 2, "critical": 0],
                        "judged": ["overall": "ok", "summary": "Generally responsive with occasional evening packet loss."],
                    ],
                    [
                        "id": "mac:bb:cc:dd:ee:02",
                        "label": "Office 5GHz",
                        "synthesized": false,
                        "bridged_from": [],
                        "first_seen": isoDaysAgo(12),
                        "last_seen": isoDaysAgo(8),
                        "run_count": 1,
                        "check_count": 1,
                        "gateways": ["10.0.10.1"],
                        "isps": ["FPT Telecom"],
                        "ssids": ["Office 5GHz"],
                        "metric_samples": ["gateway_rtt_ms": 1, "speed_down_mbps": 1],
                        "metric_stats": ["gateway_rtt_ms": ["median": 3.4, "p10": 3.4, "p90": 3.4]],
                        "severity_counts": ["ok": 1, "warn": 0, "critical": 0],
                        "judged": ["overall": "ok", "summary": "Low latency fiber uplink."],
                    ],
                    [
                        "id": "mac:cc:dd:ee:ff:03",
                        "label": "Airport Free Wi-Fi",
                        "synthesized": false,
                        "bridged_from": [],
                        "first_seen": isoDaysAgo(3),
                        "last_seen": isoDaysAgo(3),
                        "run_count": 1,
                        "check_count": 1,
                        "gateways": ["172.16.0.1"],
                        "isps": ["Public Hotspot"],
                        "ssids": ["Airport Free Wi-Fi"],
                        "metric_samples": ["gateway_rtt_ms": 1],
                        "metric_stats": ["gateway_rtt_ms": ["median": 48.0, "p10": 48.0, "p90": 48.0]],
                        "severity_counts": ["ok": 0, "warn": 1, "critical": 0],
                        "judged": ["overall": "warn", "summary": "Weak signal and elevated jitter."],
                    ],
                ],
                "runs": runsJSON,
            ]
            if let jsonData = try? JSONSerialization.data(withJSONObject: historyJSON),
               let doc = try? JSONDecoder().decode(HistoryDocument.self, from: jsonData) {
                coordinator.history.adoptDocumentForTesting(doc)
                coordinator.history.setNote("Home fiber router in study (Viettel 500/70 Mbps).", for: simNetworkID)
            }

            coordinator.clearEventLog()
            coordinator.eventLog.record(kind: "monitor-started", summary: "Started watching L2 2808", network: simNetworkID, date: base.addingTimeInterval(-38 * 60))
            coordinator.eventLog.record(kind: "rule-fired", summary: "Moderate internet packet loss", ruleID: "L2", network: simNetworkID, date: base.addingTimeInterval(-26 * 60), extraDetail: "5% internet loss · router ±61ms jitter")
            coordinator.eventLog.record(kind: "rule-fired", summary: "Severe internet packet loss", ruleID: "L1", network: simNetworkID, date: base.addingTimeInterval(-21 * 60), extraDetail: "32% loss across both 1.1.1.1 and 8.8.8.8")
            coordinator.eventLog.record(kind: "rule-cleared", summary: "Packet loss cleared", ruleID: "L1", network: simNetworkID, date: base.addingTimeInterval(-17 * 60), extraDetail: "Returned below critical threshold after 4m")
            coordinator.eventLog.record(kind: "rule-cleared", summary: "Moderate internet packet loss cleared", ruleID: "L2", network: simNetworkID, date: base.addingTimeInterval(-16 * 60), extraDetail: "Loss settled back to 0%")
            coordinator.eventLog.record(kind: "repair", summary: "Ran background check — isolated issue to ISP leg", ruleID: "L2", network: simNetworkID, date: base.addingTimeInterval(-15 * 60))
        }
        seedMultiNetworkHistoryAndTimeline(endingAt: simNow.addingTimeInterval(-15))
        attachSpeedBaseline()

        // 01. Healthy baseline + Overview + Trends + Networks + Settings tabs
        simNow = simNow.addingTimeInterval(3)
        let s01 = makeSample(seq: 1, gwRtt: 5.0, gwLoss: 0.0, gwJitter: 0.8, inetRtt: 18.0, inetLoss: 0.0, inetJitter: 1.5)
        coordinator.monitor.adoptGallerySample(s01, historical: timelineHistory + [s01])
        coordinator.handleSampleForTesting(s01)
        coordinator.adoptGalleryArrivalSettled()
        coordinator.setLiveSSIDForTesting(simNetworkName)
        coordinator.heartbeat.reset()
        coordinator.heartbeat.setFiltered(false)
        for (idx, b) in smoothBeats(base: 18.0, jitter: 2.0).enumerated() {
            coordinator.heartbeat.adoptTestBeat(latencyMs: b.0, isMiss: b.1, seq: idx + 1)
        }
        capture(id: "01-healthy", title: "Healthy baseline + Dashboard tabs (Light & Dark + Full Overview)", alsoDark: true, alsoHome: true, alsoFullHome: true, alsoDarkDashboard: true, extraTabs: [.trends, .networks, .settings]) {
            let s = coordinator.currentStage(monitoringEnabled: true)
            let p = StageResolver.statusPill(for: s)
            return [
                ("stage is healthy", s == .healthy),
                ("pill is Watching (green)", p.text == "Watching" && p.tone == .green),
                ("health is .healthy", coordinator.currentHealth == .healthy),
                ("no degraded experience", coordinator.currentDegradedExperience == nil),
            ]
        }

        // 02. Screenshot 1 reproduction: 1.1.1.1 burst rate-limit filtered out (5% real loss) + Router 91ms / ±61ms jitter + L2
        simNow = simNow.addingTimeInterval(3)
        let s02 = makeSample(
            seq: 2,
            gwRtt: 91.0, gwLoss: 0.0, gwJitter: 61.0,
            inetRtt: 60.0, inetLoss: 5.0, inetJitter: 24.0,
            topJitter: 61.0,
            severity: "warn",
            rules: ["L2"]
        )
        feed(s02, beats: smoothBeats(base: 42.9, jitter: 12.0, missesAt: [19]))
        simNow = simNow.addingTimeInterval(25) // allow L2 alert dwell if applicable
        feed(s02, beats: smoothBeats(base: 42.9, jitter: 12.0, missesAt: [19]))
        capture(id: "02-burst-rate-limit-router-laggy", title: "Screenshot 1 fix: L2 + Router ±61ms jitter + filtered 5% loss", alsoHome: true) {
            let s = coordinator.currentStage(monitoringEnabled: true)
            let p = StageResolver.statusPill(for: s)
            let degHeadline = coordinator.currentDegradedExperience?.headline ?? ""
            let _ = degHeadline
            return [
                ("internet loss filtered (not 94% spike)", (coordinator.liveSample?.internet.lossPct ?? -1) == 5.0),
                ("top jitter captures max(gw=61, inet=24) == 61", (coordinator.currentJitter ?? 0) == 61.0),
                ("pill is Degraded (amber)", p.text == "Degraded" && p.tone == .amber),
                ("menu bar dot is warning", coordinator.currentHealth == .warning),
                ("headline reflects router-not-dropping or L2", !coordinator.headline.contains("even though")),
            ]
        }

        // 03. Screenshot 2 reproduction: Background alert-triggered scan must NOT wipe telemetry or show Checking/Running full check
        coordinator.monitor.pause(reason: HopwatchCoordinator.scanPauseReason)
        coordinator.adoptGalleryScanState(isScanning: true, depth: .alertTriggered, currentStep: "ipv6", alertTriggered: true)
        capture(id: "03-background-investigating", title: "Screenshot 2 fix: Background investigation keeps live data", alsoDark: true, alsoHome: true, extraTabs: [.live]) {
            let s = coordinator.currentStage(monitoringEnabled: true)
            let p = StageResolver.statusPill(for: s)
            return [
                ("isBackgroundInvestigating is true", coordinator.isBackgroundInvestigating),
                ("stage stays warning/alerted (not .testing)", s != .testing),
                ("pill stays Degraded (not Checking)", p.text == "Degraded" && p.tone == .amber),
                ("headline does not falsely claim monitoring is paused", !coordinator.headline.lowercased().contains("paused")),
                ("preScanSample preserves internet 60ms & 5% loss", coordinator.liveSample?.internet.rttAvgMs == 60.0 && coordinator.liveSample?.internet.lossPct == 5.0),
                ("heartbeat retains recent beats", !coordinator.heartbeat.recentBeats.isEmpty),
            ]
        }

        // 04. Explicit user full check: shows Running full check hero while still keeping live metrics/heartbeat visible
        coordinator.adoptGalleryScanState(isScanning: true, depth: .full, currentStep: "speedtest", alertTriggered: false)
        capture(id: "04-user-full-check", title: "User full check preserves prior live metrics under Checking hero") {
            let s = coordinator.currentStage(monitoringEnabled: true)
            let p = StageResolver.statusPill(for: s)
            return [
                ("stage is .testing", s == .testing),
                ("pill is Checking (blue)", p.text == "Checking" && p.tone == .blue),
                ("liveSample remains preserved underneath", coordinator.liveSample?.internet.rttAvgMs == 60.0),
                ("heartbeat retains beats during scan", !coordinator.heartbeat.recentBeats.isEmpty),
            ]
        }

        // Finish scan & set lastAlertTriggeredScanAt for cooldown verification
        coordinator.monitor.resume(reason: HopwatchCoordinator.scanPauseReason)
        coordinator.adoptGalleryScanState(isScanning: false, depth: nil)
        coordinator.adoptGalleryLastAlertScanAt(Date())

        // 05. Severe packet loss L1
        simNow = simNow.addingTimeInterval(3)
        let s05 = makeSample(
            seq: 5,
            gwRtt: 110.0, gwLoss: 28.0, gwJitter: 68.0,
            inetRtt: 145.0, inetLoss: 30.0, inetJitter: 82.0,
            severity: "critical",
            rules: ["L1", "G2"]
        )
        feed(s05, beats: smoothBeats(base: 145.0, jitter: 45.0, missesAt: [3, 8, 12, 17, 19]))
        simNow = simNow.addingTimeInterval(20)
        feed(s05, beats: smoothBeats(base: 145.0, jitter: 45.0, missesAt: [3, 8, 12, 17, 19]))
        capture(id: "05-severe-loss-L1", title: "Severe loss L1 + G2 (Problem / Critical) + Live & Activity tabs", alsoDark: true, alsoHome: true, alsoDarkDashboard: true, extraTabs: [.live, .activity]) {
            let s = coordinator.currentStage(monitoringEnabled: true)
            let p = StageResolver.statusPill(for: s)
            return [
                ("pill is Problem (red)", p.text == "Problem" && p.tone == .red),
                ("health is .critical", coordinator.currentHealth == .critical),
                ("cooldown blocks looping repeat scan", !coordinator.canStartAlertTriggeredScanForTesting),
            ]
        }

        // 06. Screenshot 3 reproduction: severity=="ok" while 10% packet loss still makes Calls & Gaming unstable
        simNow = simNow.addingTimeInterval(6)
        coordinator.alerts.invalidateConnection()
        coordinator.resetGalleryState()
        attachSpeedBaseline()
        coordinator.adoptGalleryLastAlertScanAt(Date())
        let s06 = makeSample(
            seq: 6,
            gwRtt: 14.0, gwLoss: 10.0, gwJitter: 5.0,
            inetRtt: 33.0, inetLoss: 10.0, inetJitter: 5.0,
            severity: "ok",
            rules: []
        )
        feed(s06, beats: smoothBeats(base: 39.1, jitter: 6.0, missesAt: [4, 17]))
        capture(id: "06-post-loss-degraded", title: "Screenshot 3 fix: Degraded hero NEVER paired with green Watching pill") {
            let s = coordinator.currentStage(monitoringEnabled: true)
            let p = StageResolver.statusPill(for: s)
            let isDeg: Bool = { if case .degraded = s { return true }; return false }()
            return [
                ("stage resolves to .degraded even when CLI severity==ok", isDeg),
                ("pill is Degraded (amber) matching degraded experience, never green Watching", p.text == "Degraded" && p.tone == .amber),
                ("menu-bar dot is .warning matching amber Degraded pill", coordinator.currentHealth == .warning),
                ("alert scan cooldown still active", coordinator.isAlertTriggeredScanInCooldown()),
            ]
        }

        // 07. Weak Wi-Fi W1
        simNow = simNow.addingTimeInterval(6)
        coordinator.resetGalleryState()
        attachSpeedBaseline()
        feed(
            makeSample(seq: 7, gwRtt: 48.0, gwLoss: 8.0, gwJitter: 24.0, inetRtt: 76.0, inetLoss: 8.0, inetJitter: 26.0, rssi: -84, snr: 12, channel: "6", severity: "warn", rules: ["W1"]),
            beats: smoothBeats(base: 76.0, jitter: 18.0, missesAt: [14])
        )
        capture(id: "07-weak-wifi-W1", title: "Weak Wi-Fi signal W1", alsoHome: true) {
            let s = coordinator.currentStage(monitoringEnabled: true)
            let p = StageResolver.statusPill(for: s)
            return [
                ("pill is Degraded (amber)", p.text == "Degraded" && p.tone == .amber),
                ("health is warning", coordinator.currentHealth == .warning),
            ]
        }

        // 08. High gateway jitter (52 ms) hurting real-time Calls/Gaming with 0% loss
        simNow = simNow.addingTimeInterval(6)
        coordinator.resetGalleryState()
        attachSpeedBaseline()
        feed(
            makeSample(seq: 8, gwRtt: 28.0, gwLoss: 0.0, gwJitter: 52.0, inetRtt: 38.0, inetLoss: 0.0, inetJitter: 18.0, topJitter: 52.0, severity: "ok", rules: []),
            beats: smoothBeats(base: 38.0, jitter: 28.0)
        )
        capture(id: "08-high-jitter-calls", title: "High gateway jitter (52 ms) warns Calls/Gaming & jitter tile") {
            let s = coordinator.currentStage(monitoringEnabled: true)
            let p = StageResolver.statusPill(for: s)
            return [
                ("currentJitter reflects gateway 52ms", (coordinator.currentJitter ?? 0) == 52.0),
                ("pill is Problem/Degraded (not Watching)", p.text != "Watching" && p.tone != .green),
                ("menu-bar health reflects degraded jitter", coordinator.currentHealth == .critical || coordinator.currentHealth == .warning),
            ]
        }

        // 09. Slow / Failing DNS D1
        simNow = simNow.addingTimeInterval(6)
        coordinator.resetGalleryState()
        attachSpeedBaseline()
        feed(
            makeSample(seq: 9, gwRtt: 6.0, gwLoss: 0.0, gwJitter: 1.0, inetRtt: 20.0, inetLoss: 0.0, inetJitter: 1.8, dnsOk: false, dnsMs: 2400.0, severity: "warn", rules: ["D1"]),
            beats: smoothBeats(base: 20.0, jitter: 2.0)
        )
        capture(id: "09-dns-flaky-D1", title: "DNS resolution failing D1") {
            let s = coordinator.currentStage(monitoringEnabled: true)
            let p = StageResolver.statusPill(for: s)
            return [
                ("pill is Degraded (amber)", p.text == "Degraded" && p.tone == .amber),
            ]
        }

        // 10. ICMP filtered (100% ICMP drop, TCP works cleanly)
        simNow = simNow.addingTimeInterval(6)
        coordinator.resetGalleryState()
        attachSpeedBaseline()
        feed(
            makeSample(seq: 10, gwRtt: nil, gwLoss: 100.0, gwJitter: nil, inetRtt: nil, inetLoss: 100.0, inetJitter: nil, topJitter: nil, tcpOk: true, icmpFiltered: true, severity: "ok", rules: ["ICMP-1", "TCP-1"]),
            beats: smoothBeats(base: 22.0, jitter: 2.0)
        )
        capture(id: "10-icmp-filtered", title: "ICMP blocked network with healthy TCP") {
            let s = coordinator.currentStage(monitoringEnabled: true)
            let p = StageResolver.statusPill(for: s)
            return [
                ("heartbeat marks target filtered", coordinator.heartbeat.isFiltered),
                ("no false Watching outage — pill green Watching", p.text == "Watching" && p.tone == .green),
            ]
        }

        // 11. Captive portal
        simNow = simNow.addingTimeInterval(6)
        coordinator.resetGalleryState()
        attachSpeedBaseline()
        let s11 = makeSample(seq: 11, gwRtt: 7.0, gwLoss: 0.0, gwJitter: 1.2, inetRtt: nil, inetLoss: 100.0, inetJitter: nil, topJitter: 1.2, dnsOk: true, tcpOk: false, captivePortal: true, severity: "warn", rules: ["CP-1"])
        feed(s11, beats: smoothBeats(base: 8.0, jitter: 1.0, missesAt: [0,1,2,3,4,5]))
        simNow = simNow.addingTimeInterval(15)
        feed(s11, beats: [])
        capture(id: "11-captive-portal", title: "Captive portal sign-in required CP-1") {
            let s = coordinator.currentStage(monitoringEnabled: true)
            let p = StageResolver.statusPill(for: s)
            return [
                ("pill is Degraded/Problem (not Watching)", p.text != "Watching" && p.tone != .green),
            ]
        }

        // 12. No link / Offline
        simNow = simNow.addingTimeInterval(6)
        coordinator.resetGalleryState()
        feed(
            makeSample(seq: 12, up: false, severity: "critical", rules: ["N1"], offlineReason: "wifi-off"),
            beats: []
        )
        capture(id: "12-no-link", title: "Wi-Fi disconnected / No link", alsoDark: true, alsoHome: true) {
            let s = coordinator.currentStage(monitoringEnabled: true)
            let p = StageResolver.statusPill(for: s)
            return [
                ("stage is .noLink", s == .noLink),
                ("pill is Problem (red)", p.text == "Problem" && p.tone == .red),
                ("health is .critical", coordinator.currentHealth == .critical),
            ]
        }

        // 13. Monitoring paused manually
        simNow = simNow.addingTimeInterval(6)
        coordinator.resetGalleryState()
        attachSpeedBaseline()
        feed(
            makeSample(seq: 13, gwRtt: 5.0, gwLoss: 0.0, gwJitter: 1.0, inetRtt: 19.0, inetLoss: 0.0, inetJitter: 1.5),
            beats: smoothBeats(base: 19.0, jitter: 2.0)
        )
        coordinator.appSettings.monitoringEnabled = false
        coordinator.monitor.pause(reason: "user")
        capture(id: "13-paused", title: "Monitoring paused by user", alsoHome: true) {
            let s = coordinator.currentStage(monitoringEnabled: false)
            let p = StageResolver.statusPill(for: s)
            let pausedItems = SuitabilityEngine.evaluateAll(.init(monitorSample: coordinator.liveSample, isLinkUp: true, isPaused: true))
            return [
                ("stage is .paused", { if case .paused = s { return true }; return false }()),
                ("pill is Paused (muted)", p.text == "Paused" && p.tone == .muted),
                ("liveSample withheld while paused", coordinator.liveSample == nil),
                ("paused suitability avoids Assessing", pausedItems.allSatisfy { $0.consequence == "Resume monitoring to check" }),
            ]
        }

        // 14. Stale / Not reporting
        coordinator.appSettings.monitoringEnabled = true
        coordinator.monitor.resume(reason: "user")
        coordinator.resetGalleryState()
        attachSpeedBaseline()
        feed(
            makeSample(seq: 14, gwRtt: 5.0, gwLoss: 0.0, gwJitter: 1.0, inetRtt: 19.0, inetLoss: 0.0, inetJitter: 1.5),
            beats: smoothBeats(base: 19.0, jitter: 2.0)
        )
        coordinator.adoptGalleryStaleSample()
        capture(id: "14-not-reporting-stale", title: "Monitor stopped reporting (stale sample)") {
            let s = coordinator.currentStage(monitoringEnabled: true)
            let p = StageResolver.statusPill(for: s)
            return [
                ("latestSampleIsStale is true", coordinator.latestSampleIsStale),
                ("stage is .notReporting", s == .notReporting),
                ("pill is Not reporting (amber)", p.text == "Not reporting" && p.tone == .amber),
            ]
        }

        // 15. Recovered / Resolved notice banner
        simNow = simNow.addingTimeInterval(6)
        coordinator.resetGalleryState()
        attachSpeedBaseline()
        feed(
            makeSample(seq: 15, gwRtt: 4.0, gwLoss: 0.0, gwJitter: 0.7, inetRtt: 17.0, inetLoss: 0.0, inetJitter: 1.2),
            beats: smoothBeats(base: 17.0, jitter: 1.5)
        )
        coordinator.adoptGalleryResolution(.init(
            id: UUID(),
            title: "Wi-Fi Stabilized",
            message: "Switched to 5 GHz (Ch 44) — packet loss dropped back to 0%.",
            timestamp: Date(),
            icon: "checkmark.shield.fill"
        ))
        capture(id: "15-recovered-resolved", title: "Recovered & stabilized resolution banner + Live & Activity tabs", alsoHome: true, extraTabs: [.live, .activity]) {
            let s = coordinator.currentStage(monitoringEnabled: true)
            let p = StageResolver.statusPill(for: s)
            return [
                ("stage is .resolved", { if case .resolved = s { return true }; return false }()),
                ("pill is Watching (green)", p.text == "Watching" && p.tone == .green),
                ("health is .healthy", coordinator.currentHealth == .healthy),
            ]
        }

        // 16. Continuous NO-RESET cycling test (Healthy -> L2 -> Background Check -> Critical L1 -> Partial Recovery L2 -> 10% Degraded -> Healthy Recovery)
        coordinator.resetGalleryState()
        let baseCycleNow = Date().addingTimeInterval(-260)
        seedMultiNetworkHistoryAndTimeline(endingAt: baseCycleNow)
        attachSpeedBaseline()
        simNow = baseCycleNow
        let cy1 = makeSample(seq: 201, gwRtt: 5, gwLoss: 0, gwJitter: 1, inetRtt: 18, inetLoss: 0, inetJitter: 1.5, severity: "ok", rules: [])
        coordinator.monitor.adoptGallerySample(cy1, historical: timelineHistory + [cy1])
        coordinator.handleSampleForTesting(cy1)
        coordinator.adoptGalleryArrivalSettled()
        coordinator.setLiveSSIDForTesting(simNetworkName)

        // Transition 1: Burst 5% + Router 91ms/±61ms jitter -> L2 warn + bg scan triggered -> NO wipe!
        simNow = baseCycleNow.addingTimeInterval(10)
        let cy2 = makeSample(seq: 202, gwRtt: 91, gwLoss: 0, gwJitter: 61, inetRtt: 60, inetLoss: 5, inetJitter: 24, topJitter: 61, severity: "warn", rules: ["L2"])
        feed(cy2, beats: smoothBeats(base: 42.9, jitter: 12.0, missesAt: [19]))
        simNow = baseCycleNow.addingTimeInterval(30)
        feed(cy2, beats: smoothBeats(base: 42.9, jitter: 12.0, missesAt: [19]))
        coordinator.monitor.pause(reason: HopwatchCoordinator.scanPauseReason)
        coordinator.adoptGalleryScanState(isScanning: true, depth: .alertTriggered, currentStep: "dns", alertTriggered: true)
        coordinator.adoptGalleryLastAlertScanAt(simNow)
        let cy2Stage = coordinator.currentStage(monitoringEnabled: true)
        let cy2Pill = StageResolver.statusPill(for: cy2Stage)
        let cy2PreScanOk = coordinator.liveSample?.internet.rttAvgMs == 60.0 && !coordinator.heartbeat.recentBeats.isEmpty && cy2Pill.tone == .amber

        // End background scan and escalate WITHOUT resetting state -> L1 Critical!
        coordinator.monitor.resume(reason: HopwatchCoordinator.scanPauseReason)
        coordinator.adoptGalleryScanState(isScanning: false, depth: nil)
        simNow = baseCycleNow.addingTimeInterval(40)
        let cy3 = makeSample(seq: 203, gwRtt: 112, gwLoss: 28, gwJitter: 70, inetRtt: 148, inetLoss: 34, inetJitter: 84, topJitter: 84, severity: "critical", rules: ["L1", "G2"])
        feed(cy3, beats: smoothBeats(base: 148.0, jitter: 42.0, missesAt: [2, 6, 11, 16, 19]))
        simNow = baseCycleNow.addingTimeInterval(60)
        feed(cy3, beats: smoothBeats(base: 148.0, jitter: 42.0, missesAt: [2, 6, 11, 16, 19]))
        let cy3CooldownBlocked = !coordinator.canStartAlertTriggeredScanForTesting
        let cy3Pill = StageResolver.statusPill(for: coordinator.currentStage(monitoringEnabled: true))

        // Ease from Critical -> Partial Recovery 10% residual loss (severity ok, no reset!) -> Problem (red) + .critical dot, still no scan loop!
        simNow = baseCycleNow.addingTimeInterval(80)
        coordinator.alerts.invalidateConnection()
        let cy4 = makeSample(seq: 204, gwRtt: 15, gwLoss: 10, gwJitter: 5, inetRtt: 34, inetLoss: 10, inetJitter: 6, topJitter: 6, severity: "ok", rules: [])
        feed(cy4, beats: smoothBeats(base: 38.0, jitter: 6.0, missesAt: [5, 16]))
        let cy4Pill = StageResolver.statusPill(for: coordinator.currentStage(monitoringEnabled: true))
        let cy4Health = coordinator.currentHealth

        // Finally recover cleanly for > 120s monotonically forward so cooldown resets!
        simNow = Date().addingTimeInterval(-140)
        coordinator.alerts.now = { simNow }
        let cy5a = makeSample(seq: 205, gwRtt: 5, gwLoss: 0, gwJitter: 0.9, inetRtt: 18, inetLoss: 0, inetJitter: 1.5, severity: "ok", rules: [])
        feed(cy5a, beats: smoothBeats(base: 18.0, jitter: 1.8))
        simNow = Date()
        coordinator.alerts.now = { simNow }
        let cy5b = makeSample(seq: 206, gwRtt: 5, gwLoss: 0, gwJitter: 0.9, inetRtt: 18, inetLoss: 0, inetJitter: 1.5, severity: "ok", rules: [])
        feed(cy5b, beats: smoothBeats(base: 18.0, jitter: 1.8))

        capture(id: "16-continuous-transition-cycle", title: "End-to-end NO-RESET transition cycle -> Live, Activity, Trends, Networks", alsoHome: true, extraTabs: [.live, .activity, .trends, .networks]) {
            let s = coordinator.currentStage(monitoringEnabled: true)
            let p = StageResolver.statusPill(for: s)
            return [
                ("step 2 bg scan kept 60ms live data + amber Degraded pill", cy2PreScanOk),
                ("step 3 escalation blocked repeat scan & showed Problem red", cy3CooldownBlocked && cy3Pill.text == "Problem" && cy3Pill.tone == .red),
                ("step 4 post-loss 10% kept Problem red + critical dot (never Watching)", cy4Pill.text == "Problem" && cy4Pill.tone == .red && cy4Health == .critical),
                ("step 5 clean recovery restored green Watching pill", p.text == "Watching" && p.tone == .green),
                ("120s clean run reset alert-triggered cooldown", coordinator.canStartAlertTriggeredScanForTesting),
            ]
        }

        // 17. Isolated router ICMP rate-limiting (gw 10% vs internet 0%) -> Check Details shows "None · Router ping only"
        simNow = simNow.addingTimeInterval(12)
        coordinator.alerts.invalidateConnection()
        coordinator.resetGalleryState()
        attachSpeedBaseline()
        let s17 = makeSample(
            seq: 17,
            gwRtt: 4.2, gwLoss: 10.0, gwLastLoss: 0.0, gwJitter: 1.1,
            inetRtt: 16.5, inetLoss: 0.0, inetLossAlt: 0.0, inetLastLoss: 0.0, inetJitter: 1.4,
            severity: "ok", rules: []
        )
        feed(s17, beats: smoothBeats(base: 16.5, jitter: 1.4))
        capture(id: "17-isolated-gateway-rate-limit", title: "Isolated router ICMP rate-limit (gw=10%, inet=0%)", alsoHome: true, alsoFullHome: true) {
            let s = coordinator.currentStage(monitoringEnabled: true)
            let p = StageResolver.statusPill(for: s)
            let eff = EffectiveLoss.compute(
                internetLoss: s17.internet.lossPct,
                gatewayLoss: s17.gateway.lossPct,
                filtering: EffectiveLoss.filtering(sample: s17),
                hasRecentRoam: false
            )
            return [
                ("EffectiveLoss suppresses isolated 10% router loss to 0%", eff == 0.0),
                ("isIsolatedGatewayRateLimit is true", EffectiveLoss.isIsolatedGatewayRateLimit(gatewayLoss: s17.gateway.lossPct, internetLoss: s17.internet.lossPct)),
                ("pill is Watching (green)", p.text == "Watching" && p.tone == .green),
                ("health is .healthy", coordinator.currentHealth == .healthy),
            ]
        }

        // 18. Rolling-window recovery (last_probe_loss_pct == 0% while 10-probe avg is 10%) -> "10% avg" & "0% now · 10% avg"
        simNow = simNow.addingTimeInterval(6)
        coordinator.alerts.invalidateConnection()
        coordinator.resetGalleryState()
        attachSpeedBaseline()
        let s18 = makeSample(
            seq: 18,
            gwRtt: 5.1, gwLoss: 0.0, gwLastLoss: 0.0, gwJitter: 1.2,
            inetRtt: 22.0, inetLoss: 10.0, inetLossAlt: 10.0, inetLastLoss: 0.0, inetJitter: 2.4,
            severity: "ok", rules: []
        )
        feed(s18, beats: smoothBeats(base: 22.0, jitter: 2.0))
        capture(id: "18-rolling-window-recovery", title: "Rolling-window recovery (0% now · 10% avg)", alsoDark: true, alsoHome: true, alsoFullHome: true, extraTabs: [.live]) {
            let recovering = EffectiveLoss.isRecovering(windowLoss: 10.0, lastProbeLoss: 0.0)
            let menuStr = MenuBarLabel.formatLoss(lossPct: 10.0, lastProbeLossPct: 0.0)
            let detailStr = EffectiveLoss.formatWindowDetail(windowLoss: 10.0, lastProbeLoss: 0.0)
            return [
                ("EffectiveLoss.isRecovering detects 0% last probe clearing", recovering),
                ("menu bar label reads 10% avg", menuStr == "10% avg"),
                ("detail label reads 0% now · 10% avg", detailStr == "0% now · 10% avg"),
            ]
        }

        // 19. Live Wi-Fi TX rate collapse (W4) despite strong RSSI (-58 dBm, 6 Mbps TX)
        simNow = simNow.addingTimeInterval(6)
        coordinator.alerts.invalidateConnection()
        coordinator.resetGalleryState()
        attachSpeedBaseline()
        let s19 = makeSample(
            seq: 19,
            gwRtt: 18.0, gwLoss: 0.0, gwLastLoss: 0.0, gwJitter: 4.5,
            inetRtt: 34.0, inetLoss: 0.0, inetLossAlt: 0.0, inetLastLoss: 0.0, inetJitter: 5.0,
            rssi: -58, snr: 34, channel: "44", txRate: 6,
            severity: "warn", rules: ["W4"]
        )
        feed(s19, beats: smoothBeats(base: 34.0, jitter: 4.0))
        capture(id: "19-wifi-tx-collapse-W4", title: "Live Wi-Fi TX rate collapse (W4: 6 Mbps @ -58 dBm)", alsoHome: true, alsoFullHome: true) {
            let s = coordinator.currentStage(monitoringEnabled: true)
            let p = StageResolver.statusPill(for: s)
            let w4Items = SuitabilityEngine.evaluateAll(
                .init(
                    monitorSample: coordinator.liveSample,
                    catalog: coordinator.rulesCatalog.catalog,
                    firedRules: Array(coordinator.activeFiredRules),
                    isLinkUp: true,
                    effectiveLoss: 0.0
                )
            )
            let browsing = w4Items.first { $0.id == "browsing" }
            let unScannedCh = DashboardCheckEvidence.wifiChannel(snapshot: nil, channel: "44", fallbackChannel: "")
            return [
                ("wifi.txRate decodes as 6 Mbps", coordinator.liveSample?.wifi?.txRate == 6),
                ("W4 appears in active rules", coordinator.liveSample?.status.rules.contains("W4") == true),
                ("pill is Degraded (amber)", p.text == "Degraded" && p.tone == .amber),
                ("health is .warning", coordinator.currentHealth == .warning),
                ("browsing W4 consequence is concise", (browsing?.consequence.count ?? 99) <= 54),
                ("known channel without scan says Not scanned", unScannedCh.badge?.label == "Not scanned"),
            ]
        }

        // 20. Remaining Settings sub-tabs & standalone modal/detail sheets
        let sampleRunJSON = """
        {
          "version": "\(AppVersion.display)",
          "timestamp": "\(ISO8601DateFormatter().string(from: Date()))",
          "run_mode": "full",
          "interface": { "name": "en0", "type": "Wi-Fi", "ip": "192.168.1.42" },
          "network": { "id": "\(simNetworkID)", "ssid": "\(simNetworkName)" },
          "wifi": { "ssid": "\(simNetworkName)", "rssi": -58, "noise": -92, "snr": 34, "band": "5 GHz", "channel": "44", "phy": "802.11ax", "tx_rate": 866 },
          "gateway": { "ip": "192.168.1.1", "rtt_avg_ms": 5.2, "rtt_jitter_ms": 1.1, "loss_pct": 0.0 },
          "internet_latency": { "targets": ["1.1.1.1", "8.8.8.8"], "rtt_avg_ms": 18.4, "rtt_jitter_ms": 1.6, "loss_pct": 0.0, "loss_pct_alt": 0.0 },
          "public": { "ip": "118.69.120.44", "isp": "Viettel Corporation", "country": "VN" },
          "dns": [
            { "server": "1.1.1.1", "ok": true, "elapsed_ms": 14.0 },
            { "server": "8.8.8.8", "ok": true, "elapsed_ms": 17.5 }
          ],
          "bufferbloat": { "gw_delta_ms": 4.0, "gw_grade": "A", "inet_delta_ms": 8.5, "inet_grade": "A" },
          "mtu": { "pmtu": 1500, "fragmentation_needed": false },
          "speedtest": { "down_mbps": 425.0, "up_mbps": 68.0, "latency_ms": 14.0, "jitter_ms": 1.5, "server": "Viettel HCMC" },
          "wifi_scan": { "current_channel": "44", "neighbour_count": 3, "current_channel_neighbours": 0 },
          "tcp_reach": [
            { "host": "1.1.1.1", "port": 443, "ok": true },
            { "host": "8.8.8.8", "port": 443, "ok": true }
          ],
          "diagnosis": []
        }
        """
        let sampleSnapshot = (try? JSONDecoder().decode(RunSnapshot.self, from: Data(sampleRunJSON.utf8))) ?? RunSnapshot()
        coordinator.alerts.invalidateConnection()
        coordinator.resetGalleryState()
        attachSpeedBaseline()
        let s20 = makeSample(seq: 20, gwRtt: 5.0, gwLoss: 0.0, gwJitter: 0.8, inetRtt: 18.0, inetLoss: 0.0, inetJitter: 1.5)
        feed(s20, beats: smoothBeats(base: 18.0, jitter: 2.0))
        capture(
            id: "20-auxiliary-views",
            title: "Settings sub-tabs + RunReportView + RawJSONViewer + Onboarding + What's New",
            customRenders: {
                var rendered: [String] = []
                let settingsTabs: [(SettingsView.Tab, String)] = [
                    (.alerts, "tab-settings-alerts-20.png"),
                    (.diagnostics, "tab-settings-diagnostics-20.png"),
                    (.about, "tab-settings-about-20.png"),
                ]
                for (tab, fname) in settingsTabs {
                    if renderMainWindowPNG(
                        coordinator: coordinator,
                        section: .settings,
                        settingsTab: tab,
                        to: outURL.appendingPathComponent(fname)
                    ) {
                        rendered.append(fname)
                    }
                }
                let reportView = ScrollView {
                    RunReportView(
                        snapshot: sampleSnapshot,
                        rawJSON: sampleRunJSON,
                        showRuleIDs: true,
                        presentation: .full
                    )
                    .padding(20)
                }
                .background(Theme.ColorToken.detailBackground)
                .environment(coordinator)
                .environment(coordinator.appSettings)
                if renderStandalonePNG(reportView, size: NSSize(width: 860, height: 980), colorScheme: .light, appearance: NSAppearance(named: .aqua), to: outURL.appendingPathComponent("view-run-report.png")) {
                    rendered.append("view-run-report.png")
                }
                if renderStandalonePNG(reportView, size: NSSize(width: 860, height: 980), colorScheme: .dark, appearance: NSAppearance(named: .darkAqua), to: outURL.appendingPathComponent("view-run-report-dark.png")) {
                    rendered.append("view-run-report-dark.png")
                }
                let rawJsonSheet = RawJSONViewerSheet(
                    rawJSON: sampleRunJSON,
                    title: "Diagnostic Report Raw JSON",
                    isPresented: .constant(true)
                )
                .background(Theme.ColorToken.detailBackground)
                if renderStandalonePNG(rawJsonSheet, size: NSSize(width: 760, height: 560), colorScheme: .light, appearance: NSAppearance(named: .aqua), to: outURL.appendingPathComponent("view-raw-json.png")) {
                    rendered.append("view-raw-json.png")
                }
                let onboarding = OnboardingView()
                    .background(Theme.ColorToken.detailBackground)
                    .environment(coordinator)
                    .environment(coordinator.appSettings)
                if renderStandalonePNG(onboarding, size: NSSize(width: 540, height: 560), colorScheme: .light, appearance: NSAppearance(named: .aqua), to: outURL.appendingPathComponent("view-onboarding.png")) {
                    rendered.append("view-onboarding.png")
                }
                let whatsNew = WhatsNewView()
                    .background(Theme.ColorToken.detailBackground)
                if renderStandalonePNG(whatsNew, size: NSSize(width: 620, height: 680), colorScheme: .light, appearance: NSAppearance(named: .aqua), to: outURL.appendingPathComponent("view-whats-new.png")) {
                    rendered.append("view-whats-new.png")
                }
                return rendered
            }
        ) {
            return [
                ("decoded full RunSnapshot version matches", sampleSnapshot.version == AppVersion.display),
                ("decoded sample includes speedtest & wifi_scan", sampleSnapshot.speedtest?.downMbps == 425.0 && sampleSnapshot.wifiScan?.neighbourCount == 3),
            ]
        }

        let manifest = AuditManifest(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            totalScenarios: reports.count,
            totalChecks: totalChecks,
            totalFailures: totalFailures,
            scenarios: reports
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let jsonData = try? encoder.encode(manifest) {
            try? jsonData.write(to: outURL.appendingPathComponent("manifest.json"))
        }

        print("\nVisual audit complete: \(reports.count) scenarios, \(totalChecks - totalFailures)/\(totalChecks) invariants passed, \(totalFailures) failed.")
        print("Output written to: \(outURL.path)")
        return totalFailures == 0 ? 0 : 1
    }

    // MARK: - Helpers

    private static func stageLabel(_ stage: StageResolver.Stage) -> String {
        switch stage {
        case .healthy: return "healthy"
        case .degraded(let d): return "degraded(\(d.isCritical ? "critical" : "warn"))"
        case .resolved: return "resolved"
        case .noLink: return "noLink"
        case .watching(let sev): return "watching(\(sev))"
        case .alerted(let a): return "alerted(\(a.title))"
        case .notReporting: return "notReporting"
        case .checking: return "checking"
        case .testing: return "testing"
        case .arrived: return "arrived"
        case .paused(let r): return "paused(\(r ?? ""))"
        case .skewed(let m): return "skewed(\(m))"
        }
    }

    private static func toneLabel(_ tone: StageResolver.PillTone) -> String {
        switch tone {
        case .green: return "green"
        case .amber: return "amber"
        case .red: return "red"
        case .blue: return "blue"
        case .muted: return "muted"
        }
    }

    private static func renderDropdownPNG(
        coordinator: HopwatchCoordinator,
        colorScheme: ColorScheme,
        appearance: NSAppearance?,
        to url: URL
    ) -> Bool {
        let view = DropdownView()
            .environment(coordinator)
            .environment(coordinator.appSettings)
            .environment(\.colorScheme, colorScheme)
            .preferredColorScheme(colorScheme)
        let sizer = NSHostingView(rootView: view)
        sizer.layoutSubtreeIfNeeded()
        let height = max(620, ceil(sizer.fittingSize.height))
        let size = NSSize(width: 420, height: height)
        return renderViewInWindow(view, size: size, appearance: appearance, to: url)
    }

    private static func renderMainWindowPNG(
        coordinator: HopwatchCoordinator,
        section: SidebarSection,
        settingsTab: SettingsView.Tab = .general,
        colorScheme: ColorScheme = .light,
        appearance: NSAppearance? = NSAppearance(named: .aqua),
        height: CGFloat = 780,
        to url: URL
    ) -> Bool {
        let view = MainWindow(initialSection: section, initialSettingsTab: settingsTab, skipHistoryReload: true)
            .environment(coordinator)
            .environment(coordinator.appSettings)
            .environment(\.colorScheme, colorScheme)
            .preferredColorScheme(colorScheme)
        let size = NSSize(width: 1080, height: height)
        return renderViewInWindow(view, size: size, appearance: appearance, to: url, pumpRunLoop: true)
    }

    private static func renderStandalonePNG(
        _ view: some View,
        size: NSSize,
        colorScheme: ColorScheme,
        appearance: NSAppearance?,
        to url: URL
    ) -> Bool {
        let wrapped = view
            .environment(\.colorScheme, colorScheme)
            .preferredColorScheme(colorScheme)
        return renderViewInWindow(wrapped, size: size, appearance: appearance, to: url, pumpRunLoop: true)
    }

    private static func renderViewInWindow(
        _ view: some View,
        size: NSSize,
        appearance: NSAppearance?,
        to url: URL,
        pumpRunLoop: Bool = false
    ) -> Bool {
        let targetAppearance = appearance ?? NSAppearance(named: .aqua)
        let isDark = targetAppearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let prevAppAppearance = NSApp.appearance
        NSApp.appearance = targetAppearance
        defer { NSApp.appearance = prevAppAppearance }

        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = true
        window.backgroundColor = isDark ? NSColor(calibratedWhite: 0.11, alpha: 1.0) : .white
        window.appearance = targetAppearance
        hosting.appearance = window.appearance
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting

        var capturedRep: NSBitmapImageRep?
        let captureBlock = {
            hosting.layoutSubtreeIfNeeded()
            if pumpRunLoop {
                RunLoop.current.run(until: Date().addingTimeInterval(0.18))
                hosting.layoutSubtreeIfNeeded()
            }
            window.displayIfNeeded()
            if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                capturedRep = rep
            }
        }
        if let targetAppearance {
            targetAppearance.performAsCurrentDrawingAppearance(captureBlock)
        } else {
            captureBlock()
        }

        guard let rep = capturedRep,
              let png = rep.representation(using: .png, properties: [:]) else {
            return false
        }
        do {
            try png.write(to: url)
            return true
        } catch {
            return false
        }
    }
}
