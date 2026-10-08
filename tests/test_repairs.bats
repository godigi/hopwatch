#!/usr/bin/env bats
# tests/test_repairs.bats — the repair tier, phase 1: `hopwatch --repair=ID`
# with quit-app, restart-mac and open-sign-in, and the findings that offer
# them (SOCK-1, CP-1).
#
# docs/design/2026-10-07-repair-actions-design.md
#
# The rule for this file: a test never quits an app, opens a browser or
# shows a restart dialog. osascript, open and lsappinfo are stubs on PATH
# that record what they were asked, and every repair that must not touch
# the machine is run with --dry-run or against the stubs.

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  NETDIAG="$REPO/bin/hopwatch"
  STUBS="$BATS_TEST_TMPDIR/stubs"
  STATE="$BATS_TEST_TMPDIR/state"
  CALLS="$BATS_TEST_TMPDIR/calls"
  mkdir -p "$STUBS" "$STATE"
  export HOPWATCH_LOG_DIR="$BATS_TEST_TMPDIR/logs"
  export REPAIR_QUIT_WAIT_S=1
  export STATE CALLS
  stub_world
  PATH="$STUBS:$PATH"
}

# Stand-ins for the three system programs a repair touches. Each appends
# its arguments to $CALLS, so a test can prove what ran -- and, more often
# here, that nothing did.
stub_world() {
  cat >"$STUBS/osascript" <<'SH'
#!/bin/sh
printf 'osascript %s\n' "$*" >>"$CALLS"
if [ -f "$STATE/osascript-fails" ]; then
  echo "execution error: Not authorized to send Apple events to Chatty. (-1743)" >&2
  exit 1
fi
# A successful quit: the app is gone unless the test says it lingers.
[ -f "$STATE/app-lingers" ] || : >"$STATE/app-gone"
exit 0
SH
  cat >"$STUBS/open" <<'SH'
#!/bin/sh
printf 'open %s\n' "$*" >>"$CALLS"
[ -f "$STATE/open-fails" ] && exit 1
exit 0
SH
  cat >"$STUBS/lsappinfo" <<'SH'
#!/bin/sh
printf 'lsappinfo %s\n' "$*" >>"$CALLS"
case "$1" in
  find)
    if [ -f "$STATE/app-not-running" ] || [ -f "$STATE/app-gone" ]; then exit 0; fi
    echo 'ASN:0x0-0x1e01e-"Chatty App":' ;;
  info)
    echo '"LSDisplayName"="Chatty App"' ;;
esac
exit 0
SH
  chmod +x "$STUBS/osascript" "$STUBS/open" "$STUBS/lsappinfo"
}

no_calls() {
  [ ! -s "$CALLS" ] || { echo "a system program was called:"; cat "$CALLS"; return 1; }
}

# ── --repair: dry run ────────────────────────────────────────────────────

@test "--dry-run quit-app prints exactly what would run and runs nothing" {
  run "$NETDIAG" --repair=quit-app --repair-param bundle_id=com.example.chatty --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"would run: lsappinfo find bundleid=com.example.chatty"* ]]
  [[ "$output" == *"would run: osascript -e 'tell application id \"com.example.chatty\" to quit'"* ]]
  [[ "$output" == *"Nothing was changed"* ]]
  no_calls
}

@test "--dry-run restart-mac prints the standard restart-dialog event and runs nothing" {
  run "$NETDIAG" --repair=restart-mac --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"osascript -e 'tell application \"loginwindow\" to «event aevtrrst»'"* ]]
  no_calls
}

@test "--dry-run open-sign-in names the page the captive-portal probe uses and runs nothing" {
  run "$NETDIAG" --repair=open-sign-in --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"open http://captive.apple.com/hotspot-detect.html"* ]]
  no_calls
}

@test "the sign-in page is the page both captive-portal probes fetch, defined once" {
  grep -q "^CAPTIVE_CANARY_URL='http://captive.apple.com/hotspot-detect.html'" "$REPO/lib/common.sh"
  grep -q 'CAPTIVE_CANARY_URL' "$REPO/lib/public.sh"
  grep -q 'CAPTIVE_CANARY_URL' "$REPO/lib/monitor.sh"
  ! grep -q 'captive.apple.com' "$REPO/lib/public.sh" "$REPO/lib/monitor.sh" "$REPO/lib/repairs.sh"
}

@test "--dry-run --json prints one object with id, ok, dry_run, ran and message" {
  run "$NETDIAG" --repair=quit-app --repair-param bundle_id=com.example.chatty --dry-run --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert set(d) == {'id', 'ok', 'dry_run', 'ran', 'message'}, sorted(d)
assert d['id'] == 'quit-app' and d['ok'] is True and d['dry_run'] is True, d
assert len(d['ran']) == 2 and d['ran'][1].startswith('osascript -e '), d['ran']
assert d['message'], d
"
  no_calls
}

# ── --repair: refusals run nothing ───────────────────────────────────────

@test "an unknown repair id exits 3 and runs nothing" {
  run "$NETDIAG" --repair=wifi-cycle --dry-run
  [ "$status" -eq 3 ]
  run "$NETDIAG" --repair=wifi-cycle
  [ "$status" -eq 3 ]
  [[ "$output" == *"unknown repair"* ]]
  no_calls
}

@test "quit-app refuses a bundle id that is not letters, digits, dots and hyphens" {
  local bad
  for bad in 'com.example;rm' 'com example' 'com.example"' '$(touch x)' 'a/b' '-e' '.hidden' '' 'com.exam`ple' "com.ex'ample"; do
    run "$NETDIAG" --repair=quit-app --repair-param "bundle_id=$bad"
    [ "$status" -eq 3 ] || { echo "accepted bundle id: [$bad] (status $status)"; return 1; }
    local out status2=0
    out="$("$NETDIAG" --repair=quit-app --repair-param "bundle_id=$bad" --dry-run --json 2>/dev/null)" || status2=$?
    [ "$status2" -eq 3 ] || { echo "dry-run accepted: [$bad]"; return 1; }
    [ -z "$out" ] || { echo "printed a result for a refused id: $out"; return 1; }
  done
  no_calls
}

@test "quit-app refuses a missing bundle id, an unknown parameter and the desktop itself" {
  run "$NETDIAG" --repair=quit-app --dry-run
  [ "$status" -eq 3 ]
  run "$NETDIAG" --repair=quit-app --repair-param name=Chatty --dry-run
  [ "$status" -eq 3 ]
  run "$NETDIAG" --repair=quit-app --repair-param bundle_id=com.apple.finder --dry-run
  [ "$status" -eq 3 ]
  run "$NETDIAG" --repair=quit-app --repair-param bundle_id=com.apple.loginwindow --dry-run
  [ "$status" -eq 3 ]
  run "$NETDIAG" --repair=quit-app --repair-param bundle_id=com.godigi.hopwatch --dry-run
  [ "$status" -eq 3 ]
  no_calls
}

@test "repairs that take no parameter refuse one" {
  run "$NETDIAG" --repair=restart-mac --repair-param bundle_id=com.example.chatty --dry-run
  [ "$status" -eq 3 ]
  run "$NETDIAG" --repair=open-sign-in --repair-param url=http://example.com --dry-run
  [ "$status" -eq 3 ]
  no_calls
}

@test "usage errors around --repair exit 3, not 2" {
  run "$NETDIAG" --repair
  [ "$status" -eq 3 ]
  run "$NETDIAG" --repair=
  [ "$status" -eq 3 ]
  run "$NETDIAG" --dry-run
  [ "$status" -eq 3 ]
  run "$NETDIAG" --repair-param bundle_id=com.example.chatty
  [ "$status" -eq 3 ]
  run "$NETDIAG" --repair=quit-app --repair-param
  [ "$status" -eq 3 ]
  run "$NETDIAG" --repair=quit-app --repair-param nokeyvalue
  [ "$status" -eq 3 ]
  run "$NETDIAG" --repair=quit-app --repair-param Bundle_Id=x.y
  [ "$status" -eq 3 ]
  no_calls
}

# ── --repair: the mechanisms, against stubs ──────────────────────────────

@test "quit-app asks the app to quit by bundle id and reports it gone" {
  run "$NETDIAG" --repair=quit-app --repair-param bundle_id=com.example.chatty --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['ok'] is True and d['dry_run'] is False, d
assert d['message'] == 'Chatty App has quit.', d
"
  grep -qF "osascript -e tell application id \"com.example.chatty\" to quit" "$CALLS"
  # One quit request, not several, and nothing else.
  [ "$(grep -c '^osascript' "$CALLS")" -eq 1 ]
}

@test "quit-app on an app that is not running does not launch it" {
  : >"$STATE/app-not-running"
  run "$NETDIAG" --repair=quit-app --repair-param bundle_id=com.example.chatty
  [ "$status" -eq 0 ]
  [[ "$output" == *"not running"* ]]
  # `tell application id` would start the app just to quit it.
  ! grep -q '^osascript' "$CALLS"
}

@test "quit-app reports exit 1 and says what to do when macOS refuses the Apple event" {
  : >"$STATE/osascript-fails"
  run "$NETDIAG" --repair=quit-app --repair-param bundle_id=com.example.chatty --json
  [ "$status" -eq 1 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['ok'] is False, d
assert 'Automation' in d['message'], d
"
}

@test "quit-app says so when the app is still open after being asked" {
  : >"$STATE/app-lingers"
  run "$NETDIAG" --repair=quit-app --repair-param bundle_id=com.example.chatty --json
  [ "$status" -eq 1 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['ok'] is False and 'still open' in d['message'], d
"
}

@test "restart-mac sends the restart-dialog event and nothing stronger" {
  run "$NETDIAG" --repair=restart-mac
  [ "$status" -eq 0 ]
  [ "$(grep -c '' "$CALLS")" -eq 1 ]
  grep -qF 'osascript -e tell application "loginwindow" to «event aevtrrst»' "$CALLS"
}

@test "open-sign-in opens the captive-portal probe's page in the browser" {
  run "$NETDIAG" --repair=open-sign-in
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS")" = "open http://captive.apple.com/hotspot-detect.html" ]
}

@test "open-sign-in exits 1 when the browser cannot be opened" {
  : >"$STATE/open-fails"
  run "$NETDIAG" --repair=open-sign-in --json
  [ "$status" -eq 1 ]
  [[ "$output" == *'"ok":false'* ]]
}

@test "no repair mechanism uses sudo, shutdown, reboot, killall or SIGKILL" {
  # Comments may say what the code does not do; code may not do it.
  run bash -c "grep -vE '^[[:space:]]*#' '$REPO/lib/repairs.sh' | grep -nE '(^|[^a-z_-])(sudo|shutdown|reboot|killall|pkill)([^a-z_-]|$)|kill +-(9|KILL)|SIGKILL'"
  [ "$status" -eq 1 ] || { echo "found: $output"; return 1; }
}

# ── The journal ──────────────────────────────────────────────────────────

@test "a repair that runs appends one repair line to an existing journal" {
  mkdir -p "$HOPWATCH_LOG_DIR"
  : >"$HOPWATCH_LOG_DIR/events.jsonl"
  run "$NETDIAG" --repair=open-sign-in
  [ "$status" -eq 0 ]
  [ "$(grep -c '' "$HOPWATCH_LOG_DIR/events.jsonl")" -eq 1 ]
  python3 -c "
import json, sys
line = json.loads(open('$HOPWATCH_LOG_DIR/events.jsonl').read())
assert line['kind'] == 'repair' and line['to'] == 'open-sign-in', line
assert line['ok'] is True and line['t'].endswith('Z'), line
assert line['summary'], line
"
}

@test "a dry run writes nothing to the journal" {
  mkdir -p "$HOPWATCH_LOG_DIR"
  : >"$HOPWATCH_LOG_DIR/events.jsonl"
  run "$NETDIAG" --repair=open-sign-in --dry-run
  [ "$status" -eq 0 ]
  [ ! -s "$HOPWATCH_LOG_DIR/events.jsonl" ]
}

@test "with no journal, a repair writes none and does not create one" {
  [ ! -e "$HOPWATCH_LOG_DIR/events.jsonl" ]
  run "$NETDIAG" --repair=open-sign-in
  [ "$status" -eq 0 ]
  [ ! -e "$HOPWATCH_LOG_DIR/events.jsonl" ]
  [ ! -e "$HOPWATCH_LOG_DIR" ] || [ -z "$(ls -A "$HOPWATCH_LOG_DIR")" ]
}

@test "--journal PATH chooses the journal a repair is written to" {
  local j="$BATS_TEST_TMPDIR/elsewhere.jsonl"
  : >"$j"
  run "$NETDIAG" --repair=open-sign-in --journal "$j"
  [ "$status" -eq 0 ]
  [ "$(grep -c '"kind":"repair"' "$j")" -eq 1 ]
}

@test "--events tolerates a repair line and never pairs it into a fault episode" {
  local j="$HOPWATCH_LOG_DIR/events.jsonl"
  mkdir -p "$HOPWATCH_LOG_DIR"
  cat >"$j" <<'EOF'
{"t":"2026-10-07T10:00:00Z","seq":1,"network":"wifi:mac=aa","network_label":"Home","kind":"monitor-started","summary":"Monitoring started"}
{"t":"2026-10-07T10:01:00Z","seq":2,"network":"wifi:mac=aa","network_label":"Home","kind":"rule-fired","from":null,"to":"SOCK-1","summary":"s"}
{"t":"2026-10-07T10:03:00Z","seq":null,"network":null,"network_label":null,"kind":"repair","field":"repair","from":null,"to":"quit-app","summary":"Chatty App has quit.","ok":true,"params":{"bundle_id":"com.example.chatty"}}
{"t":"2026-10-07T10:05:00Z","seq":3,"network":"wifi:mac=aa","network_label":"Home","kind":"rule-cleared","from":"SOCK-1","to":null,"summary":"s"}
EOF
  run "$NETDIAG" --events=0
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['counts']['by_kind'].get('repair') == 1, d['counts']
eps = d['episodes']
assert len(eps) == 1 and eps[0]['rule'] == 'SOCK-1', eps
assert eps[0]['duration_s'] == 240 and eps[0]['ended_by'] == 'cleared', eps
repairs = [e for e in d['events'] if e['kind'] == 'repair']
assert len(repairs) == 1 and repairs[0]['to'] == 'quit-app', repairs
"
}

# ── Which finding offers which repair ────────────────────────────────────
# Same mechanism as tests/test_sock_and_dns_guidance.bats: the libraries are
# sourced and the system programs are shell functions.

load_diagnosis() {
  JSON_MODE=0 QUIET=0 QUICK=0 EXPERT=0 LOG=/dev/null
  . "$REPO/lib/thresholds.sh"
  . "$REPO/lib/common.sh"
  . "$REPO/lib/globals.sh"
  . "$REPO/lib/traffic.sh"
  . "$REPO/lib/diagnosis.sh"
  . "$REPO/lib/repairs.sh"
}

diag_baseline() {
  GATEWAY=192.168.1.1
  GW_LOSS=0 GW_LATENCY=2.5 GW_JITTER=0.3
  PUBLIC_OK=1 PUBLIC_CHECKED=1
  DNS_OK=1 DNS_LINES="192.168.1.1|apple.com|17.253.144.10|OK"$'\n'
  INET_LOSS=0 INET_LOSS_ALT=0
  IS_WIFI=1 TCP_REACH_ANY_OK=1
  WIFI_SSID="HomeNet" WIFI_RSSI=-50 WIFI_SNR=35 WIFI_TX=866
  DNS_PRIMARY_FAIL=0 DNS_FALLBACK_OK=0 PRIMARY_DNS="" SECONDARY_DNS=""
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
}

diag_text_for() {
  local i
  for i in "${!DIAG_RULE[@]}"; do
    if [ "${DIAG_RULE[$i]}" = "$1" ]; then printf '%s\n' "${DIAG[$i]}"; return 0; fi
  done
  return 1
}

# The diagnosis array exactly as bin/hopwatch hands it to emit_json.py.
diagnosis_json() {
  local lines="" i
  for i in "${!DIAG[@]}"; do lines+="${DIAG_SEV[$i]}|${DIAG_RULE[$i]}|${DIAG[$i]}"$'\n'; done
  env -i PATH="$PATH" NETDIAG_DIAGNOSIS_LINES="$lines" NETDIAG_REPAIR_OFFERS="$REPAIR_OFFERS" \
    python3 -c "
import json, sys
sys.path.insert(0, '$REPO/helpers')
import emit_json
json.dump(emit_json.build_diagnosis(), sys.stdout)
"
}

sock_fault() {
  DNS_LOCAL_FAIL=1 DNS_LOCAL_BIND=EADDRNOTAVAIL DNS_UDP_SOCKETS=20 DNS_TCP_DNS_OK=1
}

@test "SOCK-1 offers quit-app with the bundle id when a GUI app holds most of the sockets" {
  load_diagnosis; diag_baseline; sock_fault
  DNS_UDP_HOLDERS="Chatty App|4242|15"$'\n' DNS_UDP_TOP_SHARE_PCT=75
  DNS_UDP_TOP_APP_BUNDLE=com.example.chatty DNS_UDP_TOP_APP_NAME="Chatty App"
  diagnosis_run >/dev/null
  local text; text="$(diag_text_for SOCK-1)"
  [[ "$text" == *"Quit Chatty App (it is holding 15 connections open), or restart this Mac."* ]]
  run diagnosis_json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = [x for x in json.load(sys.stdin) if x['rule'] == 'SOCK-1']
assert len(d) == 1, d
r = d[0]['repairs']
assert [x['id'] for x in r] == ['quit-app'], r
q = r[0]
assert q['label'] == 'Quit Chatty App', q
assert q['params'] == {'bundle_id': 'com.example.chatty'}, q
assert q['admin'] is False, q
assert q['confirm'] and q['if_unfixed'], q
"
}

@test "SOCK-1 offers restart-mac when the holder is below the share cutoff" {
  load_diagnosis; diag_baseline; sock_fault
  DNS_UDP_HOLDERS="Chatty App|4242|3"$'\n' DNS_UDP_TOP_SHARE_PCT=$((THRESH_SOCK_HOLDER_SHARE_PCT - 1))
  DNS_UDP_TOP_APP_BUNDLE=com.example.chatty DNS_UDP_TOP_APP_NAME="Chatty App"
  diagnosis_run >/dev/null
  local text; text="$(diag_text_for SOCK-1)"
  [[ "$text" == *"Restart this Mac."* ]]
  [[ "$text" != *"Quit "* ]]
  run diagnosis_json
  printf '%s' "$output" | python3 -c "
import json, sys
r = [x for x in json.load(sys.stdin) if x['rule'] == 'SOCK-1'][0]['repairs']
assert [x['id'] for x in r] == ['restart-mac'], r
assert r[0]['params'] == {} and r[0]['label'] == 'Restart this Mac', r
"
}

@test "SOCK-1 offers restart-mac, and does not name the process, when the holder is not a GUI app" {
  load_diagnosis; diag_baseline; sock_fault
  # Above the cutoff, but lsappinfo knew no app for it: DNS_UDP_TOP_APP_* empty.
  DNS_UDP_HOLDERS="replicato|900|18"$'\n' DNS_UDP_TOP_SHARE_PCT=90
  DNS_UDP_TOP_APP_BUNDLE="" DNS_UDP_TOP_APP_NAME=""
  diagnosis_run >/dev/null
  local text; text="$(diag_text_for SOCK-1)"
  [[ "$text" == *"Restart this Mac."* ]]
  [[ "$text" != *"replicato"* ]]
  run diagnosis_json
  printf '%s' "$output" | python3 -c "
import json, sys
r = [x for x in json.load(sys.stdin) if x['rule'] == 'SOCK-1'][0]['repairs']
assert [x['id'] for x in r] == ['restart-mac'], r
"
}

@test "SOCK-1 offers restart-mac when no holder is visible at all" {
  load_diagnosis; diag_baseline; sock_fault
  DNS_UDP_HOLDERS="" DNS_UDP_TOP_SHARE_PCT=0
  diagnosis_run >/dev/null
  run diagnosis_json
  printf '%s' "$output" | python3 -c "
import json, sys
r = [x for x in json.load(sys.stdin) if x['rule'] == 'SOCK-1'][0]['repairs']
assert [x['id'] for x in r] == ['restart-mac'], r
"
}

@test "CP-1 offers open-sign-in, critical and warn alike" {
  load_diagnosis; diag_baseline
  CAPTIVE_PORTAL=1 CAPTIVE_PORTAL_CODE=302 PUBLIC_OK=0
  diagnosis_run >/dev/null
  run diagnosis_json
  printf '%s' "$output" | python3 -c "
import json, sys
d = [x for x in json.load(sys.stdin) if x['rule'] == 'CP-1']
assert len(d) == 1 and d[0]['severity'] == 'critical', d
r = d[0]['repairs']
assert [x['id'] for x in r] == ['open-sign-in'], r
assert r[0]['label'] == 'Open the sign-in page' and r[0]['params'] == {}, r
assert r[0]['recheck'] == 'later', r
"
  diag_baseline; CAPTIVE_PORTAL=1 CAPTIVE_PORTAL_CODE=302 PUBLIC_OK=1
  diagnosis_run >/dev/null
  run diagnosis_json
  printf '%s' "$output" | python3 -c "
import json, sys
d = [x for x in json.load(sys.stdin) if x['rule'] == 'CP-1']
assert d[0]['severity'] == 'warn' and d[0]['repairs'][0]['id'] == 'open-sign-in', d
"
}

@test "a diagnosis with no repair carries no repairs key at all" {
  load_diagnosis; diag_baseline
  DNS_OK=0 DNS_LINES="192.168.1.1|apple.com||FAIL"$'\n' DNS_PRIMARY_FAIL=1
  diagnosis_run >/dev/null
  [ "${#DIAG[@]}" -gt 0 ]
  [ -z "$REPAIR_OFFERS" ]
  run diagnosis_json
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d, d
assert all('repairs' not in x for x in d), d
"
}

@test "offers are rebuilt on every pass, not accumulated" {
  load_diagnosis; diag_baseline; sock_fault
  DNS_UDP_HOLDERS="" DNS_UDP_TOP_SHARE_PCT=0
  diagnosis_run >/dev/null
  [ -n "$REPAIR_OFFERS" ]
  diag_baseline
  DNS_LOCAL_FAIL=0
  diagnosis_run >/dev/null
  [ -z "$REPAIR_OFFERS" ]
}

@test "every offered repair is a button label that names the action, never a bare Fix" {
  load_diagnosis
  local id
  for id in $REPAIR_IDS; do
    repair_describe "$id" "Chatty App"
    [ -n "$REPAIR_LABEL" ] && [ -n "$REPAIR_CONFIRM" ] && [ -n "$REPAIR_IF_UNFIXED" ]
    [[ "$REPAIR_LABEL" != "Fix" && "$REPAIR_LABEL" != "Fix it" && "$REPAIR_LABEL" != Fix* ]]
    [ "$REPAIR_ADMIN" -eq 0 ]
  done
}

# ── Resolving the top holder to an app ───────────────────────────────────

@test "dns_resolve_gui_app: a helper process resolves to the app that launched it" {
  load_diagnosis
  with_timeout() { shift; "$@"; }
  lsappinfo() {
    case "$*" in
      *" 700") printf '"CFBundleIdentifier"="com.example.chatty"\n"LSDisplayName"="Chatty App"\n"ApplicationType"="Foreground"\n' ;;
      *)       printf '"CFBundleIdentifier"=[ NULL ]\n"LSDisplayName"=[ NULL ]\n"ApplicationType"=[ NULL ]\n' ;;
    esac
  }
  ps() { case "$*" in *" 701") echo " 700" ;; *" 700") echo "   1" ;; esac; }
  run dns_resolve_gui_app 701
  [ "$status" -eq 0 ]
  [ "$output" = "com.example.chatty|Chatty App" ]
}

@test "dns_resolve_gui_app: a daemon with no app above it resolves to nothing" {
  load_diagnosis
  with_timeout() { shift; "$@"; }
  lsappinfo() { printf '"CFBundleIdentifier"=[ NULL ]\n"ApplicationType"=[ NULL ]\n'; }
  ps() { echo "   1"; }
  run dns_resolve_gui_app 900
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "dns_resolve_gui_app: a background-only or UI-element process is not an app to quit" {
  load_diagnosis
  with_timeout() { shift; "$@"; }
  lsappinfo() { printf '"CFBundleIdentifier"="com.example.agent"\n"LSDisplayName"="Agent"\n"ApplicationType"="UIElement"\n'; }
  ps() { echo "   1"; }
  run dns_resolve_gui_app 900
  [ "$status" -eq 1 ]
}

@test "dns_resolve_gui_app: Finder and Hopwatch itself are never offered to be quit" {
  load_diagnosis
  with_timeout() { shift; "$@"; }
  lsappinfo() { printf '"CFBundleIdentifier"="com.apple.finder"\n"LSDisplayName"="Finder"\n"ApplicationType"="Foreground"\n'; }
  run dns_resolve_gui_app 719
  [ "$status" -eq 1 ]
}

@test "dns_capture_socket_evidence records the app behind the top holder" {
  load_diagnosis
  with_timeout() { shift; "$@"; }
  netstat() { for i in $(seq 1 20); do printf 'udp4 0 0 *.%s *.*\n' "$i"; done; }
  lsof() {
    printf 'COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\n'
    for i in $(seq 1 15); do printf 'Chatty\\x20Helper 701 me %su IPv4 0x1 0t0 UDP *:%s\n' "$i" "$((50000 + i))"; done
  }
  dig() { printf '1.2.3.4\n'; }
  lsappinfo() {
    case "$*" in
      *" 700") printf '"CFBundleIdentifier"="com.example.chatty"\n"LSDisplayName"="Chatty App"\n"ApplicationType"="Foreground"\n' ;;
      *)       printf '"CFBundleIdentifier"=[ NULL ]\n"ApplicationType"=[ NULL ]\n' ;;
    esac
  }
  ps() { case "$*" in *" 701") echo " 700" ;; *) echo "   1" ;; esac; }
  dns_capture_socket_evidence
  [ "$DNS_UDP_TOP_APP_BUNDLE" = com.example.chatty ]
  [ "$DNS_UDP_TOP_APP_NAME" = "Chatty App" ]
  [ "$(printf '%s\n' "$DNS_UDP_HOLDERS" | head -1)" = "Chatty Helper|701|15" ]
}

# ── The catalogue agrees with itself ─────────────────────────────────────

@test "--rules-catalog names the repairs SOCK-1, CONN-1, HOG-1 and CP-1 can offer, and only known ones" {
  run "$NETDIAG" --rules-catalog
  [ "$status" -eq 0 ]
  local known
  known="$(. "$REPO/lib/repairs.sh"; printf '%s' "$REPAIR_IDS")"
  printf '%s' "$output" | python3 -c "
import json, sys
known = set(sys.argv[1].split())
d = {r['id']: r for r in json.load(sys.stdin)['rules']}
assert d['SOCK-1']['repairs'] == ['quit-app', 'restart-mac'], d['SOCK-1']
assert d['CP-1']['repairs'] == ['open-sign-in'], d['CP-1']
for r in d.values():
    for rid in r.get('repairs', []):
        assert rid in known, (r['id'], rid)
assert d['CONN-1']['repairs'] == ['quit-app'], d['CONN-1']
assert d['HOG-1']['repairs'] == ['quit-app'], d['HOG-1']
assert sum(1 for r in d.values() if 'repairs' in r) == 4
" "$known"
}

@test "--capabilities lists the repair feature" {
  run "$NETDIAG" --capabilities
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
assert 'repair' in json.load(sys.stdin)['features']
"
}

@test "--help documents --repair, --repair-param and --dry-run" {
  run "$NETDIAG" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--repair=ID"* ]]
  [[ "$output" == *"--repair-param"* ]]
  [[ "$output" == *"--dry-run"* ]]
}
