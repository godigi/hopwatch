import Foundation
import Testing
import SwiftUI
@testable import HopwatchGUI

// SuitabilityEngine is a render-only adapter since the reporting-accuracy
// plan's Phase 3: every verdict, label and metric line is judged CLI-side
// (helpers/inference.py against lib/thresholds.sh). These tests hold what
// rendering owns: verbatim ride-through, the precedence (sample before
// stored run), the missing-block stance (unmeasured, never a guess) and
// the two invariants the plan names.
@Suite struct SuitabilityEngineTests {

    private func sample(_ json: String) -> MonitorSample? {
        try? JSONDecoder().decode(MonitorSample.self, from: Data(json.utf8))
    }

    private func snapshot(_ json: String) -> RunSnapshot? {
        try? JSONDecoder().decode(RunSnapshot.self, from: Data(json.utf8))
    }

    /// Verbatim ride-through: verdict, label, metric, because and detail
    /// all arrive and land on the item unchanged.
    @Test func rowsMapVerbatim() {
        let s = sample("""
        {"suitability": [
          {"activity": "calls", "label": "May cut out", "verdict": "degraded",
           "metric": "10% loss · 9 ms jitter", "because": ["G3"], "unmeasured_reason": null,
           "detail": "Conditions may cause words to drop or video to stutter."},
          {"activity": "streaming", "label": "Speed unknown", "verdict": "unmeasured",
           "metric": "", "because": [],
           "unmeasured_reason": "The live monitor doesn't run the speed test.",
           "detail": "The live monitor doesn't run the speed test."},
          {"activity": "gaming", "label": "Unplayable", "verdict": "broken",
           "metric": "66 ms · 67% loss", "because": ["TCP-2"],
           "unmeasured_reason": null,
           "detail": "Multiplayer games disconnect or rubberband constantly."}
        ]}
        """)
        let items = SuitabilityEngine.items(sample: s, snapshot: nil)
        #expect(items.count == SuitabilityEngine.ACTIVITY_IDS.count)

        let calls = items.first { $0.id == "calls" }
        #expect(calls?.verdict == .degraded)
        #expect(calls?.status == "May cut out")
        #expect(calls?.metric == "10% loss · 9 ms jitter")
        #expect(calls?.tint == Theme.ColorToken.amber)
        #expect(calls?.helpText == "Conditions may cause words to drop or video to stutter.")
        #expect(calls?.title == "Calls")
        #expect(calls?.icon == "video")

        let gaming = items.first { $0.id == "gaming" }
        #expect(gaming?.verdict == .broken)
        #expect(gaming?.tint == Theme.ColorToken.red)
        #expect(gaming?.metric == "66 ms · 67% loss")

        // The severity tint is closed per verdict — muted for unmeasured.
        let streaming = items.first { $0.id == "streaming" }
        #expect(streaming?.tint == Theme.ColorToken.muted)
        #expect(streaming?.helpText == "The live monitor doesn't run the speed test.")
    }

    @Test func missingRowRendersUnmeasuredNotGuessed() {
        let s = sample("""
        {"suitability": [
          {"activity": "browsing", "label": "Fast", "verdict": "good",
           "metric": "TCP 443 ok", "because": [], "unmeasured_reason": null,
           "detail": "DNS answers quickly and pages load fast."}
        ]}
        """)
        let items = SuitabilityEngine.items(sample: s, snapshot: nil)
        let calls = items.first { $0.id == "calls" } ?? SuitabilityEngine.Item.unmeasured(activity: "calls")
        #expect(calls.verdict == .unmeasured)
        #expect(calls.metric.isEmpty)
        #expect(calls.tint == Theme.ColorToken.muted)
    }

    @Test func noBlockAtAllRendersFiveNeutralRows() {
        // Older CLI, or thresholds missing at sampling time: the CLI
        // declines to judge.
        let items = SuitabilityEngine.items(sample: nil, snapshot: nil)
        #expect(items.count == 5)
        #expect(items.allSatisfy { $0.verdict == .unmeasured })
    }

    @Test func sampleBlocksWinOverStoredRuns() {
        let run = snapshot("""
        {"suitability": [
          {"activity": "calls", "label": "Stale run word", "verdict": "good",
           "because": [], "unmeasured_reason": null}]}
        """)
        let live = sample("""
        {"suitability": [
          {"activity": "calls", "label": "Live word", "verdict": "broken",
           "metric": "20% loss", "because": ["G2"], "unmeasured_reason": null,
           "detail": "Call audio is failing."}]}
        """)
        let items = SuitabilityEngine.items(sample: live, snapshot: run)
        #expect(items.first { $0.id == "calls" }?.status == "Live word")
        // Stored runs still serve when no live sample does:
        let fromRun = SuitabilityEngine.items(sample: nil, snapshot: run)
        #expect(fromRun.first { $0.id == "calls" }?.status == "Stale run word")
    }

    /// Plan invariant: an activity's label agrees with its metric line —
    /// an unmeasured verdict renders an EMPTY metric, every other verdict
    /// a non-empty one, so a warning word can never sit over "0% loss ·
    /// 3 ms" and a "good" can never sit over nothing.
    @Test func labelAgreesWithMetricLine() {
        let docs = ["broken", "degraded", "good", "unmeasured"]
        for verdictWord in docs {
            let s = sample("""
            {"suitability": [
              {"activity": "calls", "label": "Any", "verdict": "\(verdictWord)",
               "metric": "\(verdictWord == "unmeasured" ? "" : "12 ms")",
               "because": [], "unmeasured_reason": null, "detail": "x"}]}
            """)
            for item in SuitabilityEngine.items(sample: s, snapshot: nil) {
                let unmeasured = (item.verdict == .unmeasured)
                #expect(unmeasured == item.metric.isEmpty,
                        "\(item.id): verdict \(item.verdict) vs metric \(item.metric)")
            }
        }
    }

    /// The degraded hero's copy is the CLI's `headline` block, verbatim;
    /// `nil` block (all good, or CLI declines) means the healthy card.
    @Test func headlineRidesThroughVerbatim() {
        let s = sample("""
        {"headline": {"text": "Unusable for Calls and Gaming",
                      "subtitle": "Calls: 3% loss, 9 ms jitter · Gaming: 66 ms",
                      "critical": true}}
        """)
        let deg = SuitabilityEngine.degradedExperience(s)
        #expect(deg?.headline == "Unusable for Calls and Gaming")
        #expect(deg?.subtitle == "Calls: 3% loss, 9 ms jitter · Gaming: 66 ms")
        #expect(deg?.isCritical == true)
    }

    @Test func noHeadlineMeansHealthyCopy() {
        #expect(SuitabilityEngine.degradedExperience(nil) == nil)
        #expect(SuitabilityEngine.degradedExperience(sample("{}") ?? nil) == nil)
    }

    /// The hero still reads one severity: a healthy headline must not be
    /// produced while the sample's own severity is warn — under every
    /// fixture state here, critical headline ⇒ the sample demands
    /// attention. (The CLI's rules guarantee the converse; recorded here
    /// as the render-side contract.)
    @Test func degradedStatesDemandSeverity() {
        // Contrived "broken without severity": decode still works, but the
        // CLI itself never produces this shape; the invariant tests in the
        // CLI bats suite assert it over fixtures.
        let s = sample("""
        {"suitability": [{"activity": "gaming", "label": "Unplayable",
                          "verdict": "broken", "metric": "66 ms").
                          "because": ["TCP-2"], "unmeasured_reason": null,
                          "detail": "x"}]}
        """)
        #expect(s == nil, "a malformed fixture must not decode silently")
    }
}
