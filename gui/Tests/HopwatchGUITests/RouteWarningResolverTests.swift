import Foundation
import Testing
@testable import HopwatchGUI

// RouteWarningResolver is a passthrough since the reporting-accuracy
// plan's Phase 3: the flags and reasons are the CLI's (helpers/inference.py
// against lib/thresholds.sh). These tests hold only what rendering owns:
// verdicts ride through verbatim, the absence of a `hops` block renders
// neutral rather than re-deriving anything, and the culprit order is
// mac → router → internet.
@Suite struct RouteWarningResolverTests {

    private func sample(_ json: String) -> MonitorSample? {
        try? JSONDecoder().decode(MonitorSample.self, from: Data(json.utf8))
    }

    @Test func hopFlagsAndReasonsRideThroughVerbatim() {
        let result = RouteWarningResolver.resolve(sample("""
        {"hops": {
           "mac": {"good": false, "laggy": true, "detail": "Good (laggy)"},
           "router": {"warn": true, "detail": "40 ms latency to router",
                      "value": "40 ms"},
           "internet": {"warn": false, "detail": "0% packet loss",
                        "value": "18 ms",
                        "jitter_warn": false, "jitter_note": "Stable response times"}}}
        """) ?? nil)
        #expect(result.macStatusGood == false)
        #expect(result.isWifiLaggy == true)
        #expect(result.macDetail == "Good (laggy)")
        #expect(result.routerWarn == true)
        #expect(result.routerDetail == "40 ms latency to router")
        #expect(result.internetWarn == false)
        #expect(result.internetDetail == "0% packet loss")
        #expect(result.culpritHop == "wifi")
    }

    @Test func culpritHopsInBlameOrder() {
        // Router and internet warned, mac fine: router wins the blame row.
        let result = RouteWarningResolver.resolve(sample("""
        {"hops": {"mac": {"good": true, "laggy": false, "detail": "Good"},
                  "router": {"warn": true, "detail": "±31 ms jitter", "value": "40 ms"},
                  "internet": {"warn": true, "detail": "Unreachable", "value": ""}}}
        """) ?? nil)
        #expect(result.culpritHop == "router")

        // Internet alone: its own blame.
        let internetOnly = RouteWarningResolver.resolve(sample("""
        {"hops": {"mac": {"good": true, "laggy": false, "detail": "Good"},
                  "router": {"warn": false, "detail": "", "value": "3 ms"},
                  "internet": {"warn": true, "detail": "266 ms latency",
                               "value": "266 ms"}}}
        """) ?? nil)
        #expect(internetOnly.culpritHop == "internet")

        // Nothing wrong: no culprit.
        let clean = RouteWarningResolver.resolve(sample("""
        {"hops": {"mac": {"good": true, "laggy": false, "detail": "Excellent"},
                  "router": {"warn": false, "detail": "", "value": "3 ms"},
                  "internet": {"warn": false, "detail": "0% packet loss", "value": "60 ms"}}}
        """) ?? nil)
        #expect(clean.culpritHop == nil)
    }

    @Test func jitterVerdictDecodeRideThrough() {
        let result = RouteWarningResolver.resolve(sample("""
        {"hops": {"internet": {"warn": false, "detail": "0% packet loss",
                               "jitter_warn": true,
                               "jitter_note": "Uneven response times"}}}
        """) ?? nil)
        #expect(result.internetDetail == "0% packet loss")
        // The note is consumed via hops.internet directly (ConnectionRouteView
        // reads the sample's own sub-verdict); the resolver only renders hops.
        let note = sample("""
        {"hops": {"internet": {"jitter_warn": true,
                               "jitter_note": "Uneven response times"}}}
        """)?.hops?.internet
        #expect(note?.jitterWarn == true)
        #expect(note?.jitterNote == "Uneven response times")
    }

    @Test func noHopsBlockRendersNeutralNotJudged() {
        // An older CLI (no `hops` key): nothing judged. The result must be
        // all-clear-empty — flags false, no culprit — not a locally
        // re-derived verdict.
        let result = RouteWarningResolver.resolve(sample("{}") ?? nil)
        #expect(result.isWifiLaggy == false)
        #expect(result.macStatusGood == true)
        #expect(result.routerWarn == false)
        #expect(result.internetWarn == false)
        #expect(result.culpritHop == nil)
        #expect(result.macDetail == nil)
        #expect(result.routerDetail == nil)
        #expect(result.internetDetail == nil)
    }

    @Test func nilSampleRendersNeutral() {
        let result = RouteWarningResolver.resolve(nil)
        #expect(result.culpritHop == nil)
        #expect(result.macStatusGood == true)
    }
}
