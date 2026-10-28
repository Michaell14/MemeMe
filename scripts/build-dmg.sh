#!/usr/bin/env bash
# Packs build/MemeMe.app into build/MemeMe.dmg. Opening it shows the drag-to-install window: the app
# on the left, an arrow, a link to /Applications on the right, on a background from Resources/DMG.
# dmgbuild writes that layout (scripts/dmg-settings.py); it is installed with pinned hashes into
# build/.dmgbuild-venv and needs Python 3.10 or later. Without one, the DMG holds the same two items
# in Finder's default window.
#
# The image is compressed (UDZO), verified, signed on Developer ID builds, then mounted and checked
# the way users and the in-app updater see it: the app's signature verifies and the Applications
# link is there. Notarizing is a separate step (scripts/notarize.sh) that runs after this one.
#
# Usage:  ./scripts/build-dmg.sh   (run scripts/build-app.sh first)
#
# Environment (all optional):
#   CODESIGN_IDENTITY  "-" or empty (the default) leaves the image unsigned, as for ad-hoc builds, and
#                      its window says how to get past Gatekeeper. A "Developer ID Application"
#                      identity (name or SHA-1) signs it with a secure timestamp, ready for
#                      scripts/notarize.sh, and uses the plain window.
#   PYTHON             the Python 3.10+ for dmgbuild (default: python3)
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
VENV="$BUILD_DIR/.dmgbuild-venv"
ATTEMPTS=3
SIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

log() {
  printf '==> %s\n' "$*"
}

fail() {
  echo "error: $*" >&2
  exit 1
}

[[ -d "$APP" ]] || fail "$APP not found; run scripts/build-app.sh first"

TMP_ROOT="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "${TMP_ROOT%/}/mememe-dmg.XXXXXX")"
MOUNT="$WORK/mount"
cleanup() {
  if [[ -d "$MOUNT" ]]; then
    hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# 1. dmgbuild, in a virtual environment of its own.
PYTHON="${PYTHON:-python3}"
LAYOUT=0
if command -v "$PYTHON" >/dev/null 2>&1 \
    && "$PYTHON" -c 'import sys; sys.exit(sys.version_info < (3, 10))' 2>/dev/null; then
  if [[ ! -x "$VENV/bin/python" ]] || ! "$VENV/bin/python" -c '' 2>/dev/null; then
    log "Creating $VENV"
    rm -rf "$VENV"
    "$PYTHON" -m venv "$VENV"
  fi
  log "Installing dmgbuild"
  "$VENV/bin/python" -m pip install --quiet --disable-pip-version-check --require-hashes \
    --only-binary :all: -r "$ROOT/scripts/dmgbuild-requirements.txt"
  LAYOUT=1
else
  echo "warning: no Python 3.10 or later ($PYTHON); building the DMG without its window layout" >&2
fi

# 2. Create the image. Developer ID builds are notarized next, so they get the plain background;
#    ad-hoc builds also say how to get past Gatekeeper. hdiutil on GitHub's runners sometimes fails
#    with "Resource busy", so it gets a few attempts.
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  BACKGROUND="$ROOT/Resources/DMG/background.png"
else
  BACKGROUND="$ROOT/Resources/DMG/background-open-anyway.png"
fi

# Runs as an `until` condition, where set -e is off, so every step is chained.
create_image() {
  if (( LAYOUT )); then
    "$VENV/bin/python" -m dmgbuild -s "$ROOT/scripts/dmg-settings.py" \
      -D app="$APP" -D background="$BACKGROUND" "$PRODUCT" "$DMG"
  else
    local staging="$WORK/staging"
    rm -rf "$staging" && mkdir -p "$staging" \
      && ditto "$APP" "$staging/$PRODUCT.app" \
      && ln -s /Applications "$staging/Applications" \
      && hdiutil create -volname "$PRODUCT" -srcfolder "$staging" -fs HFS+ -format UDZO \
        -imagekey zlib-level=9 -ov "$DMG"
  fi
}

log "Creating $DMG"
rm -f "$DMG"
attempt=1
until create_image; do
  if (( attempt >= ATTEMPTS )); then
    fail "creating the image failed $ATTEMPTS times"
  fi
  attempt=$((attempt + 1))
  log "Creating the image failed; retrying in 5 s (attempt $attempt of $ATTEMPTS)"
  rm -f "$DMG"
  sleep 5
done

log "Verifying $DMG"
hdiutil verify "$DMG"

# 3. Developer ID builds: sign the image too, so it can be notarized and Gatekeeper checks it on
#    open. The timestamp server is sometimes busy, so signing gets a few attempts.
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  log "Signing $DMG with a Developer ID (secure timestamp)"
  attempt=1
  until codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"; do
    if (( attempt >= ATTEMPTS )); then
      fail "codesign failed $ATTEMPTS times"
    fi
    attempt=$((attempt + 1))
    log "codesign failed; retrying in 10 s (attempt $attempt of $ATTEMPTS)"
    sleep 10
  done
  codesign --verify --strict --verbose=2 "$DMG"
  codesign -dv --verbose=2 "$DMG" 2>&1 | grep -E '^(Authority|Timestamp|TeamIdentifier)=' || true
fi

# 4. Check the image the way users and the in-app updater see it.
log "Checking the mounted image"
mkdir -p "$MOUNT"
hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$MOUNT" "$DMG" >/dev/null
codesign --verify --deep --strict "$MOUNT/$PRODUCT.app" || fail "the app's signature doesn't verify in the DMG"
[[ "$(readlink "$MOUNT/Applications")" == "/Applications" ]] || fail "the Applications link is missing"
if (( LAYOUT )); then
  [[ -f "$MOUNT/.DS_Store" && -f "$MOUNT/.background.tiff" ]] || fail "the window layout is missing"
fi
hdiutil detach "$MOUNT" >/dev/null
rmdir "$MOUNT"

# 5. Print what CI publishes. On release builds, stapling the notarization ticket afterwards
#    changes both; scripts/publish-release.sh measures the final image.
SIZE="$(wc -c < "$DMG" | tr -d '[:space:]')"
SHA256="$(shasum -a 256 "$DMG" | awk '{ print $1 }')"
if (( LAYOUT )); then
  log "Layout: drag to Applications, $(basename "$BACKGROUND")"
else
  log "Layout: Finder default"
fi
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  log "Signature: ad-hoc app, unsigned DMG"
else
  log "Signature: Developer ID (notarized in the next step)"
fi
log "Size: $SIZE bytes"
log "SHA-256: $SHA256"
log "Done: $DMG"
