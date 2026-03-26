#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workspace_root="$project_root/benchmarks/workspaces/task-prep-check"
results_root="$project_root/benchmarks/results"

mkdir -p "$workspace_root"

list_output="$(node "$project_root/benchmarks/run-benchmark.mjs" list)"
printf '%s\n' "$list_output" | grep -q '^ts-lead-segment[[:space:]]'
printf '%s\n' "$list_output" | grep -q '^ts-lead-persistence[[:space:]]'
printf '%s\n' "$list_output" | grep -q '^clasp-lead-segment[[:space:]]'
printf '%s\n' "$list_output" | grep -q '^ts-lead-rejection[[:space:]]'
printf '%s\n' "$list_output" | grep -q '^clasp-lead-rejection[[:space:]]'
printf '%s\n' "$list_output" | grep -q '^ts-control-plane[[:space:]]'
printf '%s\n' "$list_output" | grep -q '^clasp-control-plane[[:space:]]'
printf '%s\n' "$list_output" | grep -q '^py-agent-escalation[[:space:]]'
printf '%s\n' "$list_output" | grep -q '^clasp-durable-workflow[[:space:]]'
printf '%s\n' "$list_output" | grep -q '^clasp-workflow-correctness[[:space:]]'
printf '%s\n' "$list_output" | grep -q '^clasp-external-adaptation[[:space:]]'
printf '%s\n' "$list_output" | grep -q '^ts-external-adaptation[[:space:]]'
printf '%s\n' "$list_output" | grep -q '^clasp-npm-interop[[:space:]]'
printf '%s\n' "$list_output" | grep -q '^ts-npm-interop[[:space:]]'
printf '%s\n' "$list_output" | grep -q '^clasp-python-interop[[:space:]]'
printf '%s\n' "$list_output" | grep -q '^ts-python-interop[[:space:]]'
printf '%s\n' "$list_output" | grep -q '^clasp-rust-interop[[:space:]]'
printf '%s\n' "$list_output" | grep -q '^ts-rust-interop[[:space:]]'
printf '%s\n' "$list_output" | grep -q '^clasp-interop-boundary[[:space:]]'
printf '%s\n' "$list_output" | grep -q '^ts-interop-boundary[[:space:]]'
printf '%s\n' "$list_output" | grep -q '^clasp-secret-handling[[:space:]]'
printf '%s\n' "$list_output" | grep -q '^ts-secret-handling[[:space:]]'
printf '%s\n' "$list_output" | grep -q '^clasp-authorization-data-access[[:space:]]'
printf '%s\n' "$list_output" | grep -q '^ts-authorization-data-access[[:space:]]'
printf '%s\n' "$list_output" | grep -q '^clasp-audit-log[[:space:]]'
printf '%s\n' "$list_output" | grep -q '^ts-audit-log[[:space:]]'
printf '%s\n' "$list_output" | grep -q '^clasp-compiler-maintenance[[:space:]]'
printf '%s\n' "$list_output" | grep -q '^clasp-syntax-compact[[:space:]]'
printf '%s\n' "$list_output" | grep -q '^clasp-syntax-verbose[[:space:]]'

check_incomplete_task() {
  local task_id="$1"
  local workspace="$workspace_root/$task_id"
  local recovery_args=()

  if [[ "$task_id" == clasp-* ]]; then
    recovery_args=(--allow-bootstrap-recovery true)
  fi

  if [[ "${#recovery_args[@]}" -gt 0 ]]; then
    run_benchmark_prepare "$task_id" "$workspace" "${recovery_args[@]}" >/dev/null
  else
    run_benchmark_prepare "$task_id" "$workspace" >/dev/null
  fi

  if [[ "${#recovery_args[@]}" -gt 0 ]]; then
    return 0
  elif run_benchmark_verify "$task_id" "$workspace" --harness prep-check --model local >/dev/null 2>&1; then
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

latest_result_for_harness() {
  local harness="$1"
  local latest_result=""
  local latest_mtime=0
  local stat_format=()

  if stat -c '%Y' "$results_root" >/dev/null 2>&1; then
    stat_format=(-c '%Y')
  else
    stat_format=(-f '%m')
  fi

  for candidate in "$results_root"/*--"$harness".json; do
    [[ -e "$candidate" ]] || continue
    local candidate_mtime
    candidate_mtime="$(stat "${stat_format[@]}" "$candidate")"
    if [[ -z "$latest_result" || "$candidate_mtime" -gt "$latest_mtime" ]]; then
      latest_result="$candidate"
      latest_mtime="$candidate_mtime"
    fi
  done

  if [[ -z "$latest_result" ]]; then
    echo "expected at least one benchmark result artifact for harness $harness" >&2
    return 1
  fi

  printf '%s\n' "$latest_result"
}

run_benchmark_prepare() {
  local task_id="$1"
  local workspace="$2"
  shift 2

  node "$project_root/benchmarks/run-benchmark.mjs" prepare "$task_id" --workspace "$workspace" "$@"
}

run_benchmark_verify() {
  local task_id="$1"
  local workspace="$2"
  shift 2

  node "$project_root/benchmarks/run-benchmark.mjs" verify "$task_id" --workspace "$workspace" "$@"
}

run_clasp_backend_static_verify() {
  local workspace="$1"
  shift || true

  bash "$project_root/benchmarks/verify-clasp-backend-check.sh" "$workspace" "$@"
}

check_default_clasp_benchmark_path_requires_recovery() {
  local task_id="clasp-lead-segment"
  local workspace="$workspace_root/$task_id-default-blocked"
  local output

  if output="$(run_benchmark_prepare "$task_id" "$workspace" 2>&1)"; then
    echo "expected $task_id default prepare to require explicit bootstrap recovery" >&2
    return 1
  fi

  printf '%s\n' "$output" | grep -Fq 'rerun with --allow-bootstrap-recovery true'
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
  run_benchmark_prepare "$task_id" "$override_workspace" >/dev/null
  assert_contains "$override_workspace/prepare-seed.txt" "override-seed"

  CLASP_APP_FIXTURE_SEED="override-seed" \
    run_benchmark_verify "$task_id" "$override_workspace" --harness prep-check --model local >/dev/null
  assert_contains "$override_workspace/verify-seed.txt" "override-seed"

  printf '%s\n' "$task_id" >"$task_dir/repo/expected-seed.txt"
  CLASP_APP_FIXTURE_SEED="" \
    run_benchmark_prepare "$task_id" "$fallback_workspace" >/dev/null
  assert_contains "$fallback_workspace/prepare-seed.txt" "$task_id"

  CLASP_APP_FIXTURE_SEED="" \
    run_benchmark_verify "$task_id" "$fallback_workspace" --harness prep-check --model local >/dev/null
  assert_contains "$fallback_workspace/verify-seed.txt" "$task_id"

  rm -rf "$task_dir" "$override_workspace" "$fallback_workspace"
}

check_product_only_clasp_solution() {
  local task_id="clasp-lead-segment"
  local workspace="$workspace_root/$task_id-product-only"
  local task_root="$project_root/benchmarks/tasks/$task_id/repo"

  run_benchmark_prepare "$task_id" "$workspace" --allow-bootstrap-recovery true >/dev/null

  cp "$project_root/examples/lead-app/Shared/Lead.clasp" "$workspace/Shared/Lead.clasp"

  run_clasp_backend_static_verify "$workspace"

  if [[ -e "$workspace/server.mjs" ]]; then
    echo "expected $workspace/server.mjs to be omitted from native benchmark workspaces" >&2
    exit 1
  fi
  assert_files_match "$workspace/test/lead-app.test.mjs" "$task_root/test/lead-app.test.mjs"
}

check_product_only_typescript_solution() {
  local task_id="ts-lead-segment"
  local workspace="$workspace_root/$task_id-product-only"
  local task_root="$project_root/benchmarks/tasks/$task_id/repo"

  run_benchmark_prepare "$task_id" "$workspace" >/dev/null

  cp "$project_root/examples/lead-app-ts/src/shared/lead.ts" "$workspace/src/shared/lead.ts"
  cp "$project_root/examples/lead-app-ts/src/server/main.ts" "$workspace/src/server/main.ts"
  cp "$project_root/examples/lead-app-ts/src/server/store.ts" "$workspace/src/server/store.ts"
  cp "$project_root/examples/lead-app-ts/src/server/runtime-modules.d.ts" "$workspace/src/server/runtime-modules.d.ts"

  run_benchmark_verify "$task_id" "$workspace" --harness prep-check --model local >/dev/null

  assert_files_match "$workspace/test/lead-app.test.mjs" "$task_root/test/lead-app.test.mjs"
}

check_product_only_typescript_persistence_solution() {
  local task_id="ts-lead-persistence"
  local workspace="$workspace_root/$task_id-product-only"
  local task_root="$project_root/benchmarks/tasks/$task_id/repo"

  run_benchmark_prepare "$task_id" "$workspace" >/dev/null

  cp "$project_root/examples/lead-app-ts/src/server/main.ts" "$workspace/src/server/main.ts"
  cp "$project_root/examples/lead-app-ts/src/server/store.ts" "$workspace/src/server/store.ts"
  cp "$project_root/examples/lead-app-ts/src/server/runtime-modules.d.ts" "$workspace/src/server/runtime-modules.d.ts"
  cp "$project_root/examples/lead-app-ts/src/server/dev.ts" "$workspace/src/server/dev.ts"

  run_benchmark_verify "$task_id" "$workspace" --harness prep-check --model local >/dev/null

  assert_files_match "$workspace/test/lead-app.test.mjs" "$task_root/test/lead-app.test.mjs"
}

check_product_only_clasp_workflow_correctness_solution() {
  local task_id="clasp-workflow-correctness"
  local workspace="$workspace_root/$task_id-product-only"
  local task_root="$project_root/benchmarks/tasks/$task_id/repo"
  local solution_root="$project_root/benchmarks/tasks/$task_id/solution"

  run_benchmark_prepare "$task_id" "$workspace" --allow-bootstrap-recovery true >/dev/null

  cp "$solution_root/Main.clasp" "$workspace/Main.clasp"

  run_clasp_backend_static_verify "$workspace"

  assert_files_match "$workspace/test/workflow-correctness.test.mjs" "$task_root/test/workflow-correctness.test.mjs"
}

check_oracle_prompt_mode() {
  local clasp_workspace="$workspace_root/clasp-lead-segment-oracle"
  local ts_workspace="$workspace_root/ts-lead-segment-oracle"
  local clasp_prepare_output
  local ts_prepare_output

  clasp_prepare_output="$(run_benchmark_prepare clasp-lead-segment "$clasp_workspace" --mode oracle --allow-bootstrap-recovery true)"
  printf '%s\n' "$clasp_prepare_output" | grep -Fq 'Prompt: '
  printf '%s\n' "$clasp_prepare_output" | grep -Fq 'benchmarks/tasks/clasp-lead-segment/prompt.oracle.md'

  cp "$project_root/examples/lead-app/Shared/Lead.clasp" "$clasp_workspace/Shared/Lead.clasp"
  run_clasp_backend_static_verify "$clasp_workspace"

  ts_prepare_output="$(node "$project_root/benchmarks/run-benchmark.mjs" prepare ts-lead-segment --mode oracle --workspace "$ts_workspace")"
  printf '%s\n' "$ts_prepare_output" | grep -Fq 'Prompt: '
  printf '%s\n' "$ts_prepare_output" | grep -Fq 'benchmarks/tasks/ts-lead-segment/prompt.oracle.md'
}

check_persistence_prompt_modes() {
  local raw_workspace="$workspace_root/ts-lead-persistence-raw"
  local hinted_workspace="$workspace_root/ts-lead-persistence-file-hinted"
  local oracle_workspace="$workspace_root/ts-lead-persistence-oracle"
  local raw_output
  local hinted_output
  local oracle_output
  local latest_result

  raw_output="$(run_benchmark_prepare ts-lead-persistence "$raw_workspace" --mode raw-repo)"
  printf '%s\n' "$raw_output" | grep -Fq 'Prompt: '
  printf '%s\n' "$raw_output" | grep -Fq 'benchmarks/tasks/ts-lead-persistence/prompt.raw.md'

  hinted_output="$(run_benchmark_prepare ts-lead-persistence "$hinted_workspace" --mode file-hinted)"
  printf '%s\n' "$hinted_output" | grep -Fq 'Prompt: '
  printf '%s\n' "$hinted_output" | grep -Fq 'benchmarks/tasks/ts-lead-persistence/prompt.file-hinted.md'

  oracle_output="$(run_benchmark_prepare ts-lead-persistence "$oracle_workspace" --mode oracle)"
  printf '%s\n' "$oracle_output" | grep -Fq 'Prompt: '
  printf '%s\n' "$oracle_output" | grep -Fq 'benchmarks/tasks/ts-lead-persistence/prompt.oracle.md'

  cp "$project_root/examples/lead-app-ts/src/server/main.ts" "$oracle_workspace/src/server/main.ts"
  cp "$project_root/examples/lead-app-ts/src/server/store.ts" "$oracle_workspace/src/server/store.ts"
  cp "$project_root/examples/lead-app-ts/src/server/runtime-modules.d.ts" "$oracle_workspace/src/server/runtime-modules.d.ts"
  cp "$project_root/examples/lead-app-ts/src/server/dev.ts" "$oracle_workspace/src/server/dev.ts"

  run_benchmark_verify ts-lead-persistence "$oracle_workspace" \
    --harness oracle-check \
    --model local \
    --mode oracle >/dev/null

  latest_result="$(latest_result_for_harness oracle-check)"
  assert_contains "$latest_result" '"mode": "oracle"'
  assert_contains "$latest_result" '"promptFile": "benchmarks/tasks/ts-lead-persistence/prompt.oracle.md"'
  rm -f "$latest_result"
}

check_nested_clasp_benchmark_prep() {
  local task_id="clasp-lead-priority"
  local workspace="$workspace_root/$task_id"

  run_benchmark_prepare "$task_id" "$workspace" --allow-bootstrap-recovery true >/dev/null

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

check_default_clasp_benchmark_path_requires_recovery
check_incomplete_task ts-lead-segment
check_incomplete_task ts-lead-persistence
check_incomplete_task clasp-lead-segment
check_incomplete_task ts-lead-rejection
check_incomplete_task clasp-lead-rejection
check_incomplete_task ts-control-plane
check_incomplete_task clasp-control-plane
check_incomplete_task py-agent-escalation
check_incomplete_task clasp-durable-workflow
check_incomplete_task clasp-workflow-correctness
check_incomplete_task clasp-external-adaptation
check_incomplete_task ts-external-adaptation
check_incomplete_task clasp-npm-interop
check_incomplete_task ts-npm-interop
check_incomplete_task clasp-python-interop
check_incomplete_task ts-python-interop
check_incomplete_task clasp-rust-interop
check_incomplete_task ts-rust-interop
check_incomplete_task clasp-interop-boundary
check_incomplete_task ts-interop-boundary
check_incomplete_task clasp-secret-handling
check_incomplete_task ts-secret-handling
check_incomplete_task clasp-authorization-data-access
check_incomplete_task ts-authorization-data-access
check_incomplete_task clasp-audit-log
check_incomplete_task ts-audit-log
check_incomplete_task clasp-compiler-maintenance
check_incomplete_task clasp-syntax-compact
check_incomplete_task clasp-syntax-verbose
check_nested_clasp_benchmark_prep
check_fixture_seed_override

clasp_workspace="$workspace_root/clasp-lead-segment"
assert_contains "$clasp_workspace/test/lead-app.test.mjs" 'const binaryPath = process.env.CLASP_BENCH_BINARY;'
assert_contains "$clasp_workspace/test/lead-app.test.mjs" 'withNativeServer(binaryPath'
if [[ -e "$clasp_workspace/server.mjs" ]]; then
  echo "expected clasp-lead-segment workspace to omit server.mjs" >&2
  exit 1
fi
if [[ -e "$clasp_workspace/runtime/server.mjs" ]]; then
  echo "expected clasp-lead-segment workspace to omit runtime/server.mjs" >&2
  exit 1
fi
assert_not_contains "$clasp_workspace/Shared/Lead.clasp" "LeadSegment"

ts_workspace="$workspace_root/ts-lead-segment"
assert_contains "$ts_workspace/test/lead-app.test.mjs" 'import { createServer } from "../dist/server/main.js";'
assert_not_contains "$ts_workspace/src/shared/lead.ts" "LeadSegment"
assert_not_contains "$ts_workspace/src/server/main.ts" "segment:"

ts_persistence_workspace="$workspace_root/ts-lead-persistence"
assert_contains "$ts_persistence_workspace/test/lead-app.test.mjs" 'lead app schema version 999 is incompatible with expected version 1'
assert_not_contains "$ts_persistence_workspace/src/server/main.ts" 'createLeadStore'
if [[ -f "$ts_persistence_workspace/src/server/store.ts" ]]; then
  echo "expected ts-lead-persistence workspace to omit src/server/store.ts" >&2
  exit 1
fi

clasp_rejection_workspace="$workspace_root/clasp-lead-rejection"
assert_contains "$clasp_rejection_workspace/test/rejection.test.mjs" 'const binaryPath = process.env.CLASP_BENCH_BINARY;'
assert_contains "$clasp_rejection_workspace/test/rejection.test.mjs" 'CLASP_MOCK_LEAD_SUMMARY_PRIORITY'
if [[ -e "$clasp_rejection_workspace/runtime/server.mjs" ]]; then
  echo "expected clasp-lead-rejection workspace to omit runtime/server.mjs" >&2
  exit 1
fi
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

workflow_correctness_workspace="$workspace_root/clasp-workflow-correctness"
assert_file_exists "$workflow_correctness_workspace/benchmark-prep/Main.context.json"
assert_file_exists "$workflow_correctness_workspace/benchmark-prep/Main.air.json"
assert_file_exists "$workflow_correctness_workspace/LANGUAGE_GUIDE.md"
assert_contains "$workflow_correctness_workspace/benchmark-prep/Main.context.json" '"schema:Counter"'
assert_contains "$workflow_correctness_workspace/benchmark-prep/Main.air.json" '"decl:nonNegative"'
assert_contains "$workflow_correctness_workspace/LANGUAGE_GUIDE.md" '`Main.clasp`'
assert_contains "$workflow_correctness_workspace/test/workflow-correctness.test.mjs" 'runWorkflowCorrectnessDemo'
assert_not_contains "$workflow_correctness_workspace/Main.clasp" 'invariant : nonNegative'
assert_not_contains "$workflow_correctness_workspace/Main.clasp" 'precondition : belowLimit'
assert_not_contains "$workflow_correctness_workspace/Main.clasp" 'postcondition : withinLimit'

clasp_npm_workspace="$workspace_root/clasp-npm-interop"
assert_file_exists "$clasp_npm_workspace/benchmark-prep/Main.context.json"
assert_contains "$clasp_npm_workspace/LANGUAGE_GUIDE.md" '`Main.clasp`'
assert_contains "$clasp_npm_workspace/LANGUAGE_GUIDE.md" '`benchmark-prep/Main.context.json`'
assert_not_contains "$clasp_npm_workspace/Main.clasp" 'from npm "local-upper"'
assert_not_contains "$clasp_npm_workspace/Main.clasp" 'from typescript "./support/formatLead.mjs"'

ts_npm_workspace="$workspace_root/ts-npm-interop"
assert_not_contains "$ts_npm_workspace/src/main.mjs" 'local-upper'
assert_not_contains "$ts_npm_workspace/src/main.mjs" 'formatLead'

clasp_python_workspace="$workspace_root/clasp-python-interop"
assert_file_exists "$clasp_python_workspace/benchmark-prep/Main.context.json"
assert_contains "$clasp_python_workspace/LANGUAGE_GUIDE.md" '`Main.clasp`'
assert_not_contains "$clasp_python_workspace/Main.clasp" 'hook workerStart'
assert_not_contains "$clasp_python_workspace/Main.clasp" 'route summarizeRoute'

ts_python_workspace="$workspace_root/ts-python-interop"
assert_contains "$ts_python_workspace/test/python-interop.test.mjs" 'runPythonInteropDemo'
assert_not_contains "$ts_python_workspace/src/main.mjs" 'spawn('

clasp_rust_workspace="$workspace_root/clasp-rust-interop"
assert_file_exists "$clasp_rust_workspace/benchmark-prep/Main.context.json"
assert_contains "$clasp_rust_workspace/LANGUAGE_GUIDE.md" '`Main.clasp`'
assert_not_contains "$clasp_rust_workspace/Main.clasp" 'foreign mockLeadSummaryModel'

ts_rust_workspace="$workspace_root/ts-rust-interop"
assert_contains "$ts_rust_workspace/test/rust-interop.test.mjs" 'resolveLeadSummaryNativePlan'
assert_not_contains "$ts_rust_workspace/src/nativeInterop.mjs" 'lead_summary_bridge'

clasp_boundary_workspace="$workspace_root/clasp-interop-boundary"
assert_file_exists "$clasp_boundary_workspace/benchmark-prep/Main.context.json"
assert_contains "$clasp_boundary_workspace/LANGUAGE_GUIDE.md" '`Main.clasp`'
assert_not_contains "$clasp_boundary_workspace/Main.clasp" 'foreign unsafe inspectLead'
assert_not_contains "$clasp_boundary_workspace/Main.clasp" 'from typescript "./support/inspectLead.mjs"'

ts_boundary_workspace="$workspace_root/ts-interop-boundary"
assert_contains "$ts_boundary_workspace/test/interop-boundary.test.mjs" 'runInteropBoundaryDemo'
assert_not_contains "$ts_boundary_workspace/src/main.mjs" 'inspectLead('

clasp_secret_workspace="$workspace_root/clasp-secret-handling"
assert_not_contains "$clasp_secret_workspace/Main.clasp" 'secret "SEARCH_API_TOKEN"'

ts_secret_workspace="$workspace_root/ts-secret-handling"
assert_contains "$ts_secret_workspace/src/main.mjs" 'secretNames: Object.freeze([])'

clasp_authorization_workspace="$workspace_root/clasp-authorization-data-access"
assert_not_contains "$clasp_authorization_workspace/Main.clasp" 'policy SupportAccess = public, pii'
assert_not_contains "$clasp_authorization_workspace/Main.clasp" 'projection SupportCustomer = Customer with SupportAccess { id, company, contactEmail, plan }'
assert_contains "$clasp_authorization_workspace/Main.clasp" 'writeProofPolicy = "PublicAccess"'

ts_authorization_workspace="$workspace_root/ts-authorization-data-access"
assert_contains "$ts_authorization_workspace/src/main.mjs" 'writeProofPolicy: "PublicAccess"'
assert_contains "$ts_authorization_workspace/src/main.mjs" 'disclosedField: "plan"'

clasp_audit_workspace="$workspace_root/clasp-audit-log"
assert_contains "$clasp_audit_workspace/Main.clasp" 'retentionDays = 7'
assert_not_contains "$clasp_audit_workspace/Main.clasp" 'TypedRouteAudit'

ts_audit_workspace="$workspace_root/ts-audit-log"
assert_contains "$ts_audit_workspace/src/main.mjs" 'retentionDays: 7'
assert_contains "$ts_audit_workspace/src/main.mjs" 'typedEventKinds: Object.freeze(["route", "tool", "workflow"])'

compiler_maintenance_workspace="$workspace_root/clasp-compiler-maintenance"
assert_file_exists "$compiler_maintenance_workspace/benchmark-prep/Main.context.json"
assert_file_exists "$compiler_maintenance_workspace/LANGUAGE_GUIDE.md"
assert_contains "$compiler_maintenance_workspace/benchmark-prep/Main.context.json" '"schema:SelfHostSnapshot"'
assert_contains "$compiler_maintenance_workspace/LANGUAGE_GUIDE.md" 'Compiler/Checker.clasp'
assert_contains "$compiler_maintenance_workspace/LANGUAGE_GUIDE.md" 'Compiler/Lower.clasp'
assert_contains "$compiler_maintenance_workspace/LANGUAGE_GUIDE.md" 'Compiler/Emit/JavaScript.clasp'
assert_contains "$compiler_maintenance_workspace/test/compiler-maintenance.test.mjs" 'previewEnabled = true'
assert_not_contains "$compiler_maintenance_workspace/Main.clasp" "loweredPreviewFlag"
assert_not_contains "$compiler_maintenance_workspace/Compiler/Lower.clasp" "CoreBool"

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
check_product_only_typescript_persistence_solution
check_product_only_clasp_workflow_correctness_solution
check_oracle_prompt_mode
check_persistence_prompt_modes
