#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workspace_root="$project_root/benchmarks/workspaces/task-prep-check"

mkdir -p "$workspace_root"

list_output="$(node "$project_root/benchmarks/run-benchmark.mjs" list)"
printf '%s\n' "$list_output" | grep -q '^ts-lead-segment[[:space:]]'
printf '%s\n' "$list_output" | grep -q '^clasp-lead-segment[[:space:]]'

check_incomplete_task() {
  local task_id="$1"
  local workspace="$workspace_root/$task_id"

  node "$project_root/benchmarks/run-benchmark.mjs" prepare "$task_id" --workspace "$workspace" >/dev/null

  if node "$project_root/benchmarks/run-benchmark.mjs" verify "$task_id" --workspace "$workspace" --harness prep-check --model local >/dev/null; then
    echo "expected $task_id to fail verification before the benchmark change is applied" >&2
    return 1
  fi
}

check_incomplete_task ts-lead-segment
check_incomplete_task clasp-lead-segment
