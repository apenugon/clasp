#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "usage: $0 <prompt-file> <workspace> [json-output]" >&2
  exit 1
fi

prompt_file="$1"
workspace="$2"
json_output="${3:-$workspace/codex-run.jsonl}"
model="${CODEX_MODEL:-gpt-5.4}"
reasoning_effort="${CODEX_REASONING_EFFORT:-high}"

{
  cat <<'EOF'
Benchmark harness instructions:
- Work inside the current benchmark workspace.
- Do not inspect parent directories or $CLASP_PROJECT_ROOT unless `bash scripts/verify.sh` fails in a way that points to a compiler or runtime bug rather than an app change.
- Prefer the smallest local edit set that satisfies the tests.
- Use the files in the workspace as the primary source of truth.

EOF
  cat "$prompt_file"
} | codex exec \
  --json \
  -m "$model" \
  -c "model_reasoning_effort=\"$reasoning_effort\"" \
  --skip-git-repo-check \
  --cd "$workspace" \
  --dangerously-bypass-approvals-and-sandbox \
  - > "$json_output"
