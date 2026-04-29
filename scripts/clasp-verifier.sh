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
model="${CODEX_MODEL:-gpt-5.5}"
reasoning_effort="${CODEX_REASONING_EFFORT:-xhigh}"
sandbox_mode="${CLASP_SWARM_CODEX_SANDBOX:-workspace-write}"
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
schema_file="$project_root/agents/schemas/verifier-report.schema.json"
prompt_file="$(mktemp "${TMPDIR:-/tmp}/clasp-verifier-prompt.XXXXXX")"
shared_codex_home="${CODEX_HOME:-$HOME/.codex}"
run_dir="$(dirname "$report_json")"
isolated_codex_home="$run_dir/codex-home"
sandbox_runtime_home="$(mktemp -d "${TMPDIR:-/tmp}/clasp-codex-runtime-home.XXXXXX")"
codex_sandbox_args=()

source "$project_root/scripts/clasp-codex-home.sh"
source "$project_root/scripts/clasp-swarm-common.sh"

cleanup() {
  rm -f "$prompt_file"
  rm -rf "$sandbox_runtime_home"
}

trap cleanup EXIT

case "$sandbox_mode" in
  read-only|workspace-write|danger-full-access)
    # Keep each lane contained to its worktree by default.
    codex_sandbox_args=(--sandbox "$sandbox_mode")
    ;;
  *)
    echo "CLASP_SWARM_CODEX_SANDBOX must be read-only, workspace-write, or danger-full-access" >&2
    exit 1
    ;;
esac

clasp_prepare_isolated_codex_home "$shared_codex_home" "$isolated_codex_home"
clasp_prepare_isolated_runtime_home "$sandbox_runtime_home"

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
- run the narrowest task-focused verification needed to establish correctness
- decide pass or fail

Rules:
- Do not intentionally edit source files.
- Read `AGENTS.md` first if it exists.
- Use `diff -ruN "$baseline_workspace" .` to focus your review.
- Prioritize reviewing the changed files before reading unrelated source.
- Prefer targeted checks that cover the changed surface.
- Do not fail solely because `bash scripts/verify-all.sh` cannot run inside this sandboxed verifier.
- The final merge gate runs the authoritative `bash scripts/verify-all.sh` on trunk before landing.
- If you can run `bash scripts/verify-all.sh` successfully here, mention it in `tests_run`, but it is not required for the verifier verdict.
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

HOME="$sandbox_runtime_home" \
XDG_CACHE_HOME="$sandbox_runtime_home/.cache" \
XDG_CONFIG_HOME="$sandbox_runtime_home/.config" \
XDG_DATA_HOME="$sandbox_runtime_home/.local/share" \
XDG_STATE_HOME="$sandbox_runtime_home/.local/state" \
TMPDIR="$sandbox_runtime_home/tmp" \
CODEX_HOME="$isolated_codex_home" codex exec - \
  --json \
  -m "$model" \
  -c "model_reasoning_effort=\"$reasoning_effort\"" \
  --skip-git-repo-check \
  --cd "$workspace" \
  "${codex_sandbox_args[@]}" \
  --ephemeral \
  --output-schema "$schema_file" \
  -o "$report_json" \
  < "$prompt_file" \
  > "$log_jsonl"
