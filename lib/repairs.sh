# shellcheck shell=bash
# lib/repairs.sh — the repair tier: "Fix it" actions a user starts by
# pressing a button, and the CLI that runs them.
#
# Design: docs/design/2026-10-07-repair-actions-design.md. This file is
# phase 1 — the three repairs that need no password (quit-app, restart-mac,
# open-sign-in).
#
# Three jobs, kept together because they must agree on one catalogue:
#
#   1. DESCRIBE a repair (repair_describe): the button label, the
#      confirmation the user reads before it runs, and what to try if the
#      re-check says it did not help. All prose is written here, for
#      readers who do not know what DNS or a socket is; the GUI renders it
#      verbatim.
#   2. OFFER a repair on a finding (repair_offer): lib/diagnosis.sh calls
#      this next to the add_diag it belongs to. The offers travel to the
#      --json output as each diagnosis's optional `repairs` array.
#   3. RUN a repair (repair_cli): `hopwatch --repair=ID`, with --dry-run to
#      print what would run and change nothing.
#
# What a repair may and may not do (CLAUDE.md, Permissions / Read-only):
#
#   * It runs only when something invoked `--repair`. Nothing in this file
#     is reachable from a scan, the monitor, a timer or an alert; the only
#     thing a scan does here is *describe* an offer. The one unattended
#     caller is the app's opt-in "Automatically reconnect Wi-Fi" (off unless
#     the user turns it on), which may invoke reconnect-wifi and nothing
#     else, on the monitor's say-so (status.auto_reconnect).
#   * No sudo, ever, in this phase. Nothing here changes DNS, routing or
#     ARP state; reconnect-wifi switches the Wi-Fi radio off and on, and
#     may rejoin a network macOS already remembers.
#   * Parameters are validated, never trusted, and never sanitised: a value
#     that does not match is refused and nothing runs. No value that came
#     from the network (a hostname, a DHCP string) is ever put on a command
#     line. Two parameters exist: an app's bundle id, which must match
#     ^[A-Za-z0-9.-]+$, and — for reconnect-wifi only — the name of the
#     Wi-Fi network to rejoin. That name is the one thing here that
#     originated on the network, so it is held to the narrowest rule that
#     still works: 1 to 32 bytes, no leading hyphen, no control
#     characters; it is passed to networksetup as a single argument, never
#     through a shell; and it is joined only if macOS already remembers a
#     network of exactly that name (see _repair_wifi_remembered).
#   * Nothing is ever SIGKILLed. quit-app asks the app to quit, the way
#     its own Quit menu item does.

# One record per offer, one per line, in REPAIR_OFFERS (globals.sh):
#   rule US id US label US confirm US admin US recheck US if_unfixed US params
# US is the ASCII unit separator, which no prose here contains. params is
# "key=value" pairs joined by RS. helpers/emit_json.py reads this back.
REPAIR_US=$'\x1f'
REPAIR_RS=$'\x1e'

# The page the captive-portal probe already fetches (lib/public.sh and
# lib/monitor.sh), so "open the sign-in page" and "detect the sign-in page"
# can never point at different places. Defined in lib/common.sh.

REPAIR_IDS="quit-app restart-mac open-sign-in reconnect-wifi"

repair_known() {
  case " $REPAIR_IDS " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# repair_describe ID [DISPLAY_NAME]
# Sets REPAIR_LABEL, REPAIR_CONFIRM, REPAIR_ADMIN, REPAIR_RECHECK and
# REPAIR_IF_UNFIXED. DISPLAY_NAME is what the user calls the app; it only
# ever appears in prose.
#
# REPAIR_RECHECK says whether a re-check right after the repair can tell
# the user anything: `now` when the repair's effect is immediate (an app
# closing), `later` when it is not — the user still has to sign in, or the
# Mac is about to restart — so a re-check would report "that didn't help"
# about a repair that has not finished happening.
repair_describe() {
  local id="$1" name="${2:-}"
  REPAIR_ADMIN=0
  REPAIR_RECHECK=now
  case "$id" in
    quit-app)
      [ -n "$name" ] || name="that app"
      REPAIR_LABEL="Quit ${name}"
      REPAIR_CONFIRM="${name} will be asked to close, the same as choosing Quit from its menu. If it has unsaved work it may ask you what to do first. Nothing else on your Mac is changed."
      REPAIR_IF_UNFIXED="Restart this Mac. Closing ${name} may not have been enough, or something else may be using up the connections. A restart clears all of them."
      ;;
    restart-mac)
      REPAIR_LABEL="Restart this Mac"
      REPAIR_CONFIRM="Your Mac will show its usual restart window with a countdown. It does not restart until the countdown ends, and you can cancel it there. Save your work first."
      REPAIR_RECHECK=later
      REPAIR_IF_UNFIXED="If this message is still here after the restart, the cause is probably not on this Mac. Run a full check and share the report when you ask for help."
      ;;
    open-sign-in)
      REPAIR_LABEL="Open the sign-in page"
      REPAIR_CONFIRM="Your web browser will open and show this network's sign-in or terms page. Nothing on your Mac is changed. Accept the terms or enter what it asks for, and the connection should start working."
      REPAIR_RECHECK=later
      REPAIR_IF_UNFIXED="If no sign-in page appears, forget this network in your Wi-Fi settings and join it again, or ask whoever runs the network."
      ;;
    reconnect-wifi)
      REPAIR_LABEL="Reconnect Wi-Fi"
      REPAIR_CONFIRM="Your Mac's Wi-Fi radio will be turned off and back on to prompt macOS to reconnect to your network. Nothing else on your Mac is changed."
      REPAIR_RECHECK=now
      REPAIR_IF_UNFIXED="Check that your Wi-Fi router is powered on, or open Wi-Fi settings to connect manually."
      ;;
    *) return 1 ;;
  esac
  return 0
}

# repair_offer RULE ID DISPLAY_NAME [KEY=VALUE ...]
# Record that finding RULE offers repair ID. Called from lib/diagnosis.sh
# immediately after the add_diag it belongs to. Records only; runs nothing.
repair_offer() {
  local rule="$1" id="$2" name="${3:-}" params="" kv
  shift $(( $# < 3 ? $# : 3 ))
  repair_describe "$id" "$name" || return 0
  for kv in "$@"; do
    params+="${params:+$REPAIR_RS}${kv}"
  done
  REPAIR_OFFERS+="${rule}${REPAIR_US}${id}${REPAIR_US}${REPAIR_LABEL}${REPAIR_US}${REPAIR_CONFIRM}${REPAIR_US}${REPAIR_ADMIN}${REPAIR_US}${REPAIR_RECHECK}${REPAIR_US}${REPAIR_IF_UNFIXED}${REPAIR_US}${params}"$'\n'
  return 0
}

# ── Parameters ───────────────────────────────────────────────────────────
# Parallel arrays, filled by repair_param_add from `--repair-param K=V`.
REPAIR_PARAM_KEYS=()
REPAIR_PARAM_VALS=()
REPAIR_ERR=""

# repair_param_get KEY — prints the value, or nothing.
repair_param_get() {
  local i
  for i in "${!REPAIR_PARAM_KEYS[@]}"; do
    if [ "${REPAIR_PARAM_KEYS[$i]}" = "$1" ]; then
      printf '%s' "${REPAIR_PARAM_VALS[$i]}"
      return 0
    fi
  done
  return 0
}

# repair_param_present KEY — whether the parameter was given at all, even
# as an empty value (an empty network name is refused, not ignored).
repair_param_present() {
  local i
  for i in "${!REPAIR_PARAM_KEYS[@]}"; do
    [ "${REPAIR_PARAM_KEYS[$i]}" = "$1" ] && return 0
  done
  return 1
}

# The longest an 802.11 network name can be, in bytes: a protocol limit, not
# a tuning choice, which is why it is not in lib/thresholds.sh.
REPAIR_NETWORK_MAX_BYTES=32

# repair_network_valid NAME — a Wi-Fi network name Hopwatch will pass to
# networksetup. 1 to 32 bytes (the longest an SSID can be), not starting
# with a hyphen (it would read as an option), and no control characters or
# line breaks. A name that fails is refused; nothing is stripped or
# truncated into one that passes.
repair_network_valid() {
  local LC_ALL=C v="$1"
  [ -n "$v" ] || return 1
  [ "${#v}" -le "$REPAIR_NETWORK_MAX_BYTES" ] || return 1
  case "$v" in -*) return 1 ;; esac
  [[ "$v" =~ [[:cntrl:]] ]] && return 1
  return 0
}

# repair_validate ID — checks the id and its parameters against what that
# repair accepts. Sets REPAIR_ERR and returns 1 on anything else. It
# rejects; it never repairs a value into an acceptable one.
repair_validate() {
  local id="$1" i key allowed
  REPAIR_ERR=""
  if ! repair_known "$id"; then
    REPAIR_ERR="unknown repair '${id}' (known: ${REPAIR_IDS})"
    return 1
  fi
  case "$id" in
    quit-app) allowed=" bundle_id " ;;
    reconnect-wifi) allowed=" network " ;;
    *)        allowed=" " ;;
  esac
  for i in "${!REPAIR_PARAM_KEYS[@]}"; do
    key="${REPAIR_PARAM_KEYS[$i]}"
    case "$allowed" in
      *" $key "*) ;;
      *) REPAIR_ERR="${id} does not take a parameter named '${key}'"; return 1 ;;
    esac
  done
  if [ "$id" = reconnect-wifi ] && repair_param_present network; then
    # Read from the array, not through $(...): command substitution would
    # strip a trailing line break and so let "Home\n" pass as "Home".
    local _ni _net=""
    for _ni in "${!REPAIR_PARAM_KEYS[@]}"; do
      if [ "${REPAIR_PARAM_KEYS[$_ni]}" = network ]; then
        _net="${REPAIR_PARAM_VALS[$_ni]}"
        break
      fi
    done
    if ! repair_network_valid "$_net"; then
      REPAIR_ERR="network must be 1 to 32 bytes, must not start with a hyphen, and must not contain control characters or line breaks"
      return 1
    fi
  fi
  if [ "$id" = quit-app ]; then
    local bid
    bid="$(repair_param_get bundle_id)"
    if [ -z "$bid" ]; then
      REPAIR_ERR="quit-app needs --repair-param bundle_id=<bundle id>"
      return 1
    fi
    if ! repair_bundle_id_valid "$bid"; then
      REPAIR_ERR="bundle_id must be letters, digits, dots and hyphens only, starting with a letter or digit"
      return 1
    fi
    if ! repair_bundle_quittable "$bid"; then
      REPAIR_ERR="${bid} is part of macOS or of Hopwatch itself and will not be quit by a repair"
      return 1
    fi
  fi
  return 0
}

# ── Mechanisms ───────────────────────────────────────────────────────────
# Each _repair_do_* fills REPAIR_RAN (the commands, as text), REPAIR_OK and
# REPAIR_MESSAGE. With REPAIR_DRY=1 it fills REPAIR_RAN with what *would*
# run and executes nothing at all.
REPAIR_RAN=()
REPAIR_OK=0
REPAIR_MESSAGE=""
REPAIR_DRY=0

# Single-quote a string for display in the `ran` list.
_repair_q() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

_repair_app_running() {
  [ -n "$(lsappinfo find "bundleid=$1" 2>/dev/null)" ]
}

_repair_app_name() {
  local n
  n="$(lsappinfo info -only name -app "$1" 2>/dev/null \
       | sed -n 's/^"LSDisplayName"="\(.*\)"$/\1/p' | head -1)"
  n="$(printf '%s' "$n" | tr -d '[:cntrl:]' | cut -c1-60)"
  printf '%s' "${n:-$1}"
}

_repair_do_quit_app() {
  local bid script check name err rc waited=0
  bid="$(repair_param_get bundle_id)"
  script="tell application id \"${bid}\" to quit"
  check="lsappinfo find bundleid=${bid}"
  if [ "$REPAIR_DRY" -eq 1 ]; then
    REPAIR_RAN=("$check" "osascript -e $(_repair_q "$script")")
    REPAIR_OK=1
    REPAIR_MESSAGE="Would ask ${bid} to quit. Nothing was changed."
    return 0
  fi
  # `tell application id` *launches* an app that is not running, only to
  # quit it again. Look first.
  REPAIR_RAN=("$check")
  if ! _repair_app_running "$bid"; then
    REPAIR_OK=1
    REPAIR_MESSAGE="That app is not running, so there is nothing to quit."
    return 0
  fi
  name="$(_repair_app_name "$bid")"
  REPAIR_RAN+=("osascript -e $(_repair_q "$script")")
  err="$(with_timeout 20 osascript -e "$script" 2>&1 >/dev/null)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    REPAIR_OK=0
    case "$err" in
      *-1743*|*"not allowed"*|*"Not authorized"*)
        REPAIR_MESSAGE="macOS did not let Hopwatch ask ${name} to quit. Allow it under System Settings > Privacy & Security > Automation, then try again, or quit ${name} yourself." ;;
      *)
        REPAIR_MESSAGE="${name} could not be asked to quit. Quit it yourself from its menu." ;;
    esac
    return 0
  fi
  # A quit request is a request: an app with unsaved work may put up a
  # window instead of closing. Give it a moment, then say which happened.
  while [ "$waited" -lt "${REPAIR_QUIT_WAIT_S:-5}" ]; do
    _repair_app_running "$bid" || break
    sleep 1
    waited=$((waited + 1))
  done
  if _repair_app_running "$bid"; then
    REPAIR_OK=0
    REPAIR_MESSAGE="${name} was asked to quit but is still open. It may be showing a window asking about unsaved work."
  else
    REPAIR_OK=1
    REPAIR_MESSAGE="${name} has quit."
  fi
  return 0
}

_repair_do_restart_mac() {
  local script rc
  # The standard macOS restart window: the one with a countdown that the
  # user can cancel. This is deliberately not `shutdown`, `reboot` or
  # System Events' `restart`, none of which show it.
  script='tell application "loginwindow" to «event aevtrrst»'
  REPAIR_RAN=("osascript -e $(_repair_q "$script")")
  if [ "$REPAIR_DRY" -eq 1 ]; then
    REPAIR_OK=1
    REPAIR_MESSAGE="Would show the standard macOS restart window. Nothing was changed."
    return 0
  fi
  with_timeout 15 osascript -e "$script" >/dev/null 2>&1
  rc=$?
  # 124: the dialog is still waiting on the user when the timeout lands.
  if [ "$rc" -eq 0 ] || [ "$rc" -eq 124 ]; then
    REPAIR_OK=1
    REPAIR_MESSAGE="Your Mac is showing its restart window. You can cancel it there."
  else
    REPAIR_OK=0
    REPAIR_MESSAGE="Hopwatch could not show the restart window. Restart from the Apple menu instead."
  fi
  return 0
}

_repair_do_open_sign_in() {
  REPAIR_RAN=("open ${CAPTIVE_CANARY_URL}")
  if [ "$REPAIR_DRY" -eq 1 ]; then
    REPAIR_OK=1
    REPAIR_MESSAGE="Would open ${CAPTIVE_CANARY_URL} in your browser. Nothing was changed."
    return 0
  fi
  # Launch macOS Captive Network Assistant if available so the system sign-in sheet can appear
  if [ -d "/System/Library/CoreServices/Captive Network Assistant.app" ]; then
    open -a "Captive Network Assistant" >/dev/null 2>&1 || true
  fi
  local target_url="${CAPTIVE_PORTAL_URL:-$CAPTIVE_CANARY_URL}"
  if open "$target_url" >/dev/null 2>&1 || open "$CAPTIVE_CANARY_URL" >/dev/null 2>&1; then
    REPAIR_OK=1
    REPAIR_MESSAGE="Opened the sign-in page in your browser. Hopwatch keeps watching and will notice when the network lets you through."
  else
    REPAIR_OK=0
    REPAIR_MESSAGE="Hopwatch could not open your browser. Open it yourself and load any plain http:// address."
  fi
  return 0
}

# Whether the Wi-Fi interface is associated with a network right now. The
# same test the monitor uses for "joined" (lib/monitor.sh, _mon_probe_offline):
# `networksetup -getairportnetwork` is not used because macOS withholds the
# network name from it without Location Services and answers "not associated"
# for a Mac that is.
_repair_wifi_associated() {
  ifconfig "$1" 2>/dev/null | grep -q 'status: active'
}

# Whether macOS remembers a network by exactly this name. A forced join is
# only ever to a network the user has joined before; a name that is not on
# the list is never typed into a join, whatever sent it.
_repair_wifi_remembered() {
  networksetup -listpreferredwirelessnetworks "$1" 2>/dev/null \
    | sed '1d; s/^[[:space:]]*//' | grep -Fxq -- "$2"
}

# One line of another program's output, safe to put in a message.
_repair_clean() {
  printf '%s' "$1" | head -n 1 | tr -d '[:cntrl:]' | cut -c1-120
}

_repair_do_reconnect_wifi() {
  local dev="" target_net=""
  if type wifi_primary_device >/dev/null 2>&1; then
    dev="$(wifi_primary_device)"
  fi
  [ -n "$dev" ] || dev="en0"
  target_net="$(repair_param_get network)"
  local settle="${REPAIR_WIFI_SETTLE_S:-$THRESH_REPAIR_WIFI_SETTLE_S}"
  local rejoin_wait="${REPAIR_WIFI_REJOIN_WAIT_S:-$THRESH_REPAIR_WIFI_REJOIN_WAIT_S}"
  local power_t="$THRESH_REPAIR_WIFI_POWER_TIMEOUT_S" join_t="$THRESH_REPAIR_WIFI_JOIN_TIMEOUT_S"
  local off_cmd="networksetup -setairportpower ${dev} off"
  local on_cmd="networksetup -setairportpower ${dev} on"
  if [ -n "$target_net" ]; then
    REPAIR_RAN=("$off_cmd" "$on_cmd" "networksetup -setairportnetwork ${dev} $(_repair_q "$target_net")")
  else
    REPAIR_RAN=("$off_cmd" "$on_cmd")
  fi
  if [ "$REPAIR_DRY" -eq 1 ]; then
    REPAIR_OK=1
    if [ -n "$target_net" ]; then
      REPAIR_MESSAGE="Would toggle Wi-Fi radio on ${dev} off and on and, if macOS has not rejoined a network by itself, join ${target_net}. Nothing was changed."
    else
      REPAIR_MESSAGE="Would toggle Wi-Fi radio on ${dev} off and on. Nothing was changed."
    fi
    return 0
  fi
  if ! with_timeout "$power_t" networksetup -setairportpower "$dev" off 2>/dev/null; then
    REPAIR_OK=0
    REPAIR_MESSAGE="Could not switch Wi-Fi off on ${dev}, so nothing was changed."
    return 0
  fi
  sleep "$settle"
  if ! with_timeout "$power_t" networksetup -setairportpower "$dev" on 2>/dev/null; then
    REPAIR_OK=0
    REPAIR_MESSAGE="Wi-Fi was switched off but could not be switched back on. Turn it on from the Wi-Fi menu in the menu bar."
    return 0
  fi

  # Give macOS the first go at rejoining: it knows the user's network
  # priorities, and a network it picked must not be overridden by ours.
  local waited=0
  while [ "$waited" -lt "$rejoin_wait" ] && ! _repair_wifi_associated "$dev"; do
    sleep 1
    waited=$((waited + 1))
  done
  if _repair_wifi_associated "$dev"; then
    REPAIR_OK=1
    REPAIR_MESSAGE="Wi-Fi was switched off and on, and macOS rejoined a network by itself."
    return 0
  fi
  if [ -z "$target_net" ]; then
    # Switching the radio is all this repair was asked to do, so that alone
    # counts as done; the message says plainly that nothing has joined yet.
    REPAIR_OK=1
    REPAIR_MESSAGE="Wi-Fi was switched off and on, but no network has been joined yet. macOS may still rejoin in a few seconds; if not, pick a network from the Wi-Fi menu."
    return 0
  fi

  # Asked to rejoin a named network and macOS did not. Only a remembered one.
  if ! _repair_wifi_remembered "$dev" "$target_net"; then
    REPAIR_OK=0
    REPAIR_MESSAGE="Wi-Fi was switched off and on, but \"${target_net}\" is not a network this Mac remembers, so Hopwatch did not try to join it. Pick a network from the Wi-Fi menu."
    return 0
  fi
  local out rc
  out="$(with_timeout "$join_t" networksetup -setairportnetwork "$dev" "$target_net" 2>&1)"
  rc=$?
  # networksetup reports a failed join on stdout and often still exits 0,
  # so the exit status alone proves nothing. A join counts only if the
  # status was clean, nothing was complained about, and the interface is
  # actually associated afterwards.
  if [ "$rc" -eq 124 ]; then
    REPAIR_OK=0
    REPAIR_MESSAGE="Wi-Fi was switched off and on, but joining \"${target_net}\" took longer than ${join_t} seconds and was stopped. macOS may still rejoin by itself; otherwise pick it from the Wi-Fi menu."
  elif [ "$rc" -ne 0 ] || [ -n "$out" ] || ! _repair_wifi_associated "$dev"; then
    REPAIR_OK=0
    REPAIR_MESSAGE="Wi-Fi was switched off and on, but joining \"${target_net}\" failed${out:+: $(_repair_clean "$out")}. macOS may still rejoin by itself; otherwise pick it from the Wi-Fi menu."
  else
    REPAIR_OK=1
    REPAIR_MESSAGE="Wi-Fi was switched off and on, and Hopwatch joined \"${target_net}\"."
  fi
  return 0
}

# ── The CLI ──────────────────────────────────────────────────────────────

# Where a repair that ran is recorded: the journal the recorder fills, and
# only if it already exists. A repair never creates a journal — a machine
# that has never run `--install-recorder` has no journal and keeps none.
repair_journal_path() {
  local p="${MONITOR_JOURNAL:-${LOG_DIR:-$HOME/hopwatch}/events.jsonl}"
  [ -f "$p" ] && printf '%s' "$p"
  return 0
}

# repair_cli ID DRY JSON — validate, run (or describe), print, journal.
# Exit status: 0 the repair did what it set out to; 1 it ran and did not;
# 3 a usage error (unknown id, bad parameter) with nothing run. 2 stays
# reserved for a diagnosis.
repair_cli() {
  local id="$1" dry="$2" json="$3" journal ran params i
  if ! repair_validate "$id"; then
    printf 'hopwatch: --repair: %s\n' "$REPAIR_ERR" >&2
    return 3
  fi
  REPAIR_DRY="$dry"
  REPAIR_RAN=(); REPAIR_OK=0; REPAIR_MESSAGE=""
  case "$id" in
    quit-app)       _repair_do_quit_app ;;
    restart-mac)    _repair_do_restart_mac ;;
    open-sign-in)   _repair_do_open_sign_in ;;
    reconnect-wifi) _repair_do_reconnect_wifi ;;
  esac
  ran=""
  for i in "${!REPAIR_RAN[@]}"; do ran+="${REPAIR_RAN[$i]}"$'\n'; done
  params=""
  for i in "${!REPAIR_PARAM_KEYS[@]}"; do
    params+="${params:+$REPAIR_RS}${REPAIR_PARAM_KEYS[$i]}=${REPAIR_PARAM_VALS[$i]}"
  done
  export NETDIAG_REPAIR_ID="$id" NETDIAG_REPAIR_OK="$REPAIR_OK" \
         NETDIAG_REPAIR_DRY="$dry" NETDIAG_REPAIR_RAN="$ran" \
         NETDIAG_REPAIR_MESSAGE="$REPAIR_MESSAGE" NETDIAG_REPAIR_PARAMS="$params"
  if [ "$json" -eq 1 ]; then
    python3 "$HELPERS_DIR/repair_emit.py" result || return 3
  else
    if [ "$dry" -eq 1 ]; then
      printf 'Dry run: %s\n' "$id"
      for i in "${!REPAIR_RAN[@]}"; do printf '  would run: %s\n' "${REPAIR_RAN[$i]}"; done
    fi
    printf '%s\n' "$REPAIR_MESSAGE"
  fi
  if [ "$dry" -eq 0 ]; then
    journal="$(repair_journal_path)"
    if [ -n "$journal" ]; then
      python3 "$HELPERS_DIR/repair_emit.py" journal "$journal" >/dev/null 2>&1 || true
    fi
  fi
  if [ "$REPAIR_OK" -eq 1 ]; then return 0; fi
  return 1
}
