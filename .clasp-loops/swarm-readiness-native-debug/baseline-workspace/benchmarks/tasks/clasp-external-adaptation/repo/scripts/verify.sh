#!/usr/bin/env bash
set -euo pipefail

workspace_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$workspace_root/build"

nix develop "$CLASP_PROJECT_ROOT" --command bash -lc "
  cd \"$CLASP_PROJECT_ROOT\" &&
  claspc compile \"$workspace_root/Main.clasp\" -o \"$workspace_root/build/Main.js\" --compiler=bootstrap >/dev/null &&
  node \"$workspace_root/test/objective.test.mjs\"
"
