## Description

<!-- Briefly describe the changes introduced in this PR and why they are needed. -->

## Type of Change

- [ ] `fix`: Bug fix (patch bump)
- [ ] `feat`: New feature or diagnostic rule (minor bump)
- [ ] `refactor`: Code quality / internal improvement (patch bump)
- [ ] `docs`: Documentation updates
- [ ] `test`: Test suite additions or improvements
- [ ] `chore`: Maintenance / tooling

## Checklist

- [ ] Commits follow [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`, `refactor:`, etc.)
- [ ] `shellcheck bin/hopwatch install.sh lib/*.sh` passes with 0 warnings
- [ ] `bats tests/` passes
- [ ] `make test-gui` passes (if GUI code was modified)
- [ ] Added tests for any new behavior or regression prevention
- [ ] Updated `docs/` and `README.md` if user-facing behavior changed
- [ ] Added an entry to `CHANGELOG.md` under `## [Unreleased]` (if applicable)
