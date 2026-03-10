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
reasoning_effort="${CODEX_REASONING_EFFORT:-medium}"
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
schema_file="$project_root/agents/schemas/builder-report.schema.json"
prompt_file="$(mktemp "${TMPDIR:-/tmp}/clasp-builder-prompt.XXXXXX")"

cleanup() {
  rm -f "$prompt_file"
}

trap cleanup EXIT

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
- The current checkout may be a plain copied workspace rather than a Git repository.
- Read `AGENTS.md` first if it exists.
- Do not rely on Git commands; use direct file inspection and `diff` if needed.
- Do not push.
- Prefer minimal, coherent edits over broad refactors.
- Start with the file paths named in the task findings or follow-up before scanning anything else.
- Avoid broad repo tours and repeated rereads of unrelated modules.
- Update docs only if the task changes the visible language/runtime behavior.
- Before finishing, run `bash scripts/verify-all.sh`.

Your final response must satisfy the provided JSON schema.
EOF
  if [[ -n "$feedback_file" && -f "$feedback_file" ]]; then
    node - <<'EOF' "$feedback_file"
const fs = require("fs");
const report = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const truncate = (value, max) =>
  value.length > max ? `${value.slice(0, max - 3)}...` : value;
const findings = (Array.isArray(report.findings) ? report.findings : [])
  .slice(0, 5)
  .map((item) => truncate(String(item), 240));
const followUp = (Array.isArray(report.follow_up) ? report.follow_up : [])
  .slice(0, 5)
  .map((item) => truncate(String(item), 200));
console.log("");
console.log("Verifier feedback from the previous attempt:");
if (typeof report.summary === "string" && report.summary.length > 0) {
  console.log(`Summary: ${truncate(report.summary, 320)}`);
}
if (findings.length > 0) {
  console.log("Findings:");
  for (const item of findings) {
    console.log(`- ${item}`);
  }
}
if (followUp.length > 0) {
  console.log("Follow up:");
  for (const item of followUp) {
    console.log(`- ${item}`);
  }
}
EOF
  fi
  cat <<'EOF'

Task:
EOF
  cat "$task_file"
} > "$prompt_file"

codex exec - \
  --json \
  -m "$model" \
  -c "model_reasoning_effort=\"$reasoning_effort\"" \
  --skip-git-repo-check \
  --cd "$workspace" \
  --dangerously-bypass-approvals-and-sandbox \
  --ephemeral \
  --output-schema "$schema_file" \
  -o "$report_json" \
  < "$prompt_file" \
  > "$log_jsonl"
