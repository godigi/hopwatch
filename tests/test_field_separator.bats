#!/usr/bin/env bats
#
# Empty fields must stay in their slot.
#
# The Wi-Fi scrapes used to be TAB-separated and read with
# `IFS=$'\t' read -r a b c`. A tab is IFS *whitespace*, so consecutive tabs
# collapse into one separator and every field after an empty one shifted left:
# with no SSID, the BSSID landed in the SSID slot and "WPA2" in the BSSID slot
# (and the shifted SSID fed the network id); with no tx rate, the PHY mode
# landed in tx_rate and the SSID in phy. They are now separated by 0x1f, which
# is not whitespace.

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  JSON_MODE=0 QUIET=0 QUICK=0 EXPERT=0 REDACT=0 LOG=/dev/null
  # shellcheck source=../lib/wifi_common.sh
  . "$REPO/lib/wifi_common.sh"
  # shellcheck source=../lib/thresholds.sh
  . "$REPO/lib/thresholds.sh"
  # shellcheck source=../lib/netid.sh
  . "$REPO/lib/netid.sh"
}

@test "WIFI_FS is not IFS whitespace" {
  [ "$WIFI_FS" = $'\037' ]
  case "$WIFI_FS" in ' '|$'\t'|$'\n') return 1 ;; esac
}

@test "ipconfig summary: an empty SSID does not shift BSSID and security" {
  summary="    BSSID : aa:bb:cc:dd:ee:ff
    Security : WPA2 Personal"
  IFS="$WIFI_FS" read -r ssid bssid sec <<<"$(wifi_parse_ipconfig_summary "$summary")"
  [ -z "$ssid" ]
  [ "$bssid" = "aa:bb:cc:dd:ee:ff" ]
  [ "$sec" = "WPA2 Personal" ]
}

@test "ipconfig summary: an empty BSSID keeps the security in its own slot" {
  summary="    SSID : Home
    Security : WPA3 Personal"
  IFS="$WIFI_FS" read -r ssid bssid sec <<<"$(wifi_parse_ipconfig_summary "$summary")"
  [ "$ssid" = "Home" ]
  [ -z "$bssid" ]
  [ "$sec" = "WPA3 Personal" ]
}

@test "ipconfig summary: all three fields round-trip" {
  summary="    SSID : My Net
    BSSID : aa:bb:cc:dd:ee:ff
    Security : WPA2 Personal"
  IFS="$WIFI_FS" read -r ssid bssid sec <<<"$(wifi_parse_ipconfig_summary "$summary")"
  [ "$ssid" = "My Net" ]
  [ "$bssid" = "aa:bb:cc:dd:ee:ff" ]
  [ "$sec" = "WPA2 Personal" ]
}

@test "wdutil scrape: missing tx rate leaves PHY and SSID in their own slots" {
  raw="    RSSI : -61 dBm
    Noise : -92 dBm
    Channel : 36
    PHY Mode : 802.11ax
    SSID : <redacted>"
  IFS="$WIFI_FS" read -r rssi noise chan tx phy ssid bssid <<<"$(wifi_parse_wdutil "$raw")"
  [ "$rssi" = "-61" ]
  [ "$noise" = "-92" ]
  [ "$chan" = "36" ]
  [ -z "$tx" ]
  [ "$phy" = "802.11ax" ]
  [ "$ssid" = "<redacted>" ]
  [ -z "$bssid" ]
}

@test "candidates: a 2.4 GHz-only candidate leaves the 5 GHz slots empty, not shifted" {
  sp="          Other Local Wi-Fi Networks:
            HomeWiFi:
              BSSID: 11:22:33:44:55:66
              Channel: 6 (2GHz, 20MHz)
              Signal / Noise: -50 dBm / -96 dBm"
  IFS="$WIFI_FS" read -r multi bssid rssi ssid b5 r5 c5 <<<"$(wifi_parse_candidates "$sp" "HomeWiFi" "aa:bb:cc:dd:ee:ff")"
  [ "$multi" = "1" ]
  [ "$bssid" = "11:22:33:44:55:66" ]
  [ "$rssi" = "-50" ]
  [ "$ssid" = "HomeWiFi" ]
  [ -z "$b5" ]
  [ -z "$r5" ]
  [ -z "$c5" ]
}

@test "wifi_telemetry helper: an empty SSID and tx rate keep their slots" {
  run python3 -I -c "
import importlib.util, sys
spec = importlib.util.spec_from_file_location('wt', '$REPO/helpers/wifi_telemetry.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
sys.stdout.write(m.format_line({'rssi': -60, 'noise': -90, 'chan': 36, 'tx': '', 'phy': '802.11ax', 'ssid': '', 'bssid': 'aa:bb:cc:dd:ee:ff'}))
"
  [ "$status" -eq 0 ]
  IFS="$WIFI_FS" read -r rssi noise chan tx phy ssid bssid <<<"$output"
  [ "$rssi" = "-60" ]
  [ -z "$tx" ]
  [ "$phy" = "802.11ax" ]
  [ -z "$ssid" ]
  [ "$bssid" = "aa:bb:cc:dd:ee:ff" ]
}

@test "wifi_telemetry helper: separators and newlines inside an SSID cannot forge a field" {
  run python3 -I -c "
import importlib.util, sys
spec = importlib.util.spec_from_file_location('wt', '$REPO/helpers/wifi_telemetry.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
sys.stdout.write(m.format_line({'rssi': -60, 'noise': -90, 'chan': 36, 'tx': 300, 'phy': '802.11ax', 'ssid': 'a\x1fb\tc\nd', 'bssid': 'aa:bb:cc:dd:ee:ff'}))
"
  [ "$status" -eq 0 ]
  IFS="$WIFI_FS" read -r _ _ _ _ _ ssid bssid <<<"$output"
  [ "$ssid" = "a b c d" ]
  [ "$bssid" = "aa:bb:cc:dd:ee:ff" ]
}

@test "netid_fingerprint_live: reads an empty SSID without shifting the BSSID" {
  # Stub the three commands it shells out to.
  route() { printf '   interface: en0\n   gateway: 192.168.1.1\n'; }
  ipconfig() { printf '    BSSID : aa:bb:cc:dd:ee:ff\n    Security : WPA2 Personal\n'; }
  netid_fingerprint() { FP_ARGS="$1|$2|$3|$4"; }
  netid_fingerprint_live
  [ "$FP_ARGS" = "en0|192.168.1.1||aa:bb:cc:dd:ee:ff" ]
}

# ── A hostile SSID cannot forge neighbouring fields ──────────────────────
# 0x1f is the record separator, and an SSID is arbitrary bytes. The parsers
# strip it from every value they extract.

@test "ipconfig summary: a 0x1f inside the SSID cannot forge the BSSID or security" {
  summary="    SSID : evil"$'\037'"aa:bb:cc:00:00:01"$'\037'"WPA3 Personal
    BSSID : 11:22:33:44:55:66
    Security : Open"
  IFS="$WIFI_FS" read -r ssid bssid sec extra <<<"$(wifi_parse_ipconfig_summary "$summary")"
  [ "$ssid" = "evilaa:bb:cc:00:00:01WPA3 Personal" ]
  [ "$bssid" = "11:22:33:44:55:66" ]
  [ "$sec" = "Open" ]
  [ -z "$extra" ]
}

@test "ipconfig summary: a hostile SSID with no real BSSID still leaves the BSSID empty" {
  summary="    SSID : x"$'\037'"aa:bb:cc:00:00:01"$'\037'"WPA3 Personal"
  IFS="$WIFI_FS" read -r ssid bssid sec <<<"$(wifi_parse_ipconfig_summary "$summary")"
  [ -z "$bssid" ]
  [ -z "$sec" ]
}

@test "wdutil scrape: a 0x1f inside the SSID cannot forge the BSSID" {
  raw="    RSSI : -61 dBm
    SSID : evil"$'\037'"aa:bb:cc:00:00:01
    PHY Mode : 802.11ax"
  IFS="$WIFI_FS" read -r _ _ _ _ phy ssid bssid extra <<<"$(wifi_parse_wdutil "$raw")"
  [ "$phy" = "802.11ax" ]
  [ "$ssid" = "evilaa:bb:cc:00:00:01" ]
  [ -z "$bssid" ]
  [ -z "$extra" ]
}

@test "candidates: a 0x1f inside a neighbouring SSID cannot forge candidate fields" {
  sp="          Other Local Wi-Fi Networks:
            Home"$'\037'"WiFi:
              BSSID: 11:22:33:44:55:66
              Channel: 6 (2GHz, 20MHz)
              Signal / Noise: -50 dBm / -96 dBm"
  out="$(wifi_parse_candidates "$sp" "HomeWiFi" "aa:bb:cc:dd:ee:ff")"
  # Seven fields means exactly six separators; a smuggled one makes seven.
  seps="${out//[^$WIFI_FS]/}"
  [ "${#seps}" -eq 6 ]
  IFS="$WIFI_FS" read -r multi bssid _ ssid _ <<<"$out"
  [ "$multi" = "1" ]
  [ "$bssid" = "11:22:33:44:55:66" ]
  [ "$ssid" = "HomeWiFi" ]
}

@test "wifi_resolve_ssid: separates name and source with WIFI_FS, so an empty name keeps its slot" {
  IFS="$WIFI_FS" read -r name src <<<"$(wifi_resolve_ssid "" "")"
  [ -z "$name" ]
  [ -z "$src" ]
  IFS="$WIFI_FS" read -r name src <<<"$(wifi_resolve_ssid "<redacted>" $'Hotel\tWifi')"
  [ "$name" = $'Hotel\tWifi' ]
  [ "$src" = "caller" ]
}

@test "wifi_resolve_ssid: a 0x1f in a measured or supplied name is dropped" {
  IFS="$WIFI_FS" read -r name src <<<"$(wifi_resolve_ssid "a"$'\037'"b" "")"
  [ "$name" = "ab" ]
  [ "$src" = "system" ]
}

@test "browser_check: fields are 0x1f-separated, so an empty version keeps the PID in its slot" {
  out="DESYNC${WIFI_FS}1${WIFI_FS}Google Chrome${WIFI_FS}${WIFI_FS}153.1${WIFI_FS}1846"
  IFS="$WIFI_FS" read -r status count app running disk pid <<<"$out"
  [ "$status" = "DESYNC" ]
  [ -z "$running" ]
  [ "$disk" = "153.1" ]
  [ "$pid" = "1846" ]
  # The helper itself emits that separator, never a tab.
  run python3 -I "$REPO/helpers/browser_check.py" --ps-file /dev/null
  [ "$status" -eq 0 ]
  [ "$output" = "OK${WIFI_FS}0${WIFI_FS}${WIFI_FS}${WIFI_FS}${WIFI_FS}" ]
}
