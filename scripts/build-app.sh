#!/usr/bin/env bash
# Builds build/MemeMe.app from the Swift package, fills in the version, the update feed and the
# GIPHY API key, and signs the bundle ad hoc. scripts/build-dmg.sh packs it into build/MemeMe.dmg.
#
# Usage:  GIPHY_API_KEY=your-key ./scripts/build-app.sh
#
# Environment (all optional):
#   GIPHY_API_KEY    written into the bundle; without it the key is empty and Web Discover stays
#                    off until a key is set from the menu-bar menu
#   APP_VERSION      CFBundleShortVersionString, e.g. 1.0 (default: the VERSION file)
#   APP_BUILD        CFBundleVersion, a whole number (default: git rev-list --count HEAD)
#   UPDATE_FEED_URL  https URL of the release feed, latest.json (default: empty, so the app never
#                    checks for updates)
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: MemeMe.app can only be built on macOS" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PRODUCT="MemeMe"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$PRODUCT.app"
PLIST_SOURCE="$ROOT/Resources/Info.plist"
PLIST="$APP/Contents/Info.plist"
PLISTBUDDY="/usr/libexec/PlistBuddy"

log() {
  printf '==> %s\n' "$*"
}

# 0. Check the version inputs before spending minutes on a build.
VERSION_NUMBER="${APP_VERSION:-}"
if [[ -z "$VERSION_NUMBER" && -f "$ROOT/VERSION" ]]; then
  VERSION_NUMBER="$(tr -d '[:space:]' < "$ROOT/VERSION")"
fi
VERSION_NUMBER="${VERSION_NUMBER:-1.0}"
if [[ ! "$VERSION_NUMBER" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
  echo "error: APP_VERSION must look like 1, 1.0 or 1.0.2 (got \"$VERSION_NUMBER\")" >&2
  exit 1
fi

BUILD_NUMBER="${APP_BUILD:-}"
if [[ -z "$BUILD_NUMBER" ]]; then
  BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || true)"
fi
BUILD_NUMBER="${BUILD_NUMBER:-0}"
if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "error: APP_BUILD must be a whole number (got \"$BUILD_NUMBER\")" >&2
  exit 1
fi

FEED_URL="${UPDATE_FEED_URL:-}"
FEED_URL_PATTERN=$'^https://[A-Za-z0-9._~:/?#@!$&\'()*+,;=%-]+$'
if [[ -n "$FEED_URL" && ! "$FEED_URL" =~ $FEED_URL_PATTERN ]]; then
  echo "warning: UPDATE_FEED_URL is not a plain https URL; building with updates off" >&2
  FEED_URL=""
fi

# 1. Compile. A universal binary (Apple silicon + Intel) when the toolchain can build one,
#    otherwise a release build for this Mac's architecture. Builds with an update feed must be
#    universal: the app installs them in one click on any Mac, and a thin build would replace a
#    working copy on the other architecture with one that can't run.
log "Building $PRODUCT (release, arm64 + x86_64)"
if swift build -c release --arch arm64 --arch x86_64; then
  BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
elif [[ -n "$FEED_URL" ]]; then
  echo "error: the universal build failed, and builds with UPDATE_FEED_URL set must be universal" >&2
  exit 1
else
  log "Universal build failed; building for this Mac's architecture only"
  swift build -c release
  BIN_DIR="$(swift build -c release --show-bin-path)"
fi

BINARY="$BIN_DIR/$PRODUCT"
if [[ ! -x "$BINARY" ]]; then
  echo "error: built executable not found at $BINARY" >&2
  exit 1
fi
lipo -info "$BINARY" || true
if [[ -n "$FEED_URL" ]]; then
  ARCHS="$(lipo -archs "$BINARY")"
  if [[ " $ARCHS " != *" arm64 "* || " $ARCHS " != *" x86_64 "* ]]; then
    echo "error: builds with UPDATE_FEED_URL set must be universal (arm64 + x86_64); got: $ARCHS" >&2
    exit 1
  fi
fi

# 2. Assemble the bundle.
log "Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$PRODUCT"
cp "$PLIST_SOURCE" "$PLIST"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# 3. Version and update feed. The app compares builds by CFBundleVersion only.
"$PLISTBUDDY" -c "Set :CFBundleShortVersionString $VERSION_NUMBER" "$PLIST"
"$PLISTBUDDY" -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"
log "Version $VERSION_NUMBER ($BUILD_NUMBER)"

"$PLISTBUDDY" -c "Delete :MemeMeUpdateFeedURL" "$PLIST" >/dev/null 2>&1 || true
if [[ -n "$FEED_URL" ]]; then
  "$PLISTBUDDY" -c "Add :MemeMeUpdateFeedURL string $FEED_URL" "$PLIST"
  log "Updates: on ($FEED_URL)"
else
  "$PLISTBUDDY" -c "Add :MemeMeUpdateFeedURL string" "$PLIST"
  log "Updates: off (no UPDATE_FEED_URL)"
fi

# 4. Bake in the GIPHY key (empty string when GIPHY_API_KEY is unset). The key is never printed.
GIPHY_KEY="${GIPHY_API_KEY:-}"
if [[ -n "$GIPHY_KEY" && ! "$GIPHY_KEY" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "warning: GIPHY_API_KEY contains unexpected characters; building without a key" >&2
  GIPHY_KEY=""
fi
"$PLISTBUDDY" -c "Delete :GiphyAPIKey" "$PLIST" >/dev/null 2>&1 || true
if [[ -n "$GIPHY_KEY" ]]; then
  "$PLISTBUDDY" -c "Add :GiphyAPIKey string $GIPHY_KEY" "$PLIST"
  log "GIPHY API key: set"
else
  "$PLISTBUDDY" -c "Add :GiphyAPIKey string" "$PLIST"
  log "GIPHY API key: not set (Web Discover stays off until a key is set from the menu)"
fi
plutil -lint "$PLIST"

# 5. Ad-hoc signature (no Developer ID). No hardened runtime, so no camera entitlement is needed.
log "Signing ad hoc"
codesign --force --sign - "$APP"
codesign --verify --strict --verbose=1 "$APP"

log "Done: $APP"
