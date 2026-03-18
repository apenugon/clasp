#!/usr/bin/env bash
set -euo pipefail

project_root="${CLASP_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
compiler_root="$project_root/compiler/hosted"
stage1_path="$compiler_root/stage1.mjs"
stage2_compiler_path="$compiler_root/stage2-compiler.mjs"
stage2_output_path="$compiler_root/stage2-output.mjs"

cleanup() {
  rm -f "$stage1_path" "$stage2_compiler_path" "$stage2_output_path"
}

trap cleanup EXIT

run_verify() {
  cd "$project_root"
  cabal run claspc -- check compiler/hosted/Main.clasp
  cabal run claspc -- compile compiler/hosted/Main.clasp -o "$stage1_path"
  node compiler/hosted/demo.mjs "$stage1_path" "$stage2_compiler_path" "$stage2_output_path"
}

if [[ -n "${IN_NIX_SHELL:-}" ]]; then
  run_verify | tail -n 1 | grep -F '"stage2MatchesStage1Snapshot":true,"stage2CompilerMatchesStage1Snapshot":true,"stage2CheckMatchesStage1":true,"stage2ExplainMatchesStage1":true,"stage2OutputMatchesStage1":true'
else
  nix develop "$project_root" --command bash -lc "
    set -euo pipefail
    export CLASP_PROJECT_ROOT=\"$project_root\"
    bash compiler/hosted/scripts/verify.sh
  "
fi
