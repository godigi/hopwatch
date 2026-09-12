#!/usr/bin/env bats
# tests/test_diagnosis_accuracy.bats — unit tests for M1, DH-1, B1, B2 accuracy guardrails

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

@test "diagnosis: M1 stays silent on VPN with standard tunnel MTU (1380 bytes)" {
  accuracy_baseline
  VPN_ACTIVE=1
  MTU_EFFECTIVE=1380
  diagnosis_run >/dev/null
  ! diag_has M1 || { echo "M1 fired on VPN with MTU 1380"; return 1; }
}

@test "diagnosis: M1 emits warn (not critical) on VPN when MTU is below 1280 bytes" {
  accuracy_baseline
  VPN_ACTIVE=1
  MTU_EFFECTIVE=1200
  diagnosis_run >/dev/null
  diag_has M1 || { echo "M1 did not fire on VPN with MTU 1200"; return 1; }
  [ "$(diag_sev_for M1)" = "warn" ]
}

@test "diagnosis: M1 emits warn on direct link when MTU is 1380 bytes" {
  accuracy_baseline
  VPN_ACTIVE=0
  MTU_EFFECTIVE=1380
  diagnosis_run >/dev/null
  diag_has M1 || { echo "M1 did not fire on direct link with MTU 1380"; return 1; }
  [ "$(diag_sev_for M1)" = "warn" ]
}

@test "diagnosis: M1 emits critical on direct link when MTU is below 1280 bytes" {
  accuracy_baseline
  VPN_ACTIVE=0
  MTU_EFFECTIVE=1200
  diagnosis_run >/dev/null
  diag_has M1 || { echo "M1 did not fire on direct link with MTU 1200"; return 1; }
  [ "$(diag_sev_for M1)" = "critical" ]
}

@test "diagnosis: DH-1 stays silent when DHCP lease has 45 minutes remaining" {
  accuracy_baseline
  DHCP_TIME_REMAINING_S=2700 # 45 minutes
  diagnosis_run >/dev/null
  ! diag_has DH-1 || { echo "DH-1 fired with 45 minutes remaining"; return 1; }
}

@test "diagnosis: DH-1 fires warn when DHCP lease has under 10 minutes remaining" {
  accuracy_baseline
  DHCP_TIME_REMAINING_S=480 # 8 minutes
  diagnosis_run >/dev/null
  diag_has DH-1 || { echo "DH-1 did not fire with 8 minutes remaining"; return 1; }
  [ "$(diag_sev_for DH-1)" = "warn" ]
}

@test "diagnosis: B1 and B2 demote grade D to warn on fast connection (>= 150 Mbps)" {
  accuracy_baseline
  SPEEDTEST_DOWN_MBPS=300
  BUFFERBLOAT_GW_GRADE="D"
  BUFFERBLOAT_GW_DELTA=180
  BUFFERBLOAT_INET_GRADE="D"
  BUFFERBLOAT_INET_DELTA=190
  diagnosis_run >/dev/null
  diag_has B1 || { echo "B1 did not fire"; return 1; }
  diag_has B2 || { echo "B2 did not fire"; return 1; }
  [ "$(diag_sev_for B1)" = "warn" ]
  [ "$(diag_sev_for B2)" = "warn" ]
}

@test "diagnosis: B1 and B2 fire critical for grade D on unmeasured or constrained connection" {
  accuracy_baseline
  SPEEDTEST_DOWN_MBPS=25
  BUFFERBLOAT_GW_GRADE="D"
  BUFFERBLOAT_GW_DELTA=180
  BUFFERBLOAT_INET_GRADE="D"
  BUFFERBLOAT_INET_DELTA=190
  diagnosis_run >/dev/null
  diag_has B1 || { echo "B1 did not fire"; return 1; }
  diag_has B2 || { echo "B2 did not fire"; return 1; }
  [ "$(diag_sev_for B1)" = "critical" ]
  [ "$(diag_sev_for B2)" = "critical" ]
}

@test "remediation: D1 never instructs modifying System Settings network adapter DNS" {
  accuracy_baseline
  PUBLIC_OK=1
  DNS_OK=0
  DNS_LINES="1.1.1.1|apple.com||FAIL"
  diagnosis_run >/dev/null
  diag_has D1 || { echo "D1 did not fire"; return 1; }
  local text
  text="$(diag_text_for D1)"
  [[ "$text" != *"System Settings"* ]]
  [[ "$text" == *"Restart your router"* ]] || [[ "$text" == *"Encrypted DNS"* ]]
}

@test "remediation: D2 never instructs modifying System Settings network adapter DNS" {
  accuracy_baseline
  PUBLIC_OK=0
  DNS_OK=0
  DNS_LINES="1.1.1.1|apple.com||FAIL"
  diagnosis_run >/dev/null
  diag_has D2 || { echo "D2 did not fire"; return 1; }
  local text
  text="$(diag_text_for D2)"
  [[ "$text" != *"System Settings"* ]]
  [[ "$text" == *"restart your router"* ]]
}

@test "remediation: D3 never instructs modifying System Settings network adapter DNS" {
  accuracy_baseline
  SYS_RES="192.168.1.1"
  SYS_RES_MS=350
  DNS_OK=1
  diagnosis_run >/dev/null
  diag_has D3 || { echo "D3 did not fire"; return 1; }
  local text
  text="$(diag_text_for D3)"
  [[ "$text" != *"System Settings"* ]]
  [[ "$text" == *"Restart your router"* ]]
}

@test "remediation: D4 never instructs modifying System Settings network adapter DNS" {
  accuracy_baseline
  DNS_NXDOMAIN_HIJACK_IP="198.105.254.11"
  diagnosis_run >/dev/null
  diag_has D4 || { echo "D4 did not fire"; return 1; }
  local text
  text="$(diag_text_for D4)"
  [[ "$text" != *"System Settings"* ]]
  [[ "$text" == *"Encrypted DNS"* ]]
}

@test "remediation: V6-2 advises router restart and never advises disabling IPv6 on Mac" {
  accuracy_baseline
  IPV6_DNS_FAIL="2001:4860:4860::8888"
  DNS_OK=1
  diagnosis_run >/dev/null
  diag_has V6-2 || { echo "V6-2 did not fire"; return 1; }
  local text
  text="$(diag_text_for V6-2)"
  [[ "$text" != *"disable IPv6"* ]]
  [[ "$text" != *"Link-local"* ]]
  [[ "$text" == *"Restart your router"* ]]
  [[ "$text" == *"no settings changes are needed on your Mac"* ]]
}

@test "remediation: B1 emphasizes bandwidth hygiene and never advises replacing the router" {
  accuracy_baseline
  BUFFERBLOAT_GW_GRADE="D"
  BUFFERBLOAT_GW_DELTA=180
  SPEEDTEST_DOWN_MBPS=25
  diagnosis_run >/dev/null
  diag_has B1 || { echo "B1 did not fire"; return 1; }
  local text
  text="$(diag_text_for B1)"
  [[ "$text" != *"replace"* ]]
  [[ "$text" == *"pause"* ]] || [[ "$text" == *"QoS"* ]]
}

