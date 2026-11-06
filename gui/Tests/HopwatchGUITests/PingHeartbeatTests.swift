import Foundation
import Testing
@testable import HopwatchGUI

@Suite struct PingHeartbeatTests {

    @Test func pingLineParsingSuccessfulReply() {
        let line = "64 bytes from 1.1.1.1: icmp_seq=33169 ttl=53 time=190.641 ms"
        let beat = PingHeartbeat.parsePingLine(line)
        #expect(beat != nil)
        #expect(beat?.isMiss == false)
        #expect(beat?.latencyMs == 190.641)
        #expect(beat?.seq == 33169)
        #expect(beat?.target == "1.1.1.1")
    }

    @Test func pingLineParsingSubMillisecondReply() {
        let line = "64 bytes from 192.168.0.1: icmp_seq=0 ttl=64 time=0.852 ms"
        let beat = PingHeartbeat.parsePingLine(line, target: "192.168.0.1")
        #expect(beat != nil)
        #expect(beat?.isMiss == false)
        #expect(beat?.latencyMs == 0.852)
        #expect(beat?.seq == 0)
        #expect(beat?.target == "192.168.0.1")
    }

    @Test func pingLineParsingRequestTimeout() {
        let line = "Request timeout for icmp_seq 33170"
        let beat = PingHeartbeat.parsePingLine(line)
        #expect(beat != nil)
        #expect(beat?.isMiss == true)
        #expect(beat?.latencyMs == nil)
        #expect(beat?.seq == 33170)
    }

    @Test func pingLineParsingSendtoAndUnreachableErrors() {
        let line1 = "ping: sendto: No route to host"
        let beat1 = PingHeartbeat.parsePingLine(line1)
        #expect(beat1 != nil)
        #expect(beat1?.isMiss == true)
        #expect(beat1?.latencyMs == nil)

        let line2 = "ping: sendto: Host is down"
        let beat2 = PingHeartbeat.parsePingLine(line2)
        #expect(beat2 != nil)
        #expect(beat2?.isMiss == true)

        let line3 = "ping: cannot resolve nonexistent.invalid: Unknown host"
        let beat3 = PingHeartbeat.parsePingLine(line3)
        #expect(beat3 != nil)
        #expect(beat3?.isMiss == true)
    }

    @Test func pingLineParsingIgnoresHeadersAndStatistics() {
        #expect(PingHeartbeat.parsePingLine("PING 1.1.1.1 (1.1.1.1): 56 data bytes") == nil)
        #expect(PingHeartbeat.parsePingLine("--- 1.1.1.1 ping statistics ---") == nil)
        #expect(PingHeartbeat.parsePingLine("10 packets transmitted, 9 packets received, 10.0% packet loss") == nil)
        #expect(PingHeartbeat.parsePingLine("round-trip min/avg/max/stddev = 47.438/112.291/240.957/90.982 ms") == nil)
        #expect(PingHeartbeat.parsePingLine("") == nil)
        #expect(PingHeartbeat.parsePingLine("   \n") == nil)
    }

    @Test @MainActor func beatIngestionAndSlidingWindow() {
        let heartbeat = PingHeartbeat()
        #expect(heartbeat.beats.isEmpty)

        // Ingest 40 beats (exceeding maxBeats of 32)
        for i in 1...40 {
            heartbeat.adoptTestBeat(latencyMs: Double(i), isMiss: false, seq: i)
        }

        #expect(heartbeat.beats.count == PingHeartbeat.maxBeats)
        #expect(heartbeat.latestBeat?.latencyMs == 40.0)
        #expect(heartbeat.latestBeat?.seq == 40)
        #expect(heartbeat.beats.first?.seq == 40 - PingHeartbeat.maxBeats + 1)
    }

    @Test @MainActor func metricsComputation() {
        let heartbeat = PingHeartbeat()

        heartbeat.adoptTestBeat(latencyMs: 50.0, isMiss: false)
        heartbeat.adoptTestBeat(latencyMs: 100.0, isMiss: false)
        heartbeat.adoptTestBeat(latencyMs: nil, isMiss: true) // 1 miss
        heartbeat.adoptTestBeat(latencyMs: 150.0, isMiss: false)

        #expect(heartbeat.totalCount == 4)
        #expect(heartbeat.missCount == 1)
        #expect(heartbeat.lossPct == 25.0)
        #expect(heartbeat.minLatency == 50.0)
        #expect(heartbeat.maxLatency == 150.0)
        #expect(heartbeat.avgLatency == 100.0)
        #expect(heartbeat.hasRecentMiss == true)
    }

    @Test @MainActor func targetSwitching() {
        let heartbeat = PingHeartbeat(target: "1.1.1.1")
        heartbeat.adoptTestBeat(latencyMs: 45.0, isMiss: false)
        #expect(heartbeat.beats.count == 1)

        heartbeat.switchTarget("192.168.0.1")
        #expect(heartbeat.target == "192.168.0.1")
        #expect(heartbeat.beats.isEmpty)
        #expect(heartbeat.latestBeat == nil)
    }

    @Test @MainActor func seedingFromMonitorSamples() {
        let heartbeat = PingHeartbeat()

        var s1 = MonitorSample()
        s1.seq = 1
        s1.link.up = true
        s1.internet.rttAvgMs = 25.0
        s1.internet.lossPct = 0

        var s2 = MonitorSample()
        s2.seq = 2
        s2.internet.rttAvgMs = nil
        s2.internet.lossPct = 100
        s2.link.up = true

        var s3 = MonitorSample()
        s3.seq = 3
        s3.link.up = false
        s3.internet.rttAvgMs = nil
        s3.internet.lossPct = nil

        // Unmeasured sample with link up and 0% loss must be skipped rather than fabricated as a miss
        var s4 = MonitorSample()
        s4.seq = 4
        s4.link.up = true
        s4.internet.rttAvgMs = nil
        s4.internet.lossPct = 0

        heartbeat.seedFromSamples([s1, s2, s3, s4])

        #expect(heartbeat.beats.count == 3)
        #expect(heartbeat.beats[0].latencyMs == 25.0)
        #expect(heartbeat.beats[0].isMiss == false)
        #expect(heartbeat.beats[1].isMiss == true)
        #expect(heartbeat.beats[1].latencyMs == nil)
        #expect(heartbeat.beats[2].isMiss == true)
        #expect(heartbeat.beats[2].latencyMs == nil)
    }

    @Test @MainActor func seedingHonorsGatewayTarget() {
        let heartbeat = PingHeartbeat(target: "192.168.1.1")
        var s = MonitorSample()
        s.seq = 1
        s.link.up = true
        s.link.gateway = "192.168.1.1"
        s.gateway.rttAvgMs = 4.5
        s.gateway.lossPct = 0
        s.internet.rttAvgMs = 42.0
        s.internet.lossPct = 0

        heartbeat.seedFromSamples([s])
        #expect(heartbeat.beats.count == 1)
        #expect(heartbeat.beats[0].latencyMs == 4.5)
        #expect(heartbeat.beats[0].isMiss == false)
    }

    @Test @MainActor func resetClearsBeatsAndRestoresTarget() {
        let heartbeat = PingHeartbeat(target: "192.168.1.1")
        heartbeat.adoptTestBeat(latencyMs: 12.0, isMiss: false, seq: 1)
        #expect(heartbeat.beats.count == 1)

        heartbeat.reset()
        #expect(heartbeat.target == PingHeartbeat.defaultTarget)
        #expect(heartbeat.beats.isEmpty)
        #expect(heartbeat.latestBeat == nil)
        #expect(heartbeat.beatTick == 0)
    }

    @Test @MainActor func filteredStateManagement() {
        let heartbeat = PingHeartbeat()
        heartbeat.adoptTestBeat(latencyMs: 15.0, isMiss: false, seq: 1)
        #expect(!heartbeat.beats.isEmpty)

        // Setting filtered clears beats and latestBeat, marking isFiltered true
        heartbeat.setFiltered(true)
        #expect(heartbeat.isFiltered)
        #expect(heartbeat.beats.isEmpty)
        #expect(heartbeat.latestBeat == nil)
        #expect(!heartbeat.isRunning)

        // Seeding while filtered is suppressed
        var s = MonitorSample()
        s.internet.rttAvgMs = 20.0
        heartbeat.seedFromSamples([s])
        #expect(heartbeat.beats.isEmpty)

        // Clearing filtered restores unmuted state
        heartbeat.setFiltered(false)
        #expect(!heartbeat.isFiltered)
    }

    @Test func commandArgumentsSelectsPing6ForIPv6Target() {
        let v4 = PingHeartbeat.commandArguments(for: "192.168.1.1")
        #expect(v4.executable == "/sbin/ping")
        #expect(v4.arguments == ["-n", "-i", "1", "-W", "1000", "192.168.1.1"])

        let v6 = PingHeartbeat.commandArguments(for: "fe80::1%en0")
        #expect(v6.executable == "/sbin/ping6")
        #expect(v6.arguments == ["-n", "-i", "1", "fe80::1%en0"])
    }
}
