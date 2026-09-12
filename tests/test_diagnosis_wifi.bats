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
