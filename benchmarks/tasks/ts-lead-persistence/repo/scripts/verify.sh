#!/usr/bin/env bash
set -euo pipefail

workspace_root="$(cd "$(dirname "$0")/.." && pwd)"
project_root="${CLASP_PROJECT_ROOT:?CLASP_PROJECT_ROOT is required}"

bash "$project_root/benchmarks/run-in-nix-or-current.sh" "$project_root" bash -lc "
  set -euo pipefail
  cd \"$workspace_root\"
  npm test
"
