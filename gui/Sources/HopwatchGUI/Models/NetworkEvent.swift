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
    /// Only meaningful on "monitor-started". True when this app restarted
    /// its own monitor (a cadence change, the start or end of an
    /// investigation burst) while it was running throughout, on the same
    /// network — so the restart says nothing about whether a fault that was
    /// open went away. False is the default and means a real observation
    /// boundary: the app was launched, monitoring was switched off and on,
    /// the monitor died, or the network changed. Stored events from before
    /// this existed decode as false, which is how they were always read.
    var continuesPrevious: Bool = false

    init(id: UUID = UUID(), date: Date, kind: String,
         summary: String, ruleID: String? = nil, network: String? = nil,
         continuesPrevious: Bool = false) {
        self.id = id
        self.date = date
        self.kind = kind
        self.summary = summary
        self.ruleID = ruleID
        self.network = network
        self.continuesPrevious = continuesPrevious
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
        continuesPrevious = c.lenient(.continuesPrevious, false)
    }
}

extension NetworkEvent {
    /// Whether a freshly started monitor carries on from the one before it,
    /// for the "monitor-started" marker `ActivityEntry.fold` reads.
    ///
    /// `appRestarted` is the app saying it did this itself, while running
    /// (`MonitorStream.restart()`); an app launch, a switch-off and on, and
    /// a crash recovery are not that. A restart the app caused is no
    /// evidence a fault ended, and the app knows it caused it — which is
    /// why this needs no window or cutoff, unlike the CLI's reader of the
    /// journal, which cannot know who restarted what.
    ///
    /// A network *known* to differ across the restart is a boundary
    /// whatever caused it: the fault was on the other network. An unknown
    /// side does not count as different — the first sample can arrive before
    /// the CLI has identified the network, and treating that as a move would
    /// cut the fault in two.
    static func continuesPrevious(appRestarted: Bool,
                                  previousNetwork: String?,
                                  currentNetwork: String?) -> Bool {
        guard appRestarted else { return false }
        if let previousNetwork, let currentNetwork {
            return previousNetwork == currentNetwork
        }
        return true
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
        var newest: Date?
        for event in events where event.kind != "monitor-started" {
            if newest == nil || event.date > newest! {
                newest = event.date
            }
        }
        guard let newest else { return nil }
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
