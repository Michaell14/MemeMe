#!/usr/bin/env bash
# Packs build/MemeMe.app into build/MemeMe.dmg. Opening it shows the drag-to-install window: the app
# on the left, an arrow, a link to /Applications on the right, on a background from Resources/DMG.
# dmgbuild writes that layout (scripts/dmg-settings.py); it is installed with pinned hashes into
# build/.dmgbuild-venv and needs Python 3.10 or later. Without one, the DMG holds the same two items
# in Finder's default window.
#
# With a Developer ID the DMG is signed as well, and with notarization credentials it is notarized
# and the ticket is stapled to it, so Gatekeeper opens MemeMe without asking. The image is
# compressed (UDZO) and checked: it mounts, the app's signature verifies, the Applications link is
# there.
#
# Usage:  ./scripts/build-dmg.sh   (run scripts/build-app.sh first)
#
# Environment (all optional):
#   CODESIGN_IDENTITY  the "Developer ID Application" identity build-app.sh signed with (name or
#                      SHA-1); default "-", ad hoc, which leaves the DMG unsigned
#   APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD
#                      notarize with this Apple ID, team ID and app-specific password: all three or
#                      none, and only with CODESIGN_IDENTITY
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

log() {
  printf '==> %s\n' "$*"
}

fail() {
  echo "error: $*" >&2
  exit 1
}

[[ -d "$APP" ]] || fail "$APP not found; run scripts/build-app.sh first"

SIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
NOTARIZE=0
if [[ -n "${APPLE_ID:-}" || -n "${APPLE_TEAM_ID:-}" || -n "${APPLE_APP_PASSWORD:-}" ]]; then
  [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" ]] \
    || fail "notarization needs all of APPLE_ID, APPLE_TEAM_ID and APPLE_APP_PASSWORD"
  [[ "$SIGN_IDENTITY" != "-" ]] \
    || fail "notarization needs a Developer ID signature: set CODESIGN_IDENTITY (and build the app with it)"
  NOTARIZE=1
fi

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

# 2. Create the image. Notarized builds get the plain background; the others also say how to get
#    past Gatekeeper. hdiutil on GitHub's runners sometimes fails with "Resource busy", so it gets a
#    few attempts.
if (( NOTARIZE )); then
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

# 3. Sign and notarize.
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  log "Signing $DMG"
  codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
fi

if (( NOTARIZE )); then
  log "Notarizing $DMG (usually a few minutes)"
  NOTARY_RESULT="$WORK/notary.json"
  submit_status=0
  xcrun notarytool submit "$DMG" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" --wait --timeout 30m --output-format json \
    > "$NOTARY_RESULT" || submit_status=$?
  notary_status="$(plutil -extract status raw -o - "$NOTARY_RESULT" 2>/dev/null || true)"
  notary_id="$(plutil -extract id raw -o - "$NOTARY_RESULT" 2>/dev/null || true)"
  if [[ "$notary_status" != "Accepted" ]]; then
    cat "$NOTARY_RESULT" >&2 || true
    if [[ -n "$notary_id" ]]; then
      xcrun notarytool log "$notary_id" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
        --password "$APPLE_APP_PASSWORD" >&2 || true
    fi
    fail "notarization ended with status \"${notary_status:-unknown}\" (notarytool exit $submit_status)"
  fi
  log "Notarized ($notary_id); stapling the ticket"
  xcrun stapler staple "$DMG"
fi

# 4. Check the image the way users and the in-app updater see it.
log "Verifying $DMG"
hdiutil verify "$DMG"
mkdir -p "$MOUNT"
hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$MOUNT" "$DMG" >/dev/null
codesign --verify --deep --strict "$MOUNT/$PRODUCT.app" || fail "the app's signature doesn't verify in the DMG"
[[ "$(readlink "$MOUNT/Applications")" == "/Applications" ]] || fail "the Applications link is missing"
if (( LAYOUT )); then
  [[ -f "$MOUNT/.DS_Store" && -f "$MOUNT/.background.tiff" ]] || fail "the window layout is missing"
fi
hdiutil detach "$MOUNT" >/dev/null
rmdir "$MOUNT"

if (( NOTARIZE )); then
  xcrun stapler validate "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi

SIZE="$(wc -c < "$DMG" | tr -d '[:space:]')"
SHA256="$(shasum -a 256 "$DMG" | awk '{ print $1 }')"
log "Layout: $( (( LAYOUT )) && echo "drag to Applications, $(basename "$BACKGROUND")" || echo "Finder default")"
log "Signature: $( [[ "$SIGN_IDENTITY" == "-" ]] && echo "ad hoc app, unsigned DMG" || echo "Developer ID" )$( (( NOTARIZE )) && echo ", notarized" || true)"
log "Size: $SIZE bytes"
log "SHA-256: $SHA256"
log "Done: $DMG"
