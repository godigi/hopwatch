#!/usr/bin/env bats
#
# sudo is opt-in and a last resort.
#
# Monitoring and scans are meant to be sudo-free. `sudo -n` never prompts, but
# it runs the privileged command whenever credentials happen to be cached, so
# the old "try it, it can't hurt" fallbacks ran wdutil as root on every
# medium-tier monitor cycle for users who never asked. These tests put a
# `sudo` on PATH that records any call, then prove a default run never makes
# one and an opted-in run does so only after the unprivileged path failed.

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  SHIM="$BATS_TEST_TMPDIR/shim"
  SUDO_LOG="$BATS_TEST_TMPDIR/sudo-called"
  mkdir -p "$SHIM"
  # Succeeds for `sudo -n true` and fakes wdutil, so an opted-in run has
  # something to find; records every invocation either way.
  cat >"$SHIM/sudo" <<SHIM_EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$SUDO_LOG"
case "\$*" in
  *wdutil*) printf '          RSSI                  : -61 dBm\n          Noise                 : -92 dBm\n          Channel               : 36\n' ;;
esac
exit 0
SHIM_EOF
  chmod +x "$SHIM/sudo"
  export PATH="$SHIM:$PATH"
  unset HOPWATCH_ALLOW_SUDO
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
  # shellcheck source=../lib/mtr.sh
  . "$REPO/lib/mtr.sh"
  # An empty helpers dir: the CoreWLAN helper is "unavailable", which is
  # exactly the case that used to fall through to sudo.
  HELPERS_DIR="$BATS_TEST_TMPDIR/no-helpers"
  mkdir -p "$HELPERS_DIR"
}

@test "hopwatch_sudo_allowed: refuses by default even when sudo would work" {
  run hopwatch_sudo_allowed
  [ "$status" -ne 0 ]
  [ ! -e "$SUDO_LOG" ]
}

@test "hopwatch_sudo_allowed: only the exact value 1 opts in" {
  HOPWATCH_ALLOW_SUDO=yes run hopwatch_sudo_allowed
  [ "$status" -ne 0 ]
  HOPWATCH_ALLOW_SUDO=0 run hopwatch_sudo_allowed
  [ "$status" -ne 0 ]
  [ ! -e "$SUDO_LOG" ]
  HOPWATCH_ALLOW_SUDO=1 run hopwatch_sudo_allowed
  [ "$status" -eq 0 ]
}

@test "hopwatch_sudo_allowed: root without sudo installed is refused, not waved through" {
  # Root used to short-circuit before the sudo check, so callers went on to
  # run `sudo -n …` on a machine with no sudo.
  id() { echo 0; }
  EMPTY="$BATS_TEST_TMPDIR/no-sudo-here"
  mkdir -p "$EMPTY"
  PATH="$EMPTY"
  HOPWATCH_ALLOW_SUDO=1 run hopwatch_sudo_allowed
  [ "$status" -ne 0 ]
}

@test "hopwatch_sudo_allowed: root with sudo present is allowed without calling it" {
  id() { echo 0; }
  HOPWATCH_ALLOW_SUDO=1 run hopwatch_sudo_allowed
  [ "$status" -eq 0 ]
  [ ! -e "$SUDO_LOG" ]
}

@test "monitor wifi probe never calls sudo by default" {
  MON_IFACE_TYPE=wifi
  _mon_probe_wifi_signal
  [ ! -e "$SUDO_LOG" ]
  [ -z "$MON_WIFI_RSSI" ]
}

@test "monitor wifi probe uses sudo -n wdutil only when opted in" {
  MON_IFACE_TYPE=wifi
  HOPWATCH_ALLOW_SUDO=1
  _mon_probe_wifi_signal
  [ -e "$SUDO_LOG" ]
  grep -q -- '-n wdutil' "$SUDO_LOG"
  [ "$MON_WIFI_RSSI" = "-61" ]
}

@test "mtr_run never calls sudo by default, even when plain mtr fails" {
  # An mtr that cannot run unprivileged, plus jq, is the old sudo branch.
  printf '#!/bin/sh\nexit 1\n' >"$SHIM/mtr"; chmod +x "$SHIM/mtr"
  printf '#!/bin/sh\nexit 0\n' >"$SHIM/jq";  chmod +x "$SHIM/jq"
  HOPS=()
  run mtr_run
  [ ! -e "$SUDO_LOG" ]
}

@test "mtr_run tries sudo -n mtr only after plain mtr failed and only when opted in" {
  printf '#!/bin/sh\nexit 1\n' >"$SHIM/mtr"; chmod +x "$SHIM/mtr"
  printf '#!/bin/sh\nexit 0\n' >"$SHIM/jq";  chmod +x "$SHIM/jq"
  HOPS=()
  HOPWATCH_ALLOW_SUDO=1 run mtr_run
  [ -e "$SUDO_LOG" ]
  grep -q -- '-n mtr' "$SUDO_LOG"
}

@test "a default --wifi-only run executes no sudo" {
  run env HOPWATCH_LOG_DIR="$BATS_TEST_TMPDIR/logs" \
    "$REPO/bin/hopwatch" --wifi-only --json --no-baseline --no-gping
  [ ! -e "$SUDO_LOG" ]
}

@test "--allow-sudo exports the opt-in and is documented in --help" {
  run grep -n -- '--allow-sudo)' "$REPO/bin/hopwatch"
  [ "$status" -eq 0 ]
  [[ "$output" == *HOPWATCH_ALLOW_SUDO=1* ]]
  run "$REPO/bin/hopwatch" --help
  [[ "$output" == *"--allow-sudo"* ]]
}

@test "no lib/ file calls sudo outside the hopwatch_sudo_allowed gate" {
  # Every executable (non-comment) mention of sudo must live in a file that
  # also consults the gate; repairs.sh and the rest must have none at all.
  for f in "$REPO"/lib/*.sh; do
    calls="$(grep -vE '^[[:space:]]*#' "$f" | grep -E '(^|[^a-z_-])sudo( |$)' | grep -v 'hopwatch_sudo_allowed' || true)"
    [ -z "$calls" ] && continue
    case "$(basename "$f")" in
      common.sh|mtr.sh|monitor.sh|wifi.sh) ;;
      *) echo "unexpected sudo call in $f: $calls"; return 1 ;;
    esac
    if [ "$(basename "$f")" != common.sh ]; then
      grep -q 'hopwatch_sudo_allowed' "$f" || { echo "$f calls sudo with no gate"; return 1; }
    fi
  done
}
