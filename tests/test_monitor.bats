#!/usr/bin/env bats
#
# `netdiag --monitor` — the stream the menu-bar app consumes.
#
# The load-bearing test in this file is the parity block: for the same
# network state, lib/monitor.sh and lib/diagnosis.sh must name the same
# rule IDs. If they drift, the app shows a green dot over a red report and
# the user has no way to tell which one lied. That is checked here against
# synthetic state rather than by blocking ICMP with a firewall rule, which
# would test one condition once on one machine — this tests every condition
# on every push.
#
# Mostly network-free: the parity block and the rest of the file drive the
# pure functions (_mon_rules, monitor_sample.py) or exercise argument
# validation, which exits before any probe runs. The exception is the
# "Pause and resume" and "Orphan cleanup" blocks near the end, which start a
# real `hopwatch --monitor` and so really ping the gateway and resolve DNS
# every couple of seconds. A monitor that outlives its test keeps doing that,
# so those blocks are bounded three ways: the bats test shell is the
# monitor's parent (so the product's parent-died guard reaps it if bats is
# killed), teardown() kills every monitor a test started, and each carries
# --monitor-count as a hard cap.

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  HELPERS="$REPO/helpers"
  JSON_MODE=0 QUIET=0 QUICK=0 EXPERT=0 REDACT=0 LOG=/dev/null
  NETDIAG_VERSION="test"
  # shellcheck source=../lib/thresholds.sh
  . "$REPO/lib/thresholds.sh"
  # shellcheck source=../lib/common.sh
  . "$REPO/lib/common.sh"
  # shellcheck source=../lib/globals.sh
  . "$REPO/lib/globals.sh"
  # shellcheck source=../lib/netid.sh
  . "$REPO/lib/netid.sh"
  # shellcheck source=../lib/traffic.sh
  . "$REPO/lib/traffic.sh"
  # shellcheck source=../lib/monitor.sh
  . "$REPO/lib/monitor.sh"
}

# Every monitor (or monitor-launching shell) a test started, so teardown can
# kill them even when an assertion failed before the test's own `kill`.
MON_PIDS=()

# TERM, wait briefly for a clean exit, then KILL. Teardown runs after a
# failed assertion too, which is precisely when the test's own kill is
# skipped; the 60 s monitors it leaves behind are what this exists for.
teardown() {
  local p i
  for p in "${MON_PIDS[@]+"${MON_PIDS[@]}"}"; do
    kill -0 "$p" 2>/dev/null || continue
    kill -TERM "$p" 2>/dev/null || true
    for i in 1 2 3 4 5 6; do
      kill -0 "$p" 2>/dev/null || break
      sleep 0.5
    done
    if kill -0 "$p" 2>/dev/null; then
      kill -KILL "$p" 2>/dev/null || true
    fi
    wait "$p" 2>/dev/null || true
  done
  MON_PIDS=()
}

# Reset both rule engines to a healthy baseline, then let each test perturb
# exactly the field under study.
reset_state() {
  # monitor side
  MON_LINK_UP=1 MON_IFACE_TYPE=wifi MON_GATEWAY=192.168.1.1
  MON_GW_LOSS=0 MON_GW_RTT=3 MON_INET_LOSS="" MON_INET_LOSS_ALT="" MON_INET_RTT=""
  MON_GW_HIST="" MON_INET_HIST="" MON_INET_HIST_ALT=""
  MON_WIFI_RSSI="" MON_WIFI_SNR=""
  MON_DNS_OK=1 MON_TCP_OK=1 MON_PUBLIC_OK=1 MON_CAPTIVE=0
  MON_DNS_LOCAL_FAIL="" DNS_LOCAL_FAIL=0
  MON_WEB_OK="" MON_MEASUREMENT_STATE="unknown"
  MON_VPN_ACTIVE=0 MON_ICMP_FILTERED=0 MON_DEGRADED=0
  MON_GW_LOSS_STREAK=0 MON_INET_LOSS_STREAK=0
  MON_DNS_ALT_OK="" MON_TCP_LINES="" MON_MEDIUM_FRESH=1
  _mon_conn_reset
  _mon_hog_reset
  # scanner side
  GATEWAY=192.168.1.1 IS_WIFI=1 GW_LOSS=0 WIFI_RSSI="" WIFI_SNR=""
  DNS_OK=1 DNS_LINES="x|y|z|OK" PUBLIC_OK=1 PUBLIC_CHECKED=1
  TCP_REACH_ANY_OK=1 VPN_ACTIVE=0 CAPTIVE_PORTAL=0
  IPV6_AVAILABLE=0 MTU_EFFECTIVE="" MTR_FIRST_LOSSY_HOP=""
  INET_LOSS="" INET_LOSS_ALT="" NTP_DRIFT_S="" DHCP_TIME_REMAINING_S=""
  ARP_GW_INCOMPLETE=0 ARP_DUPLICATE_IPS="" DHCP_DNS_SERVERS="" SYS_RES_ALL=""
  WIFI_SCAN_CURRENT_CHANNEL_NEIGHBORS=0 WIFI_DISCONNECT_COUNT=0
  BUFFERBLOAT_GW_GRADE="" BUFFERBLOAT_INET_GRADE=""
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
}

monitor_rules() {
  _mon_rules
  printf '%s' "$MON_RULES" | tr ' ' '\n' | grep -v '^$' | sort | tr '\n' ' '
}

# Same as monitor_rules, but runs in the current shell so the caller can also
# read MON_SEVERITY and MON_ICMP_FILTERED afterwards — $(monitor_rules) is a
# subshell and would leave them at their reset values.
monitor_rules_here() {
  _mon_rules
  MON_RULES_SORTED="$(printf '%s' "$MON_RULES" | tr ' ' '\n' | grep -v '^$' | sort | tr '\n' ' ')"
}

# The scanner's rules, narrowed to the vocabulary a between-scans probe can
# reach. Everything the monitor cannot measure (NT-1, DI-*, DH-1, BL-1,
# M1, MT1, V6-1, B1/B2, WS-1, WD-1) is scan-only by design and must not be
# claimed by the stream.
MONITOR_VOCABULARY='^(N1|G1|G2|G3|P1|P2|D1|CONN-1|HOG-1|SOCK-1|TCP-1|VPN-1|L1|L2|ICMP-1)$'

scanner_rules() {
  . "$REPO/lib/diagnosis.sh"
  diagnosis_run >/dev/null
  printf '%s\n' "${DIAG_RULE[@]:-}" | grep -E "$MONITOR_VOCABULARY" | sort | tr '\n' ' '
}

# ── Rule parity: the monitor and the scanner agree ───────────────────────

@test "parity: a healthy network produces no rules on either side" {
  reset_state
  [ "$(monitor_rules)" = "$(scanner_rules)" ]
  reset_state
  [ -z "$(monitor_rules)" ]
}

@test "parity: heavy gateway loss produces G2 on both" {
  reset_state; MON_GW_LOSS=25 GW_LOSS=25
  local m s; m="$(monitor_rules)"; reset_state
  MON_GW_LOSS=25 GW_LOSS=25; s="$(scanner_rules)"
  [ "$m" = "$s" ]
  [[ "$m" == *"G2"* ]] || return 1
}

@test "parity: loss in the warn band produces G3 on both" {
  # G3 only fires on the monitor once it has held for
  # THRESH_MON_LOSS_CONFIRM_CYCLES consecutive cycles (lib/thresholds.sh) —
  # a single cycle's loss is a blip, not a condition. The scanner has no
  # such confirmation: its own probe already averages over 20 packets in
  # one shot. Calling _mon_rules once before monitor_rules() drives the
  # monitor to that confirmed state, so this stays a fair comparison
  # instead of a false mismatch on the first cycle.
  reset_state; MON_GW_LOSS=15 GW_LOSS=15
  _mon_rules
  local m; m="$(monitor_rules)"; reset_state; MON_GW_LOSS=15 GW_LOSS=15
  [ "$m" = "$(scanner_rules)" ]
  [[ "$m" == *"G3"* ]] || return 1
}

@test "parity: on an ICMP-filtering network both name TCP-1 and neither names G2" {
  # Both rules used to fire, which put "reboot your router (unplug it for 30
  # seconds)" and "the network is up; don't worry about the ping numbers
  # above" in the same report, and let the critical one own the headline. A
  # user cannot act on that. TCP reaching 1.1.1.1:443 means packets are
  # crossing the gateway, so the gateway is forwarding and merely declining
  # to answer pings itself — TCP-1's own prose still quotes the loss figure,
  # so no number is lost by dropping the contradiction.
  reset_state; MON_GW_LOSS=100 GW_LOSS=100
  local m; m="$(monitor_rules)"; reset_state
  MON_GW_LOSS=100 GW_LOSS=100
  [ "$m" = "$(scanner_rules)" ]
  [[ "$m" == *"TCP-1"* ]] || return 1
  [[ "$m" != *"G1"* ]] || return 1
  [[ "$m" != *"G2"* ]] || return 1
  [[ "$m" != *"G3"* ]] || return 1
}

# TCP-1 is sound only when nothing but the gateway's own replies is missing.
# TCP "succeeds" through 60% loss because TCP retransmits, so a connect that
# eventually lands says nothing about a link that is shedding most of its
# packets. The corroboration test is loss_corroborates_gateway
# (lib/common.sh), shared by both engines.
@test "parity: gateway loss corroborated by partial internet loss is not TCP-1 on either side" {
  # Live capture that shipped as "healthy": gateway 58, internet 61/60, TCP
  # ok. A gateway that merely rate-limits its own replies does not drop 60%
  # of the pings it forwards to 1.1.1.1, so this is a lossy link.
  reset_state
  MON_GW_LOSS=58 GW_LOSS=58 MON_INET_LOSS=61 MON_INET_LOSS_ALT=60 INET_LOSS=61 INET_LOSS_ALT=60
  monitor_rules_here; local m="$MON_RULES_SORTED"
  [ "$MON_ICMP_FILTERED" -eq 0 ]
  [ "$MON_SEVERITY" != "ok" ] && [ "$MON_SEVERITY" != "info" ]
  reset_state
  MON_GW_LOSS=58 GW_LOSS=58 MON_INET_LOSS=61 MON_INET_LOSS_ALT=60 INET_LOSS=61 INET_LOSS_ALT=60
  [ "$m" = "$(scanner_rules)" ]
  [[ "$m" != *"TCP-1"* ]] || return 1
  [[ "$m" == *"G2"* ]] || return 1
}

@test "parity: corroborated gateway loss keeps the monitor severity critical, not info" {
  reset_state
  MON_GW_LOSS=58 MON_INET_LOSS=61 MON_INET_LOSS_ALT=60
  _mon_rules
  [ "$MON_SEVERITY" = "critical" ]
  [ "$MON_ICMP_FILTERED" -eq 0 ]
}

@test "parity: gateway loss with clean internet loss is still TCP-1 on both" {
  # Sound case 1: pings forwarded through the gateway come back, so the
  # gateway is forwarding and only declining to answer for itself.
  reset_state
  MON_GW_LOSS=58 GW_LOSS=58 MON_INET_LOSS=0 MON_INET_LOSS_ALT=0 INET_LOSS=0 INET_LOSS_ALT=0
  monitor_rules_here; local m="$MON_RULES_SORTED"
  [ "$MON_ICMP_FILTERED" -eq 1 ]
  reset_state
  MON_GW_LOSS=58 GW_LOSS=58 MON_INET_LOSS=0 MON_INET_LOSS_ALT=0 INET_LOSS=0 INET_LOSS_ALT=0
  [ "$m" = "$(scanner_rules)" ]
  [[ "$m" == *"TCP-1"* ]] || return 1
  [[ "$m" != *"G2"* ]] || return 1
}

@test "parity: gateway and both internet targets at 100% with TCP ok is TCP-1 plus ICMP-1 on both" {
  # Sound case 2: ICMP is blocked wholesale, which is ICMP-1 territory.
  reset_state
  MON_GW_LOSS=100 GW_LOSS=100 MON_INET_LOSS=100 MON_INET_LOSS_ALT=100 INET_LOSS=100 INET_LOSS_ALT=100
  monitor_rules_here; local m="$MON_RULES_SORTED"
  [ "$MON_ICMP_FILTERED" -eq 1 ]
  reset_state
  MON_GW_LOSS=100 GW_LOSS=100 MON_INET_LOSS=100 MON_INET_LOSS_ALT=100 INET_LOSS=100 INET_LOSS_ALT=100
  [ "$m" = "$(scanner_rules)" ]
  [[ "$m" == *"TCP-1"* ]] || return 1
  [[ "$m" == *"ICMP-1"* ]] || return 1
  [[ "$m" != *"G2"* ]] || return 1
}

@test "parity: gateway loss with internet loss unmeasured is TCP-1 on both (as before)" {
  # --quick skips the internet loss probe; with nothing to corroborate the
  # inference stays exactly what it was.
  reset_state
  MON_GW_LOSS=58 GW_LOSS=58
  monitor_rules_here; local m="$MON_RULES_SORTED"
  [ "$MON_ICMP_FILTERED" -eq 1 ]
  reset_state; MON_GW_LOSS=58 GW_LOSS=58
  [ "$m" = "$(scanner_rules)" ]
  [[ "$m" == *"TCP-1"* ]] || return 1
}

@test "parity: gateway loss with one internet target lossy and one clean is still TCP-1 on both" {
  reset_state
  MON_GW_LOSS=58 GW_LOSS=58 MON_INET_LOSS=60 MON_INET_LOSS_ALT=0 INET_LOSS=60 INET_LOSS_ALT=0
  monitor_rules_here; local m="$MON_RULES_SORTED"
  reset_state
  MON_GW_LOSS=58 GW_LOSS=58 MON_INET_LOSS=60 MON_INET_LOSS_ALT=0 INET_LOSS=60 INET_LOSS_ALT=0
  [ "$m" = "$(scanner_rules)" ]
  [[ "$m" == *"TCP-1"* ]] || return 1
}

@test "loss_corroborates_gateway: the predicate's edges" {
  # both partial -> yes
  loss_corroborates_gateway 61 60
  # clean, mixed, below the warn floor -> no
  ! loss_corroborates_gateway 0 0
  ! loss_corroborates_gateway 60 0
  ! loss_corroborates_gateway 9 60
  # unmeasured on both -> no (behaviour as before)
  ! loss_corroborates_gateway "" ""
  # both at total loss is ICMP-1, not corroboration
  ! loss_corroborates_gateway 100 100
  # 100 on one and partial on the other is not wholesale ICMP blocking
  loss_corroborates_gateway 100 60
  # one leg missing: judge by the one that was measured
  loss_corroborates_gateway 60 ""
  loss_corroborates_gateway "" 60
  ! loss_corroborates_gateway 100 ""
  ! loss_corroborates_gateway 0 ""
}

@test "a stale TCP-1 clears on a cycle where corroboration, not TCP, decided it" {
  # Gateway loss is still >= 50 and the medium tier did not refresh, so the
  # old clearability rule would have left TCP-1 pinned forever.
  reset_state
  MON_GW_LOSS=58 MON_INET_LOSS=61 MON_INET_LOSS_ALT=60 MON_REFRESHED="fast "
  _mon_rules
  [[ " $MON_CLEARABLE_RULES " == *" TCP-1 "* ]]
}

@test "TCP-1 stays unclearable at gateway loss >= 50 when nothing corroborates and TCP was not refreshed" {
  reset_state
  MON_GW_LOSS=58 MON_REFRESHED="fast "
  _mon_rules
  [[ " $MON_CLEARABLE_RULES " != *" TCP-1 "* ]]
}

@test "parity: heavy gateway loss with TCP also failing still names G2 on both" {
  # The other half of the suppression: without a working TCP path there is
  # no evidence the gateway forwards anything, so the loss is a fault and
  # must still be called one.
  reset_state; MON_GW_LOSS=100 GW_LOSS=100 MON_TCP_OK=0 TCP_REACH_ANY_OK=0
  local m; m="$(monitor_rules)"; reset_state
  MON_GW_LOSS=100 GW_LOSS=100 MON_TCP_OK=0 TCP_REACH_ANY_OK=0
  [ "$m" = "$(scanner_rules)" ]
  [[ "$m" == *"G2"* ]] || return 1
  [[ "$m" != *"TCP-1"* ]] || return 1
}

@test "an ICMP-filtering network is not a critical severity" {
  # The exit-code consequence of the same conflation: every hotel and
  # corporate network scored a critical, so `netdiag` exited 2 and the
  # menu-bar card went red on a connection that works.
  reset_state; MON_GW_LOSS=100
  _mon_rules
  [ "$MON_SEVERITY" != "critical" ]
}

@test "the icmp_filtered flag is set so the alert engine can suppress" {
  reset_state; MON_GW_LOSS=100
  _mon_rules
  [ "$MON_ICMP_FILTERED" -eq 1 ]
}

@test "parity: internet down with DNS also failing is P1 on both" {
  # No independent TCP success can refute this measured public failure.
  reset_state; MON_PUBLIC_OK=0 PUBLIC_OK=0 MON_TCP_OK=0 TCP_REACH_ANY_OK=0 MON_DNS_OK=0 DNS_OK=0
  local m; m="$(monitor_rules)"; reset_state
  MON_PUBLIC_OK=0 PUBLIC_OK=0 MON_TCP_OK=0 TCP_REACH_ANY_OK=0 MON_DNS_OK=0 DNS_OK=0
  [ "$m" = "$(scanner_rules)" ]
  [[ "$m" == *"P1"* ]] || return 1
}

@test "parity: internet down with DNS working is P2 on both" {
  reset_state; MON_PUBLIC_OK=0 PUBLIC_OK=0 MON_TCP_OK=0 TCP_REACH_ANY_OK=0
  local m; m="$(monitor_rules)"; reset_state
  MON_PUBLIC_OK=0 PUBLIC_OK=0 MON_TCP_OK=0 TCP_REACH_ANY_OK=0
  [ "$m" = "$(scanner_rules)" ]
  [[ "$m" == *"P2"* ]] || return 1
}

@test "parity: failed web probe with working TCP does not claim an internet outage" {
  reset_state
  MON_WEB_OK=0 MON_PUBLIC_OK=0 PUBLIC_OK=0
  MON_INET_LOSS=100 MON_INET_LOSS_ALT=100
  INET_LOSS=100 INET_LOSS_ALT=100
  local m; m="$(monitor_rules)"
  local s; s="$(scanner_rules)"
  [[ "$m" != *"P1"* && "$m" != *"P2"* ]]
  [[ "$s" != *"P1"* && "$s" != *"P2"* ]]
  [ "$m" = "$s" ]
}

@test "parity: DNS failing while the internet is reachable is D1 on both" {
  # D1 is confirmed in the monitor like G3 (THRESH_MON_CONN_CONFIRM_CYCLES):
  # one cycle first, so the comparison is against the confirmed state.
  reset_state; MON_DNS_OK=0 DNS_OK=0
  _mon_rules
  local m; m="$(monitor_rules)"; reset_state; MON_DNS_OK=0 DNS_OK=0
  [ "$m" = "$(scanner_rules)" ]
  [[ "$m" == *"D1"* ]] || return 1
}

@test "parity: a Mac that cannot open a UDP socket is SOCK-1 on both, and never D1" {
  # The 2026-10-07 incident: dig failed locally, the internet was fine, and
  # D1 blamed the router. Both engines must name the local fault instead.
  reset_state
  MON_DNS_OK=0 MON_DNS_LOCAL_FAIL=1 DNS_OK=0 DNS_LOCAL_FAIL=1
  local m; m="$(monitor_rules)"
  reset_state
  MON_DNS_OK=0 MON_DNS_LOCAL_FAIL=1 DNS_OK=0 DNS_LOCAL_FAIL=1
  [ "$m" = "$(scanner_rules)" ]
  [[ "$m" == *"SOCK-1"* ]] || return 1
  [[ "$m" != *"D1"* ]] || return 1
}

@test "SOCK-1: critical in the monitor, and D1 cannot fire beside it" {
  reset_state; MON_DNS_OK=0 MON_DNS_LOCAL_FAIL=1
  monitor_rules_here
  [[ "$MON_RULES_SORTED" == "SOCK-1 " ]] || { echo "rules: $MON_RULES_SORTED"; return 1; }
  [ "$MON_SEVERITY" = "critical" ]
  [ "$MON_DEGRADED" -eq 1 ]
}

@test "SOCK-1: a silent resolver with a usable socket is still D1 in the monitor" {
  reset_state; MON_DNS_OK=0 MON_DNS_LOCAL_FAIL=0
  _mon_rules
  monitor_rules_here
  [[ "$MON_RULES_SORTED" == "D1 " ]] || { echo "rules: $MON_RULES_SORTED"; return 1; }
}

@test "SOCK-1: clears only on a cycle that probed and found a socket, and withdraws D1" {
  reset_state; MON_DNS_OK=1 MON_DNS_LOCAL_FAIL="" MON_PREV_RULES="SOCK-1 "
  _mon_rules
  [[ " $MON_CLEARABLE_RULES " != *" SOCK-1 "* ]]
  [[ " $MON_RULES " == *" SOCK-1 "* ]]   # kept as last-known, not announced as recovered
  reset_state; MON_DNS_OK=1 MON_DNS_LOCAL_FAIL=0 MON_PREV_RULES="SOCK-1 "
  _mon_rules
  [[ " $MON_CLEARABLE_RULES " == *" SOCK-1 "* ]]
  [[ " $MON_RULES " != *" SOCK-1 "* ]]
  # While SOCK-1 holds, a D1 carried over from before is void and may clear.
  reset_state; MON_DNS_OK=0 MON_DNS_LOCAL_FAIL=1
  _mon_rules
  [[ " $MON_CLEARABLE_RULES " == *" D1 "* ]]
}

# Stubs for one _mon_probe_dns cycle. The sockcheck stand-in is located the
# way the real helper is, through HELPERS_DIR, and records every call.
stub_dns_probe_world() {
  MON_LINK_UP=1
  HELPERS_DIR="$BATS_TEST_TMPDIR/helpers"
  mkdir -p "$HELPERS_DIR"
  rm -f "$BATS_TEST_TMPDIR/sockcheck.calls"
  printf '#!/usr/bin/env python3\nopen("%s", "a").write("called\\n")\nprint("%s")\n' \
    "$BATS_TEST_TMPDIR/sockcheck.calls" "$1" >"$HELPERS_DIR/sockcheck.py"
  scutil() { printf 'nameserver[0] : 192.168.1.1\n'; }
  with_timeout() { shift; "$@"; }
  netstat() { printf 'udp4 0 0 192.168.1.5.50001 *.*\nudp4 0 0 192.168.1.5.50002 *.*\n'; }
  lsof() {
    printf 'COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\n'
    printf 'Chatty\\x20App 4242 me 3u IPv4 0x1 0t0 UDP *:50001\n'
    printf 'Chatty\\x20App 4242 me 4u IPv4 0x1 0t0 UDP *:50002\n'
  }
}

@test "SOCK-1: _mon_probe_dns tells a local socket failure from a silent resolver" {
  stub_dns_probe_world EADDRNOTAVAIL
  dig() {
    case "$*" in
      *+tcp*) printf '104.16.132.229\n' ;;
      *) echo "dig: isc_socket_bind: address not available" >&2; return 10 ;;
    esac
  }
  _mon_probe_dns
  [ "$MON_DNS_OK" = "0" ]
  [ "$MON_DNS_LOCAL_FAIL" = "1" ]
  [ "$MON_DNS_LOCAL_BIND" = "EADDRNOTAVAIL" ]
  [ "$MON_DNS_UDP_SOCKETS" = "2" ]
  [ "$MON_DNS_TCP_DNS_OK" = "1" ]
  [ "$(printf '%s\n' "$MON_DNS_UDP_HOLDERS" | head -1)" = "Chatty App|4242|2" ]
  # And the rule that follows from it.
  reset_state; MON_DNS_OK=0 MON_DNS_LOCAL_FAIL=1
  [ "$(monitor_rules)" = "SOCK-1 " ]
}

@test "SOCK-1: _mon_probe_dns on a silent resolver with a healthy bind is a plain DNS failure" {
  stub_dns_probe_world ok
  dig() { return 0; }
  _mon_probe_dns
  [ "$MON_DNS_OK" = "0" ]
  [ "$MON_DNS_LOCAL_FAIL" = "0" ]
  [ -z "$MON_DNS_UDP_HOLDERS" ]
}

@test "SOCK-1: _mon_probe_dns pays nothing for the check when the lookup is answered" {
  stub_dns_probe_world EADDRNOTAVAIL
  dig() { printf '104.16.132.229\n'; }
  _mon_probe_dns
  [ "$MON_DNS_OK" = "1" ]
  [ "$MON_DNS_LOCAL_FAIL" = "0" ]
  [ ! -e "$BATS_TEST_TMPDIR/sockcheck.calls" ] || { echo "sockcheck ran on a healthy cycle"; return 1; }
}

@test "SOCK-1: the stream's dns block says the question never left the Mac, with the evidence" {
  run emit NETDIAG_MON_LINK_UP=1 NETDIAG_MON_DNS_OK=0 NETDIAG_MON_DNS_LOCAL_FAIL=1 \
           NETDIAG_MON_DNS_LOCAL_BIND=EADDRNOTAVAIL NETDIAG_MON_DNS_UDP_SOCKETS=16000 \
           NETDIAG_MON_DNS_UDP_TOP_SHARE_PCT=93 NETDIAG_MON_DNS_TCP_DNS_OK=1 \
           NETDIAG_MON_DNS_UDP_HOLDERS=$'Chatty App|4242|15000\nrapportd|646|3' \
           NETDIAG_MON_RULES='SOCK-1 '
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json,sys
d = json.load(sys.stdin)['dns']
assert d['ok'] is False and d['local_fail'] is True, d
assert d['local']['udp_bind'] == 'EADDRNOTAVAIL', d
assert d['local']['udp_sockets'] == 16000 and d['local']['tcp_dns_ok'] is True, d
assert d['local']['top_holders'][0] == {'process': 'Chatty App', 'pid': 4242, 'sockets': 15000}, d
"
  # Unmeasured and healthy are different claims; neither carries evidence.
  run emit NETDIAG_MON_LINK_UP=1
  printf '%s' "$output" | python3 -c "
import json,sys
d = json.load(sys.stdin)['dns']
assert d['local_fail'] is None and d['local'] is None, d
"
  run emit NETDIAG_MON_LINK_UP=1 NETDIAG_MON_DNS_OK=1 NETDIAG_MON_DNS_LOCAL_FAIL=0
  printf '%s' "$output" | python3 -c "
import json,sys
d = json.load(sys.stdin)['dns']
assert d['local_fail'] is False and d['local'] is None, d
"
}

@test "SOCK-1: the journal line that records the fault carries the evidence" {
  local journal="$BATS_TEST_TMPDIR/sock.jsonl"
  run emit NETDIAG_MON_JOURNAL="$journal" NETDIAG_MON_HAVE_PREV=1 \
           NETDIAG_MON_TS=2026-10-07T10:00:00Z \
           NETDIAG_MON_NETWORK_ID=wifi:mac=00:11:22:33:44:55 \
           NETDIAG_MON_RULES='SOCK-1 ' NETDIAG_MON_PREV_RULES='' \
           NETDIAG_MON_DNS_LOCAL_FAIL=1 NETDIAG_MON_DNS_LOCAL_BIND=EADDRNOTAVAIL \
           NETDIAG_MON_DNS_UDP_SOCKETS=16000 NETDIAG_MON_DNS_TCP_DNS_OK=1 \
           NETDIAG_MON_DNS_UDP_HOLDERS=$'Chatty App|4242|15000'
  [ "$status" -eq 0 ]
  python3 - "$journal" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
assert len(rows) == 1, rows
r = rows[0]
assert r["kind"] == "rule-fired" and r["to"] == "SOCK-1", r
ev = r["evidence"]
assert ev["udp_bind"] == "EADDRNOTAVAIL" and ev["udp_sockets"] == 16000, ev
assert ev["top_holders"] == [{"process": "Chatty App", "pid": 4242, "sockets": 15000}], ev
assert ev["tcp_dns_ok"] is True, ev
PY
  # Any other rule's line carries no evidence key.
  local other="$BATS_TEST_TMPDIR/other.jsonl"
  run emit NETDIAG_MON_JOURNAL="$other" NETDIAG_MON_HAVE_PREV=1 \
           NETDIAG_MON_RULES='D1 ' NETDIAG_MON_PREV_RULES=''
  python3 - "$other" <<'PY'
import json, sys
r = [json.loads(l) for l in open(sys.argv[1]) if l.strip()][0]
assert r["to"] == "D1" and "evidence" not in r, r
PY
}

@test "parity: an active VPN is VPN-1 on both" {
  reset_state; MON_VPN_ACTIVE=1 VPN_ACTIVE=1
  local m; m="$(monitor_rules)"; reset_state; MON_VPN_ACTIVE=1 VPN_ACTIVE=1
  [ "$m" = "$(scanner_rules)" ]
  [[ "$m" == *"VPN-1"* ]] || return 1
}

@test "parity: gateway loss with weak WiFi names G1 on both, not G2" {
  reset_state; MON_GW_LOSS=25 GW_LOSS=25 MON_WIFI_RSSI=-85 WIFI_RSSI=-85
  local m; m="$(monitor_rules)"; reset_state
  MON_GW_LOSS=25 GW_LOSS=25 MON_WIFI_RSSI=-85 WIFI_RSSI=-85
  [ "$m" = "$(scanner_rules)" ]
  [[ "$m" == *"G1"* ]] || return 1
  [[ "$m" != *"G2"* ]] || return 1
}

# The branch this file claimed to cover and did not: a strong Wi-Fi signal
# over critical gateway loss. lib/diagnosis.sh used to answer it with W5
# (warn) and suppress G2, while the monitor said G2 (critical) — a red dot
# over an amber report, and an alert waiting for a G-rule sentence that
# never came. A cause hypothesis must not lower severity, so both engines
# now say G2 critical, and this test holds them to it.
@test "parity: gateway loss with a strong Wi-Fi signal is G2 critical on both, not W5" {
  # Loss >= THRESH_ICMP_FILTERED_LOSS_PCT with a working TCP path is TCP-1
  # (a filtering gateway), not a fault, so TCP is down here — the same
  # setup the "TCP also failing still names G2" test uses.
  reset_state; MON_GW_LOSS=68 GW_LOSS=68 MON_WIFI_RSSI=-37 WIFI_RSSI=-37
  MON_TCP_OK=0 TCP_REACH_ANY_OK=0
  local m; m="$(monitor_rules)"
  [ "$m" = "G2 " ] || { echo "monitor rules: [$m]"; return 1; }
  reset_state; MON_GW_LOSS=68 GW_LOSS=68 MON_WIFI_RSSI=-37 WIFI_RSSI=-37
  MON_TCP_OK=0 TCP_REACH_ANY_OK=0
  _mon_rules
  [ "$MON_SEVERITY" = "critical" ]
  # Scanner, in this shell so its severities stay readable. Asserted on the
  # full rule list, not just the monitor vocabulary, so a W5 (or any other
  # lower-severity stand-in for G2) cannot hide behind the filter.
  . "$REPO/lib/diagnosis.sh"
  diagnosis_run >/dev/null
  local i g2_sev="" rules=" ${DIAG_RULE[*]} "
  for i in "${!DIAG_RULE[@]}"; do
    [ "${DIAG_RULE[$i]}" = "G2" ] && g2_sev="${DIAG_SEV[$i]}"
  done
  [ "$g2_sev" = "critical" ] || { echo "scanner G2 severity: [$g2_sev]; rules:$rules"; return 1; }
  case "$rules" in (*" W5 "*) echo "W5 fired: $rules"; return 1 ;; esac
  [ "$MAX_SEVERITY" -ge 2 ]
}

@test "parity: severe internet loss over a clean router is L1 on both" {
  reset_state; MON_INET_LOSS=25 MON_INET_LOSS_ALT=25 INET_LOSS=25 INET_LOSS_ALT=25
  local m; m="$(monitor_rules)"; reset_state
  MON_INET_LOSS=25 MON_INET_LOSS_ALT=25 INET_LOSS=25 INET_LOSS_ALT=25
  [ "$m" = "$(scanner_rules)" ]
  [[ "$m" == *"L1"* ]] || return 1
}

@test "monitor does not make L1 critical from one lossy internet target" {
  reset_state; MON_INET_LOSS=25 MON_INET_LOSS_ALT=0
  _mon_rules
  _mon_rules
  [[ "$(monitor_rules)" == *"L2"* ]] || return 1
  [[ "$(monitor_rules)" != *"L1"* ]] || return 1
}

@test "parity: moderate internet loss is L2 on both" {
  # L2 is confirmed across cycles the same way G3 is above — see that
  # test's comment.
  reset_state; MON_INET_LOSS=15 INET_LOSS=15 INET_LOSS_ALT=15
  _mon_rules
  local m; m="$(monitor_rules)"; reset_state
  MON_INET_LOSS=15 INET_LOSS=15 INET_LOSS_ALT=15
  [ "$m" = "$(scanner_rules)" ]
  [[ "$m" == *"L2"* ]] || return 1
}

@test "parity: total ping loss on a working link is ICMP-1 on both, not L1" {
  reset_state; MON_INET_LOSS=100 MON_INET_LOSS_ALT=100 INET_LOSS=100 INET_LOSS_ALT=100
  local m; m="$(monitor_rules)"; reset_state
  MON_INET_LOSS=100 MON_INET_LOSS_ALT=100 INET_LOSS=100 INET_LOSS_ALT=100
  [ "$m" = "$(scanner_rules)" ]
  [[ "$m" == *"ICMP-1"* ]] || return 1
  [[ "$m" != *"L1"* ]] || return 1
}

@test "parity: no default route is N1 on both" {
  # LINK_UP is deliberately left at its zero default: this is the
  # "nothing joined" case. The joined-but-routeless case is N1c, which is
  # scan-only — the monitor has no lib/linkstate.sh view — and so is
  # outside MONITOR_VOCABULARY by design.
  reset_state; MON_LINK_UP=0 GATEWAY=""
  local m; m="$(monitor_rules)"; reset_state; MON_LINK_UP=0 GATEWAY=""
  [ "$m" = "$(scanner_rules)" ]
  [ "$m" = "N1 " ]
}

@test "the monitor claims no rule the scanner cannot also produce" {
  # Guards against the stream inventing a verdict. Every rule id the
  # monitor can emit must exist in lib/diagnosis.sh.
  local rule
  for rule in $(grep -oE '_mon_add_rule (critical|warn|info) [A-Za-z0-9-]+' "$REPO/lib/monitor.sh" \
                | awk '{print $3}' | sort -u); do
    # No exclusions. CP-1 used to be one — it was emitted by the monitor
    # and by nothing else, on the theory that a scan didn't need it. It
    # did: without a scan call site a portal never reached status.rules[],
    # the GUI, or the exit code, and P1's "call your ISP" spoke for it.
    grep -qE "add_diag [a-z]+ ${rule} " "$REPO/lib/diagnosis.sh" \
      || { echo "monitor emits '$rule', which lib/diagnosis.sh never does"; return 1; }
  done
}

@test "no rule in lib/monitor.sh carries an inline numeric cutoff" {
  run grep -nE '(loss_at_least|loss_below) "\$[A-Z_]+" [0-9]+|-lt -?[1-9][0-9]* \]|-ge -?[1-9][0-9]* \]|-gt -?[1-9][0-9]* \]' \
    "$REPO/lib/monitor.sh"
  [ "$status" -ne 0 ] || { echo "inline cutoff in monitor.sh:"; echo "$output"; return 1; }
}

@test "SIGALRM requests a refresh without stopping the monitor" {
  MON_STOP=0 MON_REFRESH_REQUESTED=0
  _mon_on_refresh
  [ "$MON_REFRESH_REQUESTED" -eq 1 ]
  [ "$MON_STOP" -eq 0 ]
}

@test "monitor installs a harmless SIGALRM refresh trap" {
  run grep -n 'trap _mon_on_refresh ALRM' "$REPO/lib/monitor.sh"
  [ "$status" -eq 0 ]
}

@test "registered parent temp directories are cleaned up" {
  netdiag_mktemp_dir test-registry
  local d="$NETDIAG_TMP_DIR"
  [ -d "$d" ]
  [[ "$_NETDIAG_TMP_DIRS" == *"$d"* ]] || return 1
  netdiag_tmp_forget "$d"
  [ -z "$_NETDIAG_TMP_DIRS" ]
  rm -rf "$d"
  _netdiag_tmp_cleanup
  [ ! -e "$d" ]
  [ -z "$_NETDIAG_TMP_DIRS" ]
}

# ── Freshness on internet-side loss ──────────────────────────────────────
# The fast tier pings the internet every cycle; TCP and public probes run
# on the slower tiers and are carried over stale. A real outage (gateway
# quiet, internet ping at critical loss) used to read as ICMP-1 (info) for
# up to a minute -- green dot, no alert -- until the medium/slow timers
# refreshed. monitor_run now forces a fresh TCP + public probe the moment
# that condition holds, so _mon_rules decides L1 vs ICMP-1 on fresh data.
# This block guards the structural fix: the condition exists, it keys on
# the shared threshold variables (not inline numbers), and it gates the
# forced re-probe on the tier not having already run this cycle.
@test "monitor_run forces a fresh TCP/public probe on internet-side critical loss" {
  run grep -cE 'loss_at_least "\$MON_INET_LOSS" "\$LOSS_CRIT_PCT"' "$REPO/lib/monitor.sh"
  [ "$output" -ge 1 ]
  run grep -cE 'loss_below "\$MON_GW_LOSS" "\$LOSS_WARN_PCT"' "$REPO/lib/monitor.sh"
  [ "$output" -ge 1 ]
  run grep -cE 'grep -qw medium' "$REPO/lib/monitor.sh"
  [ "$output" -ge 1 ]
  run grep -cE 'grep -qw slow' "$REPO/lib/monitor.sh"
  [ "$output" -ge 1 ]
}

# ── Severity and cadence ─────────────────────────────────────────────────

@test "severity is the worst rule that fired" {
  reset_state; MON_GW_LOSS=25 MON_VPN_ACTIVE=1
  _mon_rules
  [ "$MON_SEVERITY" = "critical" ]
}

@test "an info-only rule does not escalate severity or halve the cadence" {
  # A VPN notice is not a reason to probe twice as often for the rest of
  # the session.
  reset_state; MON_VPN_ACTIVE=1
  _mon_rules
  [ "$MON_SEVERITY" = "info" ]
  [ "$MON_DEGRADED" -eq 0 ]
}

@test "a fault switches the monitor to its degraded cadence" {
  # G3 needs two cycles to confirm now (see the loss-confirmation block
  # below); drive it there rather than asserting degraded cadence off an
  # unconfirmed first cycle.
  reset_state; MON_GW_LOSS=15
  _mon_rules
  _mon_rules
  [ "$MON_DEGRADED" -eq 1 ]
}

# ── Loss confirmation: a blip is not a condition ─────────────────────────
# THRESH_MON_LOSS_CONFIRM_CYCLES (lib/thresholds.sh) exists because at
# MONITOR_PING_COUNT=10, one dropped packet reads as exactly 10% —
# LOSS_WARN_PCT — so a single unlucky packet used to read as G3. Only the
# warn-band rules (G3, L2) are confirmed; critical loss (G1/G2/L1) still
# fires on the first cycle, because a real outage must not wait.

@test "loss confirmation: one cycle of warn-band gateway loss produces no G3" {
  reset_state; MON_GW_LOSS=10
  _mon_rules
  [[ "$MON_RULES" != *"G3"* ]] || return 1
}

@test "loss confirmation: two consecutive cycles of warn-band gateway loss produce G3" {
  reset_state; MON_GW_LOSS=10
  _mon_rules
  _mon_rules
  [[ "$MON_RULES" == *"G3"* ]] || return 1
}

@test "loss confirmation: one cycle of critical gateway loss fires G2 immediately" {
  reset_state; MON_GW_LOSS=25
  _mon_rules
  [[ "$MON_RULES" == *"G2"* ]] || return 1
}

@test "loss confirmation: a clean cycle between two blips resets the streak" {
  reset_state; MON_GW_LOSS=10
  _mon_rules
  MON_GW_LOSS=0
  _mon_rules
  MON_GW_LOSS=10
  _mon_rules
  [[ "$MON_RULES" != *"G3"* ]] || return 1
}

# ── Internet-probe loss quantum ───────────────────────────────────────────
# The regression behind the flashing red card: _mon_probe_internet sent
# five packets, so one dropped packet read as exactly LOSS_CRIT_PCT and L1
# — which never waits for confirmation — fired on routine resolver noise,
# then cleared on the next cycle. Two fixes, both guarded here: the probe
# sends MONITOR_INET_PING_COUNT packets from thresholds.sh, and the
# reported figure accumulates over a rolling window of
# MONITOR_LOSS_WINDOW_PROBES probes (_mon_loss_fold), so the percentage's
# denominator is ~100 packets. The property to hold forever: one dropped
# packet cannot reach any loss threshold, and the smallest nonzero reading
# is a single point of the window.

@test "the internet probe's packet count comes from thresholds.sh" {
  run grep -cE 'ping -q -c "\$MONITOR_INET_PING_COUNT"' "$REPO/lib/monitor.sh"
  [ "$output" -ge 1 ]
  run grep -cE 'MONITOR_INET_PING_COUNT=' "$REPO/lib/thresholds.sh"
  [ "$output" -eq 1 ]
  # And no inline burst size snuck back in: the only -c on this probe is
  # the variable.
  run grep -cE 'ping .*-c [0-9]' "$REPO/lib/monitor.sh"
  [ "$output" -eq 0 ]
}

@test "the loss window size comes from thresholds.sh" {
  run grep -cE '_mon_loss_summarize|_mon_loss_fold' "$REPO/lib/monitor.sh"
  [ "$output" -ge 2 ]
  run grep -cE 'MONITOR_LOSS_WINDOW_PROBES=' "$REPO/lib/thresholds.sh"
  [ "$output" -eq 1 ]
}

@test "one dropped packet cannot reach critical loss on the monitor" {
  local quantum=$((100 / (MONITOR_LOSS_WINDOW_PROBES * MONITOR_INET_PING_COUNT)))
  [ "$quantum" -lt "$LOSS_WARN_PCT" ]
  [ "$quantum" -lt "$LOSS_CRIT_PCT" ]
  [ "$quantum" -lt "$THRESH_GW_LOSS_CRIT_PCT" ]
}

@test "the window trims to its cap and sums counts, not ratios" {
  local summary
  # Twelve probes' worth: only the newest ten may survive. Deliberately
  # unequal counts so a ratio-averaging implementation fails this while an
  # integer accumulation passes.
  summary="$(_mon_loss_summarize "10:10 10:10 20:0 20:0 20:0 20:5 20:0 20:1 20:0 20:0 20:0 20:0")"
  [ "${summary%%|*}" = "20:0 20:0 20:0 20:5 20:0 20:1 20:0 20:0 20:0 20:0" ]
  local totals="${summary#*|}"
  [ "${totals%%|*}" = "200" ]
  [ "${totals##*|}" = "6" ]
}

@test "a full clean window reads zero, one drop reads one point" {
  local hist="" summary i
  for i in 1 2 3 4; do
    summary="$(_mon_loss_fold "$hist" "$(ping_summary 20 20)" "$MONITOR_INET_PING_COUNT")"
    hist="${summary%%|*}"
  done
  summary="$(_mon_loss_fold "$hist" "$(ping_summary 20 20)" "$MONITOR_INET_PING_COUNT")"
  [ "${summary##*|}" = "0" ]
  summary="$(_mon_loss_fold "${summary%%|*}" "$(ping_summary 20 19)" "$MONITOR_INET_PING_COUNT")"
  [ "${summary##*|}" = "1" ]
}

@test "an unparseable probe clears the window instead of freezing it" {
  local summary
  summary="$(_mon_loss_fold "20:0 20:0 20:1" "" "$MONITOR_INET_PING_COUNT")"
  [ "${summary%%|*}" = "" ]
  [ "${summary#*|}" = "" ]
}

@test "a truncated probe (fewer packets than asked) clears the window" {
  # ping killed mid-run by with_timeout reports what it managed; counting
  # that as a normal sample would dilute real loss with missing packets.
  local summary
  summary="$(_mon_loss_fold "20:0 20:0" "$(ping_summary 7 7)" "$MONITOR_INET_PING_COUNT")"
  [ "${summary%%|*}" = "" ]
}

# A macOS `ping -q` summary with the given transmitted/received counts —
# the only part of ping's output the fold reads.
ping_summary() {
  printf '%s packets transmitted, %s packets received, 0.0%% packet loss\n' "$1" "$2"
}

@test "a dead link is degraded and reports nothing it did not measure" {
  reset_state; MON_LINK_UP=0
  _mon_rules
  [ "$MON_DEGRADED" -eq 1 ]
  [ "$MON_RULES" = "N1 " ]
}

# ── Unmeasured is not zero ───────────────────────────────────────────────

@test "an unmeasured public reach does not read as an outage" {
  # The slow tier has not run yet on the first sample. Treating its empty
  # value as false would announce "your ISP is down" one second after
  # launch, on a working connection.
  reset_state; MON_PUBLIC_OK="" MON_DNS_OK=""
  _mon_rules
  [[ "$MON_RULES" != *"P1"* ]] || return 1
  [[ "$MON_RULES" != *"P2"* ]] || return 1
  [[ "$MON_RULES" != *"D1"* ]] || return 1
}

@test "a fast HTTPS failure is reported even when the slow public probe is stale" {
  # The old monitor could carry a five-minute-old public success while the
  # user's web traffic had already stopped. The fast canary is authoritative
  # once it has produced a result.
  reset_state; MON_WEB_OK=0 MON_PUBLIC_OK=1 MON_TCP_OK=0
  _mon_rules
  [[ "$MON_RULES" == *"P2"* ]] || return 1
  [ "$MON_MEASUREMENT_STATE" = "measured" ]
}

@test "a current HTTPS success replaces a stale public failure" {
  reset_state; MON_WEB_OK=1 MON_PUBLIC_OK=0
  _mon_rules
  [[ "$MON_RULES" != *"P1"* ]] || return 1
  [[ "$MON_RULES" != *"P2"* ]] || return 1
  [ "$MON_MEASUREMENT_STATE" = "measured" ]
}

@test "missing fast readings are marked unknown, not healthy" {
  reset_state; MON_GW_LOSS="" MON_INET_LOSS="" MON_WEB_OK=""
  MON_GW_RTT="" MON_INET_RTT=""
  _mon_rules
  [ "$MON_MEASUREMENT_STATE" = "unknown" ]
}

@test "a measured 100% loss counts as measured, not as missing data" {
  # The state that produced the report: every probe failed, so nothing was
  # measured, so no rule fired, so severity read "ok". Once the probe can
  # actually report total loss it is evidence — and evidence that fires G2.
  reset_state; MON_GW_LOSS=100 MON_GW_RTT="" MON_TCP_OK=0
  _mon_rules
  [ "$MON_MEASUREMENT_STATE" = "measured" ]
  [[ "$MON_RULES" == *"G2"* ]] || return 1
}

@test "curl's 000 is not evidence that anything answered" {
  # curl -w '%{http_code}' prints 000 when the connection never completed.
  # Reading that as "a canary answered, just not with 204" turned a dead
  # link into a captive-portal verdict AND satisfied the measured gate, so
  # the app's own "checking" card could never appear on a real outage.
  reset_state; MON_GW_LOSS="" MON_INET_LOSS="" MON_GW_RTT="" MON_INET_RTT=""
  MON_WEB_OK="$(_mon_web_verdict 000 000)"
  [ -z "$MON_WEB_OK" ]
  _mon_rules
  [ "$MON_MEASUREMENT_STATE" = "unknown" ]
}

@test "a real HTTP response that is not 204 is still a captive-portal signal" {
  # The branch 000 was wrongly sharing. A redirect or a login page is a
  # genuine answer and must keep reading as "reachable, but intercepted".
  [ "$(_mon_web_verdict 302 000)" = "0" ]
  [ "$(_mon_web_verdict 204 000)" = "1" ]
  [ "$(_mon_web_verdict 000 204)" = "1" ]
  [ -z "$(_mon_web_verdict '' '')" ]
}

@test "an unmeasured gateway loss does not fire a loss rule" {
  reset_state; MON_GW_LOSS=""
  _mon_rules
  [[ "$MON_RULES" != *"G1"* ]] || return 1
  [[ "$MON_RULES" != *"G2"* ]] || return 1
  [[ "$MON_RULES" != *"G3"* ]] || return 1
}

@test "an unmeasured RSSI does not fire W1" {
  reset_state; MON_WIFI_RSSI=""
  _mon_rules
  [[ "$MON_RULES" != *"W1"* ]] || return 1
}

# ── Sample shape ─────────────────────────────────────────────────────────

emit() {
  env -i PATH="$PATH" "$@" python3 "$HELPERS/monitor_sample.py"
}

@test "monitor_sample: an empty environment still emits one valid object" {
  run emit
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c 'import json,sys; json.load(sys.stdin)'
}

@test "monitor_sample: emits exactly one line" {
  run emit NETDIAG_MON_SEQ=1
  [ "${#lines[@]}" -eq 1 ]
}

@test "monitor_sample: every documented top-level key is present" {
  run emit
  printf '%s' "$output" | python3 -c "
import json,sys
d = json.load(sys.stdin)
for k in ('schema','version','ts','seq','refreshed','link','network','vpn',
          'gateway','wifi','dns','tcp','public','status'):
    assert k in d, k
"
}

# network.group_id is the canonical --history group key — the id the app
# joins its charts and renames against. A sample that carried only the raw
# record-format id (wifi:mac=AA:BB) forced every consumer to re-derive
# grouping rules it does not own; group_id arrives already derived by the
# same netid_run precedence history.py uses. Null when the network has no
# identity at all — same contract as network.id.
@test "monitor_sample: network.group_id mirrors the history group key" {
  run emit NETDIAG_MON_GW_MAC=AA:BB:CC:DD:EE:FF NETDIAG_MON_NETWORK_ID="wifi:mac=AA:BB:CC:DD:EE:FF" \
           NETDIAG_MON_NETWORK_GROUP="mac:aa:bb:cc:dd:ee:ff"
  printf '%s' "$output" | python3 -c "
import json,sys
d = json.load(sys.stdin)
assert d['network']['group_id'] == 'mac:aa:bb:cc:dd:ee:ff', d['network']
"
  run emit
  printf '%s' "$output" | python3 -c "
import json,sys
d = json.load(sys.stdin)
assert d['network']['group_id'] is None, d['network']
"
}

@test "monitor_sample: an unmeasured probe is null, never false" {
  # dns.ok unset must be null. False would mean "we asked and it failed".
  run emit NETDIAG_MON_LINK_UP=1
  printf '%s' "$output" | python3 -c "
import json,sys
d = json.load(sys.stdin)
assert d['dns']['ok'] is None, d['dns']
assert d['public']['ok'] is None, d['public']
assert d['tcp']['any_ok'] is None, d['tcp']
assert d['public']['captive_portal'] is None
"
}

@test "monitor_sample: a measured negative is false, not null" {
  run emit NETDIAG_MON_DNS_OK=0 NETDIAG_MON_PUBLIC_OK=0 NETDIAG_MON_CAPTIVE=0
  printf '%s' "$output" | python3 -c "
import json,sys
d = json.load(sys.stdin)
assert d['dns']['ok'] is False
assert d['public']['ok'] is False
assert d['public']['captive_portal'] is False
"
}

@test "monitor_sample: wifi is null on a wired link rather than an object of nulls" {
  run emit NETDIAG_MON_IFACE_TYPE=wired
  printf '%s' "$output" | python3 -c 'import json,sys; assert json.load(sys.stdin)["wifi"] is None'
}

@test "monitor_sample: an SSID containing quotes and backslashes round-trips" {
  # The reason this goes through python instead of printf. A stream the app
  # parses forever will eventually meet one of these.
  run emit NETDIAG_MON_IFACE_TYPE=wifi 'NETDIAG_MON_SSID=say "hi"\back'
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json,sys
assert json.load(sys.stdin)['link']['ssid'] == 'say \"hi\"\\\\back'
"
}

@test "monitor_sample: rules and severity ride through to status" {
  run emit NETDIAG_MON_RULES='G2 TCP-1 ' NETDIAG_MON_SEVERITY=critical \
           NETDIAG_MON_ICMP_FILTERED=1 NETDIAG_MON_DEGRADED=1 NETDIAG_MON_CADENCE_S=5
  printf '%s' "$output" | python3 -c "
import json,sys
s = json.load(sys.stdin)['status']
assert s['rules'] == ['G2','TCP-1'], s
assert s['severity'] == 'critical'
assert s['icmp_filtered'] is True
assert s['degraded'] is True
assert s['cadence_s'] == 5
"
}

@test "monitor_sample: measurement availability rides through to status" {
  run emit NETDIAG_MON_MEASUREMENT_STATE=unknown
  printf '%s' "$output" | python3 -c '
import json,sys
assert json.load(sys.stdin)["status"]["measurement"] == "unknown"
'
}

@test "monitor_sample: TCP targets parse into structured entries" {
  run emit 'NETDIAG_MON_TCP_LINES=1.1.1.1|443|1|30
8.8.8.8|443|0|'
  printf '%s' "$output" | python3 -c "
import json,sys
t = json.load(sys.stdin)['tcp']['targets']
assert t == [{'host':'1.1.1.1','port':443,'ok':True,'elapsed_ms':30.0},
             {'host':'8.8.8.8','port':443,'ok':False,'elapsed_ms':None}], t
"
}

@test "monitor_sample: refreshed lists the tiers that actually ran" {
  run emit 'NETDIAG_MON_REFRESHED=fast medium '
  printf '%s' "$output" | python3 -c "
import json,sys
assert json.load(sys.stdin)['refreshed'] == ['fast','medium']
"
}

# ── monitor_sample: changes (schema 2) ──────────────────────────────────

@test "monitor_sample: no previous sample, no changes key" {
  run emit NETDIAG_MON_HAVE_PREV=0 \
           NETDIAG_MON_PUB_IP=203.0.113.42 NETDIAG_MON_PREV_PUB_IP=198.51.100.7
  printf '%s' "$output" | python3 -c "
import json,sys
assert 'changes' not in json.load(sys.stdin)
"
}

@test "monitor_sample: identical samples emit no changes key" {
  run emit NETDIAG_MON_HAVE_PREV=1 \
           NETDIAG_MON_PUB_IP=203.0.113.42 NETDIAG_MON_PREV_PUB_IP=203.0.113.42 \
           NETDIAG_MON_RULES='G2 ' NETDIAG_MON_PREV_RULES='G2 '
  printf '%s' "$output" | python3 -c "
import json,sys
assert 'changes' not in json.load(sys.stdin)
"
}

@test "monitor_sample: public IP change is phrased by the CLI" {
  run emit NETDIAG_MON_HAVE_PREV=1 \
           NETDIAG_MON_PUB_IP=203.0.113.42 NETDIAG_MON_PREV_PUB_IP=198.51.100.7
  printf '%s' "$output" | python3 -c "
import json,sys
ch = json.load(sys.stdin)['changes']
assert len(ch) == 1, ch
assert ch[0]['id'] == 'public-ip-changed'
assert ch[0]['field'] == 'public.ip'
assert ch[0]['from'] == '198.51.100.7' and ch[0]['to'] == '203.0.113.42'
assert ch[0]['summary'] == 'Public IP changed'
"
}

@test "monitor_sample: unmeasured side suppresses the change" {
  # null means "not measured", not a value — first slow-tier result is
  # not a change (stream convention, docs/JSON-SCHEMA.md).
  run emit NETDIAG_MON_HAVE_PREV=1 \
           NETDIAG_MON_PUB_IP=203.0.113.42 NETDIAG_MON_PREV_PUB_IP=
  printf '%s' "$output" | python3 -c "
import json,sys
assert 'changes' not in json.load(sys.stdin)
"
}

@test "monitor_sample: country move phrased as VPN exit when VPN is up" {
  run emit NETDIAG_MON_HAVE_PREV=1 NETDIAG_MON_VPN_ACTIVE=1 \
           NETDIAG_MON_PREV_VPN_ACTIVE=1 \
           NETDIAG_MON_PUB_CC=Brazil NETDIAG_MON_PREV_PUB_CC=Germany
  printf '%s' "$output" | python3 -c "
import json,sys
ch = json.load(sys.stdin)['changes']
assert ch[0]['id'] == 'country-changed'
assert ch[0]['summary'] == 'VPN exit moved: Germany → Brazil'
"
}

@test "monitor_sample: vpn drop and reconnect phrase both directions" {
  run emit NETDIAG_MON_HAVE_PREV=1 \
           NETDIAG_MON_VPN_ACTIVE=0 NETDIAG_MON_PREV_VPN_ACTIVE=1 \
           NETDIAG_MON_PREV_VPN_NAME=Mullvad
  printf '%s' "$output" | python3 -c "
import json,sys
ch = json.load(sys.stdin)['changes']
assert len(ch) == 1, ch
assert ch[0]['id'] == 'vpn-disconnected'
assert ch[0]['summary'] == 'VPN disconnected (Mullvad)'
"
  run emit NETDIAG_MON_HAVE_PREV=1 \
           NETDIAG_MON_VPN_ACTIVE=1 NETDIAG_MON_PREV_VPN_ACTIVE=0 \
           NETDIAG_MON_VPN_NAME=Mullvad
  printf '%s' "$output" | python3 -c "
import json,sys
ch = json.load(sys.stdin)['changes']
assert len(ch) == 1, ch
assert ch[0]['id'] == 'vpn-connected'
assert ch[0]['summary'] == 'VPN connected (Mullvad)'
"
}

@test "monitor_sample: ssid with a double quote survives the changes array" {
  run emit NETDIAG_MON_HAVE_PREV=1 \
           NETDIAG_MON_SSID='Cafe "Sunset" 5G' NETDIAG_MON_PREV_SSID=HomeNet
  printf '%s' "$output" | python3 -c "
import json,sys
ch = json.load(sys.stdin)['changes']
assert ch[0]['id'] == 'wifi-network-changed'
assert ch[0]['to'] == 'Cafe \"Sunset\" 5G'
"
}

@test "monitor_sample: rule transitions emit fired and cleared entries" {
  run emit NETDIAG_MON_HAVE_PREV=1 \
           NETDIAG_MON_MEASUREMENT_STATE=measured \
           NETDIAG_MON_RULES='G2 TCP-1 ' NETDIAG_MON_PREV_RULES='VPN-1 TCP-1 '
  printf '%s' "$output" | python3 -c "
import json,sys
ch = json.load(sys.stdin)['changes']
ids = [(c['id'], c.get('from'), c.get('to')) for c in ch]
assert ('rule-fired', None, 'G2') in ids, ids
assert ('rule-cleared', 'VPN-1', None) in ids, ids
assert len(ch) == 2, ch
# Summaries speak the rules catalog's plain-English titles, not the bare
# rule ID — 'Issue G2 detected' would tell a non-technical user nothing.
by_id = {c['id']: c for c in ch}
assert by_id['rule-fired']['summary'] == 'Router dropping packets', ch
assert by_id['rule-cleared']['summary'] == 'Resolved: VPN carrying your traffic', ch
"
}

@test "monitor_sample: unknown measurement does not claim an L1 recovery" {
  run emit NETDIAG_MON_HAVE_PREV=1 \
           NETDIAG_MON_MEASUREMENT_STATE=unknown \
           NETDIAG_MON_RULES='' NETDIAG_MON_PREV_RULES='L1 '
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c '
import json,sys
sample = json.load(sys.stdin)
assert sample["status"]["measurement"] == "unknown"
assert not any(change["id"] == "rule-cleared" for change in sample.get("changes", []))
'
}

@test "monitor_sample: gateway measurement cannot clear unmeasured internet fault" {
  run emit NETDIAG_MON_HAVE_PREV=1 \
           NETDIAG_MON_MEASUREMENT_STATE=measured \
           NETDIAG_MON_CLEARABLE_RULES='N1 VPN-1 G1 G2 G3 TCP-1 ' \
           NETDIAG_MON_RULES='' NETDIAG_MON_PREV_RULES='L1 '
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c '
import json,sys
sample = json.load(sys.stdin)
assert not any(change["id"] == "rule-cleared" for change in sample.get("changes", []))
'
}

@test "_mon_snapshot_prev retains internet fault when only gateway was measured" {
  reset_state
  MON_PREV_RULES="L1 "
  MON_GW_LOSS=0 MON_INET_LOSS="" MON_INET_LOSS_ALT="" MON_WEB_OK=""
  _mon_rules
  [ "$MON_MEASUREMENT_STATE" = "unknown" ]
  [[ " $MON_CLEARABLE_RULES " != *" L1 "* ]]
  _mon_snapshot_prev
  [ "$MON_PREV_RULES" = "L1 " ]
  MON_INET_LOSS=0 MON_INET_LOSS_ALT=0
  _mon_rules
  _mon_snapshot_prev
  [ "$MON_PREV_RULES" = "" ]
}

@test "partial measurement presents an unresolved internet fault as unverified" {
  reset_state
  MON_PREV_RULES="L1 "
  MON_GW_LOSS=0 MON_INET_LOSS="" MON_INET_LOSS_ALT="" MON_WEB_OK=""
  _mon_rules
  [[ " $MON_RULES " == *" L1 "* ]]
  [ "$MON_MEASUREMENT_STATE" = "unknown" ]
  [ "$MON_SEVERITY" = "critical" ]
}

@test "unverified critical fault does not masquerade as fresh critical over D1" {
  reset_state
  MON_PREV_RULES="L1 "
  MON_GW_LOSS=0 MON_INET_LOSS="" MON_INET_LOSS_ALT=""
  MON_WEB_OK=1 MON_PUBLIC_OK=1 MON_TCP_OK=0 MON_DNS_OK=0
  # D1 waits for THRESH_MON_CONN_CONFIRM_CYCLES failed lookups in a row.
  MON_DNS_STREAK="$THRESH_MON_CONN_CONFIRM_CYCLES"
  _mon_rules
  [[ " $MON_RULES " == *" D1 "* && " $MON_RULES " == *" L1 "* ]]
  [ "$MON_SEVERITY" = "critical" ]
  [ "$MON_MEASUREMENT_STATE" = "unknown" ]
}

@test "an unmeasured prerequisite cannot clear L1 or P2" {
  reset_state
  MON_PREV_RULES="L1 " MON_GW_LOSS="" MON_INET_LOSS=40 MON_INET_LOSS_ALT=40
  _mon_rules
  [[ " $MON_CLEARABLE_RULES " != *" L1 "* ]]
  reset_state
  MON_PREV_RULES="P2 " MON_GW_LOSS="" MON_WEB_OK=0 MON_TCP_OK=0 MON_PUBLIC_OK=0
  _mon_rules
  [[ " $MON_CLEARABLE_RULES " != *" P2 "* ]]
}

@test "confirmation streak reset does not clear persistent G3" {
  reset_state
  MON_PREV_RULES="G3 " MON_GW_LOSS=15 MON_GW_LOSS_STREAK=0
  _mon_rules
  [[ " $MON_RULES " == *" G3 "* ]]
  [[ " $MON_CLEARABLE_RULES " != *" G3 "* ]]
}

@test "unknown captive classification cannot clear CP-1" {
  reset_state
  MON_PREV_RULES="CP-1 " MON_CAPTIVE="" MON_INET_LOSS=0 MON_INET_LOSS_ALT=0
  _mon_rules
  [[ " $MON_CLEARABLE_RULES " != *" CP-1 "* ]]
  [[ " $MON_RULES " == *" CP-1 "* ]]
}

@test "unavailable browser check cannot clear BR-1" {
  reset_state
  MON_PREV_RULES="BR-1 " MON_REFRESHED="fast medium "
  MON_BROWSER_DESYNC_COUNT=0 MON_BROWSER_CHECKED=0
  _mon_rules
  [[ " $MON_RULES " == *" BR-1 "* ]]
  [[ " $MON_CLEARABLE_RULES " != *" BR-1 "* ]]
  MON_BROWSER_CHECKED=1
  _mon_rules
  [[ " $MON_CLEARABLE_RULES " == *" BR-1 "* ]]
  [[ " $MON_RULES " != *" BR-1 "* ]]
}

@test "monitor_sample: journal records recovery only after measured traffic" {
  local journal="$BATS_TEST_TMPDIR/recovery.jsonl"
  run emit NETDIAG_MON_JOURNAL="$journal" NETDIAG_MON_HAVE_PREV=1 \
           NETDIAG_MON_MEASUREMENT_STATE=unknown \
           NETDIAG_MON_RULES='' NETDIAG_MON_PREV_RULES='L1 '
  [ "$status" -eq 0 ]
  [ ! -e "$journal" ]

  run emit NETDIAG_MON_JOURNAL="$journal" NETDIAG_MON_HAVE_PREV=1 \
           NETDIAG_MON_MEASUREMENT_STATE=measured \
           NETDIAG_MON_RULES='' NETDIAG_MON_PREV_RULES='L1 '
  [ "$status" -eq 0 ]
  python3 - "$journal" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    events = [json.loads(line) for line in stream]
assert len(events) == 1, events
assert events[0]["kind"] == "rule-cleared", events
assert events[0]["from"] == "L1", events
PY
}

# ── What the journal says at monitor start ──────────────────────────────
#
# A fresh monitor's first sample has no previous sample to diff against, so
# `changes` is empty and a rule already firing in it was never journaled.
# After a restart during a steady fault the journal then went silent for as
# long as the fault lasted, and helpers/events.py could only end the episode
# at the restart. The first sample's rules are now written down, marked
# `already_firing`, so the reader can join them to the episode the previous
# process had open. The stream is a different matter: its first-sample
# `changes` stays empty, because the app already knows about a fault it was
# showing before it restarted the monitor, and must not alert on it again.

# The journal's lines as one JSON list on stdout, for assertions in python.
journal_lines() {
  python3 -c "
import json, sys
print(json.dumps([json.loads(l) for l in open(sys.argv[1]) if l.strip()]))
" "$1"
}

@test "monitor_sample: rules firing in the first sample are journaled as already firing" {
  local journal="$BATS_TEST_TMPDIR/start.jsonl"
  run emit NETDIAG_MON_JOURNAL="$journal" NETDIAG_MON_SEQ=1 \
           NETDIAG_MON_HAVE_PREV=0 NETDIAG_MON_TS=2026-10-06T20:35:51Z \
           NETDIAG_MON_NETWORK_ID=wifi:mac=00:11:22:33:44:55 \
           NETDIAG_MON_RULES='G2 TCP-1 '
  [ "$status" -eq 0 ]
  run journal_lines "$journal"
  printf '%s' "$output" | python3 -c "
import json, sys
rows = json.load(sys.stdin)
assert [r['kind'] for r in rows] == ['monitor-started', 'rule-fired',
                                     'rule-fired'], rows
fired = rows[1:]
assert [r['to'] for r in fired] == ['G2', 'TCP-1'], fired
for r in fired:
    assert r['already_firing'] is True, r
    assert r['from'] is None, r
    assert r['field'] == 'status.rules', r
    assert r['network'] == 'wifi:mac=00:11:22:33:44:55', r
    assert r['t'] == '2026-10-06T20:35:51Z' and r['seq'] == 1, r
    assert r['summary'], r
"
}

@test "monitor_sample: the stream's first-sample changes stay empty" {
  # Journaling only. The GUI alerts on `changes`; a fault it was already
  # showing must not read as a new one because the monitor restarted.
  local journal="$BATS_TEST_TMPDIR/stream.jsonl"
  run emit NETDIAG_MON_JOURNAL="$journal" NETDIAG_MON_SEQ=1 \
           NETDIAG_MON_HAVE_PREV=0 NETDIAG_MON_RULES='G2 '
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert 'changes' not in d, d['changes']
assert d['status']['rules'], d['status']
"
}

@test "monitor_sample: a rule already firing is not journaled again on later samples" {
  local journal="$BATS_TEST_TMPDIR/once.jsonl"
  run emit NETDIAG_MON_JOURNAL="$journal" NETDIAG_MON_SEQ=1 \
           NETDIAG_MON_HAVE_PREV=0 NETDIAG_MON_RULES='G2 '
  [ "$status" -eq 0 ]
  # The second and third samples: the same rule, now with a baseline.
  run emit NETDIAG_MON_JOURNAL="$journal" NETDIAG_MON_SEQ=2 \
           NETDIAG_MON_HAVE_PREV=1 NETDIAG_MON_RULES='G2 ' \
           NETDIAG_MON_PREV_RULES='G2 '
  [ "$status" -eq 0 ]
  run emit NETDIAG_MON_JOURNAL="$journal" NETDIAG_MON_SEQ=3 \
           NETDIAG_MON_HAVE_PREV=1 NETDIAG_MON_RULES='G2 ' \
           NETDIAG_MON_PREV_RULES='G2 '
  [ "$status" -eq 0 ]
  run journal_lines "$journal"
  printf '%s' "$output" | python3 -c "
import json, sys
rows = json.load(sys.stdin)
assert [r['kind'] for r in rows] == ['monitor-started', 'rule-fired'], rows
"
}

@test "monitor_sample: a rule that fires after the first sample is an ordinary fire" {
  local journal="$BATS_TEST_TMPDIR/later.jsonl"
  run emit NETDIAG_MON_JOURNAL="$journal" NETDIAG_MON_SEQ=3 \
           NETDIAG_MON_HAVE_PREV=1 NETDIAG_MON_RULES='G2 ' \
           NETDIAG_MON_PREV_RULES=''
  [ "$status" -eq 0 ]
  run journal_lines "$journal"
  printf '%s' "$output" | python3 -c "
import json, sys
rows = json.load(sys.stdin)
assert len(rows) == 1 and rows[0]['kind'] == 'rule-fired', rows
# Observed starting, not found in progress: no marker.
assert 'already_firing' not in rows[0], rows[0]
"
}

@test "monitor_sample: a first sample with no rules journals only monitor-started" {
  local journal="$BATS_TEST_TMPDIR/quiet.jsonl"
  run emit NETDIAG_MON_JOURNAL="$journal" NETDIAG_MON_SEQ=1 \
           NETDIAG_MON_HAVE_PREV=0 NETDIAG_MON_RULES=''
  [ "$status" -eq 0 ]
  run journal_lines "$journal"
  printf '%s' "$output" | python3 -c "
import json, sys
rows = json.load(sys.stdin)
assert [r['kind'] for r in rows] == ['monitor-started'], rows
"
}

@test "monitor_sample: without a journal a firing first sample writes nothing" {
  local dir="$BATS_TEST_TMPDIR/cwd"
  mkdir -p "$dir/home"
  cd "$dir"
  # Python's own bytecode cache under HOME is not ours to blame.
  run emit HOME="$dir/home" PYTHONDONTWRITEBYTECODE=1 \
           NETDIAG_MON_SEQ=1 NETDIAG_MON_HAVE_PREV=0 \
           NETDIAG_MON_RULES='G2 '
  [ "$status" -eq 0 ]
  [ -z "$(find "$dir" -type f)" ]
}

@test "monitor_sample: an unknown rule id falls back to a generic phrase" {
  # A monitor running against a newer lib/thresholds.sh than the bundled
  # rules_catalog.py knows about must still emit something readable rather
  # than crashing the whole sample.
  run emit NETDIAG_MON_HAVE_PREV=1 \
           NETDIAG_MON_RULES='ZZ-9 ' NETDIAG_MON_PREV_RULES=''
  printf '%s' "$output" | python3 -c "
import json,sys
ch = json.load(sys.stdin)['changes']
assert len(ch) == 1, ch
assert ch[0]['summary'] == 'Issue ZZ-9 detected', ch
"
}

@test "monitor_sample: a broken rules_catalog sibling does not kill the emitter" {
  # helpers/rules_catalog.py corrupted (a bad merge, a stray edit) must not
  # take the whole monitor stream down with it — the import is guarded in
  # monitor_sample.py. Driven directly against a corrupted copy of
  # helpers/, matching this file's own helper-direct style, rather than via
  # the sourced bash rule engine.
  local tmp="$BATS_TEST_TMPDIR/helpers"
  cp -R "$HELPERS" "$tmp"
  printf 'this is not python\n' > "$tmp/rules_catalog.py"
  run env -i PATH="$PATH" NETDIAG_MON_HAVE_PREV=1 \
      NETDIAG_MON_RULES='G2 ' NETDIAG_MON_PREV_RULES='' \
      python3 "$tmp/monitor_sample.py"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json,sys
d = json.load(sys.stdin)
ch = d['changes']
assert len(ch) == 1, ch
assert ch[0]['summary'] == 'Issue G2 detected', ch
"
}

@test "monitor_sample: vpn name change is suppressed for utun-route tunnels" {
  # A real utun reconnect rotates both the tunnel interface and its
  # utun-route "name" (they're the same value) — the end state should be
  # one meaningful interface-changed row, not a duplicate vpn-name-changed
  # entry and not silence.
  run emit NETDIAG_MON_HAVE_PREV=1 \
           NETDIAG_MON_VPN_ACTIVE=1 NETDIAG_MON_PREV_VPN_ACTIVE=1 \
           NETDIAG_MON_VPN_TYPE=utun-route \
           NETDIAG_MON_VPN_NAME=utun6 NETDIAG_MON_PREV_VPN_NAME=utun4 \
           NETDIAG_MON_INTERFACE=utun6 NETDIAG_MON_PREV_INTERFACE=utun4
  printf '%s' "$output" | python3 -c "
import json,sys
ch = json.load(sys.stdin)['changes']
assert len(ch) == 1, ch
assert ch[0]['id'] == 'interface-changed', ch
"
}

@test "monitor_sample: vpn name change still reported for named VPNs" {
  run emit NETDIAG_MON_HAVE_PREV=1 \
           NETDIAG_MON_VPN_ACTIVE=1 NETDIAG_MON_PREV_VPN_ACTIVE=1 \
           NETDIAG_MON_VPN_TYPE=scutil-nc \
           NETDIAG_MON_VPN_NAME=Mullvad NETDIAG_MON_PREV_VPN_NAME=ProtonVPN
  printf '%s' "$output" | python3 -c "
import json,sys
ch = json.load(sys.stdin)['changes']
assert len(ch) == 1, ch
assert ch[0]['id'] == 'vpn-name-changed'
assert ch[0]['summary'] == 'VPN changed: ProtonVPN → Mullvad'
"
}

@test "monitor_sample: country move on the connect edge is phrased as arrival, not movement" {
  run emit NETDIAG_MON_HAVE_PREV=1 \
           NETDIAG_MON_VPN_ACTIVE=1 NETDIAG_MON_PREV_VPN_ACTIVE=0 \
           NETDIAG_MON_PUB_CC=Sweden NETDIAG_MON_PREV_PUB_CC=Germany
  printf '%s' "$output" | python3 -c "
import json,sys
ch = json.load(sys.stdin)['changes']
assert len(ch) == 2, ch
ids = [c['id'] for c in ch]
assert 'vpn-connected' in ids, ch
country = [c for c in ch if c['id'] == 'country-changed'][0]
assert country['summary'] == 'VPN exit is in Sweden'
"
}

@test "monitor_sample: no roam invented on a wired link" {
  run emit NETDIAG_MON_HAVE_PREV=1 \
           NETDIAG_MON_BSSID=aa:bb:cc:dd:ee:01 NETDIAG_MON_PREV_BSSID=aa:bb:cc:dd:ee:02
  printf '%s' "$output" | python3 -c "
import json,sys
assert 'changes' not in json.load(sys.stdin)
"
}

@test "monitor_sample: interface change is reported" {
  run emit NETDIAG_MON_HAVE_PREV=1 \
           NETDIAG_MON_INTERFACE=en5 NETDIAG_MON_PREV_INTERFACE=en0
  printf '%s' "$output" | python3 -c "
import json,sys
ch = json.load(sys.stdin)['changes']
assert len(ch) == 1, ch
assert ch[0]['id'] == 'interface-changed'
assert ch[0]['summary'] == 'Network interface changed: en0 → en5'
"
}

# ── Flags and exit codes ─────────────────────────────────────────────────
# These exit during argument validation, before any probe runs.

@test "--monitor with a non-numeric interval exits 3, not 2" {
  run "$REPO/bin/hopwatch" --monitor --monitor-fast-interval abc
  [ "$status" -eq 3 ]
  [[ "$output" == *"whole number of seconds"* ]] || return 1
}

@test "--monitor with a zero interval exits 3" {
  run "$REPO/bin/hopwatch" --monitor --monitor-medium-interval 0
  [ "$status" -eq 3 ]
  [[ "$output" == *"at least 1 second"* ]] || return 1
}

@test "a monitor interval flag with no value exits 3" {
  run "$REPO/bin/hopwatch" --monitor --monitor-slow-interval
  [ "$status" -eq 3 ]
  [[ "$output" == *"expects a value"* ]] || return 1
}

@test "the --monitor-*=VALUE form is accepted" {
  run "$REPO/bin/hopwatch" --monitor --monitor-fast-interval=nope
  [ "$status" -eq 3 ]
  [[ "$output" == *"whole number of seconds"* ]] || return 1
}

@test "--monitor-count is validated too" {
  run "$REPO/bin/hopwatch" --monitor --monitor-count -1
  [ "$status" -eq 3 ]
}

@test "--monitor and its interval flags are documented in --help" {
  run "$REPO/bin/hopwatch" --help
  [ "$status" -eq 0 ]
  for flag in --monitor --monitor-fast-interval --monitor-medium-interval \
              --monitor-slow-interval --monitor-count; do
    [[ "$output" == *"$flag"* ]] || { echo "missing from --help: $flag"; return 1; }
  done
}

@test "--monitor writes nothing under the log directory" {
  # It runs for days. Anything it accumulates, it accumulates forever.
  run grep -n 'LOG=/dev/null' "$REPO/bin/hopwatch"
  [ "$status" -eq 0 ]
  # Code lines only — the header comment names baseline.jsonl precisely to
  # say it is never written.
  run grep -cE '^[^#]*(baseline\.jsonl|LOG_DIR|>>[[:space:]]*"\$LOG)' "$REPO/lib/monitor.sh"
  [ "$output" -eq 0 ]
}

# ── Pause and resume ─────────────────────────────────────────────────────
# The one block here that spawns a real monitor, because the bug it guards
# was invisible to every static check and to every terminal experiment.
#
# The app pauses the monitor while a scan runs — a speed test saturates the
# link on purpose, so samples taken during one are fiction. The obvious
# mechanism, SIGSTOP from the parent, is actively unsafe: POSIX sends
# SIGHUP+SIGCONT to a process group that becomes newly orphaned while any
# member is stopped, and a stopped monitor still has live children (the
# 2 s gateway ping, with_timeout's killer subshells). The moment one exits,
# the group orphans and the SIGHUP kills it.
#
# Measured under the GUI: the monitor died 2.1 s into every pause — exactly
# one ping probe — and the app restarted it *during the scan the pause
# existed to protect*. It never reproduced from a terminal, because a
# controlling terminal keeps the group non-orphaned. That is precisely how
# it would have shipped.

# Start a monitor in the background; its pid lands in $MON_PID and is
# registered for teardown(). This must NOT be called as `pid="$(start_monitor)"`:
# the command substitution makes the monitor's parent a subshell that exits at
# once, so the monitor is re-parented to pid 1 before lib/monitor.sh captures
# its parent. With a parent of 1 the monitor's parent-died guard is disabled
# (launchd legitimately starts the recorder as ppid 1), and a monitor orphaned
# that way ran for 42 minutes pinging the router every 2 seconds. Calling it
# directly keeps the bats test shell as the parent, so the guard reaps the
# monitor if bats itself dies.
#
# --monitor-count is the third line of defence: it stops the monitor after
# that many samples whatever else goes wrong (a paused monitor takes none, so
# it never trips the tests that pause). 90 samples at the 2 s cadence is
# about three minutes, against tests that need under one.
#
# `pgrep -f` is deliberately avoided: bats runs each test through a shell
# whose own command line contains the pattern, so pgrep matches the wrong
# process and the signal lands on the test runner. `3>&-` keeps the
# background process off bats' result fd.
start_monitor() {
  "$REPO/bin/hopwatch" --monitor --monitor-fast-interval 2 \
    --monitor-medium-interval 3600 --monitor-slow-interval 3600 \
    --monitor-count 90 \
    > "$BATS_TEST_TMPDIR/stream.jsonl" 2>"$BATS_TEST_TMPDIR/stream.err" 3>&- &
  MON_PID=$!
  MON_PIDS+=("$MON_PID")
}

alive() { ps -o stat= -p "$1" >/dev/null 2>&1; }
samples() { wc -l < "$BATS_TEST_TMPDIR/stream.jsonl" | tr -d ' '; }

# Wait for a condition, up to $1 seconds. Returns 1 if it never held.
#
# Sleeping a fixed number of seconds and then asserting encodes the speed of
# the machine that wrote the test. A GitHub runner is slower than a laptop
# and its "gateway" is virtualised, so the first cycle — a real ping plus a
# DNS lookup — can take longer than the cadence it was given. Three tests
# here failed in CI for exactly that reason and passed locally every time.
# Polling keeps the assertion (it did happen) without the assumption (within
# n seconds on this hardware).
wait_until() {
  local timeout="$1"; shift
  local deadline=$(( SECONDS + timeout ))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if "$@"; then return 0; fi
    sleep 1
  done
  return 1
}

have_samples() { [ "$(samples)" -ge "${1:-1}" ]; }
not_alive()    { ! alive "$1"; }

# True once the stream's last line is a sample that reports itself paused.
# An empty file, a half-written line, or a sample that predates the signal
# are all ordinary while the monitor is mid-cycle, so each returns 1 and
# lets the caller poll again rather than failing the test outright.
last_is_paused() {
  local last
  last="$(tail -1 "$BATS_TEST_TMPDIR/stream.jsonl" 2>/dev/null)"
  [ -n "$last" ] || return 1
  printf '%s' "$last" | python3 -c '
import json, sys
try:
    sys.exit(0 if json.load(sys.stdin)["status"]["paused"] is True else 1)
except Exception:
    sys.exit(1)
'
}

@test "SIGUSR1 suspends probing and SIGUSR2 resumes it" {
  start_monitor; local pid="$MON_PID"
  wait_until 30 have_samples 1 || { echo "monitor produced no samples at all"; kill -9 "$pid"; return 1; }
  local before; before="$(samples)"

  kill -USR1 "$pid"
  sleep 6
  local paused; paused="$(samples)"
  # Still a fixed sleep, and it has to be: this asserts that samples *stop*,
  # and there is no event to wait for when the expected behaviour is
  # silence. The bound stays generous — at most one in-flight cycle plus the
  # pause marker, against the three more that 6 s at a 2 s cadence would
  # produce unpaused.
  [ $((paused - before)) -le 2 ]

  kill -USR2 "$pid"
  wait_until 30 have_samples $((paused + 1)) || { echo "monitor never resumed"; kill -9 "$pid"; return 1; }
  kill -TERM "$pid" 2>/dev/null || true
}

@test "a paused monitor stays alive rather than being killed by SIGHUP" {
  # The actual regression. Six seconds is three times the ping probe that
  # used to orphan the process group and take it down.
  start_monitor; local pid="$MON_PID"
  # Wait for a real sample rather than sleeping: pausing a monitor that has
  # not probed yet would still pass this test while asserting nothing, since
  # the orphaning it guards against happens inside a probe.
  wait_until 30 have_samples 1 || { echo "monitor produced no samples at all"; kill -9 "$pid"; return 1; }
  kill -USR1 "$pid"
  # Still a fixed sleep, and it has to be: this asserts survival across a
  # span of time, and there is no event that marks "did not die".
  sleep 7
  alive "$pid" || { echo "monitor died while paused"; return 1; }
  kill -TERM "$pid" 2>/dev/null || true
}

@test "a paused monitor says so rather than going silently quiet" {
  start_monitor; local pid="$MON_PID"
  wait_until 30 have_samples 1 || { echo "monitor produced no samples at all"; kill -9 "$pid"; return 1; }

  kill -USR1 "$pid"
  # Poll, don't sleep. The pause marker is an event, so there is something
  # to wait for — and the signal can land mid-cycle, which puts the marker
  # behind an in-flight sample rather than immediately after the kill. The
  # fixed `sleep 3` this replaces read an empty file on a loaded runner and
  # failed with a JSON decode error, red on a public README for three days.
  wait_until 30 last_is_paused || {
    echo "last sample never reported paused; stream tail:"
    tail -3 "$BATS_TEST_TMPDIR/stream.jsonl"
    kill -9 "$pid"
    return 1
  }
  kill -TERM "$pid" 2>/dev/null || true
}

@test "SIGTERM stops the monitor promptly, paused or not" {
  # "Promptly" is bounded by the longest probe a cycle can be inside when
  # the signal lands, not by a number that felt right on a laptop.
  start_monitor; local pid="$MON_PID"
  wait_until 30 have_samples 1 || { echo "monitor produced no samples at all"; kill -9 "$pid"; return 1; }
  kill -TERM "$pid"
  wait_until 15 not_alive "$pid" || { echo "monitor ignored SIGTERM"; kill -9 "$pid"; return 1; }

  start_monitor; pid="$MON_PID"
  wait_until 30 have_samples 1 || { echo "monitor produced no samples at all"; kill -9 "$pid"; return 1; }
  kill -USR1 "$pid"
  sleep 2
  kill -TERM "$pid"
  wait_until 15 not_alive "$pid" || { echo "paused monitor ignored SIGTERM"; kill -9 "$pid"; return 1; }
  return 0
}

@test "lib/monitor.sh traps the pause signals it documents" {
  run grep -cE '^[[:space:]]*trap _mon_on_(pause|resume) +USR[12]' "$REPO/lib/monitor.sh"
  [ "$output" -eq 2 ]
}

@test "the GUI pauses with SIGUSR1, never SIGSTOP" {
  # Structural guard on the fix. SIGSTOP against this process is a latent
  # kill that only manifests under a GUI parent.
  local gui="$REPO/gui/Sources/HopwatchGUI/Services/MonitorStream.swift"
  [ -f "$gui" ] || gui="$REPO/gui/Sources/NetdiagGUI/Services/MonitorStream.swift"
  [ -f "$gui" ] || skip "GUI sources not present"
  run grep -nE '^[^/]*kill\(process\.processIdentifier, SIG(STOP|CONT)\)' "$gui"
  [ "$status" -ne 0 ] || { echo "GUI still uses SIGSTOP/SIGCONT:"; echo "$output"; return 1; }
  run grep -c 'SIGUSR1' "$gui"
  [ "$output" -ge 1 ]
}

# ── Orphan cleanup ───────────────────────────────────────────────────────
# A stream exists for a consumer. A network probe still running with no
# reader is the single most likely reason an always-on tool gets
# uninstalled, and it is invisible — nothing in the UI can show a process
# the app no longer knows about.
#
# Taking EPIPE on a closed stdout is not enough on its own: measured,
# SIGKILL of the GUI left the monitor probing 30 s later, because a pipe fd
# survives in ways the child cannot audit. So the parent is checked
# explicitly, with `kill -0` rather than $PPID — bash captures PPID once at
# startup and still reports a dead pid after re-parenting to launchd.

@test "the monitor exits when the process that started it dies" {
  # An intermediate shell stands in for the app: it spawns the monitor,
  # then is killed outright, exactly as a force-quit or a crash would be.
  local out="$BATS_TEST_TMPDIR/pid"
  # `exec sleep` keeps the stand-in shell's pid (the monitor's parent) alive
  # without leaving a stray `sleep 60` behind when it is killed. The monitor
  # is capped, and both pids are registered, so teardown reaps whichever
  # survives a failure.
  bash -c "'$REPO/bin/hopwatch' --monitor --monitor-fast-interval 2 --monitor-count 30 \
             >/dev/null 2>&1 3>&- & echo \$! > '$out'; exec sleep 60" 3>&- &
  local shell_pid=$!
  MON_PIDS+=("$shell_pid")
  sleep 4
  local mon_pid; mon_pid="$(cat "$out")"
  MON_PIDS+=("$mon_pid")
  ps -o stat= -p "$mon_pid" >/dev/null 2>&1 || { echo "monitor never started"; return 1; }

  kill -9 "$shell_pid" 2>/dev/null
  # One cadence plus one in-flight probe is the honest bound.
  local i
  for i in $(seq 1 20); do
    ps -o stat= -p "$mon_pid" >/dev/null 2>&1 || return 0
    sleep 1
  done
  kill -9 "$mon_pid" 2>/dev/null
  echo "orphaned monitor was still running 20 s after its parent died"
  return 1
}

@test "the parent check uses kill -0, not a re-read of PPID" {
  # bash sets PPID once at startup and never updates it, so comparing it
  # against itself would silently never fire — the guard would look
  # present and do nothing.
  run grep -cE 'kill -0 "\$parent_pid"' "$REPO/lib/monitor.sh"
  [ "$output" -eq 1 ]
}

# ── previous-sample snapshot ────────────────────────────────────────────

@test "_mon_snapshot_prev copies identity fields and arms HAVE_PREV" {
  MON_PUB_IP="203.0.113.42"; MON_PUB_CC="Brazil"; MON_PUB_ISP="ExampleNet"
  MON_VPN_ACTIVE=1; MON_VPN_NAME="Mullvad"
  MON_SSID="HomeNet"; MON_BSSID="aa:bb:cc:dd:ee:ff"; MON_INTERFACE="en0"
  MON_RULES="G2 "
  MON_HAVE_PREV=0
  _mon_snapshot_prev
  [ "$MON_HAVE_PREV" = "1" ]
  [ "$MON_PREV_PUB_IP" = "203.0.113.42" ]
  [ "$MON_PREV_PUB_CC" = "Brazil" ]
  [ "$MON_PREV_VPN_ACTIVE" = "1" ]
  [ "$MON_PREV_VPN_NAME" = "Mullvad" ]
  [ "$MON_PREV_SSID" = "HomeNet" ]
  [ "$MON_PREV_BSSID" = "aa:bb:cc:dd:ee:ff" ]
  [ "$MON_PREV_INTERFACE" = "en0" ]
  [ "$MON_PREV_RULES" = "G2 " ]
}

@test "_mon_snapshot_prev keeps last-known identity across an empty sample" {
  # The diff in monitor_sample.py suppresses comparisons where either
  # side is null. If a link-down sample (empty interface/SSID) clobbered
  # the snapshot, en0 → "" → en5 would never report interface-changed.
  # Identity fields keep their last known value; rules and the VPN flag
  # snapshot rule recovery when the relevant measurement was made.
  MON_PUB_IP="203.0.113.42"; MON_PUB_CC="Brazil"; MON_PUB_ISP="ExampleNet"
  MON_VPN_ACTIVE=1; MON_VPN_NAME="Mullvad"
  MON_SSID="HomeNet"; MON_BSSID="aa:bb:cc:dd:ee:ff"; MON_INTERFACE="en0"
  MON_RULES="G2 "
  MON_MEASUREMENT_STATE="measured" MON_CLEARABLE_RULES="G2 "
  _mon_snapshot_prev
  MON_INTERFACE=""; MON_SSID=""; MON_BSSID=""; MON_VPN_NAME=""
  MON_RULES=""; MON_VPN_ACTIVE=0
  MON_MEASUREMENT_STATE="measured" MON_CLEARABLE_RULES="G2 "
  _mon_snapshot_prev
  [ "$MON_PREV_INTERFACE" = "en0" ]
  [ "$MON_PREV_SSID" = "HomeNet" ]
  [ "$MON_PREV_BSSID" = "aa:bb:cc:dd:ee:ff" ]
  [ "$MON_PREV_VPN_NAME" = "Mullvad" ]
  [ "$MON_PREV_RULES" = "" ]
  [ "$MON_PREV_VPN_ACTIVE" = "0" ]
}

@test "_mon_snapshot_prev retains a fault until a measured healthy cycle" {
  MON_RULES="L1 " MON_MEASUREMENT_STATE="measured"
  _mon_snapshot_prev
  MON_RULES="" MON_MEASUREMENT_STATE="unknown"
  _mon_snapshot_prev
  [ "$MON_PREV_RULES" = "L1 " ]
  MON_MEASUREMENT_STATE="measured" MON_CLEARABLE_RULES="L1 "
  _mon_snapshot_prev
  [ "$MON_PREV_RULES" = "" ]
}

@test "monitor state block initializes every MON_PREV_ variable" {
  # bin/hopwatch runs set -u: an uninitialized MON_PREV_* would abort the
  # first emit. Every var _mon_emit forwards must be declared.
  for v in MON_HAVE_PREV MON_PREV_PUB_IP MON_PREV_PUB_CC MON_PREV_PUB_ISP \
           MON_PREV_VPN_ACTIVE MON_PREV_VPN_NAME MON_PREV_SSID \
           MON_PREV_BSSID MON_PREV_INTERFACE MON_PREV_RULES; do
    grep -qE "^${v}=" "$REPO/lib/monitor.sh" || {
      echo "missing init: $v"; return 1; }
  done
}

@test "_mon_emit forwards prev state to the sample helper" {
  for v in HAVE_PREV PREV_PUB_IP PREV_PUB_CC PREV_PUB_ISP PREV_VPN_ACTIVE \
           PREV_VPN_NAME PREV_SSID PREV_BSSID PREV_INTERFACE PREV_RULES; do
    grep -q "NETDIAG_MON_${v}=" "$REPO/lib/monitor.sh" || {
      echo "not forwarded: $v"; return 1; }
  done
}

# ── Sleep and stall detection: gap_s ─────────────────────────────────────
#
# The monitor deliberately stays dumb about sleep and leaves it to the
# GUI's NSWorkspace notifications. That is right for the GUI and wrong for
# every other consumer: --monitor is documented as a stream for ANY
# program, and a laptop lid closed for eight hours emits two samples eight
# hours apart with nothing marking the discontinuity. A program reading
# that stream sees an eight-hour outage that never happened.

@test "monitor: an ordinary cycle reports no gap" {
  # 10 s cadence, 11 s elapsed — probes take 2-6 s, so overrun is normal.
  run _mon_gap_seconds 11 10
  [ "$status" -eq 0 ]
  [ "$output" = "" ] || { echo "flagged an ordinary cycle: '$output'"; return 1; }
}

@test "monitor: a cycle at exactly the tolerance is not a gap" {
  # factor 3 x 10 s cadence = 30 s, which is below the 60 s floor, so the
  # floor decides: the boundary is exclusive, 60 is still a slow cycle and
  # 61 is a discontinuity.
  run _mon_gap_seconds 60 10
  [ "$output" = "" ] || { echo "60 s flagged at a 10 s cadence: '$output'"; return 1; }
  run _mon_gap_seconds 61 10
  [ "$output" = "61" ] || { echo "61 s not flagged: '$output'"; return 1; }
}

# The tolerance has a floor because a cycle's own probe time does not
# shrink with the cadence. The app runs 5 s (healthy), 3 s (degraded) and
# 2 s (investigation burst); at factor 3 alone those tolerate 15, 9 and
# 6 s, and a cycle on a lossy link legitimately takes 8-11 s (all three
# tiers firing at once can take ~46 s). Measured live: 113 of one
# monitor's 114 cycles carried a "gap" of 10-13 s.
@test "monitor: the floor stops a short cadence calling a slow cycle a gap" {
  local args
  for args in "13 3" "9 2" "16 5" "11 2" "46 5" "46 2"; do
    # shellcheck disable=SC2086
    run _mon_gap_seconds $args
    [ "$output" = "" ] || { echo "args [$args] flagged: '$output'"; return 1; }
  done
}

@test "monitor: the floor does not hide a real stall at a short cadence" {
  local args
  for args in "61 3" "61 2" "61 5" "300 2"; do
    # shellcheck disable=SC2086
    run _mon_gap_seconds $args
    [ "$output" = "${args%% *}" ] || { echo "args [$args] gave '$output'"; return 1; }
  done
}

@test "monitor: the boundary at a 3 s cadence is the floor, not 3 x 3" {
  run _mon_gap_seconds "$THRESH_MON_GAP_MIN_S" 3
  [ "$output" = "" ] || { echo "floor itself flagged: '$output'"; return 1; }
  run _mon_gap_seconds $((THRESH_MON_GAP_MIN_S + 1)) 3
  [ "$output" = "$((THRESH_MON_GAP_MIN_S + 1))" ] || { echo "floor+1 not flagged: '$output'"; return 1; }
}

@test "monitor: the floor clears a worst-case cycle with margin" {
  # Reachable in one cycle: fast tier 6 (gateway) + 8 (internet) + 2 (web),
  # medium 3 (dns) + 8 (two tcp) + 4 (wifi) + 2 (browser), slow 4 + 4
  # (public, with its fallback) + 3 (captive), plus 2 s minimum rest and 1 s
  # of whole-second clock truncation. Written out because the probe
  # timeouts live in lib/monitor.sh; if one of them grows, this fails and
  # the floor has to be reconsidered with it.
  local worst=$(( 6 + 8 + 2 + 3 + 8 + 4 + 2 + 4 + 4 + 3 + 2 + 1 ))
  [ "$THRESH_MON_GAP_MIN_S" -ge $(( worst + 10 )) ] || {
    echo "floor $THRESH_MON_GAP_MIN_S leaves under 10 s over worst case $worst"; return 1; }
}

@test "monitor: an overnight sleep reports the seconds lost" {
  # The case this exists for. Eight hours, at a 10 s cadence.
  run _mon_gap_seconds 28800 10
  [ "$output" = "28800" ] || { echo "got '$output'"; return 1; }
}

@test "monitor: the tolerance scales with the cadence" {
  # A slow-tier consumer at a 300 s cadence must not have every cycle
  # called a gap just because 301 > 30.
  run _mon_gap_seconds 400 300
  [ "$output" = "" ] || { echo "400 s flagged at a 300 s cadence: '$output'"; return 1; }
  run _mon_gap_seconds 1000 300
  [ "$output" = "1000" ] || { echo "1000 s not flagged at 300 s: '$output'"; return 1; }
}

@test "monitor: unusable inputs report nothing rather than guessing" {
  # The first cycle has no previous timestamp, and a zero cadence would
  # make every elapsed time infinitely over tolerance.
  for args in "'' 10" "11 ''" "'' ''" "11 0" "abc 10" "11 abc" "-5 10"; do
    # shellcheck disable=SC2086
    eval "run _mon_gap_seconds $args"
    [ "$output" = "" ] || { echo "args [$args] gave '$output'"; return 1; }
  done
}

@test "monitor: the pause marker does not repeat the previous cycle's gap" {
  # The paused branch emits a sample before the cycle top resets MON_GAP_S,
  # so it used to re-emit whatever gap the last cycle had reported: the
  # journal showed identical gap_s two seconds apart on consecutive seq.
  # Driven in-process: every probe stubbed, _mon_emit records the gap it was
  # handed, and flips the state the signal handlers would have flipped.
  local probe
  for probe in link vpn gateway internet web dns tcp wifi_signal browser public; do
    eval "_mon_probe_$probe() { :; }"
  done
  _mon_rules() { :; }
  _mon_snapshot_prev() { :; }
  _mon_sleep() { :; }
  _mon_emit() {
    printf 'emit paused=%s gap=[%s]\n' "$MON_PAUSED" "$MON_GAP_S"
    case "$MON_PAUSED" in
      0) MON_PAUSED=1 ;;   # first sample out: the pause signal arrives
      *) MON_STOP=1 ;;     # the pause marker is out: let the loop end
    esac
  }
  MON_PAUSED=0 MON_STOP=0 MON_SEQ=0 MONITOR_COUNT=0 MON_LINK_UP=0
  MON_PREV_CYCLE_TS=$(( EPOCHSECONDS - 100000 )) MON_PREV_CADENCE=10
  run monitor_run
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'emit paused=0 gap=\[100000\]' || {
    echo "a genuine gap was not reported on the cycle that saw it:"; echo "$output"; return 1; }
  printf '%s\n' "$output" | grep -qx 'emit paused=1 gap=\[\]' || {
    echo "the pause marker repeated the previous gap:"; echo "$output"; return 1; }
}

@test "monitor: gap_s reaches the emitted sample" {
  run env NETDIAG_MON_SEQ=5 NETDIAG_MON_GAP_S=28800 \
    python3 "$REPO/helpers/monitor_sample.py"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
assert json.load(sys.stdin)['gap_s'] == 28800
"
}

@test "monitor: an ordinary sample carries gap_s null, not zero" {
  # 0 would mean 'no time passed', which is a measurement. null means
  # 'no discontinuity', which is the absence of one — the same
  # null-vs-zero distinction the JSON schema draws everywhere else.
  run env NETDIAG_MON_SEQ=5 python3 "$REPO/helpers/monitor_sample.py"
  printf '%s' "$output" | python3 -c "
import json, sys
assert json.load(sys.stdin)['gap_s'] is None
"
}

@test "monitor: gateway and internet jitter and top-level jitter_ms are emitted" {
  run env NETDIAG_MON_SEQ=5 \
    NETDIAG_MON_GW_JITTER="0.75" \
    NETDIAG_MON_INET_JITTER="3.42" \
    python3 "$REPO/helpers/monitor_sample.py"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
data = json.load(sys.stdin)
assert data['gateway']['rtt_jitter_ms'] == 0.75
assert data['internet']['rtt_jitter_ms'] == 3.42
assert data['jitter_ms'] == 3.42
"
}

# ── The network id survives a lookup that fails ──────────────────────────
#
# The id is derived every fast cycle from `route` and `arp -n`. Both go
# quiet exactly when a router is struggling — the default route is withdrawn
# while Wi-Fi re-associates, and the gateway's ARP entry is gone until the
# first reply repopulates it — so the id used to flip, mid-process, between
# its MAC form, no id at all, and the bare gateway address, and the event
# journal and the app's activity list (both keyed on it) split one fault into
# pieces. A monitor that has learned the router's MAC keeps it while it
# cannot look it up again, and lets go the moment anything contradicts it.

# One fast cycle's probe results, then the id they yield. $1 = clock (s),
# $2 gateway, $3 interface, $4 SSID, $5 gateway MAC from ARP ("" = lookup failed).
# Sets MON_NETWORK_ID / MON_NETWORK_GROUP in the test's own shell, because
# the state being tested lives in MON_KNOWN_* between calls.
cycle() {
  MON_GATEWAY="$2" MON_INTERFACE="$3" MON_SSID="$4" MON_GW_MAC="$5"
  # As _mon_probe_link leaves it: with no interface there is nothing to ask,
  # and the type stays at its "wired" default.
  MON_IFACE_TYPE=wifi
  [ -n "$3" ] || MON_IFACE_TYPE=wired
  _mon_hold_gw_mac "$1"
  _mon_identity
}

@test "a failed ARP lookup keeps the MAC id the monitor already learned" {
  cycle 1000 192.168.1.1 en0 "" 00:11:22:33:44:55
  [ "$MON_NETWORK_ID" = "wifi:mac=00:11:22:33:44:55" ]
  cycle 1010 192.168.1.1 en0 "" ""
  [ "$MON_NETWORK_ID" = "wifi:mac=00:11:22:33:44:55" ]
  [ "$MON_NETWORK_GROUP" = "mac:00:11:22:33:44:55" ]
}

@test "a withdrawn default route keeps it too" {
  cycle 1000 192.168.1.1 en0 "" 00:11:22:33:44:55
  cycle 1010 "" "" "" ""
  [ "$MON_NETWORK_ID" = "wifi:mac=00:11:22:33:44:55" ]
}

@test "the held id is exactly the one a lookup that succeeds produces" {
  # The id has to join onto what a scan records, so holding must not invent
  # a spelling of its own.
  cycle 1000 192.168.1.1 en0 "" 00:11:22:33:44:55
  local fresh="$MON_NETWORK_ID" fresh_group="$MON_NETWORK_GROUP"
  cycle 1010 "" "" "" ""
  [ "$MON_NETWORK_ID" = "$fresh" ]
  [ "$MON_NETWORK_GROUP" = "$fresh_group" ]
  [ "$MON_NETWORK_LABEL" = "WiFi (SSID hidden by macOS)" ]
}

@test "the hold ends after THRESH_MON_IDENTITY_HOLD_S without a sighting" {
  cycle 1000 192.168.1.1 en0 "" 00:11:22:33:44:55
  cycle $((1000 + THRESH_MON_IDENTITY_HOLD_S)) 192.168.1.1 en0 "" ""
  [ "$MON_NETWORK_ID" = "wifi:mac=00:11:22:33:44:55" ]
  cycle $((1000 + THRESH_MON_IDENTITY_HOLD_S + 1)) 192.168.1.1 en0 "" ""
  [ "$MON_NETWORK_ID" = "wifi:gw=192.168.1.1" ]
  # And it does not come back by itself once let go.
  cycle $((1000 + THRESH_MON_IDENTITY_HOLD_S + 2)) 192.168.1.1 en0 "" ""
  [ "$MON_NETWORK_ID" = "wifi:gw=192.168.1.1" ]
}

@test "after the hold, a route that is still gone is an unknown network" {
  cycle 1000 192.168.1.1 en0 "" 00:11:22:33:44:55
  cycle $((1000 + THRESH_MON_IDENTITY_HOLD_S + 1)) "" "" "" ""
  [ -z "$MON_NETWORK_ID" ]
  [ "$MON_NETWORK_LABEL" = "unknown network" ]
}

@test "a different gateway address is a different network, and the old one is forgotten" {
  cycle 1000 192.168.1.1 en0 "" 00:11:22:33:44:55
  cycle 1010 10.0.0.1 en0 "" ""
  [ "$MON_NETWORK_ID" = "wifi:gw=10.0.0.1" ]
  # Back on the first gateway address with no MAC to confirm it: not
  # evidence of the first network any more.
  cycle 1020 192.168.1.1 en0 "" ""
  [ "$MON_NETWORK_ID" = "wifi:gw=192.168.1.1" ]
}

@test "a different interface ends the hold" {
  cycle 1000 192.168.1.1 en0 "" 00:11:22:33:44:55
  cycle 1010 192.168.1.1 en7 "" ""
  [ "$MON_NETWORK_ID" = "wifi:gw=192.168.1.1" ]
}

@test "a different visible SSID ends the hold, an unreadable one does not" {
  cycle 1000 192.168.1.1 en0 Home 00:11:22:33:44:55
  [ "$MON_NETWORK_ID" = "wifi:ssid=Home,mac=00:11:22:33:44:55" ]
  cycle 1010 192.168.1.1 en0 "" ""
  [ "$MON_NETWORK_ID" = "wifi:ssid=Home,mac=00:11:22:33:44:55" ]
  cycle 1020 192.168.1.1 en0 Cafe ""
  [ "$MON_NETWORK_ID" = "wifi:ssid=Cafe" ]
}

@test "a MAC read afterwards always wins over the one held" {
  cycle 1000 192.168.1.1 en0 "" 00:11:22:33:44:55
  cycle 1010 192.168.1.1 en0 "" 66:77:88:99:aa:bb
  [ "$MON_NETWORK_ID" = "wifi:mac=66:77:88:99:aa:bb" ]
  cycle 1020 192.168.1.1 en0 "" ""
  [ "$MON_NETWORK_ID" = "wifi:mac=66:77:88:99:aa:bb" ]
}

@test "a monitor that has never read a MAC has nothing to hold" {
  cycle 1000 192.168.1.1 en0 "" ""
  [ "$MON_NETWORK_ID" = "wifi:gw=192.168.1.1" ]
  cycle 1010 "" "" "" ""
  [ -z "$MON_NETWORK_ID" ]
}
