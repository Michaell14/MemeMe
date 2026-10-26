#!/usr/bin/env bash
# Builds build/MemeMe.app from the Swift package, fills in the GIPHY API key, signs the bundle
# ad hoc and zips it as build/MemeMe.zip.
#
# Usage:  GIPHY_API_KEY=your-key ./scripts/build-app.sh
#         (without the variable the app is built with an empty key; Web Discover then stays
#          off until a key is set from the menu-bar menu)
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
ZIP="$BUILD_DIR/$PRODUCT.zip"
PLIST_SOURCE="$ROOT/Resources/Info.plist"
PLIST="$APP/Contents/Info.plist"
PLISTBUDDY="/usr/libexec/PlistBuddy"

log() {
  printf '==> %s\n' "$*"
}

# 1. Compile. A universal binary (Apple silicon + Intel) when the toolchain can build one,
#    otherwise a release build for this Mac's architecture.
log "Building $PRODUCT (release, arm64 + x86_64)"
if swift build -c release --arch arm64 --arch x86_64; then
  BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
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

# 2. Assemble the bundle.
log "Assembling $APP"
rm -rf "$APP" "$ZIP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$PRODUCT"
cp "$PLIST_SOURCE" "$PLIST"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# 3. Bake in the GIPHY key (empty string when GIPHY_API_KEY is unset). The key is never printed.
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

# 4. Ad-hoc signature (no Developer ID). No hardened runtime, so no camera entitlement is needed.
log "Signing ad hoc"
codesign --force --sign - "$APP"
codesign --verify --strict --verbose=1 "$APP"

# 5. Zip for distribution (keeps the .app folder at the top of the archive).
log "Zipping $ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

log "Done: $APP"
log "      $ZIP"
