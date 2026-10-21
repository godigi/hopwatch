# Changelog

All notable changes to Hopwatch are recorded here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versioning follows
[SemVer](https://semver.org/spec/v2.0.0.html).

Releases before 1.16.2 are archived in [docs/CHANGELOG-archive.md](docs/CHANGELOG-archive.md).

## [Unreleased]

## [1.21.0] - 2026-10-21

### Added
- Live Ping Heartbeat in the Menu Bar Dropdown: A real-time telemetry card located between "Your connection" and "What this feels like", executing a 1-second continuous ICMP stream. Features a clean line graph over 3 horizontal latency zones (Green bottom for <70ms, White middle for 70–150ms, Red top for >150ms), interactive hover inspection displaying exact latency per probe, prominent red vertical drop markers and "✕" badges for packet timeouts/MISSes, and one-click target toggling between Internet (1.1.1.1) and the local Router gateway.
- Native macOS Software Update Dialog: modeled on the clean Sparkle / Tungsten Edge update experience, featuring current vs available version comparison, an inset card displaying bulleted release notes with conventional commit prefix cleaning, background pre-caching, and one-click Skip This Version, Remind Me Later, and Install Update controls.

### Changed
- Filtered non-urgent network advisories (Double NAT, DHCP lease countdown, clock drift, and baseline speed regressions) out of the mini menu (taskbar dropdown), menu-bar health status dot, and coordinator status headlines. These conditions remain fully reported in the Dashboard findings panel, check tables, and diagnostic run reports.

### Fixed
- Fixed background process lifecycle for ping heartbeat: stopping monitoring in Settings now properly terminates the continuous ping subprocess, and re-enabling monitoring resumes it.
- Fixed ping heartbeat target retention across network changes: roaming or switching networks now resets ping targets back to default and clears stale packets rather than continuing to ping unreachable gateway IPs from prior networks.
- Fixed corrupt heartbeat beat creation during network outages (`link.up == false`) so drops are recorded cleanly as misses instead of producing invalid readings.
- Fixed captive portal sign-in action spawning duplicate browser tabs by cleanly prioritizing direct gateway HTTP under custom DNS and avoiding simultaneous fallback cascades.
- Fixed macOS Dock icon remaining stuck after dismissing the Software Update dialog by re-evaluating activation policy when the modal closes.
- Added visible error messaging in the Software Update dialog when background downloads or extractions fail.

## [1.20.1] - 2026-10-20

### Fixed
- Fixed false captive portal banner and alert hijacking:
  - Eliminated automatic captive portal network learning from rule `N1c` ("joined with no route out") or momentary `no-route` states so home and office networks are never falsely branded as captive portals.
  - Fixed `isLearnedPortalAwaitingSignIn` in `AlertEngine`: networks where internet access is confirmed (`captive_portal == false` and healthy latency/traffic) immediately clear and never raise false sign-in alerts.
  - Fixed `isCaptivePortalAlert` in dropdown and dashboard views so unrelated network findings (e.g. IPv6, double NAT, jitter) are never hijacked and replaced with captive portal sign-in banners.
  - Added automatic unlearning of portal flags when live probes confirm direct internet access without interception.
- Fixed false captive portal detection and persistent network poisoning: macOS `CaptiveNetwork` state reporting `Stage : Unknown` is no longer mistaken for an active captive portal, and probing the default gateway router on port 80 directly is eliminated so that local router admin login pages are never classified as captive portals.
- Fixed misleading "Internet ping: TCP ok" readout when internet pings fail or time out: under gateway ping filtering (`TCP-1`), missing or failing internet pings now accurately display "no reply" or packet loss instead of falsely displaying "TCP ok" in green.
- Fixed 3-hop topology attribution during upstream internet outages: when the gateway router filters ICMP ping, high internet packet loss now properly warns on the Internet hop (red/amber globe) and attributes the culprit to the ISP/Internet rather than blaming the local router.

## [1.20.0] - 2026-10-19

### Fixed
- Eliminated dropdown flip-flopping between "Monitor is not reporting" and active network states during degraded or timing-out probe cycles by stopping unnecessary monitor process restarts on severity transitions, aligning the coordinator watchdog window with probe timeout durations, and ignoring redundant SSID notifications.
- Updated `G2` (router packet loss with strong Wi-Fi signal) diagnosis and away-network guidance to rule out wireless distance and accurately attribute the issue to overloaded/rebooting router or access-point hardware or upstream ISP failures.
- Enriched "Copy 1-Click IT / Support Ticket" so it always includes the latest telemetry (gateway IP, signal quality, packet loss, active alert/rule findings) even if triggered between live sample windows.
- Fixed captive portal diagnosis to prioritize sign-in instructions and suppress router-reboot blaming (G1/G2/G3) on hotel and guest networks.
- Fixed Support Summary report generation to accurately describe captive portal authentication and avoid misleading front-desk reboot requests.
- Fixed Internet hop node rendering to prevent displaying a green checkmark when internet ping has 100% packet loss / "no reply".
- Suppressed generic connection-unstable and connection-lost alerts while awaiting captive portal authentication.

## [1.19.1] - 2026-10-16

### Changes

- fix(gui): resolve arrival scan loop on weak network IDs and menu bar memory leak

## [1.19.0] - 2026-10-16

### Added
- Captive portal learning and 1-click sign-in button from alert banner
- Custom DNS compatibility for captive networks (bypasses public DNS to reach router gateway)
- Network memory indicator for networks requiring portal authentication
- Plain English ELI5 translations for network diagnostic faults and findings
- Global system hotkey (⌥⌘N) to summon Hopwatch from anywhere
- Dynamic menu bar display mode (minimal dot when healthy, expands when degraded)
- Audio chime sound cues (Basso on disconnect, Glass on restore)
- Instant update restart with background pre-caching
- 1-click IT & ISP support ticket dispatch formatting
- What's New release highlights sheet

### Fixed
- Corrected Double-NAT detection to recognize local gateway and home subnets (10.0.0.x / 10.0.1.x) in 10/8 as home-side.
- Fixed Tailscale VPN detection to require an active online exit node before treating Tailscale as default-route VPN.
- Fixed Wi-Fi 6 GHz band detection in rule W6 to prevent false 2.4 GHz band-trapping warnings.
- Fixed MTR per-hop fallback to preserve true traceroute hop numbers when intermediate hops time out.
- Fixed bufferbloat probe to sustain download load across fast connections and grade saturated 100% loss as Grade F.
- Fixed IP address target handling in DNS and connection reachability checks.

## [1.18.1] - 2026-10-15

### Changes

- docs: hosting moved from vps2 to prod1 (#14)

## [1.18.0] - 2026-10-14

### Changes

- Merge pull request #12 from godigi/fix/audit-round2
- test: restore PATH after the no-sudo test so bats teardown can find rm
- fix(gui): Copy redacted report actually puts the report on the pasteboard
- Merge branch 'worktree-agent-aa35901282fead524' into fix/audit-round2
- feat(gui): gate the share actions on a new 'share' capability
- fix(gui): flush the event log synchronously on quit
- fix(gui): scan-only alerts are no longer suppressed by their own scan
- fix(gui): Home's quiet line scopes to the current network without the 24 h cap
- fix(gui): drop stale announced faults without posting 'Restored'
- fix(gui): Settings re-check restarts the monitor now and clears the stale error
- fix(gui): HistoryStore.load publishes the newest finished load, ignores cancellation
- fix(gui): finish the progress stream before execute's early throws
- fix(gui): ChildProcess.feed owns its stdin fd; bound drain after exit
- fix(common): ping_sigint_bound cleans up after itself; sudo gate needs sudo even for root
- fix(json): --quick --speed is budgeted by what ran, not the 8 s quick budget
- fix(wifi): strip 0x1f from scraped values and stop reading tab-separated records
- fix(share): mask IPv6 prefixes and addresses ending in '::'
- fix(monitor): a signal-induced emit failure exits 0, not 3
- fix(redact): mask $HOME, watcher path and every WAN_LB_IPS address in text mode

## [1.17.2] - 2026-10-14

### Changes

- Merge pull request #11 from godigi/fix/audit-2026-10
- Merge branch 'worktree-agent-a8c3d8446d66a25db' into fix/audit-2026-10
- Merge branch 'worktree-agent-a012de52df3eb1733' into fix/audit-2026-10
- refactor(thresholds): move baseline cutoffs and run budgets into lib/thresholds.sh
- docs(architecture): mtr no longer implies sudo
- docs(schema): netdiag_extras is the real key; document browser_health
- fix(headline): show the Router row at 100% loss; judge the MTU row like rule M1
- fix(monitor): free the stream on stop, init MON_INET_RTT, report emit failure, move loss floors to thresholds
- fix(probes): bound pings with -W, bound ping6 with SIGINT, unknown hop is not clean, fix ::1 filter
- fix(gui): harden the self-updater
- fix(gui): don't drop the first monitor sample in the second after a boundary
- fix(gui): serialise event-log writes and drop stale history loads
- fix(gui): scope the Live view's last event to the current network
- fix(gui): do not cache a failed capability handshake for the session
- fix(helpers): never emit NaN/Infinity; summary skips non-object JSONL lines
- fix(wifi): keep empty Wi-Fi fields in their slot with a non-whitespace separator
- fix(gui): alert pause state, event announcements and same-network roams
- fix(traffic): difference nettop counters per (name, pid), then sum by name
- fix(browser): bind helper-process matching to the browser's own bundle
- fix(events): keep both rule-cleared rows from one sample
- fix(launchd,watch): escape plist XML, check launchctl load, stop calling exit 1/2 a failure
- fix(gui): ignore SIGPIPE and cancel scans through their whole process group
- fix(redact): close share --json, WAN IP and watcher-path leaks under --redact
- fix(sudo): make sudo opt-in and a last resort

## [1.17.1] - 2026-10-13

### Fixed

- **The "All good" banner is readable in dark mode.** The green status banner at the top of Home and the main window set its headline, sentence and "All systems nominal" pill in a fixed dark green that disappeared against the dark green background. They now use the app's own green and body-text colours, which adapt to the appearance, so the banner reads clearly in both light and dark mode. The README and `docs/SCREENSHOTS.md` images that show it are re-captured from synthetic data.
- **Old cache files no longer pile up.** Each version of the app saved its own copy of the rules catalog and the signal scale in its Application Support folder and never removed the older ones, so the folder grew by two files per release. The app now deletes every copy that belongs to another version and keeps only the current one. Nothing else in the folder is touched.
- **The changelog's version links no longer point at deleted tags.** Only the newest release and tag are kept, so the "compare" links under 1.17.0, 1.16.3 and 1.16.2 led to pages that no longer exist. Older versions now link to the commit that released them, and the release script keeps doing that for each version it supersedes instead of generating a link to a tag that is about to be removed.

## [1.17.0] - 2026-10-13

### Fixed

- **The offline card's remaining copy now comes from the CLI.** The monitor's `link.offline` gains `reason_label`, the short caption for the reason ("Wi-Fi is off" for `wifi-off`, "Not connected" for `wifi-not-joined` and `wifi-no-address`, `null` for the rest and for a wired link). The Mac node and the signal tile render it verbatim and fall back to the neutral "No link" wording when it is absent, instead of mapping reasons to text in Swift. The "Not connected" caption under the Mac node in the menu-bar card replaces the old "Wi-Fi · not connected" so one label serves both places.
- **Rule titles are no longer duplicated in Swift.** When the rules catalog has not loaded, the offline headline falls back to the neutral "No network connection" rather than a copy of the WJ-1 or WF-1 title (the WJ-1 copy had already drifted: "hasn't" against the catalog's "has not"). `NoLinkCopy.fallbackSubtitle`, the line shown under it, was a copy of the start of N1's text; it now only states what the app sees ("Hopwatch's connection monitor reports no active network link.").
- **The Reconnect Wi-Fi button on the offline card is driven by the rules catalog.** The card used to draw it for `WJ-1` or `DH-3`, a list kept in Swift. It now asks the catalog's per-rule `repairs` (decoded in the app from catalog schema 6) which firing rule offers `reconnect-wifi`, so the CLI decides which finding offers which repair here as in scans. Consequence: `WF-1` (Wi-Fi switched off), which the catalog and the scan already offer the repair for, now gets the button too; until the catalog has loaded the card shows only "Open Wi-Fi Settings". A new bats test ties the catalog's `repairs` to the `repair_offer` calls in `lib/`, so they cannot drift.
- **"Right before Wi-Fi dropped" is no longer said of a wired link.** `precursor_summary` is worded for the link that was lost: "Wi-Fi", "the wired connection", or "your connection" when the monitor does not know (a restarted monitor does not: the type is not in the carry record).
- **"Last on wired via 192.168.1.1" is gone.** A wired network's label describes a link, not a name, so `netid_label_is_name` now refuses it and `link.offline.last_network` is `null` for a wired network (the card says "Offline for X" alone). Wi-Fi names are unaffected.

## [1.16.3] - 2026-10-13

### Changed

- **Documentation tidy-up.** The screenshots in the README and `docs/SCREENSHOTS.md` are re-captured from the current app using synthetic data (`scripts/gallery-fixture.py` regenerates the fixture they render), and `docs/CHANGELOG-archive.md` now holds the release notes for every version before 1.16.2. The reference docs say Hopwatch where they still said netdiag, the README's roadmap no longer cites versions that are no longer published, and `docs/BACKLOG.md` keeps only the ideas that are still open.
- **Sample output** (`examples/`) no longer shows a real DNS resolver address or a home-directory path.
- **Changelog tests follow the trimmed release history.** `tests/test_changelog.bats` requires a git tag only for the newest version, checks the README's version credits against the changelog and its archive, and runs its parser tests against the archive, since older tags are no longer kept.

## [1.16.2] - 2026-10-13

### Fixed

- **Tags cut by the auto-version bot now become Releases.** `auto-version.yml` pushes the release commit and tag with the default `GITHUB_TOKEN`, and GitHub does not start workflows from events that token creates, so `release.yml`'s tag trigger never fired: v1.15.1, v1.16.0 and v1.16.1 were tagged with no Release and no DMG, while `Casks/hopwatch.rb` pointed at the DMG that was never built (v1.16.1 was repaired by hand). The job now dispatches `release.yml` for the tag it just pushed (`workflow_dispatch` is allowed from `GITHUB_TOKEN`; it needs `actions: write` and no new secret). A tag pushed from a maintainer's machine still triggers the release by itself and is not dispatched twice.
- **A Release is built from its tag, not from whatever main holds when the job runs.** `release.yml` checked out the default branch, so a merge landing between the tag and the build made `gui/Makefile` name its artefacts from the wrong version. It now checks out the tag; only `CHANGELOG.md` and its reader still come from the default branch, so later corrections to old entries keep reaching the notes.
- **A rejected bot push can no longer leave an orphan tag.** The tag and `main` are pushed atomically and by name instead of with `--follow-tags`, and `auto-version` runs are serialised and start from the tip of `main`, so two merges in quick succession cannot both bump from the same tag.

<!-- Only versions that still have a GitHub Release are kept here; older
     history lives in docs/CHANGELOG-archive.md, which tests/test_changelog.bats
     does not read. -->

[Unreleased]: https://github.com/godigi/hopwatch/compare/v1.21.0...HEAD
[1.21.0]: https://github.com/godigi/hopwatch/releases/tag/v1.21.0
[1.20.1]: https://github.com/godigi/hopwatch/commit/52c71e3dc125133c3c395de6f004394762825f17
[1.20.0]: https://github.com/godigi/hopwatch/commit/0202371d64474cfd06d9c5b1c5299b8c81ea29a9
[1.19.1]: https://github.com/godigi/hopwatch/commit/03beb7f6daddef01d2fb94e104363eae01374572
[1.19.0]: https://github.com/godigi/hopwatch/commit/0d87c149a5434e1b16733fb4e16ce2f1f4fcfb7b
[1.18.1]: https://github.com/godigi/hopwatch/commit/69148336c6c93b2418b34bdce9b1b9aaf099f148
[1.18.0]: https://github.com/godigi/hopwatch/commit/7b9d11733bda2a37fed505b27c7e81178b50fe61
[1.17.2]: https://github.com/godigi/hopwatch/commit/34aeb710049da8eb73bcf66e116bf3ad05e4695f
[1.17.1]: https://github.com/godigi/hopwatch/commit/d4be4f91116203ba65f20e05eaed87f59c8a6517
[1.17.0]: https://github.com/godigi/hopwatch/commit/685ef4f5e4695ff17a34c5b986f0c877165168fe
[1.16.3]: https://github.com/godigi/hopwatch/commit/7bf928d274434b04483d7a59f5f308785749d242
[1.16.2]: https://github.com/godigi/hopwatch/commit/23379af98d37b28f6b8aed9946c7b103b93dfe9f
