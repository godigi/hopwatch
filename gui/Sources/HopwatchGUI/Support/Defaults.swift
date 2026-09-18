import Foundation

/// Every persisted preference, in one place.
///
/// A key that any *view* reads must also be mirrored as a property on
/// `AppSettings` — views observe that wrapper, never this enum directly,
/// so an unmirrored key would render once and go stale.
///
/// Note what is *not* here: no thresholds. The cadence intervals below are
/// how often to look, which is a preference; what counts as lossy is a
/// judgement, and it lives in lib/thresholds.sh where the CLI can act on
/// it too. If a setting ever needs a number that decides whether something
/// is wrong, it belongs in the CLI and this file should read it back.
enum Defaults {

    /// `UserDefaults.standard`, with the registered fallbacks folded into
    /// this lazy initializer instead of a separate `registerDefaults()`
    /// call site.
    ///
    /// `AppSettings` snapshots these values into `@Observable` storage as
    /// part of `NetdiagCoordinator`'s property-default phase, which Swift
    /// runs *before* a custom `init()`'s body — i.e. before
    /// `NetdiagApp.init()` could reach a separate registration call.
    /// Registering here, on first touch of `d` itself, makes the order the
    /// app happens to construct things in unable to matter: every getter
    /// and setter below goes through `d`, so registration is guaranteed to
    /// have already run by the time any of them do.
    private static let d: UserDefaults = {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Key.monitoringEnabled: true,
            Key.fastInterval: 5,
            Key.degradedInterval: 3,
            Key.mediumInterval: 60,
            Key.slowInterval: 300,
            Key.menuBarStyle: MenuBarStyle.dotAndFlag.rawValue,
            Key.expertExpanded: false,
            Key.pauseOnDisplaySleep: true,
            Key.pauseOnBattery: false,
            Key.scanOnNewNetwork: true,
            Key.scanOnAlert: true,
            Key.hasOnboarded: false,
            Key.notificationsEnabled: true,
            Key.notificationScope: "all",
            Key.showInDock: false,
        ])

        // On first launch of com.godigi.hopwatch, import legacy user preferences
        // (network names, merges, arrival states, phase durations) if present.
        if defaults.object(forKey: Key.networkNames) == nil {
            let prefPath = ("~/Library/Preferences" as NSString).expandingTildeInPath
            if let files = try? FileManager.default.contentsOfDirectory(atPath: prefPath) {
                for file in files where (file.hasSuffix(".hopwatch.plist") || file.hasSuffix(".netdiag.plist")) && !file.contains("com.godigi.hopwatch") {
                    let legacyDomain = file.replacingOccurrences(of: ".plist", with: "")
                    if let legacy = UserDefaults(suiteName: legacyDomain) {
                        let keysToMigrate = [
                            Key.networkNames,
                            Key.networkMerges,
                            Key.networkOwned,
                            Key.arrivalStates,
                            Key.phaseDurationSamples,
                            Key.menuBarStyle,
                            Key.expertExpanded,
                            Key.fastInterval,
                            Key.degradedInterval,
                            Key.mediumInterval,
                            Key.slowInterval,
                        ]
                        var didMigrate = false
                        for key in keysToMigrate {
                            if let val = legacy.object(forKey: key), defaults.object(forKey: key) == nil {
                                defaults.set(val, forKey: key)
                                didMigrate = true
                            }
                        }
                        if didMigrate { break }
                    }
                }
            }
        }

        return defaults
    }()

    private enum Key {
        static let monitoringEnabled  = "monitoringEnabled"
        static let fastInterval       = "monitorFastInterval"
        static let degradedInterval   = "monitorDegradedInterval"
        static let mediumInterval     = "monitorMediumInterval"
        static let slowInterval       = "monitorSlowInterval"
        static let menuBarStyle       = "menuBarStyle"
        static let expertExpanded     = "expertExpanded"
        static let binaryPath         = "netdiagBinaryPath"
        static let networkNames       = "networkNames"
        static let networkMerges      = "networkMerges"
        static let networkOwned       = "networkOwned"
        static let seenNetworks       = "seenNetworks"
        static let arrivalStates      = "arrivalStates"
        static let hasOnboarded       = "hasOnboarded"
        static let pauseOnDisplaySleep = "pauseOnDisplaySleep"
        static let pauseOnBattery     = "pauseOnBattery"
        static let scanOnNewNetwork   = "scanOnNewNetwork"
        static let scanOnAlert        = "scanOnAlert"
        static let disabledAlerts     = "disabledAlerts"
        static let notificationsEnabled = "notificationsEnabled"
        static let notificationScope  = "notificationScope"
        static let showInDock         = "showInDock"
        static let autoCheckUpdates   = "autoCheckUpdates"
        static let lastUpdateCheck    = "lastUpdateCheck"
        static let lastNotifiedUpdateVersion = "lastNotifiedUpdateVersion"
        static let locationBannerDismissed = "locationBannerDismissed"
        static let phaseDurationSamples = "phaseDurationSamples"
    }

    // MARK: - Updates

    static var autoCheckUpdates: Bool {
        get { d.object(forKey: Key.autoCheckUpdates) as? Bool ?? true }
        set { d.set(newValue, forKey: Key.autoCheckUpdates) }
    }

    static var lastUpdateCheck: Date? {
        get { d.object(forKey: Key.lastUpdateCheck) as? Date }
        set { d.set(newValue, forKey: Key.lastUpdateCheck) }
    }

    static var lastNotifiedUpdateVersion: String? {
        get { d.string(forKey: Key.lastNotifiedUpdateVersion) }
        set { d.set(newValue, forKey: Key.lastNotifiedUpdateVersion) }
    }

    // MARK: - Monitoring

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.10.0"
    }

    static var monitoringEnabled: Bool {
        get { d.bool(forKey: Key.monitoringEnabled) }
        set { d.set(newValue, forKey: Key.monitoringEnabled) }
    }

    /// Clamped on read, not just on write. A value edited straight into the
    /// plist — or left over from an older build — would otherwise reach the
    /// CLI's own validation and abort the monitor at startup, which the
    /// user sees as "monitoring just stops working".
    static var fastInterval: Int {
        get { clamp(d.integer(forKey: Key.fastInterval), 2, 300, fallback: 5) }
        set { d.set(newValue, forKey: Key.fastInterval) }
    }
    static var degradedInterval: Int {
        get { clamp(d.integer(forKey: Key.degradedInterval), 2, 300, fallback: 3) }
        set { d.set(newValue, forKey: Key.degradedInterval) }
    }
    static var mediumInterval: Int {
        get { clamp(d.integer(forKey: Key.mediumInterval), 10, 3600, fallback: 60) }
        set { d.set(newValue, forKey: Key.mediumInterval) }
    }
    static var slowInterval: Int {
        get { clamp(d.integer(forKey: Key.slowInterval), 60, 7200, fallback: 300) }
        set { d.set(newValue, forKey: Key.slowInterval) }
    }

    private static func clamp(_ v: Int, _ lo: Int, _ hi: Int, fallback: Int) -> Int {
        v == 0 ? fallback : min(max(v, lo), hi)
    }

    /// The on-demand latency test: how fast to sample, and for how long.
    ///
    /// Not persisted and not a preference — a bounded window the user opts
    /// into per press. Two seconds is the CLI's own floor for
    /// `--monitor-fast-interval`, not a number chosen here; going below it
    /// would have the monitor reject its arguments and exit at startup.
    /// Neither value decides whether anything is good or bad.
    static let latencyTestInterval = 2
    static let latencyTestDuration: TimeInterval = 60

    static var pauseOnDisplaySleep: Bool {
        get { d.bool(forKey: Key.pauseOnDisplaySleep) }
        set { d.set(newValue, forKey: Key.pauseOnDisplaySleep) }
    }
    static var pauseOnBattery: Bool {
        get { d.bool(forKey: Key.pauseOnBattery) }
        set { d.set(newValue, forKey: Key.pauseOnBattery) }
    }

    // MARK: - Auto-run triggers

    static var scanOnNewNetwork: Bool {
        get { d.bool(forKey: Key.scanOnNewNetwork) }
        set { d.set(newValue, forKey: Key.scanOnNewNetwork) }
    }
    static var scanOnAlert: Bool {
        get { d.bool(forKey: Key.scanOnAlert) }
        set { d.set(newValue, forKey: Key.scanOnAlert) }
    }

    // MARK: - Presentation

    static var menuBarStyle: MenuBarStyle {
        get { MenuBarStyle(rawValue: d.string(forKey: Key.menuBarStyle) ?? "") ?? .dotAndFlag }
        set { d.set(newValue.rawValue, forKey: Key.menuBarStyle) }
    }

    /// Whether the expert disclosure is open. Persisted so it is a
    /// disclosure the user opens once and keeps, never a mode chosen at
    /// first launch — an expert should not have to re-open it every time,
    /// and a non-technical user should never be asked which they are.
    static var expertExpanded: Bool {
        get { d.bool(forKey: Key.expertExpanded) }
        set { d.set(newValue, forKey: Key.expertExpanded) }
    }

    static var hasOnboarded: Bool {
        get { d.bool(forKey: Key.hasOnboarded) }
        set { d.set(newValue, forKey: Key.hasOnboarded) }
    }

    static var showInDock: Bool {
        get { d.bool(forKey: Key.showInDock) }
        set { d.set(newValue, forKey: Key.showInDock) }
    }

    /// Declining Location Services is a settled choice, not a per-visit
    /// question — see `HomeView.locationWarningBanner`. Settings → Alerts
    /// → Permissions keeps its own always-visible "Allow" row as the
    /// durable way back in, so this only silences the repeated ask on
    /// Home, never the feature itself.
    static var locationBannerDismissed: Bool {
        get { d.bool(forKey: Key.locationBannerDismissed) }
        set { d.set(newValue, forKey: Key.locationBannerDismissed) }
    }

    static var binaryPath: String {
        get { d.string(forKey: Key.binaryPath) ?? "" }
        set { d.set(newValue, forKey: Key.binaryPath) }
    }

    // MARK: - Networks

    static var networkNames: [String: String] {
        get { d.dictionary(forKey: Key.networkNames) as? [String: String] ?? [:] }
        set { d.set(newValue, forKey: Key.networkNames) }
    }

    static var networkMerges: [String: String] {
        get { d.dictionary(forKey: Key.networkMerges) as? [String: String] ?? [:] }
        set { d.set(newValue, forKey: Key.networkMerges) }
    }

    static var networkOwned: Set<String> {
        get { Set(d.stringArray(forKey: Key.networkOwned) ?? []) }
        set { d.set(Array(newValue).sorted(), forKey: Key.networkOwned) }
    }

    // MARK: - Scan progress weighting

    /// `PhaseWeights`' raw material: mode -> phase name -> recent measured
    /// durations (ms), oldest first. `PhaseWeights` owns the shape and the
    /// median/window logic; this is only the same dictionary-in-UserDefaults
    /// pattern `networkNames` above uses, one level deeper. A malformed or
    /// pre-this-feature value decodes as empty, which `PhaseWeights` already
    /// treats as "nothing learned yet" — the correct behaviour for an
    /// upgrade, not a crash.
    static var phaseDurationSamples: [String: [String: [Int]]] {
        get { d.dictionary(forKey: Key.phaseDurationSamples) as? [String: [String: [Int]]] ?? [:] }
        set { d.set(newValue, forKey: Key.phaseDurationSamples) }
    }

    /// Superseded by `arrivalStates`. Kept readable so the one-time
    /// migration can find it, and *not* written to any more — a build that
    /// still wrote this would keep a second, diverging record of the same
    /// fact. Delete once no supported version reads it.
    static var legacySeenNetworks: Set<String> {
        Set(d.stringArray(forKey: Key.seenNetworks) ?? [])
    }

    /// What has happened about checking each network, keyed by
    /// `NetworkIdentity.canonical`.
    ///
    /// Stored as JSON in a single key rather than as a plist dictionary,
    /// because the value is an enum with associated values. The
    /// dictionary-of-dictionaries pattern `phaseDurationSamples` uses does
    /// not stretch that far.
    ///
    /// A malformed or absent value reads as empty, which means every
    /// network is `.unchecked` — the correct behaviour for a corrupt read
    /// (check them again) rather than a crash. Per-entry decoding failures
    /// cannot happen: `ArrivalState.init(from:)` decodes an unrecognised
    /// state as `.unchecked` rather than throwing, precisely so one bad
    /// entry cannot wipe the map.
    static var arrivalStates: [String: ArrivalState] {
        get {
            guard let data = d.data(forKey: Key.arrivalStates) else { return [:] }
            return (try? JSONDecoder().decode([String: ArrivalState].self, from: data)) ?? [:]
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            d.set(data, forKey: Key.arrivalStates)
        }
    }

    /// Fold a legacy `seenNetworks` set into arrival states. Pure, so
    /// `VerifyMode` can check it without touching the real defaults.
    ///
    /// **Fails closed.** Everything it can name becomes `.checked` at
    /// `.distantPast`; everything it cannot name is dropped. The asymmetry
    /// is deliberate: a network wrongly assumed seen loses one automatic
    /// baseline and is one button away from getting it, while a network
    /// wrongly assumed new can spend a few hundred megabytes of someone's
    /// cellular data without asking.
    ///
    /// `.distantPast` rather than `Date()` so the entry is visibly a
    /// migration artefact — nothing in the UI claims a real check happened
    /// at that timestamp, because `runID` is nil and the card renders
    /// nothing for `.checked`.
    static func migratedArrivalStates(from legacy: Set<String>) -> [String: ArrivalState] {
        var out: [String: ArrivalState] = [:]
        for raw in legacy {
            guard let id = NetworkIdentity.canonical(raw) else { continue }
            out[id] = .checked(depth: .full, at: .distantPast, runID: nil)
        }
        return out
    }

    /// Run the migration once, on first launch of a build that has
    /// `arrivalStates`. Idempotent: an existing value means it has already
    /// run, and a second pass would resurrect networks the user has since
    /// been re-checked on.
    static func migrateArrivalStatesIfNeeded() {
        guard d.data(forKey: Key.arrivalStates) == nil else { return }
        arrivalStates = migratedArrivalStates(from: legacySeenNetworks)
    }

    // MARK: - Alerts
    //
    // All twelve ship on. The three that are nag-prone are tamed with long
    // dwell and long cooldown in AlertDefinitions rather than being shipped
    // off, because an alert the user never sees is indistinguishable from
    // one that does not exist.

    static var disabledAlerts: Set<String> {
        get { Set(d.stringArray(forKey: Key.disabledAlerts) ?? []) }
        set { d.set(Array(newValue), forKey: Key.disabledAlerts) }
    }

    static func isAlertEnabled(_ id: String) -> Bool { !disabledAlerts.contains(id) }

    static var notificationsEnabled: Bool {
        get { d.object(forKey: Key.notificationsEnabled) as? Bool ?? true }
        set { d.set(newValue, forKey: Key.notificationsEnabled) }
    }

    static var notificationScope: String {
        get { d.string(forKey: Key.notificationScope) ?? "all" }
        set { d.set(newValue, forKey: Key.notificationScope) }
    }
}

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case dotOnly = "dot"
    case dotAndFlag = "dot+flag"
    case dotFlagAndIP = "dot+flag+ip"
    case dotAndPing = "dot+ping"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dotOnly:      return "Status dot only"
        case .dotAndFlag:   return "Status dot and country flag"
        case .dotFlagAndIP: return "Status dot, flag, and IP address"
        case .dotAndPing:   return "Dot and ping time"
        }
    }
}
