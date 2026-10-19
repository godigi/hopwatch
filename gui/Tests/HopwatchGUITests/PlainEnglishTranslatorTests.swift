import Foundation
import Testing
@testable import HopwatchGUI

@Suite struct PlainEnglishTranslatorTests {

    // MARK: - Required Core Rules

    @Test func requiredCoreRulesProduceFriendlyEL5Language() {
        // Test all rules explicitly mentioned in requirements
        let testCases: [(ruleId: String, expectedTitle: String)] = [
            ("WIFI-1", "Weak Wi-Fi Signal"),
            ("WIFI-2", "Wi-Fi Interference / Noisy Signal"),
            ("GW-1", "Router Communication Problem"),
            ("INET-1", "Internet Provider Outage"),
            ("L1", "Severe Internet Packet Loss"),
            ("P1", "Internet Provider Outage"),
            ("BLOAT-1", "Network Overload (Bufferbloat)"),
            ("BLOAT-2", "Internet Provider Bufferbloat"),
            ("DNS-1", "Sluggish Website Lookup (DNS)"),
            ("DNS-2", "Website Lookup Failure (DNS Down)"),
            ("MTU-1", "Packet Size Limit Issue (MTU)"),
            ("ARP-1", "Local Device Conflict (ARP / IP Conflict)"),
            ("VPN-1", "VPN Rerouting Traffic"),
            ("DESYNC-1", "System Clock Out of Sync"),
        ]

        for testCase in testCases {
            let explanation = PlainEnglishTranslator.translate(ruleId: testCase.ruleId)
            #expect(explanation.title == testCase.expectedTitle, "Rule \(testCase.ruleId) unexpected title: \(explanation.title)")
            #expect(!explanation.explanation.isEmpty, "Rule \(testCase.ruleId) has empty explanation")
            #expect(!explanation.action.isEmpty, "Rule \(testCase.ruleId) has empty action")

            // Test component helper methods
            #expect(PlainEnglishTranslator.plainTitle(for: testCase.ruleId) == explanation.title)
            #expect(PlainEnglishTranslator.plainExplanation(for: testCase.ruleId) == explanation.explanation)
            #expect(PlainEnglishTranslator.whatYouCanDo(for: testCase.ruleId) == explanation.action)

            // Test property aliases on PlainExplanation
            #expect(explanation.plainTitle == explanation.title)
            #expect(explanation.plainExplanation == explanation.explanation)
            #expect(explanation.whatYouCanDo == explanation.action)
        }
    }

    @Test func wifiRuleExactVerbiageMatchesPromptSpecification() {
        let result = PlainEnglishTranslator.translate(ruleId: "WIFI-1")
        #expect(result.title == "Weak Wi-Fi Signal")
        #expect(result.explanation == "Your Mac is struggling to receive radio waves from your router. You may be too far away, behind concrete or brick walls, or on a crowded frequency.")
        #expect(result.action == "Move closer to your router, switch to 5 GHz or 6 GHz Wi-Fi, or connect with an Ethernet cable.")
    }

    @Test func dnsRuleTranslations() {
        let d1 = PlainEnglishTranslator.translate(ruleId: "D1")
        #expect(d1.title == "Flaky Website Lookup (DNS)")
        #expect(d1.explanation.contains("intermittently"))

        let d2 = PlainEnglishTranslator.translate(ruleId: "D2")
        #expect(d2.title == "Website Lookup Failure (DNS Down)")

        let d3 = PlainEnglishTranslator.translate(ruleId: "D3")
        #expect(d3.title == "Sluggish Website Lookup (DNS)")
    }

    // MARK: - Normalization and Case-Insensitivity

    @Test func ruleIdNormalizationHandlesVariations() {
        let variations = [
            "wifi-1",
            "WIFI-1",
            "  wifi-1  ",
            "[WIFI-1]",
            "RULE WIFI-1",
            "W1",
            "w1",
            "[W1]",
        ]

        for id in variations {
            let res = PlainEnglishTranslator.translate(ruleId: id)
            #expect(res.title == "Weak Wi-Fi Signal", "Failed for variation: \(id)")
            #expect(PlainEnglishTranslator.plainTitle(for: id) == "Weak Wi-Fi Signal")
        }

        #expect(PlainEnglishTranslator.plainTitle(for: "bloat-1") == "Network Overload (Bufferbloat)")
        #expect(PlainEnglishTranslator.plainTitle(for: "b1") == "Network Overload (Bufferbloat)")
        #expect(PlainEnglishTranslator.plainTitle(for: "gw-1") == "Router Communication Problem")
        #expect(PlainEnglishTranslator.plainTitle(for: "inet-1") == "Internet Provider Outage")
        #expect(PlainEnglishTranslator.plainTitle(for: "dns-1") == "Sluggish Website Lookup (DNS)")
        #expect(PlainEnglishTranslator.plainTitle(for: "mtu-1") == "Packet Size Limit Issue (MTU)")
        #expect(PlainEnglishTranslator.plainTitle(for: "arp-1") == "Local Device Conflict (ARP / IP Conflict)")
    }

    // MARK: - RulesCatalog Comprehensive Coverage

    @Test func rulesCatalogRulesTranslateCleanly() {
        let catalogRules = [
            "N1", "N1B", "N1C", "W3", "W4", "W5", "W6",
            "AWDL-1", "WS-1", "WF-1", "WJ-1", "WD-1", "WI-1", "DQ-1",
            "G1", "G2", "G3", "P2", "L2", "ICMP-1", "TCP-1",
            "D3", "D4", "D5", "D6", "SOCK-1", "CONN-1", "HOG-1",
            "EDNS-1", "MT1", "V6-1", "V6-2", "V6-3", "VPN-2",
            "PX-1", "FW-1", "BR-1", "PR-1", "SP-1", "MET-1",
            "DI-1", "DI-2", "LAN-1", "ETH-1", "ETH-2",
            "DH-1", "DH-2", "DH-3", "WAN-1", "WAN-1B", "NAT-1", "NAT-1B",
            "BL-1", "CP-1", "ND-1", "AV-1", "AV-2", "TR-1",
        ]

        for ruleId in catalogRules {
            let result = PlainEnglishTranslator.translate(ruleId: ruleId)
            #expect(!result.title.isEmpty, "Rule \(ruleId) has empty title")
            #expect(!result.explanation.isEmpty, "Rule \(ruleId) has empty explanation")
            #expect(!result.action.isEmpty, "Rule \(ruleId) has empty action")
            #expect(!result.title.contains("(\(ruleId))"), "Rule \(ruleId) was not curated: \(result.title)")
        }
    }

    @Test func translatesRulesCatalogRuleObject() {
        // Known rule
        let knownRule = RulesCatalog.Rule(id: "WIFI-1")
        let knownResult = PlainEnglishTranslator.translate(rule: knownRule)
        #expect(knownResult.title == "Weak Wi-Fi Signal")

        // Unknown rule with custom catalog fields
        let customRule = RulesCatalog.Rule(
            id: "CUSTOM-100",
            title: "Unusual Packet Burst",
            blurb: "Your network is sending unexpected bursts of traffic.",
            fix: "Check your local networked smart devices."
        )
        let customResult = PlainEnglishTranslator.translate(rule: customRule)
        #expect(customResult.title == "Unusual Packet Burst")
        #expect(customResult.explanation == "Your network is sending unexpected bursts of traffic.")
        #expect(customResult.action == "Check your local networked smart devices.")

        // Unknown bare rule
        let bareRule = RulesCatalog.Rule(id: "BARE-200")
        let bareResult = PlainEnglishTranslator.translate(rule: bareRule)
        #expect(bareResult.title == "Network Finding (BARE-200)")
        #expect(bareResult.explanation.contains("BARE-200"))
        #expect(!bareResult.action.isEmpty)
    }

    // MARK: - Finding Summary Heuristics

    @Test func translatesSummaryHeuristicsWhenRuleIdIsNilOrUnknown() {
        // Bufferbloat summary
        let bb = PlainEnglishTranslator.translate(summary: "Excessive latency under upload saturation (+160ms)")
        #expect(bb.title == "Network Overload (Bufferbloat)")

        // Wi-Fi signal summary
        let wifi = PlainEnglishTranslator.translate(summary: "Weak Wi-Fi signal detected on en0 (-85 dBm)")
        #expect(wifi.title == "Weak Wi-Fi Signal")

        // Captive portal summary
        let portal = PlainEnglishTranslator.translate(summary: "Captive portal sign-in page detected")
        #expect(portal.title == "Captive Portal Sign-In Required")

        // DNS summary
        let dns = PlainEnglishTranslator.translate(summary: "DNS lookup server unresponsive")
        #expect(dns.title == "Website Lookup Failure (DNS Down)")

        let slowDns = PlainEnglishTranslator.translate(summary: "Slow domain name lookup latency (180ms)")
        #expect(slowDns.title == "Sluggish Website Lookup (DNS)")

        // Gateway loss
        let gw = PlainEnglishTranslator.translate(summary: "30% packet loss to gateway router")
        #expect(gw.title == "Router Communication Problem")

        // Packet loss
        let loss = PlainEnglishTranslator.translate(summary: "Severe packet loss on WAN interface")
        #expect(loss.title == "Severe Internet Packet Loss")

        // Clock drift
        let clock = PlainEnglishTranslator.translate(summary: "System clock drift exceeds 4.5 seconds")
        #expect(clock.title == "System Clock Out of Sync")

        // VPN
        let vpn = PlainEnglishTranslator.translate(summary: "VPN route active on utun4")
        #expect(vpn.title == "VPN Rerouting Traffic")

        // ARP / IP conflict
        let arp = PlainEnglishTranslator.translate(summary: "Duplicate IP address conflict reported on ARP table")
        #expect(arp.title == "Local Device Conflict (ARP / IP Conflict)")

        // MTU
        let mtu = PlainEnglishTranslator.translate(summary: "Path MTU restricted to 1380 bytes")
        #expect(mtu.title == "Packet Size Limit Issue (MTU)")

        // Ethernet
        let eth = PlainEnglishTranslator.translate(summary: "Ethernet negotiated at half duplex")
        #expect(eth.title == "Ethernet Stuck on Half-Duplex")
    }

    // MARK: - Fallbacks and Edge Cases

    @Test func handlesUnknownRulesAndEmptyInputsSensibly() {
        // Unknown rule with custom summary
        let unknownWithSummary = PlainEnglishTranslator.translate(
            ruleId: "STRANGE-999",
            summary: "Third-party IoT sensor emitting malformed frames"
        )
        #expect(unknownWithSummary.title == "Third-party IoT sensor emitting malformed frames")
        #expect(unknownWithSummary.explanation.contains("Third-party IoT sensor emitting malformed frames"))
        #expect(!unknownWithSummary.action.isEmpty)

        // Unknown rule without summary
        let unknownNoSummary = PlainEnglishTranslator.translate(ruleId: "STRANGE-999", summary: "")
        #expect(unknownNoSummary.title == "Network Issue Detected (STRANGE-999)")
        #expect(unknownNoSummary.explanation.contains("STRANGE-999"))
        #expect(!unknownNoSummary.action.isEmpty)

        // Nil rule ID and empty summary
        let allEmpty = PlainEnglishTranslator.translate(ruleId: nil, summary: "")
        #expect(allEmpty.title == "Network Issue Detected")
        #expect(!allEmpty.explanation.isEmpty)
        #expect(!allEmpty.action.isEmpty)

        // Empty rule ID and empty summary
        let emptyStrings = PlainEnglishTranslator.translate(ruleId: "   ", summary: "   ")
        #expect(emptyStrings.title == "Network Issue Detected")
        #expect(!emptyStrings.explanation.isEmpty)
        #expect(!emptyStrings.action.isEmpty)

        // Extremely long summary truncates title gracefully
        let longSummary = String(repeating: "Extremely long diagnostic explanation string without spaces ", count: 5)
        let longResult = PlainEnglishTranslator.translate(summary: longSummary)
        #expect(longResult.title == "Network Issue Detected")
        #expect(longResult.explanation.contains("Extremely long"))
    }

    @Test func plainExplanationValueSemanticsAndCodable() throws {
        let item1 = PlainExplanation(title: "Title A", explanation: "Expl A", action: "Act A")
        let item2 = PlainExplanation(title: "Title A", explanation: "Expl A", action: "Act A")
        let item3 = PlainExplanation(title: "Title B", explanation: "Expl B", action: "Act B")

        #expect(item1 == item2)
        #expect(item1 != item3)

        // Hashable
        let set: Set<PlainExplanation> = [item1, item2, item3]
        #expect(set.count == 2)

        // Codable round-trip
        let encoder = JSONEncoder()
        let data = try encoder.encode(item1)
        let decoded = try JSONDecoder().decode(PlainExplanation.self, from: data)
        #expect(decoded == item1)
        #expect(decoded.title == "Title A")
        #expect(decoded.explanation == "Expl A")
        #expect(decoded.action == "Act A")
    }
}
