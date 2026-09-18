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
    @Environment(HopwatchCoordinator.self) private var coordinator
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
                statusHeroCard

                locationWarningBanner

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

                if let mem = currentNetworkMemory, mem.checkCount >= 2 {
                    let comp: NetworkComparison? = {
                        if let snap = currentRunResult?.snapshot {
                            return NetworkHistoryStore.compare(snapshot: snap, baseline: mem)
                        } else if let sample = coordinator.monitor.latest {
                            return NetworkHistoryStore.compare(sample: sample, baseline: mem)
                        }
                        return nil
                    }()
                    NetworkDetailCard(memory: mem, comparison: comp)
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
    private var arrivalNetworkName: String? {
        if let live = coordinator.wifiDisplayName, !live.isEmpty { return live }
        guard let id = coordinator.arrivalNetworkID else { return nil }
        let resolved = coordinator.history.displayName(for: id)
        return resolved.isEmpty ? nil : resolved
    }

    // MARK: - Status at a Glance Hero Card

    private var statusHeroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Top Row: Status Glyph, Headline & Subtitle, Primary Action
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: statusIcon)
                    .font(.system(size: 26))
                    .foregroundStyle(coordinator.currentHealth.tint)
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(coordinator.headline)
                        .font(.title3.weight(.bold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if let caption = lastCheckedCaption {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if coordinator.monitor.isRunning {
                        Text("Continuous background monitoring active")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

                if coordinator.isScanning {
                    HStack(spacing: 6) {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(elapsedLabel(at: context.date))
                                .monospacedDigit()
                                .font(.caption.weight(.medium))
                        }
                        Button("Cancel") { coordinator.cancelScan() }
                            .controlSize(.small)
                    }
                } else {
                    Button {
                        coordinator.runFullCheck()
                    } label: {
                        Label(fullCheckLabel, systemImage: "stethoscope")
                    }
                    .keyboardShortcut("r")
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .help(fullCheckHelp)
                }
            }

            Divider()

            // 4 Vital Instrument Tiles
            vitalTilesGrid
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(coordinator.currentHealth.tint.opacity(0.25), lineWidth: 1)
                )
        )
    }

    private var statusIcon: String {
        switch coordinator.currentHealth {
        case .healthy:  return "checkmark.shield.fill"
        case .warning:  return "exclamationmark.triangle.fill"
        case .critical: return "xmark.octagon.fill"
        case .paused:   return "pause.circle.fill"
        }
    }

    private var vitalTilesGrid: some View {
        HStack(alignment: .top, spacing: 10) {
            // 1. Latency
            vitalTile(
                icon: "gauge.with.needle",
                iconColor: latencyTint,
                label: "Latency (Ping)",
                value: latencyValue,
                subcaption: latencyQuality
            )

            // 2. Stability & Jitter
            vitalTile(
                icon: currentStability.icon,
                iconColor: currentStability.tint,
                label: "Stability",
                value: currentStability.label,
                subcaption: jitterSubcaption
            )

            // 3. Packet Loss
            vitalTile(
                icon: "shield.checkerboard",
                iconColor: lossTint,
                label: "Packet Loss",
                value: lossValue,
                subcaption: lossSubcaption
            )

            // 4. Connection Link
            vitalTile(
                icon: linkIcon,
                iconColor: linkTint,
                label: linkTypeLabel,
                value: linkName,
                subcaption: linkQuality
            )
        }
    }

    private func vitalTile(
        icon: String,
        iconColor: Color,
        label: String,
        value: String,
        subcaption: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(iconColor)
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(subcaption)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    // MARK: - Vital Computations

    private var latencyMs: Double? {
        if let ping = coordinator.monitor.latest?.internet.rttAvgMs { return ping }
        if let gw = coordinator.monitor.latest?.gateway.rttAvgMs { return gw }
        if let ping = coordinator.latestRun?.snapshot.internetLatency.rttAvgMs { return ping }
        return coordinator.latestRun?.snapshot.gateway.rttAvgMs
    }

    private var latencyValue: String {
        guard let ms = latencyMs else { return "—" }
        return String(format: "%.0f ms", ms)
    }

    private var latencyTint: Color {
        guard let ms = latencyMs else { return .secondary }
        if ms < 40 { return .green }
        if ms < 100 { return .yellow }
        return .red
    }

    private var latencyQuality: String {
        guard let ms = latencyMs else { return "Waiting for probe" }
        if ms < 25 { return "Fast & responsive" }
        if ms < 60 { return "Good" }
        if ms < 120 { return "Moderate lag" }
        return "High latency"
    }

    private var currentJitter: Double? {
        coordinator.currentJitter
    }

    private var currentStability: ConnectionStability {
        coordinator.currentStability
    }

    private var jitterSubcaption: String {
        if let j = currentJitter {
            return String(format: "±%.1f ms jitter", j)
        }
        return currentStability.description
    }

    private var currentLoss: Double? {
        coordinator.effectiveLoss
    }

    private var lossValue: String {
        guard let l = currentLoss else { return "—" }
        return String(format: "%.0f%%", l)
    }

    private var lossTint: Color {
        guard let l = currentLoss else { return .secondary }
        if l == 0 { return .green }
        if l <= 2.0 { return .yellow }
        return .red
    }

    private var lossSubcaption: String {
        guard let l = currentLoss else { return "Measuring" }
        if l == 0 { return "Clean link (0 drops)" }
        if l <= 2.0 { return "Minor packet loss" }
        return "Frequent drops"
    }

    private var linkIcon: String {
        if isConnectedToWiFi { return "wifi" }
        return "cable.connector"
    }

    private var linkTypeLabel: String {
        if isConnectedToWiFi { return "Wi-Fi" }
        return "Ethernet"
    }

    private var linkName: String {
        if isConnectedToWiFi {
            if let name = coordinator.wifiDisplayName, !name.isEmpty {
                return name
            }
            return coordinator.locationPermissions.isAuthorized ? "Wi-Fi" : "Connected"
        }
        return "Wired Link"
    }

    private var linkTint: Color {
        if isConnectedToWiFi {
            let cell = SignalScale.cellContent(rssi: resolvedRSSI, scale: coordinator.signalScale.scale)
            return cell.tint
        }
        return .green
    }

    private var linkQuality: String {
        if isConnectedToWiFi {
            if !coordinator.locationPermissions.isAuthorized {
                return "Location restricted"
            }
            let cell = SignalScale.cellContent(rssi: resolvedRSSI, scale: coordinator.signalScale.scale)
            if let unit = cell.unit {
                return "\(cell.value) (\(unit))"
            }
            return cell.value
        }
        return "Active connection"
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
            Text("Hopwatch is watching your connection continuously in the background. Run a full check to see the detail behind it.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .proseWidth()
        }
        .padding(.top, 24)
    }

    // MARK: - Expert layer

    private var currentNetworkMemory: NetworkMemory? {
        guard let netID = coordinator.arrivalNetworkID ?? currentRunResult?.snapshot.network.id else { return nil }
        let canon = coordinator.history.canonicalID(netID)
        guard let net = coordinator.history.mergedNetworks.first(where: { $0.id == canon }) else {
            return nil
        }
        let runs = coordinator.history.runs(networkID: net.id, window: .all)
        return NetworkHistoryStore.memory(
            for: net,
            displayName: coordinator.history.displayName(for: net.id),
            runs: runs
        )
    }

    /// Whichever report is on screen, as the `RunResult` the expert
    /// disclosure and the raw-JSON viewer inside it both expect.
    private var currentRunResult: RunResult? {
        coordinator.currentRunResult
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
