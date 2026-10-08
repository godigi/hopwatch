# Stale / misleading display audit — 2026-10-08

Read-only audit run after the "no link shows 10% loss, 3 ms jitter and a green Internet check" bug. Code-traced, not executed. Excludes the link-down clearing, router/internet/jitter tiles and no-link stage, which are fixed on `fix/no-link-state`. Line numbers are as of `c2c95ee`.

## Cross-cutting

- **A. Fallbacks take over once the monitor stops carrying old values.** `currentJitter` (`MonitorSeries.swift:139-141`, `HopwatchCoordinator.swift:1505`), `effectiveLoss`, `currentStability`, the menu-bar ping/flag/IP and the public IP/country/ISP chains fall back to `monitor.recent`, `latestRun` or `hydratedReport` with no network or age check.
- **B. Link recovery blanks for up to 5 min.** Same-network recovery does not re-arm the medium/slow tiers (`monitor.sh:1475-1505`). Addressed in the CLI fix.
- **C. Defaults turn blanks into green** (`?? 0`, `?? 2.0`, `?? 5.0`, "TCP 443 ok"). See #7 and #16.

## Findings (most likely first)

| # | Severity | Where | Wrong output | Fix |
|---|---|---|---|---|
| 1 | critical | `monitor.sh:279` `MON_IFACE_TYPE="wired"` set before the interface guard | A Wi-Fi drop renders as Ethernet / "1 Gbps wired" (`DropdownView.swift:431-434, 712-717`, `HomeView.swift:901-921, 1233-1237`) | Emit the held identity type or null; GUI treats nil as unknown |
| 2a | critical | `monitor.sh:741-757` `_mon_probe_public` clears `MON_PUB_*` only on a successful lookup | Portal blocks the lookup, so the previous network's IP and flag persist | Clear at top of function |
| 2b | critical | `DropdownView.swift:579-583, 938-949`; `HomeView.swift:1155-1165, 1204-1208, 1249-1253`; `HopwatchApp.swift:330-343` | `monitor ?? latestRun ?? hydratedReport` chain shows another network's flag/IP/ISP (CLAUDE.md rule 2) | Monitor value only, or a stored run only if same network, labelled |
| 3 | critical | `HopwatchCoordinator.swift:457-459, 1126-1127, 94-95, 566-573`; `DropdownView.swift:813-828`; `HomeView.swift:1274-1289` | Cold launch at a café shows home's 480/40 speed test; Streaming/Calls tiles read "4K ready" | Use `history.latestSpeedTest(for:)` only; drop in-memory value on network change |
| 4 | critical | `MonitorSeries.swift:139-141`; `HopwatchCoordinator.swift:1478-1517` | Jitter over the past hour across networks and drops; loss/RTT from the last scan | Latest sample only, or same network/link/unpaused within ~3 cadences |
| 5 | minor-critical | `MonitorStream.stop()`/`start()` keep `latest`/`recent`; `DropdownView.swift:463-488`; `HopwatchApp.swift:350-357` | After monitoring off/pause then resume elsewhere, old latency/flag/IP show as "Live" for ~7 s | Clear on start/stop, or gate on running and a present sample |
| 6 | critical | `HopwatchCoordinator.swift:566-573, 1458-1460`; `HomeView.swift:191-231, 449-454, 480-499, 544-567, 595-604` | Home shows an old run's findings, IPv6/MTU, availability under "Saved check · 3:12 PM" with no network or date | `currentRunResult` only if same network as live sample, else "Awaiting check" or a labelled banner |
| 7 | minor | `HomeView.swift` :935, :109/:1256, :1041, :1178, :1183-1187, :1267, :1309, :1271, :1236, :1261, :213, :786-818, :675-773; `DashboardCheckEvidence.swift:74` | Fabricated defaults shown as fact: 192.168.1.24, 192.168.1.1, jitter 1.0/5.0, 5 GHz ch 44, WPA2, "8 hours remaining", "Not flagged as metered", WireGuard, hard-coded "Usual" column; DNS row shows the gateway | Show "—" / "Not measured"; use `sample.dns.resolver` |
| 8 | minor | `monitor.sh:1505`; `DropdownView.swift:462, 664`; `HomeView.swift:1293` | VPN toggle leaves public IP/country 5 min stale (looks like a leak); "Checked just now" is hard-coded; "· before VPN" appended by current state, not test time | Re-arm slow tier on VPN change; derive freshness from `latest.timestamp`; record VPN state with the speed test |
| 9 | minor-critical | `monitor.sh:741-770, 1541-1546` | Captive-portal card persists up to 5 min after sign-in | While `MON_CAPTIVE=1`, re-probe each medium cycle or on a nudge |
| 10a | minor | `HopwatchCoordinator.swift:892-972` | `lastUnhealthySample`/`previousActiveAlerts` not scoped to network or age; "Online — captive portal succeeded" after rejoining home | Clear on network change and after a gap |
| 10b | minor | `HopwatchCoordinator.swift:505-510`; `NotificationManager.swift:300-323` | Event alerts enter `announcedFaults`, so a VPN toggle posts "Wi-Fi Restored" even on Ethernet | Exclude event IDs; per-network tracking |
| 11 | critical (narrow) | `HopwatchCoordinator.swift:1402-1416, 1722-1742`; `HistoryStore.swift:120-126` | Live SSID adopted onto a held/in-flight sample from the previous network: history renamed permanently | Adopt only when sample SSID/BSSID equals live, or outside grace and newer than the last SSID event |
| 12 | minor | `MonitorSample.swift:280-299`; `DropdownView.swift:85-98`; `MainWindow.swift:214-236`; `HealthResolver.swift:58-79`; `StageResolver.swift:175` | Dot, pill and card disagree (amber at 2.5% loss while CLI says ok; green pill over amber dot with monitor dead; amber dot on every scan) | One resolver; trust CLI severity and measurement |
| 13 | critical (hard to hit) | no staleness check on `latest.timestamp`; `MonitorSample.swift:278` | Hung `ipconfig`/`arp`/`route` freezes `latest`, dot stays green forever | `isStale` = age > 3 cadences feeding all resolvers |
| 14 | minor | `DropdownView.swift:329-347`; `HopwatchCoordinator.swift:1463-1471`; `EffectiveLoss.swift:69-73` | "Nothing has changed in 9h" after sleep; `hasRecentRoam` counts samples, not time; loss windows blend pre-sleep probes | Time-gate roam; subtract `gap_s`; reset windows on gap |
| 15 | minor | `DropdownView.swift:767-768`; `HomeView.swift:1318-1320` | 60 s-old monitor RSSI/channel beats fresh CoreWLAN and sits beside "Wi-Fi roamed" | Re-arm medium on BSSID change; prefer CoreWLAN when authorised |
| 16 | minor | `SuitabilityEngine.swift:204-206, 405, 461-462, 491, 709, 823`; `DropdownView.swift:624-650`; `HomeView.swift:300` | No data reads "Clear audio · 0% loss · 2ms jit" and "TCP 443 ok"; five green tiles under "Monitoring paused" | `.unmeasured` verdict |
| 17 | minor | `RunReportView.swift:59-94`; `RunDetailView.swift:29`; `HomeView.swift:512-517`; `HopwatchCoordinator.swift:1169-1173` | Old reports re-blamed using today's RSSI/roam; repair buttons from another network's diagnosis | No live inputs to stored views; compare network IDs in `repairsAreCurrent` |
| 18 | unverified | `lib/vpn.sh:36-41`; `monitor.sh:279-285`; `netid.sh` | Full-tunnel VPN makes `utun` the interface, so a VPN toggle looks like a new network | Derive type/identity from the underlying physical interface; needs a real utun test |

## Not stale-data, but related

The Swift tree re-derives verdicts in `MonitorSample.health`, `NetworkHistoryStore.compare`, `RouteWarningResolver`, `SuitabilityEngine` and `EffectiveLoss`. That conflicts with "the GUI holds no diagnostic logic" and is the underlying reason #12 exists.

## Open design decision

Move the fallback chains (#2b, #3, #4, #6) behind one `coordinator.currentNetworkRun` accessor that returns a run only when its network equals `monitor.latest.network.historyJoinID`, together with its age.
