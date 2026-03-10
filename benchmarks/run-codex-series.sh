#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 || $# -gt 4 ]]; then
  echo "usage: $0 <task-id> <count> <note-prefix> [model]" >&2
  exit 1
fi

task_id="$1"
count="$2"
note_prefix="$3"
model="${4:-gpt-5.4}"
project_root="$(cd "$(dirname "$0")/.." && pwd)"

for index in $(seq 1 "$count"); do
  workspace="$project_root/benchmarks/workspaces/${task_id}-${note_prefix}-${index}"
  note="${note_prefix}-${index}"
  agent_command="CODEX_MODEL=$model CODEX_REASONING_EFFORT=high bash \"$project_root/benchmarks/run-codex-harness.sh\" \"\$CLASP_BENCHMARK_PROMPT_FILE\" \"\$CLASP_BENCHMARK_WORKSPACE\""

  nix develop "$project_root" --command node "$project_root/benchmarks/run-benchmark.mjs" run \
    "$task_id" \
    --workspace "$workspace" \
    --harness codex \
    --model "$model" \
    --notes "$note" \
    --agent-command "$agent_command"
done
