# shellcheck shell=bash
# lib/browser.sh — detect desynchronized browser processes after background updates.
#
# When Chromium-based browsers (Google Chrome, Brave, Arc, Edge, Chromium)
# auto-update silently in the background on macOS, the updater replaces the
# bundle on disk and removes the previous framework version directory from
# `Contents/Frameworks/<Name> Framework.framework/Versions/<old_version>`.
#
# If the browser is still running, existing tabs continue to function in RAM,
# but any new tab or cross-site navigation attempts to spawn a new helper
# process from that removed directory. The spawn fails immediately (ENOENT)
# and displays an unhappy face ("Aw, Snap!"). Chrome's internal UpgradeDetector
# often hasn't shown an "Update" badge yet, leaving the user confused and
# suspecting network failure.
#
# Reads:  HELPERS_DIR
# Writes: BROWSER_DESYNC_COUNT, BROWSER_DESYNC_APP, BROWSER_DESYNC_RUNNING_VER,
#         BROWSER_DESYNC_DISK_VER, BROWSER_DESYNC_PID
# Entry:  browser_run
#
# Fast (ps/lsof, ~20ms). Parallel-safe.

browser_run() {
  BROWSER_DESYNC_COUNT=0
  BROWSER_DESYNC_APP=""
  BROWSER_DESYNC_RUNNING_VER=""
  BROWSER_DESYNC_DISK_VER=""
  BROWSER_DESYNC_PID=""

  local helper="${HELPERS_DIR:-helpers}/browser_check.py"
  if [ ! -f "$helper" ]; then
    return 0
  fi

  local out
  out="$(python3 "$helper" 2>/dev/null || true)"
  if [ -z "$out" ]; then
    return 0
  fi

  local status count app running_ver disk_ver pid
  IFS=$'\t' read -r status count app running_ver disk_ver pid <<< "$out"

  if [ "$status" = "DESYNC" ] && [ "${count:-0}" -gt 0 ]; then
    BROWSER_DESYNC_COUNT="$count"
    BROWSER_DESYNC_APP="$app"
    BROWSER_DESYNC_RUNNING_VER="$running_ver"
    BROWSER_DESYNC_DISK_VER="$disk_ver"
    BROWSER_DESYNC_PID="$pid"

    hdr "Browser health"
    warn "We detected that $BROWSER_DESYNC_APP (PID $BROWSER_DESYNC_PID) may not be working correctly right now. It updated in the background while open. Quit and reopen $BROWSER_DESYNC_APP to finish the update."
  fi

  if [ -n "${NETDIAG_PAR_VARS:-}" ]; then
    setvar BROWSER_DESYNC_COUNT "$BROWSER_DESYNC_COUNT"
    setvar BROWSER_DESYNC_APP "$BROWSER_DESYNC_APP"
    setvar BROWSER_DESYNC_RUNNING_VER "$BROWSER_DESYNC_RUNNING_VER"
    setvar BROWSER_DESYNC_DISK_VER "$BROWSER_DESYNC_DISK_VER"
    setvar BROWSER_DESYNC_PID "$BROWSER_DESYNC_PID"
  fi
}
