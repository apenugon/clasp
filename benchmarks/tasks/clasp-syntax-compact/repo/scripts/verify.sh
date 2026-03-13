#!/usr/bin/env bash
set -euo pipefail

workspace_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$workspace_root/build"

nix develop "$CLASP_PROJECT_ROOT" --command bash -lc "
  set -euo pipefail
  cd \"$CLASP_PROJECT_ROOT\" &&
  cabal run claspc -- compile \"$workspace_root/Main.clasp\" -o \"$workspace_root/build/Main.js\" >/dev/null &&
  node \"$workspace_root/test/authoring.test.mjs\"
"
