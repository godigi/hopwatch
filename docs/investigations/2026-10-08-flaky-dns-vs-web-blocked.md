# 2026-10-08 — "DNS resolver flaky" / "Web blocked (port 443)" bouncing

Observed in v1.12.0: the menu bar card alternated between *DNS failing* (D1,
"DNS resolver flaky") and *Web blocked — Port 443 down* on a link whose router
ping was 3 ms and whose internet ping was 59 ms.

## What is actually wrong (measured, 120 s, 5 probes in parallel)

| Probe | Result |
|---|---|
| ICMP to router (240 pkts) | 0% loss, avg 7.7 ms |
| ICMP to 1.1.1.1 (240 pkts) | 0% loss, avg 62.7 ms |
| UDP DNS `@1.1.1.1` (120) | 11 timed out (9%) |
| UDP DNS `@8.8.8.8` (120) | 13 timed out (11%) |
| DNS via system resolver (120) | 1 timed out (dig falls back between the two) |
| TCP/443 to 1.1.1.1 (120) | 72 refused (60%) |
| TCP/443 to 8.8.8.8 (120) | 70 refused (58%) |

- **It is not the resolver.** The Mac's resolvers are 1.1.1.1 and 8.8.8.8 (not the
  router's), two unrelated operators. 8 of 11 and 9 of 13 failures coincide within
  2 s across the two. 18 of 24 DNS failures coincide with a TCP/443 refusal.
- **It is not port 443 being blocked.** `nc -v` says `Connection refused` in
  10–40 ms. 1.1.1.1 is 55 ms away, so that refusal was not sent by 1.1.1.1; the
  same host accepts the next connection. Something near the Mac is rejecting *new*
  flows intermittently while ICMP and existing flows are untouched.
- **Likely cause: the Mac is flooding the router with new flows.** Stremio's
  streaming server (`/Applications/Stremio.app/.../node server.js`, PID 48834) holds
  210 UDP sockets and 67 connections stuck in SYN_SENT to BitTorrent peers on port
  6881. Consumer routers exhaust their NAT/connection table under that load and
  refuse or drop new flows.
- **Proven.** Quitting Stremio (0 SYN_SENT sockets afterwards) and re-running the
  identical 120 s probe: 0/120 DNS failures to 1.1.1.1, 0/120 to 8.8.8.8, 0/120
  system, 0/120 TCP/443 refusals to either target, ICMP still 0% loss.
- **Still open.** Whether the refusal is sent by the router or by something on the
  Mac can't be told apart without a packet capture, which needs root.

## Why Hopwatch says two different things

1. **Both verdicts rest on one sample.** `lib/monitor.sh` `_mon_probe_dns` sends one
   `dig +time=2 +tries=1 @resolver cloudflare.com`; one lost packet sets
   `MON_DNS_OK=0` and D1 fires. There is no confirmation streak for D1 (G3 and L2
   have one: `THRESH_MON_LOSS_CONFIRM_CYCLES`). `_mon_probe_tcp` is the same, with
   two targets, so a bad moment refusing both reads as "down".
2. **The Browsing tile picks whichever probe failed this cycle.**
   `gui/.../Support/SuitabilityEngine.swift` ~L713: `dnsOk == false` wins, else
   `tcpOk == false` → "Web blocked". At ~10% DNS loss and ~35% both-443-refused,
   it alternates.
3. **The prose claims a cause nobody measured.** D1 says "your DNS server is
   flaky"; "Port 443 … is blocked or unreachable; websites cannot load" says a
   firewall. Both are the same symptom, *new connections intermittently fail*,
   seen through two different probes. Neither names the cause.
4. **ICMP-clean is shown as healthy.** The headline stat tiles (3 ms / 59 ms,
   0% loss) are all ICMP, which was never affected, so the card reads "all green
   with a red problem" and nothing reconciles them.

## Candidate changes (not made)

- Confirm D1 and the 443 verdict over N consecutive cycles, like G3/L2.
- When two independent resolvers fail together, or DNS and TCP/443 fail together
  while ICMP is clean, report one finding — "new connections are being refused
  or dropped on the way out" — not D1 or "Web blocked".
- Name the local cause when there is one: SOCK-1 already counts UDP sockets per
  app; a many-SYN_SENT / many-UDP-socket holder is the same evidence class.
- Reword "blocked" to what was observed (refused, and how fast).
- Per `CLAUDE.md`, the 443/DNS tile logic in `SuitabilityEngine.swift` is verdict
  logic in Swift; it belongs in `lib/`.

## Proposed fix plan (awaiting go-ahead; worktree `fix/connection-refusal-finding`)

1. **New rule `CONN-1`** (`lib/diagnosis.sh`, mirrored in `lib/monitor.sh`
   `_mon_rules`): new outbound connections are being refused or dropped while ICMP
   is clean. Fires when DNS and TCP/443 fail in the same window (or two independent
   resolvers fail together) and gateway/internet loss are under the warn cutoff.
   It suppresses D1/D5 and the "Web blocked" wording, the way SOCK-1 suppresses D1.
2. **Confirmation, not one sample.** CONN-1, and D1 when it fires alone, wait
   `THRESH_MON_CONN_CONFIRM_CYCLES` consecutive cycles (new, in `lib/thresholds.sh`).
3. **Name the local cause.** Extend the `lsof` evidence SOCK-1 already gathers with
   SYN_SENT and UDP-socket counts per process; CONN-1 names the app that holds
   most of them (same `THRESH_SOCK_HOLDER_SHARE_PCT` rule) and offers the existing
   `quit-app` repair. No new repair type.
4. **GUI.** `SuitabilityEngine` browsing tile reads `status.rules` / `diagnosis[]`
   for CONN-1 instead of deciding from raw `dns.ok` / `tcp.anyOk`.
5. **Docs and tests.** `docs/DIAGNOSIS-RULES.md`, `docs/JSON-SCHEMA.md`,
   `--rules-catalog`; bats for CONN-1 (fires, suppresses D1, held by the confirm
   streak, monitor/scan parity); shellcheck and `--verify` clean.

Open question: whether to call it a Hopwatch finding at all when the cause is the
user's own app, or leave a generic "new connections failing" with the app named
only as a hint. Recommendation: name it; the repair button is the useful part.
