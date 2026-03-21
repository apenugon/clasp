#!/usr/bin/env bash
set -euo pipefail

project_root="${CLASP_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
example_root="$project_root/examples/prompt-functions"
compiled_path="$example_root/compiled.mjs"

cleanup() {
  rm -f "$compiled_path"
}

trap cleanup EXIT

run_verify() {
  cd "$project_root"
  claspc check examples/prompt-functions/Main.clasp --compiler=bootstrap
  claspc compile examples/prompt-functions/Main.clasp -o examples/prompt-functions/compiled.mjs --compiler=bootstrap
  node examples/prompt-functions/demo.mjs "$compiled_path"
}

if [[ -n "${IN_NIX_SHELL:-}" ]]; then
  run_verify | tail -n 1 | grep -F '{"messageCount":3,"roles":["system","assistant","user"],"content":["You are a support agent.","Draft a concise reply.","Renewal is blocked on legal review."],"text":"system: You are a support agent.\n\nassistant: Draft a concise reply.\n\nuser: Renewal is blocked on legal review.","promptHasSecretValue":false,"promptMessageKeys":["content,role","content,role","content,role"],"promptPolicySurface":"PromptSecrets","promptGuideScope":"Keep secret values out of prompt payloads, traces, and tool calls.","traceSecret":"OPENAI_API_KEY","tracePolicy":"PromptSecrets","traceBoundary":"PromptTools","traceActor":"prompt-worker","traceHasSecretValue":false,"resolvedSecretName":"OPENAI_API_KEY","promptInputKind":"clasp-prompt-input","promptInputSecretName":"OPENAI_API_KEY","toolInputKind":"clasp-tool-input","toolInputSecretName":"OPENAI_API_KEY","toolMethod":"summarize_draft","toolQuery":"system: You are a support agent.\n\nassistant: Draft a concise reply.\n\nuser: Renewal is blocked on legal review.","toolCallHasSecretValue":false,"toolKnowsDeclaredSecret":true,"evalTraceCount":1,"evalTraceAction":"prepare_call","evalTraceActor":"prompt-worker"}'
else
  nix develop "$project_root" --command bash -lc "
    set -euo pipefail
    export CLASP_PROJECT_ROOT=\"$project_root\"
    bash examples/prompt-functions/scripts/verify.sh
  "
fi
