import Foundation

/// The one packet-loss figure the suitability tiles and the headline agree on.
///
/// Pure and free of any coordinator state so `--verify` can exercise it; the
/// coordinator's `effectiveLoss` only gathers the raw figures and calls in.
///
/// Which figure is unmeasurable is decided by the CLI's rules, never here:
/// - `status.icmp_filtered` / `TCP-1` mean the **gateway** declines to answer
///   pings, so the gateway loss figure says nothing about the link.
/// - `ICMP-1` means pings to the **public internet** are dropped wholesale, so
///   the internet loss figure says nothing about the link.
/// A filtered leg is excluded, never read as 0 and never read as its raw value.
enum EffectiveLoss {

    /// The two ping legs a filter rule can make unmeasurable.
    enum Leg: Equatable, Sendable { case gateway, internet }

    struct Filtering: Equatable, Sendable {
        var gatewayLeg: Bool = false
        var internetLeg: Bool = false

        static let none = Filtering()

        var any: Bool { gatewayLeg || internetLeg }
        var both: Bool { gatewayLeg && internetLeg }

        /// True when ping figures for `leg` say nothing about the link.
        func filters(_ leg: Leg) -> Bool {
            switch leg {
            case .gateway: return gatewayLeg
            case .internet: return internetLeg
            }
        }
    }

    /// Which loss legs the CLI says cannot be measured by ping.
    /// - Parameters:
    ///   - icmpFilteredFlag: the monitor sample's `status.icmp_filtered`.
    ///   - ruleIDs: every rule ID in view (the live sample's `status.rules`,
    ///     a run's diagnosis rules, or both).
    static func filtering(icmpFilteredFlag: Bool, ruleIDs: [String]) -> Filtering {
        Filtering(
            gatewayLeg: icmpFilteredFlag || ruleIDs.contains("TCP-1"),
            internetLeg: ruleIDs.contains("ICMP-1")
        )
    }

    /// Convenience for the usual live-sample case.
    static func filtering(sample: MonitorSample?, extraRuleIDs: [String] = []) -> Filtering {
        filtering(
            icmpFilteredFlag: sample?.status.icmpFiltered == true,
            ruleIDs: (sample?.status.rules ?? []) + extraRuleIDs
        )
    }

    /// Unified effective packet loss across the internet and gateway probes,
    /// or `nil` when no usable figure exists (not yet measured, or every leg
    /// that was measured is one a filter makes meaningless).
    static func compute(
        internetLoss: Double?,
        gatewayLoss: Double?,
        filtering: Filtering,
        hasRecentRoam: Bool
    ) -> Double? {
        let inetLoss: Double? = filtering.internetLeg ? nil : internetLoss
        let gwLoss: Double? = filtering.gatewayLeg ? nil : gatewayLoss

        var candidateGW = gwLoss
        if hasRecentRoam, let gw = candidateGW, gw < 10.0 {
            // Handover blip: suppress attributing to persistent connection loss if internet is intact
            candidateGW = inetLoss ?? 0.0
        }

        if let inetLoss, let candidateGW {
            // Downstream validation: Packets to the internet must traverse the local gateway.
            // If internet through-traffic is clean (loss < 2%), any isolated router ping loss
            // is harmless ICMP control-plane rate-limiting by the router's CPU, NOT physical
            // link loss. Only propagate gateway loss when internet also shows loss or is unmeasured.
            if inetLoss < 2.0 && candidateGW > inetLoss {
                return inetLoss
            }
            return max(inetLoss, candidateGW)
        }
        return inetLoss ?? candidateGW
    }
}
