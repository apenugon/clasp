#!/usr/bin/env bash
set -euo pipefail

workspace_root="$(cd "$(dirname "$0")/.." && pwd)"

nix develop "$CLASP_PROJECT_ROOT" --command bash -lc "
  set -euo pipefail
  cd \"$workspace_root\"
  npm test
"
