#!/usr/bin/env bats
#
# The Swift and Python halves of the network-id rule must agree.
#
# helpers/history.py canonicalises a network record so runs group into
# networks; NetworkIdentity.swift does the same so the GUI's per-network
# state keys match. Two implementations of one rule drift, and when they
# drift the app records an arrival check under a key it will never present
# under again — which is the bug this fixture exists to prevent.
#
# VerifyMode's runNetworkIdentityFixtureTests() reads the same file.

setup() {
    REPO_ROOT="$( cd "$( dirname "$BATS_TEST_FILENAME" )/.." && pwd )"
    FIXTURE="$REPO_ROOT/tests/fixtures/network-ids.txt"
}

@test "the fixture exists and has cases" {
    [ -f "$FIXTURE" ]
    run bash -c "grep -vc '^#\|^$' '$FIXTURE'"
    [ "$status" -eq 0 ]
    [ "$output" -ge 10 ]
}

@test "history.py canonicalises every fixture case as the fixture says" {
    run python3 - "$FIXTURE" <<'PY'
import sys, os
# argv[1] is tests/fixtures/network-ids.txt, so helpers/ is two levels up.
sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.abspath(sys.argv[1])), "..", "..", "helpers"))
import history

failures = []
with open(sys.argv[1], encoding="utf-8") as fh:
    for lineno, line in enumerate(fh, 1):
        line = line.rstrip("\n")
        if not line or line.startswith("#"):
            continue
        raw, _, expected = line.partition("|")
        got = history.canonical_network_id(raw)
        got = "-" if got is None else got
        if got != expected:
            failures.append(f"line {lineno}: {raw!r} -> {got!r}, fixture says {expected!r}")

if failures:
    print("\n".join(failures))
    sys.exit(1)
print("all cases agree")
PY
    [ "$status" -eq 0 ]
    [[ "$output" == *"all cases agree"* ]]
}
