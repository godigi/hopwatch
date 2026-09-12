#!/usr/bin/env bash
# install-app.sh — 1-line installer for Netdiag macOS Menu Bar App & CLI
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/godigi/netdiag/main/install-app.sh | bash
#
# What it does:
#   1. Fetches the latest signed Netdiag.dmg / Netdiag.zip from GitHub Releases
#   2. Installs Netdiag.app to /Applications (or ~/Applications if unprivileged)
#   3. Clears macOS Gatekeeper quarantine tags (no "unidentified developer" blockage)
#   4. Links the terminal CLI tool 'netdiag' to your PATH
#   5. Launches Netdiag in your menu bar

set -euo pipefail

REPO="godigi/netdiag"
API_URL="https://api.github.com/repos/${REPO}/releases/latest"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
cyan() { printf '\033[36m%s\033[0m\n' "$*"; }
die() { printf '\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "Netdiag is macOS-only (detected $(uname -s))."

# Check macOS version (minimum Sonoma 14.0)
OS_VER="$(sw_vers -productVersion | cut -d. -f1)"
if [ "$OS_VER" -lt 14 ]; then
  die "Netdiag requires macOS 14 Sonoma or newer (current: $(sw_vers -productVersion))."
fi

bold "⚡ Installing Netdiag for macOS..."

# Determine install destination
if [ -w "/Applications" ]; then
  APP_DIR="/Applications"
else
  APP_DIR="$HOME/Applications"
  mkdir -p "$APP_DIR"
fi
TARGET_APP="$APP_DIR/Netdiag.app"

TMP_DIR="$(mktemp -d -t netdiag-install-XXXXXX)"
cleanup() {
  if [ -n "${MOUNT_DIR:-}" ] && [ -d "$MOUNT_DIR" ]; then
    hdiutil detach "$MOUNT_DIR" -force -quiet 2>/dev/null || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# ── Query latest release from GitHub ─────────────────────────────────────
cyan "• Finding latest release..."
RELEASE_JSON=""
if command -v curl >/dev/null 2>&1; then
  RELEASE_JSON="$(curl -sSL -H "Accept: application/vnd.github+json" "$API_URL" 2>/dev/null || true)"
fi

DOWNLOAD_URL=""
ASSET_NAME=""

if [ -n "$RELEASE_JSON" ]; then
  # Parse installable asset URL from GitHub API
  DOWNLOAD_URL="$(printf '%s' "$RELEASE_JSON" | grep -E 'browser_download_url.*Netdiag.*(\.dmg|\.zip)' | head -1 | cut -d '"' -f 4 || true)"
  ASSET_NAME="$(basename "$DOWNLOAD_URL" 2>/dev/null || true)"
fi

# Fallback URL if GitHub API rate-limited
if [ -z "$DOWNLOAD_URL" ]; then
  DOWNLOAD_URL="https://github.com/${REPO}/releases/latest/download/Netdiag.dmg"
  ASSET_NAME="Netdiag.dmg"
fi

# ── Download asset ───────────────────────────────────────────────────────
ARCHIVE_PATH="$TMP_DIR/$ASSET_NAME"
cyan "• Downloading $ASSET_NAME..."
curl -fL --progress-bar "$DOWNLOAD_URL" -o "$ARCHIVE_PATH" \
  || die "Failed to download Netdiag from $DOWNLOAD_URL"

# ── Extract and install ──────────────────────────────────────────────────
cyan "• Installing to $TARGET_APP..."
EXTRACTED_APP=""

case "$ASSET_NAME" in
  *.dmg)
    MOUNT_DIR="$TMP_DIR/mount"
    mkdir -p "$MOUNT_DIR"
    hdiutil attach "$ARCHIVE_PATH" -mountpoint "$MOUNT_DIR" -nobrowse -quiet -noautoopen
    if [ -d "$MOUNT_DIR/Netdiag.app" ]; then
      EXTRACTED_APP="$MOUNT_DIR/Netdiag.app"
    fi
    ;;
  *.zip)
    EXTRACT_DIR="$TMP_DIR/extracted"
    mkdir -p "$EXTRACT_DIR"
    ditto -xk "$ARCHIVE_PATH" "$EXTRACT_DIR"
    if [ -d "$EXTRACT_DIR/Netdiag.app" ]; then
      EXTRACTED_APP="$EXTRACT_DIR/Netdiag.app"
    fi
    ;;
esac

[ -n "$EXTRACTED_APP" ] || die "Could not locate Netdiag.app in downloaded archive."

# Stop running instance if currently active
killall Netdiag 2>/dev/null || true
sleep 0.5

# Install app bundle
rm -rf "$TARGET_APP"
cp -R "$EXTRACTED_APP" "$TARGET_APP"

# Detach DMG if mounted
if [ -n "${MOUNT_DIR:-}" ]; then
  hdiutil detach "$MOUNT_DIR" -force -quiet 2>/dev/null || true
  MOUNT_DIR=""
fi

# ── Strip Gatekeeper quarantine ──────────────────────────────────────────
# Prevents "Netdiag cannot be opened because Apple cannot check it for malicious software"
xattr -cr "$TARGET_APP" 2>/dev/null || true

# ── CLI Symlink ──────────────────────────────────────────────────────────
CLI_BIN="$TARGET_APP/Contents/Resources/cli/bin/netdiag"
if [ -x "$CLI_BIN" ]; then
  CLI_DEST=""
  if [ -w "/usr/local/bin" ]; then
    CLI_DEST="/usr/local/bin/netdiag"
  elif [ -d "$HOME/bin" ] && [ -w "$HOME/bin" ]; then
    CLI_DEST="$HOME/bin/netdiag"
  elif [ -d "$HOME/.local/bin" ] && [ -w "$HOME/.local/bin" ]; then
    CLI_DEST="$HOME/.local/bin/netdiag"
  else
    mkdir -p "$HOME/bin"
    CLI_DEST="$HOME/bin/netdiag"
  fi

  ln -sfn "$CLI_BIN" "$CLI_DEST"
  cyan "• Linked CLI: $CLI_DEST -> $CLI_BIN"
fi

# ── Launch ───────────────────────────────────────────────────────────────
open "$TARGET_APP"

green "✔ Netdiag successfully installed to $TARGET_APP"
printf '\n'
bold "  Menu Bar:  Look for the ● indicator in your top macOS menu bar"
bold "  Terminal:  Run 'netdiag' or 'netdiag --quick' from any terminal"
printf '\n'
