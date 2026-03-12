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

  if node "$project_root/benchmarks/run-benchmark.mjs" verify "$task_id" --workspace "$workspace" --harness prep-check --model local >/dev/null 2>&1; then
    echo "expected $task_id to fail verification before the benchmark change is applied" >&2
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

assert_files_match() {
  local left="$1"
  local right="$2"

  if ! cmp -s "$left" "$right"; then
    echo "expected $left to match $right" >&2
    return 1
  fi
}

assert_file_exists() {
  local target="$1"

  if [[ ! -f "$target" ]]; then
    echo "expected file to exist: $target" >&2
    return 1
  fi
}

check_product_only_clasp_solution() {
  local task_id="clasp-lead-segment"
  local workspace="$workspace_root/$task_id-product-only"
  local task_root="$project_root/benchmarks/tasks/$task_id/repo"

  node "$project_root/benchmarks/run-benchmark.mjs" prepare "$task_id" --workspace "$workspace" >/dev/null

  cp "$project_root/examples/lead-app/Shared/Lead.clasp" "$workspace/Shared/Lead.clasp"

  node "$project_root/benchmarks/run-benchmark.mjs" verify "$task_id" --workspace "$workspace" --harness prep-check --model local >/dev/null

  assert_files_match "$workspace/server.mjs" "$task_root/server.mjs"
  assert_files_match "$workspace/test/lead-app.test.mjs" "$task_root/test/lead-app.test.mjs"
}

check_nested_clasp_benchmark_prep() {
  local task_id="clasp-lead-priority"
  local workspace="$workspace_root/$task_id"

  node "$project_root/benchmarks/run-benchmark.mjs" prepare "$task_id" --workspace "$workspace" >/dev/null

  assert_file_exists "$workspace/benchmark-prep/Main.context.json"
  assert_file_exists "$workspace/benchmark-prep/Main.air.json"
  assert_file_exists "$workspace/benchmark-prep/Main.ui.json"
  assert_file_exists "$workspace/LANGUAGE_GUIDE.md"

  assert_contains "$workspace/benchmark-prep/Main.context.json" '"route:summarizeLeadRoute"'
  assert_contains "$workspace/benchmark-prep/Main.air.json" '"record:LeadRequest"'
  assert_contains "$workspace/benchmark-prep/Main.ui.json" '[]'
  assert_contains "$workspace/LANGUAGE_GUIDE.md" '`app/Main.clasp`'
  assert_contains "$workspace/LANGUAGE_GUIDE.md" '`benchmark-prep/Main.context.json`'
  assert_contains "$workspace/LANGUAGE_GUIDE.md" '`POST /lead/summary` request `LeadRequest` -> response `LeadSummary`'
}

check_incomplete_task ts-lead-segment
check_incomplete_task clasp-lead-segment
check_nested_clasp_benchmark_prep

clasp_workspace="$workspace_root/clasp-lead-segment"
assert_contains "$clasp_workspace/test/lead-app.test.mjs" 'import { createServer } from "../server.mjs";'
assert_contains "$clasp_workspace/server.mjs" "compiled.__claspAdaptHostBindings({"
assert_contains "$clasp_workspace/server.mjs" 'segment: toWireSegment(summary.segment) ?? toWireSegment(intake.segment) ?? "startup"'
assert_contains "$clasp_workspace/server.mjs" "const segment = toWireSegment(lead.segment);"
assert_not_contains "$clasp_workspace/Shared/Lead.clasp" "LeadSegment"

ts_workspace="$workspace_root/ts-lead-segment"
assert_contains "$ts_workspace/test/lead-app.test.mjs" 'import { createServer } from "../dist/server/main.js";'
assert_not_contains "$ts_workspace/src/shared/lead.ts" "LeadSegment"
assert_not_contains "$ts_workspace/src/server/main.ts" "segment:"

check_product_only_clasp_solution
