# Local socket failure, and guided DNS switching

Status: proposed, not implemented. Written 2026-10-07 after a real incident.

## The incident

On 2026-10-07 the app reported **D1 — "your DNS server is flaky, restart your
router"** for well over an hour. That was wrong. The router and both public
resolvers were fine; the Mac itself could not open a UDP socket:

```
$ dig @192.168.1.1 apple.com
dig: isc_socket_bind: address not available
```

What was observed at the time:

- every UDP `dig` failed with that error, against the router, 1.1.1.1 and 8.8.8.8
- `dig +tcp @1.1.1.1` answered in 69 ms
- ping to the router and to 1.1.1.1 was healthy, 0% loss
- flushing the DNS cache, `ipconfig set en0 DHCP`, forgetting networks and
  toggling Wi-Fi did not help; a reboot did

The likely cause is UDP ephemeral-port exhaustion (range 49152–65535) from a
process leaking sockets. **This is not proven** — the reboot destroyed the
evidence, and no socket census was taken while it was happening. Six minutes
after the reboot the machine held 41 UDP sockets. Hopwatch's own monitor
(a `dig` every medium-tier cycle) is an untested suspect.

## Why Hopwatch got it wrong

Every DNS probe discards stderr and treats an empty answer as "the resolver
did not answer":

- `lib/monitor.sh:484` (`_mon_probe_dns`)
- `lib/dns.sh:18`, `:63`, `:78`, `:89`, `:101`

So "the Mac could not send the question" and "the server did not reply" are
the same value, and D1/D2 blame the router for a fault on this machine. The
advice that follows (restart the router) cannot work.

## Part 1 — detect a local socket failure

**A probe that does not depend on dig's wording.** New `helpers/sockcheck.py`:
bind a UDP socket to port 0, report `ok` or the errno name. Bash calls it
only when a `dig` came back empty, so the healthy path pays nothing. As a
second signal, keep `dig`'s stderr for that one retry and match
`socket_bind`/`address not available`.

**A new rule, `SOCK-1` (critical).** Fires when the local bind fails. It
suppresses D1, D2, D5 and V6-2 for that run, because their evidence is void.
Draft summary, written for someone who does not know what a socket is:

> This Mac has run out of room to make new network connections, so it can't
> look up website names — even though your Wi-Fi, router and internet are all
> fine. Restarting the router will not help. Quit *<app>* (it is holding
> *N* connections open), or restart this Mac.

**Evidence captured at fault time**, because a reboot erases it:

- UDP socket count (`netstat -an -p udp`)
- top holders by process (`lsof -nP -iUDP`). Sudo-free, so only the user's
  own processes are visible; when the holder is not visible the summary drops
  the "quit <app>" clause and says to restart.
- whether TCP DNS still works

All three go into the JSON `dns` block and, when `--journal` is on, into the
event line for the transition. Next time this happens the culprit is on disk.

**Monitor.** `_mon_probe_dns` gains `MON_DNS_LOCAL_FAIL`; `SOCK-1` reaches the
app through `status.rules` like any other rule. No Swift logic.

**Thresholds.** The trigger is a failed bind, not a count, so no cutoff is
needed. If an early warning ("80% of ports in use") is added later, that
number goes in `lib/thresholds.sh`.

**Tests.** Bats with a stub `dig` that prints the bind error and a stub
`sockcheck.py`: assert `SOCK-1` fires and D1/D2 do not. A second case with a
silent `dig` and a healthy bind asserts D1 still fires.

**Docs.** `docs/DIAGNOSIS-RULES.md` (new rule + suppression), 
`docs/JSON-SCHEMA.md` (new `dns` fields), CHANGELOG.

## Part 2 — guided switch to a better DNS

**Not a one-click button.** Changing DNS needs admin rights and writes system
network state; the project is sudo-free and read-only by contract. Guidance
only.

**Only offered when the evidence supports it.** A new rule `D6` fires when the
router-supplied resolver fails or is slow *and* a public resolver answered in
the same scan (`lib/dns.sh` already probes both). It is never shown as a
general "improve your internet" tip, and never alongside `SOCK-1` — in the
incident above it would not have helped.

**What it says.** One plain-language sentence on what DNS is ("the phone book
that turns a website name into an address; on this network the phone book is
the part that's failing"), then two options, recommended first:

1. **Encrypted DNS** — install a provider's profile (Cloudflare, Quad9) or
   turn on Secure DNS in the browser. Lookups are private and cannot be
   tampered with on the local network. `EDNS-1` already detects the result.
2. **Plain public DNS** (1.1.1.1 / 8.8.8.8) in System Settings → Wi-Fi →
   Details → DNS. Fixes a broken router resolver, but is **not encrypted**.

**Downsides the guidance must state**, because the audience will not know them:

- a hotel or café sign-in page may not appear until DNS is set back
- names that only exist on the local network stop working (printers, a work
  intranet, `router.lan`)
- some networks block outside DNS entirely, which makes things worse
- on macOS the manual setting applies to **every** Wi-Fi network, not just
  this one — so the guidance includes how to undo it
- a router's parental or content filter is bypassed

The prose lives in `lib/diagnosis.sh`; the GUI renders it verbatim.

## Out of scope

- Finding what leaked the sockets on 2026-10-07 (evidence gone).
- A soak test of Hopwatch's monitor as the leaker — worth doing, deferred.
- `DH-2` reporting `0.0.0.0` as a router-suggested resolver — separate bug.
