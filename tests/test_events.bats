#!/usr/bin/env bats
#
# The event journal — netdiag remembering what happened.
#
# The gap this closes, from docs/design/nothing-was-watching.md: netdiag
# could always say what was wrong *now* and never what was wrong at 03:14
# or for how long. The monitor observed every transition, rendered it, used
# it to decide whether to notify, and then discarded it. `--monitor
# --journal` writes those transitions down; `--events` reads them back.
#
# What is asserted here is pairing and honesty about observation. Nothing
# judges a duration: whether four minutes of downtime is acceptable is a
# verdict, and verdicts live in lib/diagnosis.sh against lib/thresholds.sh.

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  NETDIAG="$REPO/bin/hopwatch"
  EVENTS="$REPO/helpers/events.py"
  J="$BATS_TEST_TMPDIR/events.jsonl"
  # The reader takes its one cutoff from lib/thresholds.sh through the
  # environment, as bin/hopwatch hands it over, and refuses to run without.
  # shellcheck source=../lib/thresholds.sh
  . "$REPO/lib/thresholds.sh"
  export THRESH_EV_RESTART_BRIDGE_S
}

# One journal line. $1 kind, $2 timestamp, $3 seq, then kind-specific args.
# ALREADY=1 marks a rule-fired as "found already firing in the first sample
# of a monitor", which is how monitor_sample.py writes them at start.
ev() {
  local kind="$1" ts="$2" seq="$3"; shift 3
  local extra=""
  case "$kind" in
    rule-fired)   extra=",\"from\":null,\"to\":\"$1\"${ALREADY:+,\"already_firing\":true}" ;;
    rule-cleared) extra=",\"from\":\"$1\",\"to\":null" ;;
    gap)          extra=",\"gap_s\":$1" ;;
  esac
  local net="${NET:-wifi:mac=aa}"
  printf '{"t":"%s","seq":%s,"network":"%s","network_label":"Home","kind":"%s","summary":"s"%s}\n' \
    "$ts" "$seq" "$net" "$kind" "$extra" >> "$J"
}

read_events() {
  python3 "$EVENTS" --journal "$J" --version test
}

# The same read, bounded to the last $1 hours — the shape a user asks for
# ("was it down last night?") and the only one where the window itself can
# cut an episode in half.
read_events_window() {
  python3 "$EVENTS" --journal "$J" --hours "$1" --version test
}

# A timestamp $1 minutes before now. Needed wherever the assertion is about
# --hours, which is measured against the wall clock: a fixed 2026 date is
# either always inside the window or always outside it.
ago() {
  python3 -c "
import datetime, sys
print((datetime.datetime.now(datetime.timezone.utc)
       - datetime.timedelta(minutes=int(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))
" "$1"
}

# ── Pairing ──────────────────────────────────────────────────────────────

@test "a fault that fired and cleared becomes an episode with a duration" {
  # The whole point: "the internet was down from 03:14 for 4m25s" is a
  # sentence netdiag could not previously produce at all.
  ev monitor-started 2026-08-28T01:00:00Z 1
  ev rule-fired      2026-08-28T03:14:00Z 900 N1
  ev rule-cleared    2026-08-28T03:18:25Z 930 N1
  run read_events
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
eps = [e for e in d['episodes'] if e['rule'] == 'N1']
assert len(eps) == 1, d['episodes']
assert eps[0]['duration_s'] == 265, eps[0]
assert eps[0]['ongoing'] is False, eps[0]
assert eps[0]['ended_by'] == 'cleared', eps[0]
"
}

@test "the same fault on two networks is two episodes" {
  # Keyed on (network, rule). Otherwise a laptop that moves has one
  # network's recovery closing the other network's fault.
  NET=wifi:mac=aa ev rule-fired 2026-08-28T01:00:00Z 1 G3
  NET=wifi:mac=bb ev rule-fired 2026-08-28T01:01:00Z 2 G3
  NET=wifi:mac=aa ev rule-cleared 2026-08-28T01:05:00Z 3 G3
  run read_events
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
eps = {(e['network'], e['ongoing']): e for e in d['episodes']}
assert len(d['episodes']) == 2, d['episodes']
assert eps[('wifi:mac=aa', False)]['duration_s'] == 300
assert ('wifi:mac=bb', True) in eps, list(eps)
"
}

@test "an episode still open at the end is measured to the last event, not to now" {
  # Reporting 'ongoing for 4 hours' when the recorder stopped an hour ago
  # invents observation that never happened. The duration must stop where
  # the record stops.
  ev rule-fired 2020-01-01T00:00:00Z 1 N1
  ev gap        2020-01-01T00:10:00Z 2 60
  run read_events
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
ep = d['episodes'][0]
assert ep['ongoing'] is True, ep
assert ep['ended_by'] == 'still-open', ep
# 10 minutes to the last event, not the years since 2020.
assert ep['duration_s'] == 600, ep
"
}

@test "a monitor restart closes an open episode as a lower bound" {
  # The recorder died or the Mac rebooted. Whatever happened to that fault
  # in between was not observed, so the episode must not silently span it.
  ev rule-fired      2026-08-28T03:00:00Z 900 N1
  ev monitor-started 2026-08-28T03:05:00Z 1
  run read_events
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
ep = d['episodes'][0]
assert ep['ended_by'] == 'monitor-restart', ep
assert ep['duration_is_lower_bound'] is True, ep
assert ep['duration_s'] == 300, ep
"
}

@test "a fault re-observed after a restart keeps its earliest known start" {
  # Firing twice with no clear between means the recorder restarted and
  # saw the same fault again. The earliest sighting is the earliest moment
  # it is known to have been true.
  ev rule-fired 2026-08-28T03:00:00Z 900 G3
  ev rule-fired 2026-08-28T03:02:00Z 901 G3
  ev rule-cleared 2026-08-28T03:10:00Z 902 G3
  run read_events
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert len(d['episodes']) == 1, d['episodes']
assert d['episodes'][0]['duration_s'] == 600, d['episodes'][0]
"
}

@test "a clear with no matching fire is an episode with an unknown start" {
  # The recorder started mid-fault and only saw the recovery. An end with
  # no beginning is still an end: the episode is reported, and its start
  # and duration are null rather than invented.
  ev rule-cleared 2026-08-28T03:00:00Z 1 N1
  run read_events
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
eps = json.load(sys.stdin)['episodes']
assert len(eps) == 1, eps
assert eps[0]['rule'] == 'N1', eps[0]
assert eps[0]['started'] is None, eps[0]
assert eps[0]['duration_s'] is None, eps[0]
assert eps[0]['start_unobserved'] is True, eps[0]
"
}

@test "a fault that began before the window still appears when it ends inside it" {
  # 'Was the internet down last night, and for how long?' — a fault that
  # started before the window and ended inside it is the likeliest shape of
  # that answer, and --events=24 used to drop it entirely: the fire is
  # filtered out by the window, so the clear arrives orphaned and paired
  # with nothing. The `events` array still carried the raw row, which is no
  # help to anyone reading `episodes`.
  ev rule-fired   "$(ago 2880)" 1 N1
  ev rule-cleared "$(ago 60)"   2 N1
  run read_events_window 24
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
eps = [e for e in d['episodes'] if e['rule'] == 'N1']
assert len(eps) == 1, d['episodes']
ep = eps[0]
# The fire is genuinely outside what was read, so no start is claimed and
# no duration is derived from one.
assert ep['started'] is None, ep
assert ep['duration_s'] is None, ep
assert ep['start_unobserved'] is True, ep
assert ep['ongoing'] is False, ep
assert ep['ended_by'] == 'cleared', ep
"
}

# ── A restart is a blind spot, not an end ───────────────────────────────
#
# The app restarts the monitor to change cadence and to start and end a
# 60-second investigation burst, and a fault that keeps flapping severity
# re-arms the burst about once a minute. Every restart writes a
# monitor-started line, and the fresh monitor re-reports the still-firing
# rule a few seconds later. Read literally, one continuous router fault
# became a dozen short "monitor-restart" episodes.
#
# These tests pin what the reader does with that shape. The window itself
# comes from lib/thresholds.sh; the boundary tests pin it explicitly so
# they do not move when the shipped value is retuned.

# A python assertion over the episodes for rule $1, reading JSON on stdin.
# The body is $2, with `eps` in scope.
eps_for() {
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
eps = [e for e in d['episodes'] if e['rule'] == '$1']
$2
"
}

@test "a rule that re-fires within the window after a restart is one episode" {
  ev rule-fired      2026-10-06T20:34:39Z 23 G2
  ev monitor-started 2026-10-06T20:34:53Z 1
  ev rule-fired      2026-10-06T20:35:11Z 3 G2
  ev rule-cleared    2026-10-06T20:40:00Z 9 G2
  run read_events
  [ "$status" -eq 0 ]
  eps_for G2 "
assert len(eps) == 1, eps
ep = eps[0]
# The span of the whole fault, first fire to the clear that was seen.
assert ep['started'] == '2026-10-06T20:34:39Z', ep
assert ep['ended'] == '2026-10-06T20:40:00Z', ep
assert ep['duration_s'] == 321, ep
# 20:34:53 to 20:35:11: nobody saw it, and it is counted as such rather
# than absorbed into the duration.
assert ep['unobserved_s'] == 18, ep
assert ep['restarts_bridged'] == 1, ep
# It ended because it cleared, and nothing about it is a lower bound.
assert ep['ended_by'] == 'cleared', ep
assert ep['ongoing'] is False, ep
assert 'duration_is_lower_bound' not in ep, ep
"
}

@test "a re-fire after the window leaves two episodes, the first still restart-ended" {
  THRESH_EV_RESTART_BRIDGE_S=60
  export THRESH_EV_RESTART_BRIDGE_S
  ev rule-fired      2026-10-06T20:00:00Z 1 G2
  ev monitor-started 2026-10-06T20:01:00Z 1
  ev rule-fired      2026-10-06T20:02:01Z 3 G2
  ev rule-cleared    2026-10-06T20:03:00Z 4 G2
  run read_events
  [ "$status" -eq 0 ]
  eps_for G2 "
assert len(eps) == 2, eps
first, second = eps
assert first['ended_by'] == 'monitor-restart', first
assert first['duration_is_lower_bound'] is True, first
assert first['duration_s'] == 60, first
assert 'restarts_bridged' not in first, first
assert second['started'] == '2026-10-06T20:02:01Z', second
assert second['ended_by'] == 'cleared', second
assert 'restarts_bridged' not in second, second
"
}

@test "the window is inclusive at its edge, and not a second past it" {
  THRESH_EV_RESTART_BRIDGE_S=60
  export THRESH_EV_RESTART_BRIDGE_S
  ev rule-fired      2026-10-06T20:00:00Z 1 G2
  ev monitor-started 2026-10-06T20:01:00Z 1
  ev rule-fired      2026-10-06T20:02:00Z 3 G2
  ev rule-cleared    2026-10-06T20:03:00Z 4 G2
  run read_events
  eps_for G2 "assert len(eps) == 1, eps"

  rm -f "$J"
  ev rule-fired      2026-10-06T20:00:00Z 1 G2
  ev monitor-started 2026-10-06T20:01:00Z 1
  ev rule-fired      2026-10-06T20:02:01Z 3 G2
  ev rule-cleared    2026-10-06T20:03:00Z 4 G2
  run read_events
  eps_for G2 "assert len(eps) == 2, eps"
}

@test "a different rule after a restart does not continue the first" {
  ev rule-fired      2026-10-06T20:34:39Z 23 G2
  ev monitor-started 2026-10-06T20:34:53Z 1
  ev rule-fired      2026-10-06T20:35:11Z 3 G3
  run read_events
  [ "$status" -eq 0 ]
  eps_for G2 "
assert len(eps) == 1, eps
assert eps[0]['ended_by'] == 'monitor-restart', eps[0]
assert eps[0]['duration_is_lower_bound'] is True, eps[0]
assert 'restarts_bridged' not in eps[0], eps[0]
"
  eps_for G3 "
assert len(eps) == 1, eps
assert eps[0]['started'] == '2026-10-06T20:35:11Z', eps[0]
"
}

@test "the same rule on a different network does not continue the first" {
  # A laptop that changed network across the restart has a new fault, not
  # the old one resumed.
  NET=wifi:mac=aa ev rule-fired      2026-10-06T20:34:39Z 23 G2
  NET=wifi:mac=aa ev monitor-started 2026-10-06T20:34:53Z 1
  NET=wifi:mac=bb ev rule-fired      2026-10-06T20:35:11Z 3 G2
  run read_events
  [ "$status" -eq 0 ]
  eps_for G2 "
assert len(eps) == 2, eps
by_net = {e['network']: e for e in eps}
assert by_net['wifi:mac=aa']['ended_by'] == 'monitor-restart', eps
assert 'restarts_bridged' not in by_net['wifi:mac=aa'], eps
assert by_net['wifi:mac=bb']['ongoing'] is True, eps
"
}

@test "a rule that cleared before the restart is not resurrected by a later fire" {
  # Only a restart-closed episode can be continued. This one ended because
  # the monitor *saw* it clear, so a fire seconds after the restart is a
  # new fault.
  ev rule-fired      2026-10-06T20:00:00Z 1 G2
  ev rule-cleared    2026-10-06T20:00:30Z 2 G2
  ev monitor-started 2026-10-06T20:00:40Z 1
  ev rule-fired      2026-10-06T20:00:50Z 3 G2
  ev rule-cleared    2026-10-06T20:01:20Z 4 G2
  run read_events
  [ "$status" -eq 0 ]
  eps_for G2 "
assert len(eps) == 2, eps
assert [e['duration_s'] for e in eps] == [30, 30], eps
assert all(e['ended_by'] == 'cleared' for e in eps), eps
assert all('restarts_bridged' not in e for e in eps), eps
"
}

@test "a chain of burst restarts is one episode (the shape of the real journal)" {
  # The 2026-10-06 20:34-20:40Z fault, as the journal wrote it: a restart
  # every ~60 s, the rule re-fired ~18 s after each one. Network id is
  # synthetic; the real one is a MAC and this repo is public.
  export NET=wifi:mac=00:11:22:33:44:55
  ev rule-fired      2026-10-06T20:34:39Z 23 G2
  ev monitor-started 2026-10-06T20:34:53Z 1
  ev gap             2026-10-06T20:35:03Z 2 15
  ev rule-fired      2026-10-06T20:35:11Z 3 G2
  ev monitor-started 2026-10-06T20:35:51Z 1
  ev rule-fired      2026-10-06T20:36:09Z 3 G2
  ev monitor-started 2026-10-06T20:36:50Z 1
  ev rule-fired      2026-10-06T20:37:08Z 3 G2
  ev rule-cleared    2026-10-06T20:40:00Z 9 G2
  run read_events
  [ "$status" -eq 0 ]
  eps_for G2 "
assert len(eps) == 1, eps
ep = eps[0]
assert ep['duration_s'] == 321, ep
assert ep['unobserved_s'] == 54, ep
assert ep['restarts_bridged'] == 3, ep
assert ep['ended_by'] == 'cleared', ep
assert 'duration_is_lower_bound' not in ep, ep
"
  # Three starts happened and the window still says so: bridging an
  # episode must not rewrite what the recorder did.
  printf '%s' "$output" | python3 -c "
import json, sys
assert json.load(sys.stdin)['observation']['monitor_starts'] == 3
"
}

@test "a merged episode whose last segment ends in a restart is still restart-ended" {
  ev rule-fired      2026-10-06T20:34:39Z 23 G2
  ev monitor-started 2026-10-06T20:34:53Z 1
  ev rule-fired      2026-10-06T20:35:11Z 3 G2
  ev monitor-started 2026-10-06T20:35:51Z 1
  run read_events
  [ "$status" -eq 0 ]
  eps_for G2 "
assert len(eps) == 1, eps
ep = eps[0]
assert ep['ended_by'] == 'monitor-restart', ep
assert ep['duration_is_lower_bound'] is True, ep
assert ep['ended'] == '2026-10-06T20:35:51Z', ep
assert ep['duration_s'] == 72, ep
assert ep['restarts_bridged'] == 1, ep
assert ep['ongoing'] is False, ep
"
}

@test "a merged episode still open at the end is measured to the last event" {
  ev rule-fired      2026-10-06T20:34:39Z 23 G2
  ev monitor-started 2026-10-06T20:34:53Z 1
  ev rule-fired      2026-10-06T20:35:11Z 3 G2
  ev gap             2026-10-06T20:36:00Z 4 20
  run read_events
  [ "$status" -eq 0 ]
  eps_for G2 "
assert len(eps) == 1, eps
ep = eps[0]
assert ep['ended_by'] == 'still-open', ep
assert ep['ongoing'] is True, ep
assert ep['duration_s'] == 81, ep
# 18 s across the restart plus the 20 s gap line inside the open stretch.
assert ep['unobserved_s'] == 38, ep
assert ep['restarts_bridged'] == 1, ep
"
}

@test "back-to-back restarts inside the window do not break the candidate" {
  # A monitor that was replaced before its second sample could not have
  # reported the rule even if it were still firing, so it is not evidence
  # that the fault stopped.
  ev rule-fired      2026-10-06T20:00:00Z 1 G2
  ev monitor-started 2026-10-06T20:00:20Z 1
  ev monitor-started 2026-10-06T20:00:34Z 1
  ev rule-fired      2026-10-06T20:00:52Z 3 G2
  ev rule-cleared    2026-10-06T20:02:00Z 4 G2
  run read_events
  [ "$status" -eq 0 ]
  eps_for G2 "
assert len(eps) == 1, eps
assert eps[0]['duration_s'] == 120, eps[0]
assert eps[0]['restarts_bridged'] == 2, eps[0]
assert eps[0]['unobserved_s'] == 32, eps[0]
"
}

@test "a long silent process between two restarts is not bridged across" {
  # Ten minutes of a monitor running and never reporting the rule is not a
  # blind spot, it is a measurement: the candidate must not survive it.
  ev rule-fired      2026-10-06T20:00:00Z 1 G2
  ev monitor-started 2026-10-06T20:00:20Z 1
  ev monitor-started 2026-10-06T20:10:20Z 1
  ev rule-fired      2026-10-06T20:10:38Z 3 G2
  ev rule-cleared    2026-10-06T20:11:00Z 4 G2
  run read_events
  [ "$status" -eq 0 ]
  eps_for G2 "
assert len(eps) == 2, eps
assert eps[0]['ended_by'] == 'monitor-restart', eps[0]
assert eps[0]['duration_s'] == 20, eps[0]
assert eps[1]['duration_s'] == 22, eps[1]
"
}

@test "events.py refuses to run without the restart window, and says where it lives" {
  # A default here would be a second home for a number with one, and a
  # stale copy still yields a plausible episode count.
  ev rule-fired 2026-10-06T20:00:00Z 1 G2
  run env -u THRESH_EV_RESTART_BRIDGE_S \
    python3 "$EVENTS" --journal "$J" --version test
  [ "$status" -eq 3 ]
  [[ "$output" == *"THRESH_EV_RESTART_BRIDGE_S"* ]] || return 1
  [[ "$output" == *"lib/thresholds.sh"* ]] || return 1
}

@test "--events reads the window from lib/thresholds.sh without help from the caller" {
  # The CLI is the one caller that must supply it; run it with the variable
  # scrubbed from the environment to prove bin/hopwatch does.
  mkdir -p "$BATS_TEST_TMPDIR/h/net-diag"
  ev rule-fired      "$(ago 10)" 1 G2
  ev monitor-started "$(ago 9)"  1
  ev rule-fired      "$(ago 8)"  3 G2
  cp "$J" "$BATS_TEST_TMPDIR/h/net-diag/events.jsonl"
  run env -u THRESH_EV_RESTART_BRIDGE_S HOME="$BATS_TEST_TMPDIR/h" HOPWATCH_LOG_DIR="$BATS_TEST_TMPDIR/h/net-diag" \
    "$NETDIAG" --events=1
  [ "$status" -eq 0 ]
  eps_for G2 "
assert len(eps) == 1, eps
assert eps[0]['restarts_bridged'] == 1, eps[0]
"
}

# ── Honesty about what was observed ──────────────────────────────────────

@test "a gap inside an episode is recorded, not absorbed into its duration" {
  # A four-hour outage and a four-hour closed lid produce the same silence.
  # The difference has to survive into the answer.
  ev rule-fired 2026-08-28T01:00:00Z 1 N1
  ev gap        2026-08-28T02:00:00Z 2 28800
  ev rule-cleared 2026-08-28T03:00:00Z 3 N1
  run read_events
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
ep = json.load(sys.stdin)['episodes'][0]
assert ep['duration_s'] == 7200, ep
assert ep['unobserved_s'] == 28800, ep
"
}

@test "the window reports the fraction of itself nobody was watching" {
  ev monitor-started 2026-08-28T00:00:00Z 1
  ev gap             2026-08-28T04:00:00Z 2 3600
  run read_events
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
o = json.load(sys.stdin)['observation']
assert o['gap_count'] == 1, o
assert o['unobserved_s'] == 3600, o
assert o['monitor_starts'] == 1, o
assert o['unobserved_fraction'] is not None, o
"
}

# ── The file itself ──────────────────────────────────────────────────────

@test "a truncated final line costs one event, not the whole answer" {
  # The recorder killed mid-write. Reading must degrade, not fail.
  ev rule-fired 2026-08-28T01:00:00Z 1 N1
  printf '{"t":"2026-08-28T01:01:00Z","seq":2,"kin' >> "$J"
  run read_events
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['counts']['events'] == 1, d['counts']
"
}

@test "duplicate lines from an interrupted archive roll are deduped" {
  # _journal_prune appends to the archive before truncating the live file,
  # so a crash between the two duplicates lines rather than dropping them.
  # That is only the safe failure because this dedupes.
  ev rule-fired 2026-08-28T01:00:00Z 1 N1
  cp "$J" "$BATS_TEST_TMPDIR/events-archive.jsonl"
  run read_events
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
assert json.load(sys.stdin)['counts']['events'] == 1
"
}

@test "an absent journal is an empty answer, not an error" {
  run python3 "$EVENTS" --journal "$BATS_TEST_TMPDIR/nope.jsonl" --version test
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['episodes'] == [] and d['counts']['events'] == 0
"
}

# ── The CLI surface ──────────────────────────────────────────────────────

@test "--events emits one parseable JSON object" {
  run bash -c "HOME='$BATS_TEST_TMPDIR' '$NETDIAG' --events=24"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -m json.tool >/dev/null
}

@test "--events with a non-numeric window is a usage error, not a diagnosis" {
  # Exit 3, never 2: 2 is reserved for a real finding so wrappers can tell
  # a broken invocation from a broken network.
  run "$NETDIAG" --events=banana
  [ "$status" -eq 3 ]
}

@test "--monitor without --journal still writes nothing to disk" {
  # The documented contract of --monitor, and the reason --journal is
  # opt-in: a consumer piping this stream into its own program gets a
  # process that touches no disk.
  home="$BATS_TEST_TMPDIR/clean"
  mkdir -p "$home"
  run bash -c "HOME='$home' '$NETDIAG' --monitor --monitor-fast-interval 1 --monitor-count 2 >/dev/null 2>&1"
  [ ! -e "$home/net-diag/events.jsonl" ]
}

@test "--monitor --journal writes the file it was given" {
  home="$BATS_TEST_TMPDIR/j"
  mkdir -p "$home"
  run bash -c "HOME='$home' '$NETDIAG' --monitor --journal '$home/ev.jsonl' --monitor-fast-interval 1 --monitor-count 2 >/dev/null 2>&1"
  [ -s "$home/ev.jsonl" ]
  # Always at least the start marker, so a reader can tell "nothing
  # happened" from "nothing was running".
  run grep -c 'monitor-started' "$home/ev.jsonl"
  [ "$output" = "1" ]
}

@test "--journal pointing somewhere unwritable fails at startup, not silently" {
  # Dropping every event for days because a path was wrong is the failure
  # ND-1 exists to catch one level up. Fail loudly, immediately.
  run "$NETDIAG" --monitor --journal /nope/nowhere/ev.jsonl --monitor-count 1
  [ "$status" -eq 3 ]
  [[ "$output" == *journal* ]] || { echo "$output"; return 1; }
}

@test "events and recorder are advertised in --capabilities" {
  run "$NETDIAG" --capabilities
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
f = json.load(sys.stdin)['features']
assert 'events' in f, f
assert 'recorder' in f, f
"
}

@test "--install-recorder refuses a TCC-protected path, like the watcher" {
  fake_home="$BATS_TEST_TMPDIR/rhome"
  mkdir -p "$fake_home/Documents/netdiag/bin" "$fake_home/Library/LaunchAgents"
  cp "$NETDIAG" "$fake_home/Documents/netdiag/bin/hopwatch"
  cp -R "$REPO/lib" "$REPO/helpers" "$fake_home/Documents/netdiag/"
  run env HOME="$fake_home" "$fake_home/Documents/netdiag/bin/hopwatch" --install-recorder
  [ "$status" -eq 3 ]
  [ ! -f "$fake_home/Library/LaunchAgents/com.hopwatch.recorder.plist" ]
  [ ! -f "$fake_home/Library/LaunchAgents/com.netdiag.recorder.plist" ]
}

@test "the recorder and the watcher are separate agents" {
  # They answer different questions — a snapshot every fifteen minutes
  # versus every transition — and neither replaces the other.
  run bash -c "grep -E 'RECORDER_LABEL=\"com\.(hopwatch|netdiag)\.recorder\"' '$REPO/lib/watchdog.sh'"
  [ "$status" -eq 0 ]
  run bash -c "grep -E 'WATCHER_LABEL=\"com\.(hopwatch|netdiag)\.watcher\"' '$REPO/lib/watchdog.sh'"
  [ "$status" -eq 0 ]
}

# ── A fault that simply carries on through a restart ────────────────────
#
# A fresh monitor's first sample is a baseline, so a rule already firing in
# it used to be journaled never: the fault went silent for as long as it
# lasted, and the reader could only close it at the restart. The first
# sample's rules are now journaled with `already_firing`, so the reader can
# tell "observed starting" from "found in progress" and join the latter to
# the episode the previous process had open.

@test "a steady fault across one restart is one episode" {
  ev rule-fired      2026-10-06T20:00:00Z 5 G2
  ev monitor-started 2026-10-06T20:10:00Z 1
  ALREADY=1 ev rule-fired 2026-10-06T20:10:00Z 1 G2
  ev rule-cleared    2026-10-06T20:20:00Z 9 G2
  run read_events
  [ "$status" -eq 0 ]
  eps_for G2 "
assert len(eps) == 1, eps
ep = eps[0]
assert ep['started'] == '2026-10-06T20:00:00Z', ep
assert ep['ended'] == '2026-10-06T20:20:00Z', ep
assert ep['duration_s'] == 1200, ep
# The new monitor reported it in its own first sample: nothing in between
# went unobserved.
assert ep['unobserved_s'] == 0, ep
assert ep['restarts_bridged'] == 1, ep
assert ep['ended_by'] == 'cleared', ep
assert ep['ongoing'] is False, ep
# It began where it was seen to begin.
assert 'start_unobserved' not in ep, ep
assert 'duration_is_lower_bound' not in ep, ep
"
}

@test "a steady fault across a chain of restarts is one episode with the right totals" {
  # Three restarts, the second of whose monitors had not yet got the rule
  # in its first sample and re-fired it 18 s in (the older shape), so the
  # two kinds of start compose in one episode.
  ev rule-fired      2026-10-06T20:00:00Z 5 G2
  ev monitor-started 2026-10-06T20:01:00Z 1
  ALREADY=1 ev rule-fired 2026-10-06T20:01:00Z 1 G2
  ev monitor-started 2026-10-06T20:02:00Z 1
  ev rule-fired      2026-10-06T20:02:18Z 3 G2
  ev gap             2026-10-06T20:02:40Z 4 12
  ev monitor-started 2026-10-06T20:03:00Z 1
  ALREADY=1 ev rule-fired 2026-10-06T20:03:00Z 1 G2
  ev rule-cleared    2026-10-06T20:04:00Z 9 G2
  run read_events
  [ "$status" -eq 0 ]
  eps_for G2 "
assert len(eps) == 1, eps
ep = eps[0]
assert ep['started'] == '2026-10-06T20:00:00Z', ep
assert ep['duration_s'] == 240, ep
# 18 s blind before the re-fire, plus the 12 s gap line. Start lines add
# nothing: they were written in the first sample.
assert ep['unobserved_s'] == 30, ep
assert ep['restarts_bridged'] == 3, ep
assert ep['ended_by'] == 'cleared', ep
assert 'start_unobserved' not in ep, ep
"
}

@test "a fault already in progress when the first monitor started is flagged start-unobserved" {
  ev monitor-started 2026-10-06T20:00:00Z 1
  ALREADY=1 ev rule-fired 2026-10-06T20:00:00Z 1 G2
  ev rule-cleared    2026-10-06T20:05:00Z 9 G2
  run read_events
  [ "$status" -eq 0 ]
  eps_for G2 "
assert len(eps) == 1, eps
ep = eps[0]
# The first moment it is known to have been true, and said to be that.
assert ep['started'] == '2026-10-06T20:00:00Z', ep
assert ep['start_unobserved'] is True, ep
assert ep['ended'] == '2026-10-06T20:05:00Z', ep
assert ep['duration_s'] == 300, ep
assert ep['duration_is_lower_bound'] is True, ep
assert ep['ended_by'] == 'cleared', ep
assert 'restarts_bridged' not in ep, ep
"
}

@test "an in-progress fault with no clear is still-open, start-unobserved, measured to the last event" {
  ev monitor-started 2026-10-06T20:00:00Z 1
  ALREADY=1 ev rule-fired 2026-10-06T20:00:00Z 1 G2
  ev gap             2026-10-06T20:03:00Z 5 10
  run read_events
  [ "$status" -eq 0 ]
  eps_for G2 "
assert len(eps) == 1, eps
ep = eps[0]
assert ep['start_unobserved'] is True, ep
assert ep['ongoing'] is True, ep
assert ep['ended_by'] == 'still-open', ep
assert ep['duration_s'] == 180, ep
assert ep['unobserved_s'] == 10, ep
"
}

@test "start-unobserved survives being bridged across a later restart" {
  ev monitor-started 2026-10-06T20:00:00Z 1
  ALREADY=1 ev rule-fired 2026-10-06T20:00:00Z 1 G2
  ev monitor-started 2026-10-06T20:01:00Z 1
  ALREADY=1 ev rule-fired 2026-10-06T20:01:00Z 1 G2
  ev rule-cleared    2026-10-06T20:02:00Z 9 G2
  run read_events
  [ "$status" -eq 0 ]
  eps_for G2 "
assert len(eps) == 1, eps
ep = eps[0]
assert ep['started'] == '2026-10-06T20:00:00Z', ep
assert ep['start_unobserved'] is True, ep
assert ep['duration_s'] == 120, ep
assert ep['restarts_bridged'] == 1, ep
assert ep['duration_is_lower_bound'] is True, ep
"
}

@test "a fault that ended while the monitor was down still ends at the restart" {
  # The new monitor's first sample did not have G2, so nothing carries it:
  # closed at the restart, as a lower bound, exactly as before. G3 is in
  # progress at start, and is its own start-unobserved episode.
  ev rule-fired      2026-10-06T20:00:00Z 5 G2
  ev monitor-started 2026-10-06T20:10:00Z 1
  ALREADY=1 ev rule-fired 2026-10-06T20:10:00Z 1 G3
  ev rule-cleared    2026-10-06T20:10:30Z 4 G3
  run read_events
  [ "$status" -eq 0 ]
  eps_for G2 "
assert len(eps) == 1, eps
ep = eps[0]
assert ep['ended_by'] == 'monitor-restart', ep
assert ep['ended'] == '2026-10-06T20:10:00Z', ep
assert ep['duration_s'] == 600, ep
assert ep['duration_is_lower_bound'] is True, ep
assert 'restarts_bridged' not in ep, ep
"
  eps_for G3 "
assert len(eps) == 1, eps
assert eps[0]['start_unobserved'] is True, eps[0]
assert eps[0]['duration_s'] == 30, eps[0]
"
}

@test "an in-progress rule on a different network does not continue the first" {
  NET=wifi:mac=aa ev rule-fired      2026-10-06T20:00:00Z 5 G2
  NET=wifi:mac=bb ev monitor-started 2026-10-06T20:10:00Z 1
  NET=wifi:mac=bb ALREADY=1 ev rule-fired 2026-10-06T20:10:00Z 1 G2
  run read_events
  [ "$status" -eq 0 ]
  eps_for G2 "
assert len(eps) == 2, eps
by_net = {e['network']: e for e in eps}
assert by_net['wifi:mac=aa']['ended_by'] == 'monitor-restart', eps
assert 'restarts_bridged' not in by_net['wifi:mac=aa'], eps
assert by_net['wifi:mac=bb']['start_unobserved'] is True, eps
"
}

@test "a rule that cleared before the restart is not continued by an in-progress line" {
  ev rule-fired      2026-10-06T20:00:00Z 5 G2
  ev rule-cleared    2026-10-06T20:00:30Z 6 G2
  ev monitor-started 2026-10-06T20:00:40Z 1
  ALREADY=1 ev rule-fired 2026-10-06T20:00:40Z 1 G2
  run read_events
  [ "$status" -eq 0 ]
  eps_for G2 "
assert len(eps) == 2, eps
assert eps[0]['ended_by'] == 'cleared' and eps[0]['duration_s'] == 30, eps
assert eps[1]['start_unobserved'] is True, eps
assert 'restarts_bridged' not in eps[1], eps
"
}

@test "the same in-progress line twice does not make two episodes" {
  # The archive roll can duplicate lines; load() dedupes, and a second
  # copy from a different process must not reopen anything either.
  ev monitor-started 2026-10-06T20:00:00Z 1
  ALREADY=1 ev rule-fired 2026-10-06T20:00:00Z 1 G2
  ALREADY=1 ev rule-fired 2026-10-06T20:00:01Z 2 G2
  ev rule-cleared    2026-10-06T20:05:00Z 9 G2
  run read_events
  [ "$status" -eq 0 ]
  eps_for G2 "
assert len(eps) == 1, eps
assert eps[0]['duration_s'] == 300, eps[0]
"
}

# ── Journals written before the start lines existed ─────────────────────
#
# Old journals have a restart, no re-fire, and later a rule-cleared the
# fresh monitor saw for a rule it was already carrying. Read literally that
# was two entries for one fault: the episode closed at the restart, and an
# orphan clear with no beginning.

@test "an orphan clear after a restart continues the episode the restart closed" {
  ev rule-fired      2026-10-06T20:00:00Z 5 G2
  ev monitor-started 2026-10-06T20:10:00Z 1
  ev rule-cleared    2026-10-06T20:25:00Z 9 G2
  run read_events
  [ "$status" -eq 0 ]
  eps_for G2 "
assert len(eps) == 1, eps
ep = eps[0]
assert ep['started'] == '2026-10-06T20:00:00Z', ep
assert ep['ended'] == '2026-10-06T20:25:00Z', ep
assert ep['duration_s'] == 1500, ep
assert ep['ended_by'] == 'cleared', ep
assert ep['ongoing'] is False, ep
assert ep['restarts_bridged'] == 1, ep
assert 'duration_is_lower_bound' not in ep, ep
# Nothing journaled what the second monitor saw before the clear.
assert ep['unobserved_s'] == 900, ep
"
}

@test "an orphan clear for a rule the restart did not close is still an end with no beginning" {
  ev rule-fired      2026-10-06T20:00:00Z 5 G2
  ev monitor-started 2026-10-06T20:10:00Z 1
  ev rule-cleared    2026-10-06T20:10:11Z 3 TCP-1
  run read_events
  [ "$status" -eq 0 ]
  eps_for TCP-1 "
assert len(eps) == 1, eps
assert eps[0]['started'] is None, eps[0]
assert eps[0]['start_unobserved'] is True, eps[0]
assert eps[0]['duration_s'] is None, eps[0]
"
  eps_for G2 "
assert len(eps) == 1 and eps[0]['ended_by'] == 'monitor-restart', eps
"
}
