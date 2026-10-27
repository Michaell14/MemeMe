#!/usr/bin/env bash
# Builds build/site/index.html, a standalone copy of the website that any static host can serve.
#
# site/index.html is written as a claude.ai artifact page, which gets its <!doctype>, <head> and
# <body> skeleton when it is published; this script adds the same skeleton. The page's download
# button links to MemeMe.dmg in the latest GitHub Release, so nothing else is copied.
#
# Usage:  ./scripts/build-site.sh
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

echo "==> $OUT/index.html"
