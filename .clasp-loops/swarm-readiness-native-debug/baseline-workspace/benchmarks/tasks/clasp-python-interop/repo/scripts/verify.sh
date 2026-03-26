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

output="$(cd "$workspace_root" && node "$workspace_root/demo.mjs" "$compiled_path")"
expected='{"workerRunning":true,"workerAccepted":true,"workerLabel":"py:worker-7","workerStopped":false,"workerRestarted":true,"serviceSummary":"py:Acme:42","serviceAccepted":true,"serviceStopped":false,"invalid":"budget must be an integer"}'

if [[ "$output" != "$expected" ]]; then
  echo "unexpected python interop output: $output" >&2
  exit 1
fi
