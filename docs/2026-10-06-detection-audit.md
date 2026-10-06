# Network detection audit — 2026-10-06

Scope: released `main` at `c1db0c7` (v1.10.2), checked against `feat/monitor-stability` at `925f14d` and `feat/reporting-accuracy` at `88d5121`. This is a read-only behavioral audit: no application logic was changed. Reproductions below used the actual shell functions or Python helpers with controlled, in-memory inputs; they did not depend on the current network. All listed defects remain on both feature branches unless noted.

Priority reflects the effect of the incorrect claim, not the size of a prospective fix. P1 means a false critical outage or an all-clear over a serious fault; P2 means a materially wrong warning, recovery, or attribution; P3 means a narrower presentation inconsistency.

## P1 — fix first

### 1. History calls a repeatedly broken network “Usually healthy”

**Under-reporting; high confidence.** [`helpers/judgement.py`](../helpers/judgement.py) judges only six metric keys, omitting internet packet loss and DNS failures. [`helpers/history.py`](../helpers/history.py) builds `judged.overall` solely from those metric medians; recorded `diagnosis` severities do not constrain the whole-network claim. [`helpers/judgement.py`](../helpers/judgement.py) then renders `ok` as “Usually healthy across … checks.”

Reproduction: ten records with `internet_latency.loss_pct=40`, `diagnosis=[{"rule":"L1","severity":"critical"}]`, gateway loss 0, RSSI −50 dBm, and MTU 1500. Actual result: `judged.overall="ok"` and `judged.summary="Usually healthy across 10 checks."` Each run itself correctly carries critical L1. The same structural gap applies to repeated DNS or public-reachability faults when the judged metrics stay normal. Relevant lines: `judgement.py:96,146`, `history.py:758`, `lib/diagnosis.sh:458`.

### 2. `--ping-only` reports a critical outage on healthy pings

**Over-reporting; high confidence.** The focused path in [`bin/hopwatch`](../bin/hopwatch) runs gateway and internet pings but skips public, DNS, and TCP checks. Defaults stay `PUBLIC_CHECKED=0`, `PUBLIC_OK=0`, and `DNS_OK=0`. P1/P2 in [`lib/diagnosis.sh`](../lib/diagnosis.sh) use `PUBLIC_OK` without requiring `PUBLIC_CHECKED`.

Reproduction: `FOCUS=ping`, gateway present, gateway loss 0, both internet target losses 0, public check skipped. Actual result: `severity=2 rules=P1`, plus an “unreachable” Internet report-card label. This is not evidence of an outage; both public ping targets answered. Relevant lines: `bin/hopwatch:982,995`, `lib/diagnosis.sh:309`, `lib/headline.sh:167`.

### 3. Failure of one public-IP service becomes a whole-internet outage

**Over-reporting; high confidence.** [`lib/public.sh`](../lib/public.sh) tries `ifconfig.co` twice, but both attempts depend on the same service. When it fails, `PUBLIC_OK=0`. P2 in [`lib/diagnosis.sh`](../lib/diagnosis.sh) ignores other successful public evidence, including Apple’s connectivity canary, TCP, DNS, and both internet ping targets.

Reproduction: both `ifconfig.co` requests failed; Apple returned its genuine Success page with HTTP 200; gateway, both internet pings, TCP, and DNS worked. Actual result: `PUBLIC_CHECKED=1 PUBLIC_OK=0`, then critical P2 claiming no public website responds and likely ISP outage. The single-service failure also skips tests gated on `PUBLIC_OK`. Relevant lines: `lib/public.sh:18`, `lib/diagnosis.sh:309`.

## P2 — materially incorrect diagnosis or recovery

### 4. An unmeasured monitor cycle records a fault as resolved

**False recovery; high confidence.** An unparseable ping can clear its measurement in [`lib/monitor.sh`](../lib/monitor.sh). The rule set starts empty on each cycle. [`helpers/monitor_sample.py`](../helpers/monitor_sample.py) compares prior and current rule sets without checking `status.measurement`, so `PREV_RULES=L1`, current rules empty, and `measurement=unknown` emits `rule-cleared` with “Resolved: Severe internet packet loss.” The journal persists that event. Reproduced on all three branches, including the newer stability emitter. Relevant lines: `lib/monitor.sh:347,630,816`, `helpers/monitor_sample.py:202` (branch copies: `reporting-accuracy:261`, `monitor-stability:313`).

### 5. DNS reports fallback to a configured resolver that did not answer

**Under-reporting and false attribution; high confidence.** [`lib/dns.sh`](../lib/dns.sh) measures configured secondary resolvers, but sets `DNS_FALLBACK_OK=1` if a separate *direct public* resolver query succeeds, assigning the configured secondary’s address to the success flag. [`lib/diagnosis.sh`](../lib/diagnosis.sh) then emits D5 saying macOS silently fell back to that configured resolver.

Reproduction: configured resolvers `192.0.2.1` and `192.0.2.2` both failed; direct queries to `1.1.1.1` and `8.8.8.8` worked. Actual result: `fallback_ok=1 secondary=192.0.2.2`, D5, although every configured resolver failed. Relevant lines: `lib/dns.sh:62,70`, `lib/diagnosis.sh:329`.

### 6. Full-check diagnoses run before the speed measurement they use

**Over-reporting and missed advice; high confidence.** [`bin/hopwatch`](../bin/hopwatch) calls `diagnosis_run` before `speedtest_run` and does not reevaluate. Yet [`lib/diagnosis.sh`](../lib/diagnosis.sh) uses `SPEEDTEST_DOWN_MBPS` to demote D/F bufferbloat severity on a fast link and to emit SP-1 Wi-Fi ceiling advice. With a D grade, +180 ms under load and a subsequently measured 300 Mbps, stored B1/B2 remain critical; rerunning the same diagnosis with speed populated makes them warnings. SP-1 is also unreachable in that full-check order. The preloaded-speed unit test covers the policy but not orchestration. Relevant lines: `bin/hopwatch:1076,1090`, `lib/diagnosis.sh:346,503`, `tests/test_diagnosis_accuracy.bats:111`.

### 7. Historical verdict restores the gateway ping false alarm

**Over-reporting; high confidence.** Scans emit informational TCP-1 when gateway ICMP is filtered but real traffic succeeds. [`helpers/history.py`](../helpers/history.py) extracts raw gateway loss without this context, and [`helpers/judgement.py`](../helpers/judgement.py) judges it unconditionally. Ten working-network runs with TCP-1 and 100% gateway ping loss produced `judged.overall="critical"`, “Often having problems — the router drops packets,” and a red 100% loss summary. Relevant lines: `lib/diagnosis.sh:207`, `helpers/history.py:449`, `helpers/judgement.py:97`, `helpers/summary.py:246`.

### 8. Severe negative clock drift is judged healthy in history

**Under-reporting; high confidence.** The scan uses absolute NTP drift, but the historical classifier treats signed `ntp.drift_seconds` as a normal higher-is-worse metric. Ten critical NT-1 runs with drift −120 seconds produced `judged.overall="ok"`, an NTP `✓ −120.0`, and a relative comparison saying “−120 s — better than usual.” Magnitude must be applied to individual observations before aggregation; taking the absolute value of a median can still hide alternating signs. Relevant lines: `lib/diagnosis.sh:608`, `helpers/judgement.py:69,117`, `helpers/history.py:156`, `helpers/summary.py:264`.

### 9. Historical MTU verdict ignores tunnel context

**Over-reporting; high confidence.** The scan suppresses the usual 1380-byte VPN tunnel MTU, while historical judgement uses a context-free lower-is-worse threshold. Ten otherwise clean VPN runs at MTU 1380 produced `judged.overall="warn"` and “path MTU is often reduced.” Exact 1400 and 1280 boundaries also disagree because history uses `<=` and the scan uses `<`. Relevant lines: `lib/diagnosis.sh:373,380`, `helpers/judgement.py:75,114`.

### 10. Baseline can lose history when SSID visibility changes

**Under-reporting; high confidence.** [`helpers/baseline.py`](../helpers/baseline.py) matches raw `network.id` strings, while [`helpers/history.py`](../helpers/history.py) groups the same gateway MAC across visible and hidden SSID forms. Ten historical `wifi:ssid=Home,mac=aa:bb:cc:dd:ee:ff` runs and a current `wifi:mac=aa:bb:cc:dd:ee:ff` run have the same history group key but yield zero baseline matches. A real regression cannot fire BL-1 until a new exact-string history accumulates. Relevant lines: `helpers/baseline.py:272`, `helpers/history.py:292`, `lib/netid.sh:43`.

## P3 — dashboard and advisory inconsistencies

### 11. Dashboard labels all nearby networks as channel crowding

**Over-reporting; high confidence from source trace.** [`gui/Sources/HopwatchGUI/Views/HomeView.swift`](../gui/Sources/HopwatchGUI/Views/HomeView.swift) marks the channel “Crowded” when `wifiScan.neighbourCount > 3` (`:644`). The CLI’s WS-1 uses `current_channel_neighbours > 3` at `lib/diagnosis.sh:121–124`; [`lib/wifi_scan.sh`](../lib/wifi_scan.sh) measures both separately, and [`RunSnapshot.swift`](../gui/Sources/HopwatchGUI/Models/RunSnapshot.swift) decodes both. Four APs on other channels therefore produce a yellow dashboard “Crowded” badge while the CLI correctly emits no WS-1. This logic remains in both feature branches.

### 12. Missing checks render as successful dashboard evidence

**Under-reporting; high confidence from source trace.** Home always renders the Check details table, including before any saved check. Its fallbacks label absent DNS data “All lookups healthy,” absent TCP reachability “TCP 443 reachable,” and absent bufferbloat as Grade A with invented +3/+15 ms deltas. The panel header can simultaneously say “Awaiting check.” This is a display assertion without a measurement, not a zero result. Relevant lines: `HomeView.swift:174–179,784–817,858–870`; [`DashboardComponents.swift`](../gui/Sources/HopwatchGUI/Views/DashboardComponents.swift) renders each badge as supplied. These fallbacks persist on both feature branches.

### 13. MTU improvement becomes a regression warning

**Over-reporting; high confidence.** [`helpers/baseline.py`](../helpers/baseline.py) treats MTU as a generic change; any difference from its historical mode is appended to `regressions`. Three historical MTUs of 1380 followed by 1500 produce `{"metric":"mtu.effective","current":1500,"median":1380,"kind":"change"}`. [`lib/output.sh`](../lib/output.sh) promotes that item to warning BL-1, “Metric regressed vs. history,” although packet size improved. Relevant lines: `helpers/baseline.py:92,174`, `lib/output.sh:560`.

## Deliberately not promoted to confirmed defects

- Forty percent gateway ICMP loss with clean internet pings still triggers G2 in the shell while the GUI’s downstream validation suppresses isolated gateway loss. The active branches intentionally tightened TCP-1 to require complete gateway silence, so this needs a policy decision about whether partial ICMP rate limiting is safely inferable.
- IPv6 ping loss despite working AAAA and TCP6 can trigger V6-1, and a policy-blocked direct public DNS probe can trigger D1 despite a working configured resolver. Both are plausible false positives, but their treatment depends on the product’s diagnostic policy. They should be tested before changing thresholds.

## Verification and limits

Focused inputs reproduced findings 1–10 and 13 using the actual helpers or shell modules. Findings 11–12 are deterministic source traces through unconditional dashboard rendering and data fallbacks; they were not visually exercised in the app. No full test suite was run because no application code changed. This audit did not inspect every possible detector and does not claim exhaustiveness.

## Resolution in local 1.10.3

The audit above describes the released 1.10.2 behavior. The following corrections were implemented on `fix/network-detection-accuracy`; see the 1.10.3 CHANGELOG notes for user-facing effects. The local validation build used version 1.10.3.

| Finding | Correction | Regression coverage |
| --- | --- | --- |
| 1 | Recurring critical/warning recorded diagnoses constrain the historical network verdict after enough fault-bearing full, quick, or legacy checks. | `tests/test_history.bats` |
| 2 | P1/P2 require a measured public check and do not override successful public pings or TCP. The Report card distinguishes reachable from unmeasured. | `tests/test_diagnosis_accuracy.bats`, `tests/test_output.bats`, `tests/test_monitor.bats` |
| 3 | Apple canary success establishes HTTP reachability independently of public-IP metadata; failure of one metadata service no longer claims a whole-internet outage. | `tests/test_diagnosis_accuracy.bats`, `tests/test_output.bats` |
| 4 | A monitor fault remains last-known through unknown or partial cycles; only rule-relevant evidence can produce a `rule-cleared` event. Confirmation streak gaps cannot falsely resolve continuing warning-band loss. | `tests/test_monitor.bats` |
| 5 | Configured DNS fallback requires an answer from the configured secondary, not a direct public resolver. | `tests/test_dns.bats` |
| 6 | Final diagnosis follows speed measurement while the Report card remains early. Printed and saved findings use the same measured capacity. | `tests/test_progress.bats` |
| 7 | Gateway loss from a run with TCP-1 stays in raw history but is excluded from router-fault judgement. | `tests/test_history.bats`, `tests/test_summary.bats` |
| 8 | Historical drift judgement and comparisons use each reading's magnitude; raw signed readings remain available. | `tests/test_history.bats`, `tests/test_summary.bats` |
| 9 | Historical MTU applies VPN/split-tunnel policy and the scan's exact lower-bound semantics while retaining raw MTU. | `tests/test_history.bats`, `tests/test_summary.bats` |
| 10 | Baseline matching uses the same canonical network key as history across hidden/visible SSID forms. | `tests/test_helpers.bats` |
| 11 | Dashboard crowding comes from CLI WS-1 and the displayed count is same-channel neighbors. | `gui/Tests/HopwatchGUITests/DashboardCheckEvidenceTests.swift` |
| 12 | Missing DNS/TCP/bufferbloat evidence is neutral; absent grades and latency values are no longer fabricated. | `gui/Tests/HopwatchGUITests/DashboardCheckEvidenceTests.swift` |
| 13 | Baseline warns on supported MTU decreases, not increases. | `tests/test_helpers.bats` |

Integration review also caught two related mismatches: monitor P1/P2 now accept successful independent TCP or public ping traffic after a failed web probe, and the dashboard's web row accepts any successful TCP target rather than only the first. The additional regressions are in `tests/test_monitor.bats` and `DashboardCheckEvidenceTests.swift`.

Existing saved diagnosis records remain as recorded; the historical recurrence verdict does not retroactively rerun old scans. The three policy-dependent candidates above remain outside this change. Full-suite and installed-app verification are recorded below.

## Verification of local 1.10.3

- `make test` passed on the final source state: 966 CLI Bats tests and 123 Swift GUI tests across 20 suites.
- `shellcheck -x` passed for all changed shell product modules; Python compilation and `git diff --check` passed.
- `make install-gui` built, signed with the stable identity, and installed `/Applications/Hopwatch.app`; it was relaunched with `open`. Its bundle and bundled CLI both report 1.10.3, and the GUI process is running.
- `codesign --verify` remained valid after launch. A regression first reproduced Python creating `__pycache__` inside the signed bundle; exporting `PYTHONDONTWRITEBYTECODE=1` for helper subprocesses prevented the post-launch signature failure. No bundled `.pyc` was present after relaunch.
- The dashboard row states were verified by Swift tests. Live visual inspection was unavailable because this menu bar app exposed no ordinary window to the UI automation surface.
