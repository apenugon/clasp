#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
state_root="$(mktemp -d "${TMPDIR:-/tmp}/clasp-legal-assistant-appbench.XXXXXX")"
trap 'rm -rf "$state_root"' EXIT
claspc_bin="$(cd "$project_root" && bash scripts/resolve-claspc.sh)"

json_quote() {
  node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$1"
}

run_with_env() {
  local command_json="$1"
  shift
  (
    cd "$project_root"
    CLASP_LEGAL_APPBENCH_STATE_ROOT_JSON="$(json_quote "$state_root")" \
    CLASP_LEGAL_APPBENCH_WORKSPACE_JSON="$(json_quote "$project_root")" \
    CLASP_LEGAL_APPBENCH_COMMAND_JSON="$command_json" \
    "$@"
  )
}

upload_payload() {
  local document_id="$1"
  local title="$2"
  local filename="$3"
  local body="$4"
  printf '{"authToken":"token-ada","conversationId":"conv-legal-1","title":"%s","upload":{"documentId":"%s","filename":"%s","mediaType":"text/plain","sizeBytes":0,"contentText":"%s"}}' \
    "$title" "$document_id" "$filename" "$body"
}

ask_payload='{"authToken":"token-ada","conversationId":"conv-legal-1","prompt":"Compare @document[doc-msa|Master Services Agreement] against current Delaware force majeure guidance."}'

cd "$project_root"
"$claspc_bin" --json check examples/legal-assistant-appbench/Main.clasp | grep -F '"status":"ok"' >/dev/null

bootstrap_output="$(run_with_env '"bootstrap"' "$claspc_bin" run examples/legal-assistant-appbench/Main.clasp)"
printf '%s\n' "$bootstrap_output" | grep -F '"command":"bootstrap"' >/dev/null

upload_one="$(CLASP_LEGAL_APPBENCH_UPLOAD_JSON="$(upload_payload "doc-msa" "Master Services Agreement" "msa.txt" "The Master Services Agreement includes a force majeure clause and a notice requirement.")" run_with_env '"upload"' "$claspc_bin" run examples/legal-assistant-appbench/Main.clasp)"
printf '%s\n' "$upload_one" | grep -F '"latestDocumentVersion":1' >/dev/null

upload_replace="$(CLASP_LEGAL_APPBENCH_UPLOAD_JSON="$(upload_payload "doc-msa" "Master Services Agreement" "msa-v2.txt" "The updated Master Services Agreement keeps the force majeure clause and adds a cure period.")" run_with_env '"upload"' "$claspc_bin" run examples/legal-assistant-appbench/Main.clasp)"
printf '%s\n' "$upload_replace" | grep -F '"latestDocumentVersion":2' >/dev/null
printf '%s\n' "$upload_replace" | grep -F '"latestDocumentStatus":"replaced"' >/dev/null

upload_two="$(CLASP_LEGAL_APPBENCH_UPLOAD_JSON="$(upload_payload "doc-delaware" "Delaware Case Notes" "delaware.txt" "Delaware case notes discuss force majeure notice and contractual remedies.")" run_with_env '"upload"' "$claspc_bin" run examples/legal-assistant-appbench/Main.clasp)"
printf '%s\n' "$upload_two" | grep -F '"documentCount":2' >/dev/null

ask_output="$(CLASP_LEGAL_APPBENCH_ASK_JSON="$ask_payload" run_with_env '"ask"' "$claspc_bin" run examples/legal-assistant-appbench/Main.clasp)"
printf '%s\n' "$ask_output" | grep -F '"latestRetrievedDocumentIds":["doc-msa","doc-delaware"]' >/dev/null
printf '%s\n' "$ask_output" | grep -F '"latestCitationLabels":["Master Services Agreement v2","Delaware Case Notes","Delaware Force Majeure Update"]' >/dev/null
printf '%s\n' "$ask_output" | grep -F '"latestToolKinds":["retrieval","web-search"]' >/dev/null

snapshot_output="$(run_with_env '"snapshot"' "$claspc_bin" run examples/legal-assistant-appbench/Main.clasp)"
printf '%s\n' "$snapshot_output" | grep -F '"chatTurnCount":5' >/dev/null

grep -F '"query": "Compare @document[doc-msa|Master Services Agreement] against current Delaware force majeure guidance."' "$state_root/search-log.json" >/dev/null

printf '%s\n' '{"status":"ok","implementation":"clasp-native","example":"legal-assistant-appbench"}'
