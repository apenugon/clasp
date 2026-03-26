#!/usr/bin/env bash
set -euo pipefail

project_root="${CLASP_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
explicit_bin="${CLASP_CLASPC:-${CLASPC_BIN:-}}"
local_debug_bin="$project_root/runtime/target/debug/claspc"

binary_is_stale() {
  local binary_path="$1"

  if [[ ! -x "$binary_path" ]]; then
    return 0
  fi

  if [[ "$project_root/src/stage1.native.image.json" -nt "$binary_path" ]]; then
    return 0
  fi

  if [[ "$project_root/src/stage1.compiler.native.image.json" -nt "$binary_path" ]]; then
    return 0
  fi

  if find "$project_root/runtime" -maxdepth 1 \( -name '*.rs' -o -name 'Cargo.toml' \) -newer "$binary_path" -print -quit | grep -q .; then
    return 0
  fi

  return 1
}

if [[ -n "$explicit_bin" ]]; then
  if [[ ! -x "$explicit_bin" ]]; then
    printf 'resolve-claspc: explicit binary is not executable: %s\n' "$explicit_bin" >&2
    exit 1
  fi
  printf '%s\n' "$explicit_bin"
  exit 0
fi

if binary_is_stale "$local_debug_bin"; then
  if command -v cargo >/dev/null 2>&1; then
    (
      cd "$project_root"
      cargo build --quiet --manifest-path runtime/Cargo.toml --bin claspc
    ) >&2
  fi
fi

if [[ -x "$local_debug_bin" ]]; then
  printf '%s\n' "$local_debug_bin"
  exit 0
fi

if command -v claspc >/dev/null 2>&1; then
  command -v claspc
  exit 0
fi

printf '%s\n' 'resolve-claspc: unable to find a native claspc binary' >&2
exit 1
