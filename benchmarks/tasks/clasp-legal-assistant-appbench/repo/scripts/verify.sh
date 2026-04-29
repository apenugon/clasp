#!/usr/bin/env bash
set -euo pipefail

workspace_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project_root="${CLASP_PROJECT_ROOT:?CLASP_PROJECT_ROOT is required}"
state_root="$(mktemp -d "${TMPDIR:-/tmp}/clasp-legal-assistant-benchmark.XXXXXX")"
trap 'rm -rf "$state_root"' EXIT

json_quote() {
  node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$1"
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

claspc_bin="$(cd "$project_root" && bash scripts/resolve-claspc.sh)"

run_with_env() {
  local command_json="$1"
  shift
  (
    cd "$project_root"
    CLASP_LEGAL_APPBENCH_STATE_ROOT_JSON="$(json_quote "$state_root")" \
    CLASP_LEGAL_APPBENCH_WORKSPACE_JSON="$(json_quote "$workspace_root")" \
    CLASP_LEGAL_APPBENCH_SEARCH_SCRIPT_JSON="$(json_quote "$workspace_root/web-search-fixture.mjs")" \
    CLASP_LEGAL_APPBENCH_COMMAND_JSON="$command_json" \
    "$@"
  )
}

cd "$project_root"
"$claspc_bin" --json check "$workspace_root/Main.clasp" | grep -F '"status":"ok"' >/dev/null

bootstrap_output="$(run_with_env '"bootstrap"' "$claspc_bin" run "$workspace_root/Main.clasp")"
grep -F '"command":"bootstrap"' <<<"$bootstrap_output" >/dev/null

upload_one="$(CLASP_LEGAL_APPBENCH_UPLOAD_JSON="$(upload_payload "doc-msa" "Master Services Agreement" "msa.txt" "The Master Services Agreement includes a force majeure clause and a notice requirement.")" run_with_env '"upload"' "$claspc_bin" run "$workspace_root/Main.clasp")"
grep -F '"latestDocumentVersion":1' <<<"$upload_one" >/dev/null

upload_replace="$(CLASP_LEGAL_APPBENCH_UPLOAD_JSON="$(upload_payload "doc-msa" "Master Services Agreement" "msa-v2.txt" "The updated Master Services Agreement keeps the force majeure clause and adds a cure period.")" run_with_env '"upload"' "$claspc_bin" run "$workspace_root/Main.clasp")"
grep -F '"latestDocumentVersion":2' <<<"$upload_replace" >/dev/null
grep -F '"latestDocumentStatus":"replaced"' <<<"$upload_replace" >/dev/null

upload_two="$(CLASP_LEGAL_APPBENCH_UPLOAD_JSON="$(upload_payload "doc-delaware" "Delaware Case Notes" "delaware.txt" "Delaware case notes discuss force majeure notice and contractual remedies.")" run_with_env '"upload"' "$claspc_bin" run "$workspace_root/Main.clasp")"
grep -F '"documentCount":2' <<<"$upload_two" >/dev/null

ask_output="$(CLASP_LEGAL_APPBENCH_ASK_JSON="$ask_payload" run_with_env '"ask"' "$claspc_bin" run "$workspace_root/Main.clasp")"
grep -F '"latestRetrievedDocumentIds":["doc-msa","doc-delaware"]' <<<"$ask_output" >/dev/null
grep -F '"latestCitationLabels":["Master Services Agreement v2","Delaware Case Notes","Delaware Force Majeure Update"]' <<<"$ask_output" >/dev/null
grep -F '"latestToolKinds":["retrieval","web-search"]' <<<"$ask_output" >/dev/null

snapshot_output="$(run_with_env '"snapshot"' "$claspc_bin" run "$workspace_root/Main.clasp")"
grep -F '"chatTurnCount":5' <<<"$snapshot_output" >/dev/null

grep -F '"query": "Compare @document[doc-msa|Master Services Agreement] against current Delaware force majeure guidance."' "$state_root/search-log.json" >/dev/null

printf '%s\n' '{"status":"ok","implementation":"clasp-native","benchmarkTask":"clasp-legal-assistant-appbench"}'
