#!/usr/bin/env bash
# Builds build/MemeMe.app from the Swift package, fills in the version, the update feed and the
# GIPHY API key, and signs the bundle: ad hoc by default, or with a Developer ID for releases.
# scripts/build-dmg.sh packs it into build/MemeMe.dmg.
#
# Usage:  GIPHY_API_KEY=your-key ./scripts/build-app.sh
#
# Environment (all optional):
#   GIPHY_API_KEY      written into the bundle; without it the key is empty and Web Discover stays
#                      off until a key is set from the menu-bar menu
#   APP_VERSION        CFBundleShortVersionString, e.g. 1.0 (default: the VERSION file)
#   APP_BUILD          CFBundleVersion, a whole number (default: git rev-list --count HEAD)
#   UPDATE_FEED_URL    https URL of the release feed, latest.json (default: empty, so the app never
#                      checks for updates)
#   CODESIGN_IDENTITY  "-" (the default, also when empty) signs ad hoc. A "Developer ID Application"
#                      identity in the keychain (its name or SHA-1) signs with the hardened runtime,
#                      a secure timestamp and Resources/MemeMe.entitlements, ready for
#                      scripts/notarize.sh
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
ENTITLEMENTS="$ROOT/Resources/MemeMe.entitlements"
SIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
SIGN_ATTEMPTS=3

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

if [[ "$SIGN_IDENTITY" != "-" ]]; then
  if [[ ! -f "$ENTITLEMENTS" ]]; then
    echo "error: $ENTITLEMENTS not found; Developer ID builds need it for camera access" >&2
    exit 1
  fi
  plutil -lint "$ENTITLEMENTS"
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

# 5. Sign. Ad hoc by default: no hardened runtime, so no camera entitlement is needed.
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  log "Signing ad hoc"
  codesign --force --sign - "$APP"
  codesign --verify --strict --verbose=1 "$APP"
  log "Done: $APP"
  exit 0
fi

# Developer ID: the hardened runtime (required for notarization) blocks the camera unless the
# entitlement grants it, and the secure timestamp keeps the signature valid after the certificate
# expires. The timestamp server is sometimes busy, so signing gets a few attempts.
log "Signing with a Developer ID (hardened runtime, secure timestamp)"
attempt=1
until codesign --force --timestamp --options runtime --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" "$APP"; do
  if (( attempt >= SIGN_ATTEMPTS )); then
    echo "error: codesign failed $SIGN_ATTEMPTS times" >&2
    exit 1
  fi
  attempt=$((attempt + 1))
  log "codesign failed; retrying in 10 s (attempt $attempt of $SIGN_ATTEMPTS)"
  sleep 10
done
codesign --verify --deep --strict --verbose=2 "$APP"

# The signer and team are public (they are in every copy of the app); print them for the log.
SIGNATURE_INFO="$(codesign -dv --verbose=2 "$APP" 2>&1)"
grep -E '^(Identifier|Authority|Timestamp|TeamIdentifier)=|^CodeDirectory ' <<< "$SIGNATURE_INFO" || true
if ! grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime' <<< "$SIGNATURE_INFO"; then
  echo "error: the signature has no hardened runtime" >&2
  exit 1
fi
if ! grep -q '^Timestamp=' <<< "$SIGNATURE_INFO"; then
  echo "error: the signature has no secure timestamp" >&2
  exit 1
fi
if ! grep -Eq '^TeamIdentifier=[A-Z0-9]{10}$' <<< "$SIGNATURE_INFO"; then
  echo "error: the signature has no Team ID; is $SIGN_IDENTITY a Developer ID identity?" >&2
  exit 1
fi

log "Done: $APP"
