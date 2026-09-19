# Hopwatch: complete information, two levels of detail

Visual mockups only. The first design used the supplied screenshots. This revision also audits selected app views, report fields and documentation, as requested. No application code was edited. All displayed measurements, addresses, countries, history and test outcomes are illustrative; the two mockups depict the same VPN travel scenario.

[Menu mockup](hopwatch-menu.mockup.html "width=560 height=900")

[Dashboard mockup](hopwatch-dashboard.mockup.html "width=1440 height=1100")

## Corrections to the first design

Country and VPN belong in the menu's primary information, especially for travelers. The previous suggestion to keep them in technical context was wrong for this use case. Both now remain visible in the connection panel, and the country flag is attached to the internet icon. The dashboard exposes the public IP separately from the ping destination.

The invented logo has been replaced with the project's existing [app icon](/Users/bfreeman/Documents/AI-Workspace/netdiag/gui/Resources/AppIcon.iconset/icon_32x32@2x.png), embedded unchanged in both files. Dashboard readings above the hops use 20 px type, explicit line spacing and room to grow instead of the oversized, compressed layout.

The first dashboard omitted bufferbloat, MTU, IPv6, clock drift, two-target packet loss, comparisons with normal performance, recorded availability, actionable findings and access to the deeper report. These now have visible placements. The live chart's unsupported 24-hour option has been removed: the existing Live view retains an hour of samples; longer history comes from saved checks. DNS is shown as resolver results and web reachability as TCP 443, instead of inventing a DNS duration or HTTP 200 result that these fields do not establish.

## Menu: preserve the quick answer

The menu keeps its compact hierarchy. The only substantial additions are country and VPN.

| Information | Placement |
|---|---|
| Connection health and everyday consequence | Headline; separate neutral monitoring indicator |
| Router and internet ping | Above the corresponding icons |
| Router and internet packet loss | Under the corresponding hops |
| Internet jitter | Labeled row below the route |
| Public IP country | Flag attached to internet icon, country name and explicit caption |
| VPN state and detected name/type | Persistent line below jitter; example “VPN on · WireGuard” |
| Wi-Fi signal and current network | Mac hop and footer |
| Download/upload speeds and age | Secondary row; explicitly labeled before-VPN when applicable |
| Likely impact on calls, gaming and streaming | Three short visual summaries |
| Recent incident | Grouped event plus access to Activity |
| Full check, dashboard, pause, share, settings, quit | Compact controls |

Public IP numbers, resolver lists, routing tables and the full diagnostic battery stay in the dashboard. Country and VPN are not hidden behind tooltips.

## Dashboard: show the evidence

The expanded Check details table sits beside the live chart and findings. There is no disclosure hiding these primary results. Additional content continues vertically rather than squeezing every measurement into the first screen.

| Data or capability | Placement |
|---|---|
| Country, VPN, public IP, ping destination | Connection path and persistent context row |
| Live ping, loss, jitter, Wi-Fi signal | Route and chart; separate from saved checks |
| Router/internet loss and two destinations | Expanded check table; exact targets in technical detail |
| DNS, Wi-Fi SNR, bufferbloat on both legs | Expanded check table and findings |
| MTU, IPv6, TCP reachability, clock | Expanded table; unavailable/not-measured states stay neutral |
| Typical network performance | “Usual” column from saved-check medians, with route/VPN caveat |
| Likely cause, evidence and next step | Findings & next steps; browser issues get a separate finding |
| Outage count, total downtime, longest outage, observation gaps | Connection reliability strip |
| Interface, local IP, gateway, DNS, security, public IP/ISP, metering | Network details |
| Speed-test age and connection context, separate speed action | Network details footer; skipped current test stays explicit |
| Calls, streaming, gaming, VPN/remote access, browsing | Compact saved-suitability strip retains all five categories |
| Activity and repeated incidents | Grouped events with timestamps and durations |
| Fast latency test | Chart action |
| Traceroute/MTR, radio scan, DHCP, local traffic, NAT, timings, raw report | Technical detail disclosure and report access |
| Redacted text, front-desk summary, Markdown, JSON | Share diagnostics menu with masking explanation |
| Saved runs, trends, network history | Existing Trends/Networks destinations retained |

The saved check is labeled with its time, network and VPN state. Its figures may differ from the live route. Old throughput is explicitly from before the VPN, so it does not certify current VPN speed. Missing measurements must never become zero or passed checks. Actual severity, findings, actions and suitability come from the CLI's verdicts; the interface must not derive a competing diagnosis.

## Country and VPN state rules

- **VPN on:** show detected name/type and country from the current public IP lookup. United States/WireGuard is an example, not a claim about the user's location or home country.
- **VPN off:** retain the row, explicitly say “VPN off”, and still show public IP country.
- **VPN changing or new network:** retain both slots with “Checking…” until refreshed; do not present a cached flag as current.
- **Country unavailable:** keep a neutral globe/unknown badge and “Country unavailable”. Cached information must say “Last known” with age.
- **VPN not measured:** say “Checking VPN…” or “Unknown”. The current decoded VPN model defaults active to false; future implementation must gate on sample/provenance so absence is not interpreted as off.
- **Split tunneling/proxy:** country describes the public-IP request's exit. VPN detection does not prove every application uses that route. Surface relevant findings in the dashboard without claiming “Protected” or “Home country verified”. No new leak-test or preferred-country feature is assumed.

## Other states that must keep their place

These are presentation requirements for future implementation, not runtime states implemented by this mockup.

| State | Required presentation |
|---|---|
| Hotel/café captive portal | “Sign in to this network” headline and sign-in action; country/VPN slots remain with honest freshness |
| New network, running or failed check | Existing arrival/progress state and phase results; retry on failure; separate saved evidence |
| Paused, sleeping, no samples | Explicit monitoring state and sample age; chart gaps remain gaps |
| Offline or link down | Direct connection message; Wi-Fi signal alone does not imply internet access |
| ICMP blocked or IPv6-only network | Explain probe limitation instead of treating that probe as proof of an outage |
| Missing Wi-Fi permission or Ethernet | Explain unavailable radio fields or use wired identity; never invent RSSI |
| Metered connection | Cost context, existing safe-test policy and skipped-test reason |
| Background transfer, NAT/DHCP/IP conflict, proxy or split-tunnel finding | Promote actual warning and evidence above the raw report |
| Missing baseline or availability journal | Insufficient-history state where relevant; no fabricated medians, uptime or counts |
| CLI problem or app update | Conditional notice with existing repair/update action; normal version/update preferences in Settings |

## Audit evidence and limits

The review was limited to selected slices of [README](/Users/bfreeman/Documents/AI-Workspace/netdiag/README.md:78), [DropdownView](/Users/bfreeman/Documents/AI-Workspace/netdiag/gui/Sources/HopwatchGUI/Views/DropdownView.swift:581), [HomeView](/Users/bfreeman/Documents/AI-Workspace/netdiag/gui/Sources/HopwatchGUI/Views/HomeView.swift:60), the [check-table rows](/Users/bfreeman/Documents/AI-Workspace/netdiag/gui/Sources/HopwatchGUI/Views/RunReportView.swift:503), [Live](/Users/bfreeman/Documents/AI-Workspace/netdiag/gui/Sources/HopwatchGUI/Views/LiveView.swift:78), [Trends](/Users/bfreeman/Documents/AI-Workspace/netdiag/gui/Sources/HopwatchGUI/Views/TrendsView.swift:62), [ExpertPanel](/Users/bfreeman/Documents/AI-Workspace/netdiag/gui/Sources/HopwatchGUI/Views/ExpertPanel.swift:93), [network comparisons](/Users/bfreeman/Documents/AI-Workspace/netdiag/gui/Sources/HopwatchGUI/Views/NetworkDetailCard.swift:161), [snapshot fields](/Users/bfreeman/Documents/AI-Workspace/netdiag/gui/Sources/HopwatchGUI/Models/RunSnapshot.swift:21), [country/VPN models](/Users/bfreeman/Documents/AI-Workspace/netdiag/gui/Sources/HopwatchGUI/Models/MonitorSample.swift:147), the [browser finding](/Users/bfreeman/Documents/AI-Workspace/netdiag/gui/Sources/HopwatchGUI/Support/HopAttributionResolver.swift:175), and top-level fields in [sample output](/Users/bfreeman/Documents/AI-Workspace/netdiag/examples/sample-output.json).

This covers the main visible capabilities and presentation states; it is not a full implementation or detection-accuracy audit. Existing in-progress application edits were not changed. These mockups do not run checks, copy reports or verify a real VPN route. Navigation links and HTML disclosures are the working preview controls.

## Visual verification

Both concepts were inspected in the Nimbalyst editor with the real embedded icon. Local preview checks covered menu widths 375 and 420 px, and dashboard widths 768, 850, 1024 and 1440 px. Reviewed containers showed no horizontal overflow; reading areas did not clip vertically. Longer readings and country names were also checked. The expanded table was inspected after scrolling. No application tests, version bump, installation, commit or release are part of this visual-only task.
