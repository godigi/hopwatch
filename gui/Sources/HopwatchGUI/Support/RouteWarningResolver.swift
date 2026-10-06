import SwiftUI
import Foundation

/// Renders the CLI's hop judgements for the 3-hop connection route:
/// Hop 1: This Mac (Local Wi-Fi link)
/// Hop 2: Router (Local Gateway)
/// Hop 3: Internet (Broadband WAN & Upstream ISP)
///
/// Since the reporting-accuracy plan's Phase 3 it decides nothing: every
/// warning flag and reason sentence is judged in helpers/inference.py
/// against lib/thresholds.sh (the same cutoffs the CLI's own rules fire
/// on) and carried by the sample's `hops` block. This file used to keep
/// its own private cutoffs over raw figures — 20% here, 35 ms there,
/// all six a drift risk against the CLI's tables and several provably at
/// odds with them (its 3% internet-loss warning sat under the CLI's 10%
/// warn band, coloring a hop the rules had not named). What remains is
/// the passthrough plus one composition rule of presentation's own: the
/// order of blame (Wi-Fi before router before internet).
///
/// When the `hops` block is absent — an older CLI, or thresholds missing
/// at sampling time — the sample says nothing and every flag renders as
/// all-clear-with-detail-empty rather than being re-derived here.
enum RouteWarningResolver {

    struct Result: Equatable, Sendable {
        let isWifiLaggy: Bool
        let macStatusGood: Bool
        let macDetail: String?
        let routerWarn: Bool
        let routerDetail: String?
        let internetWarn: Bool
        let internetDetail: String?
        /// The hop to blame for a degraded experience, in fix-it order:
        /// wifi → router → internet. `nil` when nothing is wrong.
        let culpritHop: String?

        init(
            isWifiLaggy: Bool = false,
            macStatusGood: Bool = true,
            macDetail: String? = nil,
            routerWarn: Bool = false,
            routerDetail: String? = nil,
            internetWarn: Bool = false,
            internetDetail: String? = nil,
            culpritHop: String? = nil
        ) {
            self.isWifiLaggy = isWifiLaggy
            self.macStatusGood = macStatusGood
            self.macDetail = macDetail
            self.routerWarn = routerWarn
            self.routerDetail = routerDetail
            self.internetWarn = internetWarn
            self.internetDetail = internetDetail
            self.culpritHop = culpritHop
        }
    }

    /// The sample's hop judgements, rendered. A `nil` sample renders the
    /// neutral result.
    static func resolve(_ sample: MonitorSample?) -> Result {
        guard let hops = sample?.hops else { return Result() }

        let macGood = hops.mac.good
        let macLaggy = hops.mac.laggy
        let routerWarn = hops.router.warn
        let internetWarn = hops.internet.warn

        let culprit: String?
        if !macGood || macLaggy {
            culprit = "wifi"
        } else if routerWarn {
            culprit = "router"
        } else if internetWarn {
            culprit = "internet"
        } else {
            culprit = nil
        }

        return Result(
            isWifiLaggy: macLaggy,
            macStatusGood: macGood,
            macDetail: hops.mac.detail.isEmpty ? nil : hops.mac.detail,
            routerWarn: routerWarn,
            routerDetail: hops.router.detail.isEmpty ? nil : hops.router.detail,
            internetWarn: internetWarn,
            internetDetail: hops.internet.detail.isEmpty ? nil : hops.internet.detail,
            culpritHop: culprit
        )
    }
}
