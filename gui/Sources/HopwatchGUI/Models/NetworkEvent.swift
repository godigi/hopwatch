import Foundation

/// One thing that changed, as told by the CLI — a monitor `changes`
/// entry or a fired alert. The GUI stores and renders these; it never
/// authors the summary text.
///
/// A stored record (persisted to `events.json`), so every property is
/// `var` with an inline default and decodes leniently — the same
/// discipline `MonitorSample` and `RunSnapshot` follow, for the same
/// reason: a key this app doesn't know about yet must degrade to "not
/// recorded", not fail the whole decode.
struct NetworkEvent: Codable, Identifiable, Sendable, Equatable {
    var id = UUID()
    var date: Date = .distantPast
    /// Stream change kind ("vpn-disconnected", "rule-fired", …) or
    /// "alert" for alert-engine events. Drives icon/tint mapping only.
    var kind: String = ""
    var summary: String = ""
    var ruleID: String? = nil
    /// The network this event occurred on (e.g. "wifi:mac=…"), matching
    /// the event journal and helpers/events.py.
    var network: String? = nil

    init(id: UUID = UUID(), date: Date, kind: String,
         summary: String, ruleID: String? = nil, network: String? = nil) {
        self.id = id
        self.date = date
        self.kind = kind
        self.summary = summary
        self.ruleID = ruleID
        self.network = network
    }
}

extension NetworkEvent {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id, UUID())
        date = c.lenient(.date, .distantPast)
        kind = c.lenient(.kind, "")
        summary = c.lenient(.summary, "")
        ruleID = c.lenient(.ruleID)
        network = c.lenient(.network)
    }
}

extension NetworkEvent {
    /// Newest-first, capped. Pure so the test target can hit it.
    static func trimmed(_ events: [NetworkEvent], cap: Int) -> [NetworkEvent] {
        Array(events.sorted { $0.date > $1.date }.prefix(cap))
    }

    /// Interval since the newest network change, or nil when there is none.
    /// Excludes internal monitor-started lifecycle events so monitor restarts
    /// do not reset the headline reassurance time.
    static func timeSinceLast(_ events: [NetworkEvent],
                              now: Date) -> TimeInterval? {
        let meaningful = events.filter { $0.kind != "monitor-started" }
        guard let newest = meaningful.map(\.date).max() else { return nil }
        return now.timeIntervalSince(newest)
    }

    static func within(_ events: [NetworkEvent], hours: Double,
                       now: Date) -> [NetworkEvent] {
        let cutoff = now.addingTimeInterval(-hours * 3600)
        return events.filter { $0.date >= cutoff }
    }

    /// A flapping condition or a resume-from-sleep burst repeats the
    /// same CLI phrase; storing every copy would evict real history.
    /// `events` must be newest-first (EventStore's invariant): the scan
    /// stops at the first entry older than the window. Events on different
    /// networks are never coalesced.
    static func isRepeat(kind: String, summary: String, network: String? = nil,
                         date: Date, in events: [NetworkEvent],
                         window: TimeInterval = 600) -> Bool {
        for event in events {
            if date.timeIntervalSince(event.date) > window { break }
            if event.kind == kind && event.summary == summary && event.network == network {
                return true
            }
        }
        return false
    }
}
