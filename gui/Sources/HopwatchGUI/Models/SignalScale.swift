import Foundation
import SwiftUI

/// Lenient model of `netdiag --signal-scale` — see that schema in
/// docs/JSON-SCHEMA.md, and helpers/signal_scale.py for what writes it.
///
/// Exists so a raw RSSI number never reaches the screen as the only thing
/// describing it: CLAUDE.md's line about the GUI holding no diagnostic
/// logic applies just as much to "is -62 dBm good?" as it does to a rule
/// ID. This app looks a reading up against `bands` and shows the CLI's own
/// `label`; it never states a dBm boundary of its own.
///
/// Additive by the schema's own promise, same as `RulesCatalog` — every
/// property below degrades field by field rather than failing the whole
/// document, and `band(forRSSI:)` returning `nil` (no catalog loaded, or a
/// reading below every band's floor, which can't happen with a real one)
/// is exactly the signal every consumer already treats as "fall back to
/// raw dBm".
struct SignalScale: Decodable, Sendable {
    var schema: Int?
    var bands: [Band] = []

    enum CodingKeys: String, CodingKey { case schema, bands }

    /// One band from `bands`, strongest first. `minDBm` is `nil` only on
    /// the last (weakest) band — see the schema doc for why that is a
    /// floor-less "everything below here" band rather than a sentinel.
    struct Band: Decodable, Sendable {
        var minDBm: Int?
        var label: String?
        var tone: String?
        var blurb: String?

        enum CodingKeys: String, CodingKey { case minDBm = "min_dbm", label, tone, blurb }
    }

    /// The first band (strongest first) whose floor `rssi` clears — the
    /// exact walk docs/JSON-SCHEMA.md specifies: "the first one whose
    /// `min_dbm` the reading is `>=`". `nil` when `bands` hasn't loaded
    /// yet; never a Swift-authored fallback label.
    func band(forRSSI rssi: Int) -> Band? {
        bandIndex(forRSSI: rssi).map { bands[$0] }
    }

    /// Position of `band(forRSSI:)` in `bands` (0 = strongest).
    func bandIndex(forRSSI rssi: Int) -> Int? {
        bands.firstIndex { band in
            guard let minDBm = band.minDBm else { return true }
            return rssi >= minDBm
        }
    }

    /// One mapping from an RSSI reading to what a cell shows, shared by
    /// every call site that renders one (`DropdownView`'s Wi-Fi
    /// instrument, `HomeView`'s Wi-Fi row) so the word-plus-dBm treatment
    /// Item 1 asks for exists exactly once. `rssi == nil` renders "—" —
    /// no reading at all, distinct from a reading this build can't yet
    /// classify. A `scale` that hasn't loaded (or a reading below every
    /// band's floor, which can't happen with the open-ended last band but
    /// costs nothing to guard) falls back to the raw dBm text with no
    /// unit — today's pre-scale behavior — rather than a Swift-authored
    /// word.
    static func cellContent(rssi: Int?, scale: SignalScale?) -> (value: String, unit: String?, tint: Color) {
        guard let rssi else { return ("—", nil, .primary) }
        let dbmText = "\(rssi) dBm"
        guard let band = scale?.band(forRSSI: rssi), let label = band.label else {
            return (dbmText, nil, .primary)
        }
        return (label, dbmText, band.tint)
    }

    /// Human-friendly proximity phrase for a reading, read off the CLI's
    /// own band walk — never off a dBm number of this app's own.
    ///
    /// The previous version hard-coded -50 / -67 / -75 dBm here, which
    /// contradicted the header above (and disagreed with the CLI's -55 /
    /// -70 / -75, so the phrase and the band word shown beside it could
    /// name different bands for the same reading). Now the band the CLI
    /// puts the reading in decides it: strongest band is "Near router", the
    /// open-ended bottom band is "Too far from router", and the ones
    /// between are "Good range" then "Medium range".
    ///
    /// `nil` without a loaded `scale`, like `band(forRSSI:)` — callers
    /// already treat that as "show the raw dBm and the band word instead",
    /// and there is no Swift-authored fallback phrase. Pass
    /// `coordinator.signalScale.scale`.
    static func distanceGuidance(forRSSI rssi: Int?, scale: SignalScale? = nil) -> String? {
        guard let rssi, let scale, scale.bands.count >= 2,
              let index = scale.bandIndex(forRSSI: rssi) else { return nil }
        if index == 0 { return "Near router" }
        if index == scale.bands.count - 1 { return "Too far from router" }
        return index == 1 ? "Good range" : "Medium range"
    }
}

extension SignalScale.Band {
    /// Tint for `tone` — colour only, mirroring
    /// `RunDetail.Verdict.tint`'s header: this is the one place the
    /// good/ok/warn/bad → colour mapping lives, so nothing else in the
    /// app invents a second one.
    var tint: Color {
        switch tone {
        case "good": return .green
        case "ok":   return .green
        case "warn": return .yellow
        case "bad":  return .red
        default:     return .secondary
        }
    }
}

// MARK: - Lenient decoding

extension SignalScale {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = c.lenient(.schema)
        bands = c.lenient(.bands, [Band]())
    }
}

extension SignalScale.Band {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        minDBm = c.lenient(.minDBm)
        label = c.lenient(.label)
        tone = c.lenient(.tone)
        blurb = c.lenient(.blurb)
    }
}
