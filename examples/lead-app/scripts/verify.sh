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
  node examples/lead-app/client-demo.mjs "$compiled_path"
  node examples/lead-app/workflow-demo.mjs "$compiled_path"
}

if [[ -n "${IN_NIX_SHELL:-}" ]]; then
  output="$(run_verify)"
  printf '%s\n' "$output" | grep -F '{"routeCount":11,"routeNames":["landingRoute","inboxRoute","primaryLeadRoute","secondaryLeadRoute","createLeadRoute","reviewLeadRoute","inboxSnapshotRoute","primaryLeadRecordRoute","secondaryLeadRecordRoute","createLeadRecordRoute","reviewLeadRecordRoute"],"landingHasForm":true,"createdHasLead":true,"inboxHasCreatedLead":true,"primaryHasCreatedLead":true,"secondaryHasSeedLead":true,"reviewHasNote":true,"invalid":"budget must be an integer"}'
  printf '%s\n' "$output" | grep -F '{"routeClientCount":11,"routeClientNames":["landingRoute","inboxRoute","primaryLeadRoute","secondaryLeadRoute","createLeadRoute","reviewLeadRoute","inboxSnapshotRoute","primaryLeadRecordRoute","secondaryLeadRecordRoute","createLeadRecordRoute","reviewLeadRecordRoute"],"inboxHeadline":"Priority inbox","createdLeadId":"lead-3","createdPriority":"Medium","createdSegment":"Growth","primaryCompany":"SynthSpeak API","reviewedStatus":"Reviewed","reviewedNote":"Schedule technical discovery","invalid":"value.segment expected a LeadSegment value"}'
  printf '%s\n' "$output" | grep -F '{"workflowCount":1,"workflowName":"LeadFollowUpFlow","checkpointLeadId":"lead-3","createdLeadId":"lead-3","createdPriority":"High","preparedStatus":"delivered","preparedResult":"schedule-discovery","reviewedStatus":"Reviewed","finalNextAction":"await-reply","finalTouchCount":2,"finalReviewNote":"Schedule executive discovery","remainingMailboxSize":0}'
else
  nix develop "$project_root" --command bash -lc "
    set -euo pipefail
    export CLASP_PROJECT_ROOT=\"$project_root\"
    bash examples/lead-app/scripts/verify.sh
  "
fi
