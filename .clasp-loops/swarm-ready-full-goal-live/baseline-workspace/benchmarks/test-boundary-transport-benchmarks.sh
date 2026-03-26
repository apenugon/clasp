#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_path="$project_root/benchmarks/results/backend/test-boundary-transport-benchmarks.json"

rm -f "$output_path"

node "$project_root/benchmarks/run-boundary-transport-benchmarks.mjs" \
  --samples 1 \
  --iterations 10 \
  --warmup-runs 0 \
  --output "$output_path" >/dev/null

test -f "$output_path"
grep -Fq '"schemaVersion": 1' "$output_path"
grep -Fq '"schemaType": "BoundaryTransportSample"' "$output_path"
grep -Fq '"jsonProjection"' "$output_path"
grep -Fq '"generatedBinaryProjection"' "$output_path"
grep -Fq '"binaryPayloadRatioVsJson"' "$output_path"
grep -Fq '"binarySpeedupVsJson"' "$output_path"

node --input-type=module <<'EOF' "$output_path"
import { readFileSync } from "node:fs";

const resultPath = process.argv[1];
const result = JSON.parse(readFileSync(resultPath, "utf8"));

if (result.jsonProjection.samplesMs.length !== 1) {
  throw new Error(`expected one JSON sample, found ${result.jsonProjection.samplesMs.length}`);
}

if (result.generatedBinaryProjection.samplesMs.length !== 1) {
  throw new Error(
    `expected one binary sample, found ${result.generatedBinaryProjection.samplesMs.length}`
  );
}

if (
  result.jsonProjection.roundTripChecksum !==
  result.generatedBinaryProjection.roundTripChecksum
) {
  throw new Error("expected JSON and binary projections to preserve the same round-trip checksum");
}

if (typeof result.binaryPayloadRatioVsJson !== "number") {
  throw new Error("expected numeric binaryPayloadRatioVsJson");
}

if (typeof result.binarySpeedupVsJson !== "number") {
  throw new Error("expected numeric binarySpeedupVsJson");
}
EOF
