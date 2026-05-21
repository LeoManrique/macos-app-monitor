#!/usr/bin/env bash
set -euo pipefail

# Installs App Monitor from the latest GitHub release into /Applications.
# Intended to be curlable:
#   curl -fsSL https://raw.githubusercontent.com/LeoManrique/macos-app-monitor/master/scripts/install.sh | bash

# ── Colors ──
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

TOTAL_STEPS=5
step()    { echo -e "\n${BLUE}[$1/$TOTAL_STEPS]${NC} ${CYAN}$2${NC}"; }
success() { echo -e "  ${GREEN}✓ $1${NC}"; }
warn()    { echo -e "  ${YELLOW}⚠ $1${NC}"; }
error()   { echo -e "  ${RED}✗ $1${NC}"; exit 1; }

REPO="LeoManrique/macos-app-monitor"
API_URL="https://api.github.com/repos/$REPO/releases/latest"
TMP_DIR="/tmp/app-monitor-install"
APP_NAME="AppMonitor.app"
DEST="/Applications/$APP_NAME"

# ── Step 1: Detect platform ──
step 1 "Detecting platform"

OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
case "$ARCH" in
  arm64|aarch64) ARCH="arm64" ;;
  x86_64)        ARCH="amd64" ;;
  *) error "Unsupported architecture: $ARCH" ;;
esac
[ "$OS" = "darwin" ] || error "Unsupported OS: $OS (App Monitor is macOS-only)"
PLATFORM="macOS-$ARCH"
success "Platform: $PLATFORM"

# ── Step 2: Stop any running instance ──
# A running app holds an open file lock on its binary; replacing the bundle
# on disk while the old copy is running leaves you with a half-old/half-new
# install until the next launch. Kill it first.
step 2 "Stopping running instance"

RUNNING=()
for p in "App Monitor" AppMonitor activity-monitor; do
  if pgrep -f "$p" >/dev/null 2>&1; then RUNNING+=("$p"); fi
done

if [ ${#RUNNING[@]} -eq 0 ]; then
  success "No running instances"
else
  for p in "${RUNNING[@]}"; do
    pkill -TERM -f "$p" 2>/dev/null || true
  done
  for _ in $(seq 1 16); do
    STILL=0
    for p in "${RUNNING[@]}"; do
      if pgrep -f "$p" >/dev/null 2>&1; then STILL=1; fi
    done
    [ "$STILL" = "0" ] && break
    sleep 0.5
  done
  for p in "${RUNNING[@]}"; do
    if pgrep -f "$p" >/dev/null 2>&1; then
      warn "Force-killing $p (graceful stop timed out)"
      pkill -KILL -f "$p" 2>/dev/null || true
    fi
  done
  success "Stopped: ${RUNNING[*]}"
fi

# ── Step 3: Fetch latest release metadata ──
step 3 "Fetching latest release from GitHub"

RELEASE_JSON=$(curl -fsSL -H "Accept: application/vnd.github.v3+json" "$API_URL" 2>/dev/null) \
  || error "Failed to fetch release info from GitHub. Check your internet connection."

TAG=$(echo "$RELEASE_JSON" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
[ -z "$TAG" ] && error "Could not parse release tag from GitHub API"

VERSION="${TAG#v}"
success "Latest version: $VERSION (tag: $TAG)"

# ── Step 4: Download artifact ──
step 4 "Downloading $APP_NAME"

ARTIFACT="AppMonitor-$VERSION-$PLATFORM.zip"
DOWNLOAD_URL=$(echo "$RELEASE_JSON" | grep -o '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*'"$ARTIFACT"'"' | head -1 | sed 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
[ -z "$DOWNLOAD_URL" ] && error "Could not find artifact $ARTIFACT in release $TAG"

rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"

curl -fSL --progress-bar -o "$TMP_DIR/$ARTIFACT" "$DOWNLOAD_URL" \
  || error "Failed to download $ARTIFACT"
success "Downloaded $ARTIFACT"

# ── Step 5: Install ──
step 5 "Installing to /Applications"

# `ditto -x -k` unpacks the zip preserving the bundle structure (xattrs,
# resource forks, symlinks) — the inverse of how deploy_releases.sh packs it.
ditto -x -k "$TMP_DIR/$ARTIFACT" "$TMP_DIR"
[ -d "$TMP_DIR/$APP_NAME" ] || error "Expected $APP_NAME inside $ARTIFACT, but didn't find it"

if [ -d "$DEST" ]; then
  rm -rf "$DEST"
  warn "Replaced existing $DEST"
fi
mv "$TMP_DIR/$APP_NAME" "$DEST"

# Strip the quarantine xattr Gatekeeper adds to anything downloaded via curl.
# Without this, ad-hoc-signed bundles trigger a "developer cannot be verified"
# dialog and won't open with a double-click. Stripping is the standard escape
# hatch for open-source / unsigned tools.
xattr -cr "$DEST" 2>/dev/null || true
success "Installed: $DEST"

rm -rf "$TMP_DIR"

echo -e "\n${GREEN}═══ App Monitor $VERSION installed ═══${NC}"
echo -e "  ${CYAN}Open from /Applications, Spotlight, or:  open -a 'App Monitor'${NC}"
