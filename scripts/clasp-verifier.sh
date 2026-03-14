#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 5 ]]; then
  echo "usage: $0 <task-file> <workspace> <baseline-workspace> <report-json> <log-jsonl>" >&2
  exit 1
fi

task_file="$1"
workspace="$2"
baseline_workspace="$3"
report_json="$4"
log_jsonl="$5"
model="${CODEX_MODEL:-gpt-5.4}"
reasoning_effort="${CODEX_REASONING_EFFORT:-medium}"
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
schema_file="$project_root/agents/schemas/verifier-report.schema.json"
prompt_file="$(mktemp "${TMPDIR:-/tmp}/clasp-verifier-prompt.XXXXXX")"
shared_codex_home="${CODEX_HOME:-$HOME/.codex}"
run_dir="$(dirname "$report_json")"
isolated_codex_home="$run_dir/codex-home"

source "$project_root/scripts/clasp-codex-home.sh"
source "$project_root/scripts/clasp-swarm-common.sh"

cleanup() {
  rm -f "$prompt_file"
}

trap cleanup EXIT

clasp_prepare_isolated_codex_home "$shared_codex_home" "$isolated_codex_home"

feedback_required=0
feedback_activation_task="$(clasp_swarm_feedback_activation_task)"
if clasp_swarm_feedback_required "$project_root" "$feedback_activation_task"; then
  feedback_required=1
fi

cat <<'EOF' > "$prompt_file"
You are the verifier subagent for the Clasp language repository.

Your job:
- verify the task described below against the current checkout
- inspect the filesystem diff from the last verified snapshot
- run the full repo verification command
- decide pass or fail

Rules:
- Do not intentionally edit source files.
- Read `AGENTS.md` first if it exists.
- Treat `bash scripts/verify-all.sh` as the required verification gate.
- Use `diff -ruN "$baseline_workspace" .` to focus your review.
- Prioritize reviewing the changed files before reading unrelated source.
- If verification fails, explain the concrete defects or missing coverage.
- Treat missing scenario-level or end-to-end verification for runtime, trust-boundary, workflow, interop, or app-surface changes as a real verification defect.
EOF
if (( feedback_required )); then
  cat <<EOF >> "$prompt_file"
- Because ${feedback_activation_task} is complete, this task must leave a committed feedback artifact for future agents under \`agents/feedback/\`.
- Treat missing, low-signal, or obviously generic feedback as a verification defect when the task changes source files.
EOF
fi
cat <<'EOF' >> "$prompt_file"

Your final response must satisfy the provided JSON schema.

Task:
EOF
printf 'Baseline workspace: %s\n\n' "$baseline_workspace" >> "$prompt_file"
cat "$task_file" >> "$prompt_file"

clasp_swarm_assert_prompt_size "$prompt_file" "verifier"

CODEX_HOME="$isolated_codex_home" codex exec - \
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
