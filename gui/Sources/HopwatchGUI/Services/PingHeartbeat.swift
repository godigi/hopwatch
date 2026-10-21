import Foundation
import os

/// Represents a single ping probe measurement in the live heartbeat stream.
struct PingBeat: Identifiable, Sendable, Equatable {
    let id: UUID
    let timestamp: Date
    let latencyMs: Double?
    let isMiss: Bool
    let seq: Int?
    let target: String

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        latencyMs: Double?,
        isMiss: Bool,
        seq: Int? = nil,
        target: String = "1.1.1.1"
    ) {
        self.id = id
        self.timestamp = timestamp
        self.latencyMs = latencyMs
        self.isMiss = isMiss
        self.seq = seq
        self.target = target
    }
}

/// Runs a continuous 1-second ICMP ping stream (`/sbin/ping -n -i 1 -W 1000 <target>`)
/// to provide a real-time heartbeat of network latency and instantaneous packet drops ("MISSes").
///
/// Designed to feel like the terminal `ping` utility: beating rhythmically every second,
/// displaying latency fluctuations with microsecond precision, and immediately highlighting
/// dropped packets / timeouts as they occur.
@MainActor
@Observable
final class PingHeartbeat: @unchecked Sendable {

    nonisolated static let defaultTarget = "1.1.1.1"
    nonisolated static let maxBeats = 32

    private(set) var beats: [PingBeat] = []
    private(set) var latestBeat: PingBeat?
    private(set) var isRunning: Bool = false
    private(set) var isPaused: Bool = false
    private(set) var target: String = defaultTarget
    private(set) var beatTick: Int = 0

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var readTask: Task<Void, Never>?
    private var isTestingMode: Bool = false
    private let log = Logger(subsystem: "com.godigi.hopwatch", category: "heartbeat")

    init(target: String = defaultTarget) {
        self.target = target
    }

    // MARK: - Computed Metrics

    var recentBeats: [PingBeat] {
        beats
    }

    var missCount: Int {
        beats.filter(\.isMiss).count
    }

    var totalCount: Int {
        beats.count
    }

    var lossPct: Double {
        guard !beats.isEmpty else { return 0.0 }
        return (Double(missCount) / Double(beats.count)) * 100.0
    }

    var validLatencies: [Double] {
        beats.compactMap(\.latencyMs)
    }

    var minLatency: Double? {
        validLatencies.min()
    }

    var maxLatency: Double? {
        validLatencies.max()
    }

    var avgLatency: Double? {
        let valid = validLatencies
        guard !valid.isEmpty else { return nil }
        return valid.reduce(0, +) / Double(valid.count)
    }

    var hasRecentMiss: Bool {
        // Did any of the last 5 beats fail?
        beats.suffix(5).contains(where: \.isMiss)
    }

    // MARK: - Lifecycle Controls

    func start(target: String? = nil) {
        if let target, !target.isEmpty {
            self.target = target
        }
        guard !isRunning, !isTestingMode else { return }
        spawnPingProcess()
    }

    func stop() {
        terminatePingProcess()
        isRunning = false
        isPaused = false
    }

    func pause() {
        guard isRunning, !isPaused else { return }
        isPaused = true
        terminatePingProcess()
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        spawnPingProcess()
    }

    func reset(to newTarget: String = defaultTarget) {
        let trimmed = newTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        target = trimmed.isEmpty ? Self.defaultTarget : trimmed
        beats.removeAll()
        latestBeat = nil
        beatTick = 0
        if isRunning && !isPaused {
            terminatePingProcess()
            spawnPingProcess()
        }
    }

    func switchTarget(_ newTarget: String) {
        let trimmed = newTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != target else { return }
        reset(to: trimmed)
    }

    // MARK: - Ingestion & Parsing

    func ingestBeat(_ beat: PingBeat) {
        latestBeat = beat
        beats.append(beat)
        if beats.count > Self.maxBeats {
            beats.removeFirst(beats.count - Self.maxBeats)
        }
        beatTick &+= 1
    }

    func adoptTestBeat(latencyMs: Double?, isMiss: Bool, seq: Int? = nil) {
        isTestingMode = true
        let beat = PingBeat(
            timestamp: Date(),
            latencyMs: latencyMs,
            isMiss: isMiss,
            seq: seq ?? beatTick,
            target: target
        )
        ingestBeat(beat)
    }

    func seedFromSamples(_ samples: [MonitorSample]) {
        guard beats.isEmpty else { return }
        let recent = samples.suffix(Self.maxBeats)
        for sample in recent {
            if sample.status.paused { continue }
            let rtt = sample.internet.rttAvgMs
            let loss = sample.internet.lossPct ?? 0
            let isMiss = !sample.link.up || (loss >= 100) || (rtt == nil)
            let beat = PingBeat(
                timestamp: sample.timestamp,
                latencyMs: isMiss ? nil : rtt,
                isMiss: isMiss,
                seq: sample.seq,
                target: target
            )
            ingestBeat(beat)
        }
    }

    // MARK: - Line Parser (Internal & Pure for Unit Testing)

    nonisolated static func parsePingLine(_ line: String, target: String = defaultTarget) -> PingBeat? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Ignore metadata header and trailing summary statistics
        if trimmed.hasPrefix("PING ") || trimmed.hasPrefix("--- ")
            || trimmed.contains("packets transmitted")
            || trimmed.contains("round-trip")
            || trimmed.contains("stddev =") {
            return nil
        }

        let seq = extractSequence(from: trimmed)

        // 1. Explicit request timeout: "Request timeout for icmp_seq 33170"
        if trimmed.contains("Request timeout") {
            return PingBeat(
                timestamp: Date(),
                latencyMs: nil,
                isMiss: true,
                seq: seq,
                target: target
            )
        }

        // 2. Network delivery error: sendto: No route to host, Host is down, Network is down
        if trimmed.contains("sendto:") || trimmed.contains("Host is down")
            || trimmed.contains("No route to host") || trimmed.contains("Network is down")
            || trimmed.contains("cannot resolve") {
            return PingBeat(
                timestamp: Date(),
                latencyMs: nil,
                isMiss: true,
                seq: seq,
                target: target
            )
        }

        // 3. Successful ICMP reply: "64 bytes from 1.1.1.1: icmp_seq=33169 ttl=53 time=190.641 ms"
        if let timeRange = trimmed.range(of: "time=") {
            let afterTime = trimmed[timeRange.upperBound...]
            var numStr = ""
            for ch in afterTime {
                if ch.isNumber || ch == "." {
                    numStr.append(ch)
                } else {
                    break
                }
            }
            if let latency = Double(numStr) {
                return PingBeat(
                    timestamp: Date(),
                    latencyMs: latency,
                    isMiss: false,
                    seq: seq,
                    target: target
                )
            }
        }

        return nil
    }

    private nonisolated static func extractSequence(from line: String) -> Int? {
        guard let seqRange = line.range(of: "icmp_seq=") ?? line.range(of: "icmp_seq ") else {
            return nil
        }
        let afterSeq = line[seqRange.upperBound...]
        var numStr = ""
        for ch in afterSeq {
            if ch.isNumber {
                numStr.append(ch)
            } else {
                break
            }
        }
        return Int(numStr)
    }

    // MARK: - Process Execution

    private func spawnPingProcess() {
        terminatePingProcess()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/sbin/ping")
        proc.arguments = [
            "-n",           // Numeric output only, avoid DNS reverse lookups
            "-i", "1",      // 1-second heartbeat interval
            "-W", "1000",   // 1000ms reply timeout
            target
        ]

        let pipe = Pipe()
        stdoutPipe = pipe
        proc.standardOutput = pipe
        proc.standardError = pipe // Also capture errors (sendto, etc.)

        do {
            try proc.run()
            process = proc
            isRunning = true
            log.info("ping heartbeat started for target \(self.target, privacy: .public)")

            readTask = Task { [weak self] in
                await self?.consumePingStream(pipe: pipe, proc: proc)
            }
        } catch {
            log.error("failed to spawn ping heartbeat: \(error.localizedDescription, privacy: .public)")
            isRunning = false
        }
    }

    private func consumePingStream(pipe: Pipe, proc: Process) async {
        let handle = pipe.fileHandleForReading
        do {
            for try await line in handle.bytes.lines {
                if Task.isCancelled || process !== proc { break }
                if let beat = Self.parsePingLine(line, target: target) {
                    await MainActor.run {
                        self.ingestBeat(beat)
                    }
                }
            }
        } catch {
            // EOF or pipe closed
        }

        await MainActor.run {
            if self.process === proc {
                self.isRunning = false
            }
        }
    }

    private func terminatePingProcess() {
        readTask?.cancel()
        readTask = nil
        try? stdoutPipe?.fileHandleForReading.close()
        stdoutPipe = nil

        if let proc = process, proc.isRunning {
            proc.terminate()
            Task.detached(priority: .utility) {
                for _ in 0..<10 {
                    if !proc.isRunning { break }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                if proc.isRunning {
                    kill(proc.processIdentifier, SIGKILL)
                }
                proc.waitUntilExit()
            }
        }
        process = nil
    }
}
