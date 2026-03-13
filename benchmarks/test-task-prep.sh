#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workspace_root="$project_root/benchmarks/workspaces/task-prep-check"

mkdir -p "$workspace_root"

list_output="$(node "$project_root/benchmarks/run-benchmark.mjs" list)"
printf '%s\n' "$list_output" | grep -q '^ts-lead-segment[[:space:]]'
printf '%s\n' "$list_output" | grep -q '^clasp-lead-segment[[:space:]]'
printf '%s\n' "$list_output" | grep -q '^ts-lead-rejection[[:space:]]'
printf '%s\n' "$list_output" | grep -q '^clasp-lead-rejection[[:space:]]'
printf '%s\n' "$list_output" | grep -q '^ts-control-plane[[:space:]]'
printf '%s\n' "$list_output" | grep -q '^clasp-control-plane[[:space:]]'
printf '%s\n' "$list_output" | grep -q '^py-agent-escalation[[:space:]]'
printf '%s\n' "$list_output" | grep -q '^clasp-durable-workflow[[:space:]]'
printf '%s\n' "$list_output" | grep -q '^clasp-external-adaptation[[:space:]]'
printf '%s\n' "$list_output" | grep -q '^ts-external-adaptation[[:space:]]'
printf '%s\n' "$list_output" | grep -q '^clasp-syntax-compact[[:space:]]'
printf '%s\n' "$list_output" | grep -q '^clasp-syntax-verbose[[:space:]]'

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

check_fixture_seed_override() {
  local task_id="fixture-seed-env-check"
  local task_dir="$project_root/benchmarks/tasks/$task_id"
  local override_workspace="$workspace_root/$task_id-override"
  local fallback_workspace="$workspace_root/$task_id-fallback"

  rm -rf "$task_dir" "$override_workspace" "$fallback_workspace"
  mkdir -p "$task_dir/repo"

  cat <<'JSON' >"$task_dir/task.json"
{
  "id": "fixture-seed-env-check",
  "title": "Fixture seed env check",
  "suite": "harness-regression",
  "language": "typescript",
  "repo": "repo",
  "prompt": "prompt.md",
  "prepare": [
    ["python3", "-c", "from pathlib import Path; import os; Path('prepare-seed.txt').write_text(os.environ['CLASP_APP_FIXTURE_SEED'] + '\\n', encoding='utf8')"]
  ],
  "verify": ["python3", "-c", "from pathlib import Path; import os, sys; Path('verify-seed.txt').write_text(os.environ['CLASP_APP_FIXTURE_SEED'] + '\\n', encoding='utf8'); sys.exit(0 if os.environ['CLASP_APP_FIXTURE_SEED'] == Path('expected-seed.txt').read_text(encoding='utf8').strip() else 1)"]
}
JSON

  cat <<'EOF' >"$task_dir/prompt.md"
Fixture seed env regression.
EOF

  cat <<'EOF' >"$task_dir/repo/expected-seed.txt"
override-seed
EOF

  CLASP_APP_FIXTURE_SEED="override-seed" \
    node "$project_root/benchmarks/run-benchmark.mjs" prepare "$task_id" --workspace "$override_workspace" >/dev/null
  assert_contains "$override_workspace/prepare-seed.txt" "override-seed"

  CLASP_APP_FIXTURE_SEED="override-seed" \
    node "$project_root/benchmarks/run-benchmark.mjs" verify "$task_id" --workspace "$override_workspace" --harness prep-check --model local >/dev/null
  assert_contains "$override_workspace/verify-seed.txt" "override-seed"

  printf '%s\n' "$task_id" >"$task_dir/repo/expected-seed.txt"
  CLASP_APP_FIXTURE_SEED="" \
    node "$project_root/benchmarks/run-benchmark.mjs" prepare "$task_id" --workspace "$fallback_workspace" >/dev/null
  assert_contains "$fallback_workspace/prepare-seed.txt" "$task_id"

  CLASP_APP_FIXTURE_SEED="" \
    node "$project_root/benchmarks/run-benchmark.mjs" verify "$task_id" --workspace "$fallback_workspace" --harness prep-check --model local >/dev/null
  assert_contains "$fallback_workspace/verify-seed.txt" "$task_id"

  rm -rf "$task_dir" "$override_workspace" "$fallback_workspace"
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

check_product_only_typescript_solution() {
  local task_id="ts-lead-segment"
  local workspace="$workspace_root/$task_id-product-only"
  local task_root="$project_root/benchmarks/tasks/$task_id/repo"

  node "$project_root/benchmarks/run-benchmark.mjs" prepare "$task_id" --workspace "$workspace" >/dev/null

  cp "$project_root/examples/lead-app-ts/src/shared/lead.ts" "$workspace/src/shared/lead.ts"
  cp "$project_root/examples/lead-app-ts/src/server/main.ts" "$workspace/src/server/main.ts"

  node "$project_root/benchmarks/run-benchmark.mjs" verify "$task_id" --workspace "$workspace" --harness prep-check --model local >/dev/null

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
check_incomplete_task ts-lead-rejection
check_incomplete_task clasp-lead-rejection
check_incomplete_task ts-control-plane
check_incomplete_task clasp-control-plane
check_incomplete_task py-agent-escalation
check_incomplete_task clasp-durable-workflow
check_incomplete_task clasp-external-adaptation
check_incomplete_task ts-external-adaptation
check_incomplete_task clasp-syntax-compact
check_incomplete_task clasp-syntax-verbose
check_nested_clasp_benchmark_prep
check_fixture_seed_override

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

clasp_rejection_workspace="$workspace_root/clasp-lead-rejection"
assert_contains "$clasp_rejection_workspace/test/rejection.test.mjs" 'import { installRuntime, serveCompiledModule } from "../runtime/server.mjs";'
assert_not_contains "$clasp_rejection_workspace/app/Shared/Lead.clasp" "type Priority"
assert_not_contains "$clasp_rejection_workspace/app/Shared/Lead.clasp" "priorityHint"
assert_not_contains "$clasp_rejection_workspace/app/Shared/Lead.clasp" "priority :"

ts_rejection_workspace="$workspace_root/ts-lead-rejection"
assert_contains "$ts_rejection_workspace/test/rejection.test.mjs" 'import { createServer } from "../dist/server/main.js";'
assert_not_contains "$ts_rejection_workspace/src/shared/lead.ts" "priorityHint"
assert_not_contains "$ts_rejection_workspace/src/shared/lead.ts" "priority:"

clasp_control_workspace="$workspace_root/clasp-control-plane"
assert_contains "$clasp_control_workspace/Main.clasp" 'approval: never'
assert_contains "$clasp_control_workspace/Main.clasp" 'sandbox: read_only'
assert_contains "$clasp_control_workspace/Main.clasp" 'process "rg"'
assert_not_contains "$clasp_control_workspace/Main.clasp" 'process "bash"'
assert_not_contains "$clasp_control_workspace/Main.clasp" 'secret "OPENAI_API_KEY"'
assert_not_contains "$clasp_control_workspace/Main.clasp" 'verification: "Run bash scripts/verify-all.sh before finishing."'

ts_control_workspace="$workspace_root/ts-control-plane"
assert_contains "$ts_control_workspace/src/controlPlane.ts" 'file: ["/workspace", "/tmp"]'
assert_contains "$ts_control_workspace/src/controlPlane.ts" 'network: ["api.openai.com", "example.com"]'
assert_contains "$ts_control_workspace/src/controlPlane.ts" 'process: ["rg", "git"]'
assert_contains "$ts_control_workspace/src/controlPlane.ts" 'secret: []'
assert_contains "$ts_control_workspace/src/controlPlane.ts" 'approvalPolicy: "never"'
assert_contains "$ts_control_workspace/src/controlPlane.ts" 'sandboxPolicy: "read_only"'

durable_workspace="$workspace_root/clasp-durable-workflow"
assert_file_exists "$durable_workspace/benchmark-prep/Main.context.json"
assert_file_exists "$durable_workspace/LANGUAGE_GUIDE.md"
assert_contains "$durable_workspace/benchmark-prep/Main.context.json" '"schema:Counter"'
assert_contains "$durable_workspace/LANGUAGE_GUIDE.md" '`Main.clasp`'
assert_contains "$durable_workspace/test/durable-workflow.test.mjs" 'import { runDurableWorkflowDemo } from "../demo.mjs";'
assert_contains "$durable_workspace/demo.mjs" "overlapStatus: null"
assert_contains "$durable_workspace/demo.mjs" "autoRollbackStatus: null"
assert_contains "$durable_workspace/demo.mjs" "manualRollbackStatus: null"

syntax_compact_workspace="$workspace_root/clasp-syntax-compact"
assert_file_exists "$syntax_compact_workspace/benchmark-prep/Main.context.json"
assert_not_contains "$syntax_compact_workspace/LANGUAGE_GUIDE.md" '`benchmark-prep/Main.explain.txt`'
if [[ -f "$syntax_compact_workspace/benchmark-prep/Main.explain.txt" ]]; then
  echo "expected compact syntax workspace to omit explain artifact" >&2
  exit 1
fi

syntax_verbose_workspace="$workspace_root/clasp-syntax-verbose"
assert_file_exists "$syntax_verbose_workspace/benchmark-prep/Main.context.json"
assert_file_exists "$syntax_verbose_workspace/benchmark-prep/Main.explain.txt"
assert_contains "$syntax_verbose_workspace/benchmark-prep/Main.explain.txt" 'leadSummary : Lead -> Str'
assert_contains "$syntax_verbose_workspace/LANGUAGE_GUIDE.md" '`benchmark-prep/Main.explain.txt`'

check_product_only_clasp_solution
check_product_only_typescript_solution
