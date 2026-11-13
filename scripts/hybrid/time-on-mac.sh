#!/usr/bin/env bash
# Times the hybrid matcher on this Mac in a release build: a live frame (face landmarks + crop + HSEmotion) and a
# held-face search (2 CLIP passes + zero-shot + scoring 209 and 5,000 memes), for CPU only, CPU + Neural Engine and
# All (the app's setting). Prints a table; nothing leaves the Mac except the downloads below.
#
# Usage:  scripts/hybrid/time-on-mac.sh            (from the repository; Apple silicon recommended)
#
# Builds the models first if build/HybridModels is missing (scripts/build-hybrid-models.sh: Python 3.10–3.12, the
# pinned weights downloaded once) and downloads 24 of the benchmark's face photos into build/speed-data.
# Environment (optional): HYBRID_MODELS_DIR, MEMEME_SPEED_ROUNDS (default 3).
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: run this on a Mac" >&2
  exit 1
fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
MODELS="${HYBRID_MODELS_DIR:-$ROOT/build/HybridModels}"
DATA="$ROOT/build/speed-data"

if [[ ! -d "$MODELS/CLIPImage.mlpackage" || ! -d "$MODELS/HSEmotion.mlpackage" ]]; then
  echo "==> Building the hybrid models into $MODELS"
  "$ROOT/scripts/build-hybrid-models.sh" "$MODELS"
fi
echo "==> Downloading 24 face photos into $DATA"
python3 -I "$ROOT/scripts/hybrid/fetch_benchmark_data.py" --out "$DATA" --sample 24 --queries-only

echo "==> Building and timing (release)"
log="$ROOT/build/hybrid-speed.log"
MEMEME_HYBRID_TEST_MODELS="$MODELS" MEMEME_SPEED_PHOTOS="$DATA/queries" \
  swift test -c release -Xswiftc -enable-testing --filter MemeMeAppTests.HybridSpeedTests >"$log" 2>&1 || {
    echo "error: the timing run failed; see $log" >&2
    tail -30 "$log" >&2
    exit 1
  }
echo
grep '^HYBRID-SPEED' "$log" | awk '!seen[$0]++' | sed 's/^HYBRID-SPEED //' || true
echo
echo "$(sysctl -n machdep.cpu.brand_string), macOS $(sw_vers -productVersion)"
