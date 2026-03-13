#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 || $# -gt 4 ]]; then
  echo "usage: $0 <task-id|app|control-plane|lead-priority|lead-rejection|lead-segment|external-adaptation|syntax-form> <count> <note-prefix> [model]" >&2
  exit 1
fi

task_id="$1"
count="$2"
note_prefix="$3"
model="${4:-sonnet}"
project_root="$(cd "$(dirname "$0")/.." && pwd)"

case "$task_id" in
  app)
    task_ids=(
      "clasp-lead-priority"
      "ts-lead-priority"
      "clasp-lead-rejection"
      "ts-lead-rejection"
      "clasp-lead-segment"
      "ts-lead-segment"
    )
    ;;
  control-plane)
    task_ids=(
      "clasp-control-plane"
      "ts-control-plane"
    )
    ;;
  lead-priority)
    task_ids=(
      "clasp-lead-priority"
      "ts-lead-priority"
    )
    ;;
  lead-rejection)
    task_ids=(
      "clasp-lead-rejection"
      "ts-lead-rejection"
    )
    ;;
  lead-segment)
    task_ids=(
      "clasp-lead-segment"
      "ts-lead-segment"
    )
    ;;
  external-adaptation)
    task_ids=(
      "clasp-external-adaptation"
      "ts-external-adaptation"
    )
    ;;
  syntax-form)
    task_ids=(
      "clasp-syntax-compact"
      "clasp-syntax-verbose"
    )
    ;;
  *)
    task_ids=("$task_id")
    ;;
esac

for index in $(seq 1 "$count"); do
  note="${note_prefix}-${index}"

  for current_task_id in "${task_ids[@]}"; do
    workspace="$project_root/benchmarks/workspaces/${current_task_id}-${note}"
    agent_command="CLAUDE_MODEL=$model bash \"$project_root/benchmarks/run-claude-harness.sh\" \"\$CLASP_BENCHMARK_PROMPT_FILE\" \"\$CLASP_BENCHMARK_WORKSPACE\""

    nix develop "$project_root" --command node "$project_root/benchmarks/run-benchmark.mjs" run \
      "$current_task_id" \
      --workspace "$workspace" \
      --harness claude-code \
      --model "$model" \
      --notes "$note" \
      --agent-command "$agent_command"
  done
done
