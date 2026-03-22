#!/usr/bin/env bash
set -euo pipefail

project_root="${CLASP_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
example_root="$project_root/examples/compiler-selfhost"
stage1_path="$example_root/stage1.mjs"
stage2_compiler_path="$example_root/stage2-compiler.mjs"
stage2_output_path="$example_root/stage2-output.mjs"
claspc_bin="${CLASP_CLASPC:-$project_root/runtime/target/debug/claspc}"

cleanup() {
  rm -f "$stage1_path" "$stage2_compiler_path" "$stage2_output_path"
}

trap cleanup EXIT

run_verify() {
  cd "$project_root"
  "$claspc_bin" check examples/compiler-selfhost/Main.clasp
  "$claspc_bin" compile examples/compiler-selfhost/Main.clasp -o "$stage1_path"
  node examples/compiler-selfhost/demo.mjs "$stage1_path" "$stage2_compiler_path" "$stage2_output_path"
}

if [[ -n "${IN_NIX_SHELL:-}" || -n "${CLASP_CLASPC:-}" ]]; then
  run_verify | tail -n 1 | grep -F '"stage2MatchesStage1Snapshot":true,"stage2CompilerMatchesStage1Snapshot":true,"stage2OutputMatchesStage1":true'
else
  nix develop "$project_root" --command bash -lc "
    set -euo pipefail
    export CLASP_PROJECT_ROOT=\"$project_root\"
    bash examples/compiler-selfhost/scripts/verify.sh
  "
fi
