#!/usr/bin/env bats
#
# HOG-1 — one app on this Mac is using up the connection.
#
# What these tests hold: the finding names an app and offers the existing
# Quit button only when the evidence supports it; it stays silent on a big
# upload that costs nothing, on Hopwatch's own traffic (a full check
# saturates the link on purpose), on a system daemon, on several apps
# sharing the link and on any failure of the evidence source; the monitor
# confirms before spending a capture; and the monitor and the scan agree.
#
# Network-free. `nettop` is a stub that prints a fixture, `ps` is the real
# one, so process ancestry is exercised against real processes: a child of
# the test (Hopwatch's own, by descent) and a double-forked orphan (someone
# else's, re-parented to launchd). What is NOT covered here is a real app
# saturating a real link; see the design note.

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  HELPERS="$REPO/helpers"
  HELPERS_DIR="$HELPERS"
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

  STUBS="$BATS_TEST_TMPDIR/bin"; mkdir -p "$STUBS"
  NETTOP_OUT="$BATS_TEST_TMPDIR/nettop.out"
  NETTOP_CALLS="$BATS_TEST_TMPDIR/nettop.calls"
  export NETTOP_OUT NETTOP_CALLS
  : >"$NETTOP_CALLS"
  cat >"$STUBS/nettop" <<'EOF'
#!/bin/sh
echo called >>"$NETTOP_CALLS"
[ -n "$NETTOP_FAIL" ] && exit 1
cat "$NETTOP_OUT"
EOF
  chmod +x "$STUBS/nettop"
  PATH="$STUBS:$PATH"

  # Someone else's process: double-forked so it is re-parented to launchd and
  # is neither a descendant of this shell nor under a Hopwatch command line.
  OTHER="$( ( sleep 600 >/dev/null 2>&1 & echo $! ) )"
  OTHER2="$( ( sleep 600 >/dev/null 2>&1 & echo $! ) )"
  # Hopwatch's own: an ordinary child of this shell.
  sleep 600 >/dev/null 2>&1 &
  OWN=$!
  disown "$OWN" 2>/dev/null || true
  sleep 0.3
  APP_PID="$OTHER"
}

teardown() {
  kill "${OTHER:-}" "${OTHER2:-}" "${OWN:-}" ${EXTRA_PIDS:-} 2>/dev/null || true
}

# ── Fixtures and stubs ───────────────────────────────────────────────────

# make_nettop ROW...   ROW = "name|pid|up_mbps|down_mbps". A rate may be a
# comma list, one value per interval ("40,0": busy, then idle); the last
# value repeats. Three cumulative snapshots, as the real capture takes.
make_nettop() {
  : >"$NETTOP_OUT"
  local snap row name pid up down
  for snap in 0 1 2; do
    printf ',bytes_in,bytes_out,\n' >>"$NETTOP_OUT"
    for row in "$@"; do
      IFS='|' read -r name pid up down <<<"$row"
      awk -v s="$snap" -v n="$name" -v p="$pid" -v u="$up" -v d="$down" -v i="$THRESH_HOG_SAMPLE_S" '
        function cum(spec, upto,   a, c, k, t, r) {
          c = split(spec, a, ","); t = 0
          for (k = 1; k <= upto; k++) { r = (k <= c) ? a[k] : a[c]; t += r * 1000000 / 8 * i }
          return t
        }
        BEGIN { printf "%s.%d,%.0f,%.0f,\n", n, p, 5000000 + cum(d, s), 7000000 + cum(u, s) }' >>"$NETTOP_OUT"
    done
  done
}

# The resolver: only APP_PID belongs to a quittable GUI app.
stub_app() {
  dns_resolve_gui_app() {
    if [ "$1" = "$APP_PID" ]; then printf 'com.example.backup|Backup Pro'; return 0; fi
    return 1
  }
}
stub_no_app() { dns_resolve_gui_app() { return 1; }; }

nettop_calls() { wc -l <"$NETTOP_CALLS" | tr -d ' '; }

# A healthy baseline for both engines; each test perturbs what it studies.
reset_state() {
  MON_LINK_UP=1 MON_IFACE_TYPE=wifi MON_GATEWAY=192.168.1.1
  MON_GW_LOSS=0 MON_GW_RTT=3 MON_GW_JITTER=1 MON_INET_LOSS=0 MON_INET_LOSS_ALT=0
  MON_INET_RTT=20 MON_INET_JITTER=2
  MON_GW_HIST="" MON_INET_HIST="" MON_INET_HIST_ALT=""
  MON_WIFI_RSSI="" MON_WIFI_SNR=""
  MON_DNS_OK=1 MON_DNS_ALT_OK="" MON_TCP_OK=1 MON_TCP_LINES="" MON_PUBLIC_OK=1 MON_CAPTIVE=0
  MON_DNS_LOCAL_FAIL="" DNS_LOCAL_FAIL=0
  MON_WEB_OK="" MON_MEASUREMENT_STATE="unknown" MON_PREV_RULES=""
  MON_VPN_ACTIVE=0 MON_ICMP_FILTERED=0 MON_DEGRADED=0
  MON_GW_LOSS_STREAK=0 MON_INET_LOSS_STREAK=0 MON_MEDIUM_FRESH=1
  MON_REFRESHED="fast "
  _mon_conn_reset
  _mon_hog_reset
  MON_HOG_LAST_CAPTURE=0
  GATEWAY=192.168.1.1 IS_WIFI=1 GW_LOSS=0 GW_LATENCY=3 GW_JITTER=1 GW_RTT_MAX=5
  WIFI_RSSI="" WIFI_SNR=""
  INET_LOSS=0 INET_LOSS_ALT=0 INET_RTT_AVG=20 INET_RTT_JITTER=2
  DNS_OK=1 PUBLIC_OK=1 PUBLIC_CHECKED=1
  DNS_LINES=$'192.168.1.1|apple.com|1.2.3.4|OK\n1.1.1.1|apple.com|1.2.3.4|OK\n8.8.8.8|apple.com|1.2.3.4|OK\n'
  TCP_REACH_LINES=$'1.1.1.1:443|OK|20\n8.8.8.8:443|OK|22\ngithub.com:443|OK|30\n'
  TCP_REACH_ANY_OK=1 VPN_ACTIVE=0 CAPTIVE_PORTAL=0
  DNS_PRIMARY_FAIL=0 DNS_FALLBACK_OK=0 PRIMARY_DNS="" SECONDARY_DNS="" SYS_RES="192.168.1.1" SYS_RES_ALL="192.168.1.1"
  IPV6_AVAILABLE=0 MTU_EFFECTIVE="" MTR_FIRST_LOSSY_HOP=""
  NTP_DRIFT_S="" DHCP_TIME_REMAINING_S=""
  ARP_GW_INCOMPLETE=0 ARP_DUPLICATE_IPS="" DHCP_DNS_SERVERS=""
  WIFI_SCAN_CURRENT_CHANNEL_NEIGHBORS=0 WIFI_DISCONNECT_COUNT=0 WIFI_AWDL_ACTIVE=0
  BUFFERBLOAT_GW_GRADE="" BUFFERBLOAT_INET_GRADE=""
  SPEEDTEST_UP_MBPS="" SPEEDTEST_DOWN_MBPS=""
  TRAFFIC_MEASURED=0 TRAFFIC_UP_MBPS="" TRAFFIC_DOWN_MBPS="" TRAFFIC_TOP_NAME=""
  CONN_HOLDERS="" CONN_FLOWS_TOTAL="" CONN_HOLDER_TOP_SHARE_PCT="" CONN_HOLDER_APP_BUNDLE="" CONN_HOLDER_APP_NAME=""
  HOG_MEASURED=0 HOG_FIRES=0
  REPAIR_OFFERS=""
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  : >"$NETTOP_CALLS"; NETTOP_FAIL=""; export NETTOP_FAIL
}

# The router answers slowly while nothing is lost: the latency gate is open.
slow_pings() {
  GW_LATENCY=84 GW_JITTER=22
  MON_GW_RTT=84 MON_GW_JITTER=22
}

scan() {
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0; REPAIR_OFFERS=""
  diagnosis_run >/dev/null
}

scan_rules() { printf '%s ' "${DIAG_RULE[@]:-}"; }

has_rule() { [[ " $(scan_rules)" == *" $1 "* ]]; }

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

# ── The scan: it fires, and says what it measured ────────────────────────

@test "HOG-1: one app uploading hard while pings slow is one warn finding that names it and offers Quit" {
  reset_state; slow_pings; stub_app
  make_nettop "Backup Pro|$APP_PID|40|0.2" "mDNSResponder|534|0.01|0.02"
  scan
  has_rule HOG-1 || { echo "rules: $(scan_rules)"; return 1; }
  local i sev=""
  for i in "${!DIAG_RULE[@]}"; do [ "${DIAG_RULE[$i]}" = HOG-1 ] && sev="${DIAG_SEV[$i]}"; done
  [ "$sev" = warn ]
  local t; t="$(diag_text_for HOG-1)"
  [[ "$t" == "Backup Pro is uploading about 40 Mbps, which is most of what this Mac is sending, while pings to your router are taking about 84 ms."* ]] || { echo "$t"; return 1; }
  [[ "$t" == *"Quitting Backup Pro is a quick way to find out whether it is the cause; it will pick up again when you start it."* ]]
  [[ "$t" == *"technical: Backup Pro 40 Mbps up, 9"* ]] || { echo "$t"; return 1; }
  [[ "$REPAIR_OFFERS" == HOG-1$'\x1f'quit-app$'\x1f'"Quit Backup Pro"$'\x1f'* ]] || { printf '%s\n' "$REPAIR_OFFERS"; return 1; }
  [[ "$REPAIR_OFFERS" == *"bundle_id=com.example.backup"* ]]
}

@test "HOG-1: the prose claims no cause that was not measured" {
  reset_state; slow_pings; stub_app
  make_nettop "Backup Pro|$APP_PID|40|0.2"
  scan
  local t; t="$(diag_text_for HOG-1)"
  # It may say what was seen and suggest the experiment; it may not say
  # what the app is for, or that the router or ISP is at fault.
  [[ "$t" != *"backup"* && "$t" != *"sync"* && "$t" != *"ISP"* && "$t" != *"torrent"* ]] || { echo "$t"; return 1; }
  [[ "$t" == *"A busy upload can make everything else on the connection feel slow"* ]]
}

@test "HOG-1: a download hog is worded as a download" {
  reset_state; slow_pings; stub_app
  make_nettop "Backup Pro|$APP_PID|0.1|55"
  scan
  local t; t="$(diag_text_for HOG-1)"
  [[ "$t" == "Backup Pro is downloading about 55 Mbps, which is most of what this Mac is receiving"* ]] || { echo "$t"; return 1; }
  [[ "$t" == *"A busy download can make"* ]]
}

@test "HOG-1: jitter alone opens the gate, and the prose says jitter, not an RTT it did not see" {
  reset_state; stub_app
  INET_RTT_JITTER=45
  make_nettop "Backup Pro|$APP_PID|40|0.2"
  scan
  local t; t="$(diag_text_for HOG-1)"
  [[ "$t" == *"while pings to the internet vary by about 45 ms from one to the next."* ]] || { echo "$t"; return 1; }
}

@test "HOG-1: processes of one app are folded into it (a helper is not the app)" {
  reset_state; slow_pings; stub_app
  # Two processes, 15 + 15 Mbps; the resolver knows only the first by pid, so
  # the second stays separate and the group is 15 of 30: not dominant. Make
  # the second resolvable too and the pair is 30 of 30.
  local second; second="$( ( sleep 600 >/dev/null 2>&1 & echo $! ) )"; EXTRA_PIDS="$second"
  sleep 0.2
  dns_resolve_gui_app() {
    case "$1" in "$APP_PID"|"$second") printf 'com.example.backup|Backup Pro'; return 0 ;; esac
    return 1
  }
  make_nettop "Backup Pro|$APP_PID|15|0" "Backup Pro Helper|$second|15|0"
  scan
  has_rule HOG-1 || { echo "rules: $(scan_rules)"; return 1; }
  [[ "$(diag_text_for HOG-1)" == "Backup Pro is uploading about 30 Mbps"* ]]
}

# ── Silent when it should be ─────────────────────────────────────────────

@test "HOG-1: a big upload on a link whose latency is fine is not a fault, and costs no capture" {
  reset_state; stub_app
  make_nettop "Backup Pro|$APP_PID|80|0.2"
  scan
  ! has_rule HOG-1
  [ "$(nettop_calls)" -eq 0 ]
}

@test "HOG-1: evidence is gathered only once the gate passes, never on a healthy scan" {
  reset_state
  make_nettop "Backup Pro|$APP_PID|80|0.2"
  scan
  [ "$(nettop_calls)" -eq 0 ]
  slow_pings; stub_app
  scan
  [ "$(nettop_calls)" -eq 1 ]
}

@test "HOG-1: stays silent when the pings are being lost (the loss rules own that)" {
  reset_state; slow_pings; stub_app; GW_LOSS=15
  make_nettop "Backup Pro|$APP_PID|40|0.2"
  scan
  ! has_rule HOG-1
  [ "$(nettop_calls)" -eq 0 ]
  GW_LOSS=0 INET_LOSS=30
  scan
  ! has_rule HOG-1
}

@test "HOG-1: stays silent in an outage, behind a captive portal and under SOCK-1" {
  reset_state; slow_pings; stub_app
  make_nettop "Backup Pro|$APP_PID|40|0.2"
  PUBLIC_OK=0 TCP_REACH_ANY_OK=0 DNS_OK=0 DNS_LINES=$'192.168.1.1|apple.com||FAIL\n'
  scan; ! has_rule HOG-1
  reset_state; slow_pings; CAPTIVE_PORTAL=1 PUBLIC_OK=1
  scan; has_rule CP-1; ! has_rule HOG-1
  reset_state; slow_pings; DNS_LOCAL_FAIL=1
  scan; has_rule SOCK-1; ! has_rule HOG-1
  [ "$(nettop_calls)" -eq 0 ]
}

@test "HOG-1: a burst in one interval is not sustained" {
  reset_state; slow_pings; stub_app
  make_nettop "Backup Pro|$APP_PID|40,0|0.2"
  scan
  ! has_rule HOG-1
}

@test "HOG-1: two apps sharing the link are not 'one app'" {
  reset_state; slow_pings; stub_app
  make_nettop "Backup Pro|$APP_PID|25|0.2" "Other|$OTHER2|20|0"
  scan
  ! has_rule HOG-1
  # The same app against a trickle is one app.
  make_nettop "Backup Pro|$APP_PID|25|0.2" "Other|$OTHER2|3|0"
  scan
  has_rule HOG-1
}

@test "HOG-1: an upload below the unknown-capacity floor is a video call, not a hog" {
  reset_state; slow_pings; stub_app
  make_nettop "Backup Pro|$APP_PID|6|0.2"
  scan
  ! has_rule HOG-1
}

@test "HOG-1: a system daemon's huge lifetime counter is not traffic" {
  reset_state; slow_pings; stub_app
  # mDNSResponder at 14 MB in / 7 MB out and not moving; the app is small.
  make_nettop "mDNSResponder|534|0|0" "Backup Pro|$APP_PID|0.3|0.2"
  scan
  ! has_rule HOG-1
}

@test "HOG-1: with a measured speed, a small share of a fast line is not a hog" {
  reset_state; slow_pings; stub_app
  SPEEDTEST_UP_MBPS=900 SPEEDTEST_DOWN_MBPS=900
  make_nettop "Backup Pro|$APP_PID|40|0.2"
  scan
  ! has_rule HOG-1
}

@test "HOG-1: with a measured speed, most of a slow line is a hog even below the unknown-capacity floor" {
  reset_state; slow_pings; stub_app
  SPEEDTEST_UP_MBPS=1 SPEEDTEST_DOWN_MBPS=50
  make_nettop "Backup Pro|$APP_PID|6|0.2"
  scan
  has_rule HOG-1 || { echo "rules: $(scan_rules)"; return 1; }
  [[ "$(diag_text_for HOG-1)" == *"about 85% of the line's measured upload capacity"* ]] || { diag_text_for HOG-1; return 1; }
}

@test "HOG-1: the full check's own earlier traffic sample must have seen the link busy" {
  reset_state; slow_pings; stub_app
  TRAFFIC_MEASURED=1 TRAFFIC_UP_MBPS=0.05 TRAFFIC_DOWN_MBPS=0.02
  make_nettop "Backup Pro|$APP_PID|40|0.2"
  scan
  ! has_rule HOG-1
  [ "$(nettop_calls)" -eq 0 ]
  TRAFFIC_UP_MBPS=38
  scan
  has_rule HOG-1
  # Busy in the other direction does not vouch for this one.
  TRAFFIC_UP_MBPS=0.05 TRAFFIC_DOWN_MBPS=60
  scan
  ! has_rule HOG-1
}

# ── Hopwatch's own traffic is never the answer ───────────────────────────

@test "HOG-1: the top talker being Hopwatch's own child process is never accused" {
  reset_state; slow_pings
  dns_resolve_gui_app() { printf 'com.example.backup|Backup Pro'; return 0; }
  # A curl, as bufferbloat_run starts: a descendant of this run.
  make_nettop "curl|$OWN|90|0.2"
  scan
  ! has_rule HOG-1
  [ -z "$REPAIR_OFFERS" ]
}

@test "HOG-1: Hopwatch's own traffic voids the direction even beside a bystander" {
  reset_state; slow_pings; stub_app
  # The bystander is 12 Mbps of 12, but the speed test is moving 90: the
  # latency is ours, and pinning it on the bystander would be a guess.
  make_nettop "curl|$OWN|90|0.2" "Backup Pro|$APP_PID|12|0.2"
  scan
  ! has_rule HOG-1
}

@test "HOG-1: an orphaned probe tool is recognised by name when ancestry cannot say" {
  reset_state; slow_pings; stub_app
  make_nettop "speedtest|$OTHER|90|90"
  scan
  ! has_rule HOG-1
}

@test "HOG-1: a full check run by ANOTHER process (the app, a terminal) is recognised by its command line" {
  reset_state; slow_pings
  # A fake `hopwatch` script, run by bash the way the real one is, whose
  # child plays the part of the speed test's curl. Double-forked, so it is
  # not this shell's descendant: only the command line can identify it.
  local dir="$BATS_TEST_TMPDIR/fake/bin"; mkdir -p "$dir"
  printf '#!/usr/bin/env bash\nsleep 600 &\necho $! > "%s/child.pid"\nwait\n' "$BATS_TEST_TMPDIR" >"$dir/hopwatch"
  ( bash "$dir/hopwatch" >/dev/null 2>&1 & )
  local n=0
  while [ ! -s "$BATS_TEST_TMPDIR/child.pid" ] && [ "$n" -lt 30 ]; do sleep 0.1; n=$((n + 1)); done
  local child; child="$(cat "$BATS_TEST_TMPDIR/child.pid")"
  EXTRA_PIDS="$child $(ps -o ppid= -p "$child" | tr -d ' ')"
  dns_resolve_gui_app() { printf 'com.example.backup|Backup Pro'; return 0; }
  make_nettop "curl|$child|90|0.2"
  scan
  ! has_rule HOG-1
  # The same process, not under a Hopwatch command line, is anyone's.
  make_nettop "curl|$OTHER|90|0.2"
  scan
  has_rule HOG-1
}

@test "HOG-1: a pid nettop saw and ps no longer lists cannot be vouched for, so it voids the direction" {
  reset_state; slow_pings; stub_app
  make_nettop "Backup Pro|$APP_PID|12|0.2" "gone|2999999|90|0.2"
  scan
  ! has_rule HOG-1
}

# ── Naming ───────────────────────────────────────────────────────────────

@test "HOG-1: a process that is not a quittable GUI app gives the finding with no name and no button" {
  reset_state; slow_pings; stub_no_app
  make_nettop "bird|$OTHER|40|0.2"
  scan
  has_rule HOG-1 || { echo "rules: $(scan_rules)"; return 1; }
  local t; t="$(diag_text_for HOG-1)"
  [[ "$t" == "Something on this Mac is uploading about 40 Mbps, which is most of what this Mac is sending, while pings to your router are taking about 84 ms. This check could not tell which app it is."* ]] || { echo "$t"; return 1; }
  [[ "$t" == *"Pausing any backup, sync or large transfer running on this Mac is a quick way to find out whether it is the cause."* ]]
  [[ "$t" == *"technical: bird 40 Mbps up"* ]]
  [[ "$t" != *"Quit"* && "$t" != *"Quitting"* ]]
  [ -z "$REPAIR_OFFERS" ]
}

@test "HOG-1: the button is the existing quit-app repair, and quit-app still refuses what it should" {
  reset_state; slow_pings; stub_app
  make_nettop "Backup Pro|$APP_PID|40|0.2"
  scan
  [[ "$REPAIR_OFFERS" == *$'\x1f'quit-app$'\x1f'* ]]
  # The resolver never hands back Finder or Hopwatch, and the repair would
  # refuse them anyway.
  ! repair_bundle_quittable com.godigi.hopwatch
  ! repair_bundle_quittable com.apple.finder
}

# ── The evidence source failing is a silent skip ─────────────────────────

@test "HOG-1: nettop exiting non-zero is a silent skip" {
  reset_state; slow_pings; stub_app
  make_nettop "Backup Pro|$APP_PID|40|0.2"
  NETTOP_FAIL=1; export NETTOP_FAIL
  run diagnosis_run
  [ "$status" -eq 0 ]
  scan
  ! has_rule HOG-1
  [ "$HOG_MEASURED" -eq 0 ]
}

@test "HOG-1: nettop printing nothing, garbage, or a single snapshot is a silent skip" {
  reset_state; slow_pings; stub_app
  : >"$NETTOP_OUT"
  scan; ! has_rule HOG-1
  printf 'nettop: this is not what you expected\n\x00\xff\n' >"$NETTOP_OUT"
  scan; ! has_rule HOG-1
  printf ',bytes_in,bytes_out,\nBackup Pro.%s,1,99999999,\n' "$APP_PID" >"$NETTOP_OUT"
  scan; ! has_rule HOG-1
  [ "$HOG_MEASURED" -eq 0 ]
}

@test "HOG-1: nettop being absent is a silent skip" {
  reset_state; slow_pings; stub_app
  command() { if [ "${1:-}" = -v ] && [ "${2:-}" = nettop ]; then return 1; fi; builtin command "$@"; }
  run diagnosis_run
  [ "$status" -eq 0 ]
  scan
  ! has_rule HOG-1
  [ "$(nettop_calls)" -eq 0 ]
}

@test "HOG-1: python3 failing on the parser is a silent skip" {
  reset_state; slow_pings; stub_app
  make_nettop "Backup Pro|$APP_PID|40|0.2"
  HELPERS_DIR="$BATS_TEST_TMPDIR/nowhere"
  scan
  ! has_rule HOG-1
}

# ── The parser, against what nettop really prints ────────────────────────

@test "hog.py: names with spaces and dots, a time column and a header-less first row all parse" {
  local out
  out="$(printf '%s\n' \
    'time,,bytes_in,bytes_out,' \
    '10:00:00.000001,Google Chrome H.7130,1000000,1000000,' \
    '10:00:00.000002,Runner.Listener.1046,0,0,' \
    '10:00:00.000003,2.1.292.14809,0,0,' \
    'time,,bytes_in,bytes_out,' \
    '10:00:02.000001,Google Chrome H.7130,3500000,1000000,' \
    '10:00:02.000002,Runner.Listener.1046,0,0,' \
    '10:00:02.000003,2.1.292.14809,0,0,' \
    | python3 "$HELPERS/hog.py" 2 "$$")"
  [[ "$out" == M\|2\|* ]] || { echo "$out"; return 1; }
  # 2.5 MB over 2 s is 10 Mb/s down.
  [[ "$out" == *"|Google Chrome H|10.000|"* ]] || { echo "$out"; return 1; }
}

@test "hog.py: a counter that goes backwards (a reused pid) is dropped, not read as a rate" {
  local out
  out="$(printf '%s\n' ',bytes_in,bytes_out,' "x.$OTHER,9000000,9000000," ',bytes_in,bytes_out,' "x.$OTHER,10,10," \
    | python3 "$HELPERS/hog.py" 2 "$$")"
  [[ "$out" == "M|2|0.000|0.000|0.000|0.000" ]] || { echo "$out"; return 1; }
}

@test "hog.py: one snapshot is not a measurement" {
  local out
  out="$(printf '%s\n' ',bytes_in,bytes_out,' "x.$OTHER,10,10," | python3 "$HELPERS/hog.py" 2 "$$")"
  [[ "$out" == M\|1\|* ]]
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -eq 1 ]
}

@test "hog.py: judges nothing (no verdict, no threshold)" {
  run grep -nE 'THRESH_|Mbps|warn|critical' "$HELPERS/hog.py"
  [ "$status" -ne 0 ] || { echo "$output"; return 1; }
}

@test "the real nettop on this Mac parses to a measured capture" {
  command -v nettop >/dev/null 2>&1 || skip "no nettop"
  PATH="${PATH#"$STUBS":}"
  stub_no_app
  hog_capture_evidence
  [ "$HOG_MEASURED" -eq 1 ]
  [ -n "$HOG_UP_TOTAL" ] && [ -n "$HOG_DOWN_TOTAL" ]
}

# ── The monitor ──────────────────────────────────────────────────────────

# A stand-in for the capture: counts calls and plants evidence. The real
# hog_judge then decides, so the monitor's verdict is the scan's.
stub_capture() {
  : >"$BATS_TEST_TMPDIR/captures"
  hog_capture_evidence() {
    echo x >>"$BATS_TEST_TMPDIR/captures"
    HOG_MEASURED=1
    HOG_UP_RATE="${EV_RATE:-40}" HOG_UP_MIN="${EV_MIN:-38}" HOG_UP_DOM_PCT="${EV_DOM:-95}"
    HOG_UP_PROC=Backup HOG_UP_BUNDLE=com.example.backup HOG_UP_NAME="Backup Pro"
    HOG_UP_TOTAL=42 HOG_UP_EXCLUDED=0
    HOG_DOWN_RATE=0 HOG_DOWN_MIN=0 HOG_DOWN_DOM_PCT=0 HOG_DOWN_PROC="" HOG_DOWN_BUNDLE="" HOG_DOWN_NAME=""
    HOG_DOWN_TOTAL=0 HOG_DOWN_EXCLUDED=0
  }
}
captures() { wc -l <"$BATS_TEST_TMPDIR/captures" | tr -d ' '; }

@test "monitor: one degraded cycle spends no capture and fires nothing" {
  reset_state; slow_pings; stub_capture
  _mon_probe_hog
  [ "$(captures)" -eq 0 ]
  [ -z "$(monitor_rules)" ]
}

@test "monitor: the second consecutive degraded cycle takes one capture and lists HOG-1 as a warn" {
  reset_state; slow_pings; stub_capture
  _mon_probe_hog; _mon_probe_hog
  [ "$(captures)" -eq 1 ]
  _mon_rules
  [ "$MON_RULES" = "HOG-1 " ]
  [ "$MON_SEVERITY" = warn ]
}

@test "monitor: a healthy cycle in between resets the streak, so one blip never captures" {
  reset_state; stub_capture
  slow_pings; _mon_probe_hog
  MON_GW_RTT=3 MON_GW_JITTER=1; _mon_probe_hog
  slow_pings; _mon_probe_hog
  [ "$(captures)" -eq 0 ]
}

@test "monitor: a gate that stays open costs one capture per recheck interval, not one per cycle" {
  reset_state; slow_pings; stub_capture
  _mon_probe_hog; _mon_probe_hog; _mon_probe_hog; _mon_probe_hog; _mon_probe_hog
  [ "$(captures)" -eq 1 ]
  MON_HOG_LAST_CAPTURE=$((EPOCHSECONDS - THRESH_MON_HOG_RECHECK_S))
  _mon_probe_hog
  [ "$(captures)" -eq 2 ]
}

@test "monitor: a capture that finds no single app withdraws the rule" {
  reset_state; slow_pings; stub_capture
  _mon_probe_hog; _mon_probe_hog
  [ "$MON_HOG_ACTIVE" -eq 1 ]
  EV_DOM=30
  MON_HOG_LAST_CAPTURE=0
  _mon_probe_hog
  [ "$MON_HOG_ACTIVE" -eq 0 ]
}

@test "monitor: once on it survives one clean cycle and clears after the confirmation count" {
  reset_state; slow_pings; stub_capture
  _mon_probe_hog; _mon_probe_hog
  [ "$(monitor_rules)" = "HOG-1 " ]
  MON_GW_RTT=3 MON_GW_JITTER=1
  _mon_probe_hog
  [ "$(monitor_rules)" = "HOG-1 " ]
  _mon_probe_hog
  _mon_rules
  [ -z "$MON_RULES" ]
  [[ " $MON_CLEARABLE_RULES " == *" HOG-1 "* ]]
}

@test "monitor: a cycle whose fast tier did not run adds nothing to the streak" {
  reset_state; slow_pings; stub_capture
  _mon_probe_hog
  MON_REFRESHED="medium "
  _mon_probe_hog; _mon_probe_hog; _mon_probe_hog
  [ "$(captures)" -eq 0 ]
}

@test "monitor: lossy ping, a captive portal or a refused socket keep the capture from being spent" {
  reset_state; slow_pings; stub_capture
  MON_GW_LOSS=15; _mon_probe_hog; _mon_probe_hog
  MON_GW_LOSS=0 MON_CAPTIVE=1; _mon_probe_hog; _mon_probe_hog
  MON_CAPTIVE=0 MON_DNS_LOCAL_FAIL=1; _mon_probe_hog; _mon_probe_hog
  [ "$(captures)" -eq 0 ]
}

@test "monitor: HOG-1 held on does not survive ping turning lossy, an outage or a portal" {
  reset_state; slow_pings; stub_capture
  _mon_probe_hog; _mon_probe_hog
  MON_GW_LOSS=15
  [[ " $(monitor_rules)" != *" HOG-1 "* ]]
  MON_GW_LOSS=0 MON_CAPTIVE=1
  [[ " $(monitor_rules)" != *" HOG-1 "* ]]
}

@test "monitor: a link drop or a new network forgets it" {
  reset_state; slow_pings; stub_capture
  _mon_probe_hog; _mon_probe_hog
  [ "$MON_HOG_ACTIVE" -eq 1 ]
  MON_LINK_UP=0
  _mon_rules
  [ "$MON_HOG_ACTIVE" -eq 0 ] && [ "$MON_HOG_STREAK" -eq 0 ]
}

@test "monitor: the stream never judges as if it knew the line's capacity" {
  reset_state; slow_pings; stub_capture
  # 6 Mbps of 6 would be a hog on a measured 1 Mbps line; the monitor has no
  # such figure, so it holds the stand-in floor and says nothing.
  EV_RATE=6 EV_MIN=6
  _mon_probe_hog; _mon_probe_hog
  [ "$MON_HOG_ACTIVE" -eq 0 ]
}

@test "monitor: an unresolved top talker still fires the rule (the stream carries no name)" {
  reset_state; slow_pings
  hog_capture_evidence() {
    HOG_MEASURED=1
    HOG_UP_RATE=40 HOG_UP_MIN=40 HOG_UP_DOM_PCT=99 HOG_UP_PROC=bird HOG_UP_BUNDLE="" HOG_UP_NAME=""
    HOG_UP_TOTAL=40 HOG_UP_EXCLUDED=0
    HOG_DOWN_RATE=0 HOG_DOWN_MIN=0 HOG_DOWN_DOM_PCT=0 HOG_DOWN_EXCLUDED=0 HOG_DOWN_TOTAL=0
  }
  _mon_probe_hog; _mon_probe_hog
  [ "$(monitor_rules)" = "HOG-1 " ]
}

# ── Scan / monitor parity ────────────────────────────────────────────────

@test "parity: the same hog is HOG-1 on both engines" {
  reset_state; slow_pings; stub_app
  make_nettop "Backup Pro|$APP_PID|40|0.2"
  _mon_probe_hog; _mon_probe_hog
  local m s; m="$(monitor_rules)"
  scan
  s="$(printf '%s\n' "${DIAG_RULE[@]}" | grep -E '^(HOG-1|G3|L2|CONN-1)$' | sort | tr '\n' ' ')"
  [ "$m" = "$s" ]
  [ "$m" = "HOG-1 " ]
}

@test "parity: a big upload with healthy latency is nothing on both engines" {
  reset_state; stub_app
  make_nettop "Backup Pro|$APP_PID|80|0.2"
  _mon_probe_hog; _mon_probe_hog
  local m; m="$(monitor_rules)"
  scan
  [ -z "$m" ]
  ! has_rule HOG-1
  [ "$(nettop_calls)" -eq 0 ]
}

@test "parity: Hopwatch's own child saturating the link is nothing on both engines" {
  reset_state; slow_pings
  dns_resolve_gui_app() { printf 'com.example.backup|Backup Pro'; return 0; }
  make_nettop "curl|$OWN|90|0.2"
  _mon_probe_hog; _mon_probe_hog
  [ -z "$(monitor_rules)" ]
  scan
  ! has_rule HOG-1
}

@test "parity: lossy ping turns both engines back to the loss rules" {
  reset_state; slow_pings; stub_app
  GW_LOSS=15 MON_GW_LOSS=15
  make_nettop "Backup Pro|$APP_PID|40|0.2"
  _mon_probe_hog; _mon_probe_hog
  local m; m="$(monitor_rules)"
  scan
  [[ "$m" != *HOG-1* ]] && ! has_rule HOG-1
}

# ── The rules are written down where they must be ────────────────────────

@test "no inline numeric cutoff in the HOG-1 code of the scan, the monitor or the shared judge" {
  run grep -nE '(-lt|-ge|-gt|-le) +[1-9][0-9]*( |\])' "$REPO/lib/diagnosis.sh"
  [ "$status" -ne 0 ] || { echo "$output"; return 1; }
  # The monitor's HOG functions, from their first line to the next function.
  local body
  body="$(awk '/^_mon_hog_reset\(\)/,/^_mon_rules\(\)/' "$REPO/lib/monitor.sh")"
  [ -n "$body" ]
  run grep -nE '(-lt|-ge|-gt|-le) +[1-9]' <<<"$body"
  [ "$status" -ne 0 ] || { echo "$output"; return 1; }
  # hog_judge: every comparison is against a THRESH_ variable.
  body="$(awk '/^hog_judge\(\)/,/^}/' "$REPO/lib/common.sh")"
  [ -n "$body" ]
  run grep -nE "(-lt|-ge|-gt|-le) +[1-9]|t=[1-9]" <<<"$body"
  [ "$status" -ne 0 ] || { echo "$output"; return 1; }
}

@test "HOG-1 is in the catalog with quit-app, in both scopes, and a doc anchor that exists" {
  run python3 "$HELPERS/rules_catalog.py"
  local entry
  entry="$(printf '%s' "$output" | python3 -c "
import json, sys
d = {r['id']: r for r in json.load(sys.stdin)['rules']}
r = d['HOG-1']
assert r['severity'] == 'warn' and r['scope'] == 'both', r
assert r['repairs'] == ['quit-app'], r
print(r['doc'].split('#')[1])
")"
  [ "$entry" = "hog-1--one-app-is-using-up-the-connection" ]
  grep -q '^### HOG-1 — One app is using up the connection$' "$REPO/docs/DIAGNOSIS-RULES.md"
}

@test "the design note exists and stays under 400 words" {
  local f="$REPO/docs/design/2026-10-08-upload-hog-design.md"
  [ -f "$f" ]
  [ "$(wc -w <"$f" | tr -d ' ')" -lt 400 ]
}
