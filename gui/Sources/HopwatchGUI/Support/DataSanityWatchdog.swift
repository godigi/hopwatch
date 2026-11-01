import Foundation
import os

/// Runtime and test invariant checker that proactively validates view states and telemetry bindings
/// against ground truth, flagging contradictions or stale fallbacks before they mislead users.
enum DataSanityWatchdog {

    private static let log = Logger(subsystem: "com.godigi.hopwatch", category: "sanity")

    struct Violation: Sendable, Equatable {
        let name: String
        let description: String
        let severity: Severity

        enum Severity: String, Sendable, Equatable {
            case warning
            case critical
        }
    }

    /// Verifies availability telemetry consistency against raw network events and heartbeat telemetry.
    static func checkAvailability(
        result: AvailabilityEngine.Result,
        events: [NetworkEvent],
        heartbeatMisses: Int
    ) -> [Violation] {
        var violations: [Violation] = []

        // Invariant 1: If hard outages or severe drops occurred in the event log,
        // the display cannot claim "0 outages" or "No history yet".
        let hasHardOutages = events.contains { e in
            guard let r = e.ruleID else { return false }
            return AvailabilityEngine.hardOutageRules.contains(r) && (e.kind == "rule-fired" || e.kind == "alert")
        }
        if hasHardOutages && result.outages == 0 {
            violations.append(Violation(
                name: "UncountedHardOutages",
                description: "Event log contains hard outage rules but availability reported 0 outages",
                severity: .critical
            ))
        }

        // Invariant 2: Total downtime must be >= longest single outage.
        if result.downtimeSeconds < result.longestOutageSeconds {
            violations.append(Violation(
                name: "DowntimeInversion",
                description: "Total downtime (\(result.downtimeSeconds)s) is less than longest outage (\(result.longestOutageSeconds)s)",
                severity: .critical
            ))
        }

        // Invariant 3: Observation note cannot say "No prior data" when events exist.
        if !events.isEmpty && result.observationSummary.contains("No prior data") {
            violations.append(Violation(
                name: "MisleadingNoPriorData",
                description: "Observation summary claimed no prior data despite \(events.count) network events existing",
                severity: .warning
            ))
        }

        // Log violations in debug mode
        #if DEBUG
        for violation in violations {
            if violation.severity == .critical {
                log.error("DataSanityWatchdog [CRITICAL]: \(violation.name) — \(violation.description)")
            } else {
                log.warning("DataSanityWatchdog [WARN]: \(violation.name) — \(violation.description)")
            }
        }
        #endif

        return violations
    }
}
