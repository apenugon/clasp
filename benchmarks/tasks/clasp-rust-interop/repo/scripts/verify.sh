#!/usr/bin/env bash
set -euo pipefail

project_root="${CLASP_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
workspace_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compiled_path="$workspace_root/compiled.mjs"

(
  cd "$project_root"
  cabal run claspc -- check "$workspace_root/Main.clasp"
  cabal run claspc -- compile "$workspace_root/Main.clasp" -o "$compiled_path"
)

output="$(node "$workspace_root/demo.mjs" "$compiled_path")"
expected='{"abi":"clasp-native-v1","supportedTargets":["bun","worker","react-native","expo"],"bindingName":"mockLeadSummaryModel","capabilityId":"capability:foreign:mockLeadSummaryModel","crateName":"lead_summary_bridge","loader":"bun:ffi","crateType":"cdylib","manifestPath":"native/lead-summary/Cargo.toml","artifactFileName":"liblead_summary_bridge.so","cargoCommand":["cargo","build","--manifest-path","native/lead-summary/Cargo.toml","--release","--target","x86_64-unknown-linux-gnu"],"capabilities":["capability:foreign:mockLeadSummaryModel","capability:ml:lead-summary"]}'

if [[ "$output" != "$expected" ]]; then
  echo "unexpected rust interop output: $output" >&2
  exit 1
fi
