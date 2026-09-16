import Foundation

enum IPAddressValidation {
    /// Returns true if `ip` is an RFC1918 private IPv4 address:
    /// - 10.0.0.0/8 (10.0.0.0 – 10.255.255.255)
    /// - 172.16.0.0/12 (172.16.0.0 – 172.31.255.255)
    /// - 192.168.0.0/16 (192.168.0.0 – 192.168.255.255)
    static func isRFC1918PrivateIPv4(_ ip: String?) -> Bool {
        guard let ip = ip?.trimmingCharacters(in: .whitespacesAndNewlines), !ip.isEmpty else {
            return false
        }
        let parts = ip.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4,
              let a = Int(parts[0]), (0...255).contains(a),
              let b = Int(parts[1]), (0...255).contains(b),
              let c = Int(parts[2]), (0...255).contains(c),
              let d = Int(parts[3]), (0...255).contains(d) else {
            return false
        }
        if a == 10 { return true }
        if a == 172 && (16...31).contains(b) { return true }
        if a == 192 && b == 168 { return true }
        return false
    }

    /// Builds the router admin URL for an RFC1918 gateway IP.
    static func routerAdminURL(for gatewayIP: String?) -> URL? {
        guard let gatewayIP, isRFC1918PrivateIPv4(gatewayIP) else { return nil }
        return URL(string: "http://\(gatewayIP.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
}
