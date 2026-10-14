#!/usr/bin/env bats
#
# Report-card rows must agree with the diagnosis under them (audit item 15).
#
#   * The Router row required a latency, and at 100% loss there is none, so
#     the row vanished in exactly the case where it matters most.
#   * The Packet size row cut at 1400/1500 regardless of VPN, so PPPoE (1492)
#     and every VPN showed yellow/red while rule M1 — which is VPN-aware and
#     cuts at 1280/1400 — said nothing.

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  JSON_MODE=0 QUIET=0 QUICK=0 EXPERT=0 LOG=/dev/null
  # shellcheck source=../lib/thresholds.sh
  . "$REPO/lib/thresholds.sh"
  # shellcheck source=../lib/common.sh
  . "$REPO/lib/common.sh"
  # shellcheck source=../lib/globals.sh
  . "$REPO/lib/globals.sh"
  # shellcheck source=../lib/speedtest.sh
  . "$REPO/lib/speedtest.sh"
  # shellcheck source=../lib/headline.sh
  . "$REPO/lib/headline.sh"
  FOCUS=ping NO_SPEED=1 NO_BUFFERBLOAT=1
  GATEWAY=192.168.1.1 GW_LOSS=0 GW_LATENCY=2
}

_strip() { printf '%s' "$1" | sed $'s/\x1b\\[[0-9;]*[mK]//g'; }

# ── Router row ───────────────────────────────────────────────────────────

@test "Router row is shown at 100% loss, when there is no latency to print" {
  GW_LOSS=100 GW_LATENCY=""
  run headline_run
  out="$(_strip "$output")"
  [[ "$out" == *"Router"* ]] || { echo "$out"; return 1; }
  [[ "$out" == *"192.168.1.1"* ]]
  [[ "$out" == *"100% loss"* ]]
  [[ "$out" == *"no replies"* ]]
}

@test "Router row still carries latency when there are replies" {
  GW_LOSS=0 GW_LATENCY=2.34
  run headline_run
  out="$(_strip "$output")"
  [[ "$out" == *"0% loss · 2.3 ms"* ]] || { echo "$out"; return 1; }
}

@test "Router row says latency was not measured when loss is partial but there is no latency" {
  GW_LOSS=40 GW_LATENCY=""
  run headline_run
  out="$(_strip "$output")"
  [[ "$out" == *"latency not measured"* ]] || { echo "$out"; return 1; }
}

# ── MTU row ──────────────────────────────────────────────────────────────

_mtu_row() {
  FOCUS=mtu MTU_EFFECTIVE="$1" VPN_ACTIVE="${2:-0}" PATH_SPLIT_TUNNEL="${3:-0}"
  run headline_run
  _strip "$output" | grep 'Packet size'
}

@test "MTU row: PPPoE (1492) is not flagged" {
  run _mtu_row 1492
  [[ "$output" != *"below standard"* ]] && [[ "$output" != *"clamped"* ]]
}

@test "MTU row: no VPN, 1350 is a warning (M1 warns below 1400)" {
  run _mtu_row 1350
  [[ "$output" == *"below standard"* ]]
}

@test "MTU row: no VPN, below 1280 is the severe state (M1 critical)" {
  run _mtu_row 1200
  [[ "$output" == *"severely clamped"* ]]
}

@test "MTU row: a VPN at 1380 is normal tunnel overhead, not a problem" {
  run _mtu_row 1380 1
  [[ "$output" == *"VPN / tunnel overhead (normal)"* ]]
  [[ "$output" != *"below standard"* ]]
}

@test "MTU row: a split tunnel at 1400 is treated like a VPN" {
  run _mtu_row 1400 0 1
  [[ "$output" == *"tunnel overhead"* ]]
}

@test "MTU row: a VPN below 1280 still warns, as M1's VPN branch does" {
  run _mtu_row 1250 1
  [[ "$output" == *"below the IPv6 minimum"* ]]
}

@test "MTU row and rule M1 agree: the row is coloured exactly when M1 fires" {
  # M1 only fires on the diagnosis side for these; whatever the row's colour,
  # both sides must say "something" or both must say "nothing".
  local mtu vpn row_flagged m1_fired
  for vpn in 0 1; do
    for mtu in 1500 1492 1420 1380 1350 1279 1200; do
      FOCUS=mtu MTU_EFFECTIVE="$mtu" VPN_ACTIVE="$vpn" PATH_SPLIT_TUNNEL=0
      row="$(headline_run 2>&1 | sed $'s/\x1b\\[[0-9;]*[mK]//g' | grep 'Packet size' || true)"
      row_flagged=0
      case "$row" in *"clamped"*|*"below standard"*|*"IPv6 minimum"*) row_flagged=1 ;; esac
      m1_fired=0
      if [ "$vpn" -eq 1 ]; then
        [ "$mtu" -lt "$THRESH_MTU_CRIT" ] && m1_fired=1
      else
        [ "$mtu" -lt "$THRESH_MTU_STANDARD" ] && m1_fired=1
      fi
      [ "$row_flagged" -eq "$m1_fired" ] \
        || { echo "mtu=$mtu vpn=$vpn row_flagged=$row_flagged m1=$m1_fired row=[$row]"; return 1; }
    done
  done
}
