#!/usr/bin/env bash
set -euo pipefail

# Builds AppMonitor.app from the release binary + assets/.
# Output: $PROJECT_ROOT/target/release/bundle/AppMonitor.app
# Usage:  scripts/bundle.sh [VERSION]
#   VERSION defaults to Cargo.toml's [package].version.

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
success() { echo -e "  ${GREEN}✓ $1${NC}"; }
warn()    { echo -e "  ${YELLOW}⚠ $1${NC}"; }
error()   { echo -e "  ${RED}✗ $1${NC}"; exit 1; }
info()    { echo -e "${CYAN}$1${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

# Resolve VERSION (arg → Cargo.toml).
VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  VERSION=$(sed -n 's/^version = "\([^"]*\)".*/\1/p' Cargo.toml | head -1)
  [ -z "$VERSION" ] && error "Could not read version from Cargo.toml"
fi
info "Bundling App Monitor $VERSION"

# Locate required source assets.
BINARY="target/release/activity-monitor"
PLIST_SRC="assets/Info.plist"
ICON_SRC="assets/AppIcon.icns"
[ -f "$BINARY" ]    || error "Missing $BINARY — run 'cargo build --release' first"
[ -f "$PLIST_SRC" ] || error "Missing $PLIST_SRC"
[ -f "$ICON_SRC" ]  || error "Missing $ICON_SRC — drop the icns there before bundling"

# Lay out the bundle from scratch each time so removed assets don't linger.
BUNDLE_DIR="target/release/bundle"
APP="$BUNDLE_DIR/AppMonitor.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Binary → Contents/MacOS/ under the CFBundleExecutable name.
cp "$BINARY" "$APP/Contents/MacOS/activity-monitor"
chmod +x "$APP/Contents/MacOS/activity-monitor"
success "Copied binary"

# Info.plist → fill in {{VERSION}}.
sed "s/{{VERSION}}/$VERSION/g" "$PLIST_SRC" > "$APP/Contents/Info.plist"
success "Wrote Info.plist (version $VERSION)"

# Icon → Resources/. Filename must match CFBundleIconFile (no extension).
cp "$ICON_SRC" "$APP/Contents/Resources/AppIcon.icns"
success "Copied AppIcon.icns"

# Ad-hoc sign. We don't have a Developer ID Application cert, so users will
# need to bypass Gatekeeper (xattr -cr — install.sh does this automatically,
# or right-click → Open on first launch). --force re-signs over any existing
# signature; --deep covers nested resources even though we ship none today.
if codesign --force --deep --sign - "$APP" 2>/dev/null; then
  success "Ad-hoc signed"
else
  warn "codesign failed (continuing — bundle still usable with xattr -cr)"
fi

# Verify the bundle actually launches as an app (not just files in a folder).
codesign --verify --verbose=2 "$APP" >/dev/null 2>&1 || warn "codesign --verify failed"

success "Built $APP"
