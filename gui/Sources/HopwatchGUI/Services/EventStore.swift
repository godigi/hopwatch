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

    private let log = Logger(subsystem: "com.godigi.hopwatch",
                             category: "events")
    private let url: URL?

    init(directory: URL? = nil) {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
        let dir = directory ?? appSupport?
            .appendingPathComponent(Bundle.main.bundleIdentifier
                                    ?? "com.godigi.hopwatch",
                                    isDirectory: true)
        if let dir {
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
            let fileURL = dir.appendingPathComponent("events.json")

            // If no events file exists yet, migrate legacy events.json if present
            if !FileManager.default.fileExists(atPath: fileURL.path), let appSupport {
                if let entries = try? FileManager.default.contentsOfDirectory(at: appSupport, includingPropertiesForKeys: nil) {
                    for legacyDir in entries where legacyDir.hasDirectoryPath {
                        let name = legacyDir.lastPathComponent
                        if (name.hasSuffix(".hopwatch") || name.hasSuffix(".netdiag")) && name != "com.godigi.hopwatch" {
                            let legacyFile = legacyDir.appendingPathComponent("events.json")
                            if FileManager.default.fileExists(atPath: legacyFile.path) {
                                try? FileManager.default.copyItem(at: legacyFile, to: fileURL)
                                break
                            }
                        }
                    }
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
                date: Date = .now,
                continuesPrevious: Bool = false,
                evidence: AppTrafficEvidence? = nil,
                fromValue: String? = nil,
                toValue: String? = nil,
                extraDetail: String? = nil) {
        guard !summary.isEmpty else { return }
        if kind == "rule-updated", let evidence {
            // Keep the opening and each distinct app, but replace repeated
            // sightings of that app in this episode. Minute-by-minute captures
            // must not consume the 500-event history in a few hours.
            for event in events {
                if event.kind == "monitor-started" && !event.continuesPrevious { break }
                guard event.network == network, event.ruleID == ruleID else { continue }
                if event.kind == "rule-cleared" { break }
                if event.kind == "rule-updated", event.evidence?.captureKey == evidence.captureKey {
                    events.removeAll { $0.id == event.id }
                    break
                }
            }
        }
        // A monitor restart is an observation boundary, never a repeat.
        // It must not be coalesced by isRepeat, or a restart within the
        // 10-minute window would lose its restart signal.
        if kind != "monitor-started" && kind != "rule-fired" && kind != "rule-cleared" && evidence == nil {
            guard !NetworkEvent.isRepeat(kind: kind, summary: summary,
                                         network: network,
                                         date: date, in: events) else {
                return
            }
        }
        events = NetworkEvent.trimmed(
            events + [NetworkEvent(date: date, kind: kind,
                                   summary: summary, ruleID: ruleID,
                                   network: network,
                                   continuesPrevious: continuesPrevious,
                                   evidence: evidence,
                                   fromValue: fromValue,
                                   toValue: toValue,
                                   extraDetail: extraDetail)],
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

    /// The newest event describing a network condition, on *any* network,
    /// ignoring internal monitor-started restart markers. Not for display:
    /// an unlabelled event from the network you were on an hour ago reads
    /// as being about this one. Screens use
    /// `HopwatchCoordinator.latestCurrentNetworkEvent`.
    var latestNetworkEvent: NetworkEvent? {
        NetworkEvent.latestCondition(in: events)
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

    private let writer = EventWriter()

    private func save() {
        guard let url else { return }
        writer.submit(events, to: url)
    }

    /// Writes any snapshot still waiting for the background writer, and
    /// returns only when it is on disk. Called on quit: the writer runs on a
    /// utility queue, and an event recorded in the last moments (the outage
    /// that made the user quit, say) would otherwise die with the process.
    func flush() { writer.flush() }
}

/// Writes the event log one snapshot at a time, newest wins.
///
/// `save()` used to spawn a detached task per call. Two calls close together
/// (a rule firing and clearing in one sample) wrote concurrently, and the
/// older snapshot could land last — silently dropping the newest event from
/// disk. Here at most one write runs at a time, and anything submitted while
/// it runs replaces the single waiting snapshot, so the file always ends on
/// the latest state and a burst costs two writes, not fifty.
private final class EventWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: (events: [NetworkEvent], url: URL)?
    private var draining = false

    func submit(_ events: [NetworkEvent], to url: URL) {
        lock.lock()
        pending = (events, url)
        let startDrain = !draining
        draining = true
        lock.unlock()
        guard startDrain else { return }
        DispatchQueue.global(qos: .utility).async { [self] in drain() }
    }

    /// Serialises disk writes *and* the choice of which snapshot to write:
    /// whoever holds it takes the newest pending snapshot, so an older one
    /// can never land after a newer one — not from `drain()`, not from
    /// `flush()`.
    private let writeLock = NSLock()

    private func drain() {
        while true {
            writeLock.lock()
            lock.lock()
            guard let next = pending else {
                draining = false
                lock.unlock()
                writeLock.unlock()
                return
            }
            pending = nil
            lock.unlock()
            if let data = try? JSONEncoder().encode(next.events) {
                try? data.write(to: next.url, options: .atomic)
            }
            writeLock.unlock()
        }
    }

    /// Synchronous: writes the waiting snapshot (if any) on the calling
    /// thread, after any write already in flight has finished.
    func flush() {
        writeLock.lock()
        defer { writeLock.unlock() }
        lock.lock()
        let next = pending
        pending = nil
        lock.unlock()
        guard let next, let data = try? JSONEncoder().encode(next.events) else { return }
        try? data.write(to: next.url, options: .atomic)
    }
}
