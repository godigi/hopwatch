# shellcheck shell=bash
# lib/public.sh — public reach via ifconfig.co, captive-portal sniff,
# optional TARGET-specific ping.
#
# Reads:  TARGET
# Writes: PUBLIC_OK, PUB_IP, PUB_ASN, PUB_ISP, PUB_CITY, PUB_CC,
#         CAPTIVE_PORTAL, CAPTIVE_PORTAL_CODE, TARGET_PING_LOSS,
#         TARGET_PING_RTT
# Entry:  public_run

# Writes PUBLIC_OK, PUB_*, CAPTIVE_PORTAL, TARGET_PING_* — all read in
# diagnosis.sh / output.sh / emit_json.py.
# shellcheck disable=SC2034
public_run() {
  hdr "Public reachability"
  PUBLIC_CHECKED=1
  local pub_out
  pub_out="$(curl -4 -s -m 4 https://ifconfig.co/json 2>/dev/null || curl -s -m 4 https://ifconfig.co/json 2>/dev/null)"
  if [ -n "$pub_out" ]; then
    PUB_IP="" PUB_ISP="" PUB_ASN="" PUB_CITY="" PUB_CC="" PUB_CC_ISO=""
    [[ "$pub_out" =~ \"ip\":[[:space:]]*\"([^\"]*)\" ]] && PUB_IP="${BASH_REMATCH[1]}"
    [[ "$pub_out" =~ \"asn_org\":[[:space:]]*\"([^\"]*)\" ]] && PUB_ISP="${BASH_REMATCH[1]}"
    [[ "$pub_out" =~ \"asn\":[[:space:]]*\"([^\"]*)\" ]] && PUB_ASN="${BASH_REMATCH[1]}"
    [[ "$pub_out" =~ \"city\":[[:space:]]*\"([^\"]*)\" ]] && PUB_CITY="${BASH_REMATCH[1]}"
    [[ "$pub_out" =~ \"country\":[[:space:]]*\"([^\"]*)\" ]] && PUB_CC="${BASH_REMATCH[1]}"
    # ifconfig.co's "country" is the full name ("Brazil"); the ISO-3166
    # alpha-2 lives in a separate key. Both are kept because they answer
    # different questions: the name is what a report should read, the code
    # is what a consumer maps to a flag or a locale. Deriving one from the
    # other would mean shipping a country table in every consumer.
    [[ "$pub_out" =~ \"country_iso\":[[:space:]]*\"([^\"]*)\" ]] && PUB_CC_ISO="${BASH_REMATCH[1]}"
    if [ -n "$PUB_IP" ]; then
      PUBLIC_OK=1
      ok "Public IP: $PUB_IP  ($PUB_ISP, $PUB_CITY ${PUB_CC_ISO:-$PUB_CC})"
    else
      PUBLIC_OK=0
      warn "Could not parse public IP from response."
    fi
  else
    PUBLIC_OK=0
    warn "Could not reach ifconfig.co — public IP and ISP metadata are unavailable."
  fi

  # Captive portal sniff. The body is captured, not discarded: a portal
  # answering 200 with its login page is the common case and is invisible
  # in the status alone — see captive_portal_classify in lib/common.sh.
  # No -L: a followed redirect lands on the portal's own 200 and erases
  # the evidence.
  local captive_raw captive_code captive_body captive_url=""
  captive_raw="$(curl -s -m 3 -w $'\n__METADATA__\n%{http_code}\n%{redirect_url}\n' \
    "$CAPTIVE_CANARY_URL" 2>/dev/null || true)"
  captive_body="${captive_raw%%$'\n'__METADATA__*}"
  local captive_meta="${captive_raw##*$'\n'__METADATA__$'\n'}"
  { read -r captive_code || true; read -r captive_url || true; } <<< "$captive_meta"
  # One classifier shared with the live monitor — see lib/common.sh — so a
  # scan and a between-scans sample cannot disagree about what the answer
  # means. A probe that never answered classifies "unknown" and stays
  # silent here: silence beats a guess.
  case "$(captive_portal_classify "$captive_code" "$captive_body")" in
    ok)
      PUBLIC_OK=1
      CAPTIVE_PORTAL=0
      CAPTIVE_PORTAL_URL=""
      ok "No captive portal."
      ;;
    portal)
      CAPTIVE_PORTAL=1
      CAPTIVE_PORTAL_CODE="$captive_code"
      CAPTIVE_PORTAL_URL="${captive_url:-}"
      warn "Captive portal detected (HTTP $captive_code) — log in via browser."
      ;;
    *)
      # Primary canary probe failed (unknown) — often due to custom DNS blocking resolution.
      # Fallback 1: Resolve canary host via DHCP-provided DNS server or gateway
      local dhcp_dns=""
      if [ -n "${INTERFACE:-}" ]; then
        dhcp_dns="$(ipconfig getoption "$INTERFACE" domain_name_server 2>/dev/null | awk '{print $1; exit}' || true)"
      fi
      [ -n "$dhcp_dns" ] || dhcp_dns="${GATEWAY:-}"
      local resolved_ip=""
      if [ -n "$dhcp_dns" ] && type dig >/dev/null 2>&1; then
        resolved_ip="$(dig @"$dhcp_dns" +short +time=1 "$CAPTIVE_CANARY_HOST" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1 || true)"
      fi
      if [ -n "$resolved_ip" ]; then
        local fb_raw fb_body fb_meta fb_code fb_url
        fb_raw="$(curl -s -m 3 -w $'\n__METADATA__\n%{http_code}\n%{redirect_url}\n' \
          --resolve "$CAPTIVE_CANARY_HOST:80:$resolved_ip" "$CAPTIVE_CANARY_URL" 2>/dev/null || true)"
        fb_body="${fb_raw%%$'\n'__METADATA__*}"
        fb_meta="${fb_raw##*$'\n'__METADATA__$'\n'}"
        { read -r fb_code || true; read -r fb_url || true; } <<< "$fb_meta"
        case "$(captive_portal_classify "$fb_code" "$fb_body")" in
          ok)
            PUBLIC_OK=1
            CAPTIVE_PORTAL=0
            CAPTIVE_PORTAL_URL=""
            ok "No captive portal."
            ;;
          portal)
            CAPTIVE_PORTAL=1
            CAPTIVE_PORTAL_CODE="$fb_code"
            CAPTIVE_PORTAL_URL="${fb_url:-}"
            warn "Captive portal detected (HTTP $fb_code) — log in via browser."
            ;;
        esac
      fi

      # Fallback 2: Check macOS DynamicStore CaptiveNetwork state
      if [ "${CAPTIVE_PORTAL:-0}" -eq 0 ] && [ -n "${INTERFACE:-}" ]; then
        local sc_out
        sc_out="$(echo "get State:/Network/Interface/$INTERFACE/CaptiveNetwork"$'\n'"d.show" | scutil 2>/dev/null || true)"
        if [[ "$sc_out" =~ Stage[[:space:]]*:[[:space:]]*(Captive|Redirect|Probe) ]] || [[ "$sc_out" =~ WaitingOnUI[[:space:]]*:[[:space:]]*(TRUE|1) ]]; then
          CAPTIVE_PORTAL=1
          CAPTIVE_PORTAL_CODE="CNA"
          [ -z "$CAPTIVE_PORTAL_URL" ] && [ -n "${GATEWAY:-}" ] && CAPTIVE_PORTAL_URL="http://${GATEWAY}"
          warn "Captive portal detected (macOS Captive Network Assistant) — log in via browser."
        fi
      fi

      # Fallback 3: Probe gateway on port 80 directly (no DNS needed)
      if [ "${CAPTIVE_PORTAL:-0}" -eq 0 ] && [ -n "${GATEWAY:-}" ]; then
        local gw_raw gw_code gw_url gw_body
        gw_raw="$(curl -s -m 2 -w $'\n__METADATA__\n%{http_code}\n%{redirect_url}\n' "http://${GATEWAY}/" 2>/dev/null || true)"
        gw_body="${gw_raw%%$'\n'__METADATA__*}"
        local gw_meta="${gw_raw##*$'\n'__METADATA__$'\n'}"
        { read -r gw_code || true; read -r gw_url || true; } <<< "$gw_meta"
        if [ "$gw_code" = "302" ] || [ "$gw_code" = "307" ] || [ "$gw_code" = "511" ]; then
          CAPTIVE_PORTAL=1
          CAPTIVE_PORTAL_CODE="$gw_code"
          CAPTIVE_PORTAL_URL="${gw_url:-http://${GATEWAY}}"
          warn "Captive portal detected (HTTP $gw_code) — log in via browser."
        elif [ "$gw_code" = "200" ] && printf '%s' "$gw_body" | grep -qiE '(captive|portal|guest|login|sign[ -]?in|password)'; then
          CAPTIVE_PORTAL=1
          CAPTIVE_PORTAL_CODE="200"
          CAPTIVE_PORTAL_URL="${gw_url:-http://${GATEWAY}}"
          warn "Captive portal detected (HTTP 200) — log in via browser."
        fi
      fi
      ;;
  esac

  if [ "${CAPTIVE_PORTAL:-0}" -eq 1 ]; then
    PUBLIC_OK=0
  fi

  # TARGET-specific ping for "this site is slow" investigations.
  if [ -n "$TARGET" ]; then
    local tp_out
    # As elsewhere, macOS ping's -t is a deadline for the entire probe. Use
    # the shared outer timeout so the target probe sends all five packets.
    tp_out="$(with_timeout 8 ping -c 5 -i 0.2 -W "$PING_REPLY_WAIT_MS" "$TARGET" 2>/dev/null || true)"
    local tp_parsed
    tp_parsed="$(ping_parse_summary "$tp_out")"
    IFS='|' read -r TARGET_PING_LOSS TARGET_PING_RTT _ <<<"$tp_parsed"
    if [ -n "$TARGET_PING_RTT" ]; then
      ok "ping $TARGET: ${TARGET_PING_LOSS:-?}% loss, ${TARGET_PING_RTT} ms avg"
    else
      bad "ping $TARGET: no reply"
    fi
  fi
}
