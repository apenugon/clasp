#!/usr/bin/env bash
set -euo pipefail

project_root="${CLASP_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
example_root="$project_root/examples/support-console"
compiled_path="$example_root/compiled.mjs"

cleanup() {
  rm -f "$compiled_path"
}

trap cleanup EXIT

run_verify() {
  cd "$project_root"
  cabal run claspc -- check examples/support-console/Main.clasp --compiler=bootstrap
  cabal run claspc -- compile examples/support-console/Main.clasp -o "$compiled_path" --compiler=bootstrap
  node examples/support-console/demo.mjs "$compiled_path"
}

if [[ -n "${IN_NIX_SHELL:-}" ]]; then
  run_verify | tail -n 1 | grep -F '{"routeCount":4,"routeNames":["supportDashboardRoute","supportCustomerRoute","supportCustomerPageRoute","previewReplyRoute"],"hostBindingNames":["generateReplyPreview","publishCustomer"],"dashboardHasPreviewForm":true,"dashboardHasCustomerLink":true,"customerCompany":"Northwind Studio","customerEmail":"ops@northwind.example","customerPageHasExport":true,"previewReply":"Thanks for the update. Renewal is blocked on legal review. We will send the next renewal step today.","previewEscalationNeeded":true,"previewPageHasReply":true,"invalid":"summary must be a string"}'
else
  nix develop "$project_root" --command bash -lc "
    set -euo pipefail
    export CLASP_PROJECT_ROOT=\"$project_root\"
    bash examples/support-console/scripts/verify.sh
  "
fi
