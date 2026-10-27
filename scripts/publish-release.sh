#!/usr/bin/env bash
# Publishes GitHub Release v<version>-<build> with MemeMe.dmg and latest.json, the update feed the
# app reads from https://github.com/<owner>/<repo>/releases/latest/download/latest.json, and marks
# it as the latest release unless a newer build already is. A release that already has both assets
# is left unchanged. CI runs it on Linux after the macOS build; it also runs on macOS.
#
# Usage:  ./scripts/publish-release.sh <dmg> <version> <build> <min-macos>
#         e.g. ./scripts/publish-release.sh build/MemeMe.dmg 1.0 57 14.0
#
# Environment:
#   GITHUB_REPOSITORY  owner/repo (required unless DRY_RUN=1, which defaults to Michaell14/MemeMe)
#   GITHUB_SHA         the commit to release (default: git rev-parse HEAD)
#   GH_TOKEN           token for gh with contents: write
#   NOTARIZED=true     the DMG is notarized, so the install notes skip the Gatekeeper step
#   DRY_RUN=1          only write latest.json and release-notes.md and print what would be published
#
# latest.json and release-notes.md are written next to the DMG. Needs git, jq and (unless
# DRY_RUN=1) gh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSET_NAME="MemeMe.dmg"
MAX_NOTES=12

log() {
  printf '==> %s\n' "$*"
}

fail() {
  echo "error: $*" >&2
  exit 1
}

if [[ $# -ne 4 ]]; then
  echo "usage: $0 <dmg> <version> <build> <min-macos>" >&2
  exit 2
fi
DMG="$1"
VERSION="$2"
BUILD="$3"
MIN_MACOS="$4"
DRY_RUN="${DRY_RUN:-0}"

# 1. Check the inputs.
[[ -f "$DMG" ]] || fail "DMG not found at $DMG"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || fail "version must look like 1, 1.0 or 1.0.2 (got \"$VERSION\")"
[[ "$BUILD" =~ ^[0-9]+$ ]] || fail "build must be a whole number (got \"$BUILD\")"
BUILD=$((10#$BUILD))
(( BUILD >= 1 )) || fail "build must be at least 1"
[[ "$MIN_MACOS" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || fail "min-macos must look like 14.0 (got \"$MIN_MACOS\")"
command -v jq >/dev/null 2>&1 || fail "jq is required"

if [[ "$DRY_RUN" == "1" ]]; then
  REPO="${GITHUB_REPOSITORY:-Michaell14/MemeMe}"
else
  REPO="${GITHUB_REPOSITORY:-}"
  [[ -n "$REPO" ]] || fail "GITHUB_REPOSITORY (owner/repo) is required"
  command -v gh >/dev/null 2>&1 || fail "gh is required"
fi
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "GITHUB_REPOSITORY must be owner/repo (got \"$REPO\")"

COMMIT="${GITHUB_SHA:-$(git -C "$ROOT" rev-parse HEAD)}"
COMMIT="$(git -C "$ROOT" rev-parse --verify --quiet "${COMMIT}^{commit}")" \
  || fail "commit ${GITHUB_SHA:-HEAD} not found in $ROOT"

TAG="v${VERSION}-${BUILD}"
TITLE="MemeMe ${VERSION} (${BUILD})"
DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${TAG}/${ASSET_NAME}"
RELEASE_URL="https://github.com/${REPO}/releases/tag/${TAG}"

OUT_DIR="$(cd "$(dirname "$DMG")" && pwd)"
FEED="$OUT_DIR/latest.json"
NOTES_MD="$OUT_DIR/release-notes.md"

TMP_ROOT="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "${TMP_ROOT%/}/mememe-release.XXXXXX")"
cleanup() {
  rm -rf "$WORK"
}
trap cleanup EXIT

# 2. Measure the DMG.
if command -v sha256sum >/dev/null 2>&1; then
  SHA256="$(sha256sum "$DMG" | awk '{ print $1 }')"
else
  SHA256="$(shasum -a 256 "$DMG" | awk '{ print $1 }')"
fi
[[ "$SHA256" =~ ^[0-9a-f]{64}$ ]] || fail "could not compute the DMG's SHA-256"
SIZE="$(wc -c < "$DMG" | tr -d '[:space:]')"
(( SIZE > 0 )) || fail "$DMG is empty"

# 3. Release notes: subjects of the commits that changed the app since the previous release,
#    newest first.
PREV_TAG="$(git -C "$ROOT" describe --tags --abbrev=0 --match 'v*' "${COMMIT}^" 2>/dev/null || true)"
NOTES_FILE="$WORK/notes.txt"
if [[ -z "$PREV_TAG" ]]; then
  echo "First release." > "$NOTES_FILE"
else
  git -C "$ROOT" log --no-merges --format='%s' "${PREV_TAG}..${COMMIT}" \
      -- Sources Resources Package.swift VERSION \
    | awk -v max="$MAX_NOTES" 'NF && !/^Update site download/ && n < max { print; n++ }' \
    > "$NOTES_FILE"
  [[ -s "$NOTES_FILE" ]] || echo "Maintenance update." > "$NOTES_FILE"
fi

# 4. latest.json, the update feed (UpdateManifest in Sources/MemeMeCore/Update.swift).
jq -n \
  --arg version "$VERSION" \
  --argjson build "$BUILD" \
  --arg downloadURL "$DOWNLOAD_URL" \
  --arg sha256 "$SHA256" \
  --argjson size "$SIZE" \
  --arg minimumSystemVersion "$MIN_MACOS" \
  --rawfile notes "$NOTES_FILE" \
  --arg releasePageURL "$RELEASE_URL" \
  --arg publishedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
    version: $version,
    build: $build,
    downloadURL: $downloadURL,
    sha256: $sha256,
    size: $size,
    minimumSystemVersion: $minimumSystemVersion,
    notes: ($notes | split("\n") | map(select(length > 0))),
    releasePageURL: $releasePageURL,
    publishedAt: $publishedAt
  }' > "$FEED"
jq -e '
  (.version | length > 0) and (.build >= 1) and (.sha256 | test("^[0-9a-f]{64}$"))
  and (.size >= 1) and (.notes | length > 0)
' "$FEED" >/dev/null || fail "latest.json failed validation"

# 5. The release page text.
{
  echo "## What’s new"
  echo
  while IFS= read -r note; do
    printf -- '- %s\n' "$note"
  done < "$NOTES_FILE"
  echo
  echo "## Install"
  echo
  if [[ "${NOTARIZED:-}" == "true" ]]; then
    echo "Open MemeMe.dmg and drag MemeMe into your Applications folder. If you already have MemeMe, it offers this update itself."
  else
    echo "Open MemeMe.dmg and drag MemeMe into your Applications folder. The first time you open it, macOS blocks it because it is not notarized: go to System Settings → Privacy & Security and click Open Anyway. If you already have MemeMe, it offers this update itself."
  fi
  echo
  printf "SHA-256: \`%s\`\n" "$SHA256"
} > "$NOTES_MD"

log "Release $TAG: $TITLE"
log "Commit: $COMMIT (previous release: ${PREV_TAG:-none})"
log "DMG: $DMG ($SIZE bytes, SHA-256 $SHA256)"
log "Feed: $FEED"
log "Notes: $NOTES_MD"

# 6. Publish. The asset must be called MemeMe.dmg: the website and the feed link to that name.
if [[ "$(basename "$DMG")" == "$ASSET_NAME" ]]; then
  ASSET="$DMG"
else
  ASSET="$WORK/$ASSET_NAME"
  cp "$DMG" "$ASSET"
fi

if [[ "$DRY_RUN" == "1" ]]; then
  log "Dry run: nothing is published. latest.json:"
  cat "$FEED"
  log "release-notes.md:"
  cat "$NOTES_MD"
  log "Would create $RELEASE_URL (repo $REPO, target $COMMIT, marked latest unless a newer build is)"
  log "  with $ASSET_NAME (from $ASSET) and latest.json, or leave it unchanged if it has both already"
  exit 0
fi

# Only the newest build is marked latest, so re-running an older CI run never moves the website's
# download and the feed back to an older build. GitHub marks a new release latest unless told not to.
LATEST_TAG="$(gh release view -R "$REPO" --json tagName -q .tagName 2>/dev/null || true)"
LATEST_BUILD=0
if [[ "$LATEST_TAG" =~ -([0-9]+)$ ]]; then
  LATEST_BUILD=$((10#${BASH_REMATCH[1]}))
fi
if (( BUILD >= LATEST_BUILD )); then
  LATEST_FLAG="--latest"
else
  LATEST_FLAG="--latest=false"
  log "The latest release is $LATEST_TAG (build $LATEST_BUILD): $TAG is not marked latest"
fi

# A published release keeps its DMG. The DMG is not reproducible, so swapping it for a rebuild
# with the same build number would break the SHA-256 that running apps already hold; a new build
# needs a new commit. The DMG and latest.json always come from the same build.
if EXISTING_ASSETS="$(gh release view "$TAG" -R "$REPO" --json assets --jq '.assets[].name' 2>/dev/null)"; then
  if grep -qxF "$ASSET_NAME" <<< "$EXISTING_ASSETS" && grep -qxF "latest.json" <<< "$EXISTING_ASSETS"; then
    log "Release $TAG already has $ASSET_NAME and latest.json; leaving it unchanged"
    if [[ "$LATEST_FLAG" == "--latest" && "$LATEST_TAG" != "$TAG" ]]; then
      gh release edit "$TAG" --latest -R "$REPO"
    fi
  else
    log "Release $TAG is missing an asset; uploading $ASSET_NAME and latest.json from this build"
    gh release upload "$TAG" "$ASSET" "$FEED" --clobber -R "$REPO"
    gh release edit "$TAG" --notes-file "$NOTES_MD" "$LATEST_FLAG" -R "$REPO"
  fi
else
  log "Creating release $TAG"
  gh release create "$TAG" "$ASSET" "$FEED" -R "$REPO" \
    --title "$TITLE" --notes-file "$NOTES_MD" --target "$COMMIT" "$LATEST_FLAG"
fi

log "Published: $RELEASE_URL"
log "Download:  https://github.com/${REPO}/releases/latest/download/${ASSET_NAME}"
