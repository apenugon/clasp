#!/usr/bin/env bash
set -euo pipefail

project_root="${CLASP_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
example_root="$project_root/examples/interop-ts"
compiled_path="$example_root/compiled.mjs"

cleanup() {
  rm -f "$compiled_path"
}

trap cleanup EXIT

run_verify() {
  cd "$project_root"
  claspc check examples/interop-ts/Main.clasp --compiler=bootstrap
  claspc compile examples/interop-ts/Main.clasp -o examples/interop-ts/compiled.mjs --compiler=bootstrap
  node examples/interop-ts/demo.mjs "$compiled_path"
}

if [[ -n "${IN_NIX_SHELL:-}" ]]; then
  run_verify | tail -n 1 | grep -F '{"packageKinds":["npm","typescript"],"upper":"HELLO ADA","formatted":"Acme Labs:7"}'
else
  nix develop "$project_root" --command bash -lc "
    set -euo pipefail
    export CLASP_PROJECT_ROOT=\"$project_root\"
    bash examples/interop-ts/scripts/verify.sh
  "
fi
