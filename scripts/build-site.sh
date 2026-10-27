#!/usr/bin/env bash
# Builds build/site/, a standalone copy of the website that any static host can serve.
#
# site/index.html is written as a claude.ai artifact page, which gets its <!doctype>, <head> and
# <body> skeleton when it is published; this script adds the same skeleton and copies the
# download next to it. It also writes download.json (the zip as base64 plus its SHA-256): artifacts
# can't serve a .zip, so the published page reads that file and offers the zip through the
# viewer's download prompt.
#
# Usage:  ./scripts/build-site.sh   (needs site/MemeMe.zip or build/MemeMe.zip)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/build/site"
mkdir -p "$OUT"

{
  printf '%s\n' '<!doctype html>' '<html lang="en">' '<head>' \
    '<meta charset="utf-8">' \
    '<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">' \
    '<style>:root{color-scheme:light;padding-top:env(safe-area-inset-top,0px);padding-bottom:env(safe-area-inset-bottom,0px)}body{margin:0;font:14px system-ui,sans-serif}img{max-width:100%}[hidden]{display:none!important}</style>' \
    '</head>' '<body>'
  cat "$ROOT/site/index.html"
  printf '%s\n' '</body>' '</html>'
} > "$OUT/index.html"

if [[ -f "$ROOT/site/MemeMe.zip" ]]; then
  cp "$ROOT/site/MemeMe.zip" "$OUT/MemeMe.zip"
elif [[ -f "$ROOT/build/MemeMe.zip" ]]; then
  cp "$ROOT/build/MemeMe.zip" "$OUT/MemeMe.zip"
else
  echo "warning: no MemeMe.zip found; the download link will 404" >&2
fi

if [[ -f "$OUT/MemeMe.zip" ]]; then
  python3 - "$OUT/MemeMe.zip" "$OUT/download.json" <<'PY'
import base64, hashlib, json, sys
data = open(sys.argv[1], "rb").read()
with open(sys.argv[2], "w") as out:
    json.dump({"filename": "MemeMe.zip", "size": len(data),
               "sha256": hashlib.sha256(data).hexdigest(),
               "base64": base64.b64encode(data).decode("ascii")}, out)
PY
  echo "==> $OUT/download.json"
fi

echo "==> $OUT/index.html"
