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
        bands.first { band in
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

// MARK: - Band classification for a Wi-Fi channel

extension SignalScale {
    /// "2.4 GHz" / "5 GHz" / "6 GHz" for a monitor sample's channel
    /// string ("6", "36", "5 GHz", "2.4 GHz"…).
    ///
    /// Moved out of Views/DropdownView.swift (`resolvedBand`) in the
    /// reporting-accuracy plan: it is the same classification W6 in the
    /// CLI makes, and the numbers it reads are lib/thresholds.sh's
    /// THRESH_WIFI_24GHZ_MIN_CHANNEL / THRESH_WIFI_24GHZ_MAX_CHANNEL and
    /// the 5 GHz band's lower channel edge. Until those edges arrive as
    /// named constants this is presentation-side composition, parked here
    /// (one formatter, used everywhere) and marked for the CLI to own.
    static func bandName(forChannel channel: String?) -> String? {
        guard let chStr = channel else { return nil }
        if chStr.contains("2.4") { return "2.4 GHz" }
        if chStr.contains("5 GHz") || chStr.contains("5GHz") { return "5 GHz" }
        if chStr.contains("6 GHz") || chStr.contains("6GHz") { return "6 GHz" }
        let firstDigits = chStr.components(separatedBy: CharacterSet.decimalDigits.inverted).first { !$0.isEmpty }
        guard let firstDigits, let ch = Int(firstDigits) else { return nil }
        if ch <= 14 { return "2.4 GHz" }
        if ch >= 32 { return "5 GHz" }
        return nil
    }
}
