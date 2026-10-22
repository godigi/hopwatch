import Foundation
import Darwin
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
    private var readSource: (any DispatchSourceRead)?
    private var isTestingMode: Bool = false
    private var isExplicitlyStopped: Bool = true
    private let log = Logger(subsystem: "com.godigi.hopwatch", category: "heartbeat")
    private let readQueue = DispatchQueue(label: "com.godigi.hopwatch.heartbeat.read", qos: .userInitiated)

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
        isExplicitlyStopped = false
        guard !isRunning, !isTestingMode else { return }
        spawnPingProcess()
    }

    func stop() {
        isExplicitlyStopped = true
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
        log.debug("beat #\(self.beatTick): \(beat.latencyMs ?? -1, format: .fixed(precision: 1))ms miss=\(beat.isMiss)")
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
        proc.standardError = pipe

        do {
            try proc.run()
            process = proc
            isRunning = true
            log.info("ping heartbeat started for target \(self.target, privacy: .public)")

            let fd = pipe.fileHandleForReading.fileDescriptor
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)

            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: readQueue)
            var lineBuffer = Data()

            source.setEventHandler { [weak self] in
                var chunk = [UInt8](repeating: 0, count: 1024)
                while true {
                    let bytesRead = read(fd, &chunk, chunk.count)
                    if bytesRead > 0 {
                        lineBuffer.append(chunk, count: bytesRead)
                    } else if bytesRead == 0 {
                        source.cancel()
                        break
                    } else {
                        break
                    }
                }

                while let nlIndex = lineBuffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let lineData = lineBuffer.subdata(in: 0..<nlIndex)
                    lineBuffer.removeSubrange(0...nlIndex)
                    if let line = String(data: lineData, encoding: .utf8) {
                        let cleanLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !cleanLine.isEmpty {
                            Task { @MainActor [weak self] in
                                guard let self else { return }
                                if let beat = Self.parsePingLine(cleanLine, target: self.target) {
                                    self.ingestBeat(beat)
                                }
                            }
                        }
                    }
                }
            }

            source.setCancelHandler { [weak self, weak proc, pipe] in
                _ = pipe // Retain pipe until dispatch source registration teardown completes
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.process === proc {
                        self.isRunning = false
                        self.scheduleAutoRecoveryIfNeeded()
                    }
                }
            }

            readSource = source
            source.resume()
        } catch {
            log.error("failed to spawn ping heartbeat: \(error.localizedDescription, privacy: .public)")
            isRunning = false
            scheduleAutoRecoveryIfNeeded()
        }
    }

    private func scheduleAutoRecoveryIfNeeded() {
        guard !isExplicitlyStopped, !isPaused, !isTestingMode else { return }
        log.info("ping heartbeat stream ended; scheduling auto-recovery in 1s")
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, !self.isRunning, !self.isExplicitlyStopped, !self.isPaused, !self.isTestingMode else { return }
            self.spawnPingProcess()
        }
    }

    private func terminatePingProcess() {
        if let source = readSource {
            readSource = nil
            source.cancel()
        }

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
