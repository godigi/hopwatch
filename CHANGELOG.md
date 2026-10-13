# Changelog

All notable changes to Hopwatch are recorded here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versioning follows
[SemVer](https://semver.org/spec/v2.0.0.html).

Releases before 1.16.2 are archived in [docs/CHANGELOG-archive.md](docs/CHANGELOG-archive.md).

## [Unreleased]

### Changed

- **Documentation tidy-up.** The screenshots in the README and `docs/SCREENSHOTS.md` are re-captured from the current app using synthetic data (`scripts/gallery-fixture.py` regenerates the fixture they render), and `docs/CHANGELOG-archive.md` now holds the release notes for every version before 1.16.2. The reference docs say Hopwatch where they still said netdiag, the README's roadmap no longer cites versions that are no longer published, and `docs/BACKLOG.md` keeps only the ideas that are still open.
- **Sample output** (`examples/`) no longer shows a real DNS resolver address or a home-directory path.
- **Changelog tests follow the trimmed release history.** `tests/test_changelog.bats` requires a git tag only for the newest version, checks the README's version credits against the changelog and its archive, and runs its parser tests against the archive, since older tags are no longer kept.

## [1.16.2] - 2026-10-13

### Fixed

- **Tags cut by the auto-version bot now become Releases.** `auto-version.yml` pushes the release commit and tag with the default `GITHUB_TOKEN`, and GitHub does not start workflows from events that token creates, so `release.yml`'s tag trigger never fired: v1.15.1, v1.16.0 and v1.16.1 were tagged with no Release and no DMG, while `Casks/hopwatch.rb` pointed at the DMG that was never built (v1.16.1 was repaired by hand). The job now dispatches `release.yml` for the tag it just pushed (`workflow_dispatch` is allowed from `GITHUB_TOKEN`; it needs `actions: write` and no new secret). A tag pushed from a maintainer's machine still triggers the release by itself and is not dispatched twice.
- **A Release is built from its tag, not from whatever main holds when the job runs.** `release.yml` checked out the default branch, so a merge landing between the tag and the build made `gui/Makefile` name its artefacts from the wrong version. It now checks out the tag; only `CHANGELOG.md` and its reader still come from the default branch, so later corrections to old entries keep reaching the notes.
- **A rejected bot push can no longer leave an orphan tag.** The tag and `main` are pushed atomically and by name instead of with `--follow-tags`, and `auto-version` runs are serialised and start from the tip of `main`, so two merges in quick succession cannot both bump from the same tag.

<!-- Only versions that still have a GitHub Release are kept here; older
     history lives in docs/CHANGELOG-archive.md, which tests/test_changelog.bats
     does not read. -->

[Unreleased]: https://github.com/godigi/hopwatch/compare/v1.16.2...HEAD
[1.16.2]: https://github.com/godigi/hopwatch/compare/v1.16.1...v1.16.2
