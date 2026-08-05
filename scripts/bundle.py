#!/usr/bin/env python3
"""Builds AppMonitor.app from the Xcode project.

Output: $PROJECT_ROOT/target/release/bundle/AppMonitor.app
Usage:  scripts/bundle.py [VERSION] [--no-notarize]
  VERSION defaults to the project's MARKETING_VERSION (see project.yml).
  When set, both MARKETING_VERSION and CURRENT_PROJECT_VERSION are
  overridden for this build via xcodebuild settings.
  --no-notarize skips the (slow, network-bound) notarization step.

Signing escalates automatically with whatever the machine can do:

  Developer ID cert + notary profile -> signed, notarized, stapled
  Developer ID cert only             -> signed (helper stays inert)
  neither                            -> ad-hoc (helper stays inert)

"Inert" matters because the app embeds a LaunchDaemon: SMAppService refuses to
register one unless the containing bundle is notarized, so an ad-hoc build can
never turn on Full Process Access. See TECHNICAL.md.
"""

from __future__ import annotations

import os
import re
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _console import error, info, run, success, warn  # noqa: E402

PROJECT_ROOT = Path(__file__).resolve().parent.parent
BUNDLE_DIR = PROJECT_ROOT / "target" / "release" / "bundle"
DEST_APP = BUNDLE_DIR / "AppMonitor.app"

# Apple Developer team identifier, mirrored from project.yml's DEVELOPMENT_TEAM.
# Only lands in the signature when a real identity signs — ad-hoc builds carry no
# team. This is the OU field `codesign -dv` reports as TeamIdentifier, *not* the
# id in a certificate's common name, which is the certificate's own id.
DEVELOPMENT_TEAM = "56VA234XZ8"

# `xcrun notarytool store-credentials <name>` writes this keychain profile.
NOTARY_PROFILE = os.environ.get("APPMONITOR_NOTARY_PROFILE", "AppMonitor")

# Nested code must be signed before the bundle that contains it. `--deep` would
# do it in one call but is deprecated and applies the outer options blindly to
# nested binaries, so the helper is signed explicitly first.
NESTED_EXECUTABLES = ("Contents/MacOS/AppMonitorHelper",)

_MARKETING_VERSION_RE = re.compile(r'^\s*MARKETING_VERSION:\s*"([^"]*)"', re.MULTILINE)
_DEVELOPER_ID_RE = re.compile(r'"(Developer ID Application: [^"]+)"')


def read_marketing_version() -> str:
    """Pull MARKETING_VERSION out of project.yml so callers without an explicit
    version still get the right one baked into Info.plist."""
    match = _MARKETING_VERSION_RE.search((PROJECT_ROOT / "project.yml").read_text())
    if not match or not match.group(1):
        error("Could not read MARKETING_VERSION from project.yml")
    return match.group(1)


def developer_id_identity() -> str | None:
    """The machine's 'Developer ID Application' identity, if it has one.

    An 'Apple Development' certificate is *not* a substitute: it signs for local
    testing only and the notary service rejects it.
    """
    proc = run(
        ["security", "find-identity", "-v", "-p", "codesigning"],
        quiet=True,
        check=False,
    )
    match = _DEVELOPER_ID_RE.search(proc.stdout or "")
    return match.group(1) if match else None


def notary_profile_configured(profile: str) -> bool:
    """Whether `notarytool store-credentials` has been run for this profile."""
    if not shutil.which("xcrun"):
        return False
    proc = run(
        ["xcrun", "notarytool", "history", "--keychain-profile", profile],
        quiet=True,
        check=False,
    )
    return proc.returncode == 0


def sign(app: Path, identity: str) -> None:
    """Sign nested code first, then the bundle — codesign requires inside-out.

    `--options runtime` (hardened runtime) and `--timestamp` are both mandatory
    for notarization; without either the notary service rejects the submission.
    """
    for relative in NESTED_EXECUTABLES:
        nested = app / relative
        if not nested.exists():
            error(f"expected nested executable missing: {relative}")
        run(
            ["codesign", "--force", "--options", "runtime", "--timestamp",
             "--sign", identity, str(nested)],
            quiet=True,
        )
        success(f"Signed {relative}")

    run(
        ["codesign", "--force", "--options", "runtime", "--timestamp",
         "--sign", identity, str(app)],
        quiet=True,
    )
    success(f"Signed bundle with {identity}")

    run(["codesign", "--verify", "--strict", "--verbose=2", str(app)], quiet=True)
    success("Signature verifies")


def notarize(app: Path, profile: str) -> None:
    """Submit to Apple's notary service and staple the ticket.

    Stapling matters beyond Gatekeeper here: the ticket is what lets the app
    register its LaunchDaemon on a machine that has never seen it online.
    """
    archive = app.with_suffix(".zip")
    archive.unlink(missing_ok=True)
    # notarytool takes an archive, not a bare .app. `ditto -c -k --keepParent`
    # is the form Apple documents — plain `zip` mangles symlinks in bundles.
    run(["ditto", "-c", "-k", "--keepParent", str(app), str(archive)], quiet=True)

    info("Submitting to Apple's notary service (this takes a few minutes)…")
    run(
        ["xcrun", "notarytool", "submit", str(archive),
         "--keychain-profile", profile, "--wait"],
    )
    archive.unlink(missing_ok=True)
    success("Notarized")

    run(["xcrun", "stapler", "staple", str(app)], quiet=True)
    success("Stapled notarization ticket")

    # Gatekeeper's own verdict — the only check that reflects what a user's Mac
    # will decide on first launch.
    assessed = run(
        ["spctl", "--assess", "--type", "execute", "--verbose=2", str(app)],
        quiet=True,
        check=False,
    )
    if assessed.returncode == 0:
        success("Gatekeeper accepts the bundle")
    else:
        warn("spctl assessment failed — check the output above")


def sign_and_notarize(app: Path, *, allow_notarize: bool = True) -> None:
    """Escalate as far as this machine's credentials allow, and say so plainly.

    Never fatal: a missing certificate downgrades to ad-hoc rather than failing
    the build, so `bundle.py` still works on a machine with no signing set up.
    """
    identity = developer_id_identity()
    if identity is None:
        run(["codesign", "--force", "--sign", "-", str(app)], quiet=True, check=False)
        warn("No 'Developer ID Application' certificate — ad-hoc signed")
        warn("Full Process Access will stay unavailable: SMAppService only "
             "registers a LaunchDaemon from a notarized bundle")
        warn("Create one at developer.apple.com → Certificates → "
             "Developer ID Application (an 'Apple Development' cert cannot be notarized)")
        return

    sign(app, identity)

    if not allow_notarize:
        warn("Skipping notarization (--no-notarize) — helper stays inert in this build")
        return

    if not notary_profile_configured(NOTARY_PROFILE):
        warn(f"No notary keychain profile '{NOTARY_PROFILE}' — skipping notarization")
        warn("Set one up once with: xcrun notarytool store-credentials "
             f"{NOTARY_PROFILE} --apple-id <you> --team-id {DEVELOPMENT_TEAM} "
             "--password <app-specific-password>")
        return

    notarize(app, NOTARY_PROFILE)


def bundle(version: str | None = None, *, allow_notarize: bool = True) -> Path:
    """Build, lay out, sign, and (where possible) notarize AppMonitor.app."""
    version = version or read_marketing_version()
    info(f"Bundling App Monitor {version}")

    # Ensure the Xcode project is up to date. xcodegen is fast and idempotent;
    # running it every time keeps the project in sync with project.yml.
    if shutil.which("xcodegen"):
        run(["xcodegen", "generate"], cwd=PROJECT_ROOT, quiet=True)
        success("Regenerated AppMonitor.xcodeproj")
    elif not (PROJECT_ROOT / "AppMonitor.xcodeproj").is_dir():
        error(
            "xcodegen not installed and AppMonitor.xcodeproj missing — "
            "install xcodegen or commit the project"
        )
    else:
        warn("xcodegen not found; using existing AppMonitor.xcodeproj as-is")

    # Build into a local DerivedData so the script is self-contained and
    # repeatable — no dependency on Xcode's global ~/Library cache.
    build_dir = PROJECT_ROOT / "build"
    shutil.rmtree(build_dir, ignore_errors=True)
    run(
        [
            "xcodebuild",
            "-project", "AppMonitor.xcodeproj",
            "-scheme", "AppMonitor",
            "-configuration", "Release",
            "-destination", "platform=macOS",
            "-derivedDataPath", str(build_dir),
            f"MARKETING_VERSION={version}",
            f"CURRENT_PROJECT_VERSION={version}",
            "build",
        ],
        cwd=PROJECT_ROOT,
        quiet=True,
    )
    success("Built Release configuration")

    src_app = build_dir / "Build" / "Products" / "Release" / "AppMonitor.app"
    if not src_app.is_dir():
        error(f"xcodebuild did not produce {src_app}")

    # Lay out the canonical output path (consumed by deploy_releases.py).
    # `ditto` rather than a plain recursive copy: it is the macOS-canonical way
    # to duplicate a bundle, preserving xattrs, resource forks, and symlinks.
    shutil.rmtree(DEST_APP, ignore_errors=True)
    BUNDLE_DIR.mkdir(parents=True, exist_ok=True)
    run(["ditto", str(src_app), str(DEST_APP)], quiet=True)
    success(f"Copied AppMonitor.app to {DEST_APP.relative_to(PROJECT_ROOT)}")

    sign_and_notarize(DEST_APP, allow_notarize=allow_notarize)

    success(f"Built {DEST_APP}")
    return DEST_APP


def main(argv: list[str]) -> None:
    args = [a for a in argv[1:] if a != "--no-notarize"]
    bundle(args[0] if args else None, allow_notarize="--no-notarize" not in argv)


if __name__ == "__main__":
    try:
        main(sys.argv)
    except KeyboardInterrupt:
        raise SystemExit(130)
