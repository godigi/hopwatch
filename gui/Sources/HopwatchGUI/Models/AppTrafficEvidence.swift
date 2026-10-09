import Foundation

/// A contemporaneous monitor capture, persisted unchanged with the event.
struct AppTrafficEvidence: Codable, Sendable, Equatable {
    var appName: String?
    var appBundle: String?
    var process: String?
    var direction: String?
    var rateMbps: Double?
    var dominancePct: Double?
    var observedAt: String?
    var gatewayRttMs: Double?
    var gatewayJitterMs: Double?
    var internetJitterMs: Double?

    enum CodingKeys: String, CodingKey {
        case appName = "app_name", appBundle = "app_bundle", process, direction
        case rateMbps = "rate_mbps", dominancePct = "dominance_pct", observedAt = "observed_at"
        case gatewayRttMs = "gateway_rtt_ms", gatewayJitterMs = "gateway_jitter_ms"
        case internetJitterMs = "internet_jitter_ms"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appName = c.lenient(.appName); appBundle = c.lenient(.appBundle)
        process = c.lenient(.process); direction = c.lenient(.direction)
        rateMbps = c.lenient(.rateMbps); dominancePct = c.lenient(.dominancePct)
        observedAt = c.lenient(.observedAt); gatewayRttMs = c.lenient(.gatewayRttMs)
        gatewayJitterMs = c.lenient(.gatewayJitterMs); internetJitterMs = c.lenient(.internetJitterMs)
    }

    var identity: String { appBundle ?? process ?? "unidentified" }
    var captureKey: String { identity + "|" + (direction ?? "") }
    var observedDate: Date? { observedAt.flatMap { ISO8601DateFormatter().date(from: $0) } }
    var name: String { appName ?? process ?? "Unidentified process" }

    var detail: String {
        var parts = [name]
        if let rate = rateMbps, rate.isFinite, rate >= 0 {
            let verb = direction == "up" ? "uploading" : direction == "down" ? "downloading" : "transferring"
            parts.append("\(verb) \(rate.formatted(.number.precision(.fractionLength(0...1)))) Mbps")
        }
        if let share = dominancePct, share.isFinite, (0...100).contains(share) {
            parts.append("\(Int(share.rounded()))% of Mac's \(direction == "up" ? "upload" : "download") traffic")
        }
        if appName == nil { parts.append("app unidentified") }
        if let date = observedDate { parts.append("observed \(date.formatted(date: .omitted, time: .shortened))") }
        return parts.joined(separator: " · ")
    }

    var latencyDetail: String? {
        var parts: [String] = []
        for (label, value) in [("Router ping", gatewayRttMs), ("router jitter", gatewayJitterMs),
                               ("internet jitter", internetJitterMs)] {
            if let value, value.isFinite, value >= 0 {
                parts.append("\(label) \(value.formatted(.number.precision(.fractionLength(0...1)))) ms")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
