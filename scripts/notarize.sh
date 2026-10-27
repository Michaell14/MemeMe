#!/usr/bin/env bash
# Sends a Developer ID signed file to Apple's notary service, waits for the verdict and staples the
# ticket. CI notarizes MemeMe.app (as a zip, stapling the .app) before packing the DMG, then the
# signed MemeMe.dmg itself.
#
# Usage:  ./scripts/notarize.sh <file-to-submit> [<path-to-staple>...]
#         e.g. ./scripts/notarize.sh build/MemeMe-notarize.zip build/MemeMe.app
#              ./scripts/notarize.sh build/MemeMe.dmg build/MemeMe.dmg
#
# Environment (all required), an App Store Connect API team key:
#   NOTARY_KEY_PATH   path to the key file, AuthKey_<id>.p8
#   NOTARY_KEY_ID     the key's ID
#   NOTARY_ISSUER_ID  the issuer ID (App Store Connect › Users and Access › Integrations)
#
# The key is never printed. A submission that fails with a network error is retried once; one that
# Apple doesn't accept prints the notary log and fails.
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: notarization needs macOS (xcrun notarytool)" >&2
  exit 1
fi

TIMEOUT="45m"
SUBMIT_ATTEMPTS=2
STAPLE_ATTEMPTS=3

log() {
  printf '==> %s\n' "$*"
}

fail() {
  echo "error: $*" >&2
  exit 1
}

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <file-to-submit> [<path-to-staple>...]" >&2
  exit 2
fi
FILE="$1"
shift

# 1. Check the inputs before uploading anything.
MISSING=""
[[ -n "${NOTARY_KEY_PATH:-}" ]] || MISSING="$MISSING NOTARY_KEY_PATH"
[[ -n "${NOTARY_KEY_ID:-}" ]] || MISSING="$MISSING NOTARY_KEY_ID"
[[ -n "${NOTARY_ISSUER_ID:-}" ]] || MISSING="$MISSING NOTARY_ISSUER_ID"
[[ -z "$MISSING" ]] || fail "missing environment variables:$MISSING (an App Store Connect API key)"
[[ -s "$NOTARY_KEY_PATH" ]] || fail "NOTARY_KEY_PATH does not point at a key file"
# Pasted IDs sometimes carry a trailing newline.
KEY_ID="$(printf '%s' "$NOTARY_KEY_ID" | tr -d '[:space:]')"
ISSUER_ID="$(printf '%s' "$NOTARY_ISSUER_ID" | tr -d '[:space:]')"

[[ -f "$FILE" ]] || fail "$FILE not found"
if (( $# > 0 )); then
  for path in "$@"; do
    [[ -e "$path" ]] || fail "$path (to staple) not found"
  done
fi
command -v python3 >/dev/null 2>&1 || fail "python3 is required to read notarytool's output"

TMP_ROOT="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "${TMP_ROOT%/}/mememe-notarize.XXXXXX")"
cleanup() {
  rm -rf "$WORK"
}
trap cleanup EXIT
OUT="$WORK/submit.json"
ERR="$WORK/submit.log"

# A string field of the JSON object notarytool prints (the last one, if it printed several);
# empty when there is none.
json_field() {
  python3 -I - "$1" "$2" <<'PY' 2>/dev/null || true
import json, sys
path, key = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8", errors="replace") as f:
    text = f.read()
candidates = [text] + [l for l in reversed(text.splitlines()) if l.strip().startswith("{")]
for candidate in candidates:
    try:
        value = json.loads(candidate)
    except ValueError:
        continue
    if isinstance(value, dict) and isinstance(value.get(key), str):
        print(value[key])
        break
PY
}

# 2. Submit and wait for the verdict.
attempt=1
SUBMISSION_ID=""
STATUS=""
while :; do
  log "Submitting $(basename "$FILE") for notarization (waiting up to $TIMEOUT)"
  if xcrun notarytool submit "$FILE" --key "$NOTARY_KEY_PATH" --key-id "$KEY_ID" \
      --issuer "$ISSUER_ID" --wait --timeout "$TIMEOUT" --output-format json > "$OUT" 2> "$ERR"; then
    rc=0
  else
    rc=$?
  fi
  cat "$OUT" "$ERR"
  SUBMISSION_ID="$(json_field "$OUT" id)"
  STATUS="$(json_field "$OUT" status)"
  log "notarytool exit status $rc; submission ${SUBMISSION_ID:-none}; status ${STATUS:-none}"

  # Accepted, Invalid or Rejected: Apple has decided.
  if [[ -n "$STATUS" && "$STATUS" != "In Progress" ]]; then
    break
  fi
  if [[ "$STATUS" == "In Progress" ]]; then
    fail "Apple did not finish within $TIMEOUT; check later with xcrun notarytool info $SUBMISSION_ID"
  fi
  if (( attempt < SUBMIT_ATTEMPTS )) && grep -Eqi \
      'network|timed out|offline|could not connect|connection (was )?(lost|reset|refused)|NSURLErrorDomain|Code=-10[0-9][0-9]|HTTP status code: 5[0-9][0-9]|socket' \
      "$OUT" "$ERR"; then
    attempt=$((attempt + 1))
    log "The submission failed with a network error; retrying in 30 s (attempt $attempt of $SUBMIT_ATTEMPTS)"
    sleep 30
    continue
  fi
  STATUS="failed (notarytool exit status $rc)"
  break
done

if [[ "$STATUS" != "Accepted" ]]; then
  echo "error: notarization of $(basename "$FILE"): $STATUS (submission ${SUBMISSION_ID:-none})" >&2
  if [[ -n "$SUBMISSION_ID" ]]; then
    log "The notary log:"
    xcrun notarytool log "$SUBMISSION_ID" --key "$NOTARY_KEY_PATH" --key-id "$KEY_ID" \
      --issuer "$ISSUER_ID" || echo "warning: could not fetch the notary log" >&2
  fi
  exit 1
fi
log "Notarized: $(basename "$FILE") (submission $SUBMISSION_ID)"

# 3. Staple the ticket, so Gatekeeper can check it offline. The ticket can take a moment to be
#    served after the verdict, so stapling gets a few attempts.
if (( $# > 0 )); then
  for path in "$@"; do
    log "Stapling $path"
    attempt=1
    until xcrun stapler staple "$path"; do
      if (( attempt >= STAPLE_ATTEMPTS )); then
        fail "stapler failed $STAPLE_ATTEMPTS times for $path"
      fi
      attempt=$((attempt + 1))
      log "stapler failed; retrying in 20 s (attempt $attempt of $STAPLE_ATTEMPTS)"
      sleep 20
    done
    xcrun stapler validate "$path"
  done
fi

log "Done: $FILE"
