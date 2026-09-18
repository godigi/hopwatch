# Agent Guidelines & Workflow Rules

## Continuous Development & Release Workflow
Every change that lands on `main` represents a released version that users can download. The repository is structured so that version bumping, CHANGELOG updates, release tagging, and distribution are automated and predictable.

### 1. Committing Changes & Version Bumps
- Anytime small fixes, tweaks, or improvements are made locally, bump the version by a digit (patch bump, e.g. 1.4.0 → 1.4.1):
  - `fix:` for bug fixes and small adjustments (triggers a **patch** bump, e.g. 1.4.0 → 1.4.1).
  - `feat:` for substantial new features/capabilities (triggers a **minor** bump, e.g. 1.4.0 → 1.5.0).
  - Breaking changes (`BREAKING CHANGE:` or `feat!:`) trigger a **major** bump (e.g. 1.0.0 → 2.0.0).

### 2. Automated Version Bump & Release
- To ship changes, run `make ship` (or `make ship-all` for full CLI+GUI test runs):
  1. Runs test verification (`make test-gui`).
  2. Runs `python3 scripts/bump.py`, which automatically:
     - Inspects unreleased commits to determine the bump level (patch, minor, or major).
     - Updates version numbers in `bin/hopwatch`, `Casks/hopwatch.rb`, `VerifyMode.swift`, and `sample-output.json`.
     - Rolls `CHANGELOG.md` with today's date and commit notes.
     - Creates the `chore(release): bump version to X.Y.Z` commit and annotated git tag `vX.Y.Z`.
  3. Pushes the release commit and tags to `origin/main`. GitHub Actions (`.github/workflows/release.yml`) automatically publishes the GitHub Release with the bundled DMG and ZIP assets.
  4. Automatically runs `make install-gui` to bundle, sign, install to `/Applications/Hopwatch.app`, and relaunch the app.

### 3. Safety Net via Git Hooks
- Git hooks are maintained in `.githooks/` and active via `git config core.hooksPath .githooks`.
- If a standard `git push origin main` is run with unreleased commits, the `.githooks/pre-push` hook automatically intercepts it, runs `scripts/bump.py`, tags the release, and pushes the release commit and tags together.

### 4. Local Build, Versioning & Testing Rule
Whenever making changes locally that should be tested:
- Always bump the version by a digit so the version number is incremented.
- Immediately make/compile and install using `make install-gui` (which bundles, signs with stable identity, and installs to `/Applications/Hopwatch.app`), and relaunch it (`open /Applications/Hopwatch.app`) so that the local machine has that latest version ready to test.

### 5. Local Work vs. Remote Release Gate
- Development and testing are performed locally first. Changes are kept local until verified.
- Whenever significant work or a feature milestone is completed locally, **always explicitly ask the user** if they would like to commit, push to remote `main`, and make a new version release available to the public. Never push to `main` without asking/confirmation.
