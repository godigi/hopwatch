#!/usr/bin/env bats
# tests/test_dns.bats — unit tests for DNS diagnostic rules: D5, D1, D2

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
  local rule="$1"
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

@test "diagnosis: D5 fires when primary DNS fails but secondary resolver responds" {
  dns_baseline
  DNS_OK=0
  DNS_PRIMARY_FAIL=1
  DNS_FALLBACK_OK=1
  PRIMARY_DNS="192.168.1.1"
  SECONDARY_DNS="8.8.8.8"
  DNS_LINES="192.168.1.1|apple.com||FAIL"$'\n'"8.8.8.8|apple.com|17.253.144.10|OK"$'\n'
  diagnosis_run >/dev/null
  diag_has D5 || { echo "rules: ${DIAG_RULE[*]}"; return 1; }
  [ "$(diag_sev_for D5)" = "warn" ]
  assert_contains "$(diag_text_for D5)" "primary DNS server (192.168.1.1) is not responding"
  assert_contains "$(diag_text_for D5)" "silently falling back to secondary DNS (8.8.8.8)"
  ! diag_has D1 || { echo "D1 fired alongside D5!"; return 1; }
}

@test "diagnosis: D5 stays silent when primary DNS resolver is healthy" {
  dns_baseline
  DNS_OK=1
  diagnosis_run >/dev/null
  ! diag_has D5 || { echo "D5 fired on healthy primary DNS"; return 1; }
  ! diag_has D1 || { echo "D1 fired on healthy DNS"; return 1; }
}

@test "diagnosis: D5 yields to D2 when internet is down and all lookups fail" {
  dns_baseline
  DNS_OK=0
  PUBLIC_OK=0
  DNS_PRIMARY_FAIL=1
  DNS_FALLBACK_OK=0
  DNS_LINES="192.168.1.1|apple.com||FAIL"$'\n'"8.8.8.8|apple.com||FAIL"$'\n'
  diagnosis_run >/dev/null
  diag_has D2 || { echo "D2 did not fire when internet was down"; return 1; }
  ! diag_has D5 || { echo "D5 fired when internet was down"; return 1; }
}

@test "diagnosis: D1 fires when lookups are flaky but not an exclusive primary fallback" {
  dns_baseline
  DNS_OK=0
  PUBLIC_OK=1
  DNS_PRIMARY_FAIL=0
  DNS_FALLBACK_OK=0
  DNS_LINES="1.1.1.1|apple.com||FAIL"$'\n'"1.1.1.1|cloudflare.com|104.16.132.229|OK"$'\n'
  diagnosis_run >/dev/null
  diag_has D1 || { echo "D1 did not fire for flaky DNS; rules: ${DIAG_RULE[*]}"; return 1; }
  ! diag_has D5 || { echo "D5 fired without primary failure"; return 1; }
}
