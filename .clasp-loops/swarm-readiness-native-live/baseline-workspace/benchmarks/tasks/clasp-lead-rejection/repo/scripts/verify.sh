#!/usr/bin/env bash
set -euo pipefail

project_root="${CLASP_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../../" && pwd)}"
workspace_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$workspace_root/build"
binary_path="$workspace_root/build/lead-rejection"

nix develop "$project_root" --command bash -lc "
  set -euo pipefail
  cd \"$project_root\" &&
  env RUSTC=/definitely-missing-rustc claspc compile \"$workspace_root/app/Main.clasp\" -o \"$binary_path\" >/dev/null &&
  export CLASP_PROJECT_ROOT=\"$project_root\" &&
  export CLASP_BENCH_BINARY=\"$binary_path\" &&
  node \"$workspace_root/test/rejection.test.mjs\"
"
