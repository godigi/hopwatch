#!/usr/bin/env python3
"""
End-to-end Hopwatch live-network simulation and visual screenshot audit.

Runs two stages without touching the user's real preferences or live network:
  1. CLI simulation: executes lib/monitor.sh (_mon_rules) and
     helpers/monitor_sample.py over chronological network transitions
     (healthy -> single-resolver burst rate limit + high router jitter ->
     critical packet loss L1 -> moderate L2 -> recovered) and checks all
     numeric, rule, and wording invariants.
  2. GUI visual audit: copies Hopwatch.app to an isolated temp bundle
     with a unique CFBundleIdentifier and synthetic CFFIXED_USER_HOME, runs
     HopwatchGUI --visual-audit=<out_dir> across 15 network states/transitions,
     generates an HTML contact sheet (index.html), and fails non-zero if
     any invariant fails.
"""

from __future__ import annotations

import argparse
import html
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP_BUNDLE = ROOT / "gui" / "build" / "Hopwatch.app"
DEFAULT_OUT = ROOT / "gui" / "build" / "visual-audit"


def run_cli_simulation() -> list[str]:
    failures: list[str] = []
    bash_script = r'''
set -euo pipefail
REPO="$1"
JSON_MODE=0 QUIET=0 QUICK=0 EXPERT=0 REDACT=0 LOG=/dev/null NETDIAG_VERSION="audit"
. "$REPO/lib/thresholds.sh"
. "$REPO/lib/common.sh"
. "$REPO/lib/globals.sh"
. "$REPO/lib/netid.sh"
. "$REPO/lib/traffic.sh"
. "$REPO/lib/monitor.sh"

reset_case() {
  MON_GW_LOSS="" MON_GW_RTT="" MON_GW_JITTER=""
  MON_INET_LOSS="" MON_INET_LOSS_ALT="" MON_INET_RTT="" MON_INET_JITTER=""
  MON_WEB_OK="" MON_DNS_OK="" MON_DNS_MS="" MON_DNS_LOCAL_FAIL=0 MON_DNS_TCP_DNS_OK=""
  MON_TCP_OK="" MON_CAPTIVE="" MON_VPN_ACTIVE=0
  MON_WIFI_RSSI="" MON_WIFI_NOISE="" MON_WIFI_SNR=""
  MON_RULES="" MON_PREV_RULES="" MON_CLEARABLE_RULES="" MON_SEVERITY="ok"
  MON_ICMP_FILTERED=0 MON_DEGRADED=0 MON_CADENCE_S=12
  MON_GW_LOSS_STREAK=0 MON_INET_LOSS_STREAK=0 MON_DNS_STREAK=0 MON_WEB_STREAK=0 MON_GW_RTT_STREAK=0
  MON_LINK_UP=1 MON_MEASUREMENT_STATE="measured" MON_BROWSER_DESYNC=0
  MON_DNS_FILTERED=0 MON_ISP_THROTTLE=0
}

emit_json() {
  NETDIAG_MON_SEQ="${1}" \
  NETDIAG_MON_TS="2026-11-14T11:43:00Z" \
  NETDIAG_MON_NET_ID="mac:aa:bb:cc:dd:ee:01" \
  NETDIAG_MON_NET_LABEL="L2 2808" \
  NETDIAG_MON_LINK_UP="$MON_LINK_UP" \
  NETDIAG_MON_LINK_TYPE="wifi" \
  NETDIAG_MON_SSID="L2 2808" \
  NETDIAG_MON_GW="192.168.1.1" \
  NETDIAG_MON_GW_LOSS="$MON_GW_LOSS" \
  NETDIAG_MON_GW_RTT="$MON_GW_RTT" \
  NETDIAG_MON_GW_JITTER="$MON_GW_JITTER" \
  NETDIAG_MON_INET_LOSS="$MON_INET_LOSS" \
  NETDIAG_MON_INET_LOSS_ALT="$MON_INET_LOSS_ALT" \
  NETDIAG_MON_INET_RTT="$MON_INET_RTT" \
  NETDIAG_MON_INET_JITTER="$MON_INET_JITTER" \
  NETDIAG_MON_LOSS_CRIT_PCT="$LOSS_CRIT_PCT" \
  NETDIAG_MON_DNS_OK="${MON_DNS_OK:-1}" \
  NETDIAG_MON_TCP_OK="${MON_TCP_OK:-1}" \
  NETDIAG_MON_SEVERITY="$MON_SEVERITY" \
  NETDIAG_MON_MEASUREMENT="$MON_MEASUREMENT_STATE" \
  NETDIAG_MON_RULES="$MON_RULES" \
  NETDIAG_MON_CADENCE="$MON_CADENCE_S" \
  NETDIAG_MON_REASONS="fast,medium,slow" \
  python3 "$REPO/helpers/monitor_sample.py"
}

reset_case
# Cycle 1: Healthy
MON_GW_LOSS=0 MON_GW_RTT=5 MON_GW_JITTER=1 MON_INET_LOSS=0 MON_INET_LOSS_ALT=0 MON_INET_RTT=18 MON_INET_JITTER=2 MON_TCP_OK=1 MON_DNS_OK=1
_mon_rules
emit_json 1

# Cycle 2-3: Screenshot 1 artifact (1.1.1.1 burst 94% vs 8.8.8.8 5% + GW jitter 61ms)
MON_PREV_RULES="$MON_RULES"
MON_GW_LOSS=0 MON_GW_RTT=91 MON_GW_JITTER=61 MON_INET_LOSS=94 MON_INET_LOSS_ALT=5 MON_INET_RTT=60 MON_INET_JITTER=24
_mon_rules
MON_PREV_RULES="$MON_RULES"
_mon_rules
emit_json 2

# Cycle 4: True critical outage L1
MON_PREV_RULES="$MON_RULES"
MON_GW_LOSS=0 MON_GW_RTT=110 MON_GW_JITTER=65 MON_INET_LOSS=35 MON_INET_LOSS_ALT=32 MON_INET_RTT=135 MON_INET_JITTER=55
_mon_rules
emit_json 3

# Cycle 5: Critical -> moderate recovery (L1 -> L2 with no ok blind spot)
MON_PREV_RULES="$MON_RULES"
MON_GW_LOSS=0 MON_GW_RTT=22 MON_GW_JITTER=8 MON_INET_LOSS=10 MON_INET_LOSS_ALT=9 MON_INET_RTT=44 MON_INET_JITTER=11
_mon_rules
emit_json 4
'''
    proc = subprocess.run(
        ["bash", "-c", bash_script, "_", str(ROOT)],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        return [f"CLI simulation failed (rc={proc.returncode}): {proc.stderr.strip()}"]

    lines = [json.loads(line) for line in proc.stdout.strip().splitlines() if line.strip()]
    if len(lines) != 4:
        return [f"Expected 4 CLI simulation samples, got {len(lines)}"]

    s1, s2, s3, s4 = lines
    checks = [
        ("CLI cycle 1 healthy", s1["status"]["severity"] == "ok" and s1["internet"]["loss_pct"] == 0.0),
        ("CLI cycle 2 single-resolver 94% vs 5% filtered to 5.0%", s2["internet"]["loss_pct"] == 5.0),
        ("CLI cycle 2 top jitter_ms picks max(gw=61, inet=24) == 61.0", s2["jitter_ms"] == 61.0),
        ("CLI cycle 2 fires L2 (warn)", "L2" in s2["status"]["rules"] and s2["status"]["severity"] == "warn"),
        ("CLI cycle 3 critical loss agreed by both resolvers fires L1 (35.0%)", "L1" in s3["status"]["rules"] and s3["internet"]["loss_pct"] == 35.0 and s3["status"]["severity"] == "critical"),
        ("CLI cycle 4 critical->moderate transitions L1 -> L2 without ok blind spot", "L2" in s4["status"]["rules"] and s4["status"]["severity"] == "warn"),
    ]
    for label, ok in checks:
        mark = "PASS" if ok else "FAIL"
        print(f"[{mark}] {label}")
        if not ok:
            failures.append(label)

    # Also verify L2 prose in rules_catalog.py no longer claims router itself is clean
    catalog = json.loads(
        subprocess.check_output([str(ROOT / "bin" / "hopwatch"), "--rules-catalog"], text=True)
    )
    rules = catalog.get("rules", [])
    l2_entry = next((r for r in rules if r.get("id") == "L2"), None)
    if not l2_entry:
        failures.append("L2 entry missing from --rules-catalog")
    else:
        l2_blurb = l2_entry.get("blurb", "")
        if "router itself is clean" in l2_blurb or "while your router isn't dropping packets" not in l2_blurb:
            failures.append(f"L2 blurb invalid: {l2_blurb!r}")
        else:
            print(f"[PASS] CLI rules catalog L2 blurb updated: {l2_blurb}")

    return failures


def build_contact_sheet(out_dir: Path, manifest: dict) -> None:
    cards: list[str] = []
    for s in manifest["scenarios"]:
        ok = not s["failures"]
        badge = '<span class="ok">PASS</span>' if ok else '<span class="fail">FAIL</span>'
        checks_html = "".join(
            f'<li class="ok">✓ {html.escape(c)}</li>' for c in s["checksPassed"]
        ) + "".join(
            f'<li class="fail">✘ {html.escape(f)}</li>' for f in s["failures"]
        )
        imgs = [s["dropdownLight"]] + s.get("extraScreenshots", [])
        imgs_html = "".join(
            f'<a href="{html.escape(img)}" target="_blank">'
            f'<img src="{html.escape(img)}" alt="{html.escape(img)}" />'
            f'<div class="cap">{html.escape(img)}</div></a>'
            for img in imgs
        )
        cards.append(
            f"""
            <article class="card {'card-fail' if not ok else ''}">
              <header>
                <div>{badge} <strong>{html.escape(s['id'])}</strong> — {html.escape(s['title'])}</div>
                <div class="meta">Pill: <b>{html.escape(s['statusPill'])}</b> ({html.escape(s['pillTone'])}) · Dot: <b>{html.escape(s['health'])}</b> · Stage: <code>{html.escape(s['stage'])}</code></div>
              </header>
              <div class="thumbs">{imgs_html}</div>
              <ul class="checks">{checks_html}</ul>
            </article>
            """
        )

    doc = f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <title>Hopwatch Visual Audit Report</title>
  <style>
    body {{ font-family: -apple-system, BlinkMacSystemFont, sans-serif; background: #f5f5f7; color: #1d1d1f; margin: 24px; }}
    h1 {{ margin-bottom: 4px; }}
    .summary {{ color: #515154; margin-bottom: 20px; }}
    .grid {{ display: grid; grid-template-columns: repeat(auto-fill, minmax(460px, 1fr)); gap: 18px; }}
    .card {{ background: #fff; border: 1px solid #d2d2d7; border-radius: 12px; padding: 14px; box-shadow: 0 1px 3px rgba(0,0,0,0.06); }}
    .card-fail {{ border-color: #d93025; background: #fff8f8; }}
    .meta {{ color: #6e6e73; font-size: 12px; margin-top: 4px; }}
    .thumbs {{ display: flex; flex-wrap: wrap; gap: 10px; margin: 12px 0; }}
    .thumbs a {{ text-decoration: none; color: #515154; font-size: 11px; }}
    .thumbs img {{ max-height: 560px; max-width: 100%; border-radius: 8px; border: 1px solid #e5e5ea; display: block; }}
    .cap {{ margin-top: 3px; text-align: center; }}
    .checks {{ list-style: none; padding: 0; margin: 8px 0 0; font-size: 12px; }}
    .ok {{ color: #188038; }}
    .fail {{ color: #d93025; font-weight: 600; }}
  </style>
</head>
<body>
  <h1>Hopwatch Visual Audit</h1>
  <div class="summary">Generated {html.escape(manifest['generatedAt'])} · {manifest['totalScenarios']} scenarios · {manifest['totalChecks'] - manifest['totalFailures']}/{manifest['totalChecks']} checks passed · {manifest['totalFailures']} failed</div>
  <section class="grid">{''.join(cards)}</section>
</body>
</html>
"""
    (out_dir / "index.html").write_text(doc, encoding="utf-8")


def run_gui_audit(out_dir: Path) -> int:
    if not APP_BUNDLE.exists():
        print("Building Hopwatch.app (make gui)...", file=sys.stderr)
        subprocess.run(["make", "gui"], cwd=ROOT, check=True)

    with tempfile.TemporaryDirectory(prefix="hopwatch-visual-audit-") as tmp:
        tmp_path = Path(tmp)
        isolated_home = tmp_path / "home"
        isolated_home.mkdir(parents=True, exist_ok=True)
        staged_app = tmp_path / "Hopwatch.app"
        shutil.copytree(APP_BUNDLE, staged_app, symlinks=True)

        # Unique bundle id keeps cfprefsd completely separate from the user's preferences
        plist_path = staged_app / "Contents" / "Info.plist"
        with plist_path.open("rb") as fh:
            plist = plistlib.load(fh)
        plist["CFBundleIdentifier"] = f"org.hopwatch.visual-audit.{os.getpid()}"
        with plist_path.open("wb") as fh:
            plistlib.dump(plist, fh)

        env = os.environ.copy()
        env["CFFIXED_USER_HOME"] = str(isolated_home)
        env["HOME"] = str(isolated_home)
        env["HOPWATCH_QUIET_TEST"] = "1"

        exe = staged_app / "Contents" / "MacOS" / "HopwatchGUI"
        proc = subprocess.run(
            [str(exe), f"--visual-audit={out_dir}"],
            env=env,
            cwd=ROOT,
            check=False,
        )
        manifest_path = out_dir / "manifest.json"
        if manifest_path.exists():
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            build_contact_sheet(out_dir, manifest)
            print(f"Contact sheet: {out_dir / 'index.html'}")
        return proc.returncode


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT, help="Output directory for screenshots & HTML report")
    parser.add_argument("--open-report", action="store_true", help="Open index.html in default browser when finished")
    args = parser.parse_args()

    out_dir = args.out.resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    print("=== Stage 1: CLI Monitor Simulation ===")
    cli_failures = run_cli_simulation()
    if cli_failures:
        for f in cli_failures:
            print(f"[FAIL] {f}", file=sys.stderr)
        return 1

    print("\n=== Stage 2: GUI Live Simulation & Visual Audit ===")
    gui_rc = run_gui_audit(out_dir)
    if args.open_report and (out_dir / "index.html").exists():
        subprocess.run(["open", str(out_dir / "index.html")], check=False)
    return gui_rc


if __name__ == "__main__":
    raise SystemExit(main())
