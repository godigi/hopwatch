#!/usr/bin/env bash
# install-app.sh — 1-line installer for Hopwatch macOS Menu Bar App & CLI
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/godigi/hopwatch/main/install-app.sh | bash
#
# What it does:
#   1. Fetches the latest signed Hopwatch.dmg / Hopwatch.zip from GitHub Releases
#   2. Installs Hopwatch.app to /Applications (or ~/Applications if unprivileged)
#   3. Clears macOS Gatekeeper quarantine tags (no "unidentified developer" blockage)
#   4. Links the terminal CLI tool 'hopwatch' to your PATH
#   5. Launches Hopwatch in your menu bar

set -euo pipefail

REPO="godigi/hopwatch"
API_URL="https://api.github.com/repos/${REPO}/releases/latest"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
cyan() { printf '\033[36m%s\033[0m\n' "$*"; }
die() { printf '\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "Hopwatch is macOS-only (detected $(uname -s))."

# Check macOS version (minimum Sonoma 14.0)
OS_VER="$(sw_vers -productVersion | cut -d. -f1)"
if [ "$OS_VER" -lt 14 ]; then
  die "Hopwatch requires macOS 14 Sonoma or newer (current: $(sw_vers -productVersion))."
fi

bold "⚡ Installing Hopwatch for macOS..."

# Determine install destination
if [ -w "/Applications" ]; then
  APP_DIR="/Applications"
else
  APP_DIR="$HOME/Applications"
  mkdir -p "$APP_DIR"
fi
TARGET_APP="$APP_DIR/Hopwatch.app"

TMP_DIR="$(mktemp -d -t hopwatch-install-XXXXXX)"
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
  # Parse installable asset URL from GitHub API (preferring .zip for instant extraction, fallback to .dmg)
  DOWNLOAD_URL="$(printf '%s' "$RELEASE_JSON" | grep -E 'browser_download_url.*(Hopwatch|Netdiag).*\.zip' | head -1 | cut -d '"' -f 4 || true)"
  if [ -z "$DOWNLOAD_URL" ]; then
    DOWNLOAD_URL="$(printf '%s' "$RELEASE_JSON" | grep -E 'browser_download_url.*(Hopwatch|Netdiag).*\.dmg' | head -1 | cut -d '"' -f 4 || true)"
  fi
  ASSET_NAME="$(basename "$DOWNLOAD_URL" 2>/dev/null || true)"
fi

# If latest release had no attached assets, search recent releases
if [ -z "$DOWNLOAD_URL" ]; then
  ALL_RELEASES="$(curl -sSL -H "Accept: application/vnd.github+json" "https://api.github.com/repos/${REPO}/releases" 2>/dev/null || true)"
  DOWNLOAD_URL="$(printf '%s' "$ALL_RELEASES" | grep -E 'browser_download_url.*(Hopwatch|Netdiag).*\.zip' | head -1 | cut -d '"' -f 4 || true)"
  if [ -z "$DOWNLOAD_URL" ]; then
    DOWNLOAD_URL="$(printf '%s' "$ALL_RELEASES" | grep -E 'browser_download_url.*(Hopwatch|Netdiag).*\.dmg' | head -1 | cut -d '"' -f 4 || true)"
  fi
  ASSET_NAME="$(basename "$DOWNLOAD_URL" 2>/dev/null || true)"
fi

# Fallback URL if GitHub API rate-limited or unreachable
if [ -z "$DOWNLOAD_URL" ]; then
  DOWNLOAD_URL="https://github.com/${REPO}/releases/latest/download/Hopwatch.zip"
  ASSET_NAME="Hopwatch.zip"
fi

# ── Download asset ───────────────────────────────────────────────────────
ARCHIVE_PATH="$TMP_DIR/$ASSET_NAME"
cyan "• Downloading $ASSET_NAME..."
if ! curl -fL --progress-bar "$DOWNLOAD_URL" -o "$ARCHIVE_PATH"; then
  if [ "$ASSET_NAME" != "Hopwatch.dmg" ]; then
    cyan "• Retrying with DMG fallback..."
    DOWNLOAD_URL="https://github.com/${REPO}/releases/latest/download/Hopwatch.dmg"
    ASSET_NAME="Hopwatch.dmg"
    ARCHIVE_PATH="$TMP_DIR/$ASSET_NAME"
    curl -fL --progress-bar "$DOWNLOAD_URL" -o "$ARCHIVE_PATH" || die "Failed to download Hopwatch from $DOWNLOAD_URL"
  else
    die "Failed to download Hopwatch from $DOWNLOAD_URL"
  fi
fi

# ── Extract and install ──────────────────────────────────────────────────
cyan "• Installing to $TARGET_APP..."
EXTRACTED_APP=""

case "$ASSET_NAME" in
  *.dmg)
    MOUNT_DIR="$TMP_DIR/mount"
    mkdir -p "$MOUNT_DIR"
    hdiutil attach "$ARCHIVE_PATH" -mountpoint "$MOUNT_DIR" -nobrowse -quiet -noautoopen
    if [ -d "$MOUNT_DIR/Hopwatch.app" ]; then
      EXTRACTED_APP="$MOUNT_DIR/Hopwatch.app"
    elif [ -d "$MOUNT_DIR/Netdiag.app" ]; then
      EXTRACTED_APP="$MOUNT_DIR/Netdiag.app"
    fi
    ;;
  *.zip)
    EXTRACT_DIR="$TMP_DIR/extracted"
    mkdir -p "$EXTRACT_DIR"
    ditto -xk "$ARCHIVE_PATH" "$EXTRACT_DIR"
    if [ -d "$EXTRACT_DIR/Hopwatch.app" ]; then
      EXTRACTED_APP="$EXTRACT_DIR/Hopwatch.app"
    elif [ -d "$EXTRACT_DIR/Netdiag.app" ]; then
      EXTRACTED_APP="$EXTRACT_DIR/Netdiag.app"
    fi
    ;;
esac

[ -n "$EXTRACTED_APP" ] || die "Could not locate Hopwatch.app in downloaded archive."

# Stop running instances if currently active
killall Hopwatch 2>/dev/null || true
killall Netdiag 2>/dev/null || true
sleep 0.5

# Install app bundle (and remove old Netdiag.app)
rm -rf "$TARGET_APP"
rm -rf "$APP_DIR/Netdiag.app"
cp -R "$EXTRACTED_APP" "$TARGET_APP"

# Detach DMG if mounted
if [ -n "${MOUNT_DIR:-}" ]; then
  hdiutil detach "$MOUNT_DIR" -force -quiet 2>/dev/null || true
  MOUNT_DIR=""
fi

# ── Strip Gatekeeper quarantine ──────────────────────────────────────────
# Prevents "Hopwatch cannot be opened because Apple cannot check it for malicious software"
xattr -cr "$TARGET_APP" 2>/dev/null || true

# ── CLI Symlinks ─────────────────────────────────────────────────────────
CLI_DIR="$TARGET_APP/Contents/Resources/cli/bin"
BIN_DIR=""
if [ -w "/usr/local/bin" ]; then
  BIN_DIR="/usr/local/bin"
elif [ -d "$HOME/bin" ] && [ -w "$HOME/bin" ]; then
  BIN_DIR="$HOME/bin"
elif [ -d "$HOME/.local/bin" ] && [ -w "$HOME/.local/bin" ]; then
  BIN_DIR="$HOME/.local/bin"
else
  mkdir -p "$HOME/bin"
  BIN_DIR="$HOME/bin"
fi

if [ -n "$BIN_DIR" ]; then
  if [ -x "$CLI_DIR/hopwatch" ]; then
    ln -sfn "$CLI_DIR/hopwatch" "$BIN_DIR/hopwatch"
    cyan "• Linked CLI: $BIN_DIR/hopwatch -> $CLI_DIR/hopwatch"
  fi
fi

# ── Launch ───────────────────────────────────────────────────────────────
open "$TARGET_APP"

green "✔ Hopwatch successfully installed to $TARGET_APP"
printf '\n'
bold "  Menu Bar:  Look for the ● indicator in your top macOS menu bar"
bold "  Terminal:  Run 'hopwatch' or 'hopwatch --quick' from any terminal"
printf '\n'
