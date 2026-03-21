#!/usr/bin/env bash
set -euo pipefail

project_root="${CLASP_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
claspc_bin="${CLASPC_BIN:-}"

if [[ -z "$claspc_bin" ]]; then
  if command -v claspc >/dev/null 2>&1; then
    claspc_bin="$(command -v claspc)"
  elif [[ -x "$project_root/runtime/target/debug/claspc" ]]; then
    claspc_bin="$project_root/runtime/target/debug/claspc"
  elif [[ -x "$project_root/runtime/target/release/claspc" ]]; then
    claspc_bin="$project_root/runtime/target/release/claspc"
  else
    printf '%s\n' "missing native claspc binary; set CLASPC_BIN or build claspc first" >&2
    exit 1
  fi
fi

exec "$claspc_bin" exec-image "$@"
