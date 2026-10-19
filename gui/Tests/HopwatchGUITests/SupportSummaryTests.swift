import Foundation
import Testing
@testable import HopwatchGUI

@Suite struct SupportSummaryTests {

    @Test func formatsParametersCleanly() {
        let params = SupportSummaryFormatter.Parameters(
            networkName: "Hotel-WiFi",
            gatewayIP: "192.168.1.1",
            signalQuality: "Good (-58 dBm), SNR 32 dB",
            observedProblem: "Losing 15% of packets to the router",
            localVerification: "Local link is idle and healthy; issue is upstream on network/router",
            concreteAction: "Please consider restarting the local Wi-Fi router / access point",
            userImpact: "Video calls dropping",
            clientIP: "192.168.1.105",
            interfaceName: "en0",
            bssid: "18:e8:29:ab:cd:ef"
        )
        let output = SupportSummaryFormatter.format(params)

        #expect(output.contains("Network: Hotel-WiFi"))
        #expect(output.contains("Local Gateway: 192.168.1.1"))
        #expect(output.contains("Client Device: 192.168.1.105 (en0)"))
        #expect(output.contains("AP BSSID: 18:e8:29:ab:cd:ef"))
        #expect(output.contains("Issue: Losing 15% of packets to the router"))
        #expect(output.contains("Impact: Video calls dropping"))
        #expect(output.contains("Why This Is Not a Computer or Distance Issue"))
        #expect(output.contains("Computer / Laptop Ruled Out:"))
        #expect(output.contains("Wi-Fi Signal / Distance Ruled Out:"))
        #expect(output.contains("Device Status: Local link is idle and healthy; issue is upstream on network/router"))
        #expect(output.contains("Suggested Action: Please consider restarting the local Wi-Fi router / access point"))
        #expect(output.contains("https://github.com/godigi/hopwatch"))
    }

    @Test func describeSignalRatings() {
        #expect(SupportSummaryFormatter.describeSignal(rssi: -45, snr: 35).contains("Excellent"))
        #expect(SupportSummaryFormatter.describeSignal(rssi: -65, snr: 25).contains("Good"))
        #expect(SupportSummaryFormatter.describeSignal(rssi: -72, snr: 15).contains("Fair"))
        #expect(SupportSummaryFormatter.describeSignal(rssi: -82, snr: 8).contains("Weak"))
        #expect(SupportSummaryFormatter.describeSignal(rssi: nil, isWired: true) == "Wired Ethernet link")
    }

    @Test func formatsSnapshotWithFixAwayWhenNotOwned() throws {
        let json = """
        {
          "network": {"id": "wifi:ssid=Hotel-Guest", "label": "Hotel Guest WiFi"},
          "wifi": {"ssid": "Hotel-Guest", "bssid": "3c:37:86:11:22:33", "rssi": -65, "snr": 28, "channel": "36"},
          "interface": {"name": "en0", "ip": "10.0.0.52"},
          "gateway": {"ip": "10.0.0.1", "loss_pct": 12.0, "rtt_avg_ms": 45.0},
          "public": {"ip": "198.51.100.1", "isp": "Spectrum", "city": "Orlando", "country": "United States"},
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
        #expect(notOwnedSummary.contains("Good (-65 dBm)"))
        #expect(notOwnedSummary.contains("AP BSSID: 3c:37:86:11:22:33"))
        #expect(notOwnedSummary.contains("Client Device: 10.0.0.52 (en0)"))
        #expect(notOwnedSummary.contains("Public Endpoint: 198.51.100.1 (Spectrum, Orlando, United States)"))
        #expect(notOwnedSummary.contains("Why This Is Not a Computer or Distance Issue"))
        #expect(notOwnedSummary.contains("Computer / Laptop Ruled Out:"))
        #expect(notOwnedSummary.contains("Wi-Fi Signal / Distance Ruled Out: Wireless signal between this computer and the access point is Good (-65 dBm, SNR 28 dB, well above the -75 dBm minimum threshold)"))
        #expect(notOwnedSummary.contains("Actual Fault Location (Local Router / Access Point):"))
        #expect(notOwnedSummary.contains("Ask whoever runs this network to restart the router."))
        #expect(notOwnedSummary.contains("Local link is idle and healthy"))
        #expect(notOwnedSummary.contains("https://github.com/godigi/hopwatch"))

        // When network IS owned
        let ownedSummary = SupportSummaryFormatter.format(
            snapshot: snapshot,
            catalog: catalog,
            networkIsOwned: true
        )
        #expect(ownedSummary.contains("Reboot the router: unplug it"))
    }

    @Test func formatsLiveMonitorSampleWithoutAlertFallingBackToGatewayLoss() throws {
        let json = """
        {
          "schema": 2,
          "ts": "2026-10-18T13:20:00Z",
          "link": {"up": true, "type": "wifi", "ssid": "CoffeeShop-Guest", "bssid": "aa:bb:cc:dd:ee:ff", "ip": "192.168.1.42", "interface": "en0", "gateway": "192.168.1.1", "gateway_mac": "00:11:22:33:44:55"},
          "wifi": {"rssi": -67, "snr": 15, "channel": "36"},
          "gateway": {"loss_pct": 14.0, "rtt_avg_ms": 38.5, "rtt_jitter_ms": 4.2},
          "internet": {"loss_pct": 10.0, "rtt_avg_ms": 48.0},
          "public": {"ip": "203.0.113.5", "isp": "Starlink", "city": "Austin", "country": "United States"},
          "status": {"severity": "degraded", "rules": []}
        }
        """.data(using: .utf8)!
        let sample = try JSONDecoder().decode(MonitorSample.self, from: json)

        let summary = SupportSummaryFormatter.format(
            sample: sample,
            alert: nil,
            catalog: nil,
            networkIsOwned: false
        )

        #expect(summary.contains("CoffeeShop-Guest"))
        #expect(summary.contains("192.168.1.1"))
        #expect(summary.contains("MAC: 00:11:22:33:44:55"))
        #expect(summary.contains("Client Device: 192.168.1.42 (en0)"))
        #expect(summary.contains("AP BSSID: aa:bb:cc:dd:ee:ff"))
        #expect(summary.contains("Good (-67 dBm)"))
        #expect(summary.contains("Why This Is Not a Computer or Distance Issue"))
        #expect(summary.contains("Computer / Laptop Ruled Out:"))
        #expect(summary.contains("Wi-Fi Signal / Distance Ruled Out:"))
        #expect(summary.contains("Actual Fault Location (Local Router / Access Point):"))
        #expect(summary.contains("Public Endpoint: 203.0.113.5 (Starlink, Austin, United States)"))
        #expect(summary.contains("Losing 14% of packets to the local router"))
        #expect(summary.contains("Suggested Action: Please restart or power-cycle the local Wi-Fi router / access point"))
        #expect(summary.contains("https://github.com/godigi/hopwatch"))
    }

    @Test func isolatesUpstreamISPFailureWhenWiFiAndRouterAreHealthy() throws {
        let json = """
        {
          "schema": 2,
          "ts": "2026-10-18T14:00:00Z",
          "link": {"up": true, "type": "wifi", "ssid": "Airbnb-5G", "gateway": "192.168.1.1"},
          "wifi": {"rssi": -58, "snr": 30, "channel": "149"},
          "gateway": {"loss_pct": 0.0, "rtt_avg_ms": 2.4},
          "internet": {"loss_pct": 18.0, "rtt_avg_ms": 65.0},
          "public": {"ip": "198.51.100.99", "isp": "Comcast"},
          "status": {"severity": "critical", "rules": ["L1"]}
        }
        """.data(using: .utf8)!
        let sample = try JSONDecoder().decode(MonitorSample.self, from: json)

        let summary = SupportSummaryFormatter.format(
            sample: sample,
            alert: nil,
            catalog: nil,
            networkIsOwned: false
        )

        #expect(summary.contains("Why This Is Not a Computer or Distance Issue"))
        #expect(summary.contains("Computer / Laptop Ruled Out:"))
        #expect(summary.contains("Wi-Fi Signal / Distance Ruled Out:"))
        #expect(summary.contains("Actual Fault Location (Upstream ISP / Broadband Line): Traffic reaches the local router (192.168.1.1) with 0% packet loss, proving the computer and room Wi-Fi are working properly."))
    }

    @Test func distinguishesWeakRoomWiFiCoverageFromComputerFault() throws {
        let json = """
        {
          "schema": 2,
          "ts": "2026-10-18T14:05:00Z",
          "link": {"up": true, "type": "wifi", "ssid": "Hotel-CornerRoom", "gateway": "10.10.0.1"},
          "wifi": {"rssi": -82, "snr": 8, "channel": "6"},
          "gateway": {"loss_pct": 8.0, "rtt_avg_ms": 42.0},
          "status": {"severity": "warn", "rules": ["W1"]}
        }
        """.data(using: .utf8)!
        let sample = try JSONDecoder().decode(MonitorSample.self, from: json)

        let summary = SupportSummaryFormatter.format(
            sample: sample,
            alert: nil,
            catalog: nil,
            networkIsOwned: false
        )

        #expect(summary.contains("Why This Is Not a Computer Issue (Root-Cause Isolation)"))
        #expect(summary.contains("Computer / Laptop Ruled Out:"))
        #expect(summary.contains("Room Wi-Fi Coverage Issue: Wireless signal in this location is Weak (-82 dBm, SNR 8 dB, below the -75 dBm threshold needed for a stable connection)"))
        #expect(summary.contains("Actual Fault Location (Property Wi-Fi Coverage / Access Point):"))
    }

    @Test func formatsCaptivePortalSupportSummaryWithoutRouterBlame() throws {
        let json = """
        {
          "schema": 2,
          "ts": "2026-10-18T14:10:00Z",
          "link": {"up": true, "type": "wifi", "ssid": "Mercure", "gateway": "10.125.128.1"},
          "wifi": {"rssi": -67, "snr": 10, "channel": "3"},
          "gateway": {"loss_pct": 100.0, "rtt_avg_ms": 0.0},
          "internet": {"loss_pct": 100.0, "rtt_avg_ms": 0.0},
          "public": {"captive_portal": true},
          "status": {"severity": "critical", "rules": ["CP-1"]}
        }
        """.data(using: .utf8)!
        let sample = try JSONDecoder().decode(MonitorSample.self, from: json)

        let summary = SupportSummaryFormatter.format(
            sample: sample,
            alert: nil,
            catalog: nil,
            networkIsOwned: false
        )

        #expect(summary.contains("Network: Mercure"))
        #expect(summary.contains("Issue: Wi-Fi sign-in / captive portal authentication required to access the internet"))
        #expect(summary.contains("Suggested Action: Please provide the guest Wi-Fi portal URL or login instructions."))
        #expect(summary.contains("Actual Fault Location (Captive Portal / Sign-In Gateway)"))
        #expect(!summary.contains("restart the router"))
        #expect(!summary.contains("power-cycle the local Wi-Fi router"))
    }
}
