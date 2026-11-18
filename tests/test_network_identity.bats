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

@test "netid_run's group key falls back to the DHCP router exactly as the id does" {
    # A routeless run (no default route, so no GATEWAY) with a DHCP router
    # is filed as `lan:gw=<router>`; history.py groups that id as
    # `gw:<router>`. netid_run used to leave NETWORK_GROUP empty here, so a
    # live monitor sample carried group_id null and could not join the
    # stored run it describes.
    run bash -c '
        REPO_ROOT="$1"
        . "$REPO_ROOT/lib/netid.sh"
        IS_WIFI=0 WIFI_SSID="" GW_MAC="" GATEWAY="" LINK_DHCP_ROUTER="192.168.1.1"
        NETWORK_ID="" NETWORK_LABEL="" NETWORK_GROUP=""
        netid_run >/dev/null 2>&1
        printf "%s|%s" "$NETWORK_ID" "$NETWORK_GROUP"
    ' _ "$REPO_ROOT"
    [ "$status" -eq 0 ]
    [ "$output" = "lan:gw=192.168.1.1|gw:192.168.1.1" ] || { echo "got '$output'"; return 1; }
    run python3 -I - "$REPO_ROOT/helpers" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import history
print(history.group_key({"network": {"id": "lan:gw=192.168.1.1"}})[0])
PY
    [ "$output" = "gw:192.168.1.1" ] || { echo "history.py says '$output'"; return 1; }
}

@test "a real gateway still outranks the DHCP router in the group key" {
    run bash -c '
        REPO_ROOT="$1"
        . "$REPO_ROOT/lib/netid.sh"
        IS_WIFI=0 WIFI_SSID="" GW_MAC="" GATEWAY="10.0.0.1" LINK_DHCP_ROUTER="192.168.1.1"
        NETWORK_ID="" NETWORK_LABEL="" NETWORK_GROUP=""
        netid_run >/dev/null 2>&1
        printf "%s" "$NETWORK_GROUP"
    ' _ "$REPO_ROOT"
    [ "$output" = "gw:10.0.0.1" ] || { echo "got '$output'"; return 1; }
}
