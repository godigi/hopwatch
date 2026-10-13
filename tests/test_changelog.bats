#!/usr/bin/env bats
#
# CHANGELOG.md is the source of every GitHub Release's notes, so a defect
# in the file becomes a defect on the repo's front page. Two have already
# happened and both were invisible until someone went looking:
#
#   - a second `## [Unreleased]` heading sat mid-file between 0.5.2 and
#     0.5.1 for months, holding notes that had actually shipped in 0.6.0;
#   - 0.1.0, 0.4.1, 0.5.0 and 0.9.1 were documented here with no tag
#     anywhere, so their entries described a version no one could check out.
#
# Neither broke a build, which is exactly why they lasted. These tests
# make both loud, and cover helpers/changelog_section.py — the parser
# .github/workflows/release.yml depends on to generate notes.

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  CHANGELOG="$REPO/CHANGELOG.md"
  ARCHIVE="$REPO/docs/CHANGELOG-archive.md"
  SECTION="$REPO/helpers/changelog_section.py"
}

# Version headings, in file order, excluding [Unreleased].
released_versions() {
  python3 "$SECTION" --file "$CHANGELOG" --list | cut -f1 | grep -v '^Unreleased$'
}

# The two guards below compare the docs against the tag list, so they are
# meaningless in a checkout that has no tags — and worse than meaningless:
# every version reads as untagged and the build goes red on a repo that is
# entirely correct, which is exactly what `actions/checkout` (which fetches
# no tags by default) produced the first time these ran. CI now sets
# `fetch-tags: true`; this skip keeps a shallow or tagless clone honest
# rather than failing it for a defect it cannot see.
require_tags() {
  [ -n "$(git -C "$REPO" tag -l 2>/dev/null)" ] \
    || skip "checkout has no tags; nothing to check the docs against"
}

# ── The parser ───────────────────────────────────────────────────────────

@test "changelog_section extracts a known section's prose" {
  run python3 "$SECTION" --file "$ARCHIVE" --version 0.6.1
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "changelog_section accepts a version with or without a leading v" {
  run python3 "$SECTION" --file "$ARCHIVE" --version v0.6.1
  [ "$status" -eq 0 ]
  local with_v="$output"
  run python3 "$SECTION" --file "$ARCHIVE" --version 0.6.1
  [ "$output" = "$with_v" ]
}

@test "changelog_section fails loudly on a version that isn't there" {
  # The release workflow relies on this being an error rather than an
  # empty string: empty notes would publish a blank Release and look fine.
  run python3 "$SECTION" --file "$CHANGELOG" --version 9.9.9
  [ "$status" -ne 0 ]
  [[ "$output" == *"no '## [9.9.9]'"* ]] || return 1
}

@test "changelog_section keeps the link-ref footer out of the oldest section" {
  # The footer sits directly under the last version's prose, so an
  # off-by-one in the parser publishes a maintenance note as 0.1.0's
  # release notes.
  run python3 "$SECTION" --file "$ARCHIVE" --version 0.1.0
  [ "$status" -eq 0 ]
  [[ "$output" != *"https://github.com"* ]] || return 1
  [[ "$output" != *"<!--"* ]] || return 1
}

# ── The file's structure ─────────────────────────────────────────────────

@test "there is exactly one [Unreleased] heading" {
  run grep -c '^## \[Unreleased\]' "$CHANGELOG"
  [ "$output" -eq 1 ]
}

@test "versions run in descending order" {
  local versions sorted
  versions="$(released_versions)"
  sorted="$(printf '%s\n' "$versions" | sort -rV)"
  [ "$versions" = "$sorted" ] || {
    echo "file order:   $(printf '%s ' $versions)"
    echo "sorted order: $(printf '%s ' $sorted)"
    return 1
  }
}

@test "the newest released version has a git tag" {
  # The gap this closes: a CHANGELOG entry for a version that was never
  # tagged describes something a reader cannot obtain. Only the newest
  # version is held to it. Older releases and their tags were deliberately
  # pruned from the public repo, and their notes live in
  # docs/CHANGELOG-archive.md, so "every heading has a tag" can no longer
  # hold and would fail on every release after the one that pruned them.
  require_tags
  local v
  v="$(released_versions | head -1)"
  [ -n "$v" ] || { echo "CHANGELOG.md has no released version"; return 1; }
  git -C "$REPO" rev-parse -q --verify "refs/tags/v$v" >/dev/null \
    || { echo "newest documented version v$v has no tag"; return 1; }
}

@test "every version heading is preceded by a blank line" {
  # Not cosmetic. Releasing v0.9.1 inserted its heading directly on top of
  # the last line of the entry above it, deleting "asserted to exit
  # anything but 3 and to parse with python3." — the previous release's
  # notes ended mid-sentence, and nothing complained. A heading flush
  # against prose is the visible signature of that clobber.
  local bad
  bad="$(awk '
    /^## \[/ && NR > 1 && prev != "" { print NR ": " $0 }
    { prev = $0 }
  ' "$CHANGELOG")"
  [ -z "$bad" ] || { echo "heading with no blank line above it:"; echo "$bad"; return 1; }
}

@test "every heading has a link-reference definition" {
  local missing=""
  while read -r v; do
    [ -n "$v" ] || continue
    grep -qF "[$v]: http" "$CHANGELOG" || missing="$missing $v"
  done <<< "$(python3 "$SECTION" --file "$CHANGELOG" --list | cut -f1)"
  [ -z "$missing" ] || { echo "headings with no link ref:$missing"; return 1; }
}

@test "no link reference depends on a tag other than the newest" {
  # Only the newest release and tag are kept. A compare link between two
  # tags, or a link to an older release page, is dead the moment the next
  # release deletes the tag it names; 1.17.0, 1.16.3 and 1.16.2 shipped
  # with exactly that. Older versions link to a commit, which outlives tags.
  local newest bad
  newest="$(released_versions | head -1)"
  bad="$(grep -E '^\[[^]]+\]: https://' "$CHANGELOG" | awk -v newest="$newest" '
    /^\[Unreleased\]:/ {
      # Must compare from the newest tag, nothing else.
      if ($0 !~ ("/compare/v" newest "\\.\\.\\.HEAD$")) print; next
    }
    /\/compare\// { print; next }
    /\/releases\/tag\// && $0 !~ ("/releases/tag/v" newest "$") { print }
  ')"
  [ -z "$bad" ] || { echo "link refs that depend on a tag that will not exist:"; echo "$bad"; return 1; }
}

# bump.py's roll_link_refs, run against a throwaway repo with real tags.
roll_links() {  # roll_links <changelog-text> <next> <prev> <repo-dir>
  ( cd "$4" && python3 -I - "$REPO/scripts/bump.py" "$1" "$2" "$3" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("bump", sys.argv[1])
bump = importlib.util.module_from_spec(spec); spec.loader.exec_module(bump)
sys.stdout.write(bump.roll_link_refs(sys.argv[2], sys.argv[3], sys.argv[4]))
PY
  )
}

make_tagged_repo() {  # prints the dir; tags v1.0.0 only
  local d; d="$(mktemp -d)"
  git -C "$d" init -q
  git -C "$d" -c user.name=t -c user.email=t@t commit -q --allow-empty -m one
  git -C "$d" tag v1.0.0
  echo "$d"
}

@test "bump.py links the new version to its release and the previous one to a commit" {
  local d sha out
  d="$(make_tagged_repo)"
  sha="$(git -C "$d" rev-parse v1.0.0)"
  out="$(roll_links $'[Unreleased]: https://github.com/godigi/hopwatch/compare/v1.0.0...HEAD\n[1.0.0]: https://github.com/godigi/hopwatch/releases/tag/v1.0.0\n[0.9.0]: https://github.com/godigi/hopwatch/commit/abc' 1.0.1 1.0.0 "$d")"
  rm -rf "$d"
  grep -qF '[Unreleased]: https://github.com/godigi/hopwatch/compare/v1.0.1...HEAD' <<<"$out"
  grep -qF '[1.0.1]: https://github.com/godigi/hopwatch/releases/tag/v1.0.1' <<<"$out"
  grep -qF "[1.0.0]: https://github.com/godigi/hopwatch/commit/$sha" <<<"$out"
  grep -qF '[0.9.0]: https://github.com/godigi/hopwatch/commit/abc' <<<"$out"
  ! grep -q '/compare/v1.0.0\.\.\.v' <<<"$out"
}

@test "bump.py leaves the previous link alone when that tag is already gone" {
  local d out
  d="$(make_tagged_repo)"
  git -C "$d" tag -d v1.0.0 >/dev/null
  out="$(roll_links $'[Unreleased]: https://github.com/godigi/hopwatch/compare/v1.0.0...HEAD\n[1.0.0]: https://github.com/godigi/hopwatch/commit/abc' 1.0.1 1.0.0 "$d")"
  rm -rf "$d"
  grep -qF '[1.0.0]: https://github.com/godigi/hopwatch/commit/abc' <<<"$out"
  ! grep -qF 'compare/v1.0.0...v1.0.1' <<<"$out"
}

@test "every released version's section actually has notes" {
  while read -r v; do
    [ -n "$v" ] || continue
    run python3 "$SECTION" --file "$CHANGELOG" --version "$v"
    [ "$status" -eq 0 ] || { echo "empty or missing notes for $v"; return 1; }
  done <<< "$(released_versions)"
}

@test "every version the README credits a feature to actually exists" {
  # The README's Roadmap said the one-line installer shipped in v0.5.3.
  # There has never been a v0.5.3 — no tag, no CHANGELOG section — and the
  # installer actually landed in 0.6.0. A reader chasing that version finds
  # nothing, which is worse than an undated claim. Old tags are pruned, so
  # the check is against the versions the changelog and its archive
  # document, not against the tag list.
  local missing=""
  local v
  for v in $(grep -oE '\(v[0-9]+\.[0-9]+\.[0-9]+\)' "$REPO/README.md" \
             | tr -d '()' | sort -u); do
    grep -qhF "## [${v#v}]" "$CHANGELOG" "$ARCHIVE" || missing="$missing $v"
  done
  [ -z "$missing" ] || { echo "README credits versions that do not exist:$missing"; return 1; }
}

# ── The file and the CLI agree ───────────────────────────────────────────

@test "HOPWATCH_VERSION is documented in the CHANGELOG" {
  # A local build may be ahead of the last release tag. Keep its notes under
  # Unreleased, with an explicit version marker; once tagged, require its
  # own version section so the published release has retrievable notes.
  local cli
  cli="$(sed -n 's/^HOPWATCH_VERSION="\(.*\)"$/\1/p' "$REPO/bin/hopwatch" | head -1)"
  [ -n "$cli" ] || cli="$(sed -n 's/^NETDIAG_VERSION="\(.*\)"$/\1/p' "$REPO/bin/hopwatch" | head -1)"
  [ -n "$cli" ] || { echo "could not read HOPWATCH_VERSION from bin/hopwatch"; return 1; }
  run python3 "$SECTION" --file "$CHANGELOG" --version "$cli"
  [ "$status" -eq 0 ] && return 0
  [ -z "$(git -C "$REPO" tag -l "v$cli")" ] || {
    echo "tagged version $cli has no '## [$cli]' section"
    return 1
  }
  run python3 "$SECTION" --file "$CHANGELOG" --version Unreleased
  [[ "$output" == *"Local build version: $cli "* ]] || {
    echo "bin/hopwatch reports $cli, which has neither release notes nor an Unreleased local-build marker"
    return 1
  }
}
