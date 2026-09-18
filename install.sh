#!/usr/bin/env bash
# install.sh — install hopwatch on macOS.
#
# Two supported entry points:
#
#   curl -fsSL https://raw.githubusercontent.com/godigi/hopwatch/main/install.sh | bash
#   git clone https://github.com/godigi/hopwatch.git && cd hopwatch && ./install.sh
#
# hopwatch is a bash program that loads lib/*.sh and helpers/*.py at runtime,
# so "installing" means putting a symlink on PATH that points at a checkout —
# there is no single-file build to copy. Piped from curl there is no checkout
# to point at, so this script fetches one into ~/.local/share/hopwatch and
# re-runs `git pull` there on every subsequent install. Run from inside a
# clone it uses that clone instead and never touches the network.
#
# Usage: install.sh [--prefix DIR] [--no-brew] [--uninstall]
#
# When piping, pass flags after `-s --`:
#   curl -fsSL <url> | bash -s -- --prefix ~/.local/bin
#
# Environment:
#   HOPWATCH_SRC  where to keep the checkout (default ~/.local/share/hopwatch)
#   HOPWATCH_REPO clone URL (default the public GitHub repo)
#   NETDIAG_SRC   legacy fallback for HOPWATCH_SRC

set -euo pipefail

REPO_URL="${HOPWATCH_REPO:-${NETDIAG_REPO:-https://github.com/godigi/hopwatch.git}}"
SRC_DIR="${HOPWATCH_SRC:-${NETDIAG_SRC:-$HOME/.local/share/hopwatch}}"
PREFIX=""
NO_BREW=0
UNINSTALL=0

die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*"; }

usage() {
  cat <<'HELP'
install.sh — install hopwatch on macOS.

Usage: install.sh [--app] [--prefix DIR] [--no-brew] [--uninstall]

  --app          install the native macOS Menu Bar App (Hopwatch.app) and CLI
  --prefix DIR   install the symlink here (default: /usr/local/bin when
                 writable, otherwise ~/bin, created if missing)
  --no-brew      skip the Homebrew bash 5 bootstrap
  --uninstall    remove symlinks; leaves checkout and log data alone

Environment:
  HOPWATCH_SRC   where to keep the checkout (default ~/.local/share/hopwatch)
  HOPWATCH_REPO  clone URL (default the public GitHub repo)

When piping from curl, pass flags after `-s --`:
  curl -fsSL <url> | bash -s -- --app
  curl -fsSL <url> | bash -s -- --prefix ~/.local/bin
HELP
}

while [ $# -gt 0 ]; do
  case "$1" in
    --app)
      SELF="${BASH_SOURCE[0]:-}"
      SELF_DIR=""
      if [ -n "$SELF" ] && [ -f "$SELF" ]; then
        SELF_DIR="$(cd "$(dirname "$SELF")" && pwd)"
      fi
      if [ -n "$SELF_DIR" ] && [ -f "$SELF_DIR/install-app.sh" ]; then
        exec "$SELF_DIR/install-app.sh"
      else
        exec curl -fsSL "https://raw.githubusercontent.com/godigi/hopwatch/main/install-app.sh" | bash
      fi
      ;;
    --prefix)
      # Guard before indexing $2 — under `set -u` a bare --prefix aborts
      # with "unbound variable" instead of a usable message.
      [ $# -ge 2 ] || die '--prefix expects a directory'
      PREFIX="$2"; shift 2 ;;
    --no-brew)   NO_BREW=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[ "$(uname -s)" = "Darwin" ] || die "hopwatch is macOS-only (this is $(uname -s))."

# ── Where is the source? ─────────────────────────────────────────────────
# Run as a file inside a checkout, BASH_SOURCE points at that checkout and
# we use it as-is. Piped into bash there is no file — BASH_SOURCE is "bash"
# or unset — so the -f test fails and we fetch a checkout instead.
SELF="${BASH_SOURCE[0]:-}"
SELF_DIR=""
if [ -n "$SELF" ] && [ -f "$SELF" ]; then
  SELF_DIR="$(cd "$(dirname "$SELF")" && pwd)"
fi

if [ -n "$SELF_DIR" ] && [ -x "$SELF_DIR/bin/hopwatch" ]; then
  SRC_DIR="$SELF_DIR"
elif [ "$UNINSTALL" -eq 0 ]; then
  command -v git >/dev/null 2>&1 \
    || die 'git is required to fetch hopwatch. Install the Xcode command line tools: xcode-select --install'
  if [ -d "$SRC_DIR/.git" ]; then
    note "updating existing checkout at $SRC_DIR"
    # --ff-only so a checkout the user has committed to is never rewritten.
    git -C "$SRC_DIR" pull --ff-only --quiet \
      || die "could not fast-forward $SRC_DIR — resolve it by hand, or remove it and re-run."
  else
    note "fetching hopwatch into $SRC_DIR"
    mkdir -p "$(dirname "$SRC_DIR")"
    git clone --quiet --depth 1 "$REPO_URL" "$SRC_DIR" \
      || die "could not clone $REPO_URL"
  fi
fi

# ── Install location ─────────────────────────────────────────────────────
if [ -z "$PREFIX" ]; then
  if [ -w /usr/local/bin ]; then
    PREFIX=/usr/local/bin
  else
    PREFIX="$HOME/bin"
  fi
fi
# Create the prefix for the install path, including an explicit --prefix:
# pointing at a directory that doesn't exist yet is an ordinary thing to
# do, and letting it through produced a bare "ln: No such file or
# directory" with no hint about which path was wrong.
if [ "$UNINSTALL" -eq 0 ] && [ ! -d "$PREFIX" ]; then
  mkdir -p "$PREFIX" 2>/dev/null \
    || die "cannot create $PREFIX — create it yourself, or pass a writable --prefix"
fi
[ "$UNINSTALL" -eq 1 ] || [ -w "$PREFIX" ] \
  || die "$PREFIX is not writable — pass --prefix with somewhere you own, e.g. --prefix ~/.local/bin"
DEST="$PREFIX/hopwatch"

if [ "$UNINSTALL" -eq 1 ]; then
  removed=0
  for d in "$DEST" "$PREFIX/netdiag"; do
    if [ -L "$d" ] || [ -f "$d" ]; then
      rm -f "$d"
      note "removed: $d"
      removed=1
    fi
  done
  if [ "$removed" -eq 1 ]; then
    note "the checkout and your reports in ~/hopwatch were left in place."
  else
    note "nothing to remove at $DEST"
  fi
  exit 0
fi

# ── bash 5 ───────────────────────────────────────────────────────────────
# macOS ships bash 3.2 (2007, GPLv2). hopwatch's startup check exits 3
# without a 5.x, so bootstrap it before the first run rather than letting
# the user hit that error.
have_bash5() {
  [ -x /opt/homebrew/bin/bash ] || [ -x /usr/local/bin/bash ]
}

if [ "$NO_BREW" -eq 0 ] && ! have_bash5; then
  if command -v brew >/dev/null 2>&1; then
    note 'installing Homebrew bash 5 (hopwatch runtime dependency)...'
    brew install bash
  else
    printf 'warning: bash 5+ not found and Homebrew not installed.\n' >&2
    printf '         hopwatch requires bash 5+. Install Homebrew from\n' >&2
    printf '         https://brew.sh, then: brew install bash\n' >&2
  fi
fi

# ── Link it ──────────────────────────────────────────────────────────────
SRC="$SRC_DIR/bin/hopwatch"
[ -x "$SRC" ] || die "$SRC is missing or not executable"

ln -sfn "$SRC" "$DEST"
note "installed: $DEST -> $SRC"

case ":$PATH:" in
  *":$PREFIX:"*) ;;
  *)
    note ""
    note "note: $PREFIX is not on your PATH. Add this to ~/.zshrc:"
    note "  export PATH=\"$PREFIX:\$PATH\""
    ;;
esac

note ""
note "run 'hopwatch' for a full check, or 'hopwatch --quick' for a fast one."
note ""
note "tip: to install the native macOS menu bar app (Hopwatch.app), run:"
note "  curl -fsSL https://raw.githubusercontent.com/godigi/hopwatch/main/install-app.sh | bash"
