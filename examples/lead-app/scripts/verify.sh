#!/usr/bin/env bash
set -euo pipefail

project_root="${CLASP_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
example_root="$project_root/examples/lead-app"
compiled_path="$example_root/compiled.mjs"

cleanup() {
  rm -f "$compiled_path"
}

trap cleanup EXIT

run_verify() {
  cd "$project_root"
  cabal run claspc -- check examples/lead-app/Main.clasp
  cabal run claspc -- compile examples/lead-app/Main.clasp -o "$compiled_path"
  node examples/lead-app/demo.mjs "$compiled_path"
}

if [[ -n "${IN_NIX_SHELL:-}" ]]; then
  run_verify | tail -n 1 | grep -F '{"routeCount":6,"routeNames":["landingRoute","inboxRoute","primaryLeadRoute","secondaryLeadRoute","createLeadRoute","reviewLeadRoute"],"landingHasForm":true,"createdHasLead":true,"inboxHasCreatedLead":true,"primaryHasCreatedLead":true,"secondaryHasSeedLead":true,"reviewHasNote":true,"invalid":"budget must be an integer"}'
else
  nix develop "$project_root" --command bash -lc "
    set -euo pipefail
    export CLASP_PROJECT_ROOT=\"$project_root\"
    bash examples/lead-app/scripts/verify.sh
  "
fi
