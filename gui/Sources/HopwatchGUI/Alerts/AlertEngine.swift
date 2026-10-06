import Foundation
import UserNotifications
import os

/// Decides *whether and when* to notify. It never decides what is wrong.
///
/// The split is the whole architecture: lib/monitor.sh and lib/diagnosis.sh
/// say which rules fired, this file says which of those are worth
/// interrupting someone over. Nothing here reads a measurement or compares
/// it to a number.
///
/// Each alert runs a small state machine:
///
///   idle ──condition holds for `dwell`──▶ firing ──notify──▶ active
///     ▲                                                        │
///     └──────────── condition absent, `resolves` ◀─────────────┘
///
/// plus a `cooldown` that suppresses a repeat notification of an alert that
/// is already known, and four global suppressors that hold everything.
@MainActor
@Observable
final class AlertEngine {

    /// One alert currently raised, for the dropdown's banner.
    struct ActiveAlert: Identifiable, Sendable {
        let id: String
        let title: String
        var body: String
        var raisedAt: Date
        /// Where `body` came from, and so whether it may still change.
        ///
        /// The holding line is a promise that a check is under way, so it
        /// is only ever the body in `.awaitingScan` — a state the engine
        /// leaves the instant the scan lands, fails, is cancelled, or turns
        /// out never to have been started. What replaces it is always the
        /// CLI's text (`ruleText` or a scan's `diagnosis[].summary`), with
        /// two mechanism-only fallbacks for when the catalog has nothing.
        enum BodyState: Sendable, Equatable {
            /// `interimBody`, shown because a scan that could enrich this
            /// alert is pending or running right now.
            case awaitingScan
            /// No scan was started for this alert — auto-scan is off, the
            /// loop guard declined, or it was raised inside its cooldown.
            case settledNoScan
            /// The scan this alert was waiting on has ended without a
            /// sentence for it: landed with no matching rule, failed, or
            /// was cancelled.
            case settledScanEnded
            /// `diagnosis[].summary`, verbatim. Terminal.
            case enriched
            /// An event-driven alert (no rules): its body is the
            /// definition's own line and no scan can improve on it.
            case fixed
        }
        var bodyState: BodyState = .awaitingScan
        /// Set once a triggered scan lands and replaces the holding text
        /// with the CLI's own prose.
        var enrichedByScan: Bool { bodyState == .enriched }
        /// A settled body is the catalog's blurb when there is one and a
        /// mechanism-only fallback when there is not (the catalog loads
        /// asynchronously). Only the latter is worth revisiting.
        var settledFromCatalog = false
        var isSettled: Bool { bodyState == .settledNoScan || bodyState == .settledScanEnded }
        /// The rule IDs that **actually fired**, not the whole set this
        /// alert listens for — empty for the four event-driven alerts (VPN
        /// dropped, public IP changed, ...) that have no rule at all.
        ///
        /// The distinction is load-bearing and used to be wrong: this was
        /// assigned `def.rules`, so `internet-degraded` (which listens for
        /// L1 *and* L2) always reported L1. That made the attribution line
        /// name a critical rule for a warn condition, made `activeSorted`
        /// rank every such alert critical, and — via `def.rules.first` on
        /// an unordered Set — recorded the same alert in the event log as
        /// L1 on one run and L2 on the next. Everything downstream that
        /// asks "how bad is this?" reads these IDs, so they have to be the
        /// ones the CLI actually reported.
        var rules: Set<String> = []
    }

    private(set) var active: [String: ActiveAlert] = [:]
    var notificationManager: NotificationManager

    var notificationsAuthorized: Bool {
        notificationManager.isAuthorized
    }

    var notificationsDenied: Bool {
        notificationManager.isDenied
    }

    init(notificationManager: NotificationManager? = nil) {
        self.notificationManager = notificationManager ?? NotificationManager()
    }

    /// Set by the app when a scan starts, so alerts are held rather than
    /// fired against measurements the app's own traffic is distorting.
    var scanInProgress = false
    /// Set from the display-sleep / battery / user-toggle paths.
    var monitoringPaused = false
    /// Supplied by NetworkEventWatcher: true for 30 s after any network
    /// transition.
    var inNetworkGracePeriod: () -> Bool = { false }
    /// Injected by `NetdiagCoordinator` once the rules catalog has a
    /// version to answer from: rule ID in, the catalog's severity rank out
    /// (higher is worse). Default ranks everything 0 — before the catalog
    /// loads, `activeSorted` degrades to raised-time order rather than
    /// pretending to know which alert is worse.
    @ObservationIgnored var severityRank: (String) -> Int = { _ in 0 }

    /// Raised when an alert fires and the user has auto-scan on. The app
    /// wires this to NetdiagRunner; the loop guard lives there.
    /// Carries the *firing* rule IDs alongside the definition, so the
    /// timeline entry the app writes names the rule the CLI reported rather
    /// than an arbitrary member of the listen-set. See `ActiveAlert.rules`.
    var onAlertFired: ((AlertDefinition, Set<String>) -> Bool)?

    /// Rule ID in, the rules catalog's plain-language blurb out. Injected by
    /// `NetdiagCoordinator` like `severityRank`, and read live for the same
    /// reason: before the catalog loads this answers nil and the engine
    /// falls back to a mechanism-only line (see `AlertDefinition`'s header),
    /// then upgrades the body the first sample after the catalog arrives.
    @ObservationIgnored var ruleText: (String) -> String? = { _ in nil }

    /// The clock, injectable so `--verify` can walk an alert through its
    /// dwell and cooldown without waiting minutes for them.
    @ObservationIgnored var now: () -> Date = { Date() }

    private var conditionSince: [String: Date] = [:]
    private var lastNotifiedAt: [String: Date] = [:]
    private var firedForNetwork: [String: Set<String>] = [:]
    private var previousSample: MonitorSample?
    private let log = Logger(subsystem: "com.godigi.hopwatch", category: "alerts")

    // MARK: - Permission

    func requestAuthorization() async {
        await notificationManager.requestAuthorization()
    }

    func requestOrOpenSettings() async {
        await notificationManager.requestOrOpenSettings()
    }

    func refreshAuthorization() async {
        await notificationManager.refreshAuthorization()
    }

    func openSystemSettings() {
        notificationManager.openSystemSettings()
    }

    // MARK: - Global suppressors
    //
    // Each of these prevents a distinct class of false alarm, and each was
    // chosen because the alternative is an alert that is *always* wrong
    // rather than occasionally wrong.

    private func suppressed(_ def: AlertDefinition, sample: MonitorSample?) -> String? {
        if !Defaults.isAlertEnabled(def.id) { return "disabled by user" }
        // A scan saturates the link on purpose (speed test, bufferbloat).
        // Alerting on latency the app itself caused is the worst possible
        // false positive: it is self-inflicted and perfectly reproducible.
        if scanInProgress { return "a check is running" }
        if monitoringPaused { return "monitoring paused" }
        // DHCP, DNS and the default route land a beat apart after a switch.
        // Probes in the first seconds measure a half-configured stack.
        if inNetworkGracePeriod() { return "network just changed" }
        // TCP-1: real connections work, only ping is being dropped. Hotel
        // and corporate networks block ICMP wholesale, and without this a
        // loss alert there fires constantly and is never once correct.
        if def.suppressedByICMPFilter, sample?.status.icmpFiltered == true {
            return "ICMP filtered (TCP-1)"
        }
        return nil
    }

    // MARK: - Live evaluation

    func evaluate(sample: MonitorSample) {
        defer { previousSample = sample }
        let now = self.now()
        let networkKey = sample.network.id ?? "unknown"

        // The catalog loads after the first alerts can fire; this is the
        // cheapest place to notice it has, and a sample arrives every few
        // seconds.
        refreshSettledBodies()

        let firing = Set(sample.status.rules)
        for def in AlertDefinition.liveAlerts {
            let holds = conditionHolds(def, sample: sample, previous: previousSample)
            step(def, holds: holds, now: now, networkKey: networkKey, sample: sample,
                 firingRules: def.rules.intersection(firing))
        }
    }

    /// Which live alerts a sample raises. Rule-driven where a rule exists;
    /// the four event-driven ones read a transition instead, because "your
    /// VPN dropped" is a change rather than a state and no rule can say it.
    private func conditionHolds(_ def: AlertDefinition,
                                sample: MonitorSample,
                                previous: MonitorSample?) -> Bool {
        switch def.id {
        case "public-ip-changed":
            guard let prev = previous,
                  let old = prev.publicInfo.ip, let new = sample.publicInfo.ip,
                  !old.isEmpty, !new.isEmpty else { return false }
            return old != new

        case "captive-portal":
            return sample.publicInfo.captivePortal == true

        case "vpn-dropped":
            guard let prev = previous else { return false }
            return prev.vpn.active && !sample.vpn.active

        case "different-network":
            // Same Wi-Fi name, different router behind it. Only meaningful
            // when the SSID is actually visible — without Location
            // Services macOS hides it, and comparing two nils would fire
            // this on every gateway the machine ever sees.
            guard let prev = previous,
                  let prevSSID = prev.link.ssid, let ssid = sample.link.ssid,
                  !prevSSID.isEmpty, prevSSID == ssid,
                  let prevMAC = prev.link.gatewayMAC, let mac = sample.link.gatewayMAC,
                  !prevMAC.isEmpty else { return false }
            return prevMAC != mac

        default:
            return !def.rules.isDisjoint(with: Set(sample.status.rules))
        }
    }

    // MARK: - Scan evaluation

    /// Scan-only alerts, plus the enrichment pass that replaces a live
    /// alert's holding text with the CLI's own prose.
    func evaluate(run: RunSnapshot) {
        let now = self.now()
        let networkKey = run.network.id ?? "unknown"
        let firedRules = Set(run.diagnosis.compactMap(\.rule))

        for def in AlertDefinition.scanAlerts {
            step(def, holds: !def.rules.isDisjoint(with: firedRules),
                 now: now, networkKey: networkKey, sample: nil,
                 bodyOverride: bestSummary(for: def, in: run),
                 firingRules: def.rules.intersection(firedRules))
        }

        // The point of the alert-triggered scan: "Connection is unstable"
        // becomes "You're losing packets between your Mac and your router
        // even though the WiFi signal is strong — the router itself is
        // misbehaving. Try rebooting it (unplug for 30 seconds, plug back
        // in)." The notification updates in place rather than arriving a
        // second time.
        for (id, var alert) in active where !alert.enrichedByScan {
            guard let def = AlertDefinition.byID(id),
                  let summary = bestSummary(for: def, in: run) else { continue }
            alert.body = summary
            alert.bodyState = .enriched
            active[id] = alert
            deliver(id: id, title: alert.title, body: summary, isOutage: def.isOutage, replacing: true)
        }

        // A scan has landed, so no alert is still waiting on it. Whatever
        // the loop above did not enrich — this scan saw a different fault,
        // or none, which is routine for an intermittent one the monitor
        // caught — settles now. A settled alert stays eligible for the loop
        // above, so a *later* scan that does carry a matching sentence
        // still upgrades it.
        settleAwaiting(as: .settledScanEnded)
    }

    /// The scan an alert was waiting on has ended without landing — it
    /// failed, was cancelled, or its result was discarded. Called by the
    /// coordinator when any scan's task finishes, after `evaluate(run:)` has
    /// had its chance, so on the success path this finds nothing left to do.
    func scanEnded() {
        settleAwaiting(as: .settledScanEnded)
    }

    // MARK: - Settling

    /// Replaces the holding line of every alert still showing it. Updates
    /// the dropdown's body only and never notifies: the notification for
    /// this alert was delivered when it fired and said what was true then,
    /// and a second one for "the check is over" would be the engine
    /// narrating its own plumbing. Only a real scan summary re-delivers.
    private func settleAwaiting(as state: ActiveAlert.BodyState) {
        for id in active.keys where active[id]?.bodyState == .awaitingScan {
            settle(id, as: state)
        }
    }

    private func settle(_ id: String, as state: ActiveAlert.BodyState) {
        guard var alert = active[id], alert.bodyState == .awaitingScan else { return }
        alert.bodyState = state
        if let text = catalogText(for: alert.rules) {
            alert.body = text
            alert.settledFromCatalog = true
        } else {
            alert.body = state == .settledNoScan ? Self.noScanBody : Self.scanEndedBody
            alert.settledFromCatalog = false
        }
        active[id] = alert
    }

    /// Re-resolves settled alerts that had to use a fallback because the
    /// catalog had not loaded when they settled.
    private func refreshSettledBodies() {
        for (id, var alert) in active where alert.isSettled && !alert.settledFromCatalog {
            guard let text = catalogText(for: alert.rules) else { continue }
            alert.body = text
            alert.settledFromCatalog = true
            active[id] = alert
        }
    }

    /// The catalog's blurb for the rule that actually fired. When several
    /// did, the most severe by the CLI's own ranking (the one `activeSorted`
    /// uses) wins, with the rule ID as a tiebreak so the same alert never
    /// reads differently from one run to the next — `Set` iteration order is
    /// not stable. Verbatim, never edited.
    private func catalogText(for rules: Set<String>) -> String? {
        let ranked = rules.sorted { a, b in
            let (ra, rb) = (severityRank(a), severityRank(b))
            return ra != rb ? ra > rb : a < b
        }
        for rule in ranked {
            if let text = ruleText(rule), !text.isEmpty { return text }
        }
        return nil
    }

    // These two are the only sentences Swift writes into a settled banner,
    // and only when the catalog has nothing for the rule (not loaded yet,
    // or a rule it does not name). Mechanism only, per `AlertDefinition`'s
    // header: they say whether a check ran, never why the network is
    // misbehaving or what to do about it. Two rather than one because
    // "a check ended" would be untrue of an alert for which none ever ran.
    private static let noScanBody = "No follow-up check was run for this alert."
    private static let scanEndedBody = "The follow-up check has ended."

    /// The CLI's own sentence for this alert: the highest-severity
    /// diagnosis whose rule the alert listens for. Verbatim, never edited.
    private func bestSummary(for def: AlertDefinition, in run: RunSnapshot) -> String? {
        let matching = run.diagnosis.filter { d in
            guard let rule = d.rule else { return false }
            return def.rules.contains(rule)
        }
        for severity in ["critical", "warn", "info"] {
            if let hit = matching.first(where: { $0.severity == severity }) { return hit.summary }
        }
        return nil
    }

    // MARK: - The state machine

    /// `firingRules` is the subset of `def.rules` the CLI reported on this
    /// observation. Empty is legitimate — the four event-driven alerts have
    /// no rules at all — and is distinct from "we didn't look".
    private func step(_ def: AlertDefinition, holds: Bool, now: Date,
                      networkKey: String, sample: MonitorSample?,
                      bodyOverride: String? = nil,
                      firingRules: Set<String> = []) {
        guard holds else {
            conditionSince.removeValue(forKey: def.id)
            if def.resolves, let alert = active.removeValue(forKey: def.id) {
                // Only announce a recovery for something we announced
                // breaking. Silently clearing would leave the user
                // wondering whether it is still wrong.
                deliverResolved(id: def.id, title: alert.title)
            } else {
                active.removeValue(forKey: def.id)
            }
            return
        }

        if let reason = suppressed(def, sample: sample) {
            // Reset the dwell clock. A condition that held only while
            // suppressed has not held in the sense the dwell measures.
            conditionSince.removeValue(forKey: def.id)
            log.debug("\(def.id, privacy: .public) suppressed: \(reason, privacy: .public)")
            // `monitoringPaused` is the one suppressor that means "this
            // alert is no longer current" rather than "hold judgement, we
            // can't measure right now". Scanning and the network-just-
            // changed grace period are both bounded to seconds and a fresh
            // sample re-evaluates the condition honestly the moment either
            // lifts — clearing `active` for those would just make the
            // alert flicker off and back on. Monitoring paused (which also
            // covers monitoring switched off entirely — see
            // `setMonitoring(enabled:)`) has no such guarantee: it can last
            // indefinitely, and while it holds no sample ever arrives to
            // walk this alert through the `!holds` branch above. Without
            // this, pausing monitoring during an active alert left that
            // alert in `active` forever, still feeding `headline` and the
            // dropdown long after pausing made it stale.
            //
            // Removed directly rather than through `deliverResolved`: the
            // alert was suppressed, not resolved, and a "resolved"
            // notification every time someone pauses monitoring would be
            // its own false signal.
            if monitoringPaused {
                active.removeValue(forKey: def.id)
            }
            return
        }

        let since = conditionSince[def.id] ?? now
        conditionSince[def.id] = since
        guard now.timeIntervalSince(since) >= def.dwell else { return }
        guard active[def.id] == nil else { return }

        if def.oncePerNetwork {
            if firedForNetwork[networkKey, default: []].contains(def.id) { return }
            firedForNetwork[networkKey, default: []].insert(def.id)
        } else if let last = lastNotifiedAt[def.id],
                  now.timeIntervalSince(last) < def.cooldown {
            // Still inside the cooldown: track it as active so the
            // dropdown shows it, but do not interrupt again.
            //
            // No scan runs for this raise (the handler below is skipped),
            // so there is nothing a holding line could be waiting for: it
            // is settled on the spot rather than left up indefinitely.
            active[def.id] = ActiveAlert(id: def.id, title: def.title,
                                         body: bodyOverride ?? def.interimBody, raisedAt: now,
                                         bodyState: initialBodyState(def, bodyOverride: bodyOverride),
                                         rules: firingRules)
            settle(def.id, as: .settledNoScan)
            return
        }

        let body = bodyOverride ?? def.interimBody
        active[def.id] = ActiveAlert(id: def.id, title: def.title, body: body,
                                     raisedAt: now,
                                     bodyState: initialBodyState(def, bodyOverride: bodyOverride),
                                     rules: firingRules)
        lastNotifiedAt[def.id] = now
        deliver(id: def.id, title: def.title, body: body, isOutage: def.isOutage, replacing: false)
        log.info("alert fired: \(def.id, privacy: .public)")

        // Only live alerts trigger a scan. A scan-only alert was produced
        // *by* a scan, and scanning again to explain it is the loop the
        // guard in NetdiagCoordinator exists to prevent.
        //
        // The handler says whether a scan actually started, because that is
        // what the holding line's claim rests on. Declined — auto-scan off,
        // loop guard, a scan already in flight — means no check is coming,
        // and the banner settles now. A handler that was never wired counts
        // as declined for the same reason: no scan, no "checking".
        let scanStarted = def.scanOnly ? false : (onAlertFired?(def, firingRules) ?? false)
        if !scanStarted { settle(def.id, as: .settledNoScan) }
    }

    /// `.awaitingScan` is only the *starting* state for an alert a scan
    /// could still improve: one with rules to look up and no sentence yet.
    /// A scan-sourced body is already final, and an event-driven alert has
    /// no rule any diagnosis could match — its line is its own and is never
    /// a promise of a check.
    private func initialBodyState(_ def: AlertDefinition,
                                  bodyOverride: String?) -> ActiveAlert.BodyState {
        if bodyOverride != nil { return .enriched }
        return def.rules.isEmpty ? .fixed : .awaitingScan
    }

    // MARK: - Delivery

    private func deliver(id: String, title: String, body: String, isOutage: Bool, replacing: Bool) {
        notificationManager.deliverDegradation(
            id: id,
            title: title,
            body: body,
            isOutage: isOutage,
            replacing: replacing
        )
    }

    private func deliverResolved(id: String, title: String) {
        notificationManager.deliverAlertResolved(id: id, title: title)
    }

    // MARK: - Housekeeping

    /// Clear the once-per-network memory for a network we have left, so
    /// rejoining a captive-portal network next week prompts again. Keyed on
    /// the network we are *on* rather than a timer, because "once per
    /// network" means exactly that.
    func networkChanged(to id: String?) {
        guard let id else { return }
        for key in firedForNetwork.keys where key != id {
            firedForNetwork.removeValue(forKey: key)
        }
    }

    /// Worst first, so the dropdown's one-alert stage always shows the
    /// alert most worth interrupting someone over rather than whichever
    /// happened to fire most recently. Rank comes from the CLI's own
    /// severity by way of `severityRank`, never a judgment made here; ties
    /// (including the pre-catalog default rank of 0 for everything) fall
    /// back to newest first.
    var activeSorted: [ActiveAlert] {
        guard !active.isEmpty else { return [] }
        if active.count == 1 { return Array(active.values) }
        let ranked = active.values.map { alert in
            (alert: alert, rank: alert.rules.compactMap(severityRank).max() ?? 0)
        }
        return ranked.sorted { a, b in
            if a.rank != b.rank { return a.rank > b.rank }
            return a.alert.raisedAt > b.alert.raisedAt
        }.map(\.alert)
    }
}
