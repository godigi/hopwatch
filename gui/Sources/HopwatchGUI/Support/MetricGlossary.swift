import Foundation

/// Central glossary providing concise, jargon-free explanations of technical
/// network metrics and their real-world impact for non-network engineers.
public enum MetricGlossary {
    public struct Entry: Equatable, Sendable {
        public let key: String
        public let title: String
        public let summary: String
        public let impact: String?

        public init(key: String, title: String, summary: String, impact: String? = nil) {
            self.key = key
            self.title = title
            self.summary = summary
            self.impact = impact
        }

        public var fullHelp: String {
            if let impact, !impact.isEmpty {
                return "\(summary)\n\nImpact: \(impact)"
            }
            return summary
        }
    }

    public static let allEntries: [Entry] = [
        Entry(
            key: "bufferbloat",
            title: "Bufferbloat (Under Load)",
            summary: "How much your connection's latency surges while large downloads or uploads saturate your bandwidth.",
            impact: "When a router or modem buffers excess packets under load, real-time activities like Zoom/FaceTime calls freeze or drop audio, and online games lag the moment someone starts a download or cloud backup."
        ),
        Entry(
            key: "mtu",
            title: "Packet Size (MTU)",
            summary: "Maximum Transmission Unit is the largest individual packet size (usually 1,500 bytes) that can travel your connection without being broken into fragments.",
            impact: "When MTU is too small or restricted by a VPN or tunnel, websites can stall indefinitely during SSL handshakes and large file transfers can slow down or fail."
        ),
        Entry(
            key: "rssi",
            title: "Wi-Fi Signal Strength (RSSI)",
            summary: "Received Signal Strength Indicator measures the radio signal power between your Mac and the Wi-Fi router in decibels (-30 dBm is excellent, -80 dBm is very weak).",
            impact: "A weak Wi-Fi signal causes sudden speed drops, packet retransmissions, and frequent dropouts even when your broadband line is perfectly fine."
        ),
        Entry(
            key: "snr",
            title: "Signal-to-Noise Ratio (SNR)",
            summary: "The difference in decibels (dB) between your Wi-Fi signal power and background radio noise. Higher is cleaner (>25 dB is strong, <15 dB is noisy).",
            impact: "Low SNR means microwave ovens, neighboring routers, or physical barriers are drowning out your signal, causing packet loss and jitter even if raw signal bars appear full."
        ),
        Entry(
            key: "ipv6",
            title: "IPv6",
            summary: "The modern internet addressing protocol that replaces IPv4, providing trillions of direct addresses and eliminating the need for address translation (NAT).",
            impact: "Services with IPv6 enabled often connect faster and avoid carrier-grade NAT bottlenecks. While lack of IPv6 is common, having it ensures seamless modern connectivity."
        ),
        Entry(
            key: "vpn",
            title: "Virtual Private Network (VPN)",
            summary: "An encrypted tunnel that routes all your network traffic through a private server or corporate gateway.",
            impact: "Safeguards privacy on public Wi-Fi hotspots, but can add extra routing delay, reduce effective MTU, and block connections to local network printers and smart home devices."
        ),
        Entry(
            key: "upnp",
            title: "Universal Plug and Play (UPnP)",
            summary: "A router protocol that lets local apps (like games or media servers) automatically open incoming network ports without manual configuration.",
            impact: "Convenient for peer-to-peer multiplayer and game consoles, but can be a security vulnerability if untrusted devices or malware open ports to the internet."
        ),
        Entry(
            key: "nat_topology",
            title: "NAT Topology & Double NAT",
            summary: "Network Address Translation maps local private device IPs to your single public IP. Double NAT means traffic passes through two consecutive routers doing translation.",
            impact: "Double NAT causes issues with peer-to-peer gaming, VoIP calls, smart home devices, and remote access by creating conflicting network boundaries."
        ),
        Entry(
            key: "clock",
            title: "Clock Drift",
            summary: "The time difference between your Mac's internal system clock and global atomic network time (NTP).",
            impact: "Security certificates and authentication protocols (OAuth, Kerberos) require accurate clocks. A drift of just a few seconds causes web browsers to throw SSL security warnings and fail to load sites."
        ),
        Entry(
            key: "dns",
            title: "Name Lookups (DNS)",
            summary: "The Domain Name System translates human website names (like apple.com) into numeric internet IP addresses.",
            impact: "Slow DNS lookups introduce an annoying pause every time you tap a link or open an app before any data starts moving. Failing DNS makes your internet look completely dead even when the link is working."
        ),
        Entry(
            key: "packet_loss",
            title: "Packet Loss",
            summary: "The percentage of data packets sent across the connection that never reached their destination and had to be resent.",
            impact: "Even 1% to 2% loss causes robotic audio, video freezing, and stutter in live calls. High packet loss (>5%) makes browsing sluggish and gaming unplayable."
        ),
        Entry(
            key: "router",
            title: "Router (Local Gateway)",
            summary: "The physical router in your home or office that bridges your Mac to the wider internet.",
            impact: "High latency or packet loss to your router points to local Wi-Fi interference, a damaged cable, or a struggling router, rather than an issue with your ISP."
        ),
        Entry(
            key: "internet",
            title: "Internet Latency (Ping)",
            summary: "The round-trip time in milliseconds for a signal to reach external internet servers and return to your Mac.",
            impact: "Lower ping (<30 ms) feels snappy and responsive; high latency (>100 ms) creates noticeable lag during video conferences and gaming."
        ),
        Entry(
            key: "speed",
            title: "Speed (Throughput)",
            summary: "The maximum transfer rate in Megabits per second (Mbps) for downloading data from and uploading data to the internet.",
            impact: "Download speed dictates 4K streaming and file download times. Upload speed is crucial for sending email attachments, cloud backups, and clear outgoing video on Zoom."
        ),
        Entry(
            key: "local_network",
            title: "Local Network (LAN & DHCP)",
            summary: "The local subnet addressing, ARP device table, and DHCP lease management on your local Wi-Fi or Ethernet.",
            impact: "IP address collisions, expired leases, or severe subnet crowding (e.g. device surges) can temporarily kick your Mac off the network or cause erratic connectivity."
        ),
        Entry(
            key: "availability",
            title: "Availability",
            summary: "The reliability of your internet connection over a 24-hour window, tracking recorded dropouts and downtime episodes.",
            impact: "Shows whether your connection suffers from frequent intermittent drops or ISP micro-outages throughout the day, even if it happens to be working right now."
        ),
        Entry(
            key: "traffic",
            title: "Local Traffic (Competing Activity)",
            summary: "Other applications or background processes running on your Mac that are actively uploading or downloading during the diagnostic test.",
            impact: "Identifies if large local activities (like iCloud syncing, Time Machine backups, or system updates) were eating bandwidth and skewing diagnostic results."
        ),
        Entry(
            key: "watcher",
            title: "Background Watcher",
            summary: "A lightweight background process that periodically verifies network health so you don't have to remember to run scans manually.",
            impact: "Maintains uninterrupted history and alerts you immediately when your connection degrades, even when the main window is closed."
        ),
        Entry(
            key: "speed_down",
            title: "Download Speed",
            summary: "How fast data arrives from the internet to your Mac during a full speed test.",
            impact: "Dictates how fast web pages load, files download, and 4K video streams without buffering."
        ),
        Entry(
            key: "speed_up",
            title: "Upload Speed",
            summary: "How fast data leaves your Mac for the internet during a full speed test.",
            impact: "Essential for smooth outgoing video on Zoom/FaceTime calls, sending files, and cloud backups."
        ),
    ]

    private static let entriesByKey: [String: Entry] = Dictionary(
        uniqueKeysWithValues: allEntries.map { ($0.key, $0) }
    )

    private static let entriesByLabel: [String: Entry] = [
        "bufferbloat": entriesByKey["bufferbloat"]!,
        "under load": entriesByKey["bufferbloat"]!,
        "packet size (mtu)": entriesByKey["mtu"]!,
        "path mtu": entriesByKey["mtu"]!,
        "mtu": entriesByKey["mtu"]!,
        "wi-fi signal": entriesByKey["rssi"]!,
        "wifi signal": entriesByKey["rssi"]!,
        "rssi": entriesByKey["rssi"]!,
        "wi-fi snr": entriesByKey["snr"]!,
        "wifi snr": entriesByKey["snr"]!,
        "snr": entriesByKey["snr"]!,
        "ipv6": entriesByKey["ipv6"]!,
        "vpn": entriesByKey["vpn"]!,
        "upnp": entriesByKey["upnp"]!,
        "nat topology": entriesByKey["nat_topology"]!,
        "double nat": entriesByKey["nat_topology"]!,
        "clock": entriesByKey["clock"]!,
        "clock drift": entriesByKey["clock"]!,
        "name lookups (dns)": entriesByKey["dns"]!,
        "dns": entriesByKey["dns"]!,
        "packet loss": entriesByKey["packet_loss"]!,
        "loss": entriesByKey["packet_loss"]!,
        "router": entriesByKey["router"]!,
        "gateway": entriesByKey["router"]!,
        "internet": entriesByKey["internet"]!,
        "latency": entriesByKey["internet"]!,
        "ping": entriesByKey["internet"]!,
        "speed": entriesByKey["speed"]!,
        "down": entriesByKey["speed_down"]!,
        "download": entriesByKey["speed_down"]!,
        "up": entriesByKey["speed_up"]!,
        "upload": entriesByKey["speed_up"]!,
        "local network": entriesByKey["local_network"]!,
        "availability": entriesByKey["availability"]!,
        "local traffic": entriesByKey["traffic"]!,
        "background watcher": entriesByKey["watcher"]!,
    ]

    /// Lookup glossary entry by key, label, or metric identifier.
    public static func entry(for query: String) -> Entry? {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let direct = entriesByKey[normalized] { return direct }
        if let byLabel = entriesByLabel[normalized] { return byLabel }

        // Alias matching for history keys and compound phrases
        switch normalized {
        case "bufferbloat_gw_ms", "bufferbloat_inet_ms":
            return entriesByKey["bufferbloat"]
        case "mtu_effective":
            return entriesByKey["mtu"]
        case "wifi_rssi_dbm", "wifi_signal":
            return entriesByKey["rssi"]
        case "wifi_snr_db":
            return entriesByKey["snr"]
        case "ntp_drift_s":
            return entriesByKey["clock"]
        case "dns_latency":
            return entriesByKey["dns"]
        case "inet_loss_pct", "gateway_loss_pct":
            return entriesByKey["packet_loss"]
        case "gateway_rtt_ms", "gateway_jitter_ms":
            return entriesByKey["router"]
        case "inet_rtt_ms":
            return entriesByKey["internet"]
        case "speed_down_mbps":
            return entriesByKey["speed_down"]
        case "speed_up_mbps":
            return entriesByKey["speed_up"]
        case "lan", "dhcp":
            return entriesByKey["local_network"]
        case "netdiag":
            return entriesByKey["watcher"]
        default:
            return nil
        }
    }

    /// Convenience for looking up plain-English help string.
    public static func help(for query: String) -> String? {
        entry(for: query)?.fullHelp
    }
}
