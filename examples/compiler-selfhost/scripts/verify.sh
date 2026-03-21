#!/usr/bin/env bash
set -euo pipefail

project_root="${CLASP_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
example_root="$project_root/examples/compiler-selfhost"
stage1_path="$example_root/stage1.mjs"
stage2_compiler_path="$example_root/stage2-compiler.mjs"
stage2_output_path="$example_root/stage2-output.mjs"

cleanup() {
  rm -f "$stage1_path" "$stage2_compiler_path" "$stage2_output_path"
}

trap cleanup EXIT

run_verify() {
  cd "$project_root"
  claspc check examples/compiler-selfhost/Main.clasp --compiler=bootstrap
  claspc compile examples/compiler-selfhost/Main.clasp -o "$stage1_path" --compiler=bootstrap
  bun examples/compiler-selfhost/demo.mjs "$stage1_path" "$stage2_compiler_path" "$stage2_output_path"
}

if [[ -n "${IN_NIX_SHELL:-}" ]]; then
  run_verify | tail -n 1 | grep -F '"stage2MatchesStage1Snapshot":true,"stage2CompilerMatchesStage1Snapshot":true,"stage2OutputMatchesStage1":true'
else
  nix develop "$project_root" --command bash -lc "
    set -euo pipefail
    export CLASP_PROJECT_ROOT=\"$project_root\"
    bash examples/compiler-selfhost/scripts/verify.sh
  "
fi
