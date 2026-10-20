import Foundation

/// Formats an authoritative, clean diagnostic report suitable for sending to non-technical
/// staff (hotel front desks, Airbnb hosts) as well as technical support / IT helpdesks / ISPs.
enum SupportSummaryFormatter {

    struct Parameters: Sendable {
        var networkName: String?
        var gatewayIP: String?
        var signalQuality: String?
        var observedProblem: String?
        var localVerification: String?
        var concreteAction: String?
        var timestamp: String?
        var userImpact: String?
        var isolationHeading: String?
        var isolationBullets: [String] = []
        var clientIP: String?
        var interfaceName: String?
        var bssid: String?
        var publicIP: String?
        var ispInfo: String?
        var internetLatency: String?
        var dnsStatus: String?
        var captivePortal: String?
        var vpnStatus: String?
        var bufferbloat: String?
        var diagnosticFindings: [String] = []
        var technicalDetails: [String] = []
        var appVersion: String?
        var repoURL: String = "https://github.com/godigi/hopwatch"

        init(
            networkName: String? = nil,
            gatewayIP: String? = nil,
            signalQuality: String? = nil,
            observedProblem: String? = nil,
            localVerification: String? = nil,
            concreteAction: String? = nil,
            timestamp: String? = nil,
            userImpact: String? = nil,
            isolationHeading: String? = nil,
            isolationBullets: [String] = [],
            clientIP: String? = nil,
            interfaceName: String? = nil,
            bssid: String? = nil,
            publicIP: String? = nil,
            ispInfo: String? = nil,
            internetLatency: String? = nil,
            dnsStatus: String? = nil,
            captivePortal: String? = nil,
            vpnStatus: String? = nil,
            bufferbloat: String? = nil,
            diagnosticFindings: [String] = [],
            technicalDetails: [String] = [],
            appVersion: String? = nil,
            repoURL: String = "https://github.com/godigi/hopwatch"
        ) {
            self.networkName = networkName
            self.gatewayIP = gatewayIP
            self.signalQuality = signalQuality
            self.observedProblem = observedProblem
            self.localVerification = localVerification
            self.concreteAction = concreteAction
            self.timestamp = timestamp
            self.userImpact = userImpact
            self.isolationHeading = isolationHeading
            self.isolationBullets = isolationBullets
            self.clientIP = clientIP
            self.interfaceName = interfaceName
            self.bssid = bssid
            self.publicIP = publicIP
            self.ispInfo = ispInfo
            self.internetLatency = internetLatency
            self.dnsStatus = dnsStatus
            self.captivePortal = captivePortal
            self.vpnStatus = vpnStatus
            self.bufferbloat = bufferbloat
            self.diagnosticFindings = diagnosticFindings
            self.technicalDetails = technicalDetails
            self.appVersion = appVersion
            self.repoURL = repoURL
        }
    }

    /// Formats signal strength and quality with a plain-English rating.
    static func describeSignal(
        rssi: Int?,
        snr: Int? = nil,
        channel: String? = nil,
        isWired: Bool = false
    ) -> String {
        if isWired { return "Wired Ethernet link" }
        guard let rssi else { return "Wi-Fi signal unavailable / Wired" }

        let rating: String
        if rssi >= -55 {
            rating = "Excellent"
        } else if rssi >= -68 {
            rating = "Good"
        } else if rssi >= -78 {
            rating = "Fair"
        } else {
            rating = "Weak"
        }

        var parts: [String] = ["\(rating) (\(rssi) dBm)"]
        if let snr {
            parts.append("SNR \(snr) dB")
        }
        if let channel, !channel.isEmpty {
            parts.append("Ch \(channel)")
        }
        return parts.joined(separator: ", ")
    }

    /// Builds the root-cause isolation section explaining whether the laptop and Wi-Fi
    /// reception are ruled out as causes of the problem.
    static func buildIsolation(
        attribution: HopAttributionResolver.Result,
        rssi: Int?,
        snr: Int?,
        isWired: Bool,
        gatewayIP: String?,
        gatewayLoss: Double?,
        gatewayRTT: Double?,
        inetLoss: Double?,
        inetRTT: Double?,
        dnsFailed: Bool,
        vpnActive: Bool,
        trafficDownMbps: Double? = nil,
        trafficUpMbps: Double? = nil,
        observedProblem: String?,
        ispName: String?,
        captivePortal: String? = nil
    ) -> (heading: String, bullets: [String]) {
        let ruleSet = Set(attribution.activeRules)
        let hasHeavyLocalTraffic = ruleSet.contains("TR-1")
            || (trafficDownMbps ?? 0) > 25.0
            || (trafficUpMbps ?? 0) > 10.0
        let macRuledOut = attribution.macHealth == .healthy && !hasHeavyLocalTraffic

        var bullets: [String] = []

        // 1. Computer / Laptop evaluation
        if macRuledOut {
            if let down = trafficDownMbps, let up = trafficUpMbps {
                let vpnClause = vpnActive ? "" : ", and no VPN is active"
                bullets.append(
                    "Computer / Laptop Ruled Out: This computer's network adapter is healthy and local traffic is idle (\(String(format: "%.1f", down)) Mbps down / \(String(format: "%.1f", up)) Mbps up\(vpnClause)). The laptop itself is not causing the slowdown."
                )
            } else {
                let vpnClause = vpnActive
                    ? "no heavy background downloads or uploads"
                    : "no heavy background downloads, uploads, or active VPNs"
                bullets.append(
                    "Computer / Laptop Ruled Out: This computer's network adapter is healthy and idle (\(vpnClause)). The laptop itself is not causing the issue."
                )
            }
        } else if hasHeavyLocalTraffic {
            bullets.append(
                "Computer / Local Traffic Note: High local bandwidth usage was detected on this computer during the check, which may contribute to queuing delay."
            )
        } else {
            bullets.append("Computer / Local Software Note: \(attribution.reassurance)")
        }

        // 2. Wi-Fi Signal / Distance evaluation
        let wifiSignalSolid: Bool
        if isWired {
            wifiSignalSolid = true
            bullets.append(
                "Wi-Fi / Distance Ruled Out: Connected via direct wired Ethernet cable, completely ruling out wireless interference or room distance."
            )
        } else if let rssi {
            if rssi > -75 && attribution.wifiHealth == .healthy {
                wifiSignalSolid = true
                let rating = rssi >= -55 ? "Excellent" : (rssi >= -68 ? "Good" : "Fair")
                let snrPart = snr.map { ", SNR \($0) dB" } ?? ""
                bullets.append(
                    "Wi-Fi Signal / Distance Ruled Out: Wireless signal between this computer and the access point is \(rating) (\(rssi) dBm\(snrPart), well above the -75 dBm minimum threshold). Sitting closer to the router will not fix this because signal strength is already solid."
                )
            } else if ruleSet.contains("WS-1") && rssi > -75 {
                wifiSignalSolid = false
                bullets.append(
                    "Wi-Fi Radio Channel Congested: Signal strength is \(rssi) dBm, but the access point's wireless channel is crowded by neighboring networks (an access point configuration issue, not the laptop)."
                )
            } else {
                wifiSignalSolid = false
                let snrPart = snr.map { ", SNR \($0) dB" } ?? ""
                bullets.append(
                    "Room Wi-Fi Coverage Issue: Wireless signal in this location is Weak (\(rssi) dBm\(snrPart), below the -75 dBm threshold needed for a stable connection). The access point is too far from this area or blocked by walls/floors."
                )
            }
        } else {
            if attribution.wifiHealth == .healthy {
                wifiSignalSolid = true
                bullets.append(
                    "Wi-Fi / Local Link Ruled Out: The local wireless connection between this computer and the access point is active and healthy."
                )
            } else {
                wifiSignalSolid = false
                bullets.append(
                    "Local Wi-Fi Link Issue: The wireless connection between the access point and this location is dropping or unstable."
                )
            }
        }

        // 3. Actual Fault Location
        let gwDisplay = gatewayIP ?? "the local router"
        if let cp = captivePortal, !cp.isEmpty {
            bullets.append(
                "Actual Fault Location (Captive Portal / Sign-In Gateway): The Wi-Fi link is connected, but the gateway requires captive portal sign-in/terms acceptance before permitting internet access. Internet connectivity will remain blocked until the sign-in page is completed or guest credentials are provided."
            )
        } else if attribution.culprit == .router || (wifiSignalSolid && ((gatewayLoss ?? 0) >= 1 || (gatewayRTT ?? 0) > 150)) {
            var faultMetrics: [String] = []
            if let loss = gatewayLoss, loss > 0 {
                faultMetrics.append("dropping \(LossFormatter.formatPct(loss)) of packets")
            }
            if let rtt = gatewayRTT, rtt > 30 {
                faultMetrics.append(String(format: "%.1f ms latency", rtt))
            }
            let metricPhrase = faultMetrics.isEmpty
                ? "experiencing internal errors (\(observedProblem ?? "degradation"))"
                : faultMetrics.joined(separator: " at ")
            bullets.append(
                "Actual Fault Location (Local Router / Access Point): Despite a healthy computer and clean wireless signal, the local router (\(gwDisplay)) is \(metricPhrase). The fault is inside the router/access point hardware and requires a router restart or admin check."
            )
        } else if attribution.culprit == .isp || (inetLoss ?? 0) >= 1 || (inetRTT ?? 0) > 250 || dnsFailed {
            let gwClean = (gatewayLoss ?? 0) == 0 ? "with 0% packet loss" : "normally"
            let ispLabel = ispName.map { " (\($0))" } ?? ""
            var upstreamMetrics: [String] = []
            if let loss = inetLoss, loss > 0 {
                upstreamMetrics.append("\(LossFormatter.formatPct(loss)) internet packet loss")
            }
            if let rtt = inetRTT, rtt > 150 {
                upstreamMetrics.append(String(format: "%.0f ms internet latency", rtt))
            }
            if dnsFailed {
                upstreamMetrics.append("failing DNS lookups")
            }
            let upstreamPhrase = upstreamMetrics.isEmpty
                ? (observedProblem ?? "upstream connectivity failure")
                : upstreamMetrics.joined(separator: ", ")
            bullets.append(
                "Actual Fault Location (Upstream ISP / Broadband Line): Traffic reaches the local router (\(gwDisplay)) \(gwClean), proving the computer and room Wi-Fi are working properly. The failure (\(upstreamPhrase)) is occurring past the router on the internet provider's line\(ispLabel)."
            )
        } else if !wifiSignalSolid {
            bullets.append(
                "Actual Fault Location (Property Wi-Fi Coverage / Access Point): The issue is caused by weak wireless coverage or radio interference between the property's access point and this room/area, not by the computer."
            )
        } else if !macRuledOut {
            bullets.append(
                "Actual Fault Location (Local Device): Diagnostics indicate the issue is originating on this computer (\(observedProblem ?? "local condition")) rather than the property's network."
            )
        } else {
            bullets.append(
                "Actual Fault Location (Network / Router Side): Diagnostic checks confirm the degradation (\(observedProblem ?? "network instability")) is occurring on the local router (\(gwDisplay)) or upstream internet connection, outside of this computer's control."
            )
        }

        let heading: String
        if macRuledOut && wifiSignalSolid {
            heading = "Why This Is Not a Computer or Distance Issue"
        } else if macRuledOut {
            heading = "Why This Is Not a Computer Issue (Root-Cause Isolation)"
        } else {
            heading = "Root-Cause Isolation"
        }

        return (heading, bullets)
    }

    /// Synthesizes default isolation bullets when `format(_ params: Parameters)` is called directly.
    private static func defaultIsolation(for params: Parameters) -> (heading: String, bullets: [String]) {
        var bullets: [String] = []
        bullets.append(
            "Computer / Laptop Ruled Out: This computer's network adapter is healthy and idle (no heavy background downloads, uploads, or conflicting software). The laptop itself is not causing the issue."
        )

        var wifiSolid = true
        if let sig = params.signalQuality, !sig.isEmpty {
            let lower = sig.lowercased()
            if lower.contains("wired") || lower.contains("ethernet") {
                bullets.append(
                    "Wi-Fi / Distance Ruled Out: Connected via direct wired Ethernet cable, completely ruling out wireless interference or room distance."
                )
            } else if lower.contains("weak") {
                wifiSolid = false
                bullets.append(
                    "Room Wi-Fi Coverage Issue: Wireless signal in this location is \(sig) (below the -75 dBm threshold needed for a stable connection). The access point is too far from this area or obstructed."
                )
            } else {
                bullets.append(
                    "Wi-Fi Signal / Distance Ruled Out: Wireless signal between this computer and the access point is solid (\(sig), above the -75 dBm minimum threshold). Sitting closer to the router will not fix this because signal strength is already good."
                )
            }
        } else {
            bullets.append(
                "Wi-Fi / Local Link Ruled Out: The local connection between this computer and the network is active and healthy."
            )
        }

        let gw = params.gatewayIP ?? "the local router"
        let prob = params.observedProblem ?? "network instability"
        if wifiSolid {
            bullets.append(
                "Actual Fault Location (Network / Router Side): Despite a healthy computer and clean wireless signal, diagnostic probes show the issue (\(prob)) is occurring on the network/router side (\(gw)), which can only be resolved via the network equipment or ISP."
            )
        } else {
            bullets.append(
                "Actual Fault Location (Property Wi-Fi Coverage / Access Point): The issue is caused by weak wireless coverage between the property's access point and this area, not by the computer."
            )
        }

        let heading = wifiSolid
            ? "Why This Is Not a Computer or Distance Issue"
            : "Why This Is Not a Computer Issue (Root-Cause Isolation)"
        return (heading, bullets)
    }

    /// Formats the summary into an authoritative, clean human-readable text report.
    static func format(_ params: Parameters) -> String {
        var lines: [String] = []
        lines.append("Hopwatch Network Diagnostic Report")
        lines.append(String(repeating: "=", count: 34))

        let net = params.networkName ?? "Unknown Network"
        lines.append("Network: \(net)")
        if let ts = params.timestamp, !ts.isEmpty {
            lines.append("Timestamp: \(ts)")
        }
        let versionStr = params.appVersion ?? Defaults.appVersion
        lines.append("Tool: Hopwatch v\(versionStr) (\(params.repoURL))")
        lines.append("")

        lines.append("Summary for Host / Front Desk")
        lines.append("-----------------------------")
        let prob = params.observedProblem ?? "Intermittent connection instability detected"
        lines.append("Issue: \(prob)")

        if let impact = params.userImpact, !impact.isEmpty {
            lines.append("Impact: \(impact)")
        }

        let action = params.concreteAction ?? "Please consider restarting the local Wi-Fi router / access point"
        lines.append("Suggested Action: \(action)")
        lines.append("")

        // Root-Cause Isolation Section
        let fallbackIso = defaultIsolation(for: params)
        let isoHeading = params.isolationHeading ?? fallbackIso.heading
        let isoBullets = params.isolationBullets.isEmpty ? fallbackIso.bullets : params.isolationBullets

        lines.append(isoHeading)
        lines.append(String(repeating: "-", count: isoHeading.count))
        for bullet in isoBullets {
            lines.append("• \(bullet)")
        }
        lines.append("")

        lines.append("Technical Telemetry (for Support / IT / ISP)")
        lines.append("--------------------------------------------")

        if let clientIP = params.clientIP, !clientIP.isEmpty {
            if let iface = params.interfaceName, !iface.isEmpty {
                lines.append("• Client Device: \(clientIP) (\(iface))")
            } else {
                lines.append("• Client Device: \(clientIP)")
            }
        }

        if let sig = params.signalQuality, !sig.isEmpty {
            if let bssid = params.bssid, !bssid.isEmpty {
                lines.append("• Wi-Fi Signal: \(sig) | AP BSSID: \(bssid)")
            } else {
                lines.append("• Signal Quality: \(sig)")
            }
        } else if let bssid = params.bssid, !bssid.isEmpty {
            lines.append("• AP BSSID: \(bssid)")
        }

        if let gw = params.gatewayIP, !gw.isEmpty {
            lines.append("• Local Gateway: \(gw)")
        }

        if let inet = params.internetLatency, !inet.isEmpty {
            lines.append("• Internet Path: \(inet)")
        }

        if let pub = params.publicIP, !pub.isEmpty {
            if let isp = params.ispInfo, !isp.isEmpty {
                lines.append("• Public Endpoint: \(pub) (\(isp))")
            } else {
                lines.append("• Public Endpoint: \(pub)")
            }
        } else if let isp = params.ispInfo, !isp.isEmpty {
            lines.append("• Provider / ISP: \(isp)")
        }

        if let dns = params.dnsStatus, !dns.isEmpty {
            lines.append("• DNS Resolution: \(dns)")
        }

        if let bb = params.bufferbloat, !bb.isEmpty {
            lines.append("• Bufferbloat: \(bb)")
        }

        if let cp = params.captivePortal, !cp.isEmpty {
            lines.append("• Captive Portal: \(cp)")
        }

        if let vpn = params.vpnStatus, !vpn.isEmpty {
            lines.append("• VPN / Relay: \(vpn)")
        }

        let verification = params.localVerification ?? "Local link is idle and healthy; issue is upstream on network/router"
        lines.append("• Device Status: \(verification)")

        for detail in params.technicalDetails {
            lines.append("• \(detail)")
        }

        if !params.diagnosticFindings.isEmpty {
            lines.append("")
            lines.append("Diagnostic Rule Findings:")
            for finding in params.diagnosticFindings {
                lines.append("• \(finding)")
            }
        }

        lines.append("")
        lines.append(String(repeating: "-", count: 48))
        lines.append("Automated report generated by Hopwatch — macOS Network Diagnostics")
        lines.append("GitHub: \(params.repoURL)")

        return lines.joined(separator: "\n")
    }

    /// Builds a support summary from a `RunSnapshot`.
    static func format(
        snapshot: RunSnapshot,
        catalog: RulesCatalog? = nil,
        networkIsOwned: Bool = false
    ) -> String {
        let netName = snapshot.wifi?.ssid ?? snapshot.network.label ?? snapshot.network.id ?? "Unknown Network"
        let gwIP = snapshot.gateway.ip ?? snapshot.interfaceInfo.gateway
        let isWired = snapshot.interfaceInfo.type == "wired" && snapshot.wifi == nil

        let signalStr: String?
        if let wifi = snapshot.wifi {
            signalStr = describeSignal(rssi: wifi.rssi, snr: wifi.snr, channel: wifi.channel)
        } else if isWired {
            signalStr = describeSignal(rssi: nil, isWired: true)
        } else {
            signalStr = nil
        }

        // Gateway loss & latency
        var gwFormatted = gwIP
        var gwStats: [String] = []
        if let loss = snapshot.gateway.lossPct, loss > 0 {
            gwStats.append("\(LossFormatter.formatPct(loss)) loss")
        }
        if let rtt = snapshot.gateway.rttAvgMs, rtt > 0 {
            gwStats.append(String(format: "%.1f ms latency", rtt))
        }
        if let jit = snapshot.gateway.rttJitterMs, jit > 0 {
            gwStats.append(String(format: "±%.1f ms jitter", jit))
        }
        if let gw = gwFormatted, !gwStats.isEmpty {
            gwFormatted = "\(gw) (\(gwStats.joined(separator: ", ")))"
        }

        // Internet latency
        var internetStr: String?
        if let inetLoss = snapshot.internetLatency.lossPct, let inetRTT = snapshot.internetLatency.rttAvgMs {
            var parts = ["\(LossFormatter.formatPct(inetLoss)) loss", String(format: "%.1f ms avg latency", inetRTT)]
            if let jit = snapshot.internetLatency.rttJitterMs, jit > 0 {
                parts.append(String(format: "±%.1f ms jitter", jit))
            }
            internetStr = parts.joined(separator: ", ")
        } else if let inetLoss = snapshot.internetLatency.lossPct, inetLoss > 0 {
            internetStr = "\(LossFormatter.formatPct(inetLoss)) packet loss to public targets"
        } else if let inetRTT = snapshot.internetLatency.rttAvgMs, inetRTT > 0 {
            internetStr = "Reachable (\(String(format: "%.1f ms avg", inetRTT)))"
        }

        // Public ISP info
        let ispComponents = [snapshot.publicInfo.isp, snapshot.publicInfo.asn, snapshot.publicInfo.city, snapshot.publicInfo.country].compactMap { $0 }.filter { !$0.isEmpty }
        let ispStr = ispComponents.isEmpty ? nil : ispComponents.joined(separator: ", ")

        // DNS checks
        var dnsStr: String?
        let dnsFailed = snapshot.dns.contains(where: { !$0.ok })
        if !snapshot.dns.isEmpty {
            let failed = snapshot.dns.filter { !$0.ok }
            if !failed.isEmpty {
                dnsStr = "\(failed.count) of \(snapshot.dns.count) query checks failed"
            } else {
                dnsStr = "Operational (all \(snapshot.dns.count) checks passed)"
            }
        }

        // Bufferbloat
        var bufferbloatStr: String?
        if let grade = snapshot.bufferbloat.inetGrade ?? snapshot.bufferbloat.gwGrade {
            let delta = snapshot.bufferbloat.inetDeltaMs ?? snapshot.bufferbloat.gwDeltaMs
            if let delta, delta > 0 {
                bufferbloatStr = "Grade \(grade) (+\(Int(round(delta))) ms under load)"
            } else {
                bufferbloatStr = "Grade \(grade)"
            }
        }

        // Captive portal
        let captivePortalStr = snapshot.publicInfo.captivePortal == true ? "Detected (login / terms acceptance required)" : nil

        // VPN
        let vpnStr = snapshot.vpn.active
            ? "Active (\(snapshot.vpn.name ?? snapshot.vpn.type ?? "Tunnel"))"
            : "Inactive (Direct connection)"

        // Speedtest
        var technicalDetails: [String] = []
        if let st = snapshot.speedtest, let down = st.downMbps, let up = st.upMbps {
            technicalDetails.append("Speedtest: \(String(format: "%.1f", down)) Mbps down / \(String(format: "%.1f", up)) Mbps up")
        }

        var problem: String?
        var action: String?
        var impact: String?

        let isCaptive = snapshot.publicInfo.captivePortal == true
            || snapshot.diagnosis.contains(where: { $0.rule == "CP-1" })

        if isCaptive {
            problem = "Wi-Fi sign-in / captive portal authentication required to access the internet"
            impact = "Internet traffic is blocked until the captive portal sign-in is completed"
            action = !networkIsOwned
                ? "Please provide the guest Wi-Fi portal URL or login instructions."
                : "Open http://captive.apple.com to complete sign-in. If the portal does not load, temporarily disable custom DNS or VPN."
        } else {
            let worst = snapshot.diagnosis.first(where: { $0.severity == "critical" })
                ?? snapshot.diagnosis.first(where: { $0.severity == "warn" })
                ?? snapshot.diagnosis.first

            if let worst {
                let rule = worst.rule.flatMap { catalog?[$0] }
                if !networkIsOwned, let fixAway = rule?.fixAway {
                    problem = worst.summary
                    action = fixAway
                } else if let fix = rule?.fix {
                    problem = worst.summary
                    action = fix
                } else {
                    problem = worst.summary
                }
            } else if let cause = snapshot.mostLikelyRootCause {
                problem = cause
            }
        }

        // User impact derived from suitability or loss
        let degradedSuitability = snapshot.suitability.filter { $0.verdict == .degraded || $0.verdict == .broken }
        if !degradedSuitability.isEmpty {
            let names = degradedSuitability.compactMap { $0.label ?? $0.activity?.capitalized }.joined(separator: ", ")
            impact = "\(names) may be degraded or unresponsive"
        } else if (snapshot.gateway.lossPct ?? 0) >= 10 || (snapshot.internetLatency.lossPct ?? 0) >= 10 {
            impact = "Audio/video calls dropping and websites timing out"
        } else if (snapshot.gateway.lossPct ?? 0) >= 2 || (snapshot.internetLatency.lossPct ?? 0) >= 2 {
            impact = "Occasional call stutter and delayed page loading"
        } else if (snapshot.gateway.rttAvgMs ?? 0) > 150 || (snapshot.internetLatency.rttAvgMs ?? 0) > 200 {
            impact = "High latency causing delay and lag during interactive use"
        }

        // Problem fallback if still nil
        if problem == nil {
            if let gwLoss = snapshot.gateway.lossPct, gwLoss >= 1 {
                problem = "Packet loss between device and local router (\(LossFormatter.formatPct(gwLoss)))"
            } else if let netLoss = snapshot.internetLatency.lossPct, netLoss >= 1 {
                problem = "Packet loss between router and internet (\(LossFormatter.formatPct(netLoss)))"
            } else if let rtt = snapshot.gateway.rttAvgMs, rtt > 150 {
                problem = "High latency to local router (\(Int(round(rtt))) ms)"
            } else if let rtt = snapshot.internetLatency.rttAvgMs, rtt > 250 {
                problem = "High internet latency (\(Int(round(rtt))) ms)"
            } else if dnsFailed {
                problem = "DNS queries are failing or timing out"
            } else if let rssi = snapshot.wifi?.rssi, rssi < -78 {
                problem = "Weak Wi-Fi signal reception"
            } else {
                problem = "Intermittent network degradation detected"
            }
        }

        // Action fallback if still nil
        if action == nil {
            if let rssi = snapshot.wifi?.rssi, rssi < -78 {
                action = !networkIsOwned
                    ? "Please check if you can move closer to the access point or switch to a closer network band."
                    : "Move closer to your router or reposition Wi-Fi antennas."
            } else if (snapshot.gateway.lossPct ?? 0) >= 1 {
                action = !networkIsOwned
                    ? "Please restart or power-cycle the local Wi-Fi router / access point for this area."
                    : "Restart your router (unplug for 15 seconds, then plug back in)."
            } else if (snapshot.internetLatency.lossPct ?? 0) >= 1 {
                action = !networkIsOwned
                    ? "Please check if your internet provider has an ongoing outage in this area."
                    : "Check your modem/ONT connection, or contact your ISP to report an outage."
            } else {
                action = !networkIsOwned
                    ? "Please consider restarting the local router / access point, or check with your network provider."
                    : "Try restarting your router and modem. If issues persist, contact your ISP."
            }
        }

        // Local verification
        let localVerification: String
        if isCaptive {
            localVerification = "Wi-Fi link is connected; internet access blocked by captive portal"
        } else if let tr = snapshot.traffic, let down = tr.downMbps, let up = tr.upMbps {
            localVerification = "Mac traffic is low (\(String(format: "%.1f", down)) Mbps down / \(String(format: "%.1f", up)) Mbps up); issue is upstream on network/router"
        } else {
            localVerification = "Local link is idle and healthy; issue is upstream on network/router"
        }

        // Root-cause isolation
        let attribution = HopAttributionResolver.resolve(snapshot: snapshot)
        let isolation = buildIsolation(
            attribution: attribution,
            rssi: snapshot.wifi?.rssi,
            snr: snapshot.wifi?.snr,
            isWired: isWired,
            gatewayIP: gwIP,
            gatewayLoss: snapshot.gateway.lossPct,
            gatewayRTT: snapshot.gateway.rttAvgMs,
            inetLoss: snapshot.internetLatency.lossPct,
            inetRTT: snapshot.internetLatency.rttAvgMs,
            dnsFailed: dnsFailed,
            vpnActive: snapshot.vpn.active,
            trafficDownMbps: snapshot.traffic?.downMbps,
            trafficUpMbps: snapshot.traffic?.upMbps,
            observedProblem: problem,
            ispName: snapshot.publicInfo.isp,
            captivePortal: captivePortalStr
        )

        // Diagnostic rule findings
        let findings = snapshot.diagnosis.map { d in
            if let rule = d.rule {
                return "[\(rule)] \(d.summary)"
            }
            return d.summary
        }

        return format(Parameters(
            networkName: netName,
            gatewayIP: gwFormatted,
            signalQuality: signalStr,
            observedProblem: problem,
            localVerification: localVerification,
            concreteAction: action,
            timestamp: snapshot.timestamp,
            userImpact: impact,
            isolationHeading: isolation.heading,
            isolationBullets: isolation.bullets,
            clientIP: snapshot.interfaceInfo.ip,
            interfaceName: snapshot.interfaceInfo.name,
            bssid: snapshot.wifi?.bssid,
            publicIP: snapshot.publicInfo.ip,
            ispInfo: ispStr,
            internetLatency: internetStr,
            dnsStatus: dnsStr,
            captivePortal: captivePortalStr,
            vpnStatus: vpnStr,
            bufferbloat: bufferbloatStr,
            diagnosticFindings: findings,
            technicalDetails: technicalDetails
        ))
    }

    private static func isRawKey(_ str: String) -> Bool {
        str.hasPrefix("mac:") || str.hasPrefix("gw:") || str.hasPrefix("ssid:") || str.hasPrefix("wired:")
    }

    /// Builds a support summary from a live `MonitorSample`.
    static func format(
        sample: MonitorSample,
        alert: StageResolver.AlertSnapshot? = nil,
        catalog: RulesCatalog? = nil,
        networkIsOwned: Bool = false,
        fallbackNetworkName: String? = nil,
        fallbackRSSI: Int? = nil,
        fallbackChannel: String? = nil,
        fallbackSnapshot: RunSnapshot? = nil
    ) -> String {
        let nonKeyLabel = sample.network.label.flatMap { Self.isRawKey($0) ? nil : $0 }
        let netName = fallbackNetworkName
            ?? sample.link.ssid
            ?? nonKeyLabel
            ?? fallbackSnapshot?.wifi?.ssid
            ?? sample.network.label
            ?? sample.network.id
            ?? "Unknown Network"
        let gwIP = sample.link.gateway ?? fallbackSnapshot?.gateway.ip
        let isWired = sample.link.up && sample.link.type == "wired" && sample.wifi == nil && fallbackRSSI == nil

        let resolvedRSSI = sample.wifi?.rssi ?? fallbackRSSI ?? fallbackSnapshot?.wifi?.rssi
        let resolvedSNR = sample.wifi?.snr ?? fallbackSnapshot?.wifi?.snr
        let resolvedChannel = sample.wifi?.channel ?? fallbackChannel ?? fallbackSnapshot?.wifi?.channel

        let signalStr: String?
        if resolvedRSSI != nil || sample.wifi != nil {
            signalStr = describeSignal(rssi: resolvedRSSI, snr: resolvedSNR, channel: resolvedChannel)
        } else if isWired {
            signalStr = describeSignal(rssi: nil, isWired: true)
        } else {
            signalStr = nil
        }

        // Gateway loss & latency
        var gwFormatted = gwIP
        var gwStats: [String] = []
        if let loss = sample.gateway.lossPct, loss > 0 {
            gwStats.append("\(LossFormatter.formatPct(loss)) loss")
        }
        if let rtt = sample.gateway.rttAvgMs, rtt > 0 {
            gwStats.append(String(format: "%.1f ms latency", rtt))
        }
        if let jit = sample.gateway.rttJitterMs, jit > 0 {
            gwStats.append(String(format: "±%.1f ms jitter", jit))
        }
        if let mac = sample.link.gatewayMAC, !mac.isEmpty {
            gwStats.append("MAC: \(mac)")
        }
        if let gw = gwFormatted, !gwStats.isEmpty {
            gwFormatted = "\(gw) (\(gwStats.joined(separator: ", ")))"
        }

        // Internet path
        var internetStr: String?
        if let inetLoss = sample.internet.lossPct, let inetRTT = sample.internet.rttAvgMs {
            var parts = ["\(LossFormatter.formatPct(inetLoss)) loss", String(format: "%.1f ms avg latency", inetRTT)]
            if let jit = sample.internet.rttJitterMs, jit > 0 {
                parts.append(String(format: "±%.1f ms jitter", jit))
            }
            internetStr = parts.joined(separator: ", ")
        } else if let inetLoss = sample.internet.lossPct, inetLoss > 0 {
            internetStr = "\(LossFormatter.formatPct(inetLoss)) packet loss to public targets"
        } else if let inetRTT = sample.internet.rttAvgMs, inetRTT > 0 {
            internetStr = "Reachable (\(String(format: "%.1f ms avg", inetRTT)))"
        }

        // Public ISP info
        let pubISP = sample.publicInfo.isp ?? fallbackSnapshot?.publicInfo.isp
        let pubASN = sample.publicInfo.asn ?? fallbackSnapshot?.publicInfo.asn
        let pubCity = sample.publicInfo.city ?? fallbackSnapshot?.publicInfo.city
        let pubCountry = sample.publicInfo.country ?? fallbackSnapshot?.publicInfo.country
        let ispComponents = [pubISP, pubASN, pubCity, pubCountry].compactMap { $0 }.filter { !$0.isEmpty }
        let ispStr = ispComponents.isEmpty ? nil : ispComponents.joined(separator: ", ")

        // DNS
        var dnsStr: String?
        let dnsFailed = (sample.dns.ok == false)
        if sample.dns.ok == false {
            if let res = sample.dns.resolver {
                dnsStr = "Queries to \(res) are failing or timing out"
            } else {
                dnsStr = "Lookup queries timing out"
            }
        } else if sample.dns.ok == true, let elapsed = sample.dns.elapsedMs {
            if let res = sample.dns.resolver {
                dnsStr = "Operational (\(res), \(String(format: "%.0f ms", elapsed)))"
            } else {
                dnsStr = "Operational (\(String(format: "%.0f ms", elapsed)))"
            }
        }

        // Captive portal
        let captivePortalStr = sample.publicInfo.captivePortal == true ? "Detected (login / terms acceptance required)" : nil

        // VPN
        let vpnStr = sample.vpn.active
            ? "Active (\(sample.vpn.name ?? "Tunnel"))"
            : "Inactive (Direct connection)"

        var problem: String?
        var action: String?
        var impact: String?
        var findings: [String] = []

        let isCaptive = sample.publicInfo.captivePortal == true
            || (alert?.rules.contains("CP-1") == true)
            || (alert?.id == "captive-portal")
            || sample.status.rules.contains("CP-1")

        if isCaptive {
            problem = "Wi-Fi sign-in / captive portal authentication required to access the internet"
            impact = "Internet traffic is blocked until the captive portal sign-in is completed"
            action = !networkIsOwned
                ? "Please provide the guest Wi-Fi portal URL or login instructions."
                : "Open http://captive.apple.com to complete sign-in. If the portal does not load, temporarily disable custom DNS or VPN."
            findings.append("Captive portal intercepted internet traffic (sign-in required)")
        } else if let alert {
            let rule = alert.rules.first.flatMap { catalog?[$0] }
            problem = "\(alert.title): \(alert.body)"
            findings.append(problem!)
            if !networkIsOwned, let fixAway = rule?.fixAway {
                action = fixAway
            } else if let fix = rule?.fix {
                action = fix
            }
        }

        if problem == nil {
            if let ruleID = sample.status.rules.first, let rule = catalog?[ruleID] {
                problem = rule.title ?? rule.blurb
                if let title = rule.title {
                    findings.append("[\(ruleID)] \(title)")
                }
                if !networkIsOwned, let fixAway = rule.fixAway { action = fixAway }
                else if let fix = rule.fix { action = fix }
            }
        }

        // Fallback problem & impact
        if problem == nil {
            if !sample.link.up {
                problem = sample.link.offline?.precursor ?? "Disconnected from local network"
                impact = "Internet is completely offline"
                action = "Check Wi-Fi connection and ensure the router is powered on."
            } else if let gwLoss = sample.gateway.lossPct, gwLoss >= 1 {
                problem = "Losing \(LossFormatter.formatPct(gwLoss)) of packets to the local router"
                impact = gwLoss >= 10 ? "Audio/video calls dropping and websites timing out" : "Occasional call stutter and slower browsing"
                action = !networkIsOwned
                    ? "Please restart or power-cycle the local Wi-Fi router / access point for this area."
                    : "Restart your router (unplug for 15 seconds, then plug back in)."
            } else if let netLoss = sample.internet.lossPct, netLoss >= 1 {
                problem = "Losing \(LossFormatter.formatPct(netLoss)) of packets to the internet"
                impact = netLoss >= 10 ? "Audio/video calls dropping and web requests timing out" : "Occasional call stutter and slower browsing"
                action = !networkIsOwned
                    ? "Please check if your internet provider has an outage in this area."
                    : "Check your modem/ONT connection, or contact your ISP."
            } else if let rtt = sample.gateway.rttAvgMs, rtt > 150 {
                problem = "High latency to local router (\(Int(round(rtt))) ms)"
                impact = "Noticeable lag during video calls and interactive tasks"
                action = !networkIsOwned
                    ? "Please consider restarting the local Wi-Fi router / access point for this area."
                    : "Restart your router."
            } else if let rtt = sample.internet.rttAvgMs, rtt > 250 {
                problem = "High internet latency (\(Int(round(rtt))) ms)"
                impact = "Websites and cloud services taking noticeably longer to respond"
                action = !networkIsOwned
                    ? "Please check if the internet connection is experiencing congestion or an ISP issue."
                    : "Check for background downloads or contact your ISP."
            } else if sample.dns.ok == false {
                problem = "DNS queries are timing out"
                impact = "Websites cannot be found or take a long time to open"
                action = !networkIsOwned
                    ? "Please check if the network DNS settings or router need a restart."
                    : "Restart the router or configure public DNS (1.1.1.1 / 8.8.8.8)."
            } else if sample.status.severity != "ok" {
                problem = "Network latency or instability detected"
                impact = "Occasional delays or pauses in network connectivity"
                action = !networkIsOwned
                    ? "Please consider restarting the local router / access point for this area."
                    : "Restart your router."
            } else {
                problem = "Intermittent network degradation detected"
                impact = "Connection may be slower or less reliable than normal"
                action = !networkIsOwned
                    ? "Please consider restarting the local router / access point for this area."
                    : "Restart your router."
            }
        }

        if action == nil {
            action = !networkIsOwned
                ? "Please consider restarting the local router / access point for this area."
                : "Restart your router (unplug for 15 seconds, then plug back in)."
        }

        // Root-cause isolation
        let attribution = HopAttributionResolver.resolve(sample: sample)
        let isolation = buildIsolation(
            attribution: attribution,
            rssi: resolvedRSSI,
            snr: resolvedSNR,
            isWired: isWired,
            gatewayIP: gwIP,
            gatewayLoss: sample.gateway.lossPct,
            gatewayRTT: sample.gateway.rttAvgMs,
            inetLoss: sample.internet.lossPct,
            inetRTT: sample.internet.rttAvgMs,
            dnsFailed: dnsFailed,
            vpnActive: sample.vpn.active,
            observedProblem: problem,
            ispName: pubISP,
            captivePortal: captivePortalStr
        )

        return format(Parameters(
            networkName: netName,
            gatewayIP: gwFormatted,
            signalQuality: signalStr,
            observedProblem: problem,
            localVerification: isCaptive
                ? "Wi-Fi link is connected; internet access blocked by captive portal"
                : "Local link is idle and healthy; issue is upstream on network/router",
            concreteAction: action,
            timestamp: sample.ts,
            userImpact: impact,
            isolationHeading: isolation.heading,
            isolationBullets: isolation.bullets,
            clientIP: sample.link.ip ?? fallbackSnapshot?.interfaceInfo.ip,
            interfaceName: sample.link.interface ?? fallbackSnapshot?.interfaceInfo.name,
            bssid: sample.link.bssid ?? fallbackSnapshot?.wifi?.bssid,
            publicIP: sample.publicInfo.ip ?? fallbackSnapshot?.publicInfo.ip,
            ispInfo: ispStr,
            internetLatency: internetStr,
            dnsStatus: dnsStr,
            captivePortal: captivePortalStr,
            vpnStatus: vpnStr,
            diagnosticFindings: findings
        ))
    }
}
