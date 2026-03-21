#!/usr/bin/env bash
set -euo pipefail

project_root="${CLASP_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
example_root="$project_root/examples/release-gate"
compiled_path="$example_root/compiled.mjs"

cleanup() {
  rm -f "$compiled_path"
}

trap cleanup EXIT

run_verify() {
  cd "$project_root"
  claspc check examples/release-gate/Main.clasp --compiler=bootstrap
  claspc compile examples/release-gate/Main.clasp -o "$compiled_path" --compiler=bootstrap
  node examples/release-gate/demo.mjs "$compiled_path"
}

if [[ -n "${IN_NIX_SHELL:-}" ]]; then
  run_verify | tail -n 1 | grep -F '{"routeCount":5,"routeNames":["releaseGateRoute","releaseAuditRoute","releaseAckRoute","releaseReviewRoute","releaseAcceptRoute"],"hostBindingNames":["reviewRelease"],"dashboardHasReviewForm":true,"auditTenant":"operations","auditStatus":"Pending","decisionStatus":"Approved","decisionNote":"Approved after typed policy review.","decisionPageHasBackLink":true,"redirectStatus":303,"redirectLocation":"/release/ack","ackHasBackLink":true,"invalid":"releaseId must be a string"}'
else
  nix develop "$project_root" --command bash -lc "
    set -euo pipefail
    export CLASP_PROJECT_ROOT=\"$project_root\"
    bash examples/release-gate/scripts/verify.sh
  "
fi
