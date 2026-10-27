#!/usr/bin/env bash
# Packs build/MemeMe.app into build/MemeMe.dmg: the app next to a link to /Applications, so
# installing is one drag. The image is compressed (UDZO) and verified.
#
# Usage:  ./scripts/build-dmg.sh   (run scripts/build-app.sh first)
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: MemeMe.dmg can only be built on macOS" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PRODUCT="MemeMe"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$PRODUCT.app"
DMG="$BUILD_DIR/$PRODUCT.dmg"
ATTEMPTS=3

log() {
  printf '==> %s\n' "$*"
}

if [[ ! -d "$APP" ]]; then
  echo "error: $APP not found; run scripts/build-app.sh first" >&2
  exit 1
fi

TMP_ROOT="${TMPDIR:-/tmp}"
STAGING="$(mktemp -d "${TMP_ROOT%/}/mememe-dmg.XXXXXX")"
cleanup() {
  rm -rf "$STAGING"
}
trap cleanup EXIT

# 1. Stage the volume's contents: the app and the Applications link.
log "Staging $PRODUCT.app"
ditto "$APP" "$STAGING/$PRODUCT.app"
ln -s /Applications "$STAGING/Applications"

# 2. Create the image. hdiutil on GitHub's runners sometimes fails with "Resource busy", so
#    it gets a few attempts.
log "Creating $DMG"
rm -f "$DMG"
attempt=1
until hdiutil create -volname "$PRODUCT" -srcfolder "$STAGING" -fs HFS+ -format UDZO \
    -imagekey zlib-level=9 -ov "$DMG"; do
  if (( attempt >= ATTEMPTS )); then
    echo "error: hdiutil create failed $ATTEMPTS times" >&2
    exit 1
  fi
  attempt=$((attempt + 1))
  log "hdiutil create failed; retrying in 5 s (attempt $attempt of $ATTEMPTS)"
  rm -f "$DMG"
  sleep 5
done

# 3. Check the image and print what CI publishes.
log "Verifying $DMG"
hdiutil verify "$DMG"

SIZE="$(wc -c < "$DMG" | tr -d '[:space:]')"
SHA256="$(shasum -a 256 "$DMG" | awk '{ print $1 }')"
log "Size: $SIZE bytes"
log "SHA-256: $SHA256"
log "Done: $DMG"
