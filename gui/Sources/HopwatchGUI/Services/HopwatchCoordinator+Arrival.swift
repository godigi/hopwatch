import Foundation
import os

// MARK: - Arrival

extension HopwatchCoordinator {

    /// The one automatic check, and the reason there is no timed one:
    /// joining a network for the first time is exactly when a baseline of
    /// what it can do — throughput, bufferbloat, path MTU — is worth
    /// having. Monitoring covers the continuous question; this covers the
    /// one-off one. See CLAUDE.md's three-depth table.
    func considerArrival(for id: String, sample: MonitorSample) {
        let targetID: String = {
            if sample.link.isWiFi || liveSSID != nil, NetworkIdentity.isPrivateOrLocalGateway(id) {
                if let ssid = liveSSID ?? Self.readableSSID(sample.link.ssid) {
                    return "ssid:\(ssid)"
                }
            }
            return id
        }()

        let canonical = history.canonicalID(targetID)
        let state = recordedArrivalState(for: targetID)
            ?? recordedArrivalState(for: canonical)
            ?? .unchecked
        if arrivalNetworkID != targetID { arrivalNetworkID = targetID }
        if arrivalState != state { arrivalState = state }

        let intent = arrivalIntent(now: Date())
        if arrivalIntent != intent { arrivalIntent = intent }

        guard Defaults.scanOnNewNetwork else { return }
        let now = Date()
        guard state.needsAttempt(now: now) else { return }
        if let next = nextArrivalAttemptAt, now < next { return }

        switch ArrivalPolicy.decide(hasSample: true,
                                    severity: sample.status.severity,
                                    isExpensive: events.pathIsExpensive,
                                    isConstrained: events.pathIsConstrained,
                                    isSettling: isSettling) {
        case .wait:
            return

        case .full:
            let reason = state.isDeclined ? "new network (now healthy)" : "new network"
            attemptArrival(id: targetID, depth: .full, reason: reason)

        case .quick(let why):
            if case .declined(let d, let r, _) = state, d == .quick, r == why {
                return
            }
            attemptArrival(id: targetID, depth: .quick,
                           reason: "new network (\(why.rawValue))",
                           declineWith: why)
        }
    }

    private func attemptArrival(id: String, depth: ArrivalDepth, reason: String,
                                declineWith: DeclineReason? = nil) {
        let now = Date()
        // Marked *before* the scan starts, not after: `launch` reads
        // `isArrivalCheck` once, synchronously, to decide whether this scan
        // reseeds the heartbeat around itself. Setting the marker only once
        // `runScan` had returned meant that read was always false, so the
        // reseed at the end of an arrival check never ran. Restored if the
        // scan is declined, so a busy decline leaves the in-flight check's
        // own marker (if any) exactly as it was.
        let previousPending = (pendingArrivalNetworkID, pendingArrivalDepth, pendingArrivalDecline)
        pendingArrivalNetworkID = id
        pendingArrivalDepth = depth
        pendingArrivalDecline = declineWith
        guard runScan(depth: depth.runnerDepth, reason: reason) else {
            (pendingArrivalNetworkID, pendingArrivalDepth, pendingArrivalDecline) = previousPending
            arrivalAttempts += 1
            let delay = min(30 * pow(2, Double(arrivalAttempts - 1)), 300)
            nextArrivalAttemptAt = now.addingTimeInterval(delay)
            log.debug("arrival check for \(id, privacy: .public) declined — a scan is running; retrying in \(delay, format: .fixed(precision: 0))s")
            return
        }

        arrivalAttempts = 0
        nextArrivalAttemptAt = nil

        setArrivalState(.checking(depth: depth, startedAt: now), for: id)
    }

    private func arrivalIntent(now: Date) -> ArrivalCopy.Intent {
        guard Defaults.scanOnNewNetwork else { return .notAutomatic }
        if let next = nextArrivalAttemptAt, now < next { return .waitingForAnotherCheck }
        if isScanning, !isArrivalCheck { return .waitingForAnotherCheck }
        return .starting
    }

    /// Those weak keys are never *persisted* — the store would let one
    /// network's verdict suppress an unrelated one that happens to share
    /// 192.168.1.1. They are still *remembered for this connection*, in
    /// `sessionArrivalStates`. Dropping the write outright (the previous
    /// behaviour) left every such network `.unchecked` forever: the full
    /// check ran, its terminal state vanished, and the very next monitor
    /// sample started another one — back-to-back, link-saturating, with the
    /// arrival card stuck on "Starting a check".
    func setArrivalState(_ state: ArrivalState, for id: String) {
        if NetworkIdentity.isPrivateOrLocalGateway(id) {
            sessionArrivalStates[id] = state
        } else {
            var all = Defaults.arrivalStates
            all[id] = state
            Defaults.arrivalStates = all
        }
        if id == arrivalNetworkID { arrivalState = state }
    }

    /// One key's recorded arrival state: the persisted store for a
    /// trustworthy identity, the in-memory per-connection map for a weak
    /// (private gateway IP) one.
    private func recordedArrivalState(for key: String) -> ArrivalState? {
        if NetworkIdentity.isPrivateOrLocalGateway(key) {
            return sessionArrivalStates[key]
        }
        return Defaults.arrivalStates[key]
    }

    /// Determines whether two network identifiers refer to the same physical network,
    /// accounting for history merges, weak-key folding (gw: vs ssid: vs mac:),
    /// matching gateway IPs, and known Wi-Fi SSIDs.
    func networkMatches(scanNetwork: String?, measured: String?, snapshot: RunSnapshot? = nil) -> Bool {
        guard let scanNetwork, let measured else { return true }
        if history.canonicalID(measured) == history.canonicalID(scanNetwork) {
            return true
        }
        if scanNetwork.starts(with: "gw:") {
            let gw = String(scanNetwork.dropFirst(3))
            if !NetworkIdentity.isPrivateOrLocalGateway(gw) {
                if let snapGw = snapshot?.gateway.ip, snapGw == gw {
                    return true
                }
                if measured.starts(with: "gw:") && String(measured.dropFirst(3)) == gw {
                    return true
                }
            }
        }
        if measured.starts(with: "gw:") {
            let gw = String(measured.dropFirst(3))
            if !NetworkIdentity.isPrivateOrLocalGateway(gw) {
                if let snapGw = snapshot?.gateway.ip, snapGw == gw {
                    return true
                }
            }
        }
        if scanNetwork.starts(with: "ssid:") {
            let ssid = String(scanNetwork.dropFirst(5))
            if let snapSsid = snapshot?.wifi?.ssid, snapSsid == ssid {
                return true
            }
            if let live = liveSSID, live == ssid {
                return true
            }
        }
        if measured.starts(with: "ssid:") {
            let ssid = String(measured.dropFirst(5))
            if let snapSsid = snapshot?.wifi?.ssid, snapSsid == ssid {
                return true
            }
            if let live = liveSSID, live == ssid {
                return true
            }
        }
        return false
    }

    /// Write the terminal arrival state for a scan that has just landed.
    func finishArrivalIfPending(runID: String?, measured: String?) {
        guard let id = pendingArrivalNetworkID, let depth = pendingArrivalDepth else { return }
        let decline = pendingArrivalDecline

        let isMatching: Bool
        if let measured {
            isMatching = networkMatches(scanNetwork: id, measured: measured, snapshot: latestRun?.snapshot)
        } else {
            isMatching = true
        }

        guard isMatching else {
            clearPendingArrival(failed: true)
            log.info("arrival check for \(id, privacy: .public) landed after a network change — left unchecked so it retries")
            return
        }

        clearPendingArrival(failed: false)

        let targetState: ArrivalState
        if let decline {
            targetState = .declined(depth: depth, reason: decline, at: Date())
        } else {
            targetState = .checked(depth: depth, at: Date(), runID: runID)
        }

        setArrivalState(targetState, for: id)
        if let measured, measured != id {
            setArrivalState(targetState, for: measured)
        }
        let canonical = history.canonicalID(id)
        if canonical != id {
            setArrivalState(targetState, for: canonical)
        }
        if let measured {
            let canMeasured = history.canonicalID(measured)
            if canMeasured != measured && canMeasured != canonical {
                setArrivalState(targetState, for: canMeasured)
            }
        }
        log.info("arrival check for \(id, privacy: .public) finished at \(depth.rawValue, privacy: .public)")
    }

    /// Forget the in-flight arrival check without writing a terminal
    /// state. Used when a scan fails or is cancelled: the network stays
    /// `.unchecked`, so the next sample retries with backoff.
    func clearPendingArrival(failed: Bool = false) {
        if let id = pendingArrivalNetworkID {
            setArrivalState(.unchecked, for: id)
            if failed {
                arrivalAttempts += 1
                let delay = min(30 * pow(2, Double(arrivalAttempts - 1)), 300)
                nextArrivalAttemptAt = Date().addingTimeInterval(delay)
                log.info("arrival check for \(id, privacy: .public) cleared after failure/cancel (attempt \(self.arrivalAttempts)) — retrying in \(delay, format: .fixed(precision: 0))s")
            }
        }
        pendingArrivalNetworkID = nil
        pendingArrivalDepth = nil
        pendingArrivalDecline = nil
    }

    /// Whether the in-flight scan (if any) is an arrival check.
    var isArrivalCheck: Bool { pendingArrivalNetworkID != nil }

    /// The arrival card's override button: run the full check the policy
    /// declined, and record it as this network's arrival check.
    func runDeclinedFullCheck() {
        guard let id = arrivalNetworkID else { return }
        // Marked before the scan starts for the reason given in
        // `attemptArrival`; restored if the scan is declined.
        let previousPending = (pendingArrivalNetworkID, pendingArrivalDepth, pendingArrivalDecline)
        pendingArrivalNetworkID = id
        pendingArrivalDepth = .full
        pendingArrivalDecline = nil
        guard runScan(depth: .full, reason: "you asked for the full check anyway") else {
            (pendingArrivalNetworkID, pendingArrivalDepth, pendingArrivalDecline) = previousPending
            return
        }
        setArrivalState(.checking(depth: .full, startedAt: Date()), for: id)
    }
}
