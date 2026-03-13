#!/usr/bin/env bash
set -euo pipefail

project_root="${CLASP_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
example_root="$project_root/examples/support-agent"
compiled_path="$example_root/compiled.mjs"

cleanup() {
  rm -f "$compiled_path"
}

trap cleanup EXIT

run_verify() {
  cd "$project_root"
  cabal run claspc -- check examples/support-agent/Main.clasp
  cabal run claspc -- compile examples/support-agent/Main.clasp -o examples/support-agent/compiled.mjs
  node examples/support-agent/demo.mjs "$compiled_path"
}

if [[ -n "${IN_NIX_SHELL:-}" ]]; then
  run_verify | tail -n 1 | grep -F '{"agent":"renewalAgent","approval":"on_request","sandbox":"workspace_write","guideScope":"Resolve renewal blockers with typed repo tools and validated structured outputs.","plan":"Look up customer context, fetch the renewal policy note, then emit either a reply draft or an escalation draft.","bamlShimKind":"clasp-baml-shim","bamlToolNames":["lookupCustomer","lookupPolicy"],"dynamicSchemaNames":["ReplyDraft","EscalationDraft"],"scenarios":[{"ticket":"cust-42","toolMethods":["lookup_customer","lookup_policy"],"company":"Northwind Studio","plan":"standard","promptRoles":["system","assistant","assistant","user"],"promptText":"system: You are the renewal desk agent.\n\nassistant: Northwind Studio\n\nassistant: Confirm the blocker, set the next update window, and escalate urgent enterprise renewals.\n\nuser: Renewal is blocked on legal review.","decisionType":"ReplyDraft","decisionAction":"reply"},{"ticket":"cust-99","toolMethods":["lookup_customer","lookup_policy"],"company":"Blue Yonder Enterprise","plan":"enterprise","promptRoles":["system","assistant","assistant","user"],"promptText":"system: You are the renewal desk agent.\n\nassistant: Blue Yonder Enterprise\n\nassistant: Confirm the blocker, set the next update window, and escalate urgent enterprise renewals.\n\nuser: Enterprise renewal is blocked and the deadline is today.","decisionType":"EscalationDraft","decisionAction":"escalate"}],"invalidDecision":"decision did not match any dynamic schema candidate: ReplyDraft, EscalationDraft","traceActions":["prepare_call","parse_result","prepare_call","parse_result","prepare_call","parse_result","prepare_call","parse_result"]}'
else
  nix develop "$project_root" --command bash -lc "
    set -euo pipefail
    export CLASP_PROJECT_ROOT=\"$project_root\"
    bash examples/support-agent/scripts/verify.sh
  "
fi
