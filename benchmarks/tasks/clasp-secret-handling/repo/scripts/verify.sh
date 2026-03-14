#!/usr/bin/env bash
set -euo pipefail

project_root="${CLASP_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
workspace_root="${CLASP_BENCHMARK_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
compiled_path="$workspace_root/compiled.mjs"

cleanup() {
  rm -f "$compiled_path"
}

trap cleanup EXIT

run_verify() {
  cd "$project_root"
  cabal run claspc -- check "$workspace_root/Main.clasp" --compiler=bootstrap
  cabal run claspc -- compile "$workspace_root/Main.clasp" -o "$compiled_path" --compiler=bootstrap
  node "$workspace_root/test/secret-handling.test.mjs" "$compiled_path"
}

if [[ -n "${IN_NIX_SHELL:-}" ]]; then
  run_verify
else
  nix develop "$project_root" --command bash -lc "
    set -euo pipefail
    export CLASP_PROJECT_ROOT=\"$project_root\"
    export CLASP_BENCHMARK_WORKSPACE=\"$workspace_root\"
    bash \"$workspace_root/scripts/verify.sh\"
  "
fi
