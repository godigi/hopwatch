import Foundation

/// One line of `netdiag --monitor`.
///
/// Every field is optional and every decode is lenient, for one reason: a
/// monitor sample is a *stream*, and a stream that throws on an unfamiliar
/// field stops the menu-bar indicator dead. The CLI may gain keys — it has
/// four times already — and the app must degrade to "I don't know that
/// yet" rather than to a blank icon.
///
/// Note what is *not* here: no thresholds, no severity computation, no
/// verdict strings. `status.rules` arrives pre-computed from
/// lib/monitor.sh, which reads the same lib/thresholds.sh that
/// lib/diagnosis.sh does. This type transports that decision; it never
/// makes one.
struct MonitorSample: Decodable, Sendable {
    var schema: Int?
    var version: String?
    var ts: String?
    var seq: Int?
    var gapS: Int?
    var jitterMs: Double?
    /// Which cadence tiers refreshed this cycle. Everything outside this
    /// list is carried over from an earlier sample — a chart drawing a
    /// point needs to know that before it plots one.
    var refreshed: [String] = []
    var link: Link = .init()
    var network: NetworkIdentity = .init()
    var vpn: VPN = .init()
    var gateway: Gateway = .init()
    var internet: Internet = .init()
    var wifi: WiFi?
    var dns: DNS = .init()
    var tcp: TCP = .init()
    var publicInfo: PublicInfo = .init()
    var status: Status = .init()
    /// Per-activity rows, per-hop states and the degraded hero's copy —
    /// all judged by helpers/inference.py from lib/thresholds.sh and
    /// rendered verbatim here. Absent blocks (older CLI, or thresholds
    /// missing at sampling time) mean "the CLI declines to judge" and
    /// every consumer renders a neutral fallback, never its own verdict.
    var suitability: [RunSnapshot.SuitabilityRow] = []
    var hops: Hops?
    var headline: Headline?
    /// Per-tier data age in seconds (schema 2, Phase 1 of the
    /// reporting-accuracy plan): `fast` is refreshed every cycle, and
    /// `medium`/`slow` say how far back their carried-over readings come
    /// from. `nil` per tier until that tier's first run — age 0 is a
    /// measurement, not the absence of one. Absent against an older CLI,
    /// which decodes as all-nil and leaves the blanking cells on ts-based
    /// staleness alone.
    var ageS: AgeS?

    /// Effective instantaneous jitter in ms, prioritizing internet then gateway.
    var liveJitterMs: Double? {
        jitterMs ?? internet.rttJitterMs ?? gateway.rttJitterMs
    }

    /// Field-level differences from the previous sample, phrased by the
    /// CLI (schema 2+). Absent — and therefore empty — when nothing
    /// changed. `kind` is the stream's stable `id` string; `from`/`to`
    /// are nullable (rule transitions carry null on one side).
    var changes: [Change] = []

    struct Change: Decodable, Sendable, Equatable {
        var kind: String = ""
        var field: String?
        var from: String?
        var to: String?
        var summary: String = ""

        enum CodingKeys: String, CodingKey {
            case kind = "id"
            case field, from, to, summary
        }
    }

    enum CodingKeys: String, CodingKey {
        case schema, version, ts, seq, refreshed, link, network, vpn
        case gateway, internet, wifi, dns, tcp, status, changes
        case suitability, hops, headline, ageS = "age_s"
        case gapS = "gap_s"
        case jitterMs = "jitter_ms"
        case publicInfo = "public"
    }

    struct Link: Decodable, Sendable {
        var up: Bool = false
        var interface: String?
        var type: String?
        var ip: String?
        var gateway: String?
        var gatewayMAC: String?
        var ssid: String?
        var bssid: String?

        enum CodingKeys: String, CodingKey {
            case up, interface, type, ip, gateway, ssid, bssid
            case gatewayMAC = "gateway_mac"
        }

        var isWiFi: Bool { type == "wifi" }
    }

    struct NetworkIdentity: Decodable, Sendable, Equatable {
        var id: String?
        var label: String?
        /// The canonical `--history` group key for this network
        /// (`network.group_id`, schema 2): `mac:…`, `gw:…` or `ssid:…`,
        /// derived by the same `netid_run` precedence `helpers/history.py`
        /// groups by. `nil` from a CLI older than the field — join on
        /// `historyJoinID`, which falls back to `id`, never on this raw.
        var groupId: String?

        /// The id to join against `--history`'s network groups with.
        ///
        /// Canonicalised, and **nil rather than a raw fallback**. The raw
        /// `id` is the *record* format (`wifi:mac=AA:BB:…`), which
        /// history.py canonicalises before grouping — joining on it never
        /// matches. The previous `groupId ?? id` papered over that by
        /// handing back a record-format string when the CLI had not yet
        /// resolved a group, which is how one live install accumulated
        /// `gw:10.125.128.1`, `wifi:gw=10.125.128.1` and
        /// `mac:76:42:18:5c:40:64` for a single iPhone hotspot.
        ///
        /// The `id` fallback is retained but canonicalised: a record-format
        /// id still yields a usable identity, it just yields the same one
        /// the group would. What is gone is the possibility of returning a
        /// non-canonical string.
        ///
        /// `nil` means "not identified yet", and every caller must treat it
        /// as "do not decide", never as "a new network". `id` remains
        /// available for display, which is the only thing it is fit for.
        ///
        /// Module-qualified because this struct is *also* called
        /// `NetworkIdentity`: unqualified, the name resolves to this nested
        /// type, which has no `canonical`.
        var historyJoinID: String? {
            if let groupId, let canonical = HopwatchGUI.NetworkIdentity.canonical(groupId) {
                return canonical
            }
            return HopwatchGUI.NetworkIdentity.canonical(id ?? "")
        }

        /// Whether the user controls the equipment on this network (e.g. home/office router).
        var isMine: Bool {
            get {
                if let explicit = explicitMine { return explicit }
                guard let nid = historyJoinID ?? id else { return false }
                return Defaults.networkOwned.contains(nid) || (self.id.map { Defaults.networkOwned.contains($0) } ?? false)
            }
            set {
                explicitMine = newValue
            }
        }
        var explicitMine: Bool?

        enum CodingKeys: String, CodingKey {
            case id, label
            case groupId = "group_id"
        }
    }

    struct VPN: Decodable, Sendable {
        var active: Bool = false
        var type: String?
        var name: String?

        enum CodingKeys: String, CodingKey {
            case active, type, name
        }
    }

    struct Gateway: Decodable, Sendable {
        /// `nil` is "not measured this cycle", never zero. The whole
        /// null-vs-0 discipline in docs/JSON-SCHEMA.md exists because
        /// treating the first as the second produced false criticals.
        var lossPct: Double?
        var rttAvgMs: Double?
        var rttJitterMs: Double?

        enum CodingKeys: String, CodingKey {
            case lossPct = "loss_pct"
            case rttAvgMs = "rtt_avg_ms"
            case rttJitterMs = "rtt_jitter_ms"
        }
    }

    struct Internet: Decodable, Sendable {
        var lossPct: Double?
        var rttAvgMs: Double?
        var rttJitterMs: Double?

        enum CodingKeys: String, CodingKey {
            case lossPct = "loss_pct"
            case rttAvgMs = "rtt_avg_ms"
            case rttJitterMs = "rtt_jitter_ms"
        }
    }

    struct WiFi: Decodable, Sendable {
        var rssi: Int?
        var noise: Int?
        var snr: Int?
        var channel: String?

        enum CodingKeys: String, CodingKey {
            case rssi, noise, snr, channel
        }
    }

    struct DNS: Decodable, Sendable {
        /// Three-valued on purpose: `nil` means the medium tier has not
        /// run yet this session.
        var ok: Bool?
        var resolver: String?
        var elapsedMs: Double?

        enum CodingKeys: String, CodingKey {
            case ok, resolver
            case elapsedMs = "elapsed_ms"
        }
    }

    struct TCP: Decodable, Sendable {
        /// One cycle's two connects, nothing more. NOT a verdict — at a
        /// ~2-in-3 refusal rate both fail on ~40% of cycles while browsing
        /// mostly works. Read `refused` for the verdict.
        var anyOk: Bool?
        var targets: [Target] = []
        /// The CLI's refused-connect verdict (TCP-2): ratio, the confirmed
        /// state, and the sentence to show. Absent against a CLI that
        /// predates it, which decodes as all-nil — no verdict, not "fine".
        var refused: Refused = .init()

        /// `state` and `summary` are decided in lib/monitor.sh against
        /// lib/thresholds.sh; `summary` is rendered verbatim and is nil
        /// unless the CLI confirmed the verdict. Never build a "blocked"
        /// headline from `anyOk` instead.
        struct Refused: Decodable, Sendable, Equatable {
            var pct: Double?
            var attempts: Int?
            /// `"warn"` or `"critical"` when TCP-2 is confirmed, else nil.
            var state: String?
            var summary: String?
        }

        enum CodingKeys: String, CodingKey {
            case targets, refused
            case anyOk = "any_ok"
        }

        struct Target: Decodable, Sendable {
            var host: String?
            var port: Int?
            var ok: Bool = false
            var elapsedMs: Double?

            enum CodingKeys: String, CodingKey {
                case host, port, ok
                case elapsedMs = "elapsed_ms"
            }
        }
    }

    /// Per-tier ages, in the stream's own `age_s` shape.
    struct AgeS: Decodable, Sendable, Equatable {
        var fast: Int?
        var medium: Int?
        var slow: Int?

        enum CodingKeys: String, CodingKey { case fast, medium, slow }
    }

    struct PublicInfo: Decodable, Sendable, Equatable {
        var ok: Bool?
        var ip: String?
        var isp: String?
        var asn: String?
        var city: String?
        /// Full country name ("Brazil"). `countryISO` is the alpha-2 the
        /// flag rendering needs; both come from the CLI so nothing here
        /// has to ship a country table.
        var country: String?
        var countryISO: String?
        var captivePortal: Bool?
        /// False (or nil on a stream older than the field) means the geo
        /// block was fetched and verified this cycle. True means the
        /// figures are last-KNOWN — the fetch (or the network change
        /// before its next fetch) has not verified them. Never blanked by
        /// a failed attempt; consumers do not blank the flag on it.
        var stale: Bool?

        enum CodingKeys: String, CodingKey {
            case ok, ip, isp, asn, city, country, stale
            case countryISO = "country_iso"
            case captivePortal = "captive_portal"
        }
    }

    /// The route card's three hops, judged CLI-side (helpers/inference.py,
    /// Phase 3 of the reporting plan): one warn flag (and a laggy flag on
    /// the Mac hop) plus one reason phrase per hop
    /// each. The cross-checks that decided these used to live as inline
    /// literals in Support/RouteWarningResolver.swift; the numbers they
    /// ride on are THRESH_GW_RTT_WARN_MS and THRESH_LATENCY_JITTER_WARN_MS
    /// in lib/thresholds.sh now.
    struct Hops: Decodable, Sendable {
        var mac: MacHop = .init()
        var router: WarnedHop = .init()
        var internet: InternetHop = .init()

        struct MacHop: Decodable, Sendable {
            var good: Bool = true
            var laggy: Bool = false
            /// The radio-scale word for the current RSSI ("Good", "Weak"),
            /// possibly with a laggy suffix and a roamed note — the CLI's
            /// phrase, rendered verbatim.
            var detail: String = ""

            enum CodingKeys: String, CodingKey { case good, laggy, detail }
        }

        struct WarnedHop: Decodable, Sendable {
            var warn: Bool = false
            var detail: String = ""
            /// The ping cell's value phrasing (the figure, "no reply",
            /// "TCP ok") — judged CLI-side, `""` meaning "render —".
            var value: String = ""
            /// LA-2's swing is on this leg (the Wi-Fi/router side), not the
            /// internet's — see `swing_leg` in helpers/inference.py.
            var jitterWarn: Bool = false
            var jitterNote: String?
            enum CodingKeys: String, CodingKey {
                case warn, detail, value
                case jitterWarn = "jitter_warn"
                case jitterNote = "jitter_note"
            }
        }

        struct InternetHop: Decodable, Sendable, Equatable {
            var warn: Bool = false
            var detail: String = ""
            var value: String = ""
            var jitterWarn: Bool = false
            var jitterNote: String?

            enum CodingKeys: String, CodingKey {
                case warn, detail, value
                case jitterWarn = "jitter_warn"
                case jitterNote = "jitter_note"
            }
        }
    }

    /// The degraded status hero's copy, authored CLI-side. `nil` while
    /// every grid activity is good — the healthy card's copy stays the
    /// app's own presentation.
    struct Headline: Decodable, Sendable, Equatable {
        var text: String = ""
        var subtitle: String = ""
        var critical: Bool = false
        /// Stage 2 of the monitor's two-stage clearing: nothing is failing
        /// now, but the link was unstable inside the stability window.
        var recovering: Bool = false
        enum CodingKeys: String, CodingKey { case text, subtitle, critical, recovering }
    }

    /// The monitor's own investigation / latency-test burst, run inside
    /// the process (no restart). `nil` in `Status.burst` when none is
    /// running; the GUI owns no timer for it.
    struct Burst: Decodable, Sendable, Equatable {
        var kind: String = "investigation"
        var intervalS: Int = 0
        /// ISO-8601 deadline; `remainingS` is the CLI's own countdown.
        var until: String = ""
        var remainingS: Int = 0
        enum CodingKeys: String, CodingKey {
            case kind, until
            case intervalS = "interval_s"
            case remainingS = "remaining_s"
        }
    }

    /// Two-stage clearing (lib/stability.sh), with the CLI's sentences.
    /// `state` is `stable`, `unstable` (a rule is firing or being held) or
    /// `recovering` (cleared, but not yet quiet for `windowS`).
    struct Stability: Decodable, Sendable, Equatable {
        var state: String = "stable"
        var windowS: Int?
        var lastAgoS: Int?
        var summary: String?
        var isRecovering: Bool { state == "recovering" }
        enum CodingKeys: String, CodingKey {
            case state, summary
            case windowS = "window_s"
            case lastAgoS = "last_ago_s"
        }
    }

    struct Status: Decodable, Sendable {
        var severity: String = "ok"
        /// `measured` means at least one fast reachability probe produced a
        /// result. `unknown` is not healthy: the link may be associated while
        /// traffic could not be tested. `link-down` is the explicit no-route
        /// state.
        var measurement: String = "unknown"
        /// Rule IDs from docs/DIAGNOSIS-RULES.md. The app maps these to
        /// alerts and renders them in the expert layer. It never decides
        /// whether one should have fired.
        var rules: [String] = []
        /// TCP-1 holds: real connections work, only ping is being dropped.
        /// The global suppressor for every loss alert — see AlertEngine.
        var icmpFiltered: Bool = false
        var degraded: Bool = false
        /// SIGUSR1 suspended probing. Every measurement in such a sample is
        /// carried over from before the pause, so a chart must not plot it
        /// and an alert must not fire on it.
        var paused: Bool = false
        var cadenceS: Int?
        var burst: Burst?
        var stability: Stability = .init()

        enum CodingKeys: String, CodingKey {
            case severity, rules, measurement, degraded, paused, burst, stability
            case icmpFiltered = "icmp_filtered"
            case cadenceS = "cadence_s"
        }
    }

    var timestamp: Date { FastISO8601.parse(ts) ?? Date() }

    /// The menu-bar dot's health. Judgement-free since the reporting-accuracy
    /// Phase 3: the severity is `status.severity` (rule IDs judged against
    /// lib/thresholds.sh in lib/monitor.sh), gated only by whether a
    /// reachability probe actually ran (`measurement`) and whether the
    /// link is joined. Earlier versions compared loss figures here — the
    /// one place the app still re-derived a verdict, and its cutoffs
    /// disagreed with the CLI's.
    var health: Health {
        guard link.up else { return .critical }
        // No rule firing is not the same as a successful check. Keep the
        // menu-bar indicator out of the green state until a router, internet,
        // or HTTPS reachability probe has actually produced evidence.
        guard status.measurement == "measured" else { return .warning }
        switch status.severity {
        case "critical": return .critical
        case "warn":     return .warning
        default:
            if status.degraded { return .warning }
            // Cleared, but not yet quiet for the stability window: the dot
            // must not read as an all-clear the link has not earned.
            if status.stability.isRecovering { return .warning }
            return .healthy
        }
    }
}

/// Lenient, in an extension so the memberwise initializer survives — the
/// same discipline `RunSnapshot` uses, for a sharper reason. Swift's
/// synthesized decode throws `keyNotFound` rather than falling back to the
/// default written beside a property, so a netdiag one version behind on
/// any one of these keys would fail the decode of the *whole* sample and
/// stop the menu-bar indicator dead. `status.paused` is the current
/// example: it did not exist before the pause protocol.
extension MonitorSample {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = c.lenient(.schema)
        version = c.lenient(.version)
        ts = c.lenient(.ts)
        seq = c.lenient(.seq)
        gapS = c.lenient(.gapS)
        jitterMs = c.lenient(.jitterMs)
        refreshed = c.lenient(.refreshed, [])
        link = c.lenient(.link, Link())
        network = c.lenient(.network, NetworkIdentity())
        vpn = c.lenient(.vpn, VPN())
        gateway = c.lenient(.gateway, Gateway())
        internet = c.lenient(.internet, Internet())
        wifi = c.lenient(.wifi)
        dns = c.lenient(.dns, DNS())
        tcp = c.lenient(.tcp, TCP())
        publicInfo = c.lenient(.publicInfo, PublicInfo())
        status = c.lenient(.status, Status())
        changes = c.lenient(.changes, [])
        suitability = c.lenient(.suitability, [])
        hops = c.lenient(.hops)
        headline = c.lenient(.headline)
        ageS = c.lenient(.ageS)
    }
}

extension MonitorSample.Hops {
    enum CodingKeys: String, CodingKey { case mac, router, internet }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mac = c.lenient(.mac, MacHop())
        router = c.lenient(.router, WarnedHop())
        internet = c.lenient(.internet, InternetHop())
    }
}

extension MonitorSample.Change {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = c.lenient(.kind, "")
        field = c.lenient(.field)
        from = c.lenient(.from)
        to = c.lenient(.to)
        summary = c.lenient(.summary, "")
    }
}

extension MonitorSample.Link {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        up = c.lenient(.up, false)
        interface = c.lenient(.interface)
        type = c.lenient(.type)
        ip = c.lenient(.ip)
        gateway = c.lenient(.gateway)
        gatewayMAC = c.lenient(.gatewayMAC)
        ssid = c.lenient(.ssid)
        bssid = c.lenient(.bssid)
    }
}

extension MonitorSample.NetworkIdentity {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id)
        label = c.lenient(.label)
        groupId = c.lenient(.groupId)
    }
}

extension MonitorSample.VPN {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        active = c.lenient(.active, false)
        type = c.lenient(.type)
        name = c.lenient(.name)
    }
}

extension MonitorSample.Gateway {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lossPct = c.lenient(.lossPct)
        rttAvgMs = c.lenient(.rttAvgMs)
        rttJitterMs = c.lenient(.rttJitterMs)
    }
}

extension MonitorSample.Internet {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lossPct = c.lenient(.lossPct)
        rttAvgMs = c.lenient(.rttAvgMs)
        rttJitterMs = c.lenient(.rttJitterMs)
    }
}

extension MonitorSample.WiFi {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rssi = c.lenient(.rssi)
        noise = c.lenient(.noise)
        snr = c.lenient(.snr)
        channel = c.lenient(.channel)
    }
}

extension MonitorSample.DNS {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = c.lenient(.ok)
        resolver = c.lenient(.resolver)
        elapsedMs = c.lenient(.elapsedMs)
    }
}

extension MonitorSample.TCP.Target {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = c.lenient(.host)
        port = c.lenient(.port)
        ok = c.lenient(.ok, false)
        elapsedMs = c.lenient(.elapsedMs)
    }
}

extension MonitorSample.TCP {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        anyOk = c.lenient(.anyOk)
        targets = c.lenient(.targets, [])
        refused = c.lenient(.refused, Refused())
    }
}

extension MonitorSample.TCP.Refused {
    enum CodingKeys: String, CodingKey { case pct, attempts, state, summary }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pct = c.lenient(.pct)
        attempts = c.lenient(.attempts)
        state = c.lenient(.state)
        summary = c.lenient(.summary)
    }
}

extension MonitorSample.AgeS {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fast = c.lenient(.fast)
        medium = c.lenient(.medium)
        slow = c.lenient(.slow)
    }
}

extension MonitorSample.PublicInfo {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = c.lenient(.ok)
        ip = c.lenient(.ip)
        isp = c.lenient(.isp)
        asn = c.lenient(.asn)
        city = c.lenient(.city)
        country = c.lenient(.country)
        countryISO = c.lenient(.countryISO)
        captivePortal = c.lenient(.captivePortal)
        stale = c.lenient(.stale)
    }
}

extension MonitorSample.Status {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        severity = c.lenient(.severity, "ok")
        measurement = c.lenient(.measurement, "unknown")
        rules = c.lenient(.rules, [])
        icmpFiltered = c.lenient(.icmpFiltered, false)
        degraded = c.lenient(.degraded, false)
        paused = c.lenient(.paused, false)
        cadenceS = c.lenient(.cadenceS)
        burst = c.lenient(.burst)
        stability = c.lenient(.stability, MonitorSample.Stability())
    }
}

extension MonitorSample.Burst {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = c.lenient(.kind, "investigation")
        intervalS = c.lenient(.intervalS, 0)
        until = c.lenient(.until, "")
        remainingS = c.lenient(.remainingS, 0)
    }
}

extension MonitorSample.Stability {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = c.lenient(.state, "stable")
        windowS = c.lenient(.windowS)
        lastAgoS = c.lenient(.lastAgoS)
        summary = c.lenient(.summary)
    }
}

extension MonitorSample.Hops.MacHop {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        good = c.lenient(.good, true)
        laggy = c.lenient(.laggy, false)
        detail = c.lenient(.detail, "")
    }
}

extension MonitorSample.Hops.WarnedHop {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        warn = c.lenient(.warn, false)
        detail = c.lenient(.detail, "")
        value = c.lenient(.value, "")
        jitterWarn = c.lenient(.jitterWarn, false)
        jitterNote = c.lenient(.jitterNote)
    }
}

extension MonitorSample.Hops.InternetHop {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        warn = c.lenient(.warn, false)
        detail = c.lenient(.detail, "")
        value = c.lenient(.value, "")
        jitterWarn = c.lenient(.jitterWarn, false)
        jitterNote = c.lenient(.jitterNote)
    }
}

extension MonitorSample.Headline {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = c.lenient(.text, "")
        subtitle = c.lenient(.subtitle, "")
        critical = c.lenient(.critical, false)
        recovering = c.lenient(.recovering, false)
    }
}

/// The menu-bar dot has three states. Deliberately not four: "info" is a
/// heads-up (a VPN is carrying your traffic), not a fault, and colouring it
/// differently from healthy would train the user to ignore the one colour
/// that matters.
enum Health: Sendable {
    case healthy, warning, critical
    /// Nobody is watching — monitoring is switched off or held. Distinct
    /// from `.healthy` on purpose: the dot's job is to answer "is my
    /// connection OK", and the honest answer while paused is "I don't
    /// know", not the last answer from before we stopped looking.
    /// `MonitorStream.stop()` deliberately keeps its final sample (the
    /// dropdown still shows those readings, correctly labelled as stale),
    /// so without this case `currentHealth` fell through to it and left a
    /// green dot in the menu bar over a "Monitoring paused" card.
    case paused

    var symbol: String {
        switch self {
        case .healthy:  return "circle.fill"
        case .warning:  return "exclamationmark.circle.fill"
        case .critical: return "xmark.circle.fill"
        case .paused:   return "pause.circle.fill"
        }
    }

    /// What VoiceOver reads for the menu-bar item. The dot carries the whole
    /// state of the app in one glyph, so it needs words as well as a colour.
    var accessibilityLabel: String {
        switch self {
        case .healthy:  return "Network healthy"
        case .warning:  return "Network warning"
        case .critical: return "Network problem"
        case .paused:   return "Monitoring paused"
        }
    }
}
