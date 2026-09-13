#!/usr/bin/env bash
# scripts/bump.sh — Convenience wrapper around scripts/bump.py
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$DIR/scripts/bump.py" "$@"
