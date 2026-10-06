#!/usr/bin/env bats
#
# The bats suite must never be able to write to the developer's real run
# store. tests/setup_suite.bash sandboxes $HOME for the whole run; these tests
# fail if that stops being true, however it stops — a deleted setup_suite, a
# renamed variable, a change in bin/hopwatch's store resolution order, or a
# future test file that exports a store variable pointing at the real home.
#
# The store location is asked of the CLI itself: `--history` reports the file
# it reads as `sources.live` without scanning, touching the network or
# creating anything, and it resolves the path with the same code every
# writing mode uses.

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  NETDIAG="$REPO/bin/hopwatch"
}

under_run_tmpdir() {
  case "$1" in
    "$BATS_RUN_TMPDIR"/*) return 0 ;;
    *) return 1 ;;
  esac
}

store_the_cli_would_use() {
  "$NETDIAG" --history | python3 -c 'import json,sys; print(json.load(sys.stdin)["sources"]["live"])'
}

@test "store isolation: the suite's HOME is the sandbox, not the real home" {
  [ -n "${HOPWATCH_TEST_REAL_HOME:-}" ]
  [ "$HOME" != "$HOPWATCH_TEST_REAL_HOME" ]
  under_run_tmpdir "$HOME"
}

@test "store isolation: no store-selection variable survives into the suite" {
  [ -z "${HOPWATCH_LOG_DIR:-}" ]
  [ -z "${NETDIAG_LOG_DIR:-}" ]
  [ -z "${LOG_DIR:-}" ]
}

@test "store isolation: a bare hopwatch resolves its store under the bats temp dir" {
  local live
  live="$(store_the_cli_would_use)"
  [ -n "$live" ]
  under_run_tmpdir "$live" || { echo "store resolves to $live, outside $BATS_RUN_TMPDIR"; return 1; }
}

@test "store isolation: the real ~/net-diag and ~/hopwatch are not what the CLI resolves" {
  local live
  [ -n "${HOPWATCH_TEST_REAL_HOME:-}" ]
  live="$(store_the_cli_would_use)"
  case "$live" in
    "$HOPWATCH_TEST_REAL_HOME"/net-diag/*|"$HOPWATCH_TEST_REAL_HOME"/hopwatch/*)
      echo "store resolves to the real home: $live"; return 1 ;;
  esac
}

@test "store isolation: a test that sets HOME itself still gets its own store" {
  # The reason the sandbox is HOME rather than an exported HOPWATCH_LOG_DIR:
  # that variable would outrank this HOME and defeat the isolation these tests
  # (test_run_id, test_history, test_show...) set up deliberately.
  local home="$BATS_TEST_TMPDIR/own_home" live
  mkdir -p "$home"
  live="$(HOME="$home" "$NETDIAG" --history | python3 -c 'import json,sys; print(json.load(sys.stdin)["sources"]["live"])')"
  [ "$live" = "$home/hopwatch/baseline.jsonl" ]
}
