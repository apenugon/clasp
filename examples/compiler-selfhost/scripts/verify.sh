#!/usr/bin/env bash
set -euo pipefail

project_root="${CLASP_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
example_root="$project_root/examples/compiler-selfhost"
embedded_path="$example_root/embedded.mjs"
candidate_compiler_path="$example_root/candidate-compiler.mjs"
candidate_output_path="$example_root/candidate-output.mjs"
claspc_bin="${CLASP_CLASPC:-$project_root/runtime/target/debug/claspc}"

cleanup() {
  rm -f "$embedded_path" "$candidate_compiler_path" "$candidate_output_path"
}

trap cleanup EXIT

run_verify() {
  cd "$project_root"
  "$claspc_bin" check examples/compiler-selfhost/Main.clasp
  "$claspc_bin" compile examples/compiler-selfhost/Main.clasp -o "$embedded_path"
  node examples/compiler-selfhost/demo.mjs "$embedded_path" "$candidate_compiler_path" "$candidate_output_path"
}

if [[ -n "${IN_NIX_SHELL:-}" || -n "${CLASP_CLASPC:-}" ]]; then
  run_verify | tail -n 1 | grep -F '"candidateMatchesEmbeddedSnapshot":true,"candidateCompilerMatchesEmbeddedSnapshot":true,"candidateOutputMatchesEmbedded":true'
else
  nix develop "$project_root" --command bash -lc "
    set -euo pipefail
    export CLASP_PROJECT_ROOT=\"$project_root\"
    bash examples/compiler-selfhost/scripts/verify.sh
  "
fi
