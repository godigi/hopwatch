#!/usr/bin/env bats
# tests/test_sock_and_dns_guidance.bats — SOCK-1 (this Mac cannot open a UDP
# socket) and D6 (guided switch to a better DNS).
#
# docs/design/2026-10-07-local-socket-failure-and-dns-guidance-design.md
#
# 2026-10-07: every UDP dig failed with "isc_socket_bind: address not
# available" (ephemeral-port exhaustion). dig's stderr was discarded and an
# empty answer read as "the resolver did not answer", so D1 told the user to
# restart a router that was fine. The SOCK-1 tests pin both halves: the
# local fault is named and the router rules go quiet, and a merely silent
# resolver still gets the old verdict (no regression).
#
# Same mechanism as tests/test_dns.bats: lib/dns.sh is sourced and dig,
# scutil and with_timeout are shell functions. helpers/sockcheck.py is
# stubbed the way every helper is located -- through HELPERS_DIR.

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  JSON_MODE=0 QUIET=0 QUICK=0 EXPERT=0 LOG=/dev/null
  . "$REPO/lib/thresholds.sh"
  . "$REPO/lib/common.sh"
  . "$REPO/lib/globals.sh"
  . "$REPO/lib/traffic.sh"
  . "$REPO/lib/diagnosis.sh"
}

dns_baseline() {
  GATEWAY=192.168.1.1
  GW_LOSS=0 GW_LATENCY=2.5 GW_JITTER=0.3
  PUBLIC_OK=1 PUBLIC_CHECKED=1
  DNS_OK=1 DNS_LINES="192.168.1.1|apple.com|17.253.144.10|OK"$'\n'
  INET_LOSS=0 INET_LOSS_ALT=0
  IS_WIFI=1
  TCP_REACH_ANY_OK=1
  WIFI_SSID="HomeNet"
  WIFI_RSSI=-50
  WIFI_SNR=35
  WIFI_TX=866
  DNS_PRIMARY_FAIL=0
  DNS_FALLBACK_OK=0
  PRIMARY_DNS=""
  SECONDARY_DNS=""
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
}

diag_has() {
  local rule="$1" r
  for r in "${DIAG_RULE[@]}"; do [ "$r" = "$rule" ] && return 0; done
  return 1
}

diag_text_for() {
  local rule="$1" i
  for i in "${!DIAG_RULE[@]}"; do
    if [ "${DIAG_RULE[$i]}" = "$rule" ]; then printf '%s\n' "${DIAG[$i]}"; return 0; fi
  done
  return 1
}

diag_sev_for() {
  local rule="$1" i
  for i in "${!DIAG_RULE[@]}"; do
    if [ "${DIAG_RULE[$i]}" = "$rule" ]; then printf '%s\n' "${DIAG_SEV[$i]}"; return 0; fi
  done
  return 1
}

assert_contains() {
  case "$1" in (*"$2"*) return 0 ;; *) echo "expected '$1' to contain '$2'" >&2; return 1 ;; esac
}

# A stand-in for helpers/sockcheck.py. $1 is what it prints. Every call is
# recorded so a test can prove the healthy path never makes one.
stub_sockcheck() {
  HELPERS_DIR="$BATS_TEST_TMPDIR/helpers"
  mkdir -p "$HELPERS_DIR"
  rm -f "$BATS_TEST_TMPDIR/sockcheck.calls"
  cat >"$HELPERS_DIR/sockcheck.py" <<PY
#!/usr/bin/env python3
open("$BATS_TEST_TMPDIR/sockcheck.calls", "a").write("called\n")
print("$1")
PY
}

# netstat / lsof as seen during the incident: one app holding nearly all of
# the UDP sockets. Only the shape matters to the parser.
stub_socket_census() {
  netstat() {
    local i
    for i in $(seq 1 20); do printf 'udp4 0 0 192.168.1.5.%s *.*\n' $((50000 + i)); done
  }
  if [ "${1:-visible}" = visible ]; then
    lsof() {
      printf 'COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\n'
      local i
      for i in $(seq 1 15); do printf 'Chatty\\x20App 4242 me %su IPv4 0x1 0t0 UDP *:%s\n' "$i" $((50000 + i)); done
      printf 'rapportd 646 me 22u IPv6 0x2 0t0 UDP *:3722\n'
    }
    # SOCK-1 names an app only when lsappinfo says the holder is a regular
    # GUI app the user can quit (dns_resolve_gui_app); lsof's process name
    # alone is not enough to ask anything to quit.
    lsappinfo() {
      case "$*" in
        *" 4242") printf '"CFBundleIdentifier"="com.example.chatty"\n"LSDisplayName"="Chatty App"\n"ApplicationType"="Foreground"\n' ;;
        *)        printf '"CFBundleIdentifier"=[ NULL ]\n"ApplicationType"=[ NULL ]\n' ;;
      esac
    }
    ps() { echo "   1"; }
  else
    lsof() { printf 'COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\n'; }
  fi
}

# Common stubs for dns_run: one configured resolver, no real commands.
stub_dns_world() {
  TARGET=""
  DNS_OK=0 DNS_LINES=""
  scutil() { printf 'nameserver[0] : 192.168.1.1\n'; }
  with_timeout() { shift; "$@"; }
}

# ── SOCK-1 ───────────────────────────────────────────────────────────────

@test "SOCK-1: a refused UDP bind fires SOCK-1 and silences D1, D2, D5, V6-2 and D6" {
  dns_baseline
  . "$REPO/lib/dns.sh"
  stub_dns_world
  stub_sockcheck EADDRNOTAVAIL
  stub_socket_census visible
  dig() {
    case "$*" in
      *+tcp*) printf '104.16.132.229\n' ;;
      *) echo "dig: isc_socket_bind: address not available" >&2; return 10 ;;
    esac
  }
  dns_run >/dev/null || true
  [ "$DNS_LOCAL_FAIL" -eq 1 ]
  [ "$DNS_LOCAL_BIND" = EADDRNOTAVAIL ]
  [ "$DNS_UDP_SOCKETS" -eq 20 ]
  [ "$DNS_TCP_DNS_OK" -eq 1 ]
  # The top holder, with its \x20 decoded and its count.
  [ "$(printf '%s\n' "$DNS_UDP_HOLDERS" | head -1)" = "Chatty App|4242|15" ]
  # ...and the app behind it, which is what a repair is addressed to.
  [ "$DNS_UDP_TOP_APP_BUNDLE" = com.example.chatty ]
  [ "$DNS_UDP_TOP_APP_NAME" = "Chatty App" ]
  # Make every router rule's own trigger true, to prove suppression and not
  # a missing input.
  IPV6_DNS_FAIL="fe80::1" DNS_FALLBACK_OK=1 SECONDARY_DNS=8.8.8.8
  diagnosis_run >/dev/null
  diag_has SOCK-1 || { echo "rules: ${DIAG_RULE[*]}"; return 1; }
  [ "$(diag_sev_for SOCK-1)" = critical ]
  for r in D1 D2 D5 D6 V6-2; do
    ! diag_has "$r" || { echo "$r fired alongside SOCK-1"; return 1; }
  done
  [ "$MAX_SEVERITY" -eq 2 ]
  local text; text="$(diag_text_for SOCK-1)"
  assert_contains "$text" "run out of room to make new network connections"
  assert_contains "$text" "restarting the router will not help"
  assert_contains "$text" "Quit Chatty App (it is holding 15 connections open), or restart this Mac"
  assert_contains "$text" "lookups over TCP still work"
}

@test "SOCK-1: no visible holder drops the 'quit' clause and says to restart the Mac" {
  dns_baseline
  . "$REPO/lib/dns.sh"
  stub_dns_world
  stub_sockcheck EADDRNOTAVAIL
  stub_socket_census none
  dig() { echo "dig: isc_socket_bind: address not available" >&2; return 10; }
  dns_run >/dev/null || true
  [ "$DNS_LOCAL_FAIL" -eq 1 ]
  diagnosis_run >/dev/null
  local text; text="$(diag_text_for SOCK-1)"
  assert_contains "$text" "Restart this Mac."
  [[ "$text" != *"Quit "* ]] || { echo "named an app with no holder visible: $text"; return 1; }
}

@test "SOCK-1: a small holder is not named as the culprit" {
  dns_baseline
  DNS_LOCAL_FAIL=1 DNS_LOCAL_BIND=EADDRNOTAVAIL DNS_UDP_SOCKETS=16000
  DNS_UDP_HOLDERS="Safari|900|12"$'\n' DNS_UDP_TOP_SHARE_PCT=0
  diagnosis_run >/dev/null
  local text; text="$(diag_text_for SOCK-1)"
  [[ "$text" != *"Safari"* ]] || { echo "blamed a busy app: $text"; return 1; }
  assert_contains "$text" "Restart this Mac."
}

@test "SOCK-1: dig's own bind error is enough when the helper says the bind is fine" {
  dns_baseline
  . "$REPO/lib/dns.sh"
  stub_dns_world
  stub_sockcheck ok
  stub_socket_census none
  dig() { echo "dig: isc_socket_bind: address not available" >&2; return 10; }
  dns_run >/dev/null || true
  [ "$DNS_LOCAL_FAIL" -eq 1 ]
  [ "$DNS_LOCAL_BIND" = ok ]
  diagnosis_run >/dev/null
  diag_has SOCK-1
  ! diag_has D1
}

@test "SOCK-1: a silent resolver with a healthy bind is still D1, never SOCK-1" {
  dns_baseline
  . "$REPO/lib/dns.sh"
  stub_dns_world
  stub_sockcheck ok
  dig() { return 0; }
  dns_run >/dev/null || true
  [ "$DNS_LOCAL_FAIL" -eq 0 ]
  [ "$DNS_LOCAL_BIND" = ok ]
  diagnosis_run >/dev/null
  diag_has D1 || { echo "rules: ${DIAG_RULE[*]}"; return 1; }
  ! diag_has SOCK-1 || { echo "SOCK-1 fired on a healthy bind"; return 1; }
}

@test "SOCK-1: the healthy path never runs the socket check" {
  dns_baseline
  . "$REPO/lib/dns.sh"
  stub_dns_world
  stub_sockcheck EADDRNOTAVAIL
  dig() { printf '104.16.132.229\n'; }
  dns_run >/dev/null || true
  [ "$DNS_OK" -eq 1 ]
  [ "$DNS_LOCAL_FAIL" -eq 0 ]
  [ -z "$DNS_LOCAL_BIND" ]
  [ ! -e "$BATS_TEST_TMPDIR/sockcheck.calls" ] || { echo "sockcheck ran on the healthy path"; return 1; }
}

@test "SOCK-1: the bind is checked once however many probes fail" {
  dns_baseline
  . "$REPO/lib/dns.sh"
  stub_dns_world
  stub_sockcheck ok
  dig() { return 0; }
  dns_run >/dev/null || true
  [ "$(wc -l <"$BATS_TEST_TMPDIR/sockcheck.calls")" -eq 1 ]
}

@test "SOCK-1: a helper that cannot run is not evidence of a fault" {
  dns_baseline
  . "$REPO/lib/dns.sh"
  stub_dns_world
  stub_sockcheck error
  dig() { return 0; }
  dns_run >/dev/null || true
  [ "$DNS_LOCAL_FAIL" -eq 0 ]
  HELPERS_DIR="$BATS_TEST_TMPDIR/nowhere"
  dns_run >/dev/null || true
  [ "$DNS_LOCAL_FAIL" -eq 0 ]
  [ "$DNS_LOCAL_BIND" = unavailable ]
}

@test "dns_probe: dig's 'connection timed out' line on stdout is not an answer" {
  # BIND 9.10's `+short` prints that sentence on stdout, so a resolver that
  # never answered used to be recorded as having answered with it.
  stub_sockcheck ok
  with_timeout() { shift; "$@"; }
  dig() { printf ';; connection timed out; no servers could be reached\n'; return 9; }
  dns_local_reset
  ! dns_probe 192.0.2.1 apple.com
  [ -z "$DNS_PROBE_ANSWER" ]
}

@test "sockcheck.py: ok on a machine that can bind, an errno name when the kernel refuses" {
  run python3 "$REPO/helpers/sockcheck.py"
  [ "$status" -eq 0 ]
  [ "$output" = ok ]
  run python3 -c "
import errno, sys
sys.path.insert(0, '$REPO/helpers')
import sockcheck
class Refuses:
    def __init__(self, *a): pass
    def bind(self, addr): raise OSError(errno.EADDRNOTAVAIL, 'Can not assign requested address')
    def close(self): pass
assert sockcheck.check(Refuses) == 'EADDRNOTAVAIL'
def no_socket(*a): raise OSError(errno.EMFILE, 'Too many open files')
assert sockcheck.check(no_socket) == 'EMFILE'
"
  [ "$status" -eq 0 ]
}

@test "dns_local in --json: null when never checked, the evidence when there was a fault" {
  run env -i PATH="$PATH" python3 -c "
import sys
sys.path.insert(0, '$REPO/helpers')
import emit_json
assert emit_json.build_dns_local() is None
"
  [ "$status" -eq 0 ]
  run env -i PATH="$PATH" NETDIAG_DNS_LOCAL_BIND=EADDRNOTAVAIL NETDIAG_DNS_LOCAL_FAIL=1 \
    NETDIAG_DNS_UDP_SOCKETS=16000 NETDIAG_DNS_UDP_TOP_SHARE_PCT=93 NETDIAG_DNS_TCP_DNS_OK=1 \
    NETDIAG_DNS_UDP_HOLDERS="Chatty App|4242|15000"$'\n'"rapportd|646|3" \
    python3 -c "
import sys
sys.path.insert(0, '$REPO/helpers')
import emit_json
d = emit_json.build_dns_local()
assert d['fault'] is True and d['udp_bind'] == 'EADDRNOTAVAIL', d
assert d['udp_sockets'] == 16000 and d['tcp_dns_ok'] is True, d
assert d['top_holders'][0] == {'process': 'Chatty App', 'pid': 4242, 'sockets': 15000}, d
assert d['top_holder_share_pct'] == 93, d
"
  [ "$status" -eq 0 ]
  # Checked and fine: the bind is reported, the evidence is not invented.
  run env -i PATH="$PATH" NETDIAG_DNS_LOCAL_BIND=ok NETDIAG_DNS_LOCAL_FAIL=0 \
    python3 -c "
import sys
sys.path.insert(0, '$REPO/helpers')
import emit_json
d = emit_json.build_dns_local()
assert d['fault'] is False and d['udp_bind'] == 'ok', d
assert d['udp_sockets'] is None and d['top_holders'] is None and d['tcp_dns_ok'] is None, d
"
  [ "$status" -eq 0 ]
}

# ── D6 ───────────────────────────────────────────────────────────────────

@test "D6: the router's resolver fails, a public one answers, the bind is healthy -> D6 fires" {
  dns_baseline
  . "$REPO/lib/dns.sh"
  stub_dns_world
  stub_sockcheck ok
  DHCP_DNS_SERVERS=192.168.1.1
  dig() {
    case "$*" in
      *@1.1.1.1*|*@8.8.8.8*) printf '203.0.113.10\n' ;;
    esac
  }
  dns_run >/dev/null || true
  [ "$DNS_PRIMARY_FAIL" -eq 1 ]
  [ "$DNS_LOCAL_FAIL" -eq 0 ]
  diagnosis_run >/dev/null
  diag_has D6 || { echo "rules: ${DIAG_RULE[*]}"; return 1; }
  [ "$(diag_sev_for D6)" = info ]
  ! diag_has SOCK-1
  local text; text="$(diag_text_for D6)"
  assert_contains "$text" "phone book"
  assert_contains "$text" "(192.168.1.1) is not answering"
  # Plain public DNS is the fix; encrypted DNS is only an optional note after it.
  local plain="${text%%add 1.1.1.1 and 8.8.8.8*}" enc="${text%%Secure DNS*}"
  [ "${#plain}" -lt "${#enc}" ] || { echo "public DNS must come before the Secure DNS note"; return 1; }
  assert_contains "$text" "optional extra"
  assert_contains "$text" "1.1.1.1 and 8.8.8.8"
  assert_contains "$text" "NOT encrypted"
  # Every downside the audience will not know.
  assert_contains "$text" "sign-in page may not appear"
  assert_contains "$text" "router.lan"
  assert_contains "$text" "block outside DNS entirely"
  assert_contains "$text" "every Wi-Fi network you join"
  assert_contains "$text" "parental or content filter"
  assert_contains "$text" "To undo it"
  assert_contains "$text" "never changes these settings"
}

@test "D6: it carries the only remedy -- D1 still fires but stops at its observation" {
  dns_baseline
  DNS_OK=0 DNS_PRIMARY_FAIL=1 PRIMARY_DNS=192.168.1.1
  SYS_RES=192.168.1.1 SYS_RES_ALL=192.168.1.1 DHCP_DNS_SERVERS=192.168.1.1
  DNS_LINES="192.168.1.1|apple.com||FAIL"$'\n'"1.1.1.1|apple.com|17.253.144.10|OK"$'\n'
  diagnosis_run >/dev/null
  diag_has D6
  diag_has D1
  local d1; d1="$(diag_text_for D1)"
  [[ "$d1" != *"Restart your router"* ]] || { echo "D1 still carries a remedy: $d1"; return 1; }
  assert_contains "$(diag_text_for D6)" "Restarting your router is worth trying first"
}

@test "D6: without D6, D1 keeps its own remedy" {
  dns_baseline
  DNS_OK=0 DNS_PRIMARY_FAIL=0
  DNS_LINES="1.1.1.1|apple.com||FAIL"$'\n'"1.1.1.1|cloudflare.com|104.16.132.229|OK"$'\n'
  diagnosis_run >/dev/null
  ! diag_has D6
  assert_contains "$(diag_text_for D1)" "Restart your router"
}

@test "D6: a slow router resolver fires it, using D3's own cutoff" {
  dns_baseline
  SYS_RES=192.168.1.1 SYS_RES_ALL=192.168.1.1 DHCP_DNS_SERVERS=192.168.1.1
  DNS_LINES="192.168.1.1|apple.com|17.253.144.10|OK"$'\n'"8.8.8.8|apple.com|17.253.144.10|OK"$'\n'
  SYS_RES_MS=$((THRESH_DNS_LATENCY_WARN_MS + 1))
  diagnosis_run >/dev/null
  diag_has D3 || { echo "rules: ${DIAG_RULE[*]}"; return 1; }
  diag_has D6 || { echo "rules: ${DIAG_RULE[*]}"; return 1; }
  assert_contains "$(diag_text_for D6)" "is very slow to answer ($((THRESH_DNS_LATENCY_WARN_MS + 1)) ms)"
  [[ "$(diag_text_for D3)" != *"Restart your router"* ]]
  # At the cutoff exactly, D3 stays silent and so does D6.
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  SYS_RES_MS="$THRESH_DNS_LATENCY_WARN_MS"
  diagnosis_run >/dev/null
  ! diag_has D3
  ! diag_has D6
}

@test "D6: a manual-override resolver is the user's own choice -- no D6" {
  dns_baseline
  # DHCP offered the router; the Mac is using something else.
  DHCP_DNS_SERVERS=192.168.1.1 SYS_RES=10.9.9.9 SYS_RES_ALL=10.9.9.9
  DNS_OK=0 DNS_PRIMARY_FAIL=1 PRIMARY_DNS=10.9.9.9
  DNS_LINES="10.9.9.9|apple.com||FAIL"$'\n'"1.1.1.1|apple.com|17.253.144.10|OK"$'\n'
  dns_is_manual_override "$DHCP_DNS_SERVERS" "$SYS_RES_ALL"
  diagnosis_run >/dev/null
  ! diag_has D6 || { echo "D6 fired on a manual override"; return 1; }
  diag_has DH-2
  diag_has D1
}

@test "D6: not when the resolver in use is already a public one" {
  dns_baseline
  SYS_RES=9.9.9.9 SYS_RES_ALL=9.9.9.9 DHCP_DNS_SERVERS=""
  DNS_OK=0 DNS_PRIMARY_FAIL=1 PRIMARY_DNS=9.9.9.9
  DNS_LINES="9.9.9.9|apple.com||FAIL"$'\n'"1.1.1.1|apple.com|17.253.144.10|OK"$'\n'
  diagnosis_run >/dev/null
  ! diag_has D6
}

@test "D6: not when an encrypted DNS profile is active" {
  dns_baseline
  PATH_ENCRYPTED_DNS=1 PATH_ENCRYPTED_DNS_SERVER="https://cloudflare-dns.com/dns-query"
  DNS_OK=0 DNS_PRIMARY_FAIL=1 PRIMARY_DNS=192.168.1.1
  SYS_RES=192.168.1.1 SYS_RES_ALL=192.168.1.1 DHCP_DNS_SERVERS=192.168.1.1
  DNS_LINES="192.168.1.1|apple.com||FAIL"$'\n'"1.1.1.1|apple.com|17.253.144.10|OK"$'\n'
  diagnosis_run >/dev/null
  ! diag_has D6
  diag_has EDNS-1
}

@test "D6: not when no public resolver answered -- nothing better is proven" {
  dns_baseline
  DNS_OK=0 DNS_PRIMARY_FAIL=1 PRIMARY_DNS=192.168.1.1
  SYS_RES=192.168.1.1 SYS_RES_ALL=192.168.1.1 DHCP_DNS_SERVERS=192.168.1.1
  DNS_LINES="192.168.1.1|apple.com||FAIL"$'\n'"1.1.1.1|apple.com||FAIL"$'\n'
  diagnosis_run >/dev/null
  ! diag_has D6
}

@test "D6 and SOCK-1 never fire together, even when every other input says D6" {
  dns_baseline
  DNS_LOCAL_FAIL=1 DNS_LOCAL_BIND=EADDRNOTAVAIL
  DNS_OK=0 DNS_PRIMARY_FAIL=1 PRIMARY_DNS=192.168.1.1
  SYS_RES=192.168.1.1 SYS_RES_ALL=192.168.1.1 DHCP_DNS_SERVERS=192.168.1.1
  DNS_LINES="192.168.1.1|apple.com||FAIL"$'\n'"1.1.1.1|apple.com|17.253.144.10|OK"$'\n'
  diagnosis_run >/dev/null
  diag_has SOCK-1
  ! diag_has D6
  ! diag_has D1
}
