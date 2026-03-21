#!/usr/bin/env bash
set -euo pipefail

workspace_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project_root="${CLASP_PROJECT_ROOT:?CLASP_PROJECT_ROOT is required}"

mkdir -p "$workspace_root/build"

nix develop "$project_root" --command bash -lc "
  set -euo pipefail
  cd \"$project_root\"
  claspc compile \"$workspace_root/Main.clasp\" -o \"$workspace_root/build/Main.js\" --compiler=bootstrap
"

node "$workspace_root/test/compiler-maintenance.test.mjs" \
  "$workspace_root/build/Main.js" \
  "$workspace_root/build/stage2-compiler.mjs" \
  "$workspace_root/build/stage2-output.mjs"
