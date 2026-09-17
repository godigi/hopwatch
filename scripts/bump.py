#!/usr/bin/env python3
"""scripts/bump.py — Automated SemVer bumper for hopwatch.

Determines the next version from Conventional Commits since the last git tag,
updates all version definitions across the project, rolls CHANGELOG.md,
and creates the release commit and git tag.

Usage:
    python3 scripts/bump.py              # Auto-detects bump level (major/minor/patch)
    python3 scripts/bump.py --type patch # Force patch bump
    python3 scripts/bump.py --type minor # Force minor bump
    python3 scripts/bump.py --type major # Force major bump
    python3 scripts/bump.py --dry-run    # Preview changes without modifying files
"""

from __future__ import annotations

import argparse
import datetime
import os
import re
import subprocess
import sys


def run_cmd(cmd: list[str], check: bool = True) -> str:
    """Run a shell command and return trimmed stdout."""
    res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if check and res.returncode != 0:
        raise RuntimeError(f"Command failed ({res.returncode}): {' '.join(cmd)}\n{res.stderr}")
    return res.stdout.strip()


def get_repo_root() -> str:
    return run_cmd(["git", "rev-parse", "--show-toplevel"])


def get_current_version(repo_root: str) -> str:
    bin_path = os.path.join(repo_root, "bin", "hopwatch")
    if not os.path.exists(bin_path):
        bin_path = os.path.join(repo_root, "bin", "netdiag")
    with open(bin_path, "r", encoding="utf-8") as f:
        content = f.read()
        match = re.search(r'^(?:HOPWATCH|NETDIAG)_VERSION="([^"]+)"', content, re.MULTILINE)
        if not match:
            raise ValueError(f"Could not find HOPWATCH_VERSION or NETDIAG_VERSION in {bin_path}")
        return match.group(1)


def get_latest_tag() -> str | None:
    res = subprocess.run(
        ["git", "describe", "--tags", "--abbrev=0"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if res.returncode == 0 and res.stdout.strip():
        return res.stdout.strip()
    return None


def get_commits_since_tag(tag: str | None) -> list[str]:
    if tag:
        cmd = ["git", "log", f"{tag}..HEAD", "--oneline"]
    else:
        cmd = ["git", "log", "--oneline"]
    output = run_cmd(cmd, check=False)
    if not output:
        return []
    return [line.strip() for line in output.splitlines() if line.strip()]


def detect_bump_type(commits: list[str]) -> str:
    """Analyze commit subjects to detect major, minor, or patch."""
    has_breaking = False
    has_feature = False
    has_fix = False

    for commit in commits:
        parts = commit.split(" ", 1)
        subject = parts[1] if len(parts) > 1 else commit

        if "BREAKING CHANGE" in subject or re.search(r"^[a-zA-Z]+(\([^\)]+\))?!:", subject):
            has_breaking = True
            break
        if re.match(r"^feat(\([^\)]+\))?:", subject, re.IGNORECASE):
            has_feature = True
        elif re.match(r"^fix(\([^\)]+\))?:", subject, re.IGNORECASE):
            has_fix = True

    if has_breaking:
        return "major"
    if has_feature:
        return "minor"
    return "patch"


def calculate_next_version(current: str, bump_type: str) -> str:
    parts = [int(p) for p in current.split(".")]
    if len(parts) != 3:
        raise ValueError(f"Unsupported version format: {current}")

    major, minor, patch = parts
    if bump_type == "major":
        return f"{major + 1}.0.0"
    elif bump_type == "minor":
        return f"{major}.{minor + 1}.0"
    elif bump_type == "patch":
        return f"{major}.{minor}.{patch + 1}"
    else:
        raise ValueError(f"Unknown bump type: {bump_type}")


def update_file(path: str, pattern: str, replacement: str, dry_run: bool = False) -> None:
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()

    new_content, count = re.subn(pattern, lambda _: replacement, content, flags=re.MULTILINE)
    if count == 0:
        print(f"Warning: pattern '{pattern}' not matched in {path}")
        return

    if not dry_run:
        with open(path, "w", encoding="utf-8") as f:
            f.write(new_content)
    print(f"  Updated {os.path.relpath(path)}")


def update_changelog(
    repo_root: str,
    next_version: str,
    prev_version: str,
    commits: list[str],
    dry_run: bool = False,
) -> None:
    changelog_path = os.path.join(repo_root, "CHANGELOG.md")
    with open(changelog_path, "r", encoding="utf-8") as f:
        text = f.read()

    today = datetime.date.today().isoformat()
    unreleased_pattern = r"(## \[Unreleased\][^\n]*\n)([\s\S]*?)(?=^## \[|\Z)"
    match = re.search(unreleased_pattern, text, re.MULTILINE)

    unreleased_body = match.group(2).strip() if match else ""

    if unreleased_body:
        replacement = (
            f"## [Unreleased]\n\n"
            f"## [{next_version}] - {today}\n\n"
            f"{unreleased_body}\n"
        )
    else:
        commit_bullets = []
        for c in commits:
            parts = c.split(" ", 1)
            msg = parts[1] if len(parts) > 1 else c
            if not msg.startswith("chore(release):"):
                commit_bullets.append(f"- {msg}")

        bullets_str = "\n".join(commit_bullets) if commit_bullets else "- Miscellaneous maintenance."
        replacement = (
            f"## [Unreleased]\n\n"
            f"## [{next_version}] - {today}\n\n"
            f"### Changes\n\n"
            f"{bullets_str}\n"
        )

    text = re.sub(unreleased_pattern, lambda _: replacement, text, count=1, flags=re.MULTILINE)

    footer_ref = f"[Unreleased]: https://github.com/godigi/hopwatch/compare/v{next_version}...HEAD\n[{next_version}]: https://github.com/godigi/hopwatch/compare/v{prev_version}...v{next_version}"
    text = re.sub(r"\[Unreleased\]: https://[^\n]+", lambda _: footer_ref, text, count=1)

    if not dry_run:
        with open(changelog_path, "w", encoding="utf-8") as f:
            f.write(text)
    print(f"  Updated CHANGELOG.md for [{next_version}] - {today}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Automated version bumper for netdiag")
    parser.add_argument(
        "--type",
        choices=["major", "minor", "patch", "auto"],
        default="auto",
        help="SemVer bump increment type (default: auto)",
    )
    parser.add_argument("--dry-run", action="store_true", help="Preview without modifying")
    parser.add_argument("--no-tag", action="store_true", help="Do not create a git tag")
    parser.add_argument("--no-commit", action="store_true", help="Do not commit changes")
    parser.add_argument("--ci", action="store_true", help="Running in automated CI mode")

    args = parser.parse_args()
    repo_root = get_repo_root()
    os.chdir(repo_root)

    current_version = get_current_version(repo_root)
    latest_tag = get_latest_tag()
    commits = get_commits_since_tag(latest_tag)

    if not commits and args.type == "auto":
        print(f"No commits since {latest_tag or current_version}. Already up to date.")
        return 0

    bump_type = args.type
    if bump_type == "auto":
        bump_type = detect_bump_type(commits)

    next_version = calculate_next_version(current_version, bump_type)
    print(f"Bumping netdiag: {current_version} -> {next_version} ({bump_type})")
    if commits:
        print(f"Found {len(commits)} commit(s) since {latest_tag}:")
        for c in commits[:5]:
            print(f"  - {c}")
        if len(commits) > 5:
            print(f"  ... and {len(commits) - 5} more")

    if args.dry_run:
        print("[DRY RUN] No files modified.")
        return 0

    # 1. bin/hopwatch (and bin/netdiag if it exists as regular file)
    hopwatch_bin = os.path.join(repo_root, "bin", "hopwatch")
    if os.path.exists(hopwatch_bin) and not os.path.islink(hopwatch_bin):
        update_file(
            hopwatch_bin,
            r'^HOPWATCH_VERSION="[^"]+"',
            f'HOPWATCH_VERSION="{next_version}"',
        )
        update_file(
            hopwatch_bin,
            r'^NETDIAG_VERSION="[^"]+"',
            f'NETDIAG_VERSION="{next_version}"',
        )

    netdiag_bin = os.path.join(repo_root, "bin", "netdiag")
    if os.path.exists(netdiag_bin) and not os.path.islink(netdiag_bin):
        update_file(
            netdiag_bin,
            r'^NETDIAG_VERSION="[^"]+"',
            f'NETDIAG_VERSION="{next_version}"',
        )

    # 2. Casks/hopwatch.rb
    cask_hopwatch = os.path.join(repo_root, "Casks", "hopwatch.rb")
    if os.path.exists(cask_hopwatch):
        update_file(
            cask_hopwatch,
            r'version\s+"[^"]+"',
            f'version "{next_version}"',
        )

    # 3. examples/sample-output.json
    sample_json = os.path.join(repo_root, "examples", "sample-output.json")
    if os.path.exists(sample_json):
        update_file(
            sample_json,
            r'"version":\s*"[^"]+"',
            f'"version": "{next_version}"',
        )

    # 4. gui/Sources/HopwatchGUI/VerifyMode.swift
    verify_mode = os.path.join(repo_root, "gui", "Sources", "HopwatchGUI", "VerifyMode.swift")
    if os.path.exists(verify_mode):
        update_file(
            verify_mode,
            r'version:\s*"[^"]+"',
            f'version: "{next_version}"',
        )

    # 5. CHANGELOG.md
    update_changelog(repo_root, next_version, current_version, commits)

    if not args.no_commit:
        files_to_add = [
            "CHANGELOG.md",
        ]
        if os.path.exists(hopwatch_bin):
            files_to_add.append("bin/hopwatch")
        if os.path.exists(netdiag_bin):
            files_to_add.append("bin/netdiag")
        if os.path.exists(cask_hopwatch):
            files_to_add.append("Casks/hopwatch.rb")
        if os.path.exists(sample_json):
            files_to_add.append("examples/sample-output.json")
        if os.path.exists(verify_mode):
            files_to_add.append(os.path.relpath(verify_mode, repo_root))

        run_cmd(["git", "add"] + files_to_add)
        commit_msg = f"chore(release): bump version to {next_version}"
        run_cmd(["git", "commit", "-m", commit_msg])
        print(f"Created release commit: {commit_msg}")

        if not args.no_tag:
            tag_name = f"v{next_version}"
            run_cmd(["git", "tag", "-a", tag_name, "-m", f"Release {tag_name}"])
            print(f"Created tag: {tag_name}")

    print(f"\n🎉 Successfully bumped version to {next_version}!")
    return 0


if __name__ == "__main__":
    sys.exit(main())
