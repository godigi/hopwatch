# Hopwatch (formerly netdiag) — project instructions

This project builds `Hopwatch` (`hopwatch`), a comprehensive macOS network-diagnostic monitor, menu bar app, and CLI. This file is the working contract; the reference docs are [`docs/JSON-SCHEMA.md`](./docs/JSON-SCHEMA.md), [`docs/DIAGNOSIS-RULES.md`](./docs/DIAGNOSIS-RULES.md), and [`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md).

## Scope

Grown from a ~300-line bash starter into a modular `lib/*.sh` CLI with 14 diagnostic enhancements, shipped as a public GitHub repo with CI and a one-line installer. The original build spec (`netdiag-prompt.md`) was removed once its two load-bearing sections — the JSON schema and the acceptance criteria — had been moved into `docs/JSON-SCHEMA.md` and this file. It remains in git history.

## Engineering constraints (non-negotiable)

- **Platform:** macOS 14+ (Sonoma/Sequoia/Tahoe), Apple Silicon and Intel. No Linux portability for v1.
- **Shell:** must work under both zsh (default) and Homebrew bash 5+. Declare bash in the shebang if needed.
- **Dependencies:** prefer macOS built-ins (`ipconfig`, `networksetup`, `route`, `scutil`, `wdutil`, `dig`, `traceroute`, `ping`, `nc`, `arp`, `log`, `sntp`, `system_profiler`, `curl`). Acceptable Homebrew extras: `mtr`, `gping`, `speedtest` (or `speedtest-cli`), `jq`. Detect missing deps → skip with hint, never hard-fail.
- **Permissions:** 100% sudo-free. Hopwatch never prompts for root and never nudges users to cache sudo credentials. All standard diagnostics, latency tests, and monitoring run in user space.
- **Parallelism:** run independent checks concurrently via background jobs + `wait`. Target ≤ 35s for `--no-speed`, ≤ 8s `--quick`. A default run now includes the speed test and is bound by whichever speedtest CLI is installed — measured at ~115s with `speedtest-cli` and ~65s with Ookla's `speedtest`, which is why the installer prefers Ookla. `--no-speed` is the flag to reach for when the run needs to be fast.
  - Two checks must **not** be parallelised, because both measure a property of a quiet link: `internet_ping_run` (packet loss / latency) and `bufferbloat_run` (which saturates the link deliberately). Running the loss probe inside the parallel batch made it report 30% loss on a healthy network.
- **Read-only:** never modify routing, DNS, WiFi, or ARP state.
- **shellcheck-clean** at default severity. `# shellcheck disable=...` only with justification.
- **Thresholds live in `lib/thresholds.sh`, nowhere else.** Four things now
  judge a network — `lib/diagnosis.sh` (one verdict per scan),
  `lib/monitor.sh` (one every few seconds), `helpers/history.py` (one per
  metric, per stored run, in `--show`'s comparison — and now one per
  network, from that network's stored-run medians, in `--history`'s
  `judged` block) and `helpers/summary.py` (one per metric, per network,
  over a window) — the last two reading one shared pair-table in
  `helpers/judgement.py` so they can't disagree — and if they drift the
  app shows a green dot over a red report. `tests/test_thresholds.bats`
  fails the build on an inline numeric cutoff in any of the four.
- **The GUI holds no diagnostic logic.** `gui/` renders what the CLI
  decides: rule IDs come from `status.rules`, prose comes from
  `diagnosis[].summary` verbatim. If a change would put a threshold or a
  user-facing verdict string into Swift, it belongs in `lib/` instead.
- **Three depths, and the app always says which one it is in.** This has
  drifted more than once, so it is written down here rather than left to
  be re-derived:

  | | **Monitoring** | **Full check** | **Quick check** |
  |---|---|---|---|
  | Answers | *Is it still fine?* | *What is this network capable of?* | *What is wrong right now?* |
  | When | continuous, every few seconds | the one manual action; automatically **once** per new network | never a manual action — see below |
  | Cost | negligible, no saturation | ~65–115 s, **saturates the link** | ~8 s, never saturates |
  | Gives | one sample per cycle, alerts on transitions | bufferbloat, speed, path MTU, per-hop loss | everything else |

  **The quick check is an internal depth, not a button.** The GUI
  deliberately offers one manual action, the full check, because two
  manual checks presented side by side read as equivalent choices and
  leave the user to guess which one they want. "What is wrong right now?"
  is answered *without being asked*: monitoring runs continuously, starts
  a 2-second investigation burst the instant severity turns bad, and
  triggers its own non-saturating scan. The quick depth is reached from
  `ArrivalPolicy` (a metered or unhealthy link on arrival) and from an
  alert, never from a control. `netdiag --quick` remains ordinary CLI
  surface; this rule is about the app.

  Two further rules follow, and both are load-bearing:
  1. **Every new network gets a check on arrival, and the arrival is a
     state the UI renders** — not a fire-and-forget side effect that can
     decline itself and never retry. A depth may be downgraded (an
     unhealthy link, a metered hotspot), but then the app says so on
     screen and offers the full check as a button. See
     `docs/design/2026-08-31-arrival-and-the-three-modes-design.md`.
  2. **Any Home surface reading history scopes to the current network, or
     states its provenance.** An unlabelled report from the network you
     were on an hour ago is indistinguishable from one about the network
     you are on now, and users read it as the latter.

  A full check is never on a timer — see the arrival spec and
  `docs/ARCHITECTURE.md`.

## CLI surface

```
netdiag [TARGET] [--quick] [--quiet] [--json] [--expert] [--redact]
        [--gping] [--no-gping] [--no-bufferbloat]
        [--speed] [--no-speed] [--mtu-only] [--wifi-only] [--speed-only]
        [--progress]
        [--baseline] [--no-baseline] [--log PATH] [-h|--help]
netdiag --watch[=SEC] | --summary[=HOURS] | --history[=N] | --show=ID
        | --share[=ID|-] | --events[=HOURS]
netdiag --version | --capabilities | --rules-catalog
netdiag --monitor [--journal PATH]
                  [--monitor-fast-interval SEC] [--monitor-degraded-interval SEC]
                  [--monitor-medium-interval SEC] [--monitor-slow-interval SEC]
                  [--monitor-count N]
netdiag --install-watcher | --uninstall-watcher
netdiag --install-recorder | --uninstall-recorder
```

`--history`, `--show` and `--monitor` exist for the GUI (see below) but are
ordinary CLI surface: all three are documented in `docs/JSON-SCHEMA.md`, all
three are covered by bats, and none requires the app.

`--show=ID` returns one stored run in full plus a `comparison` block judging
each metric against every other run on the same network. The judging is why
`helpers/history.py` is now a **third** file bound by the thresholds rule
below — it decides whether a number is good, so its cutoffs live in
`lib/thresholds.sh` like every other cutoff, reaching Python through the
environment.

`--share` is the pasteable form of a report: one run as plain text, no
colours, identifying values masked. It exists rather than being a flag on
`--redact` because `lib/output.sh` deliberately stores every run
*unredacted* and `helpers/history.py` drops `--redact` runs from the store
entirely — so there is no redacted stored copy to read, and sharing a past
run has to redact at read time. `--share=-` reads one run's JSON on stdin,
which is how netdiag.app shares the report already on screen without
re-running anything.

`--events` is the read side of the event journal, and the reason the
project has one: a stored run is a snapshot with one timestamp, so
"was the internet down at 03:14, and for how long" was unanswerable.
`--monitor --journal PATH` appends one line per *transition* — the
`changes` set the monitor already computed every cycle and discarded —
and `--events` pairs faults into episodes with durations. The journal
is **opt-in** because `--monitor`'s contract is a process that writes
nothing to disk; `--install-recorder` is the launchd agent that passes
the flag. `helpers/events.py` deliberately judges nothing: whether a
duration is acceptable is a verdict, and verdicts live in
`lib/diagnosis.sh` against `lib/thresholds.sh` (`AV-1`/`AV-2`, not yet
written).

`--monitor` is the machine-readable sibling of `--watch`, not a duplicate
of it: `--watch` re-runs `--quick` and prints prose for a person, while
`--monitor` streams one compact JSON object per line for a program, writes
nothing to disk, and probes on three cadence tiers instead of one. It is
paused with `SIGUSR1` and resumed with `SIGUSR2` — **never `SIGSTOP`**, see
the header of `lib/monitor.sh` for the orphaned-process-group reason.

## Output modes

- **Default:** colored human-readable stdout + ANSI-stripped log to `~/net-diag/<timestamp>.log`.
- **`--json`:** single JSON object to stdout matching [`docs/JSON-SCHEMA.md`](./docs/JSON-SCHEMA.md). No colors, no log unless `--log` also passed.
- **`--quiet`:** only the punchline sections to stdout — "What should work
  here" and the Diagnosis — with the full log still written. Suitability is
  included deliberately: five per-activity verdicts are the most compressed
  useful answer the report has, which is exactly what `--quiet` is for.
- **`--quick`:** skip bufferbloat, mtr, speed test, internet packet-loss probe, baseline diff, WiFi scan. An explicit `--speed` overrides the speed-test skip.

## Exit codes

- `0` healthy · `1` warnings only · `2` ≥ 1 critical diagnosis · `3` script error.
- Usage errors (bad flag, duplicate TARGET, bare `--log`) exit `3`, not `2` —
  `2` is reserved for a real diagnosis so wrappers can distinguish the two.

## The 14 enhancements (implementation order)

**High-value:** 1) bufferbloat (loaded vs idle RTT, A–F grade, gateway vs ISP split) · 2) PMTU black-hole probe · 3) continuous loss via `mtr -r -c 60` · 4) IPv6 parity · 5) VPN-active detection · 6) TCP reach panel (not just ICMP).

**Medium-value:** 7) WiFi neighborhood scan · 8) WiFi disconnect/roam history from `log show` · 9) speed test (Ookla → speedtest-cli → skip) · 10) NTP/time-sync drift check · 11) baseline diff against last N runs · 12) custom positional `TARGET` argument.

**Polish:** 13) duplicate-IP / ARP conflict detection · 14) DHCP lease detail + DHCP-vs-system DNS comparison.

Each must: produce a labeled section, contribute to JSON output, feed the Diagnosis stage where appropriate.

## Repo layout

```
hopwatch/
├── bin/hopwatch             # bash entry point
├── lib/*.sh                 # modular checks
├── helpers/*.py             # Python helpers for parsing and analytics
├── tests/{fixtures,*.bats}  # bats-core test suites
├── examples/sample-output.{txt,json}
├── gui/                     # SwiftUI menu-bar app (SwiftPM, no Xcode)
│   ├── Package.swift  Makefile  Resources/Info.plist
│   └── Sources/HopwatchGUI/{Models,Services,Alerts,Views,Support}
├── docs/                    # Architecture, design specs, rules, and assets
│   ├── {ARCHITECTURE,DIAGNOSIS-RULES,JSON-SCHEMA,SCREENSHOTS}.md
│   ├── design/              # Architecture and feature design specifications
│   ├── archive/plans/       # Historical implementation plans
│   └── assets/              # Light and dark UI screenshots
├── .github/workflows/       # GitHub Actions CI & release automation
├── README.md  CHANGELOG.md  LICENSE  install.sh  install-app.sh  .gitignore
```

Before refactoring past ~700 lines of bash, decide bash-modules vs bash+Python helper and record the rationale in `docs/ARCHITECTURE.md`.

## Workflow expectations

1. Before writing code for a new chunk of work, produce a short plan (< 400 words) covering structure, bash/Python split, implementation order, and clarifying questions.
2. After implementing, actually run `netdiag` on this machine and paste real output into `examples/sample-output.{txt,json}`. If running in a sandbox, say so explicitly.
   - **Capture those with `--redact`, from stdout.** This repo is public, and a plain run puts the machine's public IPv6 address and city in the sample — an IPv6 address identifies a household the way a NATed v4 address does not. (The ISP name is kept by design even under `--redact`: `helpers/emit_json.py:275`'s `_REDACT_ENV` deliberately excludes it — ASN and ISP name a provider, which is needed to reason about the fault — so `examples/sample-output.txt` still shows the ISP name alongside `([redacted], Brazil)`.) The trap: `--redact` masks stdout and JSON while the **local log deliberately keeps full detail**, so capturing via `--log` yields an unredacted file that looks like it worked. Use `netdiag --redact --json` and `netdiag --redact | sed $'s/\\x1b\\[[0-9;]*[mK]//g'`. The text sample is the default view, not `--expert`: `--redact` forces `EXPERT=0`, because the expert panel is where the identifying values live.
3. Commits: one per logical feature group, clean history. Tag releases `v0.2.0+`.
4. Don't push to GitHub or create the repo until the script runs and sample output looks sane.

## Acceptance criteria (definition of done)

All 11 must hold before declaring the project shippable:

1. `netdiag` runs end-to-end on macOS with all 14 sections, no shellcheck warnings, no uncaught errors.
2. `netdiag --json` produces valid JSON matching `docs/JSON-SCHEMA.md`; `netdiag --json | jq .` succeeds.
3. `netdiag --quick` skips bufferbloat, mtr, speed test, baseline diff, and WiFi scan; finishes in ≤ 8 s on a healthy network.
4. WiFi diagnostics capture SSID, BSSID, security, channel, and neighborhood scan completely sudo-free.
5. `netdiag github.com` adds the target to ping, traceroute, TCP-reach, and DNS.
6. Exit codes work as specified (0/1/2/3).
7. A successful run writes a parseable human-readable log to `~/net-diag/<timestamp>.log`.
8. Each diagnosis explains its conclusion with evidence, not just a verdict.
9. README is complete; `examples/sample-output.{txt,json}` are real captures from an actual run.
10. The repo is public on GitHub, tagged, with passing CI (shellcheck + bats).
11. `docs/ARCHITECTURE.md` explains the bash-vs-Python decision; `docs/DIAGNOSIS-RULES.md` lists every diagnosis rule that can fire.
