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
    /// Whether an IP address is a private, link-local, or shared subnet address
    /// that cannot uniquely identify a physical network or router.
    static func isPrivateOrLocalIP(_ ip: String) -> Bool {
        let trimmed = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        // IPv4 check
        let parts = trimmed.split(separator: ".")
        if parts.count == 4,
           let o1 = Int(parts[0]),
           let o2 = Int(parts[1]),
           let o3 = Int(parts[2]),
           let o4 = Int(parts[3]),
           o1 >= 0 && o1 <= 255, o2 >= 0 && o2 <= 255, o3 >= 0 && o3 <= 255, o4 >= 0 && o4 <= 255 {
            // 10.0.0.0/8
            if o1 == 10 { return true }
            // 172.16.0.0/12 (172.16.0.0 - 172.31.255.255)
            if o1 == 172 && (o2 >= 16 && o2 <= 31) { return true }
            // 192.168.0.0/16
            if o1 == 192 && o2 == 168 { return true }
            // 169.254.0.0/16 (link-local)
            if o1 == 169 && o2 == 254 { return true }
            // 100.64.0.0/10 (CGNAT: 100.64.0.0 - 100.127.255.255)
            if o1 == 100 && (o2 >= 64 && o2 <= 127) { return true }
            // 127.0.0.0/8 (loopback)
            if o1 == 127 { return true }
            return false
        }
        // IPv6 check (fe80::/10 link-local, fc00::/7 unique local)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("fe8") || lower.hasPrefix("fe9") || lower.hasPrefix("fea") || lower.hasPrefix("feb") {
            return true
        }
        if lower.hasPrefix("fc") || lower.hasPrefix("fd") {
            return true
        }
        if lower == "::1" { return true }
        return false
    }

    /// Whether a network key or IP refers to a private/local gateway.
    static func isPrivateOrLocalGateway(_ keyOrIP: String) -> Bool {
        let ip: String
        if keyOrIP.hasPrefix("gw:") {
            ip = String(keyOrIP.dropFirst(3))
        } else if let eq = keyOrIP.range(of: "gw=") {
            let rest = String(keyOrIP[eq.upperBound...])
            ip = String(rest.split(separator: ",").first ?? "")
        } else {
            ip = keyOrIP
        }
        return isPrivateOrLocalIP(ip)
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
            for key in used where weak.contains(key) && !isPrivateOrLocalGateway(key) {
                claims[key, default: []].insert(mac)
            }
        }
        return claims.compactMapValues { $0.count == 1 ? $0.first : nil }
    }
}
