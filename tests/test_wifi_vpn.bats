#!/usr/bin/env bats
# With a full-tunnel VPN the default route is a utun device, which is not a
# hardware port. wifi_run used to conclude "Not on WiFi (interface utun4 looks
# wired)" and skip every Wi-Fi check for as long as the VPN was up.

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  STUBS="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUBS"
  cat >"$STUBS/networksetup" <<'EOF'
#!/bin/sh
[ "$1" = "-listallhardwareports" ] || exit 0
cat <<'PORTS'
Hardware Port: Ethernet
Device: en9
Ethernet Address: 00:11:22:33:44:99

Hardware Port: Wi-Fi
Device: en1
Ethernet Address: 00:11:22:33:44:55
PORTS
EOF
  cat >"$STUBS/ifconfig" <<'EOF'
#!/bin/sh
case "$1" in
  en1) echo "en1: flags=8863<UP> mtu 1500"; echo "	status: ${WIFI_STATUS:-active}" ;;
  *)   echo "$1: flags=8051<UP> mtu 1380" ;;
esac
EOF
  cat >"$STUBS/ipconfig" <<'EOF'
#!/bin/sh
[ "$2" = "en1" ] || exit 0
printf '  SSID : Casa Brian\n  BSSID : aa:bb:cc:dd:ee:ff\n  Security : WPA2 Personal\n'
EOF
  chmod +x "$STUBS/networksetup" "$STUBS/ifconfig" "$STUBS/ipconfig"
}

_wifi_run_on() {
  run env PATH="$STUBS:$PATH" WIFI_STATUS="${WIFI_STATUS:-active}" bash -c '
    JSON_MODE=0 QUIET=0 EXPERT=0 REDACT=0 LOG=/dev/null INTERFACE="$2"
    . "$1/lib/thresholds.sh"; . "$1/lib/common.sh"; . "$1/lib/globals.sh"
    . "$1/lib/wifi.sh"
    INTERFACE="$2"
    wifi_run >/dev/null
    printf "IS_WIFI=%s SSID=%s BSSID=%s\n" "$IS_WIFI" "$WIFI_SSID" "$WIFI_BSSID"
  ' _ "$REPO" "$1"
}

@test "a utun default route does not hide the Wi-Fi radio underneath" {
  _wifi_run_on utun4
  [[ "$output" == *"IS_WIFI=1 SSID=Casa Brian BSSID=aa:bb:cc:dd:ee:ff"* ]] || { echo "$output"; return 1; }
}

@test "a tunnel over a Wi-Fi radio that is down still reads as not on Wi-Fi" {
  WIFI_STATUS=inactive _wifi_run_on utun4
  [[ "$output" == *"IS_WIFI=0"* ]] || { echo "$output"; return 1; }
}

@test "a real wired interface is still wired" {
  _wifi_run_on en9
  [[ "$output" == *"IS_WIFI=0"* ]] || { echo "$output"; return 1; }
}
