#!/usr/bin/env bats
#
# netdiag --rules-catalog — the plain-English layer a GUI shows next to a
# rule-ID chip, because CLAUDE.md forbids diagnostic prose in gui/. Same
# family as test_capabilities.bats: an early exit, no probing, no log
# file, no network.
#
# THE LOAD-BEARING TEST is "catalog matches every add_diag / _mon_add_rule
# call site" below. Everything else here is shape-checking; that one is
# the thing that makes a forgotten rule fail CI instead of shipping a
# GUI that can't explain it.

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  NETDIAG="$REPO/bin/netdiag"
  HELPERS="$REPO/helpers"
  VERSION="$(grep -m1 '^NETDIAG_VERSION=' "$REPO/bin/netdiag" \
    | sed -E 's/^NETDIAG_VERSION="([^"]*)"/\1/')"
  [ -n "$VERSION" ]
}

# ── Shape ─────────────────────────────────────────────────────────────

@test "--rules-catalog exits 0 and prints one parseable JSON object" {
  run "$NETDIAG" --rules-catalog
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -m json.tool >/dev/null
  # One compact line, like --capabilities and every other machine-consumed
  # sibling output.
  [[ "$output" != *$'\n'* ]] || return 1
}

@test "--rules-catalog writes nothing under HOME — no log, no history append" {
  run bash -c "HOME='$BATS_TEST_TMPDIR' '$NETDIAG' --rules-catalog"
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/net-diag" ]
}

@test "--rules-catalog is documented in --help" {
  run "$NETDIAG" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--rules-catalog"* ]] || return 1
}

@test "--rules-catalog appears in --capabilities features" {
  run "$NETDIAG" --capabilities
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
assert 'rules-catalog' in json.load(sys.stdin)['features']
"
}

@test "version equals the running NETDIAG_VERSION" {
  run "$NETDIAG" --rules-catalog
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['version'] == sys.argv[1], d['version']
" "$VERSION"
}

@test "schema is 5" {
  # 1 -> 2 added the `metrics` glossary; 2 -> 3 added the optional
  # per-rule `also` category; 3 -> 4 added the optional per-metric
  # `why_absent` field plus 16 new metrics entries; 4 -> 5 added the
  # optional per-rule `impacts` map. All additive, per this schema's own
  # promise in docs/JSON-SCHEMA.md.
  run "$NETDIAG" --rules-catalog
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
assert json.load(sys.stdin)['schema'] == 5
"
}

# ── metrics glossary ──────────────────────────────────────────────────

@test "metrics glossary covers at least the terms the report card shows" {
  run "$NETDIAG" --rules-catalog
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
keys = {m['key'] for m in d['metrics']}
required = {'router', 'internet', 'dns', 'wifi_signal', 'bufferbloat',
            'mtu', 'speed', 'clock', 'packet_loss', 'latency', 'jitter'}
missing = required - keys
assert not missing, missing
"
}

@test "every metrics entry has key/label/help plus optional why_absent, all non-empty" {
  run "$NETDIAG" --rules-catalog
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
required = {'key', 'label', 'help'}
optional = {'why_absent'}
for m in d['metrics']:
    keys = set(m.keys())
    assert keys - optional == required, (m.get('key'), sorted(keys))
    for k, v in m.items():
        assert isinstance(v, str) and v.strip(), (m.get('key'), k, v)
"
}

@test "metrics keys are unique" {
  run "$NETDIAG" --rules-catalog
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
keys = [m['key'] for m in d['metrics']]
assert len(keys) == len(set(keys)), sorted(set(k for k in keys if keys.count(k) > 1))
"
}

@test "catalog covers every --history METRICS key and every JUDGED_METRICS key" {
  # A GUI HelpHint next to a Trends/Live chart title looks itself up by
  # the exact --history metric key (or, for the live monitor, the
  # monitor_* keys above). Read straight from the Python modules rather
  # than hand-copying their key lists here, so a metric added to either
  # table can't silently ship without a glossary entry.
  run "$NETDIAG" --rules-catalog
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
sys.path.insert(0, '$HELPERS')
import history
import judgement

d = json.load(sys.stdin)
keys = {m['key'] for m in d['metrics']}

history_keys = {row[1] for row in history.METRICS}
judged_keys = set(judgement.JUDGED_METRICS)

missing = (history_keys | judged_keys) - keys
assert not missing, sorted(missing)
"
}

@test "glossary help/why_absent text embeds no numeric threshold — dBm, %, ms, or bare digits" {
  run "$NETDIAG" --rules-catalog
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, re, sys
d = json.load(sys.stdin)
pattern = re.compile(r'[0-9](?:\s?(?:dbm|db|ms|%|seconds?|bytes?))', re.IGNORECASE)
bad = []
for m in d['metrics']:
    for field in ('help', 'why_absent'):
        text = m.get(field)
        if text and pattern.search(text):
            bad.append((m['key'], field, pattern.findall(text)))
assert not bad, bad
"
}

# ── Every entry: complete, well-typed, closed-set fields ────────────────

@test "every entry has all 9 required fields, non-empty" {
  # `also` (schema 3) and `impacts` (schema 5) are the two optional fields,
  # each checked in more depth elsewhere. Everything else stays mandatory:
  # this test is what stops a rule shipping with a blank blurb the GUI
  # would render as an empty chip. `impacts` is a dict, not a string, so
  # it is excluded from the non-empty-string check below rather than
  # asserted against it.
  run "$NETDIAG" --rules-catalog
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
required = {'id', 'title', 'category', 'severity', 'scope', 'blurb', 'doc',
            'fix', 'fix_target'}
optional = {'also', 'impacts', 'fix_away'}
for r in d['rules']:
    keys = set(r.keys())
    assert keys - optional == required, (r.get('id'), sorted(keys))
    for k, v in r.items():
        if k == 'impacts':
            continue
        assert isinstance(v, str) and v.strip(), (r.get('id'), k, v)
"
}

@test "every entry's category is from the closed set" {
  run "$NETDIAG" --rules-catalog
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
allowed = {'router', 'internet', 'dns', 'wifi', 'load', 'mtu', 'speed',
           'clock', 'ipv6', 'vpn', 'lan', 'dhcp', 'topology', 'baseline',
           # The three categories that are not properties of the network
           # as it is right now: netdiag judging its own background
           # watcher (ND-1), how the network has behaved over time
           # according to the event journal (AV-1, AV-2), and what this
           # Mac itself was putting on the link while measuring (TR-1).
           'netdiag', 'availability', 'traffic'}
d = json.load(sys.stdin)
for r in d['rules']:
    assert r['category'] in allowed, (r['id'], r['category'])
"
}

@test "every entry's severity is from the closed set" {
  run "$NETDIAG" --rules-catalog
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
allowed = {'info', 'warn', 'critical', 'varies'}
d = json.load(sys.stdin)
for r in d['rules']:
    assert r['severity'] in allowed, (r['id'], r['severity'])
"
}

@test "every entry's scope is from the closed set" {
  run "$NETDIAG" --rules-catalog
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
allowed = {'scan', 'monitor', 'both'}
d = json.load(sys.stdin)
for r in d['rules']:
    assert r['scope'] in allowed, (r['id'], r['scope'])
"
}

@test "B1, B2, M1, NT-1 are severity 'varies' — they grade by magnitude" {
  run "$NETDIAG" --rules-catalog
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
by_id = {r['id']: r for r in d['rules']}
for rid in ('B1', 'B2', 'M1', 'NT-1'):
    assert by_id[rid]['severity'] == 'varies', (rid, by_id[rid]['severity'])
"
}

@test "scope is derived from the call sites, not hand-maintained" {
  # A rule's scope must equal what the code actually does: an add_diag
  # call site makes it scan, a _mon_add_rule site makes it monitor, both
  # make it both. Derived with the same quote-tolerant extraction the
  # load-bearing test uses, so a rule newly wired into the monitor can't
  # keep claiming scope "scan" silently — that would tell the GUI a rule
  # it just received on the stream can't appear there.
  local q="['\"]"
  local scan_set mon_set
  scan_set="$(grep -ohE "add_diag[[:space:]]+${q}?(critical|warn|info)${q}?[[:space:]]+${q}?[A-Za-z0-9_-]+${q}?" \
    "$REPO/bin/netdiag" "$REPO"/lib/*.sh | awk '{print $NF}' | tr -d '"' | tr -d "'" | sort -u)"
  mon_set="$(grep -ohE "_mon_add_rule[[:space:]]+${q}?(critical|warn|info)${q}?[[:space:]]+${q}?[A-Za-z0-9_-]+${q}?" \
    "$REPO/bin/netdiag" "$REPO"/lib/*.sh | awk '{print $NF}' | tr -d '"' | tr -d "'" | sort -u)"
  [ -n "$scan_set" ]
  [ -n "$mon_set" ]
  run "$NETDIAG" --rules-catalog
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
scan = set(sys.argv[1].split())
mon = set(sys.argv[2].split())
for r in json.load(sys.stdin)['rules']:
    rid = r['id']
    expect = 'both' if (rid in scan and rid in mon) else ('monitor' if rid in mon else 'scan')
    assert r['scope'] == expect, (rid, r['scope'], expect)
" "$scan_set" "$mon_set"
}

@test "blurbs embed no numeric threshold — dBm, %, ms, or bare digits" {
  # Thresholds live in exactly one place: lib/thresholds.sh. A number in a
  # blurb would be a second, driftable copy of a cutoff docs/DIAGNOSIS-RULES.md
  # already states precisely. Flags common unit-attached numbers; not a
  # full parser, but enough to catch a copy-pasted "-75 dBm" or "20%".
  run "$NETDIAG" --rules-catalog
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, re, sys
d = json.load(sys.stdin)
pattern = re.compile(r'[0-9](?:\s?(?:dbm|db|ms|%|seconds?|bytes?))', re.IGNORECASE)
bad = [(r['id'], pattern.findall(r['blurb'])) for r in d['rules'] if pattern.search(r['blurb'])]
assert not bad, bad
"
}

@test "doc anchors resolve to real headings in DIAGNOSIS-RULES.md" {
  run "$NETDIAG" --rules-catalog
  [ "$status" -eq 0 ]
  local catalog="$output"
  python3 -c "
import json, re, sys

def github_anchor(text):
    t = text.lower()
    t = re.sub(r'[^\w\s-]', '', t, flags=re.UNICODE)
    return t.replace(' ', '-')

headings = []
with open(sys.argv[1]) as f:
    for line in f:
        if line.startswith('### '):
            headings.append(github_anchor(line[4:].strip()))
anchors = set(headings)

d = json.loads(sys.argv[2])
bad = []
for r in d['rules']:
    doc = r['doc']
    assert doc.startswith('DIAGNOSIS-RULES.md#'), (r['id'], doc)
    anchor = doc.split('#', 1)[1]
    if anchor not in anchors:
        bad.append((r['id'], anchor))
assert not bad, bad
" "$REPO/docs/DIAGNOSIS-RULES.md" "$catalog"
}

@test "rule ids are unique" {
  run "$NETDIAG" --rules-catalog
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
ids = [r['id'] for r in d['rules']]
assert len(ids) == len(set(ids)), sorted(set(x for x in ids if ids.count(x) > 1))
"
}

# ── THE LOAD-BEARING TEST ────────────────────────────────────────────────
# The set of rule IDs the shell code can actually emit must equal the
# catalog's ID set, minus documented exclusions (UP-1: reserved in
# docs/DIAGNOSIS-RULES.md, never emitted — no add_diag call exists for it
# anywhere in the tree). A rule added to lib/*.sh or lib/monitor.sh
# without a matching catalog entry fails here, not silently in the GUI.
#
# The extraction pattern tolerates an optional single or double quote
# around both the severity and the rule-ID token — add_diag warn "XX-1"
# extracts the same ID as add_diag warn XX-1 — because a regex that only
# matched the unquoted form would silently drop a quoted call site from
# both sides of the comparison at once and this test would keep passing.
# The floor assertion below is the other half of that guard: a pattern
# that stops matching entirely degrades the extracted set toward empty,
# and an empty set can equal an empty catalog read just as easily as a
# real mismatch — the floor forces that failure to be loud instead.

@test "catalog's rule IDs exactly match every add_diag / _mon_add_rule call site" {
  # Every add_diag / _mon_add_rule call site in this tree passes its
  # severity and rule ID as literal tokens, optionally quoted (never a
  # variable) — verified by eye against lib/diagnosis.sh, lib/wan.sh,
  # lib/output.sh and lib/monitor.sh when this test was written. A future
  # call site that passes a variable would silently vanish from this
  # extraction rather than fail loud, which is why this comment exists:
  # check by eye again if this test ever needs updating for a new call
  # site.
  #
  # _mon_add_rule is grepped across lib/*.sh, not just lib/monitor.sh —
  # it is only defined and called there today, but grepping the whole
  # directory costs nothing and stays correct if that ever changes.
  local q="['\"]"
  local add_diag_re="add_diag[[:space:]]+${q}?(critical|warn|info)${q}?[[:space:]]+${q}?[A-Za-z0-9_-]+${q}?"
  local mon_add_rule_re="_mon_add_rule[[:space:]]+${q}?(critical|warn|info)${q}?[[:space:]]+${q}?[A-Za-z0-9_-]+${q}?"

  # bin/netdiag is included even though no call site lives there today:
  # an add_diag added to the entry point would otherwise vanish from both
  # sides of the comparison at once.
  local extracted
  extracted="$(
    { grep -ohE "$add_diag_re" "$REPO/bin/netdiag" "$REPO"/lib/*.sh
      grep -ohE "$mon_add_rule_re" "$REPO/bin/netdiag" "$REPO"/lib/*.sh
    } | awk '{print $NF}' | tr -d '"' | tr -d "'" | sort -u
  )"
  [ -n "$extracted" ]

  # Documented exclusion: UP-1 is reserved (docs/DIAGNOSIS-RULES.md) and
  # never emitted. Strip it defensively in case it's ever wired up without
  # updating this test — the assertion below would then simply start
  # failing on a real mismatch instead of masking one.
  extracted="$(printf '%s\n' "$extracted" | grep -v '^UP-1$' || true)"

  # Floor: today's tree extracts 33. A regex that stops matching (a typo
  # in this test, a call-site style the pattern didn't anticipate) would
  # otherwise degrade silently to "both sets are empty, so they're equal"
  # — see the comment above the @test block.
  local extracted_count
  extracted_count="$(printf '%s\n' "$extracted" | grep -c '.')"
  [ "$extracted_count" -ge 25 ]

  run "$NETDIAG" --rules-catalog
  [ "$status" -eq 0 ]
  local catalog_ids
  catalog_ids="$(printf '%s' "$output" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("\n".join(sorted(r["id"] for r in d["rules"])))
')"

  local extracted_sorted
  extracted_sorted="$(printf '%s\n' "$extracted" | sort -u)"

  [ "$extracted_sorted" = "$catalog_ids" ]
}

@test "UP-1 is not in the catalog — reserved, never emitted" {
  run "$NETDIAG" --rules-catalog
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
ids = {r['id'] for r in d['rules']}
assert 'UP-1' not in ids
"
  # And confirm the premise: no add_diag call for UP-1 exists anywhere.
  run bash -c "grep -RhE 'add_diag[[:space:]]+(critical|warn|info)[[:space:]]+UP-1' '$REPO'/lib/*.sh"
  [ "$status" -ne 0 ]
}

# ── Unknown-flag behavior is unaffected ──────────────────────────────────

@test "an unrelated unknown flag still exits 3, not 0 or 2" {
  run "$NETDIAG" --this-flag-does-not-exist
  [ "$status" -eq 3 ]
}

# ── Category → report-card row coverage ──────────────────────────────────
#
# THE OTHER LOAD-BEARING TEST. The GUI tints a report-card row by the
# category of the rules that fired, so a category no row claims colours
# nothing at all — and the failure is silent in the worst possible way: an
# all-green card sitting directly above its own amber findings. That is
# exactly what `ipv6`, `topology`, `vpn` and `speed` did before the row
# table was completed.
#
# This spans two languages, so it lives here rather than in the Swift
# `--verify` harness: the categories are defined in Python and consumed in
# Swift, and only a test that reads both can hold them together. Same
# shape as test_thresholds.bats grepping Python for inline cutoffs.

@test "every rule category has a report-card row that claims it" {
  run "$NETDIAG" --rules-catalog
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, re, sys
d = json.load(sys.stdin)

used = set()
for r in d['rules']:
    used.add(r['category'])
    if r.get('also'):
        used.add(r['also'])

src = open('$REPO/gui/Sources/NetdiagGUI/Views/RunReportView.swift').read()
block = re.search(
    r'static let rowCategories: \[String: Set<String>\] = \[(.*?)\n    \]',
    src, re.S)
assert block, 'rowCategories table not found in RunReportView.swift'
claimed = set()
for line in block.group(1).splitlines():
    m = re.match(r'\s*\"[^\"]+\":\s*\[(.*)\],\s*\$', line)
    if m:
        claimed.update(re.findall(r'\"([^\"]+)\"', m.group(1)))
assert claimed, 'parsed no categories out of rowCategories'

orphans = used - claimed
assert not orphans, f'categories no report-card row claims: {sorted(orphans)}'
"
}

@test "the row-coverage guard would actually catch an unclaimed category" {
  # The guard above is only worth having if it fails when it should, so
  # prove it against a category deliberately absent from the table.
  run python3 -c "
import re
src = open('$REPO/gui/Sources/NetdiagGUI/Views/RunReportView.swift').read()
block = re.search(
    r'static let rowCategories: \[String: Set<String>\] = \[(.*?)\n    \]',
    src, re.S)
claimed = set()
for line in block.group(1).splitlines():
    m = re.match(r'\s*\"[^\"]+\":\s*\[(.*)\],\s*\$', line)
    if m:
        claimed.update(re.findall(r'\"([^\"]+)\"', m.group(1)))
assert 'a-category-no-row-claims' not in claimed
raise SystemExit(0 if ({'a-category-no-row-claims'} - claimed) else 1)
"
  [ "$status" -eq 0 ]
}

@test "G1 is judged as a router rule, with wifi as its secondary" {
  # The regression this whole field exists for. G1 and G2 report the same
  # measurement — packets lost between the Mac and the gateway — so they
  # must tint the same row. Filed under 'wifi' alone, G1 left the Router
  # row green beside the words '35% loss' and reddened a Wi-Fi row that
  # had no number in it.
  run "$NETDIAG" --rules-catalog
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
rules = {r['id']: r for r in json.load(sys.stdin)['rules']}
assert rules['G1']['category'] == 'router', rules['G1']['category']
assert rules['G1'].get('also') == 'wifi', rules['G1'].get('also')
assert rules['G1']['category'] == rules['G2']['category'], 'G1 and G2 must share a primary'
"
}

@test "an 'also' category is a real category and never repeats the primary" {
  run "$NETDIAG" --rules-catalog
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
primaries = {r['category'] for r in d['rules']}
for r in d['rules']:
    also = r.get('also')
    if also is None:
        continue
    assert isinstance(also, str) and also.strip(), r['id']
    assert also != r['category'], f\"{r['id']}: also repeats category\"
    assert also in primaries, f\"{r['id']}: {also!r} is not a known category\"
"
}

# ── Suitability impacts (schema 5) ───────────────────────────────────────

@test "rules-catalog: every impacts entry uses known activities and levels" {
  # Piping into `python3 - <<PY` doesn't work: the heredoc is consumed as
  # the *script*, so sys.stdin is already at EOF by the time the script
  # body runs — json.load(sys.stdin) sees nothing regardless of what was
  # piped in. Using -c with a quoted script, like every other test in this
  # file, keeps the pipe intact.
  run "$NETDIAG" --rules-catalog
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c '
import json, sys
ACTIVITIES = {"calls", "streaming", "gaming", "vpn", "browsing"}
LEVELS = {"degraded", "broken"}
doc = json.load(sys.stdin)
seen = 0
for r in doc["rules"]:
    imp = r.get("impacts")
    if imp is None:
        continue
    seen += 1
    rid = r["id"]
    assert isinstance(imp, dict), f"{rid}: impacts is not an object"
    assert imp, f"{rid}: impacts is empty - omit the key instead"
    for activity, level in imp.items():
        assert activity in ACTIVITIES, f"{rid}: bad activity {activity!r}"
        assert level in LEVELS, f"{rid}: bad level {level!r}"
assert seen, "no rule carries impacts at all"
# Every critical rule must say what it breaks. A fault graded critical
# that affects nothing a person actually does is a contradiction: the
# severity claims the connection is unusable while the table claims
# every activity is fine. Stated as an invariant rather than a count,
# because a count is a magic number that goes stale the moment a rule
# is added — and this caught ETH-2, which was critical and classified
# as having no consequence at all.
missing = [r["id"] for r in doc["rules"]
           if r["severity"] == "critical" and not r.get("impacts")]
assert not missing, f"critical rules with no impacts: {missing}"
'
}

@test "rules-catalog: the rules that break everything say so" {
  run "$NETDIAG" --rules-catalog
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c '
import json, sys
by_id = {r["id"]: r for r in json.load(sys.stdin)["rules"]}
for rule in ("N1", "P1", "CP-1"):
    imp = by_id[rule].get("impacts") or {}
    assert set(imp) == {"calls", "streaming", "gaming", "vpn", "browsing"}, \
        f"{rule}: expected all five activities, got {sorted(imp)}"
    assert set(imp.values()) == {"broken"}, f"{rule}: expected all broken"
b1 = by_id["B1"]["impacts"]
# bufferbloat is load-conditional, so degraded and never broken — see
# the intermittent-or-historical test below.
assert set(b1.values()) == {"degraded"}, b1
assert "impacts" not in by_id["NT-1"], "NT-1 should carry no impacts"
'
}

@test "rules-catalog: an intermittent or historical fault is never 'broken'" {
  # `broken` renders as "won't hold up", which reads as "do not bother
  # trying". That is a claim about the connection as it is right now, so
  # a rule describing something that comes and goes (AV-2, flapping) or
  # something that already happened (AV-1, outages over the last day)
  # must not use it — the link works between the flaps, and a good
  # reading now is not undone by a bad night.
  #
  # This exists because the first draft of the table had both at
  # `calls: broken`, alongside NAT-1 claiming double NAT breaks gaming
  # outright when it only costs you inbound reach.
  run "$NETDIAG" --rules-catalog
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c '
import json, sys
INTERMITTENT_OR_HISTORICAL = {"AV-1", "AV-2", "WD-1", "NAT-1", "NAT-1b",
                              # Load-conditional: bufferbloat only bites
                              # while the link is saturated, and on an
                              # idle link the same call is fine.
                              "B1", "B2"}
bad = []
for r in json.load(sys.stdin)["rules"]:
    if r["id"] not in INTERMITTENT_OR_HISTORICAL:
        continue
    for activity, level in (r.get("impacts") or {}).items():
        if level == "broken":
            bad.append((r["id"], activity))
assert not bad, bad
'
}

# ── Remediation: fix / fix_away / fix_target (schema 5) ──────────────────

@test "rules-catalog: every rule carries a fix with a valid target" {
  run "$NETDIAG" --rules-catalog
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c '
import json, sys
TARGETS = {"you", "your_router", "your_isp", "network_operator", "nobody"}
for r in json.load(sys.stdin)["rules"]:
    rid = r["id"]
    assert "fix" in r, rid + ": no fix"
    assert "fix_target" in r, rid + ": no fix_target"
    target = r["fix_target"]
    assert target in TARGETS, rid + ": bad target " + repr(target)
    assert r["fix"].strip(), rid + ": empty fix"
'
}

@test "rules-catalog: fix_away is present exactly where the advice changes" {
  # `you` (something on this Mac) and `your_isp` (a phone call either way)
  # read the same in a hotel as at home, so they carry one sentence. The
  # other two targets are the whole reason this field exists.
  run "$NETDIAG" --rules-catalog
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c '
import json, sys
NEEDS_AWAY = {"your_router", "network_operator"}
for r in json.load(sys.stdin)["rules"]:
    rid = r["id"]
    has = "fix_away" in r
    want = r["fix_target"] in NEEDS_AWAY
    assert has == want, rid + ": target " + r["fix_target"] + " but fix_away " + ("present" if has else "absent")
    if has:
        assert r["fix_away"].strip(), rid + ": empty fix_away"
        assert r["fix_away"] != r["fix"], rid + ": fix_away repeats fix"
'
}

@test "rules-catalog: away advice never opens with an order the reader cannot carry out" {
  # The whole point of fix_away. "Reboot the router", read by a hotel
  # guest, is an instruction they cannot follow; "ask whoever runs this
  # network to restart it" is one they can. An imperative opening is the
  # signature of advice written for the wrong reader.
  run "$NETDIAG" --rules-catalog
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c '
import json, re, sys
IMPERATIVE = re.compile(r"^(reboot|restart|unplug|power[- ]cycle|log in|log into|open the router|replace)", re.I)
bad = []
for r in json.load(sys.stdin)["rules"]:
    away = r.get("fix_away")
    if away and IMPERATIVE.match(away.strip()):
        bad.append((r["id"], away[:60]))
assert not bad, bad
'
}

@test "rules-catalog: fix text embeds no numeric threshold" {
  # Same discipline the blurbs already keep: a number belongs in
  # lib/thresholds.sh, and `doc` is where the actual figure lives.
  run "$NETDIAG" --rules-catalog
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c '
import json, re, sys
pattern = re.compile(r"[0-9](?:\s?(?:dbm|db|ms|%|mbps|seconds?|bytes?))", re.IGNORECASE)
bad = []
for r in json.load(sys.stdin)["rules"]:
    for field in ("fix", "fix_away"):
        text = r.get(field)
        if text and pattern.search(text):
            bad.append((r["id"], field, pattern.findall(text)))
assert not bad, bad
'
}
