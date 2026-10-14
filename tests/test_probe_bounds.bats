#!/usr/bin/env bats
#
# Probe bounds and the unknown-is-not-clean rule (2026-10-14 audit, items 10, 24).
#
# macOS ping prints its statistics ~10 s after the last packet unless the
# reply wait is capped with -W, so any probe wrapped in a shorter with_timeout
# was killed before the summary whenever one reply was lost. That left the
# path-MTU, per-hop loss and TARGET probes reporting "unmeasured" exactly when
# there was loss to measure.

teardown() {
  pkill -f "sleep 413[789]" 2>/dev/null || true
}

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  JSON_MODE=0 QUIET=0 QUICK=0 EXPERT=0 REDACT=0 LOG=/dev/null
  # shellcheck source=../lib/thresholds.sh
  . "$REPO/lib/thresholds.sh"
  # shellcheck source=../lib/common.sh
  . "$REPO/lib/common.sh"
  # shellcheck source=../lib/mtr.sh
  . "$REPO/lib/mtr.sh"
  # shellcheck source=../lib/ipv6.sh
  . "$REPO/lib/ipv6.sh"
}

@test "mtu, mtr, public: every ping call site caps the reply wait with -W" {
  local f found=0 line
  for f in mtu.sh mtr.sh public.sh; do
    while IFS= read -r line; do
      case "$line" in \#*) continue ;; esac
      found=$((found + 1))
      [[ "$line" == *'-W "$PING_REPLY_WAIT_MS"'* ]] \
        || { echo "unbounded ping in lib/$f: $line"; return 1; }
    done < <(awk '
      { cur = $0; sub(/^[ \t]+/, "", cur)
        buf = (buf == "" ? cur : buf " " cur)
        if (buf ~ /\\$/) { sub(/[ \t]*\\$/, "", buf); next }
        print buf; buf = "" }
      END { if (buf != "") print buf }
    ' "$REPO/lib/$f" | grep -E '^[^#]*[^_[:alnum:]#]ping -')
  done
  [ "$found" -ge 3 ] || { echo "only found $found ping call sites"; return 1; }
}

@test "a lossy MTU size still finishes inside its 4 s budget with a summary" {
  # TEST-NET-1 never answers: 3 packets, -W capped. Must end well inside 4 s.
  start=$SECONDS
  run with_timeout 4 ping -D -c 3 -i 0.2 -W "$PING_REPLY_WAIT_MS" -s 1472 192.0.2.1
  elapsed=$((SECONDS - start))
  [ "$status" -ne 124 ] || { echo "killed by with_timeout after ${elapsed}s"; return 1; }
  [ "$elapsed" -le 4 ]
}

# ── _classify_hop_loss ───────────────────────────────────────────────────

@test "_classify_hop_loss: an unmeasured hop is unknown, not clean" {
  run _classify_hop_loss "" 0.0 0.0
  [ "$output" = "unknown" ]
}

@test "_classify_hop_loss: an unmeasured downstream hop is not proof of a clean path" {
  # Lossy hop 4; the only downstream hops were never measured. Before the
  # fix awk read "" as 0 and this came back "rate_limited".
  run _classify_hop_loss 100 "" ""
  [ "$output" = "unknown" ]
}

@test "_classify_hop_loss: a measured clean downstream hop still means rate-limited" {
  run _classify_hop_loss 100 "" 0.0
  [ "$output" = "rate_limited" ]
}

@test "_classify_hop_loss: loss that persists downstream is real loss" {
  run _classify_hop_loss 50 40 60
  [ -z "$output" ]
}

@test "_classify_hop_loss: a lossy last hop (nothing downstream) is real loss" {
  run _classify_hop_loss 50
  [ -z "$output" ]
}

@test "unmeasured downstream does not hide a lossy hop as rate-limited in the report" {
  MTR_FIRST_LOSSY_HOP=""
  parse_mtr_tsv <<<"$(printf '1\t192.168.1.1\t0.0\t3.0\n2\t10.0.0.1\t100.0\t9.0\n3\t1.1.1.1\n')"
  # Hop 2 is lossy and hop 3 was never measured: not called rate-limited,
  # and not named as the first lossy hop either.
  [ -z "$MTR_FIRST_LOSSY_HOP" ]
  [[ "$PER_HOP_LINES" == *"3|1.1.1.1||"* ]]
}

# ── ping_sigint_bound (ping6 has no usable -W) ───────────────────────────

@test "ping_sigint_bound: SIGINT makes a stalled ping print its statistics" {
  fake="$BATS_TEST_TMPDIR/fakeping"
  # Python, not bash: a background job starts with SIGINT ignored, and a bash
  # script cannot trap a signal that was ignored on entry. A C ping installs
  # its handler with signal(), which overrides the inherited ignore, and so
  # does Python's signal.signal.
  cat >"$fake" <<'FAKE_EOF'
#!/usr/bin/env python3
import signal, sys, time
def stats(*_):
    print("--- fake ping statistics ---")
    print("5 packets transmitted, 0 packets received, 100.0% packet loss")
    sys.stdout.flush()
    sys.exit(2)
signal.signal(signal.SIGINT, stats)
time.sleep(20)  # stalled like ping6 waiting out its reply tail
FAKE_EOF
  chmod +x "$fake"
  start=$SECONDS
  run ping_sigint_bound 1 "$fake"
  elapsed=$((SECONDS - start))
  [[ "$output" == *"100.0% packet loss"* ]] || { echo "$output"; return 1; }
  [ "$elapsed" -le 4 ]
}

@test "ping_sigint_bound: a fast ping returns promptly and the killer is reaped" {
  fake="$BATS_TEST_TMPDIR/fastping"
  printf '#!/bin/sh\necho "5 packets transmitted, 5 packets received, 0.0%% packet loss"\n' >"$fake"
  chmod +x "$fake"
  start=$SECONDS
  run ping_sigint_bound 30 "$fake"
  elapsed=$((SECONDS - start))
  [[ "$output" == *"0.0% packet loss"* ]]
  [ "$elapsed" -le 3 ]
}

@test "ping_sigint_bound: leaves no killer sleep, scratch file or registry entry behind" {
  fake="$BATS_TEST_TMPDIR/fastping"
  printf '#!/bin/sh\necho "5 packets transmitted, 5 packets received, 0.0%% packet loss"\n' >"$fake"
  chmod +x "$fake"
  export TMPDIR="$BATS_TEST_TMPDIR"
  NETDIAG_TMP_DIR="sentinel"
  # 4137 is a value nothing else sleeps for, so the pgrep below sees only
  # this function's killer.
  out="$(ping_sigint_bound 4137 "$fake")"
  [[ "$out" == *"0.0% packet loss"* ]]
  # The handoff variable every caller reads is untouched, and the registry
  # no longer lists the scratch directory.
  [ "$NETDIAG_TMP_DIR" = "sentinel" ]
  [ -z "$_NETDIAG_TMP_DIRS" ]
  [ -z "$(find "$BATS_TEST_TMPDIR" -maxdepth 1 -name 'hopwatch-ping.*')" ]
  ! pgrep -f 'sleep 4137' >/dev/null
}

@test "ping_sigint_bound: a signal to its process group takes the ping, killer sleep and scratch dir with it" {
  fake="$BATS_TEST_TMPDIR/stalledping"
  printf '#!/bin/sh\nexec sleep 4138.5\n' >"$fake"
  chmod +x "$fake"
  export TMPDIR="$BATS_TEST_TMPDIR"
  # Job control gives the background job its own process group, which is
  # what a Ctrl-C or `launchctl stop` signals: the whole group at once.
  set -m
  ( ping_sigint_bound 4139 "$fake" ) >/dev/null 2>&1 3>&- &
  bg=$!
  sleep 1
  pgrep -f 'sleep 4139' >/dev/null   # the killer is genuinely waiting
  kill -TERM -- "-$bg"
  wait "$bg" 2>/dev/null || true
  set +m
  sleep 1
  ! pgrep -f 'sleep 4139' >/dev/null
  ! pgrep -f 'sleep 4138.5' >/dev/null
  [ -z "$(find "$BATS_TEST_TMPDIR" -maxdepth 1 -name 'hopwatch-ping.*')" ]
}

@test "ipv6_run bounds ping6 with ping_sigint_bound and never passes it -W" {
  run grep -nE 'ping_sigint_bound .* ping6 ' "$REPO/lib/ipv6.sh"
  [ "$status" -eq 0 ]
  run grep -nE '^[^#]*ping6 .*-W' "$REPO/lib/ipv6.sh"
  [ "$status" -ne 0 ]
}

# ── ipv6_pick_global_addr ────────────────────────────────────────────────

@test "ipv6_pick_global_addr: loopback ::1 is skipped" {
  run ipv6_pick_global_addr "$(printf '\tinet6 ::1 prefixlen 128\n\tinet6 2001:db8:1::5 prefixlen 64\n')"
  [ "$output" = "2001:db8:1::5" ]
}

@test "ipv6_pick_global_addr: addresses merely containing ::1 are kept" {
  for a in 2001:db8::1a2b 2001:db8::10 2001:db8::1f 2600:1700:abcd::1; do
    run ipv6_pick_global_addr "$(printf '\tinet6 fe80::1%%en0 prefixlen 64 scopeid 0x4\n\tinet6 %s prefixlen 64\n' "$a")"
    [ "$output" = "$a" ] || { echo "dropped $a: got '$output'"; return 1; }
  done
}

@test "ipv6_pick_global_addr: only link-local and loopback gives no address" {
  run ipv6_pick_global_addr "$(printf '\tinet6 fe80::1%%en0 prefixlen 64 scopeid 0x4\n\tinet6 ::1 prefixlen 128\n')"
  [ -z "$output" ]
}
