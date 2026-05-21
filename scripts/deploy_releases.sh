#!/usr/bin/env bash
set -euo pipefail

# Releases a new version of App Monitor:
#   1. Validates prerequisites (gh, xcodebuild, codesign, git, xcodegen)
#   2. Resolves / bumps version in project.yml
#   3. Tags the release
#   4. Bundles AppMonitor.app via scripts/bundle.sh (drives xcodebuild)
#   5. Zips and uploads to GitHub Releases
#
# Usage: scripts/deploy_releases.sh [x.y.z]
#   If a version is passed and it's higher than project.yml's, the script
#   bumps and commits project.yml first so the tag points at the bump commit.
#   Without an arg, uses whatever version is in project.yml.

# ── Colors ──
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

TOTAL_STEPS=5
REPO="LeoManrique/macos-app-monitor"
step()    { echo -e "\n${BLUE}[$1/$TOTAL_STEPS]${NC} ${CYAN}$2${NC}"; }
success() { echo -e "  ${GREEN}✓ $1${NC}"; }
warn()    { echo -e "  ${YELLOW}⚠ $1${NC}"; }
error()   { echo -e "  ${RED}✗ $1${NC}"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

VERSION="${1:-}"

# ── Step 1: Validate prerequisites ──
step 1 "Validating prerequisites"

[ "$(uname -s)" = "Darwin" ] || error "This script only runs on macOS"
[ "$(uname -m)" = "arm64" ]  || warn "Building on non-arm64; release target is Apple Silicon"

for cmd in gh xcodebuild xcodegen codesign git zip; do
  command -v "$cmd" &>/dev/null || error "$cmd is not installed"
  success "$cmd found"
done

gh auth status &>/dev/null || error "gh CLI not authenticated. Run: gh auth login"
success "gh authenticated"

# Working tree must be clean — otherwise we can't be sure what's in the tag.
if ! git diff --quiet || ! git diff --cached --quiet; then
  error "Working tree is dirty — commit or stash changes before releasing"
fi
success "Working tree clean"

# ── Step 2: Determine + bump version ──
step 2 "Determining version"

CURRENT_VERSION=$(awk -F'"' '/^[[:space:]]*MARKETING_VERSION:/ {print $2; exit}' project.yml)
[ -z "$CURRENT_VERSION" ] && error "Could not read MARKETING_VERSION from project.yml"

if [ -z "$VERSION" ]; then
  VERSION="$CURRENT_VERSION"
  success "Using version from project.yml: $VERSION"
else
  [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || error "Version must be x.y.z (got: $VERSION)"
  if [ "$VERSION" = "$CURRENT_VERSION" ]; then
    success "Version $VERSION already in project.yml, no bump needed"
  else
    HIGHER=$(printf '%s\n%s\n' "$CURRENT_VERSION" "$VERSION" | sort -V | tail -1)
    [ "$HIGHER" = "$VERSION" ] || error "New version $VERSION is not greater than current $CURRENT_VERSION"
    # Update both MARKETING_VERSION and CURRENT_PROJECT_VERSION in project.yml.
    sed -i.bak \
      -e "s/MARKETING_VERSION: \"$CURRENT_VERSION\"/MARKETING_VERSION: \"$VERSION\"/" \
      -e "s/CURRENT_PROJECT_VERSION: \"$CURRENT_VERSION\"/CURRENT_PROJECT_VERSION: \"$VERSION\"/" \
      project.yml
    rm -f project.yml.bak
    # Regenerate xcodeproj so its embedded settings line up before tagging.
    xcodegen generate >/dev/null
    git add project.yml AppMonitor.xcodeproj
    git commit -m "Bump version to $VERSION"
    git push
    success "Bumped $CURRENT_VERSION → $VERSION and pushed"
  fi
fi

TAG="v$VERSION"
ARCH=$(uname -m)
case "$ARCH" in
  arm64|aarch64) ARCH="arm64" ;;
  x86_64)        ARCH="amd64" ;;
esac
PLATFORM="macOS-$ARCH"
success "Version: $VERSION (tag: $TAG), platform: $PLATFORM"

# ── Step 3: Create git tag ──
step 3 "Tagging release"

if git rev-parse "$TAG" &>/dev/null; then
  warn "Tag $TAG already exists, skipping"
else
  git tag -a "$TAG" -m "Release $TAG"
  git push origin "$TAG"
  success "Created and pushed tag $TAG"
fi

# ── Step 4: Bundle + zip ──
step 4 "Bundling AppMonitor.app"

"$SCRIPT_DIR/bundle.sh" "$VERSION"
APP_PATH="$PROJECT_ROOT/target/release/bundle/AppMonitor.app"
[ -d "$APP_PATH" ] || error "Bundle script did not produce $APP_PATH"

DIST_DIR="$PROJECT_ROOT/dist"
mkdir -p "$DIST_DIR"
ARTIFACT="AppMonitor-$VERSION-$PLATFORM.zip"
ARTIFACT_PATH="$DIST_DIR/$ARTIFACT"
rm -f "$ARTIFACT_PATH"
# `ditto -c -k --keepParent` is the macOS-canonical way to zip an .app:
# preserves resource forks, xattrs, and symlinks (plain `zip` strips them and
# can produce a bundle that Finder refuses to open after extraction).
ditto -c -k --keepParent "$APP_PATH" "$ARTIFACT_PATH"
success "Packaged: $ARTIFACT ($(du -h "$ARTIFACT_PATH" | cut -f1))"

# ── Step 5: Upload to GitHub Release ──
step 5 "Uploading to GitHub Release"

if gh release view "$TAG" --repo "$REPO" &>/dev/null; then
  warn "Release $TAG already exists, uploading artifacts (clobber)"
  gh release upload "$TAG" "$ARTIFACT_PATH" --clobber --repo "$REPO"
else
  gh release create "$TAG" "$ARTIFACT_PATH" \
    --repo "$REPO" \
    --title "App Monitor $TAG" \
    --notes "## App Monitor $TAG

A minimal SwiftUI alternative for macOS Activity Monitor's memory view, with processes grouped by \`.app\` so you can see how much memory you'd reclaim by quitting an app.

### Install

\`\`\`
curl -fsSL https://raw.githubusercontent.com/$REPO/master/scripts/install.sh | bash
\`\`\`

Or download \`$ARTIFACT\` below and drag \`AppMonitor.app\` into \`/Applications\`. The bundle is ad-hoc signed, so on first launch right-click → Open (or run \`xattr -cr /Applications/AppMonitor.app\` — the install script does this for you).

### Requirements

- macOS 26 (Apple Silicon)"
fi
success "Uploaded $ARTIFACT to release $TAG"

echo -e "\n${GREEN}═══ Release $TAG complete ($PLATFORM) ═══${NC}"
echo -e "  ${CYAN}https://github.com/$REPO/releases/tag/$TAG${NC}"
