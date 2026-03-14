#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workspace_root="$project_root/benchmarks/workspaces/secret-handling-check"

rm -rf "$workspace_root"
mkdir -p "$workspace_root"

verify_solution() {
  local task_id="$1"
  local workspace="$workspace_root/$task_id"
  local solution_root="$project_root/benchmarks/tasks/$task_id/solution"

  node "$project_root/benchmarks/run-benchmark.mjs" prepare "$task_id" --workspace "$workspace" >/dev/null
  cp -R "$solution_root/." "$workspace/"

  node "$project_root/benchmarks/run-benchmark.mjs" verify "$task_id" \
    --workspace "$workspace" \
    --harness scenario \
    --model deterministic >/dev/null
}

verify_solution "clasp-secret-handling"
verify_solution "ts-secret-handling"
