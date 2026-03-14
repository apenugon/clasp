#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workspace_root="$project_root/benchmarks/workspaces/persistence-check"

rm -rf "$workspace_root"
mkdir -p "$workspace_root"

task_id="ts-lead-persistence"
workspace="$workspace_root/$task_id"

node "$project_root/benchmarks/run-benchmark.mjs" prepare "$task_id" --workspace "$workspace" >/dev/null

cp "$project_root/examples/lead-app-ts/src/server/main.ts" "$workspace/src/server/main.ts"
cp "$project_root/examples/lead-app-ts/src/server/store.ts" "$workspace/src/server/store.ts"
cp "$project_root/examples/lead-app-ts/src/server/runtime-modules.d.ts" "$workspace/src/server/runtime-modules.d.ts"
cp "$project_root/examples/lead-app-ts/src/server/dev.ts" "$workspace/src/server/dev.ts"

node "$project_root/benchmarks/run-benchmark.mjs" verify \
  "$task_id" \
  --workspace "$workspace" \
  --harness scenario \
  --model deterministic >/dev/null

node "$project_root/benchmarks/run-benchmark.mjs" verify \
  "$task_id" \
  --workspace "$workspace" \
  --harness scenario \
  --model deterministic \
  --mode oracle >/dev/null
