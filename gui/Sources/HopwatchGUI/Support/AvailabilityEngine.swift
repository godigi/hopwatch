import Foundation

/// Synthesizes live connection reliability and availability telemetry by combining
/// the active event log (`NetworkEvent`s), `PingHeartbeat` telemetry, and stored scan snapshots.
///
/// This eliminates the failure mode where a continuously running monitor records drops
/// and packet loss episodes, but the Dashboard displays "No history yet" or "Monitoring started recently"
/// because no manual scan was run recently.
enum AvailabilityEngine {

    struct Result: Sendable, Equatable {
        /// Formatted outage or drop count (e.g. "3 outages", "5 drops", "0 outages").
        let outageCountText: String
        /// Formatted total downtime / disruption duration (e.g. "4m 12s", "0s").
        let totalDowntimeText: String
        /// Formatted longest single outage / drop duration (e.g. "1m 45s", "0s").
        let longestOutageText: String
        /// Reassuring and honest observation note describing the monitoring window.
        let observationSummary: String
        /// Number of total outages / drops.
        let outages: Int
        /// Total downtime / disruption seconds.
        let downtimeSeconds: Int
        /// Longest single outage / disruption in seconds.
        let longestOutageSeconds: Int
    }

    /// Complete disconnection rules matching lib/thresholds.sh THRESH_AV_OUTAGE_RULES
    static let hardOutageRules: Set<String> = ["N1", "N1b", "N1c", "P1", "P2", "ND-1"]

    /// Severe disruptions that make the connection effectively unusable
    static let severeDisruptionRules: Set<String> = ["L1", "G2", "CONN-1"]

    /// Mild or moderate degradations
    static let degradationRules: Set<String> = ["L2", "G3", "D1"]

    /// Evaluates live availability from current network events, ping heartbeat, and optional run snapshot.
    static func evaluate(
        networkEvents: [NetworkEvent],
        allRecentEvents: [NetworkEvent] = [],
        currentRunAvailability: RunSnapshot.Availability? = nil,
        heartbeatMisses: Int = 0,
        heartbeatTotal: Int = 0,
        networkConnectedAt: Date? = nil,
        now: Date = .now
    ) -> Result {
        let folded = ActivityEntry.fold(networkEvents)

        // Count episodes and sum durations from folded activity entries
        var liveHardOutages = 0
        var liveHardDowntimeS = 0
        var liveHardLongestS = 0

        var liveDisruptions = 0
        var liveDisruptionDowntimeS = 0
        var liveDisruptionLongestS = 0

        for entry in folded {
            guard let ruleID = entry.ruleID else { continue }
            let ongoingElapsed = entry.isOngoing ? max(0, now.timeIntervalSince(entry.latest)) : 0
            let durationS = Int(round((entry.totalDuration ?? 0) + ongoingElapsed))
            if hardOutageRules.contains(ruleID) {
                liveHardOutages += max(1, entry.occurrences)
                liveHardDowntimeS += durationS
                liveHardLongestS = max(liveHardLongestS, durationS)
            } else if severeDisruptionRules.contains(ruleID) {
                liveDisruptions += max(1, entry.occurrences)
                liveDisruptionDowntimeS += durationS
                liveDisruptionLongestS = max(liveDisruptionLongestS, durationS)
            }
        }

        // Fold in stored availability if a scan produced higher confirmed values
        let scanOutages = currentRunAvailability?.outages ?? 0
        let scanDowntime = currentRunAvailability?.downtimeS ?? 0
        let scanLongest = currentRunAvailability?.longestOutageS ?? 0

        let effectiveOutages: Int
        let effectiveDowntime: Int
        let effectiveLongest: Int
        let countText: String

        if liveHardOutages > 0 || scanOutages > 0 {
            effectiveOutages = max(liveHardOutages, scanOutages)
            effectiveDowntime = max(liveHardDowntimeS, scanDowntime)
            effectiveLongest = max(liveHardLongestS, scanLongest)
            countText = effectiveOutages == 1 ? "1 outage" : "\(effectiveOutages) outages"
        } else if liveDisruptions > 0 {
            effectiveOutages = liveDisruptions
            effectiveDowntime = liveDisruptionDowntimeS
            effectiveLongest = liveDisruptionLongestS
            countText = effectiveOutages == 1 ? "1 drop" : "\(effectiveOutages) drops"
        } else if heartbeatMisses > 5 && heartbeatTotal > 10 {
            effectiveOutages = heartbeatMisses
            effectiveDowntime = heartbeatMisses // rough 1s per miss
            effectiveLongest = 1
            countText = "\(heartbeatMisses) drops"
        } else {
            effectiveOutages = 0
            effectiveDowntime = 0
            effectiveLongest = 0
            countText = "0 outages"
        }

        let downtimeText = formatSeconds(effectiveDowntime)
        let longestText = formatSeconds(effectiveLongest)
        let summary = buildObservationSummary(
            networkEvents: networkEvents,
            allRecentEvents: allRecentEvents,
            currentRunAvailability: currentRunAvailability,
            networkConnectedAt: networkConnectedAt,
            heartbeatTotal: heartbeatTotal,
            now: now
        )

        return Result(
            outageCountText: countText,
            totalDowntimeText: downtimeText,
            longestOutageText: longestText,
            observationSummary: summary,
            outages: effectiveOutages,
            downtimeSeconds: effectiveDowntime,
            longestOutageSeconds: effectiveLongest
        )
    }

    static func formatSeconds(_ s: Int) -> String {
        if s <= 0 { return "0s" }
        let mins = s / 60
        let secs = s % 60
        if mins > 0 {
            return "\(mins)m \(secs)s"
        }
        return "\(secs)s"
    }

    private static func buildObservationSummary(
        networkEvents: [NetworkEvent],
        allRecentEvents: [NetworkEvent],
        currentRunAvailability: RunSnapshot.Availability?,
        networkConnectedAt: Date?,
        heartbeatTotal: Int,
        now: Date
    ) -> String {
        if let unobserved = currentRunAvailability?.unobservedPct {
            if unobserved >= 99 {
                if !networkEvents.isEmpty || heartbeatTotal > 0 {
                    return "Monitoring active · Listening for disruptions"
                }
                return "Monitoring started recently · Listening for disruptions"
            } else if unobserved > 0 {
                let observedPct = max(1, 100 - unobserved)
                let observedHours = Double(24 * observedPct) / 100.0
                if observedHours >= 1.0 {
                    return String(format: "Last 24h · Monitored for ~%.0fh (%d%% offline or asleep)", observedHours, unobserved)
                } else {
                    let observedMins = max(1, Int(round(observedHours * 60)))
                    return "Last 24h · Monitored for ~\(observedMins)m (\(unobserved)% offline or asleep)"
                }
            } else {
                return "Last 24 hours · Continuously monitored"
            }
        }

        // Live calculation from event timestamps
        let dates = networkEvents.compactMap { $0.date > .distantPast ? $0.date : nil }
        if let earliest = dates.min() {
            let spanS = max(1.0, now.timeIntervalSince(earliest))
            let spanHours = spanS / 3600.0
            if spanHours >= 1.0 {
                let bounded = min(24.0, spanHours)
                return String(format: "Last 24h · Monitored for ~%.0fh", bounded)
            } else {
                let spanMins = max(1, Int(round(spanS / 60.0)))
                return "Last 24h · Monitored for ~\(spanMins)m"
            }
        }

        // If no events on this network yet, check how recently we connected
        if let connected = networkConnectedAt {
            let connectedMins = Int(now.timeIntervalSince(connected) / 60.0)
            if connectedMins < 60 {
                let mins = max(1, connectedMins)
                if !allRecentEvents.isEmpty {
                    return "Joined \(mins)m ago · Monitoring active"
                }
                return "Joined \(mins)m ago · Listening for disruptions"
            }
        }

        if heartbeatTotal > 30 {
            return "Last 24 hours · Continuously monitored"
        }

        return "Monitoring active · Listening for disruptions"
    }
}
