import Foundation
import SwiftUI

/// Turns a run of monitor samples into line segments, leaving the gaps as
/// gaps.
///
/// The monitor is not a continuous recorder and never claimed to be. It
/// pauses for system sleep, for display sleep, and for the whole duration of
/// every scan; it restarts when a cadence setting changes; and it dies and
/// backs off if the binary goes missing. A line drawn straight across any of
/// those asserts measurements that were never taken — the same lie the
/// Trends section's "no data" panel exists to refuse, and it is worse here
/// because a smooth line through a two-minute outage is *reassuring*.
///
/// Nothing in this file judges a value. It decides only whether two points
/// were close enough in time to be joined.
enum MonitorSeries {

    struct Point: Identifiable, Equatable {
        let date: Date
        let value: Double
        var id: Date { date }
    }

    /// A stretch of wall-clock with no samples in it.
    struct Gap: Identifiable, Equatable {
        let start: Date
        let end: Date
        var id: Date { start }
    }

    struct Result {
        /// One entry per unbroken stretch. Charts draw each as its own
        /// series so no line spans two of them.
        var segments: [[Point]] = []
        var gaps: [Gap] = []

        var points: [Point] { segments.flatMap { $0 } }
        var isEmpty: Bool { points.isEmpty }
        var latest: Point? { segments.last?.last }
    }

    /// Build one series.
    ///
    /// - Parameters:
    ///   - tier: which cadence tier measures this value — `"fast"`,
    ///     `"medium"` or `"slow"`. Samples where that tier was not due carry
    ///     the previous cycle's number verbatim, and plotting them would
    ///     turn one measurement into six.
    ///   - value: `nil` means not measured, never zero.
    static func build(_ samples: [MonitorSample], tier: String,
                      value: (MonitorSample) -> Double?) -> Result {
        var result = Result()
        var current: [Point] = []
        var previous: MonitorSample?

        func closeSegment() {
            if !current.isEmpty { result.segments.append(current) }
            current = []
        }

        for sample in samples {
            let now = sample.timestamp

            if let previous {
                // If the monitor CLI explicitly emitted a discontinuity via
                // gap_s (sleep/stall measured monotonically by lib/monitor.sh),
                // use that directly. Otherwise fall back to measuring wall clock
                // against the cadence tolerance (two cadences, accounting for probe
                // time on healthy samples).
                let hasGap: Bool
                if let gapS = sample.gapS {
                    hasGap = gapS > 0
                } else {
                    let cadence = Double(previous.status.cadenceS ?? 0)
                    hasGap = cadence > 0 && now.timeIntervalSince(previous.timestamp) > cadence * 2
                }

                if hasGap {
                    result.gaps.append(Gap(start: previous.timestamp, end: now))
                    closeSegment()
                }
            }
            previous = sample

            // A paused sample is the monitor saying so out loud: probing is
            // suspended and every number in it is carried over from before
            // the pause. docs/JSON-SCHEMA.md — do not plot it.
            if sample.status.paused {
                closeSegment()
                continue
            }

            // This tier was not due this cycle. Not a gap: nothing was
            // missed, this value simply is not measured every cycle, and
            // the point marks make its real density visible.
            guard sample.refreshed.contains(tier) else { continue }

            guard let measured = value(sample) else {
                // The tier ran and came back with nothing — a down link, a
                // ping that got no reply. Joining across it would draw a
                // round-trip time through an outage.
                closeSegment()
                continue
            }

            current.append(Point(date: now, value: measured))
        }

        closeSegment()
        return result
    }

    /// Computes moving RFC 3550 jitter across a sequence of samples:
    /// D(i-1, i) = |RTT_i - RTT_{i-1}|
    /// J_i = J_{i-1} + (|D| - J_{i-1}) / 16.0
    /// If samples already have measured probe burst jitter, prioritizes the latest sample's
    /// `liveJitterMs`, falling back to the inter-sample RFC 3550 moving estimate.
    static func movingJitter(samples: [MonitorSample]) -> Double? {
        if let latestJitter = samples.reversed().compactMap(\.liveJitterMs).first {
            return latestJitter
        }

        var prevRTT: Double? = nil
        var currentJitter: Double = 0.0
        var count = 0

        for s in samples {
            guard let rtt = s.internet.rttAvgMs ?? s.gateway.rttAvgMs else { continue }
            if let p = prevRTT {
                let diff = abs(rtt - p)
                if count == 0 {
                    currentJitter = diff
                } else {
                    currentJitter += (diff - currentJitter) / 16.0
                }
                count += 1
            }
            prevRTT = rtt
        }
        return count > 0 ? currentJitter : nil
    }
}

/// Real-time connection stability rating evaluated from RTT, jitter, and packet loss.
struct ConnectionStability: Sendable, Equatable {
    enum Level: String, Sendable, CaseIterable {
        case optimal = "Optimal"
        case variable = "Variable"
        case unstable = "Unstable"
    }

    let level: Level
    let label: String
    let description: String
    let icon: String

    var tint: Color {
        switch level {
        case .optimal: return .green
        case .variable: return .yellow
        case .unstable: return .red
        }
    }

    /// Evaluates stability index according to TASK-026:
    /// - Optimal (green): RTT < 35ms, Jitter < 8ms, Loss == 0%
    /// - Variable (yellow): RTT 35–90ms or Jitter > 8ms (and <= 50ms) or RTT > 90ms (and <= 150ms)
    /// - Unstable (red): Packet loss > 2% or Jitter > 50ms or RTT > 150ms
    static func evaluate(rtt: Double?, jitter: Double?, loss: Double?) -> ConnectionStability {
        guard let rtt else {
            return ConnectionStability(
                level: .variable,
                label: "Unknown",
                description: "Waiting for latency measurements",
                icon: "questionmark.circle"
            )
        }

        let l = loss ?? 0.0
        let j = jitter ?? 0.0

        if l > 2.0 || j > 50.0 || rtt > 150.0 {
            return ConnectionStability(
                level: .unstable,
                label: "Unstable",
                description: "Expect dropouts, buffering, and call audio glitching",
                icon: "exclamationmark.triangle.fill"
            )
        } else if rtt > 35.0 || j > 8.0 || l > 0.0 {
            let label = j > 20.0 ? "High Jitter" : "Variable"
            return ConnectionStability(
                level: .variable,
                label: label,
                description: "Acceptable for browsing/streaming; occasional micro-stutter in live calls/games",
                icon: "waveform.path.ecg"
            )
        } else {
            return ConnectionStability(
                level: .optimal,
                label: "Optimal",
                description: "Flawless for competitive gaming, live streaming, and 4K calls",
                icon: "checkmark.circle.fill"
            )
        }
    }
}
