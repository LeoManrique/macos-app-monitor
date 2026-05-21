#!/usr/bin/env bash
set -euo pipefail

# Releases a new version of App Monitor:
#   1. Validates prerequisites (gh, cargo, codesign, git)
#   2. Resolves / bumps version in Cargo.toml
#   3. Tags the release
#   4. cargo build --release
#   5. Bundles AppMonitor.app via scripts/bundle.sh
#   6. Zips and uploads to GitHub Releases
#
# Usage: scripts/deploy_releases.sh [x.y.z]
#   If a version is passed and it's higher than Cargo.toml's, the script bumps
#   and commits Cargo.toml first so the tag points at the bump commit.
#   Without an arg, uses whatever version is in Cargo.toml.

# ── Colors ──
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

TOTAL_STEPS=6
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

# This project is macOS-only — abort early on other hosts so the failure mode
# isn't a confusing codesign / iconutil error halfway through.
[ "$(uname -s)" = "Darwin" ] || error "This script only runs on macOS"
[ "$(uname -m)" = "arm64" ]  || warn "Building on non-arm64; release target is Apple Silicon"

for cmd in gh cargo codesign git zip; do
  command -v "$cmd" &>/dev/null || error "$cmd is not installed"
  success "$cmd found"
done

gh auth status &>/dev/null || error "gh CLI not authenticated. Run: gh auth login"
success "gh authenticated"

# Working tree must be clean — otherwise we can't be sure what's in the tag.
# (Cargo.lock churn is allowed since cargo build can touch it.)
if ! git diff --quiet || ! git diff --cached --quiet; then
  error "Working tree is dirty — commit or stash changes before releasing"
fi
success "Working tree clean"

# ── Step 2: Determine version ──
step 2 "Determining version"

CURRENT_VERSION=$(sed -n 's/^version = "\([^"]*\)".*/\1/p' Cargo.toml | head -1)
[ -z "$CURRENT_VERSION" ] && error "Could not read version from Cargo.toml"

if [ -z "$VERSION" ]; then
  VERSION="$CURRENT_VERSION"
  success "Using version from Cargo.toml: $VERSION"
else
  [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || error "Version must be x.y.z (got: $VERSION)"
  if [ "$VERSION" = "$CURRENT_VERSION" ]; then
    success "Version $VERSION already in Cargo.toml, no bump needed"
  else
    HIGHER=$(printf '%s\n%s\n' "$CURRENT_VERSION" "$VERSION" | sort -V | tail -1)
    [ "$HIGHER" = "$VERSION" ] || error "New version $VERSION is not greater than current $CURRENT_VERSION"
    # sed -i.bak + rm is the portable form (works with both BSD and GNU sed).
    # Match only the top-level [package] version line — match-once via the first
    # `^version = "x.y.z"` we see (Cargo.toml has it on line 3, before deps).
    sed -i.bak "0,/^version = \"$CURRENT_VERSION\"/s//version = \"$VERSION\"/" Cargo.toml
    rm -f Cargo.toml.bak
    # Touch Cargo.lock too so cargo updates the recorded version.
    cargo update -p activity-monitor --precise "$VERSION" >/dev/null 2>&1 || true
    git add Cargo.toml Cargo.lock
    git commit -m "Bump version to $VERSION"
    git push
    success "Bumped $CURRENT_VERSION → $VERSION and pushed"
  fi
fi

TAG="v$VERSION"
success "Version: $VERSION (tag: $TAG)"

ARCH=$(uname -m)
case "$ARCH" in
  arm64|aarch64) ARCH="arm64" ;;
  x86_64)        ARCH="amd64" ;;
esac
PLATFORM="macOS-$ARCH"
success "Platform: $PLATFORM"

# ── Step 3: Create git tag ──
step 3 "Tagging release"

if git rev-parse "$TAG" &>/dev/null; then
  warn "Tag $TAG already exists, skipping"
else
  git tag -a "$TAG" -m "Release $TAG"
  git push origin "$TAG"
  success "Created and pushed tag $TAG"
fi

# ── Step 4: Build ──
step 4 "Building release binary"

cargo build --release
[ -f "target/release/activity-monitor" ] || error "Build did not produce target/release/activity-monitor"
success "Built target/release/activity-monitor"

# ── Step 5: Bundle + zip ──
step 5 "Bundling AppMonitor.app"

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

# ── Step 6: Upload to GitHub Release ──
step 6 "Uploading to GitHub Release"

if gh release view "$TAG" --repo "$REPO" &>/dev/null; then
  warn "Release $TAG already exists, uploading artifacts (clobber)"
  gh release upload "$TAG" "$ARTIFACT_PATH" --clobber --repo "$REPO"
else
  gh release create "$TAG" "$ARTIFACT_PATH" \
    --repo "$REPO" \
    --title "App Monitor $TAG" \
    --notes "## App Monitor $TAG

A minimal GPUI alternative for macOS Activity Monitor's memory view, with processes grouped by \`.app\` so you can see how much memory you'd reclaim by quitting an app.

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
