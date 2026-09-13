# Agent Guidelines & Workflow Rules

## Local Build & Testing Rule
Whenever making changes and committing/pushing code:
- Always rebuild and install the macOS app locally using `make install-gui` (which bundles, signs with stable identity, and installs to `/Applications/Netdiag.app`), and relaunch it (`open /Applications/Netdiag.app`) so that the user is continuously testing the latest built version.
