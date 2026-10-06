import Foundation

/// What the ping readouts show when a filter rule has made one leg
/// unmeasurable. Pure, so `--verify` can exercise it; views only gather the
/// raw figures and the `EffectiveLoss.Filtering` and call in.
///
/// Which leg is filtered is decided by the CLI's rules (see `EffectiveLoss`),
/// never here, and nothing in this file is a threshold or a verdict.
enum PingReadout {

    /// True when the internet ping cell should read "TCP ok" instead of an
    /// RTT: the internet leg is filtered (ICMP-1), or the gateway is filtered
    /// (TCP-1) and no internet RTT came back to show. Under TCP-1 alone a
    /// measured internet RTT is real and is shown.
    static func internetShowsTCPOk(rtt: Double?, filtering: EffectiveLoss.Filtering) -> Bool {
        filtering.internetLeg || (filtering.gatewayLeg && rtt == nil)
    }

    /// The internet RTT a chart series plots for one sample, or `nil` (a gap)
    /// when that leg is filtered. TCP-1 alone leaves the internet RTT intact.
    static func internetSeriesValue(for sample: MonitorSample) -> Double? {
        EffectiveLoss.filtering(sample: sample).internetLeg ? nil : sample.internet.rttAvgMs
    }

    /// The menu-bar latency string. Prefers the internet RTT, falls back to
    /// the gateway RTT, and never trusts a figure from a filtered leg.
    /// "TCP ok" when a filter left nothing measurable to show.
    static func menuBarPing(internetRtt: Double?, gatewayRtt: Double?,
                            filtering: EffectiveLoss.Filtering) -> String? {
        let inet = filtering.internetLeg ? nil : internetRtt
        let gw = filtering.gatewayLeg ? nil : gatewayRtt
        if let rtt = inet ?? gw, rtt >= 0 { return "\(Int(round(rtt)))ms" }
        return filtering.any ? "TCP ok" : nil
    }
}
