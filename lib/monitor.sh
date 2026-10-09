# shellcheck shell=bash
# lib/monitor.sh — `netdiag --monitor`: a long-lived process that emits one
# compact JSON object per line on stdout, flushed per sample.
#
# This is the machine-readable sibling of --watch. --watch re-runs --quick
# on an interval and prints prose for a human watching a terminal;
# --monitor never prints prose, never writes a log, never touches
# baseline.jsonl, and emits a deliberately *smaller* shape than a full run
# (documented in docs/JSON-SCHEMA.md). The menu-bar app consumes it; a
# person would not enjoy reading it.
#
# Reads:  MONITOR_* interval flags set by bin/netdiag's argparse
# Entry:  monitor_run (loops until SIGINT/SIGTERM or stdout closes)
#
# ── Three cadence tiers ────────────────────────────────────────────────
# Probing everything on the fastest interval would be both rude to the
# network and pointless: a public-IP lookup answers a question that
# changes hourly, a gateway ping one that changes second to second.
#
#   fast   gateway ping, VPN state, link/SSID     10 s (5 s when degraded)
#   medium DNS resolve, TCP/443, RSSI/SNR         60 s
#   slow   public IP, ISP, ASN, country, portal   300 s + on network change
#
# The slow tier is the only one making an external call, so it is the only
# one where rate-limit politeness is at stake — hence 300 s, and hence the
# network-change trigger, because a changed public IP is the one thing
# worth knowing immediately after joining somewhere new.
#
# ── The monitor computes rules, not verdicts ───────────────────────────
# Each sample carries status.rules: the IDs from docs/DIAGNOSIS-RULES.md
# that *would* fire on this sample, evaluated here in bash against
# lib/thresholds.sh — the same constants lib/diagnosis.sh reads. The GUI
# renders that list and never re-derives a threshold. If the two ever
# disagree about what "lossy" means, the app contradicts the report it
# links to and the user has no way to tell which lied.
#
# ── Power is the GUI's problem, but pausing is ours ────────────────────
# The monitor stays dumb about sleep and battery: NSWorkspace delivers
# those events to the app for free, where bash would have to poll pmset.
# The app decides *when* to pause; this file implements *how*.
#
#   SIGUSR1  pause  — stop probing, keep the process alive
#   SIGUSR2  resume
#   SIGTERM / SIGINT  exit cleanly
#
# Pausing is a signal handler here rather than SIGSTOP from the caller,
# and that is not a stylistic choice — SIGSTOP is actively unsafe for this
# process. POSIX says that when a process group becomes newly orphaned and
# any member of it is stopped, the kernel delivers SIGHUP followed by
# SIGCONT to the whole group. A SIGSTOPped monitor still has children (the
# two-second gateway ping, the with_timeout killer subshells); the instant
# one of them exits, the group orphans, the SIGHUP lands, and the monitor
# dies. Measured: it survived about 2.1 s of every SIGSTOP under a GUI
# parent, exactly the length of one ping probe. It never happened under a
# shell, because a controlling terminal keeps the group non-orphaned —
# which is precisely why the bug would have shipped.
#
# Handling it in-process also makes the pause testable, and lets a paused
# monitor say so rather than going mysteriously silent.
#
# The one thing it manages by itself is a dead link: with no default route
# there is nothing to probe, so it stops probing and emits a minimal N1
# sample at the fast cadence. It deliberately does *not* exit — a stream
# that dies at the instant WiFi drops cannot report that WiFi dropped,
# which is the single event the app exists to announce.
#
# ── It exits when whoever started it goes away ─────────────────────────
# A stream exists for a consumer. If the consumer is gone there is nobody
# to stream to, and a network probe running forever with no reader is the
# single most likely reason an always-on tool gets uninstalled.
#
# The obvious mechanism — writing to a closed pipe and taking the EPIPE —
# is not sufficient on its own. Measured: SIGKILL the GUI and the monitor
# was still probing 30 s later, because a pipe fd survives in ways this
# process cannot audit. So the parent is checked explicitly each cycle.
#
# `kill -0` rather than re-reading $PPID: bash captures PPID once at
# startup and never updates it, so after re-parenting to launchd it still
# reports the pid of a process that no longer exists. `kill -0` is a
# builtin, costs nothing, and flips the moment the parent is reaped.

# The WiFi scrapes are shared with the scanner; one parser per upstream
# format means a macOS release that moves a label is fixed once.
# shellcheck source=lib/wifi_common.sh
. "$(dirname "${BASH_SOURCE[0]}")/wifi_common.sh"

# ── Sample state ─────────────────────────────────────────────────────────
# All MON_* — a distinct namespace from the scanner's globals so that
# sourcing both (as bin/netdiag does) can't have one silently read the
# other's value.
MON_SEQ=0
MON_INTERFACE=""
MON_IFACE_TYPE=""
MON_LINK_UP=0
MON_GATEWAY=""
MON_GW_MAC=""
# What the network id is built from: this cycle's gateway MAC, SSID and
# interface type when it read them, otherwise those of the last cycle that
# read a MAC on this same network. Kept apart from MON_GW_MAC / MON_SSID /
# MON_IFACE_TYPE, which report what this cycle's probes actually returned.
MON_ID_GW_MAC=""
MON_ID_SSID=""
MON_ID_IFACE_TYPE=""
# What the last successful ARP lookup learned, and where and when, for
# _mon_hold_gw_mac. KNOWN_AT is wall-clock seconds, so a Mac that slept
# ages it by the sleep.
MON_KNOWN_GW_MAC=""
MON_KNOWN_GW=""
MON_KNOWN_IFACE=""
MON_KNOWN_SSID=""
MON_KNOWN_IFACE_TYPE=""
MON_KNOWN_AT=0
MON_SSID=""
MON_BSSID=""
MON_LOCAL_IP=""
MON_NETWORK_ID=""
MON_NETWORK_LABEL=""
MON_NETWORK_GROUP=""
MON_VPN_ACTIVE=0
MON_VPN_TYPE=""
MON_VPN_NAME=""
MON_GW_LOSS=""
MON_GW_RTT=""
# How many consecutive cycles the warn-band loss condition has held for
# each leg — gateway and internet — used to confirm G3/L2 before either
# fires (see THRESH_MON_LOSS_CONFIRM_CYCLES in lib/thresholds.sh). Declared
# here, not just assigned inside _mon_rules, because bin/netdiag runs under
# `set -u` and the very first cycle reads them before ever writing them.
MON_GW_LOSS_STREAK=0
MON_INET_LOSS_STREAK=0
# CONN-1 / D1 confirmation (THRESH_MON_CONN_CONFIRM_CYCLES). Unlike the loss
# streaks these count *medium-tier* samples — DNS and TCP are only probed
# there — so they advance only on a cycle that took one (MON_MEDIUM_FRESH),
# and hold their value across the fast cycles between. Declared here for the
# same `set -u` reason as the loss streaks.
#   MON_CONN_STREAK   consecutive samples in which any new-connection probe
#                     (the DNS lookup or a TCP/443 connect) failed
#   MON_CONN_SAW_*    what failed somewhere in that streak: a lookup, a
#                     connect, or two resolvers on the same sample
#   MON_CONN_CLEAN    consecutive samples in which nothing failed
#   MON_CONN_ACTIVE   CONN-1 is confirmed; held until MON_CONN_CLEAN confirms
#                     recovery, so an intermittent fault does not flash
#   MON_DNS_STREAK    consecutive samples in which the lookup alone failed
#   MON_CONN_PENDING  a failure is waiting for its confirmation; the main
#                     loop re-probes at the fast cadence instead of waiting
#                     out the 60 s medium tier
MON_CONN_STREAK=0
MON_CONN_SAW_DNS=0
MON_CONN_SAW_TCP=0
MON_CONN_SAW_PAIR=0
MON_CONN_CLEAN=0
MON_CONN_ACTIVE=0
MON_DNS_STREAK=0
MON_CONN_PENDING=0
MON_MEDIUM_FRESH=1
# HOG-1 (THRESH_MON_HOG_CONFIRM_CYCLES, THRESH_MON_HOG_RECHECK_S). Unlike the
# CONN-1 streaks these count fast-tier cycles, because latency is measured
# there, and the capture they gate costs ~7 s.
#   MON_HOG_STREAK        consecutive cycles with latency degraded, ping clean
#   MON_HOG_CLEAN         consecutive cycles without
#   MON_HOG_ACTIVE        a capture found one app using up the connection;
#                         withdrawn by a capture that does not, or by
#                         MON_HOG_CLEAN reaching the confirmation count
#   MON_HOG_LAST_CAPTURE  EPOCHSECONDS of the last capture, so a gate that
#                         stays open costs one capture per recheck interval
MON_HOG_STREAK=0
MON_HOG_CLEAN=0
MON_HOG_ACTIVE=0
MON_HOG_LAST_CAPTURE=0
MON_HOG_REFRESHED=0
MON_HOG_OBSERVED_AT=""
MON_HOG_APP_NAME="" MON_HOG_APP_BUNDLE="" MON_HOG_PROC=""
MON_HOG_DIR="" MON_HOG_RATE="" MON_HOG_DOM_PCT=""
MON_HOG_GW_RTT="" MON_HOG_GW_JITTER="" MON_HOG_INET_JITTER=""
# Rolling loss windows, one per leg: newest-last "sent:lost" pairs, one per
# completed probe, trimmed to MONITOR_LOSS_WINDOW_PROBES entries. Plain
# space-separated scalars rather than arrays — this file must run under
# zsh AND bash, and array syntax (and even subscript origin) differs
# between them. The reported MON_GW_LOSS / MON_INET_LOSS are computed over
# the whole window, which is what makes the percentage a property of the
# link rather than of one burst; see _mon_loss_summarize.
MON_GW_HIST=""
MON_INET_HIST=""
MON_INET_HIST_ALT=""
MON_INET_LOSS_ALT=""
MON_WIFI_RSSI=""
MON_WIFI_NOISE=""
MON_WIFI_SNR=""
MON_WIFI_CHAN=""
MON_DNS_OK=""
# The same question put to a second, unrelated resolver, asked only after the
# first went unanswered (rule CONN-1). "" = not asked.
MON_DNS_ALT_OK=""
MON_DNS_RESOLVER=""
MON_DNS_MS=""
# Whether this Mac could send a DNS question at all (rule SOCK-1). "" = the
# probe has not run, 0 = it ran and a UDP socket was available, 1 = the
# kernel refused one. The evidence alongside is captured only on a fault,
# because that is when a reboot is about to erase it.
MON_DNS_LOCAL_FAIL=""
MON_DNS_LOCAL_BIND=""
MON_DNS_UDP_SOCKETS=""
MON_DNS_UDP_HOLDERS=""
MON_DNS_UDP_TOP_SHARE_PCT=""
MON_DNS_TCP_DNS_OK=""
MON_TCP_OK=""
MON_TCP_LINES=""
# A small HTTPS reachability probe runs with the fast tier. It answers the
# question users actually care about — whether ordinary internet traffic can
# leave the Mac — rather than treating Wi-Fi association or ICMP replies as
# proof that websites will load.
MON_WEB_OK=""
MON_PUB_IP=""
MON_PUB_ISP=""
MON_PUB_ASN=""
MON_PUB_CC=""
MON_PUB_CC_ISO=""
MON_PUB_CITY=""
MON_PUBLIC_OK=""
MON_CAPTIVE=""
MON_RULES=""
MON_CLEARABLE_RULES=""
MON_BROWSER_CHECKED=0
MON_SEVERITY="ok"
# `ok` severity means no diagnosis rule fired. It does not mean the probes
# succeeded; keep measurement availability separate so the GUI can avoid a
# green "all good" card when the link could not be tested.
MON_MEASUREMENT_STATE="unknown"
MON_ICMP_FILTERED=0
MON_DEGRADED=0
MON_REFRESHED=""
MON_STOP=0
MON_PAUSED=0
MON_REFRESH_REQUESTED=0
MON_HW_PORTS=""
# launchd's pid. Named rather than written as a bare 1 so the orphan check
# below reads as the sentinel it is, and so tests/test_thresholds.bats's
# "no inline cutoff" guard stays a useful signal instead of something this
# file has to be excused from.
MON_INIT_PID=1

# Previous-sample identity, for the schema-2 changes array. Snapshotted
# by _mon_snapshot_prev after every successful emit; MON_HAVE_PREV=0
# suppresses a spurious "everything changed" on the first sample.
MON_HAVE_PREV=0
MON_PREV_PUB_IP=""
MON_PREV_PUB_CC=""
MON_PREV_PUB_ISP=""
MON_PREV_VPN_ACTIVE=""
MON_PREV_VPN_NAME=""
MON_PREV_SSID=""
MON_PREV_BSSID=""
# The wall-clock second the previous cycle began, and the cadence it was
# scheduled at — the two inputs _mon_gap_seconds compares.
MON_PREV_CYCLE_TS=""
MON_PREV_CADENCE=""
MON_GAP_S=""
MON_PREV_INTERFACE=""
MON_PREV_RULES=""

# ── Fast tier ────────────────────────────────────────────────────────────

# One `route -n get default` for both fields: it is a syscall to the
# routing table, but two of them per sample forever adds up and they can
# disagree if the route changes between the calls.
_mon_probe_link() {
  local route_out
  route_out="$(route -n get default 2>/dev/null || true)"
  MON_INTERFACE="$(printf '%s\n' "$route_out" | awk '/interface:/{print $2; exit}')"
  MON_GATEWAY="$(printf '%s\n' "$route_out"  | awk '/gateway:/{print $2; exit}')"
  if [ -n "$MON_INTERFACE" ] && [ -n "$MON_GATEWAY" ]; then
    MON_LINK_UP=1
  else
    MON_LINK_UP=0
  fi
  MON_LOCAL_IP=""
  [ -n "$MON_INTERFACE" ] && MON_LOCAL_IP="$(ipconfig getifaddr "$MON_INTERFACE" 2>/dev/null || true)"

  # Hardware-port list is static for the life of the machine, so read it
  # once. networksetup is ~100 ms — affordable at startup, not every 10 s.
  if [ -z "$MON_HW_PORTS" ]; then
    MON_HW_PORTS="$(networksetup -listallhardwareports 2>/dev/null || true)"
  fi
  # No interface means no way to ask what kind it is. "wired" is a claim
  # about a port we looked at, not a default: with the route withdrawn it
  # read as "wired" and the app showed "Ethernet" for a dropped Wi-Fi link.
  # Left empty here; _mon_hold_gw_mac below may fill it from the held
  # identity, and otherwise it is emitted as null.
  MON_IFACE_TYPE=""
  MON_SSID=""; MON_BSSID=""
  if [ -n "$MON_INTERFACE" ]; then
    MON_IFACE_TYPE="wired"
    local hw_port ssid bssid
    hw_port="$(wifi_hw_port_for_device "$MON_INTERFACE" "$MON_HW_PORTS")"
    if wifi_port_is_wireless "$hw_port"; then
      MON_IFACE_TYPE="wifi"
      local summary
      summary="$(ipconfig getsummary "$MON_INTERFACE" 2>/dev/null || true)"
      {
        IFS=$'\t' read -r ssid bssid _
      } <<<"$(wifi_parse_ipconfig_summary "$summary")"
      MON_SSID="$ssid"
      MON_BSSID="$bssid"
      # Deliberately NOT falling back to NETDIAG_SSID_HINT the way
      # lib/wifi.sh does. The hint is captured once, by the calling app,
      # at spawn time — fresh for a scan that lasts seconds, stale for a
      # monitor that lives as long as the app does. Adopting it here would
      # label every future network with the name of the one the user
      # happened to be on when the monitor started, and that name feeds
      # netid_run below, so the *identity* would be wrong and not just the
      # caption. A generic label is the better failure.
    fi
  fi

  # Gateway MAC from the ARP cache — a local table read, no packets. This
  # is the strongest identity a network has and the thing "you're not on
  # the network you think you are" keys off.
  MON_GW_MAC=""
  if [ -n "$MON_GATEWAY" ]; then
    MON_GW_MAC="$(arp -n "$MON_GATEWAY" 2>/dev/null \
      | awk '/ at /{ if ($4 != "(incomplete)") print $4; exit }')"
  fi
  _mon_hold_gw_mac "$EPOCHSECONDS"
  # What the network id was built from is also the best answer to "what kind
  # of link was this" when there is no interface to ask: the held type, or
  # empty (null in the sample) when none is held. Never invented.
  [ -n "$MON_INTERFACE" ] || MON_IFACE_TYPE="$MON_ID_IFACE_TYPE"
  _mon_identity
}

# Which gateway MAC the network id is built from: this cycle's, or — when the
# lookup came back empty — the one last read on the same network.
#
# The id is derived afresh every cycle, and the two things it is derived from
# go quiet exactly when a router is struggling: the default route is withdrawn
# while Wi-Fi re-associates (no gateway, so no ARP lookup, so no id at all),
# and the gateway's ARP entry is gone until the next reply repopulates it (so
# the id falls back to the bare gateway address). Measured on a real journal,
# those two accounted for 230 of its 235 id changes, 210 of them inside one
# monitor process. The journal and the app key every fault on the id, so each
# flip cut one fault in two. A lookup that fails is absence of evidence, not
# evidence of a different network.
#
# So the MAC is held, but only while nothing contradicts it:
#   - a MAC read this cycle replaces it outright;
#   - a different gateway address, interface, or visible SSID ends it for good
#     (an unreadable SSID is not a different one — macOS hides it without
#     Location Services, which is the usual case here);
#   - and it expires THRESH_MON_IDENTITY_HOLD_S after the last MAC read, which
#     is also what makes a Mac that slept and woke elsewhere start fresh.
# What this does not do is prove the network is the same. Two networks that
# both use 192.168.1.1, joined within the hold with the new router's ARP entry
# still empty, are the same network for as long as that takes the first reply
# to land — one fast cycle — and then the MAC read corrects it.
#
# $1 is the clock, an argument so tests need not wait out the hold.
_mon_hold_gw_mac() {
  local now="$1"
  MON_ID_GW_MAC="$MON_GW_MAC"
  MON_ID_SSID="$MON_SSID"
  MON_ID_IFACE_TYPE="$MON_IFACE_TYPE"
  if [ -n "$MON_GW_MAC" ]; then
    MON_KNOWN_GW_MAC="$MON_GW_MAC"
    MON_KNOWN_GW="$MON_GATEWAY"
    MON_KNOWN_IFACE="$MON_INTERFACE"
    MON_KNOWN_SSID="$MON_SSID"
    MON_KNOWN_IFACE_TYPE="$MON_IFACE_TYPE"
    MON_KNOWN_AT="$now"
    return 0
  fi
  [ -n "$MON_KNOWN_GW_MAC" ] || return 0

  if [ $((now - MON_KNOWN_AT)) -gt "$THRESH_MON_IDENTITY_HOLD_S" ] \
    || { [ -n "$MON_GATEWAY" ]   && [ "$MON_GATEWAY"   != "$MON_KNOWN_GW" ]; } \
    || { [ -n "$MON_INTERFACE" ] && [ "$MON_INTERFACE" != "$MON_KNOWN_IFACE" ]; } \
    || { [ -n "$MON_SSID" ] && [ -n "$MON_KNOWN_SSID" ] \
         && [ "$MON_SSID" != "$MON_KNOWN_SSID" ]; }; then
    MON_KNOWN_GW_MAC=""
    return 0
  fi
  MON_ID_GW_MAC="$MON_KNOWN_GW_MAC"
  # The interface type and SSID are read through the same route, so they go
  # missing with it: a withdrawn route reads as "wired" (there is no
  # interface to ask), which would turn `wifi:mac=…` into `lan:mac=…`.
  # Hold the type whenever there is no interface to read it from; hold the
  # SSID whenever it comes back unreadable.
  [ -z "$MON_INTERFACE" ] && MON_ID_IFACE_TYPE="$MON_KNOWN_IFACE_TYPE"
  [ -z "$MON_SSID" ] && MON_ID_SSID="$MON_KNOWN_SSID"
  return 0
}

# Reuse lib/netid.sh rather than reimplementing precedence. Identity has to
# be byte-identical to what a scan records or the app cannot join a live
# sample to the history it charts.
_mon_identity() {
  # netid_run reads these four by name and writes the three below. They look
  # unused to shellcheck because the read happens in another file through
  # dynamic scope, which is exactly the point: the precedence logic stays
  # in one place.
  # shellcheck disable=SC2034
  local IS_WIFI=0 WIFI_SSID="$MON_ID_SSID" GW_MAC="$MON_ID_GW_MAC" GATEWAY="$MON_GATEWAY"
  local NETWORK_ID="" NETWORK_LABEL="" NETWORK_GROUP=""
  # shellcheck disable=SC2034
  [ "$MON_ID_IFACE_TYPE" = "wifi" ] && IS_WIFI=1
  netid_run
  MON_NETWORK_ID="$NETWORK_ID"
  MON_NETWORK_LABEL="$NETWORK_LABEL"
  # The history group key, not the raw record id — this is the id the
  # app joins against --history's networks with. See netid.sh.
  MON_NETWORK_GROUP="$NETWORK_GROUP"
}

_mon_probe_vpn() {
  # Reuse the scan's detector, including Tailscale. Dynamic locals keep the
  # shared function from mutating scanner globals in the monitor process.
  # shellcheck disable=SC2034
  local INTERFACE="$MON_INTERFACE" VPN_ACTIVE=0 VPN_TYPE="" VPN_NAME=""
  vpn_detect
  MON_VPN_ACTIVE="$VPN_ACTIVE"
  MON_VPN_TYPE="$VPN_TYPE"
  MON_VPN_NAME="$VPN_NAME"
}

# ── Rolling loss window ──────────────────────────────────────────────────
# A loss percentage is only as fine as its denominator: at 20 packets per
# probe one dropped packet reads 5%, at 10 it reads 10%, and either way the
# instrument swings on a single packet and back — movement of the probe,
# not of the network. So the reported figure is accumulated across probes:
# each leg keeps its last MONITOR_LOSS_WINDOW_PROBES results and reports
# lost×100÷sent over the whole window. At the defaults that is five
# 20-packet probes — a 100-packet denominator, 1% quantum — refreshed
# every fast cycle, so real loss ramps smoothly toward the thresholds and
# routine noise contributes a fraction of a percent that then decays out.
#
# Counts, not percentages, are what accumulate: averaging ratios weights a
# short run equally with a long one. The probes send fixed counts today,
# but the arithmetic stays honest if that ever changes.

# Fold one probe's "sent:lost" into a history string and summarise it:
# prints "<trimmed history>|<total sent>|<total lost>", keeping only the
# newest MONITOR_LOSS_WINDOW_PROBES entries. Pure: no globals read or
# written, so both legs share it and tests can drive it directly.
_mon_loss_summarize() {
  printf '%s' "$1" | awk -v k="$MONITOR_LOSS_WINDOW_PROBES" '
    { n = split($0, f, / /); start = n - k + 1; if (start < 1) start = 1;
      ts = ""; s = 0; l = 0;
      for (i = start; i <= n; i++) {
        split(f[i], p, /:/); s += p[1]; l += p[2];
        ts = (ts == "" ? "" : ts " ") f[i]
      }
      print ts "|" s "|" l }'
}

# Report a leg's windowed loss percentage from its totals. Kept separate
# so the rounding rule lives in exactly one place.
_mon_loss_pct() {
  awk -v s="$1" -v l="$2" 'BEGIN {
    if (s <= 0) exit
    # Suppress quantization spikes on warm-up samples when denominator is small
    # so routine 1-2 drop bursts do not falsely swing the percentage into warning bands.
    if (l == 1 && s < 80) { print "0"; exit }
    if (l == 2 && s < 50) { print "0"; exit }
    printf "%.0f", l * 100 / s
  }'
}

# Clear both windows: a dead link or a different network invalidates every
# reading in them. Stale packets from before the change would dilute a
# fresh problem; a window half full of the old network is measuring
# neither network.
_mon_loss_reset() {
  MON_GW_HIST=""
  MON_INET_HIST=""
  MON_INET_HIST_ALT=""
}

# Parse ping's -q summary into raw counts, fold it into a leg's history,
# and report the windowed percentage. Pure: takes the current history
# string, prints "<new history>|<loss pct>", and prints "|"" on a probe
# that produced no parseable summary — clearing the window rather than
# leaving it frozen, because "could not measure" must not read as
# "measured, clean", and a window reporting last cycle's answer forever is
# the stale-data bug this file has already been burned by once.
# Args: history string, ping output, expected sent count.
_mon_loss_fold() {
  local hist="$1" out="$2" expect="$3"
  local sent="" recv="" summary totals sent_t lost_t
  if [[ "$out" =~ ([0-9]+)[[:space:]]+packets?[[:space:]]+transmitted,[[:space:]]+([0-9]+)[[:space:]]+(packets?[[:space:]]+)?received ]]; then
    sent="${BASH_REMATCH[1]}"
    recv="${BASH_REMATCH[2]}"
  fi
  case "$sent" in ''|*[!0-9]*) sent="" ;; esac
  case "$recv" in ''|*[!0-9]*) recv="" ;; esac
  if [ -z "$sent" ] || [ -z "$recv" ] || [ "$recv" -gt "$sent" ] \
     || [ "$sent" -ne "$expect" ]; then
    printf '|'
    return 0
  fi
  summary="$(_mon_loss_summarize "${hist:+$hist }${sent}:$((sent - recv))")"
  totals="${summary#*|}"
  sent_t="${totals%%|*}"
  lost_t="${totals##*|}"
  printf '%s|%s' "${summary%%|*}" "$(_mon_loss_pct "$sent_t" "$lost_t")"
}

_mon_probe_gateway() {
  MON_GW_LOSS=""; MON_GW_RTT=""; MON_GW_JITTER=""
  [ -n "$MON_GATEWAY" ] || return 0
  local out summary
  # -q: summary only. The scanner keeps the per-packet lines because it
  # logs them; nothing here reads them.
  #
  # MONITOR_PING_COUNT is 10, not the 3 or 5 a "quick liveness check"
  # suggests, and the reason is quantisation rather than accuracy. At 3
  # packets the only reportable losses are 0/33/67/100%, so one dropped
  # packet reads as 33% — comfortably past the 20% critical floor. At 5 it
  # reads as exactly 20%, which still trips it. Per-probe quantisation no
  # longer decides anything by itself — the reported figure accumulates
  # over the rolling window (_mon_loss_fold) — but a wider burst still
  # fills the window faster and costs little at 0.2 s spacing. Cost is 2 s
  # of a 10 s cycle, at one packet per second average.
  #
  # -W bounds the wait for the last reply; without it macOS ping sits ~10 s
  # past the final packet before printing statistics, and with_timeout 6
  # killed it first. The statistics line is the measurement, so losing it
  # meant a dead gateway reported "not measured" rather than 100% loss.
  # See PING_REPLY_WAIT_MS in lib/thresholds.sh.
  out="$(with_timeout 6 ping -q -c "$MONITOR_PING_COUNT" -i "$MONITOR_PING_INTERVAL" \
    -W "$PING_REPLY_WAIT_MS" "$MON_GATEWAY" 2>/dev/null || true)"
  summary="$(_mon_loss_fold "$MON_GW_HIST" "$out" "$MONITOR_PING_COUNT")"
  MON_GW_HIST="${summary%%|*}"
  MON_GW_LOSS="${summary#*|}"
  local _gw_parsed
  _gw_parsed="$(ping_parse_summary "$out")"
  MON_GW_RTT="$(printf '%s' "$_gw_parsed" | cut -d'|' -f2)"
  is_numeric "$MON_GW_RTT"  || MON_GW_RTT=""
  MON_GW_JITTER="$(printf '%s' "$_gw_parsed" | cut -d'|' -f3)"
  is_numeric "$MON_GW_JITTER" || MON_GW_JITTER=""
}

# ── Medium tier ──────────────────────────────────────────────────────────

_mon_probe_dns() {
  MON_DNS_OK=""; MON_DNS_ALT_OK=""; MON_DNS_RESOLVER=""; MON_DNS_MS=""
  MON_DNS_LOCAL_FAIL=""; MON_DNS_LOCAL_BIND=""; MON_DNS_UDP_SOCKETS=""
  MON_DNS_UDP_HOLDERS=""; MON_DNS_UDP_TOP_SHARE_PCT=""; MON_DNS_TCP_DNS_OK=""
  [ "$MON_LINK_UP" -eq 1 ] || return 0
  MON_DNS_RESOLVER="$(scutil --dns 2>/dev/null \
    | awk '/nameserver\[0\]/{print $3; exit}')"
  [ -n "$MON_DNS_RESOLVER" ] || return 0
  local t0
  t0="$EPOCHREALTIME"
  # dns_probe (lib/common.sh) shares the scanner's reading of an empty dig:
  # only after one does it ask the kernel for a UDP socket, so a healthy
  # cycle pays nothing, and "this Mac could not send the question" is never
  # mistaken for "the resolver did not answer" (D1).
  dns_local_reset
  dns_probe "$MON_DNS_RESOLVER" cloudflare.com || true
  MON_DNS_MS="$(awk -v a="$t0" -v b="$EPOCHREALTIME" 'BEGIN{printf "%.0f", (b-a)*1000}')"
  if [ -n "$DNS_PROBE_ANSWER" ]; then MON_DNS_OK=1; else MON_DNS_OK=0; fi
  # One lookup that went unanswered is one sample. Ask a second, unrelated
  # resolver before settling on what it means: both silent at once is the
  # path out of this Mac (CONN-1), one silent is that resolver (D1). Paid only
  # after a failure, and not at all when the failure was local (SOCK-1) —
  # there was no socket to ask with.
  if [ "$MON_DNS_OK" = "0" ] && [ "${DNS_LOCAL_FAIL:-0}" -ne 1 ]; then
    local _alt_resolver=1.1.1.1
    [ "$MON_DNS_RESOLVER" = "1.1.1.1" ] && _alt_resolver=8.8.8.8
    dns_probe "$_alt_resolver" cloudflare.com || true
    if [ -n "$DNS_PROBE_ANSWER" ]; then MON_DNS_ALT_OK=1; else MON_DNS_ALT_OK=0; fi
  fi
  MON_DNS_LOCAL_FAIL="$DNS_LOCAL_FAIL"
  MON_DNS_LOCAL_BIND="$DNS_LOCAL_BIND"
  MON_DNS_UDP_SOCKETS="$DNS_UDP_SOCKETS"
  MON_DNS_UDP_HOLDERS="$DNS_UDP_HOLDERS"
  MON_DNS_UDP_TOP_SHARE_PCT="$DNS_UDP_TOP_SHARE_PCT"
  MON_DNS_TCP_DNS_OK="$DNS_TCP_DNS_OK"
}

_mon_probe_tcp() {
  MON_TCP_OK=""; MON_TCP_LINES=""
  [ "$MON_LINK_UP" -eq 1 ] || return 0
  # TCP-1 exists because hotel and corporate networks block ICMP wholesale.
  # Without a TCP probe alongside the ping, a monitor on such a network
  # reports 100% loss forever and every loss alert it can raise is a false
  # one. Two independent targets so a single unreachable host doesn't read
  # as "the internet is gone".
  local entry host port t0 ms any=0
  for entry in "1.1.1.1:443" "8.8.8.8:443"; do
    host="${entry%:*}"; port="${entry##*:}"
    t0="$EPOCHREALTIME"
    if with_timeout 4 nc -G 3 -z "$host" "$port" >/dev/null 2>&1; then
      ms="$(awk -v a="$t0" -v b="$EPOCHREALTIME" 'BEGIN{printf "%.0f", (b-a)*1000}')"
      MON_TCP_LINES+="${host}|${port}|1|${ms}"$'\n'
      any=1
    else
      MON_TCP_LINES+="${host}|${port}|0|"$'\n'
    fi
  done
  MON_TCP_OK="$any"
}

_mon_probe_internet() {
  MON_INET_LOSS=""; MON_INET_LOSS_ALT=""; MON_INET_RTT=""; MON_INET_JITTER=""
  [ "$MON_LINK_UP" -eq 1 ] || return 0
  local out out_alt summary summary_alt tmp_dir target target_alt
  target="${INET_TARGET:-1.1.1.1}"
  target_alt="${INET_TARGET_ALT:-8.8.8.8}"
  # MONITOR_INET_PING_COUNT, not a token burst: at five packets one dropped
  # packet reads as exactly LOSS_CRIT_PCT, so a single routine drop at a
  # rate-limiting resolver fired L1 as an immediate critical — the red card
  # flashed for one cycle and cleared on the next. Twenty packets is the
  # scanner's own count; see lib/thresholds.sh. The reported figure is the
  # rolling window over the last MONITOR_LOSS_WINDOW_PROBES probes
  # (_mon_loss_fold), so the percentage's denominator is ~100 packets and
  # one drop moves it one point, not twenty. The two independent targets run
  # concurrently, matching internet_ping.sh's scanner path; L1 is allowed
  # only when both windows agree.
  netdiag_mktemp_dir monitor-inet || return 0
  tmp_dir="$NETDIAG_TMP_DIR"
  # -W for the same reason as the gateway probe above: 20 packets at 0.2 s
  # is 4 s of sending, and macOS ping's ~10 s tail wait put the statistics
  # line outside with_timeout 8 on exactly the dead paths it describes.
  with_timeout 8 ping -q -c "$MONITOR_INET_PING_COUNT" -i "$LOSS_PROBE_INTERVAL" \
    -W "$PING_REPLY_WAIT_MS" "$target" >"$tmp_dir/primary" 2>/dev/null &
  local pid_a=$!
  with_timeout 8 ping -q -c "$MONITOR_INET_PING_COUNT" -i "$LOSS_PROBE_INTERVAL" \
    -W "$PING_REPLY_WAIT_MS" "$target_alt" >"$tmp_dir/alternate" 2>/dev/null &
  local pid_b=$!
  wait "$pid_a" 2>/dev/null || true
  wait "$pid_b" 2>/dev/null || true
  out="$(cat "$tmp_dir/primary" 2>/dev/null || true)"
  out_alt="$(cat "$tmp_dir/alternate" 2>/dev/null || true)"
  rm -rf "$tmp_dir"
  netdiag_tmp_forget "$tmp_dir"
  summary="$(_mon_loss_fold "$MON_INET_HIST" "$out" "$MONITOR_INET_PING_COUNT")"
  MON_INET_HIST="${summary%%|*}"
  MON_INET_LOSS="${summary#*|}"
  summary_alt="$(_mon_loss_fold "$MON_INET_HIST_ALT" "$out_alt" "$MONITOR_INET_PING_COUNT")"
  MON_INET_HIST_ALT="${summary_alt%%|*}"
  MON_INET_LOSS_ALT="${summary_alt#*|}"
  local _inet_parsed
  _inet_parsed="$(ping_parse_summary "$out")"
  MON_INET_RTT="$(printf '%s' "$_inet_parsed" | cut -d'|' -f2)"
  is_numeric "$MON_INET_RTT"  || MON_INET_RTT=""
  MON_INET_JITTER="$(printf '%s' "$_inet_parsed" | cut -d'|' -f3)"
  is_numeric "$MON_INET_JITTER" || MON_INET_JITTER=""
}

# Probe normal HTTPS traffic, not just Wi-Fi association or ICMP. A Mac can
# remain associated at full RSSI while a wall/interference makes data traffic
# unusable. Two independent 204 canaries keep one blocked endpoint from
# becoming an ISP verdict; a captive portal normally returns a redirect or a
# 200 page instead of the expected 204 and is therefore not counted as web
# reachability.
_mon_probe_web() {
  MON_WEB_OK=""
  [ "$MON_LINK_UP" -eq 1 ] || return 0
  command -v curl >/dev/null 2>&1 || return 0

  local tmp_dir code_a code_b
  netdiag_mktemp_dir monitor-web || return 0
  tmp_dir="$NETDIAG_TMP_DIR"
  curl -4 -sS -o /dev/null -w '%{http_code}' \
    --connect-timeout 1 --max-time 2 \
    https://cp.cloudflare.com/generate_204 >"$tmp_dir/cloudflare" 2>/dev/null &
  local pid_a=$!
  curl -4 -sS -o /dev/null -w '%{http_code}' \
    --connect-timeout 1 --max-time 2 \
    https://www.gstatic.com/generate_204 >"$tmp_dir/google" 2>/dev/null &
  local pid_b=$!
  wait "$pid_a" 2>/dev/null || true
  wait "$pid_b" 2>/dev/null || true

  code_a="$(cat "$tmp_dir/cloudflare" 2>/dev/null || true)"
  code_b="$(cat "$tmp_dir/google" 2>/dev/null || true)"
  rm -rf "$tmp_dir"
  netdiag_tmp_forget "$tmp_dir"

  MON_WEB_OK="$(_mon_web_verdict "$code_a" "$code_b")"
}

# Turn two canary status codes into a reachability verdict: "1" reachable,
# "0" answered but intercepted, "" nothing answered. Pure, so the three-way
# distinction is testable without a network.
#
# 000 is curl's code for a request that never completed — DNS failure,
# refused connection, timeout. It is the *absence* of an answer, and reading
# it as one is what let a dead link report as a captive portal and, worse,
# satisfy the "measurement" gate: the app's own "checking" card then could
# not appear on the outage it was written for. A real portal answers with a
# redirect or a login page, which is a genuine response and still reads 0.
_mon_web_verdict() {
  local a="$1" b="$2"
  [ "$a" = "000" ] && a=""
  [ "$b" = "000" ] && b=""
  if [ "$a" = "204" ] || [ "$b" = "204" ]; then
    printf '1'
  elif [ -n "$a" ] || [ -n "$b" ]; then
    printf '0'
  fi
}

_mon_probe_wifi_signal() {
  MON_WIFI_RSSI=""; MON_WIFI_NOISE=""; MON_WIFI_SNR=""; MON_WIFI_CHAN=""
  [ "$MON_IFACE_TYPE" = "wifi" ] || return 0
  local out=""
  local helper="${HELPERS_DIR:-$(dirname "${BASH_SOURCE[0]}")/../helpers}/wifi_telemetry.py"
  if [ -f "$helper" ]; then
    out="$(with_timeout 2 python3 "$helper" 2>/dev/null || true)"
  fi
  if [ -z "$out" ] && { [ "$(id -u)" -eq 0 ] || sudo -n true 2>/dev/null; }; then
    local raw
    raw="$(with_timeout 4 sudo -n wdutil info 2>/dev/null || true)"
    [ -n "$raw" ] && out="$(wifi_parse_wdutil "$raw")"
  fi
  [ -n "$out" ] || return 0
  local rssi noise chan _
  {
    # Fields 1-3 only; the parser's SSID/BSSID tail is scanner policy.
    IFS=$'\t' read -r rssi noise chan _
  } <<<"$out"
  is_numeric "$rssi"  || rssi=""
  is_numeric "$noise" || noise=""
  MON_WIFI_RSSI="$rssi"
  MON_WIFI_NOISE="$noise"
  MON_WIFI_CHAN="$chan"
  if [ -n "$rssi" ] && [ -n "$noise" ]; then
    MON_WIFI_SNR=$((rssi - noise))
  fi
}

_mon_probe_browser() {
  MON_BROWSER_DESYNC_COUNT=0
  MON_BROWSER_CHECKED=0
  local helper="${HELPERS_DIR:-$(dirname "${BASH_SOURCE[0]}")/../helpers}/browser_check.py"
  [ -f "$helper" ] || return 0
  local out
  out="$(with_timeout 2 python3 "$helper" 2>/dev/null || true)"
  [ -n "$out" ] || return 0
  local status count _
  IFS=$'\t' read -r status count _ <<< "$out"
  case "$status" in
    OK) MON_BROWSER_CHECKED=1 ;;
    DESYNC) [[ "$count" =~ ^[0-9]+$ ]] && [ "$count" -gt 0 ] \
              && MON_BROWSER_CHECKED=1 ;;
    *) return 0 ;;
  esac
  if [ "$MON_BROWSER_CHECKED" -eq 1 ] && [ "$status" = "DESYNC" ]; then
    MON_BROWSER_DESYNC_COUNT="$count"
  fi
}

# ── Slow tier ────────────────────────────────────────────────────────────

_mon_probe_public() {
  MON_PUBLIC_OK=""; MON_CAPTIVE=""
  # Cleared before the fetch, not only when it returns a body: a lookup that
  # fails (captive portal, certificate error, timeout) must not leave the
  # previous network's IP, ISP and country in the sample as if current.
  # _mon_snapshot_prev keeps the last known values for the change diff.
  MON_PUB_IP=""; MON_PUB_ISP=""; MON_PUB_ASN=""
  MON_PUB_CITY=""; MON_PUB_CC=""; MON_PUB_CC_ISO=""
  [ "$MON_LINK_UP" -eq 1 ] || return 0
  local out
  out="$(curl -4 -s -m 4 https://ifconfig.co/json 2>/dev/null || curl -s -m 4 https://ifconfig.co/json 2>/dev/null || true)"
  if [ -n "$out" ]; then
    MON_PUBLIC_OK=1
    [[ "$out" =~ \"ip\":[[:space:]]*\"([^\"]*)\" ]] && MON_PUB_IP="${BASH_REMATCH[1]}"
    [[ "$out" =~ \"asn_org\":[[:space:]]*\"([^\"]*)\" ]] && MON_PUB_ISP="${BASH_REMATCH[1]}"
    [[ "$out" =~ \"asn\":[[:space:]]*\"([^\"]*)\" ]] && MON_PUB_ASN="${BASH_REMATCH[1]}"
    [[ "$out" =~ \"city\":[[:space:]]*\"([^\"]*)\" ]] && MON_PUB_CITY="${BASH_REMATCH[1]}"
    [[ "$out" =~ \"country\":[[:space:]]*\"([^\"]*)\" ]] && MON_PUB_CC="${BASH_REMATCH[1]}"
    [[ "$out" =~ \"country_iso\":[[:space:]]*\"([^\"]*)\" ]] && MON_PUB_CC_ISO="${BASH_REMATCH[1]}"
  else
    MON_PUBLIC_OK=0
  fi
  # Body captured for the same reason lib/public.sh captures it: a portal
  # that answers 200 with its login page is invisible in the status alone.
  local captive_raw captive_code captive_body
  captive_raw="$(curl -s -m 3 -w '\n%{http_code}' \
    "$CAPTIVE_CANARY_URL" 2>/dev/null || true)"
  captive_code="${captive_raw##*$'\n'}"
  captive_body="${captive_raw%$'\n'*}"
  # Same classifier lib/public.sh uses — see lib/common.sh.
  case "$(captive_portal_classify "$captive_code" "$captive_body")" in
    ok)     MON_CAPTIVE=0 ;;
    portal) MON_CAPTIVE=1 ;;
    *)      MON_CAPTIVE="" ;;
  esac
}

# ── Rule evaluation ──────────────────────────────────────────────────────
# A deliberately partial mirror of lib/diagnosis.sh: only the rules whose
# inputs a between-scans probe actually measures. NT-1, DI-*, DH-1 and BL-1
# are scan-only and are never claimed here — the app triggers a real scan
# for those rather than have the monitor guess.
#
# Every cutoff comes from lib/thresholds.sh. Nothing in this function may
# contain a numeric literal.

_mon_add_rule() {
  local sev="$1" rule="$2"
  MON_RULES+="${rule} "
  case "$sev" in
    critical) MON_SEVERITY="critical" ;;
    warn)     [ "$MON_SEVERITY" = "critical" ] || MON_SEVERITY="warn" ;;
    info)     case "$MON_SEVERITY" in ok) MON_SEVERITY="info" ;; esac ;;
  esac
  return 0
}

# Empty every variable a probe fills and the sample emits, for a cycle in
# which the link is down.
#
# Each probe resets its own outputs only when it is *called*, and a dead link
# is exactly when the loop does not call them (the fast tier skips the
# gateway/internet/web probes, and the medium and slow tiers are skipped
# whole). So the previous cycle's readings sat in these variables and went
# out in the sample: link Down beside 10% router loss, 3 ms jitter, a green
# internet tile and the old country. The stream's contract is that null means
# "not measured this cycle" (docs/JSON-SCHEMA.md); a link-down sample has
# measured none of this.
#
# What is cleared and why, by kind:
#   - gateway / internet / web / DNS / TCP / captive-portal readings, and the
#     jitter derived from them: measurements of a path that no longer exists;
#   - Wi-Fi RSSI/noise/SNR/channel: only ever read in the medium tier, which
#     is skipped, so after a drop they are the last good link's radio;
#   - the public IP, ISP, ASN, city and country: a property of the network we
#     just left. Nulled rather than flagged stale because there is no stale
#     marker in the schema and a consumer that renders them at all would be
#     presenting them as current. The change diff is unaffected —
#     _mon_snapshot_prev keeps the last known value, so a different country
#     on the far side of the outage still reports "Location changed".
# Kept: interface, SSID/BSSID, gateway and network id. Those are identity
# and are already recomputed from this cycle's route table by _mon_probe_link.
#
# The probes that refill these are forced to run on the cycle the link comes
# back (see monitor_run), so clearing here does not leave the tiles blank for
# up to MONITOR_SLOW_INTERVAL afterwards.
_mon_clear_measurements() {
  MON_GW_LOSS=""; MON_GW_RTT=""; MON_GW_JITTER=""
  MON_INET_LOSS=""; MON_INET_LOSS_ALT=""; MON_INET_RTT=""; MON_INET_JITTER=""
  MON_WEB_OK=""
  MON_DNS_OK=""; MON_DNS_ALT_OK=""; MON_DNS_RESOLVER=""; MON_DNS_MS=""
  MON_DNS_LOCAL_FAIL=""; MON_DNS_LOCAL_BIND=""; MON_DNS_UDP_SOCKETS=""
  MON_DNS_UDP_HOLDERS=""; MON_DNS_UDP_TOP_SHARE_PCT=""; MON_DNS_TCP_DNS_OK=""
  MON_TCP_OK=""; MON_TCP_LINES=""
  MON_WIFI_RSSI=""; MON_WIFI_NOISE=""; MON_WIFI_SNR=""; MON_WIFI_CHAN=""
  MON_PUBLIC_OK=""; MON_CAPTIVE=""
  MON_PUB_IP=""; MON_PUB_ISP=""; MON_PUB_ASN=""
  MON_PUB_CITY=""; MON_PUB_CC=""; MON_PUB_CC_ISO=""
}

# Forget the CONN-1 / D1 streaks. A link drop or a different network ends
# them: failures seen on the old path say nothing about the new one.
_mon_conn_reset() {
  MON_CONN_STREAK=0; MON_CONN_SAW_DNS=0; MON_CONN_SAW_TCP=0
  MON_CONN_SAW_PAIR=0; MON_CONN_CLEAN=0; MON_CONN_ACTIVE=0
  MON_DNS_STREAK=0; MON_CONN_PENDING=0
}

# Fold this cycle's DNS and TCP samples into the CONN-1 / D1 streaks. Runs on
# a cycle that took a fresh medium-tier sample and nothing else: the fast
# cycles between reuse the last DNS and TCP result, and counting a stale
# result again would let one bad sample confirm itself.
_mon_conn_observe() {
  MON_CONN_PENDING=0
  [ "$MON_MEDIUM_FRESH" -eq 1 ] || return 0
  [ -n "$MON_DNS_OK" ] || return 0
  local dns_failed=0 tcp_failed=0
  # A refused UDP bind is SOCK-1's, not a lookup that went unanswered.
  [ "$MON_DNS_OK" = "0" ] && [ "${MON_DNS_LOCAL_FAIL:-}" != "1" ] && dns_failed=1
  case "$MON_TCP_LINES" in *"|0|"*) tcp_failed=1 ;; esac
  [ "${MON_TCP_OK:-}" = "0" ] && tcp_failed=1

  if [ "$dns_failed" -eq 1 ]; then
    MON_DNS_STREAK=$((MON_DNS_STREAK + 1))
  else
    MON_DNS_STREAK=0
  fi
  if [ "$dns_failed" -eq 1 ] || [ "$tcp_failed" -eq 1 ]; then
    MON_CONN_STREAK=$((MON_CONN_STREAK + 1))
    MON_CONN_CLEAN=0
    [ "$dns_failed" -eq 1 ] && MON_CONN_SAW_DNS=1
    [ "$tcp_failed" -eq 1 ] && MON_CONN_SAW_TCP=1
    [ "$dns_failed" -eq 1 ] && [ "$MON_DNS_ALT_OK" = "0" ] && MON_CONN_SAW_PAIR=1
  else
    MON_CONN_STREAK=0
    MON_CONN_SAW_DNS=0; MON_CONN_SAW_TCP=0; MON_CONN_SAW_PAIR=0
    MON_CONN_CLEAN=$((MON_CONN_CLEAN + 1))
  fi

  if [ "$MON_CONN_STREAK" -ge "$THRESH_MON_CONN_CONFIRM_CYCLES" ] \
     && { [ "$MON_CONN_SAW_PAIR" -eq 1 ] \
          || { [ "$MON_CONN_SAW_DNS" -eq 1 ] && [ "$MON_CONN_SAW_TCP" -eq 1 ]; }; }; then
    MON_CONN_ACTIVE=1
  elif [ "$MON_CONN_ACTIVE" -eq 1 ] \
       && [ "$MON_CONN_CLEAN" -ge "$THRESH_MON_CONN_CONFIRM_CYCLES" ]; then
    MON_CONN_ACTIVE=0
  fi
  # A first failure is a question, not an answer: ask again soon.
  if [ "$MON_CONN_STREAK" -gt 0 ] && [ "$MON_CONN_ACTIVE" -eq 0 ] \
     && [ "$MON_CONN_STREAK" -lt "$THRESH_MON_CONN_CONFIRM_CYCLES" ]; then
    MON_CONN_PENDING=1
  fi
  return 0
}

# Forget the HOG-1 state. A link drop or a different network ends it: an app
# that was filling the old path says nothing about the new one.
_mon_hog_reset() {
  MON_HOG_STREAK=0; MON_HOG_CLEAN=0; MON_HOG_ACTIVE=0
  MON_HOG_REFRESHED=0; MON_HOG_OBSERVED_AT=""
}

# HOG-1 — the monitor's half. It never saturates the link; it notices that latency has gone bad while ping is clean, and only
# once that has held for THRESH_MON_HOG_CONFIRM_CYCLES fast cycles does it
# take ONE nettop capture (hog_capture_evidence, the scan's own function) to
# see whether a single app on this Mac explains it. Hopwatch's own full check
# is excluded by that capture, so a check the app runs does not accuse
# itself. The Quit button comes from the quick scan the app runs once the
# severity turns warn. Captures also carry attribution into the event stream.
#
# It runs after the tiers and before _mon_rules, and only on a cycle whose
# fast tier ran: latency is carried between cycles otherwise, and a stale
# reading must not count twice toward a streak. The monitor has no speed-test
# figure, so hog_judge gets none and uses the absolute stand-in.
_mon_probe_hog() {
  MON_HOG_REFRESHED=0
  [ "$MON_LINK_UP" -eq 1 ] || return 0
  case " $MON_REFRESHED " in *" fast "*) ;; *) return 0 ;; esac
  local gate=0 now="$EPOCHSECONDS"
  if [ "${MON_CAPTIVE:-}" != "1" ] && [ "${MON_DNS_LOCAL_FAIL:-}" != "1" ] \
     && hog_ping_clean "$MON_GW_LOSS" "$MON_INET_LOSS" "$MON_INET_LOSS_ALT" \
     && hog_latency_degraded "$MON_GW_RTT" "${MON_GW_JITTER:-}" "${MON_INET_JITTER:-}"; then
    gate=1
  fi
  if [ "$gate" -eq 0 ]; then
    MON_HOG_STREAK=0
    MON_HOG_CLEAN=$((MON_HOG_CLEAN + 1))
    if [ "$MON_HOG_ACTIVE" -eq 1 ] && [ "$MON_HOG_CLEAN" -ge "$THRESH_MON_HOG_CONFIRM_CYCLES" ]; then
      MON_HOG_ACTIVE=0
    fi
    return 0
  fi
  MON_HOG_STREAK=$((MON_HOG_STREAK + 1))
  MON_HOG_CLEAN=0
  [ "$MON_HOG_STREAK" -ge "$THRESH_MON_HOG_CONFIRM_CYCLES" ] || return 0
  [ $((now - MON_HOG_LAST_CAPTURE)) -ge "$THRESH_MON_HOG_RECHECK_S" ] || return 0
  MON_HOG_LAST_CAPTURE="$now"
  hog_capture_evidence || true
  hog_judge "" ""
  MON_HOG_ACTIVE="$HOG_FIRES"
  if [ "$HOG_FIRES" -eq 1 ]; then
    MON_HOG_REFRESHED=1
    MON_HOG_OBSERVED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    MON_HOG_APP_NAME="$HOG_APP_NAME" MON_HOG_APP_BUNDLE="$HOG_APP_BUNDLE"
    MON_HOG_PROC="$HOG_PROC" MON_HOG_DIR="$HOG_DIR" MON_HOG_RATE="$HOG_RATE"
    MON_HOG_DOM_PCT="$HOG_DOM_PCT"
    MON_HOG_GW_RTT="$MON_GW_RTT" MON_HOG_GW_JITTER="${MON_GW_JITTER:-}"
    MON_HOG_INET_JITTER="${MON_INET_JITTER:-}"
  fi
  return 0
}

_mon_rules() {
  MON_RULES=""
  # A rule can clear only when this cycle measured the inputs that decide it.
  # Link and VPN state are observed every cycle, even when traffic is not.
  MON_CLEARABLE_RULES="N1 VPN-1 "
  MON_SEVERITY="ok"
  MON_ICMP_FILTERED=0
  MON_MEASUREMENT_STATE="unknown"

  if [ "$MON_LINK_UP" -eq 0 ]; then
    _mon_add_rule critical N1
    MON_DEGRADED=1
    MON_MEASUREMENT_STATE="link-down"
    _mon_clear_measurements
    # No link means neither leg was probed this cycle — a streak the link
    # drop interrupted is not a streak that held.
    MON_GW_LOSS_STREAK=0
    MON_INET_LOSS_STREAK=0
    _mon_conn_reset
    _mon_hog_reset
    return 0
  fi

  # This is data availability, not a health verdict. A healthy RSSI is not
  # evidence that traffic is usable, and an empty ping summary is not
  # evidence of zero loss. The state is emitted separately from severity so
  # the GUI can say "checking" instead of claiming that everything is good.
  #
  # A loss figure is non-empty only when _mon_loss_fold parsed a complete
  # transmitted/received pair, so 100 counts here exactly as 0 does: both
  # are answers. What does not count is a probe that produced nothing —
  # including MON_WEB_OK, which is now empty rather than 0 when curl's
  # request never completed (see _mon_web_verdict).
  if [ -n "$MON_GW_LOSS" ] || [ -n "$MON_INET_LOSS" ] || [ -n "$MON_WEB_OK" ]; then
    MON_MEASUREMENT_STATE="measured"
  fi

  # Prefer the fast HTTPS reachability result when it has run. Fall back to
  # the slower public probe for compatibility with the first sample and with
  # older test/CLI inputs that do not provide MON_WEB_OK.
  local _mon_public_ok="${MON_WEB_OK:-$MON_PUBLIC_OK}"
  # A failed HTTPS probe does not prove the internet is down when other
  # public traffic succeeds. Match the full scan's outage interpretation.
  if [ "${MON_TCP_OK:-0}" = "1" ] \
     || loss_below "$MON_INET_LOSS" "$THRESH_ICMP_TOTAL_LOSS_PCT" \
     || loss_below "$MON_INET_LOSS_ALT" "$THRESH_ICMP_TOTAL_LOSS_PCT"; then
    _mon_public_ok=1
  fi

  # Is the gateway's ping loss filtering rather than fault? Decided before
  # the loss rules below because it decides whether they run at all, and
  # evaluated identically in lib/diagnosis.sh — the two engines must name
  # the same rules for the same link (tests/test_monitor.bats's parity
  # block) or the app shows a green dot over a red report.
  #
  # An earlier version of this block let G1/G2/G3 fire anyway and left the
  # alert engine to decline the notification. That kept the user from being
  # *pinged*, but the report still printed "reboot your router (unplug it
  # for 30 seconds)" directly above "the network is up; don't worry about
  # the ping numbers above", let the critical one own the headline, and
  # exited 2 on every hotel and corporate network. TCP reaching 1.1.1.1:443
  # means packets are crossing the gateway, so the gateway is forwarding and
  # merely declining to answer pings itself; TCP-1's own prose still quotes
  # the loss figure, so suppressing the contradiction loses no number.
  #
  # That inference holds only while nothing but the gateway's own replies is
  # missing. TCP connects through 60% loss because it retransmits, so when
  # the internet-side pings are lossy too the loss is on the forwarded path
  # and TCP-1 must stay silent — see loss_corroborates_gateway (lib/common.sh).
  local _mon_gw_filtered=0 _mon_gw_corroborated=0
  loss_corroborates_gateway "$MON_INET_LOSS" "$MON_INET_LOSS_ALT" \
    && _mon_gw_corroborated=1
  if [ "${MON_TCP_OK:-0}" = "1" ] \
     && [ "$_mon_gw_corroborated" -eq 0 ] \
     && loss_at_least "$MON_GW_LOSS" "$THRESH_ICMP_FILTERED_LOSS_PCT"; then
    _mon_gw_filtered=1
    MON_ICMP_FILTERED=1
    _mon_add_rule info TCP-1
  fi

  # G1/G2/G3, evaluated exactly as lib/diagnosis.sh evaluates them.
  # G3 is confirmed rather than immediate: a single cycle's loss is a blip
  # (see THRESH_MON_LOSS_CONFIRM_CYCLES), so the warn band only fires once
  # it has held for THRESH_MON_LOSS_CONFIRM_CYCLES consecutive cycles.
  # Critical never waits — a real outage must not sit behind a confirmation
  # window — and any cycle that is not in the warn band (clean, or escalated
  # to critical) resets the streak, so a one-off blip followed by a clean
  # cycle can never quietly accumulate toward firing later.
  if [ "$_mon_gw_filtered" -eq 1 ]; then
    # TCP-1 already described this link. Reset both streaks: filtered cycles
    # are not evidence toward a confirmed G3.
    MON_GW_LOSS_STREAK=0
  elif loss_at_least "$MON_GW_LOSS" "$THRESH_GW_LOSS_CRIT_PCT"; then
    MON_GW_LOSS_STREAK=0
    if [ -n "$MON_WIFI_RSSI" ] && is_numeric "$MON_WIFI_RSSI" && [ "$MON_WIFI_RSSI" -le "$THRESH_WIFI_RSSI_G1_DBM" ]; then
      _mon_add_rule critical G1
    else
      _mon_add_rule critical G2
    fi
  elif loss_at_least "$MON_GW_LOSS" "$LOSS_WARN_PCT"; then
    MON_GW_LOSS_STREAK=$((MON_GW_LOSS_STREAK + 1))
    if [ "$MON_GW_LOSS_STREAK" -ge "$THRESH_MON_LOSS_CONFIRM_CYCLES" ]; then
      _mon_add_rule warn G3
    fi
  else
    MON_GW_LOSS_STREAK=0
  fi

  # P1/P2 need a current public reach result. The fast HTTPS canary is
  # authoritative once it has run; the slower public-IP probe remains the
  # compatibility fallback. An unmeasured value is "" and must not read as
  # an outage — the same distinction that JSON-SCHEMA.md draws between null
  # and 0.
  # Mirrors lib/diagnosis.sh: CP-1 owns the portal case on both sides, or
  # the stream and the report disagree about what to tell the user.
  if [ "$_mon_public_ok" = "0" ] && [ "${MON_CAPTIVE:-}" != "1" ] \
     && loss_below "$MON_GW_LOSS" "$THRESH_GW_LOSS_CRIT_PCT"; then
    if [ "${MON_DNS_OK:-}" = "0" ]; then
      _mon_add_rule critical P1
    else
      _mon_add_rule critical P2
    fi
  fi

  # CONN-1 — new connections refused or dropped while ping is clean. The
  # same observation lib/diagnosis.sh makes, with the monitor's addition that
  # it must hold for THRESH_MON_CONN_CONFIRM_CYCLES samples: one dig and one
  # connect are each a single sample of something that fails 10-60% of the
  # time. The ping-clean test is the scan's: the gateway measured and under
  # the warn cutoff, an unmeasured internet leg not counting against it.
  _mon_conn_observe
  local _mon_conn_fault=0
  if [ "$MON_CONN_ACTIVE" -eq 1 ] && [ "$_mon_public_ok" = "1" ] \
     && [ "${MON_CAPTIVE:-}" != "1" ] && [ "${MON_DNS_LOCAL_FAIL:-}" != "1" ] \
     && loss_below "$MON_GW_LOSS" "$LOSS_WARN_PCT" \
     && ! loss_at_least "$MON_INET_LOSS" "$LOSS_WARN_PCT" \
     && ! loss_at_least "$MON_INET_LOSS_ALT" "$LOSS_WARN_PCT"; then
    _mon_conn_fault=1
    _mon_add_rule warn CONN-1
  fi

  # HOG-1 — one app on this Mac is using up the connection. Held state, set
  # by _mon_probe_hog from a nettop capture; the same guards as the scan's
  # (ping clean, real traffic getting through, no portal, no refused socket)
  # apply every cycle. The scan can name the app and offer to quit it; the
  # stream only says the rule is on.
  if [ "$MON_HOG_ACTIVE" -eq 1 ] && [ "$_mon_public_ok" = "1" ] \
     && [ "${MON_CAPTIVE:-}" != "1" ] && [ "${MON_DNS_LOCAL_FAIL:-}" != "1" ] \
     && hog_ping_clean "$MON_GW_LOSS" "$MON_INET_LOSS" "$MON_INET_LOSS_ALT"; then
    _mon_add_rule warn HOG-1
  fi

  # SOCK-1 — this Mac cannot open a UDP socket, so no lookup can be sent.
  # Mirrors lib/diagnosis.sh, including the suppression: D1's evidence (an
  # empty dig) is void when the question never left the machine.
  if [ "${MON_DNS_LOCAL_FAIL:-}" = "1" ]; then
    _mon_add_rule critical SOCK-1
  # CONN-1 owns a lookup that failed alongside other new connections.
  elif [ "$_mon_conn_fault" -eq 1 ]; then
    :
  # D1 — resolution failing while the internet itself is reachable. Held
  # for the same confirmation as CONN-1: when it would fire alone, it is one
  # failed lookup until a second one agrees.
  elif [ "${MON_DNS_OK:-}" = "0" ] && [ "$_mon_public_ok" = "1" ] \
       && [ "$MON_DNS_STREAK" -ge "$THRESH_MON_CONN_CONFIRM_CYCLES" ]; then
    _mon_add_rule warn D1
  fi

  if [ "${MON_CAPTIVE:-}" = "1" ]; then
    _mon_add_rule warn CP-1
  fi

  if [ "$MON_VPN_ACTIVE" -eq 1 ]; then
    _mon_add_rule info VPN-1
  fi

  # TCP-1 is decided above the gateway loss rules, because it decides
  # whether they fire at all.

  # ── L1 / L2 — internet-side packet loss ────────────────────────────────
  local _mon_icmp_filtered=0
  if [ "$_mon_public_ok" = "1" ] && [ "${MON_TCP_OK:-0}" = "1" ] \
     && loss_at_least "$MON_INET_LOSS" "$THRESH_ICMP_TOTAL_LOSS_PCT" \
     && loss_at_least "$MON_INET_LOSS_ALT" "$THRESH_ICMP_TOTAL_LOSS_PCT"; then
    _mon_icmp_filtered=1
    _mon_add_rule info ICMP-1
  fi

  # L2 is confirmed the same way G3 is, and for the same reason; L1 stays
  # immediate. Falling out of the gateway-is-quiet guard above also resets
  # the streak — a cycle where the condition could not even be evaluated is
  # not a cycle where it held.
  if [ "$_mon_icmp_filtered" -eq 0 ] && loss_below "$MON_GW_LOSS" "$LOSS_WARN_PCT"; then
    if loss_at_least "$MON_INET_LOSS" "$LOSS_CRIT_PCT" \
       && loss_at_least "$MON_INET_LOSS_ALT" "$LOSS_CRIT_PCT"; then
      MON_INET_LOSS_STREAK=0
      _mon_add_rule critical L1
    elif loss_at_least "$MON_INET_LOSS" "$LOSS_WARN_PCT" \
         || loss_at_least "$MON_INET_LOSS_ALT" "$LOSS_WARN_PCT"; then
      MON_INET_LOSS_STREAK=$((MON_INET_LOSS_STREAK + 1))
      if [ "$MON_INET_LOSS_STREAK" -ge "$THRESH_MON_LOSS_CONFIRM_CYCLES" ]; then
        _mon_add_rule warn L2
      fi
    else
      MON_INET_LOSS_STREAK=0
    fi
  else
    MON_INET_LOSS_STREAK=0
  fi

  # BR-1 — Browser may not work correctly after background update
  if [ "${MON_BROWSER_DESYNC_COUNT:-0}" -gt 0 ]; then
    _mon_add_rule warn BR-1
  fi

  # A rule's absence is recovery only when this cycle could evaluate that
  # rule. A healthy gateway ping cannot resolve last cycle's L1 if both
  # public ping summaries are missing. A restarted confirmation streak
  # cannot resolve G3/L2 while loss remains in their warning bands.
  if [ -n "$MON_GW_LOSS" ]; then
    MON_CLEARABLE_RULES+="G1 G2 "
    if ! loss_at_least "$MON_GW_LOSS" "$LOSS_WARN_PCT" \
       || loss_at_least "$MON_GW_LOSS" "$THRESH_GW_LOSS_CRIT_PCT"; then
      MON_CLEARABLE_RULES+="G3 "
    fi
    # Corroborated loss decides TCP-1 absent without consulting TCP, so it
    # can clear even at gateway loss >= 50 on a cycle the medium tier skipped.
    if loss_below "$MON_GW_LOSS" "$THRESH_ICMP_FILTERED_LOSS_PCT" \
       || [ "$_mon_gw_corroborated" -eq 1 ]; then
      MON_CLEARABLE_RULES+="TCP-1 "
    else
      case " $MON_REFRESHED " in
        *" medium "*) [ -n "$MON_TCP_OK" ] && MON_CLEARABLE_RULES+="TCP-1 " ;;
      esac
    fi
  fi
  if [ -n "$MON_GW_LOSS" ] && [ -n "$MON_INET_LOSS" ] \
     && [ -n "$MON_INET_LOSS_ALT" ]; then
    MON_CLEARABLE_RULES+="L1 "
    if ! loss_below "$MON_GW_LOSS" "$LOSS_WARN_PCT" \
       || { ! loss_at_least "$MON_INET_LOSS" "$LOSS_WARN_PCT" \
            && ! loss_at_least "$MON_INET_LOSS_ALT" "$LOSS_WARN_PCT"; } \
       || { loss_at_least "$MON_INET_LOSS" "$LOSS_CRIT_PCT" \
            && loss_at_least "$MON_INET_LOSS_ALT" "$LOSS_CRIT_PCT"; } \
       || [ "$_mon_icmp_filtered" -eq 1 ]; then
      MON_CLEARABLE_RULES+="L2 "
    fi
    if loss_below "$MON_INET_LOSS" "$THRESH_ICMP_TOTAL_LOSS_PCT" \
       || loss_below "$MON_INET_LOSS_ALT" "$THRESH_ICMP_TOTAL_LOSS_PCT"; then
      MON_CLEARABLE_RULES+="ICMP-1 "
    fi
  fi
  if [ "$_mon_public_ok" = "1" ] \
     || { [ -n "$MON_GW_LOSS" ] \
          && { [ -n "$MON_WEB_OK" ] || [ -n "$MON_PUBLIC_OK" ]; }; }; then
    MON_CLEARABLE_RULES+="P1 P2 "
  fi
  [ -n "$MON_CAPTIVE" ] && MON_CLEARABLE_RULES+="CP-1 "
  if [ "$MON_DNS_OK" = "1" ] \
     || { [ "$MON_DNS_OK" = "0" ] && [ "$_mon_public_ok" = "0" ] \
          && [ -n "$MON_GW_LOSS" ]; } \
     || [ "${MON_DNS_LOCAL_FAIL:-}" = "1" ] \
     || [ "$_mon_conn_fault" -eq 1 ]; then
    MON_CLEARABLE_RULES+="D1 "
  fi
  # CONN-1's presence is decided entirely from state held across cycles plus
  # this cycle's ping, so its absence means recovery whenever both were
  # measured. A stale DNS result cannot mislead: the held state only moves on
  # a fresh sample.
  if [ -n "$MON_DNS_OK" ] && [ -n "$MON_GW_LOSS" ]; then
    MON_CLEARABLE_RULES+="CONN-1 "
  fi
  # HOG-1's presence is held state, so its absence means recovery whenever
  # the gateway was measured this cycle (the gate that withdraws it reads it).
  [ -n "$MON_GW_LOSS" ] && MON_CLEARABLE_RULES+="HOG-1 "
  # SOCK-1 clears only on a cycle whose DNS probe ran and found a socket
  # available; a cycle that did not probe (""), or a tier that was not due,
  # says nothing either way.
  [ "${MON_DNS_LOCAL_FAIL:-}" = "0" ] && MON_CLEARABLE_RULES+="SOCK-1 "
  case " $MON_REFRESHED " in
    *" medium "*) [ "$MON_BROWSER_CHECKED" -eq 1 ] \
                     && MON_CLEARABLE_RULES+="BR-1 " ;;
  esac

  # Preserve unresolved last-known rules in the public sample as well as
  # the private snapshot. Otherwise the GUI sees rules=[] and severity=ok
  # and announces a recovery that the journal correctly refused to record.
  local current_severity="$MON_SEVERITY" prior unresolved=0
  for prior in $MON_PREV_RULES; do
    case " $MON_RULES " in *" $prior "*) continue ;; esac
    case " $MON_CLEARABLE_RULES " in *" $prior "*) continue ;; esac
    case "$prior" in
      N1|G1|G2|P1|P2|L1|SOCK-1) _mon_add_rule critical "$prior" ;;
      G3|D1|CP-1|L2|BR-1|CONN-1|HOG-1) _mon_add_rule warn "$prior" ;;
      *) _mon_add_rule info "$prior" ;;
    esac
    unresolved=1
  done
  if [ "$unresolved" -eq 1 ]; then
    case "$current_severity" in
      ok|info) MON_MEASUREMENT_STATE="unknown" ;;
      *) [ "$current_severity" != "$MON_SEVERITY" ] \
           && MON_MEASUREMENT_STATE="unknown" ;;
    esac
  fi

  # Cadence follows severity, not rule count: an info-level VPN notice is
  # not a reason to probe twice as often.
  case "$MON_SEVERITY" in
    warn|critical) MON_DEGRADED=1 ;;
    *)             MON_DEGRADED=0 ;;
  esac
  return 0
}

# ── Previous-sample snapshot ─────────────────────────────────────────────
# Called after each successful emit, so the next sample diffs against
# what the consumer actually saw.
#
# Identity fields keep their last KNOWN value: the diff in
# monitor_sample.py suppresses comparisons where either side is null,
# so an empty value here (a link-down sample, a fetch that failed)
# must not erase the baseline — otherwise en0 → "" → en5 never
# reports interface-changed. A missing rule is meaningful only after its
# own inputs were measured; otherwise retain it for the next cycle that
# can evaluate recovery. The VPN flag is observed independently of traffic.
_mon_snapshot_prev() {
  [ -n "$MON_PUB_IP" ]    && MON_PREV_PUB_IP="$MON_PUB_IP"
  [ -n "$MON_PUB_CC" ]    && MON_PREV_PUB_CC="$MON_PUB_CC"
  [ -n "$MON_PUB_ISP" ]   && MON_PREV_PUB_ISP="$MON_PUB_ISP"
  [ -n "$MON_VPN_NAME" ]  && MON_PREV_VPN_NAME="$MON_VPN_NAME"
  [ -n "$MON_SSID" ]      && MON_PREV_SSID="$MON_SSID"
  [ -n "$MON_BSSID" ]     && MON_PREV_BSSID="$MON_BSSID"
  [ -n "$MON_INTERFACE" ] && MON_PREV_INTERFACE="$MON_INTERFACE"
  MON_PREV_VPN_ACTIVE="$MON_VPN_ACTIVE"
  local prior rule next_rules="$MON_RULES"
  for prior in $MON_PREV_RULES; do
    case " $MON_CLEARABLE_RULES " in
      *" $prior "*) ;;
      *) case " $next_rules " in
           *" $prior "*) ;;
           *) next_rules="${next_rules}${prior} " ;;
         esac ;;
    esac
  done
  MON_PREV_RULES="$next_rules"
  MON_HAVE_PREV=1
  return 0
}

# ── Emit ─────────────────────────────────────────────────────────────────
# Through python3 rather than bash printf. An SSID may contain a quote, a
# backslash, or a newline, and a JSON-escaping bug in a stream the GUI
# parses forever is a far worse trade than ~50 ms of interpreter startup
# once per cycle. At the 10 s fast cadence that is 0.5% duty.
_mon_emit() {
  # The sibling import (rules_catalog.py) must not write __pycache__ into a
  # sealed app bundle: newer Homebrew pythons do so by default, and inside
  # the signed .app that mutates a resource the signature covers.
  PYTHONDONTWRITEBYTECODE=1 \
  NETDIAG_MON_SCHEMA=2 \
  NETDIAG_MON_VERSION="$NETDIAG_VERSION" \
  NETDIAG_MON_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  NETDIAG_MON_SEQ="$MON_SEQ" \
  NETDIAG_MON_GAP_S="$MON_GAP_S" \
  NETDIAG_MON_REFRESHED="$MON_REFRESHED" \
  NETDIAG_MON_LINK_UP="$MON_LINK_UP" \
  NETDIAG_MON_INTERFACE="$MON_INTERFACE" \
  NETDIAG_MON_IFACE_TYPE="$MON_IFACE_TYPE" \
  NETDIAG_MON_LOCAL_IP="$MON_LOCAL_IP" \
  NETDIAG_MON_GATEWAY="$MON_GATEWAY" \
  NETDIAG_MON_GW_MAC="$MON_GW_MAC" \
  NETDIAG_MON_SSID="$MON_SSID" \
  NETDIAG_MON_BSSID="$MON_BSSID" \
  NETDIAG_MON_NETWORK_ID="$MON_NETWORK_ID" \
  NETDIAG_MON_NETWORK_LABEL="$MON_NETWORK_LABEL" \
  NETDIAG_MON_NETWORK_GROUP="$MON_NETWORK_GROUP" \
  NETDIAG_MON_VPN_ACTIVE="$MON_VPN_ACTIVE" \
  NETDIAG_MON_VPN_TYPE="$MON_VPN_TYPE" \
  NETDIAG_MON_VPN_NAME="$MON_VPN_NAME" \
  NETDIAG_MON_GW_LOSS="$MON_GW_LOSS" \
  NETDIAG_MON_GW_RTT="$MON_GW_RTT" \
  NETDIAG_MON_GW_JITTER="${MON_GW_JITTER:-}" \
  NETDIAG_MON_INET_LOSS="$MON_INET_LOSS" \
  NETDIAG_MON_INET_RTT="$MON_INET_RTT" \
  NETDIAG_MON_INET_JITTER="${MON_INET_JITTER:-}" \
  NETDIAG_MON_WIFI_RSSI="$MON_WIFI_RSSI" \
  NETDIAG_MON_WIFI_NOISE="$MON_WIFI_NOISE" \
  NETDIAG_MON_WIFI_SNR="$MON_WIFI_SNR" \
  NETDIAG_MON_WIFI_CHAN="$MON_WIFI_CHAN" \
  NETDIAG_MON_DNS_OK="$MON_DNS_OK" \
  NETDIAG_MON_DNS_RESOLVER="$MON_DNS_RESOLVER" \
  NETDIAG_MON_DNS_MS="$MON_DNS_MS" \
  NETDIAG_MON_DNS_LOCAL_FAIL="$MON_DNS_LOCAL_FAIL" \
  NETDIAG_MON_DNS_LOCAL_BIND="$MON_DNS_LOCAL_BIND" \
  NETDIAG_MON_DNS_UDP_SOCKETS="$MON_DNS_UDP_SOCKETS" \
  NETDIAG_MON_DNS_UDP_HOLDERS="$MON_DNS_UDP_HOLDERS" \
  NETDIAG_MON_DNS_UDP_TOP_SHARE_PCT="$MON_DNS_UDP_TOP_SHARE_PCT" \
  NETDIAG_MON_DNS_TCP_DNS_OK="$MON_DNS_TCP_DNS_OK" \
  NETDIAG_MON_TCP_OK="$MON_TCP_OK" \
  NETDIAG_MON_TCP_LINES="$MON_TCP_LINES" \
  NETDIAG_MON_WEB_OK="$MON_WEB_OK" \
  NETDIAG_MON_PUBLIC_OK="$MON_PUBLIC_OK" \
  NETDIAG_MON_PUB_IP="$MON_PUB_IP" \
  NETDIAG_MON_PUB_ISP="$MON_PUB_ISP" \
  NETDIAG_MON_PUB_ASN="$MON_PUB_ASN" \
  NETDIAG_MON_PUB_CITY="$MON_PUB_CITY" \
  NETDIAG_MON_PUB_CC="$MON_PUB_CC" \
  NETDIAG_MON_PUB_CC_ISO="$MON_PUB_CC_ISO" \
  NETDIAG_MON_CAPTIVE="$MON_CAPTIVE" \
  NETDIAG_MON_RULES="$MON_RULES" \
  NETDIAG_MON_HOG_REFRESHED="$MON_HOG_REFRESHED" \
  NETDIAG_MON_HOG_OBSERVED_AT="$MON_HOG_OBSERVED_AT" \
  NETDIAG_MON_HOG_APP_NAME="$MON_HOG_APP_NAME" \
  NETDIAG_MON_HOG_APP_BUNDLE="$MON_HOG_APP_BUNDLE" \
  NETDIAG_MON_HOG_PROCESS="$MON_HOG_PROC" \
  NETDIAG_MON_HOG_DIRECTION="$MON_HOG_DIR" \
  NETDIAG_MON_HOG_RATE_MBPS="$MON_HOG_RATE" \
  NETDIAG_MON_HOG_DOMINANCE_PCT="$MON_HOG_DOM_PCT" \
  NETDIAG_MON_HOG_GATEWAY_RTT_MS="$MON_HOG_GW_RTT" \
  NETDIAG_MON_HOG_GATEWAY_JITTER_MS="$MON_HOG_GW_JITTER" \
  NETDIAG_MON_HOG_INTERNET_JITTER_MS="$MON_HOG_INET_JITTER" \
  NETDIAG_MON_CLEARABLE_RULES="$MON_CLEARABLE_RULES" \
  NETDIAG_MON_SEVERITY="$MON_SEVERITY" \
  NETDIAG_MON_MEASUREMENT_STATE="$MON_MEASUREMENT_STATE" \
  NETDIAG_MON_ICMP_FILTERED="$MON_ICMP_FILTERED" \
  NETDIAG_MON_DEGRADED="$MON_DEGRADED" \
  NETDIAG_MON_PAUSED="$MON_PAUSED" \
  NETDIAG_MON_CADENCE_S="$1" \
  NETDIAG_MON_HAVE_PREV="$MON_HAVE_PREV" \
  NETDIAG_MON_PREV_PUB_IP="$MON_PREV_PUB_IP" \
  NETDIAG_MON_PREV_PUB_CC="$MON_PREV_PUB_CC" \
  NETDIAG_MON_PREV_PUB_ISP="$MON_PREV_PUB_ISP" \
  NETDIAG_MON_PREV_VPN_ACTIVE="$MON_PREV_VPN_ACTIVE" \
  NETDIAG_MON_PREV_VPN_NAME="$MON_PREV_VPN_NAME" \
  NETDIAG_MON_PREV_SSID="$MON_PREV_SSID" \
  NETDIAG_MON_PREV_BSSID="$MON_PREV_BSSID" \
  NETDIAG_MON_PREV_INTERFACE="$MON_PREV_INTERFACE" \
  NETDIAG_MON_PREV_RULES="$MON_PREV_RULES" \
  python3 "$HELPERS_DIR/monitor_sample.py"
}

# ── Loop ─────────────────────────────────────────────────────────────────

# ── Sleep and stall detection ────────────────────────────────────────────
#
# The seconds lost between two consecutive cycles, or empty when the
# elapsed time is within tolerance. $1 = elapsed seconds since the
# previous cycle started, $2 = the cadence that cycle was scheduled at.
#
# The header of this file says the monitor stays dumb about sleep and
# leaves it to the GUI's NSWorkspace notifications. That is right for the
# GUI and wrong for every other consumer: `--monitor` is documented as a
# stream for *any* program, and a laptop lid closed for eight hours emits
# two samples eight hours apart with nothing marking the discontinuity.
# A program reading that stream sees an eight-hour outage that never
# happened — the loss and latency figures either side are both fine, and
# the silence between them is indistinguishable from a dead link.
#
# Reports the elapsed time rather than a boolean, because "how long was I
# not looking" is the question a consumer actually has to answer, and it
# is the difference between a hiccup and an overnight sleep.
#
# Pure: no clock reads, no state. Both inputs come from the caller.
_mon_gap_seconds() {
  local elapsed="${1:-}" cadence="${2:-}"
  case "$elapsed" in ''|*[!0-9]*) return 0 ;; esac
  case "$cadence" in ''|*[!0-9]*|0) return 0 ;; esac
  local tolerance=$((cadence * THRESH_MON_GAP_FACTOR))
  # A short cadence must not shrink the tolerance below a legitimate cycle:
  # the probes take as long at a 2 s cadence as at a 10 s one.
  [ "$tolerance" -ge "$THRESH_MON_GAP_MIN_S" ] || tolerance="$THRESH_MON_GAP_MIN_S"
  [ "$elapsed" -gt "$tolerance" ] || return 0
  printf '%s' "$elapsed"
}

# Interruptible sleep. A bare `sleep` swallows the signal until it returns,
# so a GUI sending SIGTERM would wait up to a full cadence for the process
# to die; backgrounding it and waiting makes the trap fire immediately.
_mon_sleep() {
  if [ "$MON_REFRESH_REQUESTED" -eq 1 ]; then
    MON_REFRESH_REQUESTED=0
    return 0
  fi
  sleep "$1" &
  wait $! 2>/dev/null || true
}

# All three are reached via trap, an indirect dispatch static analysis
# can't follow.
# shellcheck disable=SC2317,SC2329
_mon_on_signal() { MON_STOP=1; }
# shellcheck disable=SC2317,SC2329
_mon_on_pause()  { MON_PAUSED=1; }
# shellcheck disable=SC2317,SC2329
_mon_on_resume() {
  MON_PAUSED=0
  # A scan or sleep can outlast cached DNS/TCP/radio/public evidence.
  # Refresh every tier before the first post-pause sample is accepted.
  MON_REFRESH_REQUESTED=1
}
# shellcheck disable=SC2317,SC2329
_mon_on_refresh() { MON_REFRESH_REQUESTED=1; }

monitor_run() {
  local now next_fast=0 next_medium=0 next_slow=0 cadence
  local prev_network_id="" network_changed announced_pause=0
  local link_was_down=0 link_restored
  # Identity-adjacent state last seen by the fast tier, to notice a VPN
  # toggle or a roam. Empty until first observed, so the first cycle (which
  # runs every tier anyway) never counts as a change.
  local seen_vpn_active="" seen_vpn_name="" seen_bssid="" vpn_changed roamed
  MON_BROWSER_DESYNC_COUNT=0
  # Captured once: bash never updates PPID, so this is the pid of whoever
  # started us and stays that way even after re-parenting.
  local parent_pid="$PPID"
  trap _mon_on_signal INT TERM
  trap _mon_on_pause  USR1
  trap _mon_on_resume USR2
  # The GUI uses SIGALRM as a cheap "sample now" nudge after a network
  # transition. Bash's default action is to terminate the monitor, so this
  # must stay an explicit, harmless flag rather than an untrapped signal.
  trap _mon_on_refresh ALRM

  while :; do
    [ "$MON_STOP" -eq 0 ] || break

    # A refresh request interrupts the remainder of the cadence. The signal
    # is intentionally handled between cycles: a probe already in flight
    # must finish and be emitted as a coherent sample before the next one.
    if [ "$MON_REFRESH_REQUESTED" -eq 1 ]; then
      MON_REFRESH_REQUESTED=0
      next_fast=0
      next_medium=0
      next_slow=0
    fi
    # Checked even while paused — a paused monitor whose consumer died is
    # exactly as orphaned as a running one, and rather harder to notice.
    # A parent of MON_INIT_PID means we were started by launchd, or were
    # already orphaned before the loop began; either way there is no
    # meaningful parent left to watch.
    if [ "$parent_pid" -gt "$MON_INIT_PID" ] && ! kill -0 "$parent_pid" 2>/dev/null; then
      break
    fi

    # Paused: probe nothing, emit nothing, but stay alive and responsive.
    # One sample announces the pause so a consumer — or a person watching
    # the stream in a terminal — sees why it went quiet, rather than being
    # left to wonder whether the process died.
    if [ "$MON_PAUSED" -eq 1 ]; then
      if [ "$announced_pause" -eq 0 ]; then
        announced_pause=1
        MON_REFRESHED=""
        # Nothing was measured, so there is no gap to report. Left alone
        # this re-emitted the previous cycle's gap_s, already reported once
        # by the cycle that saw it.
        MON_GAP_S=""
        MON_SEQ=$((MON_SEQ + 1))
        _mon_emit "$MONITOR_FAST_INTERVAL" || break
        _mon_snapshot_prev
      fi
      # One second at a time so SIGUSR2 resumes promptly. The trap fires
      # during _mon_sleep's `wait`, so the real latency is immediate; this
      # bound only covers the gap between iterations.
      _mon_sleep 1
      continue
    fi
    announced_pause=0

    now="$EPOCHSECONDS"
    # How long since the previous cycle began, against what that cycle was
    # scheduled for. Computed here rather than after the probes so it
    # excludes the time *this* cycle's own work is about to take. It does
    # include the previous cycle's work (it is start-to-start), which is why
    # _mon_gap_seconds has a floor rather than a pure multiple of the
    # cadence: measuring from the end of the previous cycle instead would
    # miss a sleep that began mid-probe.
    MON_GAP_S=""
    if [ -n "$MON_PREV_CYCLE_TS" ] && [ -n "$MON_PREV_CADENCE" ]; then
      MON_GAP_S="$(_mon_gap_seconds \
        "$((now - MON_PREV_CYCLE_TS))" "$MON_PREV_CADENCE")"
    fi
    MON_REFRESHED=""
    MON_MEDIUM_FRESH=0
    link_restored=0
    vpn_changed=0
    roamed=0
    network_changed=0

    # Fast tier drives everything: it establishes whether there is a link
    # at all, and the identity the other tiers are scoped to.
    if [ "$now" -ge "$next_fast" ]; then
      MON_REFRESHED+="fast "
      _mon_probe_link
      if [ "$MON_NETWORK_ID" != "$prev_network_id" ]; then
        network_changed=1
        prev_network_id="$MON_NETWORK_ID"
        # Reset before probing: the first packets on this connection must
        # not be folded into the previous network's rolling windows.
        _mon_loss_reset
        MON_GW_LOSS_STREAK=0 MON_INET_LOSS_STREAK=0
        _mon_conn_reset
        _mon_hog_reset
      fi
      _mon_probe_vpn
      # A VPN toggle moves the public IP/ISP/country, and the DNS and TCP
      # paths with it; a roam moves RSSI, noise and channel. Left to the
      # timers those readings stay the old ones for up to 300 s / 60 s, so
      # either change pulls the tiers that own them forward. Compared against
      # the last *known* value only (a link-down cycle reads an empty BSSID
      # and must not look like a roam), and nothing extra runs when nothing
      # changed.
      if [ -n "$seen_vpn_active" ] \
         && { [ "$MON_VPN_ACTIVE" != "$seen_vpn_active" ] \
              || [ "$MON_VPN_NAME" != "$seen_vpn_name" ]; }; then
        vpn_changed=1
      fi
      seen_vpn_active="$MON_VPN_ACTIVE"; seen_vpn_name="$MON_VPN_NAME"
      if [ -n "$MON_BSSID" ]; then
        # Same network only: a different network already forces the tiers
        # through network_changed, and its first BSSID is not a roam.
        if [ -n "$seen_bssid" ] && [ "$MON_BSSID" != "$seen_bssid" ] \
           && [ "$MON_NETWORK_ID" = "$prev_network_id" ]; then
          roamed=1
        fi
        seen_bssid="$MON_BSSID"
      fi
      if [ "$MON_LINK_UP" -eq 1 ]; then
        # The cycle after a drop starts with every medium/slow reading
        # cleared (_mon_clear_measurements); refill them now rather than
        # leaving DNS, TCP, Wi-Fi signal and the public identity blank until
        # their timers next come due. Same-network recoveries need this
        # explicitly: network_changed below only fires when the id moved.
        [ "$link_was_down" -eq 1 ] && link_restored=1
        link_was_down=0
        _mon_probe_gateway
        _mon_probe_internet
        _mon_probe_web
      else
        link_was_down=1
        # No link, no valid window: every packet in it predates the drop.
        _mon_loss_reset
      fi
    fi

    # A dead link means nothing to probe. Skipping the other tiers here is
    # the monitor's only power decision, and it is about pointlessness
    # rather than battery: a DNS query with no default route cannot
    # succeed, it can only cost four seconds of timeout per cycle.
    if [ "$MON_LINK_UP" -eq 1 ]; then
      if [ "$now" -ge "$next_medium" ] || [ "$network_changed" -eq 1 ] \
         || [ "$link_restored" -eq 1 ] || [ "$vpn_changed" -eq 1 ] \
         || [ "$roamed" -eq 1 ]; then
        MON_REFRESHED+="medium "
        _mon_probe_dns
        _mon_probe_tcp
        MON_MEDIUM_FRESH=1
        _mon_probe_wifi_signal
        _mon_probe_browser
        next_medium=$((now + MONITOR_MEDIUM_INTERVAL))
      fi
      # The slow tier is the only external call, so it is the only one
      # where being polite matters — but a network change is exactly when
      # its answer has certainly gone stale, so that overrides the timer.
      if [ "$now" -ge "$next_slow" ] || [ "$network_changed" -eq 1 ] \
         || [ "$link_restored" -eq 1 ] || [ "$vpn_changed" -eq 1 ]; then
        MON_REFRESHED+="slow "
        _mon_probe_public
        next_slow=$((now + MONITOR_SLOW_INTERVAL))
      fi
    fi

    # ── Freshness on internet-side loss ───────────────────────────────────
    # The fast tier pings the internet every cycle; the TCP and public
    # probes run on the medium (60 s) and slow (300 s) tiers and are
    # carried over stale between refreshes. A real internet outage —
    # gateway quiet, internet ping at critical loss — therefore reads, for
    # up to a minute, exactly like an ICMP-filtering hotel network: TCP and
    # public still "ok" from before the drop, so _mon_rules concludes
    # ICMP-1 (info) instead of L1 (critical), severity stays info, the
    # menu-bar dot stays green, and no connection-lost alert fires. A
    # manual scan is the only thing that forces fresh probes — which is why
    # alerts appeared only after the user pressed "Check My Connection".
    #
    # Forcing a fresh TCP probe the moment the fast tier sees the outage
    # breaks that stale-data lock within one cycle. If TCP now fails too,
    # _mon_rules names L1 (critical), degraded engages, and the fast tier
    # drops to its 5 s cadence for the duration of the outage. Public is
    # forced the same way so P1/P2 (which gate on MON_PUBLIC_OK) do not sit
    # behind the 300 s slow timer either. Gated on the tier not having
    # already run this cycle, so a cycle that hit the medium/slow timers on
    # its own pays nothing extra, and during a sustained outage the forced
    # path fires only on cycles the scheduled tiers skipped.
    if [ "$MON_LINK_UP" -eq 1 ] \
       && loss_at_least "$MON_INET_LOSS" "$LOSS_CRIT_PCT" \
       && loss_below "$MON_GW_LOSS" "$LOSS_WARN_PCT"; then
      if ! printf '%s' "$MON_REFRESHED" | grep -qw medium; then
        MON_REFRESHED+="medium "
        _mon_probe_tcp
        next_medium=$((now + MONITOR_MEDIUM_INTERVAL))
      fi
      if ! printf '%s' "$MON_REFRESHED" | grep -qw slow; then
        MON_REFRESHED+="slow "
        _mon_probe_public
        next_slow=$((now + MONITOR_SLOW_INTERVAL))
      fi
    fi

    _mon_probe_hog
    _mon_rules
    # A failure still waiting for its confirmation is re-probed next cycle
    # rather than after the rest of the 60 s medium interval.
    if [ "$MON_CONN_PENDING" -eq 1 ]; then next_medium=0; fi

    cadence="$MONITOR_FAST_INTERVAL"
    [ "$MON_DEGRADED" -eq 1 ] && cadence="$MONITOR_DEGRADED_INTERVAL"
    next_fast=$((now + cadence))

    MON_SEQ=$((MON_SEQ + 1))
    MON_PREV_CYCLE_TS="$now"
    MON_PREV_CADENCE="$cadence"
    # A failed emit means stdout is gone — the GUI exited, or a `| head -5`
    # closed the pipe. Either way there is no one left to talk to.
    _mon_emit "$cadence" || break
    _mon_snapshot_prev

    if [ "$MONITOR_COUNT" -gt 0 ] && [ "$MON_SEQ" -ge "$MONITOR_COUNT" ]; then
      break
    fi
    [ "$MON_STOP" -eq 0 ] || break

    # Sleep only the remainder: the probes themselves take 2-6 s, and
    # sleeping a full interval on top would make the real cadence drift
    # well past what the app's Settings slider claims.
    # Enforce a minimal rest pause (1-2s) so we never hammer the interface
    # in an unthrottled back-to-back loop when probes run close to the cadence.
    local spent remain min_rest=2
    spent=$((EPOCHSECONDS - now))
    remain=$((cadence - spent))
    [ "$cadence" -le 2 ] && min_rest=1
    [ "$remain" -lt "$min_rest" ] && remain="$min_rest"
    _mon_sleep "$remain"
  done
  return 0
}
