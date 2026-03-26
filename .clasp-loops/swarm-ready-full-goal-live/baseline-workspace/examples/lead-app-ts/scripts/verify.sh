#!/usr/bin/env bash
set -euo pipefail

workspace_root="$(cd "$(dirname "$0")/.." && pwd)"
project_root="${CLASP_PROJECT_ROOT:-$(cd "$workspace_root/../.." && pwd)}"

nix develop "$project_root" --command bash -lc "
  set -euo pipefail
  cd \"$workspace_root\"
  npm install
  npm test
"
