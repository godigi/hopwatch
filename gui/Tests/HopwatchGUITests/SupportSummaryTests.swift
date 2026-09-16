import Foundation
import Testing
@testable import HopwatchGUI

@Suite struct SupportSummaryTests {

    @Test func formatsParametersCleanly() {
        let params = SupportSummaryFormatter.Parameters(
            networkName: "Hotel-WiFi",
            gatewayIP: "192.168.1.1",
            signalQuality: "-58 dBm, SNR 32 dB",
            observedProblem: "Losing 15% of packets to the router",
            localVerification: "Laptop link is idle; issue is on the network/router side",
            concreteAction: "Please restart floor access point / router"
        )
        let output = SupportSummaryFormatter.format(params)

        #expect(output.contains("Network Name / SSID: Hotel-WiFi"))
        #expect(output.contains("Local Gateway IP: 192.168.1.1"))
        #expect(output.contains("Signal Strength & Quality: -58 dBm, SNR 32 dB"))
        #expect(output.contains("Observed Problem: Losing 15% of packets to the router"))
        #expect(output.contains("Local verification: Laptop link is idle; issue is on the network/router side"))
        #expect(output.contains("Concrete action: Please restart floor access point / router"))
    }

    @Test func formatsSnapshotWithFixAwayWhenNotOwned() throws {
        let json = """
        {
          "network": {"id": "wifi:ssid=Hotel-Guest", "label": "Hotel Guest WiFi"},
          "wifi": {"ssid": "Hotel-Guest", "rssi": -65, "snr": 28, "channel": "36"},
          "gateway": {"ip": "10.0.0.1"},
          "diagnosis": [
            {"severity": "critical", "rule": "G2", "summary": "Router is dropping 12% of packets"}
          ]
        }
        """.data(using: .utf8)!
        let snapshot = try JSONDecoder().decode(RunSnapshot.self, from: json)

        let catalogJSON = """
        {"schema": 5, "rules": [
          {"id": "G2", "title": "Router dropping packets",
           "fix": "Reboot the router: unplug it, wait ten seconds, plug it back in.",
           "fix_away": "Ask whoever runs this network to restart the router.",
           "fix_target": "your_router"}
        ]}
        """.data(using: .utf8)!
        let catalog = try JSONDecoder().decode(RulesCatalog.self, from: catalogJSON)

        // When network is NOT owned
        let notOwnedSummary = SupportSummaryFormatter.format(
            snapshot: snapshot,
            catalog: catalog,
            networkIsOwned: false
        )
        #expect(notOwnedSummary.contains("Hotel-Guest"))
        #expect(notOwnedSummary.contains("10.0.0.1"))
        #expect(notOwnedSummary.contains("Ask whoever runs this network to restart the router."))
        #expect(notOwnedSummary.contains("Laptop link is idle; issue is on the network/router side"))

        // When network IS owned
        let ownedSummary = SupportSummaryFormatter.format(
            snapshot: snapshot,
            catalog: catalog,
            networkIsOwned: true
        )
        #expect(ownedSummary.contains("Reboot the router: unplug it"))
    }
}
