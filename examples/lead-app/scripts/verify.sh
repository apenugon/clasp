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
  claspc check examples/lead-app/Main.clasp --compiler=bootstrap
  claspc compile examples/lead-app/Main.clasp -o "$compiled_path" --compiler=bootstrap
  bun examples/lead-app/e2e.mjs "$compiled_path"
  node examples/lead-app/demo.mjs "$compiled_path"
  node examples/lead-app/client-demo.mjs "$compiled_path"
  node examples/lead-app/workflow-demo.mjs "$compiled_path"
  node examples/lead-app/ai-demo.mjs "$compiled_path"
}

if [[ -n "${IN_NIX_SHELL:-}" ]]; then
  output="$(run_verify)"
  printf '%s\n' "$output" | grep -F '{"landingStatus":200,"inboxHasSeedLead":true,"secondaryHasSeedLead":true,"createdStatus":200,"primaryShowsCreatedLead":true,"reviewedStatus":200,"reviewedHasNote":true,"invalidBudgetStatus":400,"invalidBudgetMessage":"budget must be an integer","unknownLeadStatus":502,"unknownLeadMessage":"Unknown lead: lead-404","missingStatus":404,"missingMessage":{"error":"not_found","path":"/missing"}}'
  printf '%s\n' "$output" | grep -F '{"routeCount":11,"routeNames":["landingRoute","inboxRoute","primaryLeadRoute","secondaryLeadRoute","createLeadRoute","reviewLeadRoute","inboxSnapshotRoute","primaryLeadRecordRoute","secondaryLeadRecordRoute","createLeadRecordRoute","reviewLeadRecordRoute"],"landingHasForm":true,"createdHasLead":true,"inboxHasCreatedLead":true,"primaryHasCreatedLead":true,"secondaryHasSeedLead":true,"reviewHasNote":true,"invalid":"budget must be an integer"}'
  printf '%s\n' "$output" | grep -F '{"routeClientCount":11,"routeClientNames":["landingRoute","inboxRoute","primaryLeadRoute","secondaryLeadRoute","createLeadRoute","reviewLeadRoute","inboxSnapshotRoute","primaryLeadRecordRoute","secondaryLeadRecordRoute","createLeadRecordRoute","reviewLeadRecordRoute"],"inboxHeadline":"Priority inbox","createdLeadId":"lead-3","createdPriority":"Medium","createdSegment":"Growth","primaryCompany":"SynthSpeak API","reviewedStatus":"Reviewed","reviewedNote":"Schedule technical discovery","invalid":"value.segment expected a LeadSegment value"}'
  printf '%s\n' "$output" | grep -F '{"workflowCount":1,"workflowName":"LeadFollowUpFlow","checkpointLeadId":"lead-3","createdLeadId":"lead-3","createdPriority":"High","preparedStatus":"delivered","preparedResult":"schedule-discovery","reviewedStatus":"Reviewed","finalNextAction":"await-reply","finalTouchCount":2,"finalReviewNote":"Schedule executive discovery","remainingMailboxSize":0}'
  printf '%s\n' "$output" | grep -F '{"routeName":"primaryLeadRecordRoute","toolName":"lookupLeadPlaybook","toolMethod":"lookup_lead_playbook","leadId":"lead-2","leadPriority":"Medium","leadSegment":"Growth","playbookChannel":"email","promptRoles":["system","assistant","assistant","assistant","assistant","assistant","user"],"promptText":"system: You are the lead outreach assistant.\n\nassistant: Northwind Studio\n\nassistant: Northwind Studio is ready for a design-system migration this quarter.\n\nassistant: medium\n\nassistant: growth\n\nassistant: Keep the note concise, mention the current pilot, and ask for a next step.\n\nuser: Ask for the best time to send a tailored rollout plan.","draftChannel":"email","draftSubject":"Northwind Studio email follow-up","draftCallToAction":"Ask for the best time to send a tailored rollout plan.","signalKind":"runtime_signal","signalName":"lead_outreach_draft_ready","feedbackSignalName":"growth_reply_rate_below_goal","signalRefKinds":["route","prompt","workflow","policy","test"],"signalRefIds":["route:primaryLeadRecordRoute","decl:outreachPrompt","workflow:LeadFollowUpFlow","policy:LeadAssistOps","test:lead-app.ai-demo"],"signalPromptId":"decl:outreachPrompt","signalTestFile":"examples/lead-app/ai-demo.mjs","changePlanKind":"bounded_change_plan","changePlanName":"growth-outreach-tune","changePlanTargetIds":["decl:outreachPrompt","test:lead-app.ai-demo"],"changePlanStepCount":2,"changePlanAirRootKind":"planProjection","learningLoopKind":"learning_loop","learningLoopName":"growth-outreach-loop","learningLoopObjective":"reply-rate","learningLoopEvalIds":["eval:lead-app.ai-demo"],"learningLoopBenchmarkIds":["benchmark:clasp-external-adaptation"],"learningLoopBudgetStepCap":2,"learningLoopAirRootKind":"learningLoopProjection","collectedSignalCount":4,"invalidChange":"Change target route:secondaryLeadRecordRoute is outside the observed signal scope","invalidLearningLoop":"Learning loop budget allows at most 1 remediation steps","invalidTool":"guidance must be a string","invalidModel":"subject must be a string"}'
else
  nix develop "$project_root" --command bash -lc "
    set -euo pipefail
    export CLASP_PROJECT_ROOT=\"$project_root\"
    bash examples/lead-app/scripts/verify.sh
  "
fi
