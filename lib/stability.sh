# shellcheck shell=bash
# shellcheck disable=SC2034  # MON_* state is read by lib/monitor.sh, which sources this file
# lib/stability.sh — two-stage clearing for the monitor's rule verdicts.
#
# `_mon_rules` (lib/monitor.sh) is the INSTANTANEOUS judge: it names the
# rules whose confirmed conditions hold on this cycle. That is exactly
# right for onset — a warning must never be delayed — and exactly wrong for
# clearing: confirmation is asymmetric, N consecutive cycles to fire and
# ONE miss to clear. Measured on the live network (2026-10-06, one
# uninterrupted monitor, 69 samples over 9.5 min): LA-2 warned in five
# samples across three episodes of 1, 3 and 1 samples, the per-cycle
# internet jitter swinging 4–280 ms around a 30 ms cutoff. A warning that
# vanishes after four seconds is a warning nobody can act on, and a "good"
# verdict half a minute later is an answer to "is it safe to start a video
# call?" the link has not earned.
#
# This file sits between `_mon_rules` and the sample, and decides two
# things per warn/critical rule:
#
#   Stage 1 — still happening.  A fired rule stays fired until its
#     condition has been absent for THRESH_MON_CLEAR_HOLD_S of wall-clock
#     time. Time, not cycles: the cadence is a setting and a burst runs it
#     at 2 s, so "two clean cycles" means 4 s in one mode and 20 s in
#     another. The hold is measured from the LAST cycle the rule's own
#     condition held, so it needs no separate clean-cycle counter.
#
#   Stage 2 — recently unstable.  After the rule clears, the link is
#     "recovering" until THRESH_MON_UNSTABLE_WINDOW_S has passed since the
#     rule's condition last held. During it status.rules is empty but
#     status.stability names the rule, how long ago it last held and how
#     many separate times it came back inside the window; consumers render
#     that instead of a green all-clear. A re-fire during stage 2 is simply
#     stage 1 again, with the spike counted.
#
# Onset is untouched: the raw rule list is passed through as it is, so a
# rule fires on exactly the cycle it did before. Info rules (TCP-1, VPN-1,
# ICMP-1 …) describe the link rather than fault it and are neither held nor
# remembered. N1 (no link) is a fact, not a statistic: it clears the cycle
# the link returns — holding "no network" for 30 s while packets cross it
# would contradict every probe — but it IS remembered for stage 2, because
# a Wi-Fi drop thirty seconds ago is the opposite of a clean bill of health.
#
# State is all bash scalars named MON_STAB_<RULE>_<FIELD> (dashes in rule
# ids become underscores), built by eval from rule ids this repo defines —
# no user data reaches an eval. Scalars rather than associative arrays
# because the monitor must run under both bash and zsh, and `declare -A`
# means different things in each. The list loops are `${x%% *}` peeling
# for the same reason: zsh does not word-split an unquoted $var.
#
# Reads:  MON_RULES, MON_RAW_SEVS (set by _mon_rules / _mon_add_rule)
# Writes: MON_RULES, MON_SEVERITY, MON_DEGRADED (the held view),
#         MON_STAB_STATE (stable|unstable|recovering),
#         MON_STAB_RULES ("RULE:severity:active:ago_s:spikes …")

# Rules with state. Declared here, like every other piece of monitor
# state, because bin/hopwatch runs under `set -u`.
MON_STAB_KNOWN=""
MON_STAB_STATE="stable"
MON_STAB_RULES=""
MON_STAB_NETWORK=""
# "RULE:severity" for every rule _mon_rules fired this cycle, in firing
# order — the severity word _mon_add_rule saw, which MON_RULES alone loses.
MON_RAW_SEVS=""

# Rules whose clearing is NOT held: they report a present-tense fact (the
# link is down) rather than a statistical condition that flaps. Listed by
# id, not number, so this is not a cutoff.
_STAB_UNHELD=" N1 "

_STAB_K=""
_STAB_V=""
_STAB_FINAL="ok"

_stab_key() { _STAB_K="${1//-/_}"; }

# _stab_get K FIELD DEFAULT → _STAB_V
_stab_get() {
  eval "_STAB_V=\${MON_STAB_${1}_${2}:-\$3}"
}

# _stab_put K FIELD VALUE
_stab_put() {
  eval "MON_STAB_${1}_${2}=\$3"
}

# Fold one severity word into _STAB_FINAL with _mon_add_rule's precedence:
# critical beats warn beats info beats ok, and info never overwrites warn.
_stab_raise() {
  case "$1" in
    critical) _STAB_FINAL="critical" ;;
    warn)     [ "$_STAB_FINAL" = "critical" ] || _STAB_FINAL="warn" ;;
    info)     [ "$_STAB_FINAL" = "ok" ] && _STAB_FINAL="info" ;;
  esac
  return 0
}

# Forget everything — a different network is a different situation, and
# "recently unstable" at the hotel says nothing about the flat.
_mon_stability_reset() {
  local rest="$MON_STAB_KNOWN" rule
  while [ -n "$rest" ]; do
    rule="${rest%% *}"; rest="${rest#"$rule"}"; rest="${rest# }"
    _stab_key "$rule"
    _stab_put "$_STAB_K" HELD 0
    _stab_put "$_STAB_K" LAST ""
    _stab_put "$_STAB_K" SPIKES ""
    _stab_put "$_STAB_K" WASRAW 0
  done
  MON_STAB_KNOWN=""
  MON_STAB_STATE="stable"
  MON_STAB_RULES=""
  MON_LA2_LEG=""
  return 0
}

# Called each cycle with the current network id. An empty id (link down)
# is not a change; neither is the same id again.
_mon_stability_network() {
  local id="${1:-}"
  [ -n "$id" ] || return 0
  if [ -n "$MON_STAB_NETWORK" ] && [ "$id" != "$MON_STAB_NETWORK" ]; then
    _mon_stability_reset
  fi
  MON_STAB_NETWORK="$id"
  return 0
}

# _mon_stability_apply NOW — NOW is epoch seconds, passed in so the clock
# is the caller's and tests can drive it.
_mon_stability_apply() {
  local now="$1"
  local raw_rules=" $MON_RULES" rest entry rule sev k last held ago
  local final_rules="" spikes kept t count
  _STAB_FINAL="ok"

  # 1. Every rule this cycle's confirmed conditions named.
  rest="$MON_RAW_SEVS"
  while [ -n "$rest" ]; do
    entry="${rest%% *}"; rest="${rest#"$entry"}"; rest="${rest# }"
    rule="${entry%%:*}"; sev="${entry#*:}"
    final_rules+="$rule "
    _stab_raise "$sev"
    case "$sev" in warn|critical) ;; *) continue ;; esac
    _stab_key "$rule"; k="$_STAB_K"
    case " $MON_STAB_KNOWN " in *" $rule "*) ;; *) MON_STAB_KNOWN+="$rule " ;; esac
    _stab_get "$k" WASRAW 0
    if [ "$_STAB_V" != 1 ]; then
      # Rising edge of the rule's own condition: a new spike.
      _stab_get "$k" SPIKES ""
      _stab_put "$k" SPIKES "${_STAB_V:+$_STAB_V }$now"
    fi
    _stab_put "$k" WASRAW 1
    _stab_put "$k" LAST "$now"
    _stab_put "$k" SEV "$sev"
    _stab_put "$k" HELD 1
  done

  # 2. Every rule with state that this cycle did not name: still held,
  #    cleared (stage 2), or forgotten.
  local still_known=""
  rest="$MON_STAB_KNOWN"
  MON_STAB_RULES=""
  local any_active=0 any_recent=0
  while [ -n "$rest" ]; do
    rule="${rest%% *}"; rest="${rest#"$rule"}"; rest="${rest# }"
    _stab_key "$rule"; k="$_STAB_K"
    _stab_get "$k" LAST ""; last="$_STAB_V"
    _stab_get "$k" SEV warn; sev="$_STAB_V"
    case "$raw_rules" in
      *" $rule "*) held=1 ;;
      *)
        _stab_put "$k" WASRAW 0
        _stab_get "$k" HELD 0; held="$_STAB_V"
        if [ "$held" = 1 ]; then
          case "$_STAB_UNHELD" in
            *" $rule "*) held=0 ;;
            *) [ $((now - last)) -ge "$THRESH_MON_CLEAR_HOLD_S" ] && held=0 ;;
          esac
          _stab_put "$k" HELD "$held"
          if [ "$held" = 1 ]; then
            final_rules+="$rule "
            _stab_raise "$sev"
            [ "$rule" = "TCP-2" ] && [ -z "$MON_TCP2_STATE" ] && MON_TCP2_STATE="$sev"
          fi
        fi
        ;;
    esac
    ago=$((now - last))

    # Past the window and not held: nothing to say about it any more.
    if [ "$held" != 1 ] && [ "$ago" -ge "$THRESH_MON_UNSTABLE_WINDOW_S" ]; then
      _stab_put "$k" LAST ""
      _stab_put "$k" SPIKES ""
      continue
    fi
    still_known+="$rule "

    # Spikes inside the window (peeled the same zsh-safe way).
    _stab_get "$k" SPIKES ""; spikes="$_STAB_V"
    kept=""; count=0
    while [ -n "$spikes" ]; do
      t="${spikes%% *}"; spikes="${spikes#"$t"}"; spikes="${spikes# }"
      if [ $((now - t)) -lt "$THRESH_MON_UNSTABLE_WINDOW_S" ]; then
        kept+="${kept:+ }$t"; count=$((count + 1))
      fi
    done
    _stab_put "$k" SPIKES "$kept"

    if [ "$held" = 1 ]; then
      any_active=1
      MON_STAB_RULES+="${MON_STAB_RULES:+ }${rule}:${sev}:1:${ago}:${count}"
    else
      any_recent=1
      MON_STAB_RULES+="${MON_STAB_RULES:+ }${rule}:${sev}:0:${ago}:${count}"
    fi
  done
  MON_STAB_KNOWN="$still_known"

  if [ "$any_active" -eq 1 ]; then
    MON_STAB_STATE="unstable"
  elif [ "$any_recent" -eq 1 ]; then
    MON_STAB_STATE="recovering"
  else
    MON_STAB_STATE="stable"
  fi

  MON_RULES="$final_rules"
  MON_SEVERITY="$_STAB_FINAL"
  # Cadence follows the HELD severity: a rule still being held is a
  # problem still being watched, at the degraded cadence.
  case "$MON_SEVERITY" in
    warn|critical) MON_DEGRADED=1 ;;
    *)             MON_DEGRADED=0 ;;
  esac
  return 0
}
