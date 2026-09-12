# shellcheck shell=bash
# lib/wifi_common.sh — WiFi scrapes shared by the scanner (lib/wifi.sh) and
# the live monitor (lib/monitor.sh).
#
# Why this file exists: the same three awk pipelines (hardware-port lookup,
# `ipconfig getsummary` SSID/BSSID, `wdutil info` field scrape) were
# copy-pasted into both files and had already started to drift in style if
# not yet in behaviour. One parser per upstream format means a macOS
# release that moves a label is fixed once, and the scan and the live dot
# cannot disagree about what the tool said.
#
# Every function takes its input as $1 (or an optional pre-read $2) rather
# than re-running the subprocess, so callers keep control of caching: the
# monitor reads networksetup once for the life of the process, a scan reads
# it per run.
#
# Sourced by lib/wifi.sh and lib/monitor.sh. Depends on nothing.

# The hardware-port name for a network device ("Wi-Fi", "Ethernet", …).
# $1 = device (en0), $2 = optional pre-read `networksetup -listallhardwareports`
# output. Prints "" when the device is unknown.
wifi_hw_port_for_device() {
  local d="$1" ports="${2:-}"
  if [ -z "$ports" ]; then
    ports="$(networksetup -listallhardwareports 2>/dev/null || true)"
  fi
  printf '%s\n' "$ports" | awk -v d="$d" '
    /^Hardware Port:/{port=substr($0, index($0,$3))}
    /^Device:/{if($2==d){print port; exit}}'
}

# True when the hardware-port name is a wireless one.
wifi_port_is_wireless() {
  printf '%s' "$1" | grep -qi 'Wi-Fi\|AirPort'
}

# SSID / BSSID / Security from `ipconfig getsummary <iface>` output ($1).
# Prints them TAB-separated; any field may be empty. No trimming: the
# ipconfig values are used verbatim everywhere today.
wifi_parse_ipconfig_summary() {
  printf '%s\n' "$1" | awk -F': ' '
    /^[[:space:]]*SSID[[:space:]]*:/     {ssid=$2}
    /^[[:space:]]*BSSID[[:space:]]*:/    {bssid=$2}
    /^[[:space:]]*Security[[:space:]]*:/ {sec=$2}
    END{printf "%s\t%s\t%s\n", ssid, bssid, sec}'
}

# The network's name and where it came from, TAB-separated.
#
# $1 = the SSID this process managed to read ("" or "<redacted>" when
#      macOS withheld it), $2 = the optional NETDIAG_SSID_HINT a calling
#      app supplied.
#
# Prints "<ssid>\t<source>" where source is "system" (measured here),
# "caller" (taken from the hint) or "" (no name at all, and the SSID
# field is whatever the caller should keep displaying).
#
# A measured value always wins over a supplied one, even though the hint
# is usually the better data: the point of `ssid_source` is that a stored
# run can say which it was, and that only means anything if the
# precedence is fixed rather than "whichever looked nicer".
#
# Here rather than inline in lib/wifi.sh so it can be tested without a
# radio — the rest of wifi_run is unmockable subprocess output.
wifi_resolve_ssid() {
  local measured="$1" hint="${2:-}"
  if [ -n "$measured" ] && [ "$measured" != "<redacted>" ]; then
    printf '%s\t%s\n' "$measured" "system"
  elif [ -n "$hint" ] && [ "$hint" != "<redacted>" ]; then
    printf '%s\t%s\n' "$hint" "caller"
  else
    printf '%s\t%s\n' "$measured" ""
  fi
}

# Fields from `sudo wdutil info` output ($1). Prints seven TAB-separated
# fields: rssi, noise, channel, tx_rate, phy, ssid, bssid — any of which
# may be empty. RSSI/noise come back as bare numbers ("−55", not "−55 dBm").
# wdutil's SSID/BSSID arrive "<redacted>" without Location Services; the
# raw value is passed through so the caller applies its own policy (the
# scanner overrides only on a real value, the monitor ignores the field).
wifi_parse_wdutil() {
  printf '%s\n' "$1" | awk -F': ' '
    /^[[:space:]]*SSID[[:space:]]*:/ {
      v=$2; gsub(/^[[:space:]]+|[[:space:]]+$/,"",v); ssid=v }
    /^[[:space:]]*BSSID[[:space:]]*:/ {
      v=$2; gsub(/^[[:space:]]+|[[:space:]]+$/,"",v); bssid=v }
    /^[[:space:]]*RSSI[[:space:]]*:/ {
      v=$2; gsub(/[[:space:]]*dBm/,"",v); rssi=v }
    /^[[:space:]]*Noise[[:space:]]*:/ {
      v=$2; gsub(/[[:space:]]*dBm/,"",v); noise=v }
    /^[[:space:]]*Channel[[:space:]]*:/ {chan=$2}
    /Tx Rate/ {tx=$2}
    /PHY Mode/{phy=$2}
    END{printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
        rssi, noise, chan, tx, phy, ssid, bssid}'
}

# Multi-AP detection and candidate access point scrape from `system_profiler SPAirPortDataType`.
# $1 = system_profiler output, $2 = target SSID, $3 = current BSSID (optional).
# Prints 4 TAB-separated fields:
#   multi_ap (1 or 0), candidate_bssid, candidate_rssi, candidate_ssid
# Candidate is chosen as the AP on the same SSID (with different BSSID) with the highest RSSI.
wifi_parse_candidates() {
  local sp="$1" target="$2" cur_bssid="${3:-}"
  printf '%s\n' "$sp" | awk -v target="$target" -v cur_bssid="$cur_bssid" '
    BEGIN {
      in_other = 0; cur_ssid = ""; cur_bssid_entry = ""; cur_rssi = ""
      best_rssi = -999; best_bssid = ""; best_ssid = ""; multi_ap = 0
    }
    function flush_entry() {
      if (in_other && cur_ssid != "") {
        if (target != "" && target != "<redacted>" && cur_ssid == target) {
          if (cur_bssid_entry == "" || cur_bssid == "" || tolower(cur_bssid_entry) != tolower(cur_bssid)) {
            multi_ap = 1
            if (cur_rssi != "" && cur_rssi ~ /^-?[0-9]+$/) {
              if (cur_rssi + 0 > best_rssi) {
                best_rssi = cur_rssi + 0
                best_bssid = cur_bssid_entry
                best_ssid = cur_ssid
              }
            }
          }
        }
      }
      cur_ssid = ""; cur_bssid_entry = ""; cur_rssi = ""
    }
    /Current Network Information:/ { flush_entry(); in_other = 0; next }
    /Other Local Wi-Fi Networks:/   { flush_entry(); in_other = 1; next }
    /^[[:space:]]{0,10}[A-Za-z0-9]/ && in_other {
      flush_entry(); in_other = 0; next
    }
    in_other && /^[[:space:]]{12}[^[:space:]]/ {
      flush_entry()
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sub(/:[[:space:]]*$/, "", line)
      cur_ssid = line
      next
    }
    in_other && cur_ssid != "" {
      if ($0 ~ /^[[:space:]]+(BSSID|MAC Address):[[:space:]]*/) {
        line = $0
        sub(/^[[:space:]]+(BSSID|MAC Address):[[:space:]]*/, "", line)
        sub(/[[:space:]]+$/, "", line)
        cur_bssid_entry = line
      } else if ($0 ~ /^[[:space:]]+Signal[[:space:]]*\/[[:space:]]*Noise:[[:space:]]*/) {
        line = $0
        sub(/^[[:space:]]+Signal[[:space:]]*\/[[:space:]]*Noise:[[:space:]]*/, "", line)
        if (match(line, /-?[0-9]+/)) {
          cur_rssi = substr(line, RSTART, RLENGTH)
        }
      } else if ($0 ~ /^[[:space:]]+(Signal|RSSI):[[:space:]]*/) {
        line = $0
        sub(/^[[:space:]]+(Signal|RSSI):[[:space:]]*/, "", line)
        if (match(line, /-?[0-9]+/)) {
          cur_rssi = substr(line, RSTART, RLENGTH)
        }
      }
    }
    END {
      flush_entry()
      cand_rssi_str = (best_rssi > -999) ? best_rssi "" : ""
      printf "%d\t%s\t%s\t%s\n", multi_ap, best_bssid, cand_rssi_str, best_ssid
    }
  '
}

