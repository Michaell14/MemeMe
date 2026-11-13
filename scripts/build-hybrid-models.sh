#!/usr/bin/env bash
# Builds the hybrid matcher's Core ML models (CLIPImage.mlpackage, HSEmotion.mlpackage) into OUT_DIR from the
# pinned weights: the OpenCLIP ViT-B-32-quickgelu LAION-400M checkpoint and HSEmotion's enet_b0_8_best_vgaf.onnx,
# downloaded once and checked against the SHA-256 hashes in scripts/hybrid/hybrid_common.py. Nothing large is
# committed; scripts/build-app.sh calls this and compiles the result into the bundle.
#
# Usage:  scripts/build-hybrid-models.sh [OUT_DIR]          (default build/HybridModels)
#
# Environment (optional):
#   PYTHON                 a Python 3.10–3.12 (default: python3.12, python3.11, python3.10, then python3)
#   HYBRID_WEIGHTS_DIR     where the downloaded weights are kept (default build/.hybrid-weights)
#   HYBRID_VENV            the tools' virtual environment (default build/.hybrid-venv)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/build/HybridModels}"
WEIGHTS="${HYBRID_WEIGHTS_DIR:-$ROOT/build/.hybrid-weights}"
VENV="${HYBRID_VENV:-$ROOT/build/.hybrid-venv}"
REQUIREMENTS="$ROOT/scripts/hybrid/requirements.txt"

log() { printf '==> %s\n' "$*"; }

python_ok() {
  "$1" -c 'import sys; sys.exit(0 if (3, 10) <= sys.version_info[:2] <= (3, 12) else 1)' 2>/dev/null
}

PY="${PYTHON:-}"
if [[ -z "$PY" ]]; then
  for candidate in python3.12 python3.11 python3.10 python3; do
    if command -v "$candidate" >/dev/null && python_ok "$candidate"; then PY="$candidate"; break; fi
  done
fi
if [[ -z "$PY" ]] || ! python_ok "$PY"; then
  echo "error: the hybrid models need Python 3.10–3.12 (set PYTHON)" >&2
  exit 1
fi

# The tools' environment, made again when the pinned requirements change.
STAMP="$VENV/.requirements"
if [[ ! -x "$VENV/bin/python" ]] || ! cmp -s "$REQUIREMENTS" "$STAMP"; then
  log "Installing the model tools into $VENV"
  rm -rf "$VENV"
  "$PY" -m venv "$VENV"
  "$VENV/bin/python" -m pip install --quiet --upgrade pip
  "$VENV/bin/python" -m pip install --quiet -r "$REQUIREMENTS"
  cp "$REQUIREMENTS" "$STAMP"
fi

log "Converting the hybrid models into $OUT"
"$VENV/bin/python" -I "$ROOT/scripts/hybrid/convert_models.py" --weights "$WEIGHTS" --out "$OUT" \
  --check-prompts "$ROOT/Resources/Hybrid/emotion_prompts.json"
# The app reads the committed prompts (checked equal above).
cp "$ROOT/Resources/Hybrid/emotion_prompts.json" "$OUT/emotion_prompts.json"
log "Hybrid models: $(du -sh "$OUT" | cut -f1) in $OUT"
