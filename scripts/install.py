#!/usr/bin/env python3
"""Installs App Monitor into /Applications.

  scripts/install.py                  # download + install the latest GitHub release
  scripts/install.py --local          # install target/release/bundle/AppMonitor.app
  scripts/install.py --local --build  # run bundle.py first, then install its output

The no-flag path is intended to be curlable:
  curl -fsSL https://raw.githubusercontent.com/LeoManrique/macos-app-monitor/master/scripts/install.py | python3

Standard library only, and deliberately a single file with no imports from the
rest of scripts/ — when piped into an interpreter there is no sibling module to
import from. The --local flags are unreachable on that path (no argv, no
`__file__`) and are for working from a checkout.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import NoReturn

# ── Colors ──
# stdout stays attached to the terminal under `curl … | python3` (only stdin is
# the pipe), so progress rendering and color both still apply.
_TTY = sys.stdout.isatty()
_COLOR = _TTY and "NO_COLOR" not in os.environ
RED = "\033[0;31m" if _COLOR else ""
GREEN = "\033[0;32m" if _COLOR else ""
YELLOW = "\033[1;33m" if _COLOR else ""
BLUE = "\033[0;34m" if _COLOR else ""
CYAN = "\033[0;36m" if _COLOR else ""
NC = "\033[0m" if _COLOR else ""

TOTAL_STEPS = 5


def step(n: int, message: str) -> None:
    print(f"\n{BLUE}[{n}/{TOTAL_STEPS}]{NC} {CYAN}{message}{NC}")


def success(message: str) -> None:
    print(f"  {GREEN}✓ {message}{NC}")


def warn(message: str) -> None:
    print(f"  {YELLOW}⚠ {message}{NC}")


def error(message: str) -> NoReturn:
    print(f"  {RED}✗ {message}{NC}")
    raise SystemExit(1)


REPO = "LeoManrique/macos-app-monitor"
API_URL = f"https://api.github.com/repos/{REPO}/releases/latest"
APP_NAME = "AppMonitor.app"
DEST = Path("/Applications") / APP_NAME
PROCESS_PATTERNS = ("App Monitor", "AppMonitor", "activity-monitor")


def human_size(num_bytes: float) -> str:
    for unit in ("B", "KB", "MB", "GB"):
        if num_bytes < 1024 or unit == "GB":
            return f"{num_bytes:.1f}{unit}"
        num_bytes /= 1024
    return f"{num_bytes:.1f}GB"


def pgrep(pattern: str) -> list[int]:
    """PIDs whose full command line matches `pattern`, excluding this process
    (its own argv can contain the pattern when run from a checkout)."""
    proc = subprocess.run(
        ["pgrep", "-f", pattern], capture_output=True, text=True
    )
    mine = {os.getpid(), os.getppid()}
    return [
        int(line)
        for line in proc.stdout.split()
        if line.isdigit() and int(line) not in mine
    ]


def stop_running_instances() -> None:
    """A running app holds an open file lock on its binary; replacing the bundle
    on disk while the old copy is running leaves you with a half-old/half-new
    install until the next launch. Kill it first."""
    running = [p for p in PROCESS_PATTERNS if pgrep(p)]

    if not running:
        success("No running instances")
        return

    for pattern in running:
        subprocess.run(["pkill", "-TERM", "-f", pattern], capture_output=True)

    for _ in range(16):
        if not any(pgrep(p) for p in running):
            break
        time.sleep(0.5)

    for pattern in running:
        if pgrep(pattern):
            warn(f"Force-killing {pattern} (graceful stop timed out)")
            subprocess.run(["pkill", "-KILL", "-f", pattern], capture_output=True)

    success(f"Stopped: {' '.join(running)}")


def fetch_latest_release() -> dict:
    request = urllib.request.Request(
        API_URL, headers={"Accept": "application/vnd.github.v3+json"}
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except (urllib.error.URLError, OSError, json.JSONDecodeError):
        error("Failed to fetch release info from GitHub. Check your internet connection.")


def download(url: str, dest: Path) -> None:
    try:
        with urllib.request.urlopen(url, timeout=60) as response:
            total = int(response.headers.get("Content-Length") or 0)
            downloaded = 0
            with dest.open("wb") as out:
                while chunk := response.read(64 * 1024):
                    out.write(chunk)
                    downloaded += len(chunk)
                    _progress(downloaded, total)
        if _TTY:
            print()
    except (urllib.error.URLError, OSError):
        error(f"Failed to download {dest.name}")


def _progress(done: int, total: int) -> None:
    if not _TTY:
        return
    if total:
        fraction = done / total
        filled = int(30 * fraction)
        bar = "#" * filled + "-" * (30 - filled)
        line = f"  [{bar}] {fraction * 100:5.1f}%  {human_size(done)}/{human_size(total)}"
    else:
        line = f"  {human_size(done)}"
    sys.stdout.write("\r" + line)
    sys.stdout.flush()


def install_bundle(src_app: Path) -> None:
    """Replace /Applications/AppMonitor.app with src_app, then make macOS
    willing to launch it. Shared by both install modes."""
    if DEST.exists() or DEST.is_symlink():
        shutil.rmtree(DEST, ignore_errors=True)
        warn(f"Replaced existing {DEST}")

    # `ditto` rather than a move: --local must not consume the build output, and
    # ditto is the macOS-canonical bundle copy (xattrs, resource forks, symlinks).
    copied = subprocess.run(
        ["ditto", str(src_app), str(DEST)], capture_output=True, text=True
    )
    if copied.returncode != 0:
        detail = copied.stderr.strip() or f"ditto exited {copied.returncode}"
        error(f"Failed to install to {DEST}: {detail}")

    # Strip the quarantine xattr Gatekeeper adds to anything downloaded over
    # the network. Without this, ad-hoc-signed bundles trigger a "developer
    # cannot be verified" dialog and won't open with a double-click.
    # Stripping is the standard escape hatch for open-source / unsigned tools.
    subprocess.run(["xattr", "-cr", str(DEST)], capture_output=True)

    # Register with Launch Services so Spotlight, Launchpad, and `open -a "App
    # Monitor"` (by CFBundleName) resolve the freshly-installed bundle. Without
    # this, LS only learns about the app the first time Finder touches it.
    lsregister = Path(
        "/System/Library/Frameworks/CoreServices.framework/Frameworks"
        "/LaunchServices.framework/Support/lsregister"
    )
    if os.access(lsregister, os.X_OK):
        subprocess.run([str(lsregister), "-f", str(DEST)], capture_output=True)

    success(f"Installed: {DEST}")


def bundle_version(app: Path) -> str:
    """CFBundleShortVersionString out of an installed/built bundle, for the
    closing banner. Best-effort — the install already succeeded by this point."""
    plist = app / "Contents" / "Info.plist"
    proc = subprocess.run(
        ["defaults", "read", str(plist), "CFBundleShortVersionString"],
        capture_output=True,
        text=True,
    )
    return proc.stdout.strip() if proc.returncode == 0 else "(unknown version)"


def done_banner(version: str) -> None:
    print(f"\n{GREEN}═══ App Monitor {version} installed ═══{NC}")
    print(f"  {CYAN}Open from /Applications, Spotlight, or:  open {DEST}{NC}")


# ── Release install (the curl-piped path) ──


def install_release() -> None:
    global TOTAL_STEPS
    TOTAL_STEPS = 5

    # ── Step 1: Detect platform ──
    step(1, "Detecting platform")

    machine = platform.machine()
    arch = {"arm64": "arm64", "aarch64": "arm64", "x86_64": "amd64"}.get(machine)
    if arch is None:
        error(f"Unsupported architecture: {machine}")
    plat = f"macOS-{arch}"
    success(f"Platform: {plat}")

    # ── Step 2: Stop any running instance ──
    step(2, "Stopping running instance")
    stop_running_instances()

    # ── Step 3: Fetch latest release metadata ──
    step(3, "Fetching latest release from GitHub")

    release = fetch_latest_release()
    tag = release.get("tag_name")
    if not tag:
        error("Could not parse release tag from GitHub API")
    version = tag[1:] if tag.startswith("v") else tag
    success(f"Latest version: {version} (tag: {tag})")

    # ── Step 4: Download artifact ──
    step(4, f"Downloading {APP_NAME}")

    artifact = f"AppMonitor-{version}-{plat}.zip"
    download_url = next(
        (
            asset["browser_download_url"]
            for asset in release.get("assets", [])
            if asset.get("name") == artifact
        ),
        None,
    )
    if not download_url:
        error(f"Could not find artifact {artifact} in release {tag}")

    tmp_dir = Path(tempfile.mkdtemp(prefix="app-monitor-install-"))
    try:
        archive = tmp_dir / artifact
        download(download_url, archive)
        success(f"Downloaded {artifact}")

        # ── Step 5: Install ──
        step(5, "Installing to /Applications")

        # `ditto -x -k` unpacks the zip preserving the bundle structure (xattrs,
        # resource forks, symlinks) — the inverse of how deploy_releases.py packs it.
        unpack = subprocess.run(
            ["ditto", "-x", "-k", str(archive), str(tmp_dir)], capture_output=True
        )
        unpacked = tmp_dir / APP_NAME
        if unpack.returncode != 0 or not unpacked.is_dir():
            error(f"Expected {APP_NAME} inside {artifact}, but didn't find it")

        install_bundle(unpacked)
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)

    done_banner(version)


# ── Local install (from scripts/bundle.py output) ──


def script_dir() -> Path | None:
    """None when there is no script on disk — i.e. curl-piped into python3,
    where `__file__` is undefined."""
    path = globals().get("__file__")
    return Path(path).resolve().parent if path else None


def install_local(build: bool) -> None:
    global TOTAL_STEPS
    TOTAL_STEPS = 3

    scripts = script_dir()
    if scripts is None:
        error("--local needs the script on disk — clone the repo and run scripts/install.py")
    local_app = scripts.parent / "target" / "release" / "bundle" / APP_NAME

    # ── Step 1: Build or locate the bundle ──
    if build:
        step(1, "Building AppMonitor.app")
        bundle_py = scripts / "bundle.py"
        if not bundle_py.is_file():
            error(f"{bundle_py} not found")
        # Not captured — bundle.py prints its own progress.
        if subprocess.run([sys.executable, str(bundle_py)]).returncode != 0:
            error("bundle.py failed")
    else:
        step(1, "Locating local bundle")

    if not local_app.is_dir():
        error(f"No bundle at {local_app} — run scripts/bundle.py first, or pass --build")
    version = bundle_version(local_app)
    success(f"Found {local_app} ({version})")

    # ── Step 2: Stop any running instance ──
    step(2, "Stopping running instance")
    stop_running_instances()

    # ── Step 3: Install ──
    step(3, "Installing to /Applications")
    install_bundle(local_app)

    done_banner(version)


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="install.py",
        description="Install App Monitor into /Applications.",
        epilog="With no flags, downloads and installs the latest GitHub release.",
    )
    parser.add_argument(
        "--local",
        action="store_true",
        help="install target/release/bundle/AppMonitor.app instead of downloading a release",
    )
    parser.add_argument(
        "--build",
        action="store_true",
        help="run scripts/bundle.py first, then install its output (implies --local)",
    )
    args = parser.parse_args()

    if platform.system() != "Darwin":
        error(f"Unsupported OS: {platform.system()} (App Monitor is macOS-only)")

    if args.local or args.build:
        install_local(build=args.build)
    else:
        install_release()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        raise SystemExit(130)
