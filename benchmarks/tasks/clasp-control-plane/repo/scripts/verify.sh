#!/usr/bin/env bash
set -euo pipefail

workspace_root="$(cd "$(dirname "$0")/.." && pwd)"
project_root="${CLASP_PROJECT_ROOT:?CLASP_PROJECT_ROOT is required}"
mkdir -p "$workspace_root/build"

bash "$project_root/benchmarks/run-in-nix-or-current.sh" "$project_root" bash -lc "
  set -euo pipefail
  cd \"$project_root\" &&
  claspc compile \"$workspace_root/Main.clasp\" -o \"$workspace_root/build/Main.js\" --compiler=bootstrap >/dev/null &&
  node \"$workspace_root/test/control-plane.test.mjs\"
"
