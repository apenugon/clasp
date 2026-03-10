#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 5 ]]; then
  echo "usage: $0 <task-file> <workspace> <base-rev> <report-json> <log-jsonl>" >&2
  exit 1
fi

task_file="$1"
workspace="$2"
base_rev="$3"
report_json="$4"
log_jsonl="$5"
model="${CODEX_MODEL:-gpt-5.4}"
reasoning_effort="${CODEX_REASONING_EFFORT:-high}"
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
schema_file="$project_root/agents/schemas/verifier-report.schema.json"

{
  cat <<EOF
You are the verifier subagent for the Clasp language repository.

Your job:
- verify the task described below against the current checkout
- inspect the diff from base revision $base_rev
- run the full repo verification command
- decide pass or fail

Rules:
- Do not intentionally edit source files.
- Treat `bash scripts/verify-all.sh` as the required verification gate.
- Use the git diff from the recorded base revision to focus your review.
- If verification fails, explain the concrete defects or missing coverage.

Your final response must satisfy the provided JSON schema.

Task:
EOF
  cat "$task_file"
} | codex exec \
  --json \
  -m "$model" \
  -c "model_reasoning_effort=\"$reasoning_effort\"" \
  --skip-git-repo-check \
  --cd "$workspace" \
  --dangerously-bypass-approvals-and-sandbox \
  --output-schema "$schema_file" \
  -o "$report_json" \
  - > "$log_jsonl"
