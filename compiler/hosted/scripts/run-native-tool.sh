#!/usr/bin/env bash
set -euo pipefail

project_root="${CLASP_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
cache_root="${XDG_CACHE_HOME:-${TMPDIR:-/tmp}}/clasp-hosted-native"
manifest_path="$project_root/runtime/native/Cargo.toml"
runtime_source="$project_root/runtime/native/clasp_runtime.rs"
tool_source="$project_root/runtime/native/clasp_native_tool.rs"
tool_bin="$cache_root/clasp-native-tool"

mkdir -p "$cache_root"

needs_rebuild=0
if [[ ! -x "$tool_bin" ]]; then
  needs_rebuild=1
elif [[ "$manifest_path" -nt "$tool_bin" || "$runtime_source" -nt "$tool_bin" || "$tool_source" -nt "$tool_bin" ]]; then
  needs_rebuild=1
fi

if [[ "$needs_rebuild" -eq 1 ]]; then
  cargo build \
    --quiet \
    --manifest-path "$manifest_path" \
    --release \
    --bin clasp-native-tool
  cp "$project_root/runtime/native/target/release/clasp-native-tool" "$tool_bin"
fi

exec "$tool_bin" "$@"
