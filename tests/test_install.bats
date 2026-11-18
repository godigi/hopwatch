#!/usr/bin/env bats
# install.sh — the parts that do not need a Mac.

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  FAKEBIN="$BATS_TEST_TMPDIR/bin"
  COUNT="$BATS_TEST_TMPDIR/curl-calls"
  mkdir -p "$FAKEBIN"
  : >"$COUNT"
  # A curl that serves a harmless installer, and starts failing after three
  # calls so that a regression loops three times and stops instead of hanging.
  cat >"$FAKEBIN/curl" <<'SH'
#!/bin/sh
echo x >>"$COUNT_FILE"
if [ "$(wc -l <"$COUNT_FILE" | tr -d ' ')" -gt 3 ]; then exit 22; fi
echo 'echo FAKE-APP-INSTALLER-RAN'
SH
  chmod +x "$FAKEBIN/curl"
}

# `curl ... | bash -s -- --app` is the documented way to install the app. The
# script arrives on stdin, so there is no checkout beside it and the --app
# branch has to fetch install-app.sh. It used to `exec curl | bash` without
# leaving the argument loop, so it ran again and again.
@test "piped install.sh --app runs the app installer exactly once" {
  run env PATH="$FAKEBIN:$PATH" COUNT_FILE="$COUNT" bash -c 'cat "$1/install.sh" | bash -s -- --app' _ "$REPO"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'FAKE-APP-INSTALLER-RAN' <<<"$output")" -eq 1 ] || { echo "$output"; return 1; }
  [ "$(wc -l <"$COUNT" | tr -d ' ')" -eq 1 ]
}
