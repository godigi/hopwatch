#!/usr/bin/env bats
#
# lib/launchd.sh, lib/watch.sh and the way bin/hopwatch names itself.
#
# Regressions from the 2026-10-14 audit:
#   * a relative invocation wrote a relative path into the plist and slipped
#     past the ~/Documents TCC guard;
#   * a path or log dir containing & or < produced a plist launchd rejects;
#   * `launchctl load` failures were ignored, so install "succeeded";
#   * --watch called exit 1/2 (warnings / critical diagnosis) a failure.

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  FAKE_HOME="$BATS_TEST_TMPDIR/home"
  SHIM="$BATS_TEST_TMPDIR/shim"
  mkdir -p "$FAKE_HOME/Library/LaunchAgents" "$SHIM"
}

# A checkout copy at a path with an XML-special character in it, outside the
# folders the TCC guard refuses.
_install_copy() {
  COPY="$BATS_TEST_TMPDIR/opt&dir/hopwatch"
  mkdir -p "$COPY"
  cp -R "$REPO/bin" "$REPO/lib" "$REPO/helpers" "$COPY/"
}

_launchctl_shim() {
  # $1 = exit status, $2 = what it prints
  printf '#!/bin/sh\nprintf "%%s\\n" "%s"\nexit %s\n' "$2" "$1" >"$SHIM/launchctl"
  chmod +x "$SHIM/launchctl"
}

@test "--install-watcher: XML-special characters in paths are escaped in the plist" {
  _install_copy
  _launchctl_shim 0 ""
  run env HOME="$FAKE_HOME" PATH="$SHIM:$PATH" HOPWATCH_LOG_DIR="$BATS_TEST_TMPDIR/l&d" \
    "$COPY/bin/hopwatch" --install-watcher
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  plist="$(ls "$FAKE_HOME"/Library/LaunchAgents/*.plist)"
  grep -q 'opt&amp;dir/hopwatch/bin/hopwatch' "$plist"
  grep -q 'l&amp;d/watcher.stdout.log' "$plist"
  ! grep -q 'opt&dir' "$plist"
  plutil -lint "$plist" >/dev/null
}

@test "--install-watcher: a relative invocation writes an absolute path" {
  _install_copy
  _launchctl_shim 0 ""
  cd "$COPY"
  run env HOME="$FAKE_HOME" PATH="$SHIM:$PATH" bin/hopwatch --install-watcher
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  plist="$(ls "$FAKE_HOME"/Library/LaunchAgents/*.plist)"
  grep -q '<string>/' "$plist"
  ! grep -q '<string>bin/hopwatch</string>' "$plist"
}

@test "--install-watcher: a relative invocation from ~/Documents is still refused" {
  mkdir -p "$FAKE_HOME/Documents/netdiag"
  cp -R "$REPO/bin" "$REPO/lib" "$REPO/helpers" "$FAKE_HOME/Documents/netdiag/"
  cd "$FAKE_HOME/Documents/netdiag"
  run env HOME="$FAKE_HOME" bin/hopwatch --install-watcher
  [ "$status" -eq 3 ]
  [[ "$output" == *"watcher not installed"* ]]
}

@test "--install-watcher: a failed launchctl load is reported, not swallowed" {
  _install_copy
  _launchctl_shim 5 "Load failed: 5: Input/output error"
  run env HOME="$FAKE_HOME" PATH="$SHIM:$PATH" "$COPY/bin/hopwatch" --install-watcher
  [ "$status" -eq 3 ]
  [[ "$output" == *"could not load"* ]]
  [[ "$output" != *"installed:"* ]]
}

@test "--install-recorder: a failed launchctl load is reported, not swallowed" {
  _install_copy
  # launchctl that exits 0 but complains, as the legacy `load` can.
  _launchctl_shim 0 "Load failed: invalid property list"
  run env HOME="$FAKE_HOME" PATH="$SHIM:$PATH" "$COPY/bin/hopwatch" --install-recorder
  [ "$status" -eq 3 ]
  [[ "$output" == *"could not load"* ]]
}

# --watch ------------------------------------------------------------------

_watch_with_child_exit() {
  # $1 = exit status the fake child returns. Runs --watch for ~2.5 s.
  local child="$BATS_TEST_TMPDIR/fake-hopwatch" out="$BATS_TEST_TMPDIR/watch.out"
  printf '#!/bin/sh\nexit %s\n' "$1" >"$child"
  chmod +x "$child"
  bash -c '
    JSON_MODE=0 QUIET=0 LOG=/dev/null
    . "$1/lib/thresholds.sh"; . "$1/lib/common.sh"; . "$1/lib/watch.sh"
    SCRIPT_PATH="$2" WATCH_INTERVAL_S=1 LOG_DIR="$3"
    watch_run
  ' _ "$REPO" "$child" "$BATS_TEST_TMPDIR" >"$out" 2>&1 &
  local pid=$!
  sleep 2.5
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  WATCH_OUT="$(cat "$out")"
}

@test "--watch: a child exiting 1 (warnings) is not reported as a failure" {
  _watch_with_child_exit 1
  [[ "$WATCH_OUT" == *"iter 2"* ]] || { echo "$WATCH_OUT"; return 1; }
  [[ "$WATCH_OUT" != *"failed"* ]]
  [[ "$WATCH_OUT" != *"timed out"* ]]
}

@test "--watch: a child exiting 2 (critical) is not reported as a failure" {
  _watch_with_child_exit 2
  [[ "$WATCH_OUT" != *"failed"* ]]
}

@test "--watch: a child exiting 3 (script error) is reported with its status" {
  _watch_with_child_exit 3
  [[ "$WATCH_OUT" == *"iteration failed (exit 3)"* ]] || { echo "$WATCH_OUT"; return 1; }
}
