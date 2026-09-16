import Foundation
import Testing
@testable import HopwatchGUI

@Suite struct MetricGlossaryTests {

    @Test func requiredMetricsExist() {
        // Acceptance criteria:
        // "Create a central MetricGlossary providing concise, jargon-free explanations
        // for all diagnostic rows (Bufferbloat, MTU, RSSI, SNR, IPv6, VPN, UPnP, Clock drift, DNS latency, Packet loss)."
        let requiredKeys = [
            "bufferbloat",
            "mtu",
            "rssi",
            "snr",
            "ipv6",
            "vpn",
            "upnp",
            "clock",
            "dns",
            "packet_loss",
        ]

        for key in requiredKeys {
            let entry = MetricGlossary.entry(for: key)
            #expect(entry != nil, "Missing required glossary entry for \(key)")
            #expect(!entry!.title.isEmpty, "Entry \(key) has empty title")
            #expect(!entry!.summary.isEmpty, "Entry \(key) has empty summary")
            #expect(entry!.impact != nil && !entry!.impact!.isEmpty, "Entry \(key) has empty impact")
            #expect(entry!.fullHelp.contains("Impact:"), "Entry \(key) fullHelp does not format impact")
        }
    }

    @Test func resolvesLabelsAndAliases() {
        // Labels from report card and instruments
        #expect(MetricGlossary.entry(for: "Bufferbloat")?.key == "bufferbloat")
        #expect(MetricGlossary.entry(for: "Under load")?.key == "bufferbloat")
        #expect(MetricGlossary.entry(for: "Packet size (MTU)")?.key == "mtu")
        #expect(MetricGlossary.entry(for: "Wi-Fi signal")?.key == "rssi")
        #expect(MetricGlossary.entry(for: "wifi signal")?.key == "rssi")
        #expect(MetricGlossary.entry(for: "SNR")?.key == "snr")
        #expect(MetricGlossary.entry(for: "IPv6")?.key == "ipv6")
        #expect(MetricGlossary.entry(for: "VPN")?.key == "vpn")
        #expect(MetricGlossary.entry(for: "UPnP")?.key == "upnp")
        #expect(MetricGlossary.entry(for: "NAT topology")?.key == "nat_topology")
        #expect(MetricGlossary.entry(for: "Clock")?.key == "clock")
        #expect(MetricGlossary.entry(for: "Clock drift")?.key == "clock")
        #expect(MetricGlossary.entry(for: "Name lookups (DNS)")?.key == "dns")
        #expect(MetricGlossary.entry(for: "Packet loss")?.key == "packet_loss")
        #expect(MetricGlossary.entry(for: "Loss")?.key == "packet_loss")
        #expect(MetricGlossary.entry(for: "Router")?.key == "router")
        #expect(MetricGlossary.entry(for: "Internet")?.key == "internet")
        #expect(MetricGlossary.entry(for: "Down")?.key == "speed_down")
        #expect(MetricGlossary.entry(for: "Up")?.key == "speed_up")
        #expect(MetricGlossary.entry(for: "Availability")?.key == "availability")
        #expect(MetricGlossary.entry(for: "Local traffic")?.key == "traffic")
        #expect(MetricGlossary.entry(for: "Background watcher")?.key == "watcher")
    }

    @Test func handlesUnknownKeysGracefully() {
        #expect(MetricGlossary.entry(for: "") == nil)
        #expect(MetricGlossary.entry(for: "nonexistent_metric_key") == nil)
        #expect(MetricGlossary.help(for: "nonexistent_metric_key") == nil)
    }
}
