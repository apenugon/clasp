#!/usr/bin/env bash
set -euo pipefail

workspace_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$workspace_root/build"

nix develop "$WEFT_PROJECT_ROOT" --command bash -lc "
  cd \"$WEFT_PROJECT_ROOT\" &&
  cabal run weftc -- compile \"$workspace_root/app/Main.weft\" -o \"$workspace_root/build/Main.js\" >/dev/null &&
  bun \"$workspace_root/test/priority.test.mjs\"
"
