#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_path="$project_root/benchmarks/results/backend/test-backend-benchmarks.json"

rm -f "$output_path"

node "$project_root/benchmarks/run-backend-benchmarks.mjs" \
  --compile-samples 1 \
  --runtime-samples 1 \
  --runtime-iterations 25 \
  --warmup-runs 0 \
  --compile-workloads compiler-parser \
  --runtime-workloads compiler-source-text,boundary-transport \
  --output "$output_path" >/dev/null

test -f "$output_path"
grep -Fq '"schemaVersion": 1' "$output_path"
grep -Fq '"workload": "compiler-parser"' "$output_path"
grep -Fq '"workload": "compiler-source-text"' "$output_path"
grep -Fq '"workload": "boundary-transport"' "$output_path"
grep -Fq '"nativeSpeedupVsJs"' "$output_path"
grep -Fq '"checksum"' "$output_path"

node --input-type=module <<'EOF' "$output_path"
import { readFileSync } from "node:fs";

const resultPath = process.argv[1];
const result = JSON.parse(readFileSync(resultPath, "utf8"));

if (result.compileBenchmarks.length !== 1) {
  throw new Error(`expected 1 compile benchmark, found ${result.compileBenchmarks.length}`);
}

if (result.runtimeBenchmarks.length !== 2) {
  throw new Error(`expected 2 runtime benchmarks, found ${result.runtimeBenchmarks.length}`);
}

for (const benchmark of [...result.compileBenchmarks, ...result.runtimeBenchmarks]) {
  if (benchmark.jsBun.samplesMs.length !== 1 || benchmark.native.samplesMs.length !== 1) {
    throw new Error(`expected one sample per backend for ${benchmark.workload}`);
  }

  if (typeof benchmark.nativeSpeedupVsJs !== "number") {
    throw new Error(`expected numeric nativeSpeedupVsJs for ${benchmark.workload}`);
  }
}
EOF
