import Foundation

/// The one way this app names a network.
///
/// `helpers/history.py` has always canonicalised a network record into one
/// of three forms — `mac:` (strongest), `ssid:`, `gw:` (weakest) — and then
/// folded the weak forms onto the MAC group they belong to, so one physical
/// network is one group. The GUI never got that logic: `historyJoinID` fell
/// back to the raw *record* format when the CLI had not yet resolved a
/// group, and every dictionary keyed by network accumulated a mixture. One
/// live install held all three of `gw:10.125.128.1`,
/// `wifi:gw=10.125.128.1` and `mac:76:42:18:5c:40:64` for a single iPhone
/// hotspot, which is why its arrival check could be recorded under a key it
/// would never present under again.
///
/// Pure, and deliberately not a method on `MonitorSample.Network`: the
/// verify harness is the only runnable test host on this toolchain and it
/// must be able to call this without decoding a sample. Same shape and same
/// reason as `StageResolver` and `FullCheckPolicy`.
///
/// This is not a threshold and not a verdict — it is an identity. It says
/// which network you are on, never whether that network is any good.
enum NetworkIdentity {

    /// The CLI's sentinel for "could not identify this network". Treated
    /// exactly like an empty string: not an identity.
    private static let unknown = "unknown"

    /// Canonicalise either a record-format id (`wifi:mac=…`, `lan:gw=…`) or
    /// an already-canonical one (`mac:…`) into the canonical form.
    ///
    /// Returns `nil` when there is no identity to be had, and **`nil` means
    /// "do not decide yet", never "a new network"**. That distinction is
    /// the entire point of the optional: the previous code's `groupId ?? id`
    /// fallback treated an unresolved network as a nameable one, and every
    /// mixed key in the wild came from there.
    static func canonical(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != unknown else { return nil }

        // Already canonical: accept, but normalise a MAC's case so two
        // spellings of one address cannot be two keys.
        for prefix in ["mac:", "ssid:", "gw:"] where trimmed.hasPrefix(prefix) {
            let value = String(trimmed.dropFirst(prefix.count))
            guard !value.isEmpty else { return nil }
            return prefix == "mac:" ? "mac:\(value.lowercased())" : "\(prefix)\(value)"
        }

        // Record format: `<scope>:<k>=<v>,<k>=<v>`. The scope (`wifi`,
        // `lan`, …) is not part of the identity — the same gateway reached
        // over Wi-Fi and over Ethernet is the same network.
        guard let colon = trimmed.firstIndex(of: ":") else { return nil }
        let fields = parseFields(String(trimmed[trimmed.index(after: colon)...]))

        // Precedence is load-bearing and matches history.py.
        if let mac = fields["mac"], !mac.isEmpty { return "mac:\(mac.lowercased())" }
        if let ssid = fields["ssid"], !ssid.isEmpty { return "ssid:\(ssid)" }
        if let gw = fields["gw"], !gw.isEmpty { return "gw:\(gw)" }
        return nil
    }

    /// Split `k=v,k=v` into a dictionary. An SSID may legitimately contain
    /// `=`, so only the *first* `=` in each field separates key from value.
    private static func parseFields(_ body: String) -> [String: String] {
        var out: [String: String] = [:]
        for field in body.split(separator: ",", omittingEmptySubsequences: true) {
            guard let eq = field.firstIndex(of: "=") else { continue }
            let key = String(field[field.startIndex..<eq])
            let value = String(field[field.index(after: eq)...])
            out[key] = value
        }
        return out
    }

    /// Map weak keys onto the MAC group that shares them.
    ///
    /// `strong` is what each MAC group is known to have used — its
    /// gateways and SSIDs, in canonical form. `weak` is the set of
    /// non-MAC keys needing a home. The result maps each foldable weak key
    /// to its MAC key; a weak key with no matching group is **absent**
    /// rather than mapped to itself, so a caller can tell "folded" from
    /// "nothing known about this" without a second lookup.
    ///
    /// A weak key claimed by two MAC groups folds onto neither: two
    /// networks behind the same RFC-1918 gateway address is common (every
    /// 192.168.1.1 on earth), and merging them would be worse than leaving
    /// them apart.
    static func fold(_ strong: [String: [String]], weak: Set<String>) -> [String: String] {
        var claims: [String: Set<String>] = [:]
        for (mac, used) in strong {
            for key in used where weak.contains(key) {
                claims[key, default: []].insert(mac)
            }
        }
        return claims.compactMapValues { $0.count == 1 ? $0.first : nil }
    }
}
