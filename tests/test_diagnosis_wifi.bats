#!/usr/bin/env bats
#
# tests/test_diagnosis_wifi.bats — unit tests for Wi-Fi diagnostic rules:
#   W4: Wi-Fi transmit rate collapsed despite strong RSSI
#   W5: Asymmetric Wi-Fi link / return path loss with strong router beacon
#   W2: Low SNR floor (< 20 dB) with strong signal

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  JSON_MODE=0 QUIET=0 QUICK=0 EXPERT=0 LOG=/dev/null
  # shellcheck source=../lib/thresholds.sh
  . "$REPO/lib/thresholds.sh"
  # shellcheck source=../lib/common.sh
  . "$REPO/lib/common.sh"
  # shellcheck source=../lib/globals.sh
  . "$REPO/lib/globals.sh"
  # shellcheck source=../lib/traffic.sh
  . "$REPO/lib/traffic.sh"
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
}

wifi_baseline() {
  GATEWAY=192.168.1.1
  GW_LOSS=0 GW_LATENCY=2.5 GW_JITTER=0.3
  PUBLIC_OK=1 PUBLIC_CHECKED=1
  DNS_OK=1 DNS_LINES="1.1.1.1 ok"
  INET_LOSS=0 INET_LOSS_ALT=0
  IS_WIFI=1
  TCP_REACH_ANY_OK=1
  WIFI_SSID="HomeNet"
  WIFI_BSSID="aa:bb:cc:dd:ee:ff"
  WIFI_RSSI=-50
  WIFI_SNR=35
  WIFI_TX=866
  WIFI_CHAN="36"
  WIFI_SCAN_CURRENT_CHANNEL="36"
  WIFI_SCAN_CURRENT_BAND="5GHz"
  WIFI_CANDIDATE_5GHZ_RSSI=""
  WIFI_CANDIDATE_5GHZ_BSSID=""
  WIFI_CANDIDATE_5GHZ_CHAN=""
  WIFI_AWDL_ACTIVE=0
  WIFI_SCAN_CURRENT_CHANNEL_NEIGHBORS=0
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
}

diag_has() {
  local rule="$1"
  for r in "${DIAG_RULE[@]}"; do
    [ "$r" = "$rule" ] && return 0
  done
  return 1
}

diag_text_for() {
  local rule="$1" i
  for i in "${!DIAG_RULE[@]}"; do
    if [ "${DIAG_RULE[$i]}" = "$rule" ]; then
      printf '%s\n' "${DIAG[$i]}"
      return 0
    fi
  done
  return 1
}

diag_sev_for() {
  local rule="$1" i
  for i in "${!DIAG_RULE[@]}"; do
    if [ "${DIAG_RULE[$i]}" = "$rule" ]; then
      printf '%s\n' "${DIAG_SEV[$i]}"
      return 0
    fi
  done
  return 1
}

assert_contains() {
  case "$1" in (*"$2"*) return 0 ;; esac
  echo "expected to contain: [$2]" >&2
  echo "actual:              [$1]" >&2
  return 1
}

# ── W4: Wi-Fi transmit rate collapsed ─────────────────────────────────────

@test "diagnosis: W4 fires when tx_rate collapses despite strong RSSI" {
  wifi_baseline
  WIFI_RSSI=-55
  WIFI_TX=24
  diagnosis_run >/dev/null
  diag_has W4 || { echo "rules: ${DIAG_RULE[*]}"; return 1; }
  [ "$(diag_sev_for W4)" = "warn" ]
  assert_contains "$(diag_text_for W4)" "negotiated transmit rate has collapsed to 24 Mbps"
  assert_contains "$(diag_text_for W4)" "Moving closer to your router"
}

@test "diagnosis: W4 stays silent when tx_rate is normal" {
  wifi_baseline
  WIFI_RSSI=-55
  WIFI_TX=300
  diagnosis_run >/dev/null
  ! diag_has W4 || { echo "W4 fired unexpectedly"; return 1; }
}

@test "diagnosis: W4 stays silent when RSSI is weak (covered by W1 instead)" {
  wifi_baseline
  WIFI_RSSI=-78
  WIFI_TX=24
  diagnosis_run >/dev/null
  ! diag_has W4 || { echo "W4 fired on weak RSSI"; return 1; }
  diag_has W1 || { echo "W1 did not fire for weak signal"; return 1; }
}

@test "diagnosis: W4 stays silent on wired Ethernet" {
  wifi_baseline
  IS_WIFI=0
  WIFI_RSSI=""
  WIFI_TX=24
  diagnosis_run >/dev/null
  ! diag_has W4 || { echo "W4 fired on wired Ethernet"; return 1; }
}

@test "diagnosis: W4 stays silent when tx_rate is not measured" {
  wifi_baseline
  WIFI_RSSI=-50
  WIFI_TX=""
  diagnosis_run >/dev/null
  ! diag_has W4 || { echo "W4 fired with empty tx_rate"; return 1; }
}

# ── W5: Asymmetric Wi-Fi link (return path loss) ──────────────────────────

@test "diagnosis: W5 fires on strong RSSI with gateway loss, preventing G2" {
  wifi_baseline
  WIFI_RSSI=-50
  GW_LOSS=25
  diagnosis_run >/dev/null
  diag_has W5 || { echo "rules: ${DIAG_RULE[*]}"; return 1; }
  [ "$(diag_sev_for W5)" = "warn" ]
  assert_contains "$(diag_text_for W5)" "struggling to hear your Mac through walls"
  assert_contains "$(diag_text_for W5)" "packet loss (25%)"
  # Crucial: G2 must NOT fire (router is not the problem, asymmetric wireless link is)
  ! diag_has G2 || { echo "G2 fired alongside W5!"; return 1; }
}

@test "diagnosis: W5 stays silent on a clean gateway (0% loss)" {
  wifi_baseline
  WIFI_RSSI=-50
  GW_LOSS=0
  diagnosis_run >/dev/null
  ! diag_has W5 || { echo "W5 fired with zero loss"; return 1; }
}

@test "diagnosis: with weak Wi-Fi signal, G1 fires instead of W5" {
  wifi_baseline
  WIFI_RSSI=-75
  GW_LOSS=25
  diagnosis_run >/dev/null
  ! diag_has W5 || { echo "W5 fired on weak signal"; return 1; }
  diag_has G1 || { echo "G1 did not fire for weak signal gateway loss"; return 1; }
}

@test "diagnosis: on wired Ethernet with loss, G2 fires instead of W5" {
  wifi_baseline
  IS_WIFI=0
  WIFI_RSSI=""
  GW_LOSS=25
  diagnosis_run >/dev/null
  ! diag_has W5 || { echo "W5 fired on wired Ethernet"; return 1; }
  diag_has G2 || { echo "G2 did not fire on wired Ethernet loss"; return 1; }
}

# ── W2: Low SNR floor ─────────────────────────────────────────────────────

@test "diagnosis: low SNR (< 20 dB) emits W2 even when RSSI is in the green range" {
  wifi_baseline
  WIFI_RSSI=-50
  WIFI_NOISE=-65
  WIFI_SNR=15
  diagnosis_run >/dev/null
  diag_has W2 || { echo "W2 did not fire on low SNR; rules: ${DIAG_RULE[*]}"; return 1; }
  [ "$(diag_sev_for W2)" = "warn" ]
  assert_contains "$(diag_text_for W2)" "interference (SNR 15 dB)"
}

# ── AWDL-1: Apple Wireless Direct Link channel hopping ─────────────────────

@test "diagnosis: AWDL-1 fires when awdl0 is active and ping exhibits large RTT spike" {
  wifi_baseline
  WIFI_AWDL_ACTIVE=1
  GW_LOSS=0
  GW_LATENCY=12.5
  GW_RTT_MAX=245.8
  diagnosis_run >/dev/null
  diag_has AWDL-1 || { echo "rules: ${DIAG_RULE[*]}"; return 1; }
  [ "$(diag_sev_for AWDL-1)" = "warn" ]
  assert_contains "$(diag_text_for AWDL-1)" "Apple Wireless Direct Link (AirDrop/Sidecar)"
  assert_contains "$(diag_text_for AWDL-1)" "up to 245 ms"
}

@test "diagnosis: AWDL-1 fires on high jitter even when max RTT is omitted" {
  wifi_baseline
  WIFI_AWDL_ACTIVE=1
  GW_LOSS=0
  GW_LATENCY=14.0
  GW_JITTER=48.2
  GW_RTT_MAX=""
  diagnosis_run >/dev/null
  diag_has AWDL-1 || { echo "AWDL-1 did not fire on jitter; rules: ${DIAG_RULE[*]}"; return 1; }
  assert_contains "$(diag_text_for AWDL-1)" "up to 48 ms"
}

@test "diagnosis: AWDL-1 stays silent when awdl0 is inactive" {
  wifi_baseline
  WIFI_AWDL_ACTIVE=0
  GW_LOSS=0
  GW_LATENCY=12.0
  GW_RTT_MAX=300.0
  GW_JITTER=55.0
  diagnosis_run >/dev/null
  ! diag_has AWDL-1 || { echo "AWDL-1 fired with inactive AWDL"; return 1; }
}

@test "diagnosis: AWDL-1 stays silent on wired Ethernet" {
  wifi_baseline
  IS_WIFI=0
  WIFI_AWDL_ACTIVE=1
  GW_LOSS=0
  GW_LATENCY=2.0
  GW_RTT_MAX=300.0
  diagnosis_run >/dev/null
  ! diag_has AWDL-1 || { echo "AWDL-1 fired on wired Ethernet"; return 1; }
}

@test "diagnosis: AWDL-1 stays silent when baseline ping is high" {
  wifi_baseline
  WIFI_AWDL_ACTIVE=1
  GW_LOSS=0
  GW_LATENCY=65.0
  GW_RTT_MAX=350.0
  diagnosis_run >/dev/null
  ! diag_has AWDL-1 || { echo "AWDL-1 fired when baseline ping was already high"; return 1; }
}

@test "diagnosis: AWDL-1 stays silent when gateway has loss" {
  wifi_baseline
  WIFI_AWDL_ACTIVE=1
  GW_LOSS=15.0
  GW_LATENCY=12.0
  GW_RTT_MAX=350.0
  diagnosis_run >/dev/null
  ! diag_has AWDL-1 || { echo "AWDL-1 fired when gateway had loss"; return 1; }
}

# ── W6: Suboptimal Wi-Fi band trapping (2.4 GHz vs 5 GHz) ──────────────────

@test "diagnosis: W6 fires as info when on 2.4 GHz and strong 5 GHz candidate is available" {
  wifi_baseline
  WIFI_RSSI=-55
  WIFI_CHAN="6"
  WIFI_SCAN_CURRENT_CHANNEL="6"
  WIFI_SCAN_CURRENT_BAND="2GHz"
  WIFI_TX=144
  WIFI_CANDIDATE_5GHZ_BSSID="aa:bb:cc:dd:ee:02"
  WIFI_CANDIDATE_5GHZ_RSSI=-58
  WIFI_CANDIDATE_5GHZ_CHAN="36"
  diagnosis_run >/dev/null
  diag_has W6 || { echo "rules: ${DIAG_RULE[*]}"; return 1; }
  [ "$(diag_sev_for W6)" = "info" ]
  assert_contains "$(diag_text_for W6)" "connected to the 2.4 GHz band (channel 6, 144 Mbps)"
  assert_contains "$(diag_text_for W6)" "faster 5 GHz band on \"HomeNet\" is available with strong signal (-58 dBm)"
  assert_contains "$(diag_text_for W6)" "Toggling Wi-Fi off and back on will prompt your Mac to join 5 GHz"
}

@test "diagnosis: W6 escalates to warn when transmit rate is collapsed (<= 54 Mbps)" {
  wifi_baseline
  WIFI_RSSI=-55
  WIFI_CHAN="6"
  WIFI_SCAN_CURRENT_CHANNEL="6"
  WIFI_SCAN_CURRENT_BAND="2GHz"
  WIFI_TX=48
  WIFI_CANDIDATE_5GHZ_BSSID="aa:bb:cc:dd:ee:02"
  WIFI_CANDIDATE_5GHZ_RSSI=-58
  diagnosis_run >/dev/null
  diag_has W6 || { echo "rules: ${DIAG_RULE[*]}"; return 1; }
  [ "$(diag_sev_for W6)" = "warn" ]
  assert_contains "$(diag_text_for W6)" "48 Mbps"
}

@test "diagnosis: W6 stays silent when 5 GHz candidate is weak (< -65 dBm)" {
  wifi_baseline
  WIFI_RSSI=-55
  WIFI_CHAN="6"
  WIFI_SCAN_CURRENT_CHANNEL="6"
  WIFI_SCAN_CURRENT_BAND="2GHz"
  WIFI_CANDIDATE_5GHZ_BSSID="aa:bb:cc:dd:ee:02"
  WIFI_CANDIDATE_5GHZ_RSSI=-72
  diagnosis_run >/dev/null
  ! diag_has W6 || { echo "W6 fired when 5 GHz candidate is weak (-72 dBm)"; return 1; }
}

@test "diagnosis: W6 stays silent when delta between 2.4 GHz and 5 GHz is too large (> 12 dBm)" {
  wifi_baseline
  WIFI_RSSI=-48
  WIFI_CHAN="6"
  WIFI_SCAN_CURRENT_CHANNEL="6"
  WIFI_SCAN_CURRENT_BAND="2GHz"
  WIFI_CANDIDATE_5GHZ_BSSID="aa:bb:cc:dd:ee:02"
  WIFI_CANDIDATE_5GHZ_RSSI=-64 # delta = 16 dBm > 12 dBm
  diagnosis_run >/dev/null
  ! diag_has W6 || { echo "W6 fired when delta was 16 dBm"; return 1; }
}

@test "diagnosis: W6 stays silent when already connected to 5 GHz" {
  wifi_baseline
  WIFI_RSSI=-55
  WIFI_CHAN="36"
  WIFI_SCAN_CURRENT_CHANNEL="36"
  WIFI_SCAN_CURRENT_BAND="5GHz"
  WIFI_CANDIDATE_5GHZ_BSSID="aa:bb:cc:dd:ee:02"
  WIFI_CANDIDATE_5GHZ_RSSI=-58
  diagnosis_run >/dev/null
  ! diag_has W6 || { echo "W6 fired when already on 5 GHz"; return 1; }
}

@test "diagnosis: W6 stays silent on wired connection" {
  wifi_baseline
  IS_WIFI=0
  WIFI_CHAN="6"
  WIFI_CANDIDATE_5GHZ_BSSID="aa:bb:cc:dd:ee:02"
  WIFI_CANDIDATE_5GHZ_RSSI=-58
  diagnosis_run >/dev/null
  ! diag_has W6 || { echo "W6 fired on wired link"; return 1; }
}

@test "diagnosis: W6 stays silent when candidate BSSID is the current BSSID" {
  wifi_baseline
  WIFI_RSSI=-55
  WIFI_CHAN="6"
  WIFI_SCAN_CURRENT_CHANNEL="6"
  WIFI_SCAN_CURRENT_BAND="2GHz"
  WIFI_CANDIDATE_5GHZ_BSSID="aa:bb:cc:dd:ee:ff" # matches current WIFI_BSSID
  WIFI_CANDIDATE_5GHZ_RSSI=-58
  diagnosis_run >/dev/null
  ! diag_has W6 || { echo "W6 fired for current BSSID"; return 1; }
}

