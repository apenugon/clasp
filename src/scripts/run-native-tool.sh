#!/usr/bin/env bash
set -euo pipefail

project_root="${CLASP_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
claspc_bin="${CLASPC_BIN:-}"

if [[ -z "$claspc_bin" ]]; then
  claspc_bin="$("$project_root/scripts/resolve-claspc.sh")"
fi

exec "$claspc_bin" exec-image "$@"
