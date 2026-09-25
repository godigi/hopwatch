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

    /// Probes whether a router admin web page exists at the specified URL.
    /// Fast 1.5s timeout HEAD request (falls back to quick GET).
    /// Returns true for any HTTP response (status code 200...499) or self-signed HTTPS certificates.
    static func probeRouterAdminPage(at url: URL, session: URLSession = .shared) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 1.5
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        do {
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse {
                return (200...499).contains(http.statusCode)
            }
            return false
        } catch {
            if isUntrustedCertificateError(error) { return true }
            // Some embedded web servers reject HEAD with 405 or reset; try GET with short timeout
            var getReq = URLRequest(url: url)
            getReq.httpMethod = "GET"
            getReq.timeoutInterval = 1.5
            getReq.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            do {
                let (_, response) = try await session.data(for: getReq)
                if let http = response as? HTTPURLResponse {
                    return (200...499).contains(http.statusCode)
                }
                return false
            } catch {
                return isUntrustedCertificateError(error)
            }
        }
    }

    private static func isUntrustedCertificateError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .serverCertificateUntrusted,
             .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid:
            return true
        default:
            return false
        }
    }
}

/// Thread-safe in-memory cache and in-flight deduplicator for router admin page reachability probes.
actor RouterAdminProbeStore {
    static let shared = RouterAdminProbeStore()
    private var cache: [String: Bool] = [:]
    private var inFlight: [String: Task<Bool, Never>] = [:]

    func checkAvailability(for ip: String?) async -> Bool {
        guard let ip, let url = IPAddressValidation.routerAdminURL(for: ip) else { return false }
        let cleanIP = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cached = cache[cleanIP] {
            return cached
        }
        if let existing = inFlight[cleanIP] {
            return await existing.value
        }
        let task = Task<Bool, Never> {
            let available = await IPAddressValidation.probeRouterAdminPage(at: url)
            return available
        }
        inFlight[cleanIP] = task
        let result = await task.value
        cache[cleanIP] = result
        inFlight.removeValue(forKey: cleanIP)
        return result
    }

    func cachedAvailability(for ip: String?) -> Bool? {
        guard let ip else { return nil }
        return cache[ip.trimmingCharacters(in: .whitespacesAndNewlines)]
    }
}
