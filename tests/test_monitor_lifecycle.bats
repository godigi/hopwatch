#!/usr/bin/env bats
#
# Monitor lifecycle fixes from the 2026-10-14 audit:
#   * `sleep &` inherited the stream's stdout, so after SIGTERM the reader
#     did not see EOF for up to a whole cadence (measured 16.5 s);
#   * MON_INET_RTT was read by _mon_emit before anything had set it, and
#     `set -u` aborted the monitor on an early pause announce;
#   * a failed _mon_emit ended the monitor with exit 0, silently;
#   * _mon_loss_pct had its warm-up floors (80 / 50 packets) inline.

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  HELPERS="$REPO/helpers"
  JSON_MODE=0 QUIET=0 QUICK=0 EXPERT=0 REDACT=0 LOG=/dev/null
  NETDIAG_VERSION="test"
  # shellcheck source=../lib/thresholds.sh
  . "$REPO/lib/thresholds.sh"
  # shellcheck source=../lib/common.sh
  . "$REPO/lib/common.sh"
  # shellcheck source=../lib/globals.sh
  . "$REPO/lib/globals.sh"
  # shellcheck source=../lib/netid.sh
  . "$REPO/lib/netid.sh"
  # shellcheck source=../lib/traffic.sh
  . "$REPO/lib/traffic.sh"
  # shellcheck source=../lib/monitor.sh
  . "$REPO/lib/monitor.sh"
}

_stub_probes() {
  local probe
  for probe in link vpn gateway internet web dns tcp wifi_signal browser public; do
    eval "_mon_probe_$probe() { :; }"
  done
  _mon_probe_link() { MON_LINK_UP=1 MON_NETWORK_ID="n"; }
  _mon_rules() { :; }
  _mon_snapshot_prev() { :; }
  _mon_sleep() { :; }
  MON_STOP=0 MON_PAUSED=0 MON_SEQ=0 MONITOR_COUNT=3
  MONITOR_FAST_INTERVAL=0 MONITOR_DEGRADED_INTERVAL=0
  MONITOR_MEDIUM_INTERVAL=60 MONITOR_SLOW_INTERVAL=300
}

# ── _mon_sleep ───────────────────────────────────────────────────────────

@test "_mon_sleep: a stopped monitor does not keep the stream open" {
  # The consumer (the GUI) reads our stdout through a pipe. A `sleep` child
  # that inherited it holds the write end open after the monitor exits, so
  # the reader waits out the sleep before seeing EOF.
  cat >"$BATS_TEST_TMPDIR/sleeper.sh" <<EOF
. "$REPO/lib/thresholds.sh"; . "$REPO/lib/common.sh"; . "$REPO/lib/globals.sh"
. "$REPO/lib/netid.sh"; . "$REPO/lib/traffic.sh"; . "$REPO/lib/monitor.sh"
MON_STOP=0 MON_REFRESH_REQUESTED=0
trap _mon_on_signal INT TERM
echo started
_mon_sleep 31
echo stopped
EOF
  run python3 -I - "$BATS_TEST_TMPDIR/sleeper.sh" <<'PY'
import subprocess, sys, time
p = subprocess.Popen(["bash", sys.argv[1]], stdout=subprocess.PIPE)
assert p.stdout.readline().strip() == b"started"
time.sleep(1)
t0 = time.time()
p.terminate()
data = p.stdout.read()          # blocks until every writer has closed
print("eof_after=%.1f" % (time.time() - t0))
print(data.decode().strip())
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  secs="$(printf '%s\n' "$output" | sed -n 's/^eof_after=\([0-9]*\).*/\1/p')"
  [ "$secs" -le 5 ] || { echo "reader waited ${secs}s for EOF: $output"; return 1; }
  # And the sleep itself is gone, not merely detached.
  ! pgrep -f 'sleep 31' >/dev/null
}

# ── MON_INET_RTT ─────────────────────────────────────────────────────────

@test "the fields _mon_emit reads before any probe ran are initialised under set -u" {
  run "$BASH" -c '
    JSON_MODE=0 QUIET=0 QUICK=0 EXPERT=0 REDACT=0 LOG=/dev/null NETDIAG_VERSION=t
    . "$1/lib/thresholds.sh"; . "$1/lib/common.sh"; . "$1/lib/globals.sh"
    . "$1/lib/netid.sh"; . "$1/lib/traffic.sh"; . "$1/lib/monitor.sh"
    set -u
    : "$MON_INET_RTT$MON_GW_JITTER$MON_INET_JITTER"
  ' _ "$REPO"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

# ── _mon_emit failure ────────────────────────────────────────────────────

@test "monitor_run: a failing _mon_emit stops the monitor with a message and exit 3, not 0" {
  _stub_probes
  _mon_emit() { return 1; }
  run monitor_run
  [ "$status" -eq 3 ] || { echo "status=$status: $output"; return 1; }
  [[ "$output" == *"a sample could not be written"* ]]
}

@test "monitor_run: a failing emit on the pause announcement is reported too" {
  _stub_probes
  MON_PAUSED=1
  _mon_emit() { return 1; }
  run monitor_run
  [ "$status" -eq 3 ]
}

@test "monitor_run: a normal --monitor-count stop still returns 0" {
  _stub_probes
  _mon_emit() { :; }
  MONITOR_COUNT=2
  run monitor_run
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "bin/hopwatch --monitor passes monitor_run's status through" {
  run grep -n 'monitor_run || _monitor_rc' "$REPO/bin/hopwatch"
  [ "$status" -eq 0 ]
  run grep -n 'exit "\$_monitor_rc"' "$REPO/bin/hopwatch"
  [ "$status" -eq 0 ]
}

# ── _mon_loss_pct floors ─────────────────────────────────────────────────

@test "thresholds.sh owns the warm-up floors and monitor.sh has no inline copies" {
  [ "$MONITOR_LOSS_ONE_DROP_MIN_SENT" -eq 80 ]
  [ "$MONITOR_LOSS_TWO_DROP_MIN_SENT" -eq 50 ]
  run grep -nE 'l == [12] && s < [0-9]+' "$REPO/lib/monitor.sh"
  [ "$status" -ne 0 ]
}

@test "_mon_loss_pct: honours the floors from thresholds.sh" {
  run _mon_loss_pct 40 1
  [ "$output" = "0" ]          # one drop in a warming window: suppressed
  run _mon_loss_pct 100 1
  [ "$output" = "1" ]          # window full enough: reported
  run _mon_loss_pct 40 2
  [ "$output" = "0" ]
  run _mon_loss_pct 60 2
  [ "$output" = "3" ]
  MONITOR_LOSS_ONE_DROP_MIN_SENT=0 run _mon_loss_pct 30 1
  [ "$output" = "3" ]          # the floor is the variable, not a literal
}
