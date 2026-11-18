# Contributing to Hopwatch

Thanks for looking. Hopwatch is a bash 5 CLI and Swift menu-bar app for macOS; getting set up for CLI development is a clone and a couple Homebrew packages.

```sh
git clone https://github.com/godigi/hopwatch.git
cd hopwatch
brew install shellcheck bats-core jq bash
./install.sh          # symlinks this clone onto your PATH
```

## Before opening a PR

Both of these run in CI, so it's cheaper to run them locally first:

```sh
shellcheck bin/hopwatch install.sh lib/*.sh   # must be clean at default severity
bats tests/                                  # must be green
make test-gui                                # GUI tests must pass
```

`# shellcheck disable=...` is allowed only with a comment saying why the
warning is a false positive.

## What a good change looks like

- **One logical change per PR.** Conventional-commit prefixes
  (`fix:`, `feat:`, `docs:`, `test:`, `refactor:`) in the subject.
- **A test for anything that could regress.** `tests/` is bats-core.
  Parser-level logic goes in `test_parse.bats` with a fixture under
  `tests/fixtures/`; anything that must never come back goes in
  `test_regressions.bats`. Tests must not need a working network —
  use fixtures, or probe loopback.
- **A CHANGELOG entry** under `## [Unreleased]`.
- **Samples come from real runs.** If you change output,
  regenerate `examples/sample-output.{txt,json}` with
  `./bin/hopwatch --redact` and `./bin/hopwatch --redact --json`. Don't
  hand-edit them: a sample that doesn't match reality is worse than none,
  and the README has been wrong that way before.

## The rule that matters most

**Never report a failed measurement as a finding about the user's
network.** Most bugs in this project have been that mistake: a probe
silently fails, its empty output is defaulted to a pessimistic number,
and the user is told their network is broken. If a check can't run,
record it as unknown and let the other evidence speak. `null` in JSON
means "did not run"; `[]` means "ran, found nothing". They are not
interchangeable.

Related: diagnoses are read by people who are already frustrated. Write
them in plain English, say what the user will actually experience, and
end with something they can do. See `docs/DIAGNOSIS-RULES.md` for the
format and the existing rules.

## Adding a diagnosis rule

1. Give it an ID (`XX-1`) and document it in `docs/DIAGNOSIS-RULES.md`
   with trigger, severity, evidence, recommendation, and rationale.
2. Emit it with `add_diag <severity> <ID> "<plain-English text>"`.
3. Add it to the README's rule list.
4. Test that it fires when it should **and stays quiet when it
   shouldn't** — the second half is where the false positives live.

Severity drives the exit code (`info` → 0, `warn` → 1, `critical` → 2),
so `critical` means "a wrapper should page someone".

## Releasing

Releases are cut from a tag; `.github/workflows/release.yml` publishes the
GitHub Release (CLI tarball, bundled macOS `.app` ZIP/DMG) and takes its notes
from `CHANGELOG.md`, so the notes and the file cannot disagree. Never write
release notes by hand in the GitHub UI — the workflow overwrites them from
the CHANGELOG on the next run.

1. **Automated release helper (`make ship`).** When `## [Unreleased]` is
   ready to ship on `main`, run `make ship` (or `make ship-all` to run both
   CLI and GUI test suites). It verifies the tests, runs
   `python3 scripts/bump.py` (which inspects commits/notes or `--type` to
   pick the SemVer bump, updates `bin/hopwatch`, `Casks/hopwatch.rb`,
   `CITATION.cff`, `gui/Sources/HopwatchGUI/VerifyMode.swift`, and
   `examples/sample-output.json`, rolls `## [Unreleased]` into
   `## [X.Y.Z] - YYYY-MM-DD`, updates the footer link refs, commits
   `chore(release): bump version to X.Y.Z`, and creates an annotated tag
   `vX.Y.Z`), pushes to `origin/main` with tags, and installs the updated app.
2. **Manual / step-by-step release:**
   - Run `python3 scripts/bump.py --type patch|minor|major` (or `--version X.Y.Z`),
     or roll `## [Unreleased]` in `CHANGELOG.md` and bump `HOPWATCH_VERSION` in
     `bin/hopwatch` cleanly together.
   - Run `bats tests/` and `make test-gui` — `tests/test_changelog.bats`
     checks CHANGELOG structure and version consistency.
   - Tag annotated (`git tag -a vX.Y.Z -m "vX.Y.Z — summary"`) and push
     `git push origin main --follow-tags`. (`.github/workflows/auto-version.yml`
     can also auto-bump commits pushed directly to `main`, and `.githooks/pre-push`
     safeguards local pushes when enabled via `git config core.hooksPath .githooks`.)
3. **Check the release workflow went green.** `.github/workflows/release.yml`
   verifies the tag, CLI version, and CHANGELOG agree, then publishes or
   updates the Release. If it fails, fix forward and re-run it from the
   Actions tab with `workflow_dispatch`.

Tags are annotated (`-a`), never lightweight: the tag message is the
one-line summary, and `git describe` depends on it.

## Layout

| Path | What's in it |
|------|--------------|
| `bin/hopwatch` | argument parsing and the run orchestrator |
| `lib/*.sh` | one module per check; `common.sh` has shared helpers |
| `helpers/*.py` | JSON emission, baseline math, summaries (stock `python3`) |
| `gui/` | native SwiftUI menu-bar app and dashboard (`Hopwatch.app`) |
| `tests/` | bats-core suites and fixtures |
| `docs/` | architecture, diagnosis rules, JSON schema |

`docs/ARCHITECTURE.md` explains the bash-vs-Python split and when a check
belongs in the parallel batch.

## Scope

macOS 14+ only for now. Checks should prefer macOS built-ins; Homebrew
tools (`mtr`, `gping`, `speedtest`, `jq`) may be used but must degrade to
a skip with a hint when missing, never a hard failure. Hopwatch is
read-only: it must never change routing, DNS, WiFi, or ARP state.

By contributing you agree your work is licensed under the [MIT
License](./LICENSE).
