import Foundation

/// Saved-check row preparation shared by the dashboard and its evidence regressions.
enum DashboardCheckEvidence {
    /// A missing probe is never a measured zero or a successful verdict.
    static func requiringMeasurement(_ row: DashboardCheckTable.Row, hasMeasurement: Bool,
                                     usual: String? = nil) -> DashboardCheckTable.Row {
        .init(id: row.id, icon: hasMeasurement ? row.icon : "questionmark.circle", label: row.label,
              measured: hasMeasurement ? row.measured : "—",
              subvalue: hasMeasurement ? row.subvalue : nil,
              usual: usual ?? row.usual,
              badge: hasMeasurement ? row.badge : .init(label: "Not measured", tone: .neutral),
              isWarning: hasMeasurement && row.isWarning, isGood: hasMeasurement && row.isGood)
    }
    static func wifiChannel(snapshot snap: RunSnapshot?, channel: String?, fallbackChannel bandChannelText: String) -> DashboardCheckTable.Row {
        let neighborCount = snap?.wifiScan?.currentChannelNeighbours
        let isCrowded = snap?.diagnosis.contains { $0.rule == "WS-1" } ?? false
        let hasVerdict = isCrowded || neighborCount != nil
        let channelText = channel != nil ? "\(channel!)" : (bandChannelText.isEmpty ? "—" : bandChannelText)
        let channelBadge = DashboardCheckTable.GradeBadge(
            label: hasVerdict ? (isCrowded ? "Crowded" : "Clear") : "Unknown",
            tone: hasVerdict ? (isCrowded ? .warn : .good) : .neutral
        )
        return .init(
            id: "wifi-channel",
            icon: isCrowded ? "antenna.radiowaves.left.and.right.slash" : "antenna.radiowaves.left.and.right",
            label: "Wi-Fi channel",
            measured: channelText,
            subvalue: neighborCount.map { "\($0) neighboring networks" },
            usual: "—",
            badge: channelBadge,
            isWarning: isCrowded,
            isGood: hasVerdict && !isCrowded
        )
    }

    static func dns(snapshot snap: RunSnapshot?) -> DashboardCheckTable.Row {
        let dnsTotal = snap?.dns.count ?? 0
        guard dnsTotal > 0 else {
            return unmeasuredRow(id: "dns", icon: "network", label: "Name lookups (DNS)", snapshot: snap)
        }
        let dnsOk = snap?.dns.filter(\.ok).count ?? 0
        let dnsText = "\(dnsOk) of \(dnsTotal) resolvers OK"
        let dnsBadge = DashboardCheckTable.GradeBadge(
            label: (dnsTotal > 0 && dnsOk < dnsTotal) ? "Degraded" : "Good",
            tone: (dnsTotal > 0 && dnsOk < dnsTotal) ? .warn : .good
        )
        return .init(
            id: "dns",
            icon: dnsTotal > 0 && dnsOk < dnsTotal ? "exclamationmark.triangle.fill" : "checkmark",
            label: "Name lookups (DNS)",
            measured: dnsText,
            subvalue: nil,
            usual: "—",
            badge: dnsBadge,
            isWarning: dnsTotal > 0 && dnsOk < dnsTotal,
            isGood: dnsOk == dnsTotal
        )
    }

    static func bufferbloat(snapshot snap: RunSnapshot?) -> DashboardCheckTable.Row {
        let bb = snap?.bufferbloat
        let bbRouterGrade = bb?.gwGrade.flatMap(nonempty)
        let bbInetGrade = bb?.inetGrade.flatMap(nonempty)
        guard bbRouterGrade != nil || bbInetGrade != nil || bb?.gwDeltaMs != nil || bb?.inetDeltaMs != nil else {
            return unmeasuredRow(id: "bufferbloat", icon: "waveform.path", label: "Lag under load", snapshot: snap)
        }
        let bbBadge = DashboardCheckTable.GradeBadge(
            label: bbInetGrade.map { "Grade \($0)" } ?? "Unknown",
            tone: bbInetGrade == nil ? .neutral : ((bbInetGrade == "A" || bbInetGrade == "B") ? .good : (bbInetGrade == "C" ? .warn : .critical))
        )
        return .init(
            id: "bufferbloat",
            icon: bbInetGrade == nil ? "waveform.path" : (bbInetGrade == "D" || bbInetGrade == "F" ? "exclamationmark.triangle.fill" : "checkmark"),
            label: "Lag under load",
            measured: loadedMeasurement(label: "Router", grade: bbRouterGrade, deltaMs: bb?.gwDeltaMs),
            subvalue: loadedMeasurement(label: "Internet", grade: bbInetGrade, deltaMs: bb?.inetDeltaMs),
            usual: "+3 ms router",
            badge: bbBadge,
            isWarning: bbInetGrade == "D" || bbInetGrade == "F",
            isGood: bbInetGrade != nil && bbInetGrade != "D" && bbInetGrade != "F"
        )
    }

    static func web(snapshot snap: RunSnapshot?) -> DashboardCheckTable.Row {
        guard let targets = snap?.tcpReach, !targets.isEmpty else {
            return unmeasuredRow(id: "web", icon: "network", label: "Web connections", snapshot: snap)
        }
        let webOk = targets.contains { $0.ok }
        let webBadge = DashboardCheckTable.GradeBadge(
            label: webOk ? "Good" : "Blocked",
            tone: webOk ? .good : .critical
        )
        return .init(
            id: "web",
            icon: webOk ? "checkmark" : "exclamationmark.triangle.fill",
            label: "Web connections",
            measured: webOk ? "TCP 443 reachable" : "TCP 443 blocked",
            subvalue: nil,
            usual: "—",
            badge: webBadge,
            isWarning: !webOk,
            isGood: webOk
        )
    }

    static func loadedRTT(snapshot: RunSnapshot?) -> String {
        guard snapshot?.bufferbloat.gwDeltaMs != nil || snapshot?.bufferbloat.inetDeltaMs != nil else {
            return "Not measured"
        }
        let gw = snapshot?.bufferbloat.gwDeltaMs.map { "\(Int($0)) ms" } ?? "—"
        let inet = snapshot?.bufferbloat.inetDeltaMs.map { "\(Int($0)) ms" } ?? "—"
        return "router \(gw) / internet \(inet)"
    }

    private static func unmeasuredRow(id: String, icon: String, label: String, snapshot: RunSnapshot?) -> DashboardCheckTable.Row {
        .init(
            id: id,
            icon: icon,
            label: label,
            measured: snapshot == nil ? "Awaiting check" : "Not measured in this check",
            usual: "—",
            badge: .init(label: snapshot == nil ? "Unknown" : "Skipped", tone: .neutral)
        )
    }

    private static func nonempty(_ text: String) -> String? {
        text.isEmpty ? nil : text
    }

    private static func loadedMeasurement(label: String, grade: String?, deltaMs: Double?) -> String {
        let gradeText = grade.map { " \($0)" } ?? ""
        let deltaText = deltaMs.map { String(format: " (+%.0f ms)", $0) } ?? ""
        return grade == nil && deltaMs == nil ? "\(label) —" : "\(label)\(gradeText)\(deltaText)"
    }
}
