#!/usr/bin/env bats
#
# tests/test_browser.bats — verify browser desynchronization detection [BR-1].

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  HELPERS_DIR="$REPO/helpers"
  # shellcheck source=../lib/thresholds.sh
  . "$REPO/lib/thresholds.sh"
  # shellcheck source=../lib/common.sh
  . "$REPO/lib/common.sh"
  # shellcheck source=../lib/globals.sh
  . "$REPO/lib/globals.sh"
  # shellcheck source=../lib/browser.sh
  . "$REPO/lib/browser.sh"
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
}

@test "browser_check: empty input produces clean OK" {
  local tmp_ps="$BATS_TEST_TMPDIR/empty_ps.txt"
  touch "$tmp_ps"
  run python3 "$HELPERS_DIR/browser_check.py" --ps-file "$tmp_ps"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^OK ]]
}

@test "browser_check: detects missing framework version directory (desync)" {
  local mock_app="$BATS_TEST_TMPDIR/Google Chrome.app"
  local fw_dir="$mock_app/Contents/Frameworks/Google Chrome Framework.framework/Versions"
  mkdir -p "$fw_dir/153.0.8010.48"
  ln -s "153.0.8010.48" "$fw_dir/Current"
  mkdir -p "$mock_app/Contents/MacOS"
  touch "$mock_app/Contents/MacOS/Google Chrome"

  local tmp_ps="$BATS_TEST_TMPDIR/desync_ps.txt"
  cat << PS > "$tmp_ps"
  1234 $mock_app/Contents/MacOS/Google Chrome
  5678 $mock_app/Contents/Frameworks/Google Chrome Framework.framework/Versions/153.0.8010.37/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer) --type=renderer
PS

  run python3 "$HELPERS_DIR/browser_check.py" --ps-file "$tmp_ps"
  [ "$status" -eq 0 ]
  [[ "$output" == DESYNC* ]]
  [[ "$output" == *"Google Chrome"* ]]
  [[ "$output" == *"153.0.8010.37"* ]]
  [[ "$output" == *"153.0.8010.48"* ]]
}

@test "browser_check: passes clean when running version directory exists" {
  local mock_app="$BATS_TEST_TMPDIR/Google Chrome.app"
  local fw_dir="$mock_app/Contents/Frameworks/Google Chrome Framework.framework/Versions"
  mkdir -p "$fw_dir/153.0.8010.48"
  ln -s "153.0.8010.48" "$fw_dir/Current"
  mkdir -p "$mock_app/Contents/MacOS"
  touch "$mock_app/Contents/MacOS/Google Chrome"

  local tmp_ps="$BATS_TEST_TMPDIR/clean_ps.txt"
  cat << PS > "$tmp_ps"
  1234 $mock_app/Contents/MacOS/Google Chrome
  5678 $mock_app/Contents/Frameworks/Google Chrome Framework.framework/Versions/153.0.8010.48/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer) --type=renderer
PS

  run python3 "$HELPERS_DIR/browser_check.py" --ps-file "$tmp_ps"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^OK ]]
}

accuracy_baseline() {
  GATEWAY=192.168.1.1
  GW_LOSS=0 GW_LATENCY=2.5 GW_JITTER=0.3
  PUBLIC_OK=1 PUBLIC_CHECKED=1
  DNS_OK=1 DNS_LINES=""
  INET_LOSS=0 INET_LOSS_ALT=0
  IS_WIFI=0
  TCP_REACH_ANY_OK=1
  VPN_ACTIVE=0
  PATH_SPLIT_TUNNEL=0
  MTU_EFFECTIVE=1500
  DHCP_TIME_REMAINING_S=7200
  BUFFERBLOAT_GW_GRADE=""
  BUFFERBLOAT_INET_GRADE=""
  BUFFERBLOAT_GW_DELTA=""
  BUFFERBLOAT_INET_DELTA=""
  SPEEDTEST_DOWN_MBPS=""
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
}

diag_has() {
  local rule="$1"
  for r in "${DIAG_RULE[@]}"; do [ "$r" = "$rule" ] && return 0; done
  return 1
}

diag_sev_for() {
  local rule="$1" i
  for i in "${!DIAG_RULE[@]}"; do
    if [ "${DIAG_RULE[$i]}" = "$rule" ]; then printf '%s\n' "${DIAG_SEV[$i]}"; return 0; fi
  done
  return 1
}

diag_text_for() {
  local rule="$1" i
  for i in "${!DIAG_RULE[@]}"; do
    if [ "${DIAG_RULE[$i]}" = "$rule" ]; then printf '%s\n' "${DIAG[$i]}"; return 0; fi
  done
  return 1
}

@test "diagnosis: BR-1 fires when browser desync is detected" {
  accuracy_baseline
  BROWSER_DESYNC_COUNT=1
  BROWSER_DESYNC_APP="Google Chrome"
  BROWSER_DESYNC_RUNNING_VER="153.0.8010.37"
  BROWSER_DESYNC_DISK_VER="153.0.8010.48"
  BROWSER_DESYNC_PID="75770"

  diagnosis_run >/dev/null
  diag_has BR-1 || { echo "BR-1 did not fire"; return 1; }
  [ "$(diag_sev_for BR-1)" = "warn" ]
  [[ "$(diag_text_for BR-1)" == *"We detected that Google Chrome may not be working correctly right now"* ]]
}

@test "diagnosis: BR-1 stays quiet when browser is synchronized" {
  accuracy_baseline
  BROWSER_DESYNC_COUNT=0
  BROWSER_DESYNC_APP=""
  BROWSER_DESYNC_RUNNING_VER=""
  BROWSER_DESYNC_DISK_VER=""

  diagnosis_run >/dev/null
  ! diag_has BR-1 || { echo "BR-1 fired unexpectedly"; return 1; }
}

@test "diagnosis: BR-1 outranks advisory WS-1 in most_likely_root_cause" {
  accuracy_baseline
  IS_WIFI=1
  WIFI_SCAN_CURRENT_CHANNEL_NEIGHBORS=8
  THRESH_WIFI_CHANNEL_NEIGHBOURS=5
  BROWSER_DESYNC_COUNT=1
  BROWSER_DESYNC_APP="Google Chrome"
  BROWSER_DESYNC_RUNNING_VER="153.0.8010.37"
  BROWSER_DESYNC_DISK_VER="153.0.8010.48"
  BROWSER_DESYNC_PID="75770"

  diagnosis_run >/dev/null
  diag_has WS-1 || { echo "WS-1 did not fire"; return 1; }
  diag_has BR-1 || { echo "BR-1 did not fire"; return 1; }
  [[ "$MOST_LIKELY_ROOT_CAUSE" == *"We detected that Google Chrome may not be working correctly right now"* ]]
}

@test "output: build_json preserves BR-1 root cause over weak WiFi W1" {
  accuracy_baseline
  # shellcheck source=../lib/output.sh
  . "$REPO/lib/output.sh"
  IS_WIFI=1
  WIFI_RSSI=-79
  THRESH_WIFI_RSSI_POOR=-75
  BROWSER_DESYNC_COUNT=1
  BROWSER_DESYNC_APP="Google Chrome"
  BROWSER_DESYNC_RUNNING_VER="153.0.8010.53"
  BROWSER_DESYNC_DISK_VER="154.0.8037.58"
  BROWSER_DESYNC_PID="1846"

  diagnosis_run >/dev/null
  diag_has W1 || { echo "W1 did not fire"; return 1; }
  diag_has BR-1 || { echo "BR-1 did not fire"; return 1; }

  local json
  json="$(build_json)"
  local root_cause
  root_cause="$(python3 -c "import json, sys; print(json.loads(sys.stdin.read()).get('most_likely_root_cause', ''))" <<< "$json")"
  [[ "$root_cause" == *"We detected that Google Chrome may not be working correctly right now"* ]]
}

@test "monitor: _mon_rules adds BR-1 when browser desync detected" {
  # shellcheck source=../lib/monitor.sh
  . "$REPO/lib/monitor.sh"
  MON_LINK_UP=1
  MON_BROWSER_DESYNC_COUNT=1
  MON_BROWSER_DESYNC_APP="Google Chrome"

  _mon_rules
  [[ " $MON_RULES " == *" BR-1 "* ]]
  [ "$MON_SEVERITY" = "warn" ]
}

