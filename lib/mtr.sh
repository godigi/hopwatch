# shellcheck shell=bash
# lib/mtr.sh — per-hop loss measurement. Prefers `mtr -j -c 60 -i 0.2`
# under sudo (60 cycles for continuous-loss view); falls back to a
# parallel 5-packet-per-hop loop when mtr/jq/sudo are unavailable.
#
# Reads:  QUICK, HOPS
# Writes: PER_HOP_LINES, MTR_FIRST_LOSSY_HOP
# Entry:  mtr_run

# Threshold above which a hop's loss% is "interesting" (vs measurement noise).
# It lives in thresholds.sh with the other judgement cutoffs so the parser
# and the report cannot drift apart.
_MTR_LOSS_THRESHOLD="$THRESH_MTR_HOP_LOSS_PCT"

# Classify a hop as "rate_limited" when its loss exceeds the threshold but
# at least one downstream hop is healthy — that means data is making it
# through, so the loss is the router refusing to send ICMP TTL-Exceeded
# replies fast enough, not a real forwarding failure. Real loss propagates
# to every hop past the bad one.
#
# An empty loss% means the hop was never measured (no ping summary came back).
# That is *unknown*, not 0% and not clean: awk reads "" as 0, so without the
# explicit checks below an unmeasured downstream hop counted as proof that
# traffic got through, and a real fault upstream of it was dismissed as
# "likely ICMP rate-limit".
#
# Args: $1 = current hop's loss%, $2... = downstream hops' loss%s.
# Echoes: "rate_limited" (lossy, but a measured downstream hop is clean),
#         "unknown" (this hop was not measured, or it is lossy and every
#         downstream hop was unmeasured so rate-limit cannot be told from
#         real loss), or an empty string (not lossy / real loss).
_classify_hop_loss() {
  local cur_loss="$1"; shift
  [ -n "$cur_loss" ] || { printf 'unknown'; return; }
  awk -v l="$cur_loss" -v t="$_MTR_LOSS_THRESHOLD" 'BEGIN{exit !(l+0 > t)}' \
    || { printf ''; return; }
  local d measured=0
  for d in "$@"; do
    [ -n "$d" ] || continue
    measured=1
    if awk -v l="$d" -v t="$_MTR_LOSS_THRESHOLD" 'BEGIN{exit !(l+0 <= t)}'; then
      printf 'rate_limited'
      return
    fi
  done
  # Downstream hops exist but none produced a number: no evidence either way.
  if [ "$#" -gt 0 ] && [ "$measured" -eq 0 ]; then
    printf 'unknown'
    return
  fi
  printf ''
}

# Walk the collected hop arrays (HOP_NUMS, HOP_IPS, HOP_LOSSES, HOP_AVGS),
# tag rate-limited hops, emit PER_HOP_LINES, print them in the right severity,
# and set MTR_FIRST_LOSSY_HOP only when loss is real (propagates downstream).
_emit_per_hop_results() {
  local n total status hop_line avg_disp
  total=${#HOP_NUMS[@]}
  for ((n=0; n<total; n++)); do
    status="$(_classify_hop_loss "${HOP_LOSSES[$n]}" "${HOP_LOSSES[@]:$((n+1))}")"
    PER_HOP_LINES+="${HOP_NUMS[$n]}|${HOP_IPS[$n]}|${HOP_LOSSES[$n]}|${HOP_AVGS[$n]}"$'\n'
    avg_disp="${HOP_AVGS[$n]:-?}"
    hop_line="$(printf 'hop %2d  %-15s  %5s%% loss  %7s ms' \
      "${HOP_NUMS[$n]}" "${HOP_IPS[$n]}" "${HOP_LOSSES[$n]:-?}" "$avg_disp")"
    if [ -z "${HOP_LOSSES[$n]}" ]; then
      # Never measured: say so rather than print a clean-looking row.
      info "$hop_line  (not measured)"
    elif awk -v l="${HOP_LOSSES[$n]}" -v t="$_MTR_LOSS_THRESHOLD" 'BEGIN{exit !(l+0 > t)}'; then
      if [ "$status" = "unknown" ]; then
        # Lossy, but nothing downstream was measured, so this cannot be told
        # from ICMP rate-limiting. Shown, but not named as the first lossy
        # hop: that feeds a diagnosis, and a guess should not.
        warn "$hop_line  (downstream hops not measured — cannot tell rate-limit from real loss)"
      elif [ "$status" = "rate_limited" ]; then
        # Downstream is healthy; this hop just deprioritises ICMP TTL replies.
        info "$hop_line  (likely ICMP rate-limit, downstream is clean)"
      else
        warn "$hop_line"
        [ -z "$MTR_FIRST_LOSSY_HOP" ] && \
          MTR_FIRST_LOSSY_HOP="hop ${HOP_NUMS[$n]} (${HOP_IPS[$n]})"
      fi
    else
      info "$hop_line"
    fi
  done
  [ -n "$MTR_FIRST_LOSSY_HOP" ] && warn "First lossy hop: $MTR_FIRST_LOSSY_HOP"
  return 0
}

_run_per_hop_fallback() {
  if [ "${#HOPS[@]}" -eq 0 ]; then
    info "No hops to test (traceroute returned no IPs)."
    return
  fi
  # Fire all hop pings concurrently to one temp file per hop, then collect in
  # original hop order. Bounded by the slowest hop (~1-2 s) rather than the
  # sum (~12 s for 8 hops).
  local hop_tmp i h out parsed loss lat
  netdiag_mktemp_dir netdiag-hops || { warn "MTR scratch directory unavailable — skipping hop loss."; return 0; }
  hop_tmp="$NETDIAG_TMP_DIR"
  i=0
  # Track each ping's PID so we wait only on our own children, not on
  # the progress-spinner the orchestrator may have forked.
  local ping_pids=()
  for h in "${HOPS[@]}"; do
    i=$((i+1))
    # macOS ping's -t is a deadline for the whole run, not a per-reply
    # timeout. The old flag could truncate this probe before five packets
    # were sent and turn a healthy hop into a fabricated loss reading.
    # -W bounds the wait for the last reply: without it macOS ping prints its
    # statistics ~10 s after the last packet, after this 4 s kill, so any
    # lost reply left the hop "unmeasured". See PING_REPLY_WAIT_MS.
    with_timeout 4 ping -c 5 -i 0.2 -W "$PING_REPLY_WAIT_MS" "$h" > "$hop_tmp/hop-$i" 2>&1 &
    ping_pids+=("$!")
  done
  local pid
  for pid in "${ping_pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
  HOP_NUMS=(); HOP_IPS=(); HOP_LOSSES=(); HOP_AVGS=()
  i=0
  for h in "${HOPS[@]}"; do
    i=$((i+1))
    out="$(cat "$hop_tmp/hop-$i" 2>/dev/null)"
    parsed="$(ping_parse_summary "$out")"
    IFS='|' read -r loss lat _ <<<"$parsed"
    HOP_NUMS+=("$i")
    HOP_IPS+=("$h")
    # No summary means the probe did not produce a measurement. Keep it
    # unknown instead of turning a command failure into 100% loss.
    HOP_LOSSES+=("${loss:-}")
    HOP_AVGS+=("${lat:-}")
  done
  rm -rf "$hop_tmp"
  netdiag_tmp_forget "$hop_tmp"
  _emit_per_hop_results
}

# Parse mtr's TSV (hopnum<TAB>host<TAB>loss%<TAB>avg) into the HOP_* arrays
# and emit. Designed to be called directly from tests with fixture data.
parse_mtr_tsv() {
  local hopnum host loss avg
  HOP_NUMS=(); HOP_IPS=(); HOP_LOSSES=(); HOP_AVGS=()
  while IFS=$'\t' read -r hopnum host loss avg; do
    [ -z "$hopnum" ] && continue
    HOP_NUMS+=("$hopnum")
    HOP_IPS+=("$host")
    HOP_LOSSES+=("$loss")
    HOP_AVGS+=("$avg")
  done
  _emit_per_hop_results
}

mtr_run() {
  [ "$QUICK" -eq 0 ] || { progress_skip "--quick"; return 0; }

  local -a mtr_cmd=()
  if command -v mtr >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    if mtr -c 1 127.0.0.1 >/dev/null 2>&1; then
      mtr_cmd=(mtr)
    elif hopwatch_sudo_allowed; then
      # mtr's raw sockets need root on some installs. Opt-in last resort
      # only, reached after the unprivileged probe above already failed.
      mtr_cmd=(sudo -n mtr)
    fi
  fi

  if [ "${#mtr_cmd[@]}" -gt 0 ]; then
    hdr "Continuous loss to 1.1.1.1 (mtr -j -c 60 -i 0.2)"
    local mtr_json mtr_tsv
    mtr_json="$(with_timeout 20 "${mtr_cmd[@]}" -j -c 60 -n -i 0.2 1.1.1.1 2>/dev/null || true)"
    printf '%s\n' "$mtr_json" >> "$LOG"
    if [ -z "$mtr_json" ] || ! printf '%s' "$mtr_json" | jq -e .report >/dev/null 2>&1; then
      warn "mtr returned no parseable report — falling back to per-hop loop."
      _run_per_hop_fallback
      return
    fi
    # TSV: hopnum, host, loss%, avg
    mtr_tsv="$(printf '%s' "$mtr_json" \
      | jq -r '.report.hubs[] | [.count, .host, (.["Loss%"]|tostring), (.Avg|tostring)] | @tsv')"
    parse_mtr_tsv <<<"$mtr_tsv"
    return
  fi

  hdr "Per-hop loss (5 packets each)"
  _run_per_hop_fallback
}
