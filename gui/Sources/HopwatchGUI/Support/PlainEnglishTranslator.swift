import Foundation

/// Plain-English explanation of a diagnostic finding for non-technical users ("Explain Like I'm 5").
public struct PlainExplanation: Equatable, Sendable, Codable, Hashable {
    /// Friendly, jargon-free title describing the problem.
    public let title: String
    /// Simple explanation of why this happens in everyday language.
    public let explanation: String
    /// Concrete, actionable steps the user can take to fix or mitigate the issue.
    public let action: String

    public init(title: String, explanation: String, action: String) {
        self.title = title
        self.explanation = explanation
        self.action = action
    }

    // Convenience accessors matching ELI5 terminology
    public var plainTitle: String { title }
    public var plainExplanation: String { explanation }
    public var whatYouCanDo: String { action }
}

/// Translates technical diagnostic rules and symptoms into simple, everyday, "Explain Like I'm 5" (ELI5) language.
public enum PlainEnglishTranslator {

    // MARK: - Primary Translation APIs

    /// Translates a given rule ID and/or finding summary into a simple, friendly explanation.
    public static func translate(ruleId: String? = nil, summary: String = "") -> PlainExplanation {
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)

        if let ruleId = ruleId {
            let normalized = normalizeRuleId(ruleId)
            if !normalized.isEmpty, let curated = curatedRules[normalized] {
                return curated
            }
        }

        // If rule ID wasn't known or was nil, check if the summary matches known technical patterns
        if !trimmedSummary.isEmpty {
            if let fromSummary = translateSummaryPatterns(trimmedSummary) {
                return fromSummary
            }

            // Fallback for an unclassified summary with no known rule
            let displayTitle: String
            if trimmedSummary.count <= 60 {
                displayTitle = trimmedSummary.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            } else {
                displayTitle = "Network Issue Detected"
            }

            return PlainExplanation(
                title: displayTitle,
                explanation: "Hopwatch detected this condition: \"\(trimmedSummary)\". This may affect your connection's speed, responsiveness, or stability.",
                action: "Restart your router, check your physical connections or Wi-Fi, and run another test if the issue persists."
            )
        }

        // Fallback for unknown rule ID without any summary
        if let ruleId = ruleId {
            let cleanId = ruleId.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanId.isEmpty {
                return PlainExplanation(
                    title: "Network Issue Detected (\(cleanId))",
                    explanation: "Hopwatch detected diagnostic rule \(cleanId) on your network connection, which may impact reliability or performance.",
                    action: "Restart your router, check your physical connections or Wi-Fi, and run another test if the issue persists."
                )
            }
        }

        // Generic default when neither rule ID nor summary is present
        return PlainExplanation(
            title: "Network Issue Detected",
            explanation: "Hopwatch detected a network condition that may affect your connection reliability or performance.",
            action: "Restart your router, check your physical connections or Wi-Fi, and run another test if the issue persists."
        )
    }

    /// Convenience overload taking only a finding summary string.
    public static func translate(summary: String) -> PlainExplanation {
        translate(ruleId: nil, summary: summary)
    }

    /// Translates a `RulesCatalog.Rule` directly, using curated ELI5 explanations when available,
    /// or synthesizing one from the rule's metadata.
    static func translate(rule: RulesCatalog.Rule) -> PlainExplanation {
        let normalized = normalizeRuleId(rule.id)
        if let curated = curatedRules[normalized] {
            return curated
        }

        let title = rule.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let blurb = rule.blurb?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fix = (rule.fix ?? rule.fixAway)?.trimmingCharacters(in: .whitespacesAndNewlines)

        return PlainExplanation(
            title: (title?.isEmpty == false) ? title! : "Network Finding (\(rule.id))",
            explanation: (blurb?.isEmpty == false) ? blurb! : "Hopwatch flagged rule \(rule.id) on your network connection.",
            action: (fix?.isEmpty == false) ? fix! : "Restart your router, check your network settings, and test again."
        )
    }

    // MARK: - Individual Component Accessors

    /// Returns a plain-English title for a rule ID or finding summary.
    public static func plainTitle(for ruleId: String? = nil, summary: String = "") -> String {
        translate(ruleId: ruleId, summary: summary).title
    }

    /// Returns a plain-English explanation for a rule ID or finding summary.
    public static func plainExplanation(for ruleId: String? = nil, summary: String = "") -> String {
        translate(ruleId: ruleId, summary: summary).explanation
    }

    /// Returns actionable advice for a rule ID or finding summary.
    public static func whatYouCanDo(for ruleId: String? = nil, summary: String = "") -> String {
        translate(ruleId: ruleId, summary: summary).action
    }

    // Convenience overloads with ruleId parameter label
    public static func plainTitle(ruleId: String) -> String {
        translate(ruleId: ruleId, summary: "").title
    }

    public static func plainExplanation(ruleId: String) -> String {
        translate(ruleId: ruleId, summary: "").explanation
    }

    public static func whatYouCanDo(ruleId: String) -> String {
        translate(ruleId: ruleId, summary: "").action
    }

    // MARK: - Normalization Helpers

    private static func normalizeRuleId(_ raw: String) -> String {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        // Strip enclosing square brackets like "[W1]"
        if cleaned.hasPrefix("[") && cleaned.hasSuffix("]") {
            cleaned = String(cleaned.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Strip "RULE " prefix if present
        if cleaned.hasPrefix("RULE ") {
            cleaned = String(cleaned.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Map known aliases to canonical keys in curatedRules
        return ruleAliases[cleaned] ?? cleaned
    }

    private static let ruleAliases: [String: String] = [
        "WIFI1": "WIFI-1",
        "WIFI2": "WIFI-2",
        "GW1": "GW-1",
        "INET1": "INET-1",
        "BLOAT1": "BLOAT-1",
        "BLOAT2": "BLOAT-2",
        "DNS1": "DNS-1",
        "DNS2": "DNS-2",
        "MTU1": "MTU-1",
        "ARP1": "ARP-1",
        "DESYNC1": "DESYNC-1",
        "TIME-1": "DESYNC-1",
        "CLOCK-1": "DESYNC-1",
        "PORTAL-1": "CP-1",
        // Map CLI codes to prompt-friendly alias definitions where exact matches are expected
        "W1": "WIFI-1",
        "W2": "WIFI-2",
        "B1": "BLOAT-1",
        "B2": "BLOAT-2",
        "D1": "DNS-1",
        "D2": "DNS-2",
        "M1": "MTU-1",
        "NT-1": "DESYNC-1",
    ]

    // MARK: - Summary Heuristic Matcher

    private static func translateSummaryPatterns(_ summary: String) -> PlainExplanation? {
        let lower = summary.lowercased()

        if lower.contains("bufferbloat") || lower.contains("under load") || lower.contains("saturation") {
            return curatedRules["BLOAT-1"]
        }
        if lower.contains("captive portal") || lower.contains("sign in") || lower.contains("sign-in") || lower.contains("terms page") {
            return curatedRules["CP-1"]
        }
        if lower.contains("weak wi-fi") || lower.contains("weak wifi") || lower.contains("signal strength") || lower.contains("rssi") {
            return curatedRules["WIFI-1"]
        }
        if lower.contains("wi-fi interference") || lower.contains("noise") || lower.contains("snr") {
            return curatedRules["WIFI-2"]
        }
        if lower.contains("sticky ap") || lower.contains("distant access point") {
            return curatedRules["W3"]
        }
        if lower.contains("2.4 ghz") && (lower.contains("5 ghz") || lower.contains("slow band")) {
            return curatedRules["W6"]
        }
        if lower.contains("airdrop") || lower.contains("awdl") || lower.contains("wireless direct") {
            return curatedRules["AWDL-1"]
        }
        if lower.contains("dns") || lower.contains("name lookup") || lower.contains("domain name") {
            if lower.contains("down") || lower.contains("unresponsive") || lower.contains("failing") || lower.contains("failed") {
                return curatedRules["DNS-2"]
            }
            return curatedRules["DNS-1"]
        }
        if lower.contains("gateway") || lower.contains("router communication") || lower.contains("loss to router") || lower.contains("loss to gateway") {
            return curatedRules["GW-1"]
        }
        if lower.contains("public ip") || lower.contains("ip address changed") {
            return curatedRules["public-ip-changed"]
        }
        if lower.contains("severe packet loss") || lower.contains("severe internet loss") || lower.contains("heavy packet loss") {
            return curatedRules["L1"]
        }
        if lower.contains("packet loss") || lower.contains("loss") || lower.contains("dropped packets") {
            return curatedRules["L2"]
        }
        if lower.contains("internet unreachable") || lower.contains("outage") || lower.contains("no internet") || lower.contains("offline") {
            return curatedRules["INET-1"]
        }
        if lower.contains("mtu") || lower.contains("packet size") {
            return curatedRules["MTU-1"]
        }
        if lower.contains("clock") || lower.contains("drift") || lower.contains("ntp") || lower.contains("desync") {
            return curatedRules["DESYNC-1"]
        }
        if lower.contains("vpn") {
            return curatedRules["VPN-1"]
        }
        if lower.contains("arp") || lower.contains("duplicate ip") || lower.contains("ip conflict") {
            return curatedRules["ARP-1"]
        }
        if lower.contains("half duplex") || lower.contains("half-duplex") {
            return curatedRules["ETH-2"]
        }
        if lower.contains("ethernet") {
            return curatedRules["ETH-1"]
        }
        if lower.contains("dhcp") || lower.contains("lease") {
            return curatedRules["DH-1"]
        }
        if lower.contains("double nat") || lower.contains("double-nat") {
            return curatedRules["NAT-1"]
        }
        if lower.contains("ipv6") {
            return curatedRules["V6-1"]
        }

        return nil
    }

    // MARK: - Curated ELI5 Rule Explanations

    private static let curatedRules: [String: PlainExplanation] = [
        // Prompt-specified core rules
        "WIFI-1": PlainExplanation(
            title: "Weak Wi-Fi Signal",
            explanation: "Your Mac is struggling to receive radio waves from your router. You may be too far away, behind concrete or brick walls, or on a crowded frequency.",
            action: "Move closer to your router, switch to 5 GHz or 6 GHz Wi-Fi, or connect with an Ethernet cable."
        ),
        "WIFI-2": PlainExplanation(
            title: "Wi-Fi Interference / Noisy Signal",
            explanation: "Background radio noise from appliances, thick walls, or neighboring Wi-Fi networks is competing with your wireless connection.",
            action: "Move away from appliances and thick walls, switch your router to a less crowded channel, or connect using an Ethernet cable."
        ),
        "GW-1": PlainExplanation(
            title: "Router Communication Problem",
            explanation: "Your Mac is losing packets or having trouble talking directly to your local router or gateway, even before reaching the internet.",
            action: "Restart your router, check your Wi-Fi or Ethernet connection, and make sure cables are firmly plugged in."
        ),
        "INET-1": PlainExplanation(
            title: "Internet Provider Outage",
            explanation: "Your local connection to your router is working, but your router cannot reach the broader internet. Your Internet Service Provider (ISP) may have an outage.",
            action: "Restart your modem and router. If the issue persists, check your ISP's outage page or call their support line."
        ),
        "L1": PlainExplanation(
            title: "Severe Internet Packet Loss",
            explanation: "A large portion of data traveling between your Mac and the internet is getting lost along the way, causing stuttering, frozen calls, and sluggish browsing.",
            action: "Check whether other devices in your home are also affected. If they are, restart your modem or contact your internet provider."
        ),
        "P1": PlainExplanation(
            title: "Internet Provider Outage",
            explanation: "Your Mac can reach your local router, but cannot reach any websites or internet servers outside your home.",
            action: "Restart your modem and router. If the issue persists, check your ISP's outage page or call their support line."
        ),
        "BLOAT-1": PlainExplanation(
            title: "Network Overload (Bufferbloat)",
            explanation: "Your router is buffering too much data during heavy downloading or uploading, causing video calls to freeze and games to lag.",
            action: "Pause large downloads or cloud backups during calls, or enable Smart Queue Management (SQM) / QoS in your router settings."
        ),
        "BLOAT-2": PlainExplanation(
            title: "Internet Provider Bufferbloat",
            explanation: "Your internet provider's modem or uplink queue is overwhelmed during heavy traffic, adding huge delays to real-time traffic.",
            action: "Limit heavy upload or download activity during important calls, or contact your provider to ask about modem firmware updates or improved plans."
        ),
        "DNS-1": PlainExplanation(
            title: "Sluggish Website Lookup (DNS)",
            explanation: "Your Mac takes an unusually long time to look up server addresses, making websites pause before they start loading.",
            action: "Change your DNS servers in System Settings or router settings to faster alternatives like Cloudflare (1.1.1.1) or Google (8.8.8.8)."
        ),
        "DNS-2": PlainExplanation(
            title: "Website Lookup Failure (DNS Down)",
            explanation: "Your DNS server is not responding at all, so your Mac cannot translate website names (like google.com) into IP addresses.",
            action: "Switch your DNS settings to reliable public DNS providers like Cloudflare (1.1.1.1) or Google (8.8.8.8)."
        ),
        "MTU-1": PlainExplanation(
            title: "Packet Size Limit Issue (MTU)",
            explanation: "Large chunks of network data are too big to pass through your connection or VPN without getting broken up or dropped, causing websites to stall.",
            action: "If using a VPN, lower the MTU setting in your VPN app, or adjust your router's MTU setting to 1492 or 1400."
        ),
        "ARP-1": PlainExplanation(
            title: "Local Device Conflict (ARP / IP Conflict)",
            explanation: "Another device on your local network might be using the same IP address as your Mac or router, causing network confusion.",
            action: "Disconnect and reconnect your Wi-Fi, renew your DHCP lease in Mac Network Settings, or restart your router."
        ),
        "VPN-1": PlainExplanation(
            title: "VPN Rerouting Traffic",
            explanation: "A Virtual Private Network is encrypting and redirecting your internet traffic through a remote server, which may add delay or change performance.",
            action: "If your connection feels slow or local devices won't connect, try switching VPN servers or temporarily disconnecting the VPN."
        ),
        "DESYNC-1": PlainExplanation(
            title: "System Clock Out of Sync",
            explanation: "Your Mac's internal clock differs from internet atomic time, which breaks secure website certificates and logins.",
            action: "Open System Settings > General > Date & Time and toggle 'Set date and time automatically' off and back on."
        ),

        // RulesCatalog items
        "N1": PlainExplanation(
            title: "No Network Connection",
            explanation: "Nothing is connected: Wi-Fi is disconnected and no Ethernet cable is plugged in.",
            action: "Turn on Wi-Fi and select a network, or plug in an Ethernet cable."
        ),
        "N1B": PlainExplanation(
            title: "Internet Unreachable",
            explanation: "Your Mac is connected to your local router, but nothing on the public internet responds.",
            action: "Check your modem and router, or run a full network scan to pinpoint the fault."
        ),
        "N1C": PlainExplanation(
            title: "Action Required to Access Internet",
            explanation: "You are connected to a network that requires signing in through a browser before allowing internet access (like in a hotel, cafe, or airport).",
            action: "Open your web browser to view and accept the network's sign-in or splash page."
        ),
        "W3": PlainExplanation(
            title: "Connected to Distant Access Point",
            explanation: "Your Mac is clinging to a far-away Wi-Fi access point instead of connecting to a closer, stronger one.",
            action: "Turn Wi-Fi off and back on in the menu bar to force your Mac to connect to the nearest access point."
        ),
        "W4": PlainExplanation(
            title: "Wi-Fi Link Speed Dropped",
            explanation: "The wireless transfer speed between your Mac and your router has slowed to a crawl.",
            action: "Move closer to your router, remove obstacles, or restart your Wi-Fi connection."
        ),
        "W5": PlainExplanation(
            title: "Asymmetric Wi-Fi Link",
            explanation: "Your Mac receives signals from your router well, but the router is having trouble hearing your Mac's return signals.",
            action: "Move closer to your router or elevate your router off the floor and away from obstructions."
        ),
        "W6": PlainExplanation(
            title: "Connected to Slow 2.4 GHz Wi-Fi",
            explanation: "Your Mac is connected to the older, slower 2.4 GHz Wi-Fi band even though faster 5 GHz or 6 GHz Wi-Fi is available.",
            action: "Open Wi-Fi settings and choose your router's 5 GHz or 6 GHz network for much faster speeds."
        ),
        "AWDL-1": PlainExplanation(
            title: "Apple Wireless Direct Interference",
            explanation: "Apple background features like AirDrop, AirPlay, or Sidecar are causing periodic lag spikes on your Wi-Fi.",
            action: "Turn off AirDrop or disconnect wireless Sidecar displays while gaming or making critical video calls."
        ),
        "WS-1": PlainExplanation(
            title: "Crowded Wi-Fi Channel",
            explanation: "Too many neighboring Wi-Fi networks are broadcasting on the exact same channel, causing network traffic jams.",
            action: "Restart your router so it automatically picks an open channel, or choose an empty channel in router settings."
        ),
        "WF-1": PlainExplanation(
            title: "Wi-Fi Turned Off",
            explanation: "Your Mac's Wi-Fi antenna is turned off, so no wireless networks can be reached.",
            action: "Turn Wi-Fi on using the Wi-Fi icon in the macOS menu bar or Control Center."
        ),
        "WJ-1": PlainExplanation(
            title: "Wi-Fi Disconnected",
            explanation: "Your Wi-Fi connection dropped unexpectedly and your Mac has not rejoined a network.",
            action: "Click the Wi-Fi menu bar icon and select your network to reconnect."
        ),
        "WD-1": PlainExplanation(
            title: "Wi-Fi Connection Flapping",
            explanation: "Your Mac is frequently disconnecting or rapidly hopping back and forth between different access points.",
            action: "Stay in one spot or remove duplicate or obsolete saved networks in System Settings."
        ),
        "WI-1": PlainExplanation(
            title: "Network Name Withheld by macOS",
            explanation: "macOS is hiding the Wi-Fi network name from Hopwatch because Location Services permission has not been granted.",
            action: "Enable Location Services for Hopwatch in System Settings > Privacy & Security > Location Services."
        ),
        "DQ-1": PlainExplanation(
            title: "Multiple Networks Detected During Test",
            explanation: "The network changed or reconnected while the test was running, mixing results from two different networks.",
            action: "Run the test again while remaining connected to a single network."
        ),
        "G1": PlainExplanation(
            title: "Router Packet Loss (Weak Wi-Fi)",
            explanation: "Your Mac is losing packets to your router because your Wi-Fi signal is too weak or unstable.",
            action: "Move closer to your router, switch to 5 GHz or 6 GHz Wi-Fi, or connect with an Ethernet cable."
        ),
        "G2": PlainExplanation(
            title: "Router Dropping Packets",
            explanation: "Your local router is dropping packets, usually because its processor is overloaded, overheated, or needs a reboot.",
            action: "Restart your router by unplugging its power adapter for 15 seconds, then plug it back in."
        ),
        "G3": PlainExplanation(
            title: "Occasional Router Packet Loss",
            explanation: "A small number of packets are being dropped on the way to your router, but most traffic is still getting through.",
            action: "Check your Wi-Fi signal or Ethernet cable. If drops continue or worsen, restart your router."
        ),
        "P2": PlainExplanation(
            title: "Internet Unreachable, DNS Fine",
            explanation: "Your Mac can look up website names via DNS, but actual data cannot reach public internet servers.",
            action: "Restart your modem and router. Contact your ISP if internet connectivity does not return."
        ),
        "L2": PlainExplanation(
            title: "Moderate Internet Packet Loss",
            explanation: "Some data packets are getting lost across the internet connection, causing occasional video pauses and minor audio glitches.",
            action: "Restart your modem and router, and check if someone else on your network is using all the bandwidth."
        ),
        "ICMP-1": PlainExplanation(
            title: "Ping Responses Blocked",
            explanation: "Your network is working properly, but routers along the path are configured not to reply to test pings.",
            action: "No action needed — your connection is healthy and working normally."
        ),
        "TCP-1": PlainExplanation(
            title: "Ping Blocked, Web Traffic Working",
            explanation: "Ping diagnostic packets are blocked by a firewall, but web and application traffic flows normally.",
            action: "No action needed — web browsing and apps are functioning properly."
        ),
        "D3": PlainExplanation(
            title: "Slow DNS Server",
            explanation: "Your DNS server responds slowly, adding a noticeable delay every time you click a new web link.",
            action: "Switch your DNS servers to 1.1.1.1 (Cloudflare) or 8.8.8.8 (Google) in macOS Network Settings."
        ),
        "D4": PlainExplanation(
            title: "DNS Searches Intercepted",
            explanation: "Your DNS lookup requests are being redirected or filtered by security software, a VPN, or your internet provider.",
            action: "Check your VPN or network security software settings if you did not intend to redirect DNS."
        ),
        "D5": PlainExplanation(
            title: "Primary DNS Unresponsive",
            explanation: "Your first DNS server isn't answering, forcing your Mac to pause and wait for a backup server on every lookup.",
            action: "Remove the unresponsive DNS server in System Settings > Network > Details > DNS."
        ),
        "D6": PlainExplanation(
            title: "Faster DNS Server Available",
            explanation: "Your current DNS server works, but an alternative public DNS server would respond faster.",
            action: "Consider updating your DNS server addresses to 1.1.1.1 (Cloudflare) or 8.8.8.8 (Google)."
        ),
        "SOCK-1": PlainExplanation(
            title: "System Out of Network Connections",
            explanation: "Your Mac has exhausted its available network connections (sockets), so apps cannot open new web pages or connections.",
            action: "Quit bandwidth-heavy apps, close excess browser tabs, or restart your Mac."
        ),
        "CONN-1": PlainExplanation(
            title: "Some Connections Failing",
            explanation: "Certain new network connections are being blocked or refused by destination servers or firewalls.",
            action: "Check firewall software or try restarting your network connection."
        ),
        "HOG-1": PlainExplanation(
            title: "App Consuming Heavy Bandwidth (Latency Elevated)",
            explanation: "An app or background process on your Mac was transferring large amounts of data while network latency or jitter degraded, causing queue delay (bufferbloat). Hopwatch flags this only when the transfer degrades network responsiveness.",
            action: "Pause large downloads, cloud backups, or App Store updates in background apps to restore full responsiveness."
        ),
        "public-ip-changed": PlainExplanation(
            title: "Public IP Address Changed",
            explanation: "Your internet service provider (ISP) assigned your connection a new external IP address, or your Mac switched to a different internet connection or VPN.",
            action: "Normal behavior for dynamic home connections and mobile roaming. No action needed unless you host home servers requiring a static IP."
        ),
        "EDNS-1": PlainExplanation(
            title: "Encrypted DNS Active",
            explanation: "Your Mac is using encrypted DNS (DNS-over-HTTPS or DNS-over-TLS), which protects your lookup privacy.",
            action: "No action needed — your DNS lookups are secured against eavesdropping."
        ),
        "MT1": PlainExplanation(
            title: "Problem Hop Located",
            explanation: "Hopwatch identified the exact router or server along the path where packets first start getting lost.",
            action: "Review which provider or hop is dropping traffic (local router vs ISP vs backbone)."
        ),
        "V6-1": PlainExplanation(
            title: "IPv6 Partially Broken",
            explanation: "Your network has IPv6 enabled, but IPv6 traffic is failing or timing out.",
            action: "Disable IPv6 temporarily in System Settings or restart your router."
        ),
        "V6-2": PlainExplanation(
            title: "IPv6 DNS Not Answering",
            explanation: "The IPv6 address of your DNS server is unresponsive, though IPv4 DNS may still be working.",
            action: "Configure IPv4 DNS servers (such as 1.1.1.1) in Network Settings."
        ),
        "V6-3": PlainExplanation(
            title: "IPv6-Only Network Operating Normally",
            explanation: "This network uses modern IPv6 addressing exclusively, and translation for older services is working.",
            action: "No action needed — your network is modern and healthy."
        ),
        "VPN-2": PlainExplanation(
            title: "VPN Carrying Partial Traffic",
            explanation: "A VPN is actively handling some of your traffic (split tunneling), while other traffic goes directly out to the internet.",
            action: "No action needed unless specific company or home services fail to connect."
        ),
        "PX-1": PlainExplanation(
            title: "Proxy Server Configured",
            explanation: "Your Mac is configured to route web requests through an intermediary proxy server.",
            action: "Verify proxy settings in System Settings > Network > Proxies if websites fail to load."
        ),
        "FW-1": PlainExplanation(
            title: "Network Filter or Firewall Active",
            explanation: "Third-party security software, parental controls, or firewall filters are inspecting your network traffic.",
            action: "Check your antivirus or firewall application if specific apps or websites are blocked."
        ),
        "BR-1": PlainExplanation(
            title: "Browser Restart Recommended",
            explanation: "A background browser update may have left network sockets in an inconsistent state.",
            action: "Quit and reopen your web browser."
        ),
        "PR-1": PlainExplanation(
            title: "iCloud Private Relay Active",
            explanation: "Apple iCloud Private Relay is protecting your privacy in Safari by routing your web browsing through two separate secure hops.",
            action: "No action needed — this is an Apple privacy feature."
        ),
        "SP-1": PlainExplanation(
            title: "Wi-Fi Limiting Internet Speed",
            explanation: "Your broadband subscription is capable of higher speeds, but your current Wi-Fi link speed is capping your throughput.",
            action: "Move closer to your router, use 5 GHz or 6 GHz Wi-Fi, or connect via Ethernet."
        ),
        "MET-1": PlainExplanation(
            title: "Metered Connection",
            explanation: "Your connection may have data caps or billing surcharges for heavy data usage (such as a personal hotspot).",
            action: "Be mindful of large downloads, system updates, and video streaming quality."
        ),
        "DI-1": PlainExplanation(
            title: "Router Unreachable on Local Network",
            explanation: "Your Mac cannot locate your router's hardware address (ARP) on the local link.",
            action: "Check that your Wi-Fi or Ethernet cable is connected and restart your router."
        ),
        "DI-2": PlainExplanation(
            title: "IP Address Conflict on Network",
            explanation: "Another device on your local network is using the exact same IP address as your Mac.",
            action: "Renew your DHCP lease in Network Settings or restart your router."
        ),
        "LAN-1": PlainExplanation(
            title: "Local Network Congested",
            explanation: "A high number of active devices were detected on your local network, which may congest bandwidth.",
            action: "Disconnect unused devices or consider upgrading to a router with higher capacity."
        ),
        "ETH-1": PlainExplanation(
            title: "Ethernet Speed Limited",
            explanation: "Your Ethernet cable or switch port negotiated a lower speed (e.g. 100 Mbps instead of 1 Gbps).",
            action: "Use a Cat 5e or Cat 6 Ethernet cable and ensure all cable ends are firmly plugged into Gigabit ports."
        ),
        "ETH-2": PlainExplanation(
            title: "Ethernet Stuck on Half-Duplex",
            explanation: "Your Ethernet link is stuck in half-duplex mode, causing severe collision delays.",
            action: "Replace the Ethernet cable or try a different port on your switch or router."
        ),
        "DH-1": PlainExplanation(
            title: "DHCP Lease Expiring",
            explanation: "Your Mac's temporary local IP address lease is about to expire.",
            action: "Your Mac will renew it automatically; if connectivity drops, renew the DHCP lease in Network Settings."
        ),
        "DH-2": PlainExplanation(
            title: "Custom DNS Overriding Router",
            explanation: "Your Mac has manual DNS servers configured that override your network's default DNS.",
            action: "Verify your DNS settings in System Settings if you did not intend to override router DNS."
        ),
        "DH-3": PlainExplanation(
            title: "No IP Address Assigned (DHCP Failure)",
            explanation: "Your router connected your Mac to the network but failed to assign it an IP address.",
            action: "Restart your router, toggle Wi-Fi, or check if the router has run out of IP addresses."
        ),
        "WAN-1": PlainExplanation(
            title: "Multiple Internet Providers (Load Balancing)",
            explanation: "Your network is using two or more internet providers simultaneously.",
            action: "No action needed — your router is balancing traffic across connections."
        ),
        "WAN-1B": PlainExplanation(
            title: "Rotating Public IP (CGNAT)",
            explanation: "Your internet provider is rotating your public IP address frequently.",
            action: "Normal for some mobile or satellite providers; contact ISP if website sessions drop repeatedly."
        ),
        "NAT-1": PlainExplanation(
            title: "Double NAT Detected",
            explanation: "Your network has two routers in a row performing address translation, which can cause issues with games and smart home devices.",
            action: "Set your secondary router or Wi-Fi mesh system into 'Bridge Mode' / 'Access Point Mode'."
        ),
        "NAT-1B": PlainExplanation(
            title: "ISP-Side Private Routing (CGNAT)",
            explanation: "Your internet provider is using Carrier-Grade NAT, sharing one public IP among many households.",
            action: "Contact your internet provider and request a dedicated public IP address if you host servers or game consoles."
        ),
        "BL-1": PlainExplanation(
            title: "Performance Regressed",
            explanation: "Your current network speed or latency is noticeably worse than your historical average on this network.",
            action: "Restart your router or check if background downloads or family members are using bandwidth."
        ),
        "CP-1": PlainExplanation(
            title: "Captive Portal Sign-In Required",
            explanation: "This Wi-Fi network requires you to sign in or accept terms before accessing the internet.",
            action: "Open Safari or any web browser and complete the login page."
        ),
        "ND-1": PlainExplanation(
            title: "Hopwatch Watcher Not Running",
            explanation: "The Hopwatch background monitor service is stopped.",
            action: "Enable background monitoring in Hopwatch settings."
        ),
        "AV-1": PlainExplanation(
            title: "Frequent Connection Dropouts",
            explanation: "Hopwatch recorded multiple network outages or disconnects on this connection recently.",
            action: "Contact your ISP to inspect your line quality, or check cables between your modem and wall jack."
        ),
        "AV-2": PlainExplanation(
            title: "Connection Flapping / Unstable",
            explanation: "Your connection is rapidly dropping and reconnecting over and over.",
            action: "Check for loose cables, damaged cords, or severe wireless interference."
        ),
        "TR-1": PlainExplanation(
            title: "Heavy Traffic During Measurement",
            explanation: "An application on your Mac was transferring large amounts of data while the diagnostic test was running, slowing other apps.",
            action: "Pause large downloads, cloud backups, or game updates in background apps and test again."
        ),
    ]
}
