# bats suite-level setup, honoured by `bats tests/` and by
# `bats tests/some_file.bats` alike (bats looks for setup_suite.bash in the
# directory of the test files).
#
# Why this exists: bin/hopwatch picks its run store (baseline.jsonl, the
# per-run .log files, events.jsonl) from HOPWATCH_LOG_DIR, then
# NETDIAG_LOG_DIR, then LOG_DIR, then ~/hopwatch if it exists, then
# ~/net-diag. A test that runs the real CLI without redirecting any of those
# therefore appends to the developer's *real* history, which the app's
# per-network medians are computed from. Before this file, every bats run
# added eight "--quick" runs to ~/net-diag, and ~42 of the last 50 runs on a
# developer's current network were test runs.
#
# The fix is to make the real home unreachable rather than to remember to
# redirect it in each test: $HOME becomes a throwaway directory under
# $BATS_RUN_TMPDIR. With no override set, the CLI falls through to
# "$HOME/hopwatch" inside the sandbox. A test that sets HOME itself
# (`HOME='$tmp' hopwatch ...`) still gets exactly the store it asked for,
# which an exported HOPWATCH_LOG_DIR would not allow: that variable outranks
# HOME in the CLI's resolution order and would silently redirect those
# tests onto a shared directory.
#
# The three store-selection variables are unset first so that a developer
# shell that happens to export one (pointing at the real store, say) cannot
# route the suite back to it. tests/test_store_isolation.bats proves the
# result by asking the CLI itself where it would write.

setup_suite() {
  unset HOPWATCH_LOG_DIR NETDIAG_LOG_DIR LOG_DIR
  # Kept for the isolation test, which has to be able to say "this is not the
  # real home" without trusting the variable it is checking.
  export HOPWATCH_TEST_REAL_HOME="$HOME"
  HOME="$BATS_RUN_TMPDIR/home"
  mkdir -p "$HOME"
  export HOME
}
