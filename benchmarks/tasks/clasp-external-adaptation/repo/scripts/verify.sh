#!/usr/bin/env bash
set -euo pipefail

workspace_root="$(cd "$(dirname "$0")/.." && pwd)"
project_root="${CLASP_PROJECT_ROOT:?CLASP_PROJECT_ROOT is required}"
mkdir -p "$workspace_root/build"
binary_path="$workspace_root/build/external-adaptation"

bash "$project_root/benchmarks/run-in-nix-or-current.sh" "$project_root" bash -lc "
  set -euo pipefail
  cd \"$project_root\" &&
  env RUSTC=/definitely-missing-rustc claspc compile \"$workspace_root/Main.clasp\" -o \"$binary_path\" >/dev/null &&
  export CLASP_BENCH_BINARY=\"$binary_path\" &&
  node \"$workspace_root/test/objective.test.mjs\"
"
