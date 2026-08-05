#!/usr/bin/env python3
"""Releases a new version of App Monitor:

  1. Validates prerequisites (gh, xcodebuild, codesign, git, xcodegen)
  2. Resolves / bumps version in project.yml
  3. Tags the release
  4. Bundles AppMonitor.app via scripts/bundle.py (drives xcodebuild)
  5. Zips and uploads to GitHub Releases

Usage: scripts/deploy_releases.py [x.y.z]
  If a version is passed and it's higher than project.yml's, the script
  bumps and commits project.yml first so the tag points at the bump commit.
  Without an arg, uses whatever version is in project.yml.
"""

from __future__ import annotations

import platform
import re
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bundle as bundle_script  # noqa: E402
from _console import (  # noqa: E402
    CYAN,
    GREEN,
    NC,
    error,
    human_size,
    run,
    step,
    success,
    warn,
)

PROJECT_ROOT = Path(__file__).resolve().parent.parent
PROJECT_YML = PROJECT_ROOT / "project.yml"
REPO = "LeoManrique/macos-app-monitor"

_SEMVER_RE = re.compile(r"^\d+\.\d+\.\d+$")


def git(*args: str, check: bool = True):
    return run(["git", *args], cwd=PROJECT_ROOT, quiet=True, check=check)


def working_tree_dirty() -> bool:
    unstaged = git("diff", "--quiet", check=False).returncode != 0
    staged = git("diff", "--cached", "--quiet", check=False).returncode != 0
    return unstaged or staged


def bump_project_yml(current: str, new: str) -> None:
    """Update both MARKETING_VERSION and CURRENT_PROJECT_VERSION in project.yml."""
    text = PROJECT_YML.read_text()
    for key in ("MARKETING_VERSION", "CURRENT_PROJECT_VERSION"):
        text = text.replace(f'{key}: "{current}"', f'{key}: "{new}"')
    PROJECT_YML.write_text(text)


def version_tuple(version: str) -> tuple[int, ...]:
    return tuple(int(part) for part in version.split("."))


def platform_slug() -> str:
    arch = platform.machine()
    arch = {"arm64": "arm64", "aarch64": "arm64", "x86_64": "amd64"}.get(arch, arch)
    return f"macOS-{arch}"


def install_note(app_path: Path) -> str:
    """Describe what this specific bundle needs on first launch.

    A stapled (notarized) bundle opens normally and can enable Full Process
    Access; an ad-hoc one trips Gatekeeper and can't register its LaunchDaemon.
    Asking `stapler` beats assuming, so the notes can't drift from the artifact.
    """
    stapled = run(
        ["xcrun", "stapler", "validate", str(app_path)], quiet=True, check=False
    ).returncode == 0
    if stapled:
        return (
            "The bundle is signed and notarized, so it opens normally. "
            "Full Process Access (Process ▸ Enable Full Process Access…) is "
            "available — it installs a small root helper, with your approval in "
            "System Settings, so CPU and memory can be read for every process "
            "rather than only the ones you own."
        )
    return (
        "The bundle is ad-hoc signed, so on first launch right-click → Open (or run "
        "`xattr -cr /Applications/AppMonitor.app` — the install script does this "
        "for you). Full Process Access is unavailable in an unnotarized build, so "
        "processes you don't own show `—` for CPU and memory."
    )


def release_notes(tag: str, artifact: str, signing: str) -> str:
    return f"""## App Monitor {tag}

A minimal SwiftUI alternative for macOS Activity Monitor's memory view, with \
processes grouped by `.app` so you can see how much memory you'd reclaim by \
quitting an app.

### Install

```
curl -fsSL https://raw.githubusercontent.com/{REPO}/master/scripts/install.py | python3
```

Or download `{artifact}` below and drag `AppMonitor.app` into `/Applications`. \
{signing}

### Requirements

- macOS 14+ (Intel or Apple Silicon)"""


def main(argv: list[str]) -> None:
    version = argv[1] if len(argv) > 1 else None

    # ── Step 1: Validate prerequisites ──
    step(1, "Validating prerequisites")

    if platform.system() != "Darwin":
        error("This script only runs on macOS")
    # Both arm64 and x86_64 are supported release platforms; the host arch just
    # decides which one this run produces.

    for cmd in ("gh", "xcodebuild", "xcodegen", "codesign", "git", "zip"):
        if not shutil.which(cmd):
            error(f"{cmd} is not installed")
        success(f"{cmd} found")

    if run(["gh", "auth", "status"], quiet=True, check=False).returncode != 0:
        error("gh CLI not authenticated. Run: gh auth login")
    success("gh authenticated")

    # Working tree must be clean — otherwise we can't be sure what's in the tag.
    if working_tree_dirty():
        error("Working tree is dirty — commit or stash changes before releasing")
    success("Working tree clean")

    # ── Step 2: Determine + bump version ──
    step(2, "Determining version")

    current_version = bundle_script.read_marketing_version()

    if version is None:
        version = current_version
        success(f"Using version from project.yml: {version}")
    elif not _SEMVER_RE.match(version):
        error(f"Version must be x.y.z (got: {version})")
    elif version == current_version:
        success(f"Version {version} already in project.yml, no bump needed")
    else:
        if version_tuple(version) <= version_tuple(current_version):
            error(f"New version {version} is not greater than current {current_version}")
        bump_project_yml(current_version, version)
        # Regenerate xcodeproj so its embedded settings line up before tagging.
        run(["xcodegen", "generate"], cwd=PROJECT_ROOT, quiet=True)
        git("add", "project.yml", "AppMonitor.xcodeproj")
        git("commit", "-m", f"Bump version to {version}")
        git("push")
        success(f"Bumped {current_version} → {version} and pushed")

    tag = f"v{version}"
    plat = platform_slug()
    success(f"Version: {version} (tag: {tag}), platform: {plat}")

    # ── Step 3: Create git tag ──
    step(3, "Tagging release")

    if git("rev-parse", tag, check=False).returncode == 0:
        warn(f"Tag {tag} already exists, skipping")
    else:
        git("tag", "-a", tag, "-m", f"Release {tag}")
        git("push", "origin", tag)
        success(f"Created and pushed tag {tag}")

    # ── Step 4: Bundle + zip ──
    step(4, "Bundling AppMonitor.app")

    app_path = bundle_script.bundle(version)
    if not app_path.is_dir():
        error(f"Bundle script did not produce {app_path}")

    dist_dir = PROJECT_ROOT / "dist"
    dist_dir.mkdir(parents=True, exist_ok=True)
    artifact = f"AppMonitor-{version}-{plat}.zip"
    artifact_path = dist_dir / artifact
    artifact_path.unlink(missing_ok=True)
    # `ditto -c -k --keepParent` is the macOS-canonical way to zip an .app:
    # preserves resource forks, xattrs, and symlinks (plain `zip` strips them and
    # can produce a bundle that Finder refuses to open after extraction).
    run(["ditto", "-c", "-k", "--keepParent", str(app_path), str(artifact_path)])
    success(f"Packaged: {artifact} ({human_size(artifact_path.stat().st_size)})")

    # ── Step 5: Upload to GitHub Release ──
    step(5, "Uploading to GitHub Release")

    exists = run(
        ["gh", "release", "view", tag, "--repo", REPO], quiet=True, check=False
    ).returncode == 0
    if exists:
        warn(f"Release {tag} already exists, uploading artifacts (clobber)")
        run(["gh", "release", "upload", tag, str(artifact_path), "--clobber", "--repo", REPO])
    else:
        run([
            "gh", "release", "create", tag, str(artifact_path),
            "--repo", REPO,
            "--title", f"App Monitor {tag}",
            "--notes", release_notes(tag, artifact, install_note(app_path)),
        ])
    success(f"Uploaded {artifact} to release {tag}")

    print(f"\n{GREEN}═══ Release {tag} complete ({plat}) ═══{NC}")
    print(f"  {CYAN}https://github.com/{REPO}/releases/tag/{tag}{NC}")


if __name__ == "__main__":
    try:
        main(sys.argv)
    except KeyboardInterrupt:
        raise SystemExit(130)
