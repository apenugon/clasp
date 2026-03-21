#!/usr/bin/env bash
set -euo pipefail

project_root="${CLASP_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
workspace_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compiled_path="$workspace_root/compiled.mjs"

(
  cd "$project_root"
  claspc check "$workspace_root/Main.clasp" --compiler=bootstrap
  claspc compile "$workspace_root/Main.clasp" -o "$compiled_path" --compiler=bootstrap
)

output="$(node "$workspace_root/demo.mjs" "$compiled_path")"
expected='{"packageKinds":["npm","typescript"],"upper":"HELLO ADA","formatted":"Acme Labs:7"}'

if [[ "$output" != "$expected" ]]; then
  echo "unexpected interop output: $output" >&2
  exit 1
fi
