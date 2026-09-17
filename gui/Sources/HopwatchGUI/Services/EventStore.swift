import Foundation
import OSLog

/// The dropdown's change timeline and the "nothing has changed in N"
/// headline both read from here. Events come from the monitor stream's
/// `changes` array and from fired alerts; the monitor itself writes
/// nothing to disk (its contract), so durable memory lives GUI-side.
@MainActor
@Observable
final class EventStore {
    static let cap = 500

    private(set) var events: [NetworkEvent] = []

    private let log = Logger(subsystem: "me.brianfreeman.hopwatch",
                             category: "events")
    private let url: URL?

    init(directory: URL? = nil) {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
        let dir = directory ?? appSupport?
            .appendingPathComponent(Bundle.main.bundleIdentifier
                                    ?? "me.brianfreeman.hopwatch",
                                    isDirectory: true)
        if let dir {
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
            let fileURL = dir.appendingPathComponent("events.json")

            // If no events file exists yet, migrate legacy netdiag events.json if present
            if !FileManager.default.fileExists(atPath: fileURL.path),
               let legacyDir = appSupport?.appendingPathComponent("me.brianfreeman.netdiag", isDirectory: true) {
                let legacyFile = legacyDir.appendingPathComponent("events.json")
                if FileManager.default.fileExists(atPath: legacyFile.path) {
                    try? FileManager.default.copyItem(at: legacyFile, to: fileURL)
                }
            }

            url = fileURL
        } else {
            url = nil
        }
        load()
    }

    func record(kind: String, summary: String, ruleID: String? = nil,
                network: String? = nil,
                date: Date = .now) {
        guard !summary.isEmpty else { return }
        // A monitor restart is an observation boundary, never a repeat.
        // It must not be coalesced by isRepeat, or a restart within the
        // 10-minute window would lose its restart signal.
        if kind != "monitor-started" {
            guard !NetworkEvent.isRepeat(kind: kind, summary: summary,
                                         network: network,
                                         date: date, in: events) else {
                return
            }
        }
        events = NetworkEvent.trimmed(
            events + [NetworkEvent(date: date, kind: kind,
                                   summary: summary, ruleID: ruleID,
                                   network: network)],
            cap: Self.cap)
        save()
    }

    func within(hours: Double, now: Date = .now) -> [NetworkEvent] {
        NetworkEvent.within(events, hours: hours, now: now)
    }

    /// Rewrites rule events stored before the CLI learned to phrase them
    /// from the rules catalog, so an upgrade doesn't leave "Issue G2
    /// cleared" sitting in the timeline forever. `title` resolves a rule
    /// ID to the catalog's own wording — the prose still comes from the
    /// CLI, this only replaces the ID-shaped placeholder it superseded.
    func rephraseLegacyRuleEvents(title: (String) -> String?) {
        var changed = false
        events = events.map { event in
            guard let ruleID = event.ruleID,
                  event.summary == "Issue \(ruleID) detected"
                    || event.summary == "Issue \(ruleID) cleared",
                  let title = title(ruleID) else { return event }
            var rewritten = event
            rewritten.summary = event.kind == "rule-cleared"
                ? "Resolved: \(title)" : title
            changed = true
            return rewritten
        }
        if changed { save() }
    }

    /// The newest event describing a network condition, ignoring internal
    /// monitor-started restart markers.
    var latestNetworkEvent: NetworkEvent? {
        events.first(where: { $0.kind != "monitor-started" })
    }

    var lastEventDate: Date? { latestNetworkEvent?.date }

    private func load() {
        guard let url else { return }
        // No file yet is the ordinary first-launch case — not worth a
        // log line, unlike a file that exists but won't decode.
        guard let data = try? Data(contentsOf: url) else { return }
        guard let stored = try? JSONDecoder().decode([NetworkEvent].self,
                                                     from: data) else {
            log.error("events.json exists but failed to decode — starting with an empty log")
            return
        }
        events = NetworkEvent.trimmed(stored, cap: Self.cap)
    }

    private func save() {
        guard let url, let data = try? JSONEncoder().encode(events)
        else { return }
        try? data.write(to: url, options: .atomic)
    }
}
