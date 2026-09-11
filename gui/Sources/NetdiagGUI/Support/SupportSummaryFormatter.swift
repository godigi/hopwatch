import Foundation

/// Formats a clean, plain-text diagnostic summary suitable for sending to non-technical
/// staff, hotel front desks, Airbnb hosts, or network support.
enum SupportSummaryFormatter {

    struct Parameters: Sendable {
        var networkName: String?
        var gatewayIP: String?
        var signalQuality: String?
        var observedProblem: String?
        var localVerification: String?
        var concreteAction: String?

        init(
            networkName: String? = nil,
            gatewayIP: String? = nil,
            signalQuality: String? = nil,
            observedProblem: String? = nil,
            localVerification: String? = nil,
            concreteAction: String? = nil
        ) {
            self.networkName = networkName
            self.gatewayIP = gatewayIP
            self.signalQuality = signalQuality
            self.observedProblem = observedProblem
            self.localVerification = localVerification
            self.concreteAction = concreteAction
        }
    }

    /// Formats the summary into a clean, human-readable text message.
    static func format(_ params: Parameters) -> String {
        var lines: [String] = []
        lines.append("Network Diagnostic Summary for Support / Front Desk / Host")
        lines.append(String(repeating: "=", count: 58))

        let net = params.networkName ?? "Unknown Network"
        lines.append("Network Name / SSID: \(net)")

        if let gw = params.gatewayIP, !gw.isEmpty {
            lines.append("Local Gateway IP: \(gw)")
        } else {
            lines.append("Local Gateway IP: Not detected")
        }

        if let sig = params.signalQuality, !sig.isEmpty {
            lines.append("Signal Strength & Quality: \(sig)")
        } else {
            lines.append("Signal Strength & Quality: Wi-Fi signal not available / Wired")
        }

        let prob = params.observedProblem ?? "Network degradation detected"
        lines.append("Observed Problem: \(prob)")

        let verification = params.localVerification ?? "Laptop link is idle; issue is on the network/router side"
        lines.append("Local verification: \(verification)")

        let action = params.concreteAction ?? "Please restart floor access point / router"
        lines.append("Concrete action: \(action)")

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

        var sigParts: [String] = []
        if let wifi = snapshot.wifi {
            if let rssi = wifi.rssi { sigParts.append("\(rssi) dBm") }
            if let snr = wifi.snr { sigParts.append("SNR \(snr) dB") }
            if let ch = wifi.channel { sigParts.append("channel \(ch)") }
        } else if snapshot.interfaceInfo.type == "wired" {
            sigParts.append("Wired Ethernet link")
        }
        let signalStr = sigParts.isEmpty ? nil : sigParts.joined(separator: ", ")

        var problem: String?
        var action: String?

        let worst = snapshot.diagnosis.first(where: { $0.severity == "critical" })
            ?? snapshot.diagnosis.first(where: { $0.severity == "warn" })
            ?? snapshot.diagnosis.first

        if let worst {
            let rule = worst.rule.flatMap { catalog?[$0] }
            if !networkIsOwned, let fixAway = rule?.fixAway {
                problem = "\(worst.summary) (\(fixAway))"
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

        if action == nil {
            action = "Please restart floor access point / router"
        }

        return format(Parameters(
            networkName: netName,
            gatewayIP: gwIP,
            signalQuality: signalStr,
            observedProblem: problem,
            localVerification: "Laptop link is idle; issue is on the network/router side",
            concreteAction: action
        ))
    }

    /// Builds a support summary from a live `MonitorSample`.
    static func format(
        sample: MonitorSample,
        alert: StageResolver.AlertSnapshot? = nil,
        catalog: RulesCatalog? = nil,
        networkIsOwned: Bool = false
    ) -> String {
        let netName = sample.link.ssid ?? sample.network.label ?? sample.network.id ?? "Unknown Network"
        let gwIP = sample.link.gateway

        var sigParts: [String] = []
        if let wifi = sample.wifi {
            if let rssi = wifi.rssi { sigParts.append("\(rssi) dBm") }
            if let snr = wifi.snr { sigParts.append("SNR \(snr) dB") }
        } else if sample.link.type == "wired" {
            sigParts.append("Wired Ethernet link")
        }
        let signalStr = sigParts.isEmpty ? nil : sigParts.joined(separator: ", ")

        var problem: String?
        var action: String?

        if let alert {
            let rule = alert.rules.first.flatMap { catalog?[$0] }
            if !networkIsOwned, let fixAway = rule?.fixAway {
                problem = "\(alert.title): \(alert.body) (\(fixAway))"
                action = fixAway
            } else if let fix = rule?.fix {
                problem = "\(alert.title): \(alert.body)"
                action = fix
            } else {
                problem = "\(alert.title): \(alert.body)"
            }
        }

        if action == nil {
            action = "Please restart floor access point / router"
        }

        return format(Parameters(
            networkName: netName,
            gatewayIP: gwIP,
            signalQuality: signalStr,
            observedProblem: problem,
            localVerification: "Laptop link is idle; issue is on the network/router side",
            concreteAction: action
        ))
    }
}
