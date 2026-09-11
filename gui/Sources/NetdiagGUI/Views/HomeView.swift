import SwiftUI
import CoreWLAN

/// Home: "is my internet OK, and why?" — the question the sidebar's first
/// row answers. Hydrated from stored history on cold launch so this is
/// never empty (see `NetdiagCoordinator.hydrateFromHistoryIfNeeded`), and
/// it leads with the same user-facing suitability verdict a stored report
/// uses. Dense measurements are collapsed on this landing screen; Networks
/// remains the place to browse past checks, and the expert layer remains a
/// disclosure rather than a mode chosen at first launch.
struct HomeView: View {
    @Environment(NetdiagCoordinator.self) private var coordinator
    @Environment(AppSettings.self) private var appSettings
    /// The Wi-Fi row's CoreWLAN fallback — same cache-and-throttle shape
    /// as `DropdownView.coreWLANRSSI`, kept as its own `@State` because
    /// SwiftUI state belongs to the view that owns it, not to a store both
    /// views could share. See that property's header for why a live read
    /// on every render would be wrong.
    @State private var coreWLANRSSI: Int?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                locationWarningBanner
                wifiRow

                ArrivalCard(state: coordinator.arrivalState,
                            network: arrivalNetworkName,
                            progress: coordinator.isScanning ? coordinator.progress : nil,
                            intent: coordinator.arrivalIntent,
                            onRunFullCheck: { coordinator.runDeclinedFullCheck() },
                            isCaptivePortal: coordinator.monitor.latest?.publicInfo.captivePortal == true
                                || (coordinator.monitor.latest?.status.rules.contains("CP-1") ?? false)
                                || coordinator.alerts.active["captive-portal"] != nil)

                // Only for scans the arrival card is not already showing —
                // otherwise a new network renders two sets of progress rows.
                if coordinator.isScanning,
                   ArrivalCopy.forState(coordinator.arrivalState,
                                        network: arrivalNetworkName,
                                        intent: coordinator.arrivalIntent) == nil {
                    ScanProgressView(progress: coordinator.progress)
                    Divider()
                }

                // Hoisted out of `emptyState`: a hydrated report replaces
                // that state the moment history has anything to show, and a
                // failed scan needs to surface whether or not the screen
                // underneath it is empty.
                if let error = coordinator.lastRunError {
                    HStack(alignment: .top, spacing: 8) {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button("Try Again") {
                            coordinator.runFullCheck(reason: "retry after failure")
                        }
                        .controlSize(.small)
                    }
                }

                switch coordinator.reportSource {
                case .live(let run):
                    RunReportView(snapshot: run.snapshot, rawJSON: run.rawJSON,
                                  showRuleIDs: appSettings.expertExpanded,
                                  presentation: .home)
                case .stored(let detail):
                    // Comparison chips come free: `detail` is a `--show`
                    // response, and RunReportView already knows how to
                    // render one — RunDetailView passes the identical pair.
                    RunReportView(snapshot: detail.run, comparison: detail.comparison,
                                  rawJSON: detail.asRunResult.rawJSON,
                                  showRuleIDs: appSettings.expertExpanded,
                                  presentation: .home,
                                  provenance: storedProvenance(detail))
                case nil:
                    emptyState
                }

                if let result = currentRunResult {
                    expertDisclosure(result)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            coordinator.locationPermissions.refresh()
        }
        // Throttled the same way DropdownView.coreWLANRSSI is: a live
        // CoreWLAN read on every render would cost a syscall per redraw of
        // an always-visible screen, so this keys off the incoming sample
        // sequence number instead — at most once per monitor tick.
        .task(id: coordinator.monitor.latest?.seq) {
            refreshCoreWLANRSSIIfNeeded()
        }
    }

    /// The name for the arrival card, falling back past CoreWLAN.
    ///
    /// `wifiDisplayName` is nil without Location Services, and the card's
    /// own fallback is the generic "this network" — which rendered
    /// directly beneath a header already showing the real name, from the
    /// history store, two lines up. `arrivalNetworkID` is the canonical id
    /// the card is *about*, and `history.displayName(for:)` is the same
    /// resolver the Networks tab and the header use, so this cannot
    /// disagree with them.
    private var arrivalNetworkName: String? {
        if let live = coordinator.wifiDisplayName, !live.isEmpty { return live }
        guard let id = coordinator.arrivalNetworkID else { return nil }
        let resolved = coordinator.history.displayName(for: id)
        return resolved.isEmpty ? nil : resolved
    }

    // MARK: - Wi-Fi row
    //
    // Restores what the pre-redesign single-panel dropdown's
    // `wifiGlanceInfo` used to show (network name + signal) on Home, where
    // it never actually lived before this task — see this task's report
    // for the full investigation. Reuses Item 1's exact word-plus-dBm
    // treatment (`SignalScale.cellContent`) and `NetdiagCoordinator
    // .wifiDisplayName`, the same two things `DropdownView`'s Wi-Fi
    // instrument and quiet-line caption read, so Home and the dropdown can
    // never describe the same network two different ways.

    @ViewBuilder
    private var wifiRow: some View {
        if isConnectedToWiFi && coordinator.locationPermissions.isAuthorized {
            let cell = SignalScale.cellContent(rssi: resolvedRSSI, scale: coordinator.signalScale.scale)
            HStack(spacing: 10) {
                Image(systemName: "wifi")
                    .foregroundStyle(cell.tint)
                    .frame(width: 18)
                if let name = coordinator.wifiDisplayName {
                    Text(name).fontWeight(.medium)
                } else {
                    Text("Wi-Fi").foregroundStyle(.secondary)
                }
                Spacer()
                // "now", explicitly. The report card below carries its own
                // Wi-Fi signal row, and that one reports what the *check*
                // recorded — which stays blank without sudo. Unlabelled,
                // the two read as the app contradicting itself about a
                // number one of them is visibly showing; labelled, they
                // read as what they are, a live radio reading and a
                // recorded one.
                Text("now")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(cell.value)
                    .fontWeight(.medium)
                    .foregroundStyle(cell.tint)
                if let unit = cell.unit {
                    Text(unit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .cardStyle()
        }
    }

    /// Same precedence as `DropdownView.resolvedRSSI`: the monitor's own
    /// reading (present under `sudo netdiag`, or a future privileged
    /// helper) first, the CoreWLAN fallback second.
    private var resolvedRSSI: Int? {
        coordinator.monitor.latest?.wifi?.rssi ?? coreWLANRSSI
    }

    private func refreshCoreWLANRSSIIfNeeded() {
        guard isConnectedToWiFi,
              coordinator.monitor.latest?.wifi?.rssi == nil,
              coordinator.locationPermissions.isAuthorized,
              let live = CWWiFiClient.shared().interface()?.rssiValue(),
              live != 0 else {
            coreWLANRSSI = nil
            return
        }
        coreWLANRSSI = live
    }

    // MARK: - Location Banner

    @ViewBuilder
    private var locationWarningBanner: some View {
        if isConnectedToWiFi && !coordinator.locationPermissions.isAuthorized
            && !appSettings.locationBannerDismissed {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "location.slash")
                    .font(.title3)
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Wi-Fi network name & radio diagnostics are restricted")
                        .font(.callout)
                        .fontWeight(.medium)
                    Text("macOS requires Location Services to display your network name and diagnose local radio strength. Basic fault isolation (Router vs ISP) remains active.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .proseWidth(520)
                }

                Spacer(minLength: 8)

                Button(coordinator.locationPermissions.isDeniedOrRestricted ? "Enable in Settings" : "Allow") {
                    if coordinator.locationPermissions.isDeniedOrRestricted {
                        coordinator.locationPermissions.openSystemSettings()
                    } else {
                        coordinator.locationPermissions.requestOrOpenSettings()
                    }
                }
                .controlSize(.small)

                // Declining is a settled choice, not a per-visit question —
                // Settings keeps its own always-on "Allow" row as the
                // durable way back in, so dismissing here loses no
                // capability, just the repetition.
                Button {
                    appSettings.locationBannerDismissed = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.orange.opacity(0.3), lineWidth: 1)
            )
        }
    }

    /// Whether the machine is on Wi-Fi *as far as this app has been told*.
    ///
    /// The fallback is `false`, not `true`. Both are wrong sometimes — the
    /// question genuinely has no answer before the first sample lands — but
    /// they are wrong in different directions, and only one of them puts an
    /// orange "Wi-Fi network name & radio diagnostics are restricted"
    /// banner on a desktop that has never had a Wi-Fi card. Guessing "not
    /// Wi-Fi" costs at most one cycle of a banner appearing slightly late;
    /// guessing "Wi-Fi" invents a problem the user cannot act on.
    private var isConnectedToWiFi: Bool {
        if let isWiFi = coordinator.monitor.latest?.link.isWiFi {
            return isWiFi
        }
        if let run = coordinator.latestRun {
            return run.snapshot.wifi != nil
        }
        return false
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(coordinator.headline)
                    .font(.title3)
                    .fixedSize(horizontal: false, vertical: true)
                    // The widest thing on Home, and so the view's ideal
                    // width — see `View.proseWidth`. The longest headline
                    // the coordinator can produce still fits on two lines
                    // here; most fit on one.
                    .proseWidth()
                if let caption = lastCheckedCaption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if coordinator.isScanning {
                HStack(spacing: 6) {
                    // The elapsed seconds stay even now that the phase list
                    // exists: the list says how far along the run is
                    // through a *declared* set of checks, and says nothing
                    // about how long the rest will take. The counter is the
                    // only honest thing to put next to it.
                    //
                    // Driven by a TimelineView because nothing else ticks
                    // once a second — during a scan the monitor is paused,
                    // so a counter recomputed on observation alone would
                    // sit frozen at whatever second the last event landed.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(elapsedLabel(at: context.date))
                            .monospacedDigit().font(.caption)
                    }
                    Button("Cancel") { coordinator.cancelScan() }
                }
            } else {
                // Continuous monitoring owns the fast "is it broken now?"
                // question and starts a targeted investigation when a fault
                // appears. The only manual path is the occasional full
                // baseline check (or its safe lighter fallback).
                Button {
                    coordinator.runFullCheck()
                } label: {
                    Label(fullCheckLabel, systemImage: "stethoscope")
                }
                .keyboardShortcut("r")
                .buttonStyle(.borderedProminent)
                .help(fullCheckHelp)
            }
        }
    }

    // Both of these are `FullCheckPolicy`'s wording, not this view's — see
    // that file for why the label has to track which depth will actually
    // run, and why the fallback text states only what the app knows. The
    // dropdown's own control reads the same two functions, so the two can
    // never describe the same button differently.

    private var fullCheckLabel: String {
        FullCheckPolicy.controlLabel(isSafe: coordinator.fullCheckIsSafe)
    }

    private var fullCheckHelp: String {
        FullCheckPolicy.controlHelp(isSafe: coordinator.fullCheckIsSafe)
    }

    private func elapsedLabel(at now: Date) -> String {
        let elapsed = Int(now.timeIntervalSince(coordinator.scanStartedAt ?? now))
        return "\(max(elapsed, 0))s"
    }

    /// "Last checked …" for whichever report is on screen. A live run adds
    /// "· took Ns" — the process's own wall-clock, meaningful for a check
    /// that just ran. A stored one drops it: the process that produced a
    /// report hydrated from history exited long before this launch, and
    /// its duration says nothing about how long *this* check took. A stored
    /// one adds the network's name instead, so a report and the headline
    /// above it can never read as one contradictory screen. Mirrors
    /// `RunDetailView.subtitle`, which names the network the same way for
    /// the same reason.
    ///
    /// That name used to be here because hydration picked the newest check
    /// across every network this app had seen, which it no longer does —
    /// see `NetdiagCoordinator.hydrateFromHistoryIfNeeded`. It stays
    /// because a hydrated report still goes stale in place the moment you
    /// walk to a different network, which is the case `storedProvenance`
    /// labels on the report itself.
    private var lastCheckedCaption: String? {
        switch coordinator.reportSource {
        case .live(let run):
            return "Last checked \(run.finishedAt.formatted(date: .abbreviated, time: .shortened)) · took \(String(format: "%.0f", run.duration))s"
        case .stored(let detail):
            let date = detail.run.date.formatted(date: .abbreviated, time: .shortened)
            guard let networkID = detail.context.networkID else {
                // An old `netdiag` whose `--show` predates `context`. Still
                // better than nothing, just without the network name.
                return "Last checked \(date)"
            }
            return "Last checked \(date) · \(coordinator.history.displayName(for: networkID))"
        case nil:
            return nil
        }
    }

    /// A stored run is only unremarkable when it is about the network you
    /// are on and recent enough to still be true. Anything else is
    /// labelled, because an unlabelled report from an hour ago somewhere
    /// else is indistinguishable from a live one — which is exactly how a
    /// Wi-Fi warning about a previous building ended up at the top of a
    /// brand-new network's dashboard.
    ///
    /// Returns nil for a report that needs no caption, so the common case
    /// renders exactly as it did before.
    private func storedProvenance(_ detail: RunDetail) -> String? {
        guard Self.needsProvenance(
            storedNetworkID: detail.context.networkID,
            currentNetworkID: coordinator.monitor.latest?.network.historyJoinID,
            canonical: coordinator.history.canonicalID)
        else { return nil }
        // Non-nil `networkID` is implied by the predicate above, which
        // returns false without one.
        guard let networkID = detail.context.networkID else { return nil }
        // `history.displayName(for:)` is the same resolver the header, the
        // arrival card and the Networks tab use, so this cannot name a
        // network differently from the rest of the app.
        let name = coordinator.history.displayName(for: networkID)
        return "Last check on \(name), \(RelativeTime.string(from: detail.run.date))"
    }

    /// Whether a stored report needs a provenance caption: true unless it
    /// is positively about the network we are on right now.
    ///
    /// Static and pure so it can be asserted directly — the nil handling is
    /// the subtle part, and it is what decides whether another building's
    /// report can appear unlabelled. `canonical` is a parameter rather than
    /// something this reaches for so the function stays a function of its
    /// arguments; callers pass `HistoryStore.canonicalID`, which follows
    /// manual merges.
    static func needsProvenance(storedNetworkID: String?,
                                currentNetworkID: String?,
                                canonical: (String) -> String) -> Bool {
        // An old `netdiag` whose `--show` predates `context`: there is no
        // network to name, and `lastCheckedCaption` already prints the date
        // for this case. Nothing truthful to add here.
        guard let storedNetworkID else { return false }
        // `nil` means "not identified yet", never "any network will do", so
        // this is precisely the state in which Home cannot claim the report
        // is about the here and now. Label it.
        guard let currentNetworkID else { return true }
        return canonical(storedNetworkID) != canonical(currentNetworkID)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No check has run yet.").font(.headline)
            Text("netdiag is watching your connection continuously in the background. Run a full check to see the detail behind it.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .proseWidth()
        }
        .padding(.top, 24)
    }

    // MARK: - Expert layer

    /// Whichever report is on screen, as the `RunResult` the expert
    /// disclosure and the raw-JSON viewer inside it both expect.
    private var currentRunResult: RunResult? {
        switch coordinator.reportSource {
        case .live(let run):        return run
        case .stored(let detail):   return detail.asRunResult
        case nil:                   return nil
        }
    }

    private func expertDisclosure(_ run: RunResult) -> some View {
        @Bindable var appSettings = appSettings
        return DisclosureGroup(isExpanded: $appSettings.expertExpanded) {
            ExpertPanel(run: run)
                .padding(.top, 8)
        } label: {
            Text("Technical detail").font(.headline)
        }
    }
}
