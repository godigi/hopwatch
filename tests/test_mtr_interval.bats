#!/usr/bin/env bats
# mtr_run must probe with the flags it will really use.
#
# mtr refuses an interval under 1 s unless it runs as root. The old probe was
# a bare `mtr -c 1 127.0.0.1`, which a non-root user passes, so the real run
# (`-i 0.2`) was then refused every time and every default run reported "mtr
# returned no parseable report". The stub below enforces mtr's rule.

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  FIX="$REPO/tests/fixtures"
  STUBS="$BATS_TEST_TMPDIR/bin"
  CALLS="$BATS_TEST_TMPDIR/mtr-calls"
  mkdir -p "$STUBS"
  : >"$CALLS"
  cat >"$STUBS/mtr" <<'EOF'
#!/bin/sh
echo "$*" >>"$MTR_CALLS"
iv=""; prev=""
for a in "$@"; do
  [ "$prev" = "-i" ] && iv="$a"
  prev="$a"
done
# mtr's own rule for a non-root user.
if [ -n "$iv" ] && [ "$(echo "$iv < 1" | bc 2>/dev/null || awk -v v="$iv" 'BEGIN{print (v<1)}')" = "1" ]; then
  echo "mtr: non-root users cannot request an interval < 1.0 sec" >&2
  exit 1
fi
case " $* " in
  *" -j "*) cat "$MTR_FIXTURE" ;;
esac
exit 0
EOF
  chmod +x "$STUBS/mtr"
}

_run_mtr() {
  run env PATH="$STUBS:$PATH" MTR_CALLS="$CALLS" MTR_FIXTURE="$FIX/mtr.json" EXPERT_ON="${EXPERT_ON:-0}" \
    bash -c '
      JSON_MODE=0 QUIET=0 QUICK=0 EXPERT="${EXPERT_ON:-0}" REDACT=0 LOG=/dev/null
      . "$1/lib/thresholds.sh"; . "$1/lib/common.sh"; . "$1/lib/globals.sh"
      . "$1/lib/traceroute.sh"; . "$1/lib/mtr.sh"
      mtr_run
      printf "HOPS=%s\n" "${#HOP_NUMS[@]}"
    ' _ "$REPO"
}

@test "a non-root mtr gets the slow interval and a real report, not the fallback" {
  _run_mtr
  [ "$status" -eq 0 ]
  [[ "$output" != *"no parseable report"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"HOPS="[1-9]* ]] || { echo "$output"; return 1; }
  # The real run used the interval the probe proved works.
  grep -E -- '-j -c 20 -n -i 1 1\.1\.1\.1' "$CALLS"
  ! grep -E -- '-i 0\.2 1\.1\.1\.1' "$CALLS"
}

@test "the header names the flags that were actually used" {
  EXPERT_ON=1 _run_mtr
  [[ "$output" == *"mtr -j -c 20 -i 1"* ]] || { echo "$output"; return 1; }
}
