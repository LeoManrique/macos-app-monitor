#!/usr/bin/env bash
set -euo pipefail

# Builds AppMonitor.app from the Xcode project.
# Output: $PROJECT_ROOT/target/release/bundle/AppMonitor.app
# Usage:  scripts/bundle.sh [VERSION]
#   VERSION defaults to the project's MARKETING_VERSION (see project.yml).
#   When set, both MARKETING_VERSION and CURRENT_PROJECT_VERSION are
#   overridden for this build via xcodebuild settings.

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
success() { echo -e "  ${GREEN}✓ $1${NC}"; }
warn()    { echo -e "  ${YELLOW}⚠ $1${NC}"; }
error()   { echo -e "  ${RED}✗ $1${NC}"; exit 1; }
info()    { echo -e "${CYAN}$1${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  # Pull from project.yml so callers without an explicit arg still get the
  # right version baked into Info.plist.
  VERSION=$(awk -F'"' '/^[[:space:]]*MARKETING_VERSION:/ {print $2; exit}' project.yml)
  [ -z "$VERSION" ] && error "Could not read MARKETING_VERSION from project.yml"
fi
info "Bundling App Monitor $VERSION"

# Ensure the Xcode project is up to date. xcodegen is fast and idempotent;
# running it every time keeps the project in sync with project.yml.
if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate >/dev/null
  success "Regenerated AppMonitor.xcodeproj"
else
  [ -d "AppMonitor.xcodeproj" ] || error "xcodegen not installed and AppMonitor.xcodeproj missing — install xcodegen or commit the project"
  warn "xcodegen not found; using existing AppMonitor.xcodeproj as-is"
fi

# Build into a local DerivedData so the script is self-contained and
# repeatable — no dependency on Xcode's global ~/Library cache.
BUILD_DIR="$PROJECT_ROOT/build"
rm -rf "$BUILD_DIR"
xcodebuild \
  -project AppMonitor.xcodeproj \
  -scheme AppMonitor \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$BUILD_DIR" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$VERSION" \
  build >/dev/null
success "Built Release configuration"

SRC_APP="$BUILD_DIR/Build/Products/Release/AppMonitor.app"
[ -d "$SRC_APP" ] || error "xcodebuild did not produce $SRC_APP"

# Lay out the canonical output path (consumed by deploy_releases.sh).
BUNDLE_DIR="target/release/bundle"
DEST_APP="$BUNDLE_DIR/AppMonitor.app"
rm -rf "$DEST_APP"
mkdir -p "$BUNDLE_DIR"
cp -R "$SRC_APP" "$DEST_APP"
success "Copied AppMonitor.app to $DEST_APP"

# Ad-hoc sign. No Developer ID — users will need to bypass Gatekeeper
# (xattr -cr — install.sh does this automatically, or right-click → Open
# on first launch). --force re-signs over the Xcode default ad-hoc signature.
if codesign --force --deep --sign - "$DEST_APP" 2>/dev/null; then
  success "Ad-hoc signed"
else
  warn "codesign failed (continuing — bundle still usable with xattr -cr)"
fi

codesign --verify --verbose=2 "$DEST_APP" >/dev/null 2>&1 || warn "codesign --verify failed"

success "Built $DEST_APP"
