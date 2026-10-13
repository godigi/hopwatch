# Changelog

All notable changes to Hopwatch are recorded here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versioning follows
[SemVer](https://semver.org/spec/v2.0.0.html).

Releases before 1.16.2 are archived in [docs/CHANGELOG-archive.md](docs/CHANGELOG-archive.md).

## [Unreleased]

## [1.17.1] - 2026-10-13

### Fixed

- **The "All good" banner is readable in dark mode.** The green status banner at the top of Home and the main window set its headline, sentence and "All systems nominal" pill in a fixed dark green that disappeared against the dark green background. They now use the app's own green and body-text colours, which adapt to the appearance, so the banner reads clearly in both light and dark mode. The README and `docs/SCREENSHOTS.md` images that show it are re-captured from synthetic data.
- **Old cache files no longer pile up.** Each version of the app saved its own copy of the rules catalog and the signal scale in its Application Support folder and never removed the older ones, so the folder grew by two files per release. The app now deletes every copy that belongs to another version and keeps only the current one. Nothing else in the folder is touched.
- **The changelog's version links no longer point at deleted tags.** Only the newest release and tag are kept, so the "compare" links under 1.17.0, 1.16.3 and 1.16.2 led to pages that no longer exist. Older versions now link to the commit that released them, and the release script keeps doing that for each version it supersedes instead of generating a link to a tag that is about to be removed.

## [1.17.0] - 2026-10-13

### Fixed

- **The offline card's remaining copy now comes from the CLI.** The monitor's `link.offline` gains `reason_label`, the short caption for the reason ("Wi-Fi is off" for `wifi-off`, "Not connected" for `wifi-not-joined` and `wifi-no-address`, `null` for the rest and for a wired link). The Mac node and the signal tile render it verbatim and fall back to the neutral "No link" wording when it is absent, instead of mapping reasons to text in Swift. The "Not connected" caption under the Mac node in the menu-bar card replaces the old "Wi-Fi · not connected" so one label serves both places.
- **Rule titles are no longer duplicated in Swift.** When the rules catalog has not loaded, the offline headline falls back to the neutral "No network connection" rather than a copy of the WJ-1 or WF-1 title (the WJ-1 copy had already drifted: "hasn't" against the catalog's "has not"). `NoLinkCopy.fallbackSubtitle`, the line shown under it, was a copy of the start of N1's text; it now only states what the app sees ("Hopwatch's connection monitor reports no active network link.").
- **The Reconnect Wi-Fi button on the offline card is driven by the rules catalog.** The card used to draw it for `WJ-1` or `DH-3`, a list kept in Swift. It now asks the catalog's per-rule `repairs` (decoded in the app from catalog schema 6) which firing rule offers `reconnect-wifi`, so the CLI decides which finding offers which repair here as in scans. Consequence: `WF-1` (Wi-Fi switched off), which the catalog and the scan already offer the repair for, now gets the button too; until the catalog has loaded the card shows only "Open Wi-Fi Settings". A new bats test ties the catalog's `repairs` to the `repair_offer` calls in `lib/`, so they cannot drift.
- **"Right before Wi-Fi dropped" is no longer said of a wired link.** `precursor_summary` is worded for the link that was lost: "Wi-Fi", "the wired connection", or "your connection" when the monitor does not know (a restarted monitor does not: the type is not in the carry record).
- **"Last on wired via 192.168.1.1" is gone.** A wired network's label describes a link, not a name, so `netid_label_is_name` now refuses it and `link.offline.last_network` is `null` for a wired network (the card says "Offline for X" alone). Wi-Fi names are unaffected.

## [1.16.3] - 2026-10-13

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

[Unreleased]: https://github.com/godigi/hopwatch/compare/v1.17.1...HEAD
[1.17.1]: https://github.com/godigi/hopwatch/releases/tag/v1.17.1
[1.17.0]: https://github.com/godigi/hopwatch/commit/685ef4f5e4695ff17a34c5b986f0c877165168fe
[1.16.3]: https://github.com/godigi/hopwatch/commit/7bf928d274434b04483d7a59f5f308785749d242
[1.16.2]: https://github.com/godigi/hopwatch/commit/23379af98d37b28f6b8aed9946c7b103b93dfe9f
