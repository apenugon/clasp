#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 4 || $# -gt 5 ]]; then
  echo "usage: $0 <task-file> <workspace> <report-json> <log-jsonl> [feedback-file]" >&2
  exit 1
fi

task_file="$1"
workspace="$2"
report_json="$3"
log_jsonl="$4"
feedback_file="${5:-}"
model="${CODEX_MODEL:-gpt-5.4}"
reasoning_effort="${CODEX_REASONING_EFFORT:-high}"
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
schema_file="$project_root/agents/schemas/builder-report.schema.json"

{
  cat <<'EOF'
You are the builder subagent for the Clasp language repository.

Your job:
- implement exactly the task described below in the current checkout
- keep changes as small and local as possible
- add or update tests
- run the full repo verification command before finishing

Rules:
- Work only in the current checkout.
- Do not push.
- Prefer minimal, coherent edits over broad refactors.
- Update docs only if the task changes the visible language/runtime behavior.
- Before finishing, run `bash scripts/verify-all.sh`.

Your final response must satisfy the provided JSON schema.
EOF
  if [[ -n "$feedback_file" && -f "$feedback_file" ]]; then
    cat <<'EOF'

Verifier feedback from the previous attempt:
EOF
    cat "$feedback_file"
  fi
  cat <<'EOF'

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
