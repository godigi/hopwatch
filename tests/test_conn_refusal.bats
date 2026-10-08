#!/usr/bin/env bats
#
# CONN-1 — new connections are being refused or dropped while ping is clean.
#
# The incident (docs/investigations/2026-10-08-flaky-dns-vs-web-blocked.md):
# this Mac's own torrent client flooded the router with new flows. UDP DNS to
# two unrelated resolvers timed out ~10% of the time, TCP/443 connects were
# refused ~60% of the time, ICMP lost nothing, and Hopwatch said "your DNS
# server is flaky" one moment and "port 443 is blocked" the next. These tests
# hold the replacement: one finding, observed not guessed, confirmed over
# more than one sample in the monitor, naming the app only when it plausibly
# is the cause, and silent whenever another rule owns the symptom.
#
# Network-free: everything is driven through globals and stubbed commands.

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  HELPERS="$REPO/helpers"
  JSON_MODE=0 QUIET=0 QUICK=0 EXPERT=0 REDACT=0 LOG=/dev/null
  NETDIAG_VERSION="test"
  . "$REPO/lib/thresholds.sh"
  . "$REPO/lib/common.sh"
  . "$REPO/lib/globals.sh"
  . "$REPO/lib/netid.sh"
  . "$REPO/lib/traffic.sh"
  . "$REPO/lib/monitor.sh"
  . "$REPO/lib/repairs.sh"
  . "$REPO/lib/diagnosis.sh"
  with_timeout() { shift; "$@"; }
}

# A healthy baseline for both engines; each test perturbs what it studies.
reset_state() {
  MON_LINK_UP=1 MON_IFACE_TYPE=wifi MON_GATEWAY=192.168.1.1
  MON_GW_LOSS=0 MON_GW_RTT=3 MON_INET_LOSS="" MON_INET_LOSS_ALT="" MON_INET_RTT=""
  MON_GW_HIST="" MON_INET_HIST="" MON_INET_HIST_ALT=""
  MON_WIFI_RSSI="" MON_WIFI_SNR=""
  MON_DNS_OK=1 MON_DNS_ALT_OK="" MON_TCP_OK=1 MON_TCP_LINES="" MON_PUBLIC_OK=1 MON_CAPTIVE=0
  MON_DNS_LOCAL_FAIL="" DNS_LOCAL_FAIL=0
  MON_WEB_OK="" MON_MEASUREMENT_STATE="unknown" MON_PREV_RULES=""
  MON_VPN_ACTIVE=0 MON_ICMP_FILTERED=0 MON_DEGRADED=0
  MON_GW_LOSS_STREAK=0 MON_INET_LOSS_STREAK=0 MON_MEDIUM_FRESH=1
  _mon_conn_reset
  GATEWAY=192.168.1.1 IS_WIFI=1 GW_LOSS=0 WIFI_RSSI="" WIFI_SNR=""
  DNS_OK=1 PUBLIC_OK=1 PUBLIC_CHECKED=1
  DNS_LINES=$'192.168.1.1|apple.com|1.2.3.4|OK\n1.1.1.1|apple.com|1.2.3.4|OK\n8.8.8.8|apple.com|1.2.3.4|OK\n'
  TCP_REACH_LINES=$'1.1.1.1:443|OK|20\n8.8.8.8:443|OK|22\ngithub.com:443|OK|30\n'
  TCP_REACH_ANY_OK=1 VPN_ACTIVE=0 CAPTIVE_PORTAL=0
  DNS_PRIMARY_FAIL=0 DNS_FALLBACK_OK=0 PRIMARY_DNS="" SECONDARY_DNS="" SYS_RES="192.168.1.1" SYS_RES_ALL="192.168.1.1"
  IPV6_AVAILABLE=0 MTU_EFFECTIVE="" MTR_FIRST_LOSSY_HOP=""
  INET_LOSS="" INET_LOSS_ALT="" NTP_DRIFT_S="" DHCP_TIME_REMAINING_S=""
  ARP_GW_INCOMPLETE=0 ARP_DUPLICATE_IPS="" DHCP_DNS_SERVERS=""
  WIFI_SCAN_CURRENT_CHANNEL_NEIGHBORS=0 WIFI_DISCONNECT_COUNT=0
  BUFFERBLOAT_GW_GRADE="" BUFFERBLOAT_INET_GRADE=""
  CONN_HOLDERS="" CONN_FLOWS_TOTAL="" CONN_HOLDER_TOP_SHARE_PCT="" CONN_HOLDER_APP_BUNDLE="" CONN_HOLDER_APP_NAME=""
  REPAIR_OFFERS=""
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
}

# The scan's view of the incident: 1.1.1.1 and 8.8.8.8 both silent on
# apple.com, both answering cloudflare.com; the router's resolver fine.
flaky_dns_pair() {
  DNS_OK=0
  DNS_LINES=$'192.168.1.1|apple.com|1.2.3.4|OK\n1.1.1.1|apple.com||FAIL\n8.8.8.8|apple.com||FAIL\n192.168.1.1|cloudflare.com|5.6.7.8|OK\n1.1.1.1|cloudflare.com|5.6.7.8|OK\n8.8.8.8|cloudflare.com|5.6.7.8|OK\n'
}

# One lookup lost and one 443 connect to a bare address refused.
dns_and_443() {
  DNS_OK=0
  DNS_LINES=$'192.168.1.1|apple.com|1.2.3.4|OK\n1.1.1.1|apple.com||FAIL\n8.8.8.8|apple.com|1.2.3.4|OK\n'
  TCP_REACH_LINES=$'1.1.1.1:443|FAIL\n8.8.8.8:443|OK|22\ngithub.com:443|OK|30\n'
}

scan() {
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0; REPAIR_OFFERS=""
  diagnosis_run >/dev/null
}

scan_rules() { printf '%s ' "${DIAG_RULE[@]:-}"; }

diag_text_for() {
  local i
  for i in "${!DIAG_RULE[@]}"; do
    if [ "${DIAG_RULE[$i]}" = "$1" ]; then printf '%s\n' "${DIAG[$i]}"; return 0; fi
  done
  return 1
}

monitor_rules() {
  _mon_rules
  printf '%s' "$MON_RULES" | tr ' ' '\n' | grep -v '^$' | sort | tr '\n' ' '
}

# The Stremio shape: one `node` process holding 210 UDP sockets and 67
# connections stuck in SYN_SENT, in a Mac whose system-wide counts are a
# little over that.
stub_flood() {
  netstat() {
    case "$*" in
      *udp*) for i in $(seq 1 240); do printf 'udp4 0 0 *.%s *.*\n' "$i"; done ;;
      *tcp*) for i in $(seq 1 70); do printf 'tcp4 0 0 10.0.0.5.%s 1.2.3.4.6881 SYN_SENT\n' "$((50000 + i))"; done
             printf 'tcp4 0 0 10.0.0.5.40000 1.2.3.4.443 ESTABLISHED\n' ;;
    esac
  }
  lsof() {
    printf 'COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\n'
    case "$*" in
      *SYN_SENT*) for i in $(seq 1 67); do printf 'node 48834 me %su IPv4 0x1 0t0 TCP 10.0.0.5:%s->1.2.3.4:6881 (SYN_SENT)\n' "$i" "$((50000 + i))"; done ;;
      *UDP*)      for i in $(seq 1 210); do printf 'node 48834 me %su IPv4 0x1 0t0 UDP *:%s\n' "$i" "$((40000 + i))"; done
                  for i in 1 2 3; do printf 'Google\\x20Chrome 900 me %su IPv4 0x1 0t0 UDP *:%s\n' "$i" "$((30000 + i))"; done ;;
    esac
  }
  lsappinfo() {
    case "$*" in
      *" 48834") printf '"CFBundleIdentifier"=[ NULL ]\n"ApplicationType"=[ NULL ]\n' ;;
      *" 4000")  printf '"CFBundleIdentifier"="com.stremio.app"\n"LSDisplayName"="Stremio"\n"ApplicationType"="Foreground"\n' ;;
      *)         printf '"CFBundleIdentifier"=[ NULL ]\n"ApplicationType"=[ NULL ]\n' ;;
    esac
  }
  ps() {
    case "$*" in
      *"ppid"*" 48834") echo " 4000" ;;
      *"ppid"*)         echo "    1" ;;
    esac
  }
}

# ── The scan ──────────────────────────────────────────────────────────────

@test "CONN-1: two unrelated resolvers dropping the same lookup is one warn finding, and D1 stays quiet" {
  reset_state; flaky_dns_pair
  scan
  [[ " $(scan_rules)" == *" CONN-1 "* ]] || { echo "rules: $(scan_rules)"; return 1; }
  [[ " $(scan_rules)" != *" D1 "* && " $(scan_rules)" != *" D5 "* && " $(scan_rules)" != *" D6 "* ]]
  local i
  for i in "${!DIAG_RULE[@]}"; do
    [ "${DIAG_RULE[$i]}" = CONN-1 ] && [ "${DIAG_SEV[$i]}" = warn ]
  done
  [ "$MAX_SEVERITY" -eq 1 ]
}

@test "CONN-1: a lost lookup plus a refused 443 connect to a bare address fires it, and D1 stays quiet" {
  reset_state; dns_and_443
  scan
  [[ " $(scan_rules)" == *" CONN-1 "* ]] || { echo "rules: $(scan_rules)"; return 1; }
  [[ " $(scan_rules)" != *" D1 "* ]]
}

@test "CONN-1: the same lost lookup with every connect answered is D1, as before" {
  reset_state; dns_and_443
  TCP_REACH_LINES=$'1.1.1.1:443|OK|20\n8.8.8.8:443|OK|22\n'
  scan
  [[ " $(scan_rules)" == *" D1 "* && " $(scan_rules)" != *" CONN-1 "* ]] || { echo "rules: $(scan_rules)"; return 1; }
}

@test "CONN-1: a hostname that failed to connect is not a refused connection (it needed DNS first)" {
  reset_state; dns_and_443
  TCP_REACH_LINES=$'1.1.1.1:443|OK|20\ngithub.com:443|FAIL\napple.com:443|FAIL\n'
  scan
  [[ " $(scan_rules)" == *" D1 "* && " $(scan_rules)" != *" CONN-1 "* ]] || { echo "rules: $(scan_rules)"; return 1; }
}

@test "CONN-1: lookups that all failed are D1/D2's, not an intermittent fault" {
  reset_state
  DNS_OK=0
  DNS_LINES=$'1.1.1.1|apple.com||FAIL\n8.8.8.8|apple.com||FAIL\n'
  TCP_REACH_LINES=$'1.1.1.1:443|FAIL\n'
  scan
  [[ " $(scan_rules)" != *" CONN-1 "* ]] || { echo "rules: $(scan_rules)"; return 1; }
}

@test "CONN-1: one resolver failing two different names is that resolver, not the path" {
  reset_state
  DNS_OK=0
  DNS_LINES=$'192.168.1.1|apple.com|1.2.3.4|OK\n1.1.1.1|apple.com||FAIL\n1.1.1.1|cloudflare.com||FAIL\n8.8.8.8|apple.com|1.2.3.4|OK\n'
  scan
  [[ " $(scan_rules)" != *" CONN-1 "* ]] || { echo "rules: $(scan_rules)"; return 1; }
}

@test "CONN-1: stays silent when ping to the router is lossy (G3 owns it)" {
  reset_state; flaky_dns_pair; GW_LOSS=15
  scan
  [[ " $(scan_rules)" != *" CONN-1 "* && " $(scan_rules)" == *" G3 "* ]] || { echo "rules: $(scan_rules)"; return 1; }
}

@test "CONN-1: stays silent when either internet leg is lossy (L2 owns it)" {
  reset_state; flaky_dns_pair; INET_LOSS=0 INET_LOSS_ALT=15
  scan
  [[ " $(scan_rules)" != *" CONN-1 "* && " $(scan_rules)" == *" L2 "* ]] || { echo "rules: $(scan_rules)"; return 1; }
}

@test "CONN-1: an internet leg that was never measured does not count against it (--quick)" {
  reset_state; flaky_dns_pair; INET_LOSS="" INET_LOSS_ALT=""
  scan
  [[ " $(scan_rules)" == *" CONN-1 "* ]] || { echo "rules: $(scan_rules)"; return 1; }
}

@test "CONN-1: an unmeasured gateway is not 'ping is clean'" {
  reset_state; flaky_dns_pair; GW_LOSS=""
  scan
  [[ " $(scan_rules)" != *" CONN-1 "* ]] || { echo "rules: $(scan_rules)"; return 1; }
}

@test "CONN-1: stays silent in an outage that P1/P2 own" {
  reset_state; flaky_dns_pair
  PUBLIC_OK=0 TCP_REACH_ANY_OK=0 INET_LOSS=100 INET_LOSS_ALT=100
  TCP_REACH_LINES=$'1.1.1.1:443|FAIL\n8.8.8.8:443|FAIL\n'
  scan
  [[ " $(scan_rules)" != *" CONN-1 "* ]] || { echo "rules: $(scan_rules)"; return 1; }
  [[ " $(scan_rules)" == *" P1 "* || " $(scan_rules)" == *" P2 "* ]] || { echo "rules: $(scan_rules)"; return 1; }
}

@test "CONN-1: stays silent under SOCK-1 and under a captive portal" {
  reset_state; flaky_dns_pair; DNS_LOCAL_FAIL=1
  scan
  [[ " $(scan_rules)" == *" SOCK-1 "* && " $(scan_rules)" != *" CONN-1 "* ]] || { echo "rules: $(scan_rules)"; return 1; }
  reset_state; flaky_dns_pair; CAPTIVE_PORTAL=1 PUBLIC_OK=1
  scan
  [[ " $(scan_rules)" == *" CP-1 "* && " $(scan_rules)" != *" CONN-1 "* ]] || { echo "rules: $(scan_rules)"; return 1; }
}

@test "CONN-1: the prose says what was seen, names no cause nobody measured, and drops D1's remedy" {
  reset_state; dns_and_443
  scan
  local t; t="$(diag_text_for CONN-1)"
  [[ "$t" == *"refused or dropped"* ]]
  [[ "$t" == *"pings"* ]]
  [[ "$t" == *"1 of 3 name lookups got no answer"* ]]
  [[ "$t" == *"1 of 2 direct connections to port 443"* ]]
  # The two sentences this finding replaces.
  [[ "$t" != *"flaky"* && "$t" != *"blocked"* && "$t" != *"firewall"* ]]
  [[ "$t" == *"did not find what is causing it"* ]]
}

@test "CONN-1: names the app that holds the flood, and offers exactly the existing quit-app repair" {
  reset_state; flaky_dns_pair; stub_flood
  scan
  local t; t="$(diag_text_for CONN-1)"
  [[ "$t" == *"Stremio has 277 connections open or still trying to connect"* ]] || { echo "$t"; return 1; }
  [[ "$t" == *"quitting Stremio is a quick way to find out whether it is the cause"* ]]
  [[ "$t" == *"67 connections from node stuck waiting"* ]]
  [[ "$REPAIR_OFFERS" == CONN-1$'\x1f'quit-app$'\x1f'"Quit Stremio"$'\x1f'* ]] || { printf '%s\n' "$REPAIR_OFFERS"; return 1; }
  [[ "$REPAIR_OFFERS" == *"bundle_id=com.stremio.app"* ]]
}

@test "CONN-1: offers no repair and names nothing when no visible app holds a flood" {
  reset_state; flaky_dns_pair
  netstat() { printf 'udp4 0 0 *.1 *.*\n'; }
  lsof() { printf 'COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\n'; }
  scan
  local t; t="$(diag_text_for CONN-1)"
  [[ "$t" == *"restarting your router"* ]]
  [ -z "$REPAIR_OFFERS" ]
}

@test "CONN-1: a holder below the absolute floor is a busy app, not a culprit" {
  # Chrome holds nearly every socket here, but a handful is not a flood.
  reset_state; flaky_dns_pair
  netstat() { case "$*" in *udp*) printf 'udp4 0 0 *.1 *.*\nudp4 0 0 *.2 *.*\nudp4 0 0 *.3 *.*\n' ;; esac; }
  lsof() {
    printf 'COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\n'
    case "$*" in *UDP*) for i in 1 2 3; do printf 'Chrome 900 me %su IPv4 0x1 0t0 UDP *:%s\n' "$i" "$i"; done ;; esac
  }
  lsappinfo() { printf '"CFBundleIdentifier"="com.google.Chrome"\n"LSDisplayName"="Chrome"\n"ApplicationType"="Foreground"\n'; }
  scan
  [[ "$(diag_text_for CONN-1)" != *"Chrome"* ]]
  [ -z "$REPAIR_OFFERS" ]
}

@test "CONN-1: a big holder with a small share of everything is not named either" {
  reset_state; flaky_dns_pair; stub_flood
  netstat() {
    case "$*" in
      *udp*) for i in $(seq 1 2000); do printf 'udp4 0 0 *.%s *.*\n' "$i"; done ;;
      *tcp*) printf 'tcp4 0 0 10.0.0.5.1 1.2.3.4.6881 SYN_SENT\n' ;;
    esac
  }
  scan
  [[ "$(diag_text_for CONN-1)" != *"Stremio"* ]]
  [ -z "$REPAIR_OFFERS" ]
}

@test "CONN-1: the process lists are gathered only once it fires, never on a healthy scan" {
  reset_state
  conn_capture_holder_evidence() { : >"$BATS_TEST_TMPDIR/lsof.ran"; }
  scan
  [ ! -e "$BATS_TEST_TMPDIR/lsof.ran" ]
  reset_state; dns_and_443
  scan
  [ -e "$BATS_TEST_TMPDIR/lsof.ran" ]
}

@test "conn_capture_holder_evidence: counts UDP sockets and SYN_SENT per process, and resolves the app through its parent" {
  stub_flood
  conn_capture_holder_evidence
  [ "$CONN_FLOWS_TOTAL" -eq 310 ]
  [ "$(printf '%s\n' "$CONN_HOLDERS" | head -1)" = "node|48834|277|67" ]
  [ "$(printf '%s\n' "$CONN_HOLDERS" | sed -n 2p)" = "Google Chrome|900|3|0" ]
  [ "$CONN_HOLDER_TOP_SHARE_PCT" -eq 89 ]
  [ "$CONN_HOLDER_APP_BUNDLE" = com.stremio.app ]
  [ "$CONN_HOLDER_APP_NAME" = Stremio ]
}

@test "dns_resolve_app_by_path: a bundled helper whose parent is gone resolves through the .app it lives in" {
  local stremio_app="$BATS_TEST_TMPDIR/Stremio.app"
  mkdir -p "$stremio_app/Contents/MacOS"
  printf 'x' >"$stremio_app/Contents/Info.plist"
  ps() { printf '%s\n' "$stremio_app/Contents/MacOS/node"; }
  plutil() {
    case "$2" in
      CFBundleIdentifier)  printf 'com.stremio.app' ;;
      CFBundleDisplayName) printf 'Stremio' ;;
      *) return 1 ;;
    esac
  }
  lsappinfo() { printf 'ASN:0x0-0x1234:\n'; }
  run dns_resolve_app_by_path 48834
  [ "$status" -eq 0 ]
  [ "$output" = "com.stremio.app|Stremio" ]
  # An app that is not running is not something to offer to quit.
  lsappinfo() { :; }
  run dns_resolve_app_by_path 48834
  [ "$status" -eq 1 ]
  # Nor is a plain executable.
  ps() { printf '/usr/bin/node\n'; }
  run dns_resolve_app_by_path 48834
  [ "$status" -eq 1 ]
}

@test "dns_resolve_gui_app: falls back to the bundle path when the parent walk finds no app" {
  lsappinfo() { printf '"CFBundleIdentifier"=[ NULL ]\n"ApplicationType"=[ NULL ]\n'; }
  ps() { case "$*" in *ppid*) echo "   1" ;; *) echo "/opt/tool" ;; esac; }
  run dns_resolve_gui_app 4242
  [ "$status" -eq 1 ]
}

@test "conn_dns_lines_facts and conn_tcp_reach_facts: the counts the rule reads" {
  reset_state; flaky_dns_pair
  [ "$(conn_dns_lines_facts "$DNS_LINES")" = "6 2 4 1" ]
  [ "$(conn_dns_lines_facts "")" = "0 0 0 0" ]
  [ "$(conn_tcp_reach_facts $'1.1.1.1:443|FAIL\n8.8.8.8:443|OK|2\n1.1.1.1:53|FAIL\ngithub.com:443|FAIL\n')" = "1 2" ]
}

# ── The monitor ───────────────────────────────────────────────────────────

@test "monitor: one failed sample holds CONN-1 and D1 back and asks for a quick re-probe" {
  reset_state; MON_DNS_OK=0 MON_DNS_ALT_OK=0 MON_TCP_OK=0 MON_TCP_LINES=$'1.1.1.1|443|0|\n8.8.8.8|443|0|\n'
  _mon_rules
  [ -z "$MON_RULES" ]
  [ "$MON_CONN_PENDING" -eq 1 ]
}

@test "monitor: two consecutive failed samples fire CONN-1 as a warn, with no D1 beside it" {
  reset_state; MON_DNS_OK=0 MON_DNS_ALT_OK=0 MON_TCP_OK=0 MON_TCP_LINES=$'1.1.1.1|443|0|\n8.8.8.8|443|0|\n'
  _mon_rules
  _mon_rules
  [ "$MON_RULES" = "CONN-1 " ]
  [ "$MON_SEVERITY" = warn ]
  [ "$MON_DEGRADED" -eq 1 ]
  [ "$MON_CONN_PENDING" -eq 0 ]
}

@test "monitor: a lookup that fails in one sample and a connect in the next together fire CONN-1" {
  reset_state; MON_DNS_OK=0 MON_TCP_OK=1 MON_TCP_LINES=$'1.1.1.1|443|1|20\n8.8.8.8|443|1|22\n'
  _mon_rules
  MON_DNS_OK=1 MON_TCP_OK=1 MON_TCP_LINES=$'1.1.1.1|443|0|\n8.8.8.8|443|1|22\n'
  [ "$(monitor_rules)" = "CONN-1 " ]
}

@test "monitor: a lookup failing alone for two samples is D1, never CONN-1" {
  reset_state; MON_DNS_OK=0 MON_DNS_ALT_OK=1
  _mon_rules
  [ -z "$MON_RULES" ]
  [ "$(monitor_rules)" = "D1 " ]
}

@test "monitor: two resolvers silent at once with every connect answered is CONN-1, not D1" {
  reset_state; MON_DNS_OK=0 MON_DNS_ALT_OK=0
  _mon_rules
  [ "$(monitor_rules)" = "CONN-1 " ]
}

@test "monitor: a clean sample resets a streak that has not confirmed yet" {
  reset_state; MON_DNS_OK=0 MON_DNS_ALT_OK=0
  _mon_rules
  MON_DNS_OK=1 MON_DNS_ALT_OK=""
  _mon_rules
  MON_DNS_OK=0 MON_DNS_ALT_OK=0
  [ -z "$(monitor_rules)" ]
}

@test "monitor: a cycle with no fresh DNS/TCP sample cannot confirm a failure by repeating it" {
  reset_state; MON_DNS_OK=0 MON_DNS_ALT_OK=0
  _mon_rules
  MON_MEDIUM_FRESH=0
  [ -z "$(monitor_rules)" ]
  [ -z "$(monitor_rules)" ]
}

@test "monitor: once confirmed CONN-1 survives stale cycles and one clean sample, and clears after the same number of clean ones" {
  reset_state; MON_DNS_OK=0 MON_DNS_ALT_OK=0
  _mon_rules; _mon_rules
  [[ " $MON_RULES " == *" CONN-1 "* ]]
  MON_MEDIUM_FRESH=0
  _mon_rules; [ "$MON_RULES" = "CONN-1 " ]
  MON_MEDIUM_FRESH=1 MON_DNS_OK=1 MON_DNS_ALT_OK=""
  _mon_rules; [ "$MON_RULES" = "CONN-1 " ]
  _mon_rules; [ -z "$MON_RULES" ]
  [[ " $MON_CLEARABLE_RULES " == *" CONN-1 "* ]]
}

@test "monitor: CONN-1 does not fire while ping is lossy, captive, SOCK-1 or an outage owns the symptom" {
  reset_state; MON_DNS_OK=0 MON_DNS_ALT_OK=0
  _mon_rules
  MON_GW_LOSS=15
  [[ " $(monitor_rules)" != *" CONN-1 "* ]]
  MON_GW_LOSS=0 MON_INET_LOSS=30 MON_INET_LOSS_ALT=0
  [[ " $(monitor_rules)" != *" CONN-1 "* ]]
  MON_INET_LOSS="" MON_INET_LOSS_ALT="" MON_CAPTIVE=1
  [[ " $(monitor_rules)" != *" CONN-1 "* ]]
  MON_CAPTIVE=0 MON_DNS_LOCAL_FAIL=1
  [[ " $(monitor_rules)" != *" CONN-1 "* ]]
  MON_DNS_LOCAL_FAIL="" MON_TCP_OK=0 MON_WEB_OK=0 MON_PUBLIC_OK=0 MON_INET_LOSS=100 MON_INET_LOSS_ALT=100
  [[ " $(monitor_rules)" != *" CONN-1 "* ]]
}

@test "monitor: a D1 carried over from before is withdrawn the moment CONN-1 takes the symptom over" {
  reset_state; MON_DNS_OK=0 MON_DNS_ALT_OK=0 MON_PREV_RULES="D1 "
  _mon_rules; _mon_rules
  [[ " $MON_RULES " == *" CONN-1 "* && " $MON_RULES " != *" D1 "* ]]
  [[ " $MON_CLEARABLE_RULES " == *" D1 "* ]]
}

@test "monitor: an unmeasured DNS result does not clear CONN-1" {
  reset_state; MON_DNS_OK=0 MON_DNS_ALT_OK=0
  _mon_rules; _mon_rules
  MON_DNS_OK=""
  _mon_rules
  [[ " $MON_CLEARABLE_RULES " != *" CONN-1 "* ]]
}

@test "monitor: a link drop or a new network forgets the streak" {
  reset_state; MON_DNS_OK=0 MON_DNS_ALT_OK=0
  _mon_rules
  MON_LINK_UP=0
  _mon_rules
  [ "$MON_CONN_STREAK" -eq 0 ]
  MON_LINK_UP=1
  [ -z "$(monitor_rules)" ]
}

@test "monitor: _mon_probe_dns asks a second, unrelated resolver only after the first goes unanswered" {
  MON_LINK_UP=1
  HELPERS_DIR="$BATS_TEST_TMPDIR/helpers"; mkdir -p "$HELPERS_DIR"
  printf '#!/usr/bin/env python3\nprint("ok")\n' >"$HELPERS_DIR/sockcheck.py"
  scutil() { printf 'nameserver[0] : 192.168.1.1\n'; }
  dig() { printf '%s\n' "$*" >>"$BATS_TEST_TMPDIR/dig.calls"; case "$*" in *@192.168.1.1*) ;; *) printf '1.2.3.4\n' ;; esac; }
  rm -f "$BATS_TEST_TMPDIR/dig.calls"
  _mon_probe_dns
  [ "$MON_DNS_OK" = 0 ] && [ "$MON_DNS_ALT_OK" = 1 ]
  grep -q '@1.1.1.1' "$BATS_TEST_TMPDIR/dig.calls"
  # Healthy: one question, no second.
  dig() { printf '%s\n' "$*" >>"$BATS_TEST_TMPDIR/dig.calls"; printf '1.2.3.4\n'; }
  rm -f "$BATS_TEST_TMPDIR/dig.calls"
  _mon_probe_dns
  [ "$MON_DNS_OK" = 1 ] && [ -z "$MON_DNS_ALT_OK" ]
  [ "$(wc -l <"$BATS_TEST_TMPDIR/dig.calls" | tr -d ' ')" -eq 1 ]
  # The first resolver being 1.1.1.1, the second must be a different one.
  scutil() { printf 'nameserver[0] : 1.1.1.1\n'; }
  dig() { printf '%s\n' "$*" >>"$BATS_TEST_TMPDIR/dig.calls"; case "$*" in *@1.1.1.1*) ;; *) printf '1.2.3.4\n' ;; esac; }
  rm -f "$BATS_TEST_TMPDIR/dig.calls"
  _mon_probe_dns
  grep -q '@8.8.8.8' "$BATS_TEST_TMPDIR/dig.calls"
}

@test "monitor_run re-probes at the fast cadence while a failure waits for confirmation" {
  run grep -n 'MON_CONN_PENDING" -eq 1 \]; then next_medium=0' "$REPO/lib/monitor.sh"
  [ "$status" -eq 0 ]
}

# ── Scan and monitor agree ────────────────────────────────────────────────

@test "parity: lookups and connects failing together over clean pings are CONN-1 on both, never D1" {
  reset_state; dns_and_443
  MON_DNS_OK=0 MON_DNS_ALT_OK=1 MON_TCP_OK=0 MON_TCP_LINES=$'1.1.1.1|443|0|\n8.8.8.8|443|1|22\n'
  _mon_rules
  local m s; m="$(monitor_rules)"
  scan
  s="$(printf '%s\n' "${DIAG_RULE[@]}" | grep -E '^(CONN-1|D1|P1|P2|G3|L2)$' | sort | tr '\n' ' ')"
  [ "$m" = "$s" ]
  [ "$m" = "CONN-1 " ]
}

@test "parity: ping loss turns both engines back to the loss rules" {
  reset_state; dns_and_443; GW_LOSS=15
  MON_GW_LOSS=15 MON_DNS_OK=0 MON_DNS_ALT_OK=1 MON_TCP_OK=0 MON_TCP_LINES=$'1.1.1.1|443|0|\n'
  _mon_rules
  local m s; m="$(monitor_rules)"
  scan
  s="$(printf '%s\n' "${DIAG_RULE[@]}" | grep -E '^(CONN-1|D1|P1|P2|G3|L2)$' | sort | tr '\n' ' ')"
  [[ "$m" != *CONN-1* && "$s" != *CONN-1* ]]
  [[ "$m" == *G3* && "$s" == *G3* ]]
}

@test "the monitor's CONN-1 and D1 waits use the named threshold, not a literal" {
  run grep -nE 'MON_(CONN|DNS)_STREAK.*-(ge|gt|lt) [1-9]' "$REPO/lib/monitor.sh"
  [ "$status" -ne 0 ] || { echo "$output"; return 1; }
  grep -q 'THRESH_MON_CONN_CONFIRM_CYCLES' "$REPO/lib/monitor.sh"
}
