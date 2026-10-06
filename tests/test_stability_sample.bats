#!/usr/bin/env bats
#
# What a sample SAYS about stability, the burst and the leg a jitter swing
# starts on — helpers/monitor_sample.py + helpers/inference.py, driven with
# synthetic NETDIAG_MON_* environments. The bash state machines that
# produce those environments are tests/test_stability.bats.

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  HELPERS="$REPO/helpers"
  # shellcheck source=../lib/thresholds.sh
  . "$REPO/lib/thresholds.sh"
}

emit() {
  local env=(PATH="$PATH") t
  for t in LOSS_WARN_PCT LOSS_CRIT_PCT THRESH_GW_LOSS_CRIT_PCT \
           THRESH_LATENCY_JITTER_WARN_MS THRESH_INTERNET_LATENCY_WARN_MS \
           THRESH_INTERNET_LATENCY_CRIT_MS THRESH_DNS_LATENCY_WARN_MS \
           THRESH_GW_RTT_WARN_MS THRESH_WIFI_RSSI_EXCELLENT_DBM \
           THRESH_WIFI_RSSI_G1_DBM THRESH_WIFI_RSSI_WEAK_DBM \
           THRESH_MON_UNSTABLE_WINDOW_S THRESH_MON_SPEED_STALE_S; do
    env+=("$t=${!t}")
  done
  env -i "${env[@]}" "$@" python3 "$HELPERS/monitor_sample.py"
}

# A healthy measured link, so only the stability fields differ.
HEALTHY=(NETDIAG_MON_LINK_UP=1 NETDIAG_MON_SEVERITY=ok NETDIAG_MON_RULES=
         NETDIAG_MON_GW_LOSS=0 NETDIAG_MON_GW_RTT=5 NETDIAG_MON_INET_LOSS=0
         NETDIAG_MON_INET_RTT=20 NETDIAG_MON_INET_JITTER=4
         NETDIAG_MON_TCP_OK=1 NETDIAG_MON_DNS_OK=1 NETDIAG_MON_WEB_OK=1
         NETDIAG_MON_MEASUREMENT_STATE=measured)

jq_py() { python3 -c "import json,sys; d=json.load(sys.stdin); $1"; }

# ── stability ────────────────────────────────────────────────────────────

@test "a stable link carries state stable and no headline" {
  run emit "${HEALTHY[@]}"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq_py '
s = d["status"]["stability"]
assert s["state"] == "stable", s
assert s["rules"] == [], s
assert s["summary"] is None, s
assert d["headline"] is None, d["headline"]
'
}

@test "recovering: severity stays ok but the state, headline and rows say what happened" {
  run emit "${HEALTHY[@]}" NETDIAG_MON_STABILITY_STATE=recovering \
           NETDIAG_MON_STABILITY_RULES='LA-2:warn:0:120:3'
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq_py '
st = d["status"]
assert st["severity"] == "ok", st
assert st["rules"] == [], st
s = st["stability"]
assert s["state"] == "recovering", s
assert s["window_s"] == 300, s
assert s["rules"][0]["spikes"] == 3, s
assert s["rules"][0]["summary"] == "Response times swung 3 times in the last 5 min", s
assert s["summary"] == "Unstable 2 min ago — response times swung 3 times in the last 5 min", s
h = d["headline"]
assert h["text"] == "Unstable 2 min ago", h
assert h["subtitle"] == "Response times swung 3 times in the last 5 min", h
assert h["critical"] is False and h["recovering"] is True, h
rows = {r["activity"]: r for r in d["suitability"]}
# LA-2 impacts calls and gaming; those stay degraded with provenance
for a in ("calls", "gaming"):
    r = rows[a]
    assert r["verdict"] == "degraded", r
    assert r["because"] == ["LA-2"], r
    assert "Unstable 2 min ago" in r["metric"], r
    assert "Unstable 2 min ago" in r["detail"], r
    assert r["recent"] is True, r
# activities LA-2 does not touch are untouched
assert rows["browsing"]["verdict"] == "good", rows["browsing"]
assert rows["streaming"]["verdict"] != "degraded", rows["streaming"]
'
}

@test "recovering under a minute says so in words, never a bare number" {
  run emit "${HEALTHY[@]}" NETDIAG_MON_STABILITY_STATE=recovering \
           NETDIAG_MON_STABILITY_RULES='LA-2:warn:0:40:1'
  printf '%s' "$output" | jq_py '
assert d["headline"]["text"] == "Unstable under a minute ago", d["headline"]
assert d["headline"]["subtitle"] == "Response times swung once in the last 5 min", d["headline"]
'
}

@test "recovering from a critical never reads broken: nothing is failing now" {
  run emit "${HEALTHY[@]}" NETDIAG_MON_STABILITY_STATE=recovering \
           NETDIAG_MON_STABILITY_RULES='P2:critical:0:90:1'
  printf '%s' "$output" | jq_py '
rows = {r["activity"]: r for r in d["suitability"]}
for a, r in rows.items():
    assert r["verdict"] != "broken", r
assert rows["browsing"]["verdict"] == "degraded", rows["browsing"]
assert d["headline"]["critical"] is False, d["headline"]
assert d["status"]["severity"] == "ok"
'
}

@test "unstable now: the live rules decide the rows, stability still reports the spikes" {
  run emit "${HEALTHY[@]}" NETDIAG_MON_SEVERITY=warn NETDIAG_MON_RULES='LA-2 ' \
           NETDIAG_MON_STABILITY_STATE=unstable \
           NETDIAG_MON_STABILITY_RULES='LA-2:warn:1:0:2'
  printf '%s' "$output" | jq_py '
s = d["status"]["stability"]
assert s["state"] == "unstable" and s["rules"][0]["active"] is True, s
assert s["rules"][0]["spikes"] == 2, s
rows = {r["activity"]: r for r in d["suitability"]}
assert rows["calls"]["verdict"] == "degraded" and "recent" not in rows["calls"], rows["calls"]
assert not d["headline"].get("recovering"), d["headline"]
'
}

@test "a live degraded row is not rewritten by a recovering rule" {
  run emit "${HEALTHY[@]}" NETDIAG_MON_SEVERITY=warn NETDIAG_MON_RULES='LA-1 ' \
           NETDIAG_MON_INET_RTT=266 \
           NETDIAG_MON_STABILITY_STATE=unstable \
           NETDIAG_MON_STABILITY_RULES='LA-1:warn:1:0:1 LA-2:warn:0:60:2'
  printf '%s' "$output" | jq_py '
rows = {r["activity"]: r for r in d["suitability"]}
assert "recent" not in rows["gaming"], rows["gaming"]
'
}

# ── burst ────────────────────────────────────────────────────────────────

@test "no burst: status.burst is null" {
  run emit "${HEALTHY[@]}"
  printf '%s' "$output" | jq_py 'assert d["status"]["burst"] is None, d["status"]'
}

@test "an active burst is reported with its kind, interval and time left" {
  local until=$(( $(date +%s) + 40 ))
  run emit "${HEALTHY[@]}" NETDIAG_MON_BURST_KIND=latency-test \
           NETDIAG_MON_BURST_UNTIL="$until" NETDIAG_MON_BURST_INTERVAL_S=2
  printf '%s' "$output" | jq_py '
b = d["status"]["burst"]
assert b["active"] is True and b["kind"] == "latency-test" and b["interval_s"] == 2, b
assert 36 <= b["remaining_s"] <= 40, b
assert b["until"].endswith("Z") and len(b["until"]) == 20, b
'
}

# ── which leg carries a jitter swing ─────────────────────────────────────

LA2=(NETDIAG_MON_SEVERITY=warn "NETDIAG_MON_RULES=LA-2 " NETDIAG_MON_INET_JITTER=35
     NETDIAG_MON_WIFI_RSSI=-75)

@test "LA-2 on a swinging gateway is blamed on the Wi-Fi/router leg, not the internet" {
  run emit "${HEALTHY[@]}" "${LA2[@]}" NETDIAG_MON_LA2_LEG=router \
           NETDIAG_MON_GW_RTT=40 NETDIAG_MON_GW_JITTER=12 NETDIAG_MON_IFACE_TYPE=wifi
  printf '%s' "$output" | jq_py '
h = d["hops"]
assert h["router"]["warn"] is True, h["router"]
assert h["router"]["jitter_warn"] is True, h["router"]
assert h["internet"]["warn"] is False, h["internet"]
assert h["internet"]["jitter_warn"] is False, h["internet"]
assert "Wi-Fi/router" in h["internet"]["jitter_note"], h["internet"]
assert h["mac"]["laggy"] is True, h["mac"]
'
}

@test "LA-2 with a steady gateway stays on the internet hop" {
  run emit "${HEALTHY[@]}" "${LA2[@]}" NETDIAG_MON_LA2_LEG=internet \
           NETDIAG_MON_GW_RTT=5 NETDIAG_MON_IFACE_TYPE=wifi
  printf '%s' "$output" | jq_py '
h = d["hops"]
assert h["internet"]["warn"] is True and "jitter" in h["internet"]["detail"], h["internet"]
assert h["router"]["warn"] is False, h["router"]
'
}

@test "the rule-fired summary says where the swing starts" {
  run emit "${HEALTHY[@]}" "${LA2[@]}" NETDIAG_MON_LA2_LEG=router \
           NETDIAG_MON_GW_RTT=40 NETDIAG_MON_HAVE_PREV=1 NETDIAG_MON_PREV_RULES=
  printf '%s' "$output" | jq_py '
c = [x for x in d["changes"] if x["id"] == "rule-fired"][0]
assert c["summary"] == "Jittery Wi-Fi/router response", c
'
  run emit "${HEALTHY[@]}" "${LA2[@]}" NETDIAG_MON_LA2_LEG=internet \
           NETDIAG_MON_HAVE_PREV=1 NETDIAG_MON_PREV_RULES=
  printf '%s' "$output" | jq_py '
c = [x for x in d["changes"] if x["id"] == "rule-fired"][0]
assert c["summary"] == "Jittery internet response", c
'
}

@test "recovering from a Wi-Fi-leg swing names the Wi-Fi" {
  run emit "${HEALTHY[@]}" NETDIAG_MON_STABILITY_STATE=recovering \
           NETDIAG_MON_STABILITY_RULES='LA-2:warn:0:90:2' NETDIAG_MON_LA2_LEG=router
  printf '%s' "$output" | jq_py '
assert d["headline"]["subtitle"] == "Wi-Fi response times swung twice in the last 5 min", d["headline"]
'
}

# ── the last full check's speed, folded into Streaming ───────────────────

@test "streaming quotes the last full check's speed with its age" {
  at=$(( $(date +%s) - 29 * 60 ))
  run emit "${HEALTHY[@]}" NETDIAG_MON_SPEED_DOWN=65.1 NETDIAG_MON_SPEED_UP=51.9 \
           NETDIAG_MON_SPEED_AT="$at"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq_py '
rows = {r["activity"]: r for r in d["suitability"]}
r = rows["streaming"]
assert r["verdict"] == "good", r
assert r["metric"] == "65 Mbps · measured 29m ago", r
assert r["unmeasured_reason"] is None, r
assert "65 Mbps down and 52 Mbps up" in r["detail"], r
ls = d["last_speed"]
assert ls["stale"] is False and ls["down_mbps"] == 65.1 and ls["age_s"] in (1740, 1741, 1742), ls
assert ls["summary"] == "65 Mbps · measured 29m ago", ls
'
}

@test "streaming keeps a loss reading beside the stored speed" {
  at=$(( $(date +%s) - 120 ))
  run emit "${HEALTHY[@]}" NETDIAG_MON_INET_LOSS=2 NETDIAG_MON_SPEED_DOWN=65 \
           NETDIAG_MON_SPEED_AT="$at"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq_py '
r = {r["activity"]: r for r in d["suitability"]}["streaming"]
assert r["metric"].startswith("65 Mbps · measured 2m ago · "), r
assert "loss" in r["metric"], r
'
}

@test "a speed older than THRESH_MON_SPEED_STALE_S is not quoted and says why" {
  at=$(( $(date +%s) - THRESH_MON_SPEED_STALE_S - 3 * 86400 ))
  run emit "${HEALTHY[@]}" NETDIAG_MON_SPEED_DOWN=65 NETDIAG_MON_SPEED_AT="$at"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq_py '
r = {r["activity"]: r for r in d["suitability"]}["streaming"]
assert r["verdict"] == "unmeasured" and r["label"] == "Speed unknown", r
assert r["metric"] == "", r
assert "too old to rely on" in r["unmeasured_reason"] and "4d ago" in r["unmeasured_reason"], r
assert d["last_speed"]["stale"] is True, d["last_speed"]
'
}

@test "no stored speed: streaming stays unmeasured and last_speed is null" {
  run emit "${HEALTHY[@]}"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq_py '
r = {r["activity"]: r for r in d["suitability"]}["streaming"]
assert r["verdict"] == "unmeasured", r
assert d["last_speed"] is None
'
}

@test "last_speed.py: newest stored speed for THIS network only" {
  store="$BATS_TEST_TMPDIR/baseline.jsonl"
  {
    printf '%s\n' '{"timestamp":"2026-10-06T10:00:00Z","network":{"id":"mac:aa:bb:cc:dd:ee:01"},"speedtest":{"down_mbps":100,"up_mbps":20}}'
    printf '%s\n' '{"timestamp":"2026-10-06T11:00:00Z","network":{"id":"mac:aa:bb:cc:dd:ee:02"},"speedtest":{"down_mbps":7,"up_mbps":1}}'
    printf '%s\n' '{"timestamp":"2026-10-06T09:00:00Z","network":{"id":"mac:aa:bb:cc:dd:ee:01"},"speedtest":{"down_mbps":50,"up_mbps":10}}'
    printf '%s\n' '{"timestamp":"2026-10-06T12:00:00Z","network":{"id":"mac:aa:bb:cc:dd:ee:01"},"speedtest":null}'
  } > "$store"
  run python3 "$HELPERS/last_speed.py" --history "$store" --network "mac:aa:bb:cc:dd:ee:01"
  [ "$status" -eq 0 ]
  [ "${output%%$'\t'*}" = "100" ]
  [ "$(printf '%s' "$output" | cut -f3)" = "$(python3 -c 'from datetime import datetime,timezone;print(int(datetime(2026,10,6,10,tzinfo=timezone.utc).timestamp()))')" ]
  run python3 "$HELPERS/last_speed.py" --history "$store" --network "mac:aa:bb:cc:dd:ee:99"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
