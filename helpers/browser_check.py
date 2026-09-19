#!/usr/bin/env python3
"""Check running Chromium browsers for post-update version desynchronization.

When Chromium-based browsers (Google Chrome, Brave, Arc, Edge, Chromium)
auto-update silently in the background on macOS, the updater replaces the
bundle on disk and removes the previous framework version directory from
`Contents/Frameworks/<Name> Framework.framework/Versions/<old_version>`.

If the browser is still running, existing tabs continue to function in RAM,
but any new tab or cross-site navigation attempts to spawn a new helper
process from that removed directory. The spawn fails immediately (ENOENT)
and displays an unhappy face ("Aw, Snap!").

This helper scans running processes, detects if an active browser's version
directory is missing from disk, and outputs TSV or JSON results for netdiag.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys

KNOWN_BROWSERS = [
    {
        "name": "Google Chrome",
        "bundle": "Google Chrome.app",
        "fw": "Google Chrome Framework.framework",
        "app_support": "Google/Chrome",
    },
    {
        "name": "Google Chrome Canary",
        "bundle": "Google Chrome Canary.app",
        "fw": "Google Chrome Framework.framework",
        "app_support": "Google/Chrome Canary",
    },
    {
        "name": "Brave Browser",
        "bundle": "Brave Browser.app",
        "fw": "Brave Browser Framework.framework",
        "app_support": "BraveSoftware/Brave-Browser",
    },
    {
        "name": "Microsoft Edge",
        "bundle": "Microsoft Edge.app",
        "fw": "Microsoft Edge Framework.framework",
        "app_support": "Microsoft Edge",
    },
    {
        "name": "Arc",
        "bundle": "Arc.app",
        "fw": "Arc Framework.framework",
        "app_support": "Arc",
    },
    {
        "name": "Chromium",
        "bundle": "Chromium.app",
        "fw": "Chromium Framework.framework",
        "app_support": "Chromium",
    },
]


def get_disk_version(bundle_path: str, fw_name: str) -> str:
    """Read the version currently installed on disk."""
    versions_dir = os.path.join(bundle_path, "Contents", "Frameworks", fw_name, "Versions")
    current_symlink = os.path.join(versions_dir, "Current")
    if os.path.islink(current_symlink):
        try:
            return os.path.basename(os.readlink(current_symlink))
        except OSError:
            pass
    if os.path.isdir(versions_dir):
        try:
            entries = [
                e for e in os.listdir(versions_dir)
                if e != "Current" and os.path.isdir(os.path.join(versions_dir, e))
            ]
            if entries:
                return sorted(entries)[-1]
        except OSError:
            pass
    info_plist = os.path.join(bundle_path, "Contents", "Info.plist")
    if os.path.isfile(info_plist):
        try:
            cmd = ["defaults", "read", info_plist, "CFBundleShortVersionString"]
            return subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL).strip()
        except Exception:
            pass
    return "unknown"


def find_running_version(
    pid: int,
    bundle_path: str,
    fw_name: str,
    app_support: str,
    ps_text: str,
) -> str | None:
    """Identify the framework version the running browser process loaded."""
    # 1. Search ps output for running helper processes from this bundle
    helper_pattern = re.compile(
        re.escape(fw_name) + r"/Versions/([0-9.]+)/Helpers/"
    )
    for line in ps_text.splitlines():
        m = helper_pattern.search(line)
        if m:
            return m.group(1)

    # 2. Check ~/Library/Application Support/<App>/RunningChromeVersion symlink if present
    app_support_dir = os.path.expanduser(f"~/Library/Application Support/{app_support}")
    running_symlink = os.path.join(app_support_dir, "RunningChromeVersion")
    if os.path.islink(running_symlink):
        try:
            target = os.readlink(running_symlink)
            ver = target.split(":")[0]
            if re.match(r"^[0-9.]+$", ver):
                return ver
        except OSError:
            pass

    # 3. Use lsof to inspect open mapped files in the framework
    try:
        lsof_out = subprocess.check_output(
            ["lsof", "-p", str(pid)],
            text=True,
            stderr=subprocess.DEVNULL,
            timeout=2.0,
        )
        lsof_pattern = re.compile(
            re.escape(fw_name) + r"/Versions/([0-9.]+)/"
        )
        m = lsof_pattern.search(lsof_out)
        if m:
            return m.group(1)
    except Exception:
        pass

    return None


def inspect_browsers(ps_text: str | None = None) -> list[dict[str, object]]:
    """Inspect running Chromium browsers and detect desynchronization."""
    current_uid = os.getuid() if hasattr(os, "getuid") else None

    if ps_text is None:
        try:
            ps_text = subprocess.check_output(
                ["ps", "-eo", "uid,pid,command"],
                text=True,
                stderr=subprocess.DEVNULL,
            )
        except Exception:
            return []

    findings: list[dict[str, object]] = []

    for browser in KNOWN_BROWSERS:
        name = browser["name"]
        bundle = browser["bundle"]
        fw_name = browser["fw"]
        app_support = browser["app_support"]

        # Match main process line:
        # e.g. 501 1234 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
        # or   1234 /Applications/Google Chrome.app/... (when ps without uid in tests)
        pattern_with_uid = re.compile(
            rf"^\s*(\d+)\s+(\d+)\s+(/.*?/{re.escape(bundle)}/Contents/MacOS/{re.escape(name)})(\s|$)"
        )
        pattern_no_uid = re.compile(
            rf"^\s*(\d+)\s+(/.*?/{re.escape(bundle)}/Contents/MacOS/{re.escape(name)})(\s|$)"
        )

        for line in ps_text.splitlines():
            # Skip zombie or defunct processes
            if "<defunct>" in line:
                continue

            p_uid = None
            pid = None
            exe_path = None

            m_uid = pattern_with_uid.match(line)
            if m_uid:
                p_uid = int(m_uid.group(1))
                pid = int(m_uid.group(2))
                exe_path = m_uid.group(3)
            else:
                m_no = pattern_no_uid.match(line)
                if m_no:
                    pid = int(m_no.group(1))
                    exe_path = m_no.group(2)
                else:
                    continue

            # Only inspect processes belonging to the current user (if uid is present)
            if current_uid is not None and p_uid is not None and p_uid != current_uid:
                continue

            bundle_path = os.path.realpath(exe_path.split("/Contents/MacOS/")[0])
            if not os.path.isdir(bundle_path):
                continue

            running_ver = find_running_version(pid, bundle_path, fw_name, app_support, ps_text)
            if not running_ver or not re.match(r"^[0-9.]+$", running_ver):
                continue

            expected_fw_dir = os.path.join(
                bundle_path, "Contents", "Frameworks", fw_name, "Versions", running_ver
            )
            disk_exists = os.path.isdir(expected_fw_dir)
            disk_ver = get_disk_version(bundle_path, fw_name)

            # A desynchronization requires:
            # 1. The framework directory of the running version is missing from disk.
            # 2. A different valid version exists on disk.
            # If the disk version matches the running version, or cannot be determined,
            # we do not raise a desync finding.
            if not disk_exists and disk_ver != "unknown" and running_ver != disk_ver:
                findings.append({
                    "app": name,
                    "bundle": bundle_path,
                    "pid": pid,
                    "running_version": running_ver,
                    "disk_version": disk_ver,
                    "desync": True,
                })
            break  # One main instance per browser definition is sufficient

    return findings


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="Emit JSON output")
    parser.add_argument("--ps-file", help="Read ps output from file (for testing)")
    args = parser.parse_args()

    ps_text = None
    if args.ps_file:
        try:
            with open(args.ps_file, "r") as f:
                ps_text = f.read()
        except OSError as err:
            print(f"Error reading ps file: {err}", file=sys.stderr)
            return 1

    findings = inspect_browsers(ps_text=ps_text)

    if args.json:
        print(json.dumps({"findings": findings, "count": len(findings)}))
        return 0

    if not findings:
        # Clean: emit "OK"
        print("OK\t0\t\t\t")
        return 0

    # Emit first desync finding in TSV format: DESYNC\tCOUNT\tAPP\tRUNNING_VER\tDISK_VER\tPID
    first = findings[0]
    print(f"DESYNC\t{len(findings)}\t{first['app']}\t{first['running_version']}\t{first['disk_version']}\t{first['pid']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
