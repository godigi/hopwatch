# Agent Guidelines & Workflow Rules

## Batched Development & Release Workflow
Every change that lands on `main` represents a released version that users can download. The repository is structured so that version bumping, CHANGELOG updates, release tagging, and distribution are automated, batched, and predictable.

### 1. Local Iteration & Unreleased Changes
- **Never bump the version on individual edits, bug fixes, or small tweaks.**
- Keep developing and testing locally on the current baseline without changing version numbers.
- As work is completed, document changes cleanly under `## [Unreleased]` in `CHANGELOG.md` using human-readable bullet points (e.g. under `### Fixed`, `### Added`, or `### Changed`).
- To test changes locally, build and install using `make install-gui` (which bundles, signs with a stable identity, and installs to `/Applications/Hopwatch.app`), and relaunch it (`open /Applications/Hopwatch.app`).

### 2. Batched Milestone Releases
- Releases batch multiple improvements and fixes together into cohesive, organized releases (e.g. 3–6 clear bullet points per release), rather than micro-bumping for single commits.
- Version bumps and public releases occur **only** when a milestone or cohesive batch of work is completed **and the user explicitly asks or confirms cutting a release**.
- Bump levels follow Semantic Versioning based on what's in the batch:
  - `fix:` / bug fixes and polish (patch bump, e.g. 1.20.1 → 1.20.2).
  - `feat:` / substantial new capabilities (minor bump, e.g. 1.20.1 → 1.21.0).
  - Breaking changes (`BREAKING CHANGE:` or `feat!:`) (major bump, e.g. 1.20.1 → 2.0.0).

### 3. Automated Version Bump & Release
- When the user confirms shipping a new release, run `make ship` (or `make ship-all` for full CLI+GUI test runs):
  1. Runs test verification (`make test-gui`).
  2. Runs `python3 scripts/bump.py`, which automatically:
     - Inspects unreleased commits or `--type` to determine the bump level (patch, minor, or major).
     - Updates version numbers in `bin/hopwatch`, `Casks/hopwatch.rb`, `VerifyMode.swift`, and `sample-output.json`.
     - Rolls `CHANGELOG.md`'s `[Unreleased]` section into the new version header with today's date and links.
     - Creates the `chore(release): bump version to X.Y.Z` commit and annotated git tag `vX.Y.Z`.
  3. Pushes the release commit and tags to `origin/main`. GitHub Actions (`.github/workflows/release.yml`) automatically publishes the GitHub Release with the bundled DMG and ZIP assets.
  4. Automatically runs `make install-gui` to bundle, sign, install to `/Applications/Hopwatch.app`, and relaunch the app.

### 4. Safety Net via Git Hooks
- Git hooks are maintained in `.githooks/` and active via `git config core.hooksPath .githooks`.
- If a standard `git push origin main` is run with unreleased commits, the `.githooks/pre-push` hook automatically intercepts it, runs `scripts/bump.py`, tags the release, and pushes the release commit and tags together.

### 5. Local Work vs. Remote Release Gate
- Development and testing are performed locally first. Changes are kept local until verified.
- **Never push to `main` or cut a new release without explicit confirmation from the user.**
