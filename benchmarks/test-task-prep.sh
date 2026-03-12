#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workspace_root="$project_root/benchmarks/workspaces/task-prep-check"

mkdir -p "$workspace_root"

list_output="$(node "$project_root/benchmarks/run-benchmark.mjs" list)"
printf '%s\n' "$list_output" | grep -q '^ts-lead-segment[[:space:]]'
printf '%s\n' "$list_output" | grep -q '^clasp-lead-segment[[:space:]]'

check_complete_task() {
  local task_id="$1"
  local workspace="$workspace_root/$task_id"

  node "$project_root/benchmarks/run-benchmark.mjs" prepare "$task_id" --workspace "$workspace" >/dev/null

  if ! node "$project_root/benchmarks/run-benchmark.mjs" verify "$task_id" --workspace "$workspace" --harness prep-check --model local >/dev/null; then
    echo "expected $task_id to pass verification after the benchmark change is applied" >&2
    return 1
  fi
}

assert_contains() {
  local file="$1"
  local pattern="$2"

  if ! grep -Fq "$pattern" "$file"; then
    echo "expected $file to contain: $pattern" >&2
    return 1
  fi
}

assert_not_contains() {
  local file="$1"
  local pattern="$2"

  if grep -Fq "$pattern" "$file"; then
    echo "expected $file to omit: $pattern" >&2
    return 1
  fi
}

check_complete_task ts-lead-segment
check_complete_task clasp-lead-segment

clasp_workspace="$workspace_root/clasp-lead-segment"
assert_contains "$clasp_workspace/test/lead-app.test.mjs" 'import { createServer } from "../server.mjs";'
assert_contains "$clasp_workspace/server.mjs" "export function createServer(bindings = {}, options = {})"
assert_not_contains "$clasp_workspace/test/lead-app.test.mjs" "storeLead(intake, summary)"

ts_workspace="$workspace_root/ts-lead-segment"
assert_contains "$ts_workspace/test/lead-app.test.mjs" 'import { createServer } from "../dist/server/main.js";'
