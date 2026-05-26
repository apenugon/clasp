#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
mkdir -p "$tmp_root"
export TMPDIR="$tmp_root"
test_root="$(mktemp -d "$TMPDIR/test-swarm-ready-benchmark.XXXXXX")"

cleanup() {
  rm -rf "$test_root"
}

trap cleanup EXIT

claspc_bin="$(env -u CLASP_CLASPC -u CLASPC_BIN -u RUSTC "$project_root/scripts/resolve-claspc.sh")"
state_root="$test_root/readiness-state"
output_path="$test_root/readiness-benchmark.json"

env RUSTC=/definitely-missing-rustc \
  "$claspc_bin" --json check "$project_root/examples/swarm-native/SwarmReadyBenchmark.clasp" >/dev/null

env RUSTC=/definitely-missing-rustc \
  CLASP_MANAGER_PROJECT_ROOT="$project_root" \
  CLASP_MANAGER_BENCHMARK_WAVE=3 \
  CLASP_MANAGER_BENCHMARK_RUN_ID="fixture-run" \
  CLASP_MANAGER_BENCHMARK_STATE_ROOT="$state_root" \
  timeout 120 \
  "$claspc_bin" run "$project_root/examples/swarm-native/SwarmReadyBenchmark.clasp" \
  >"$output_path"

node - "$output_path" <<'EOF'
const fs = require("node:fs");

const signal = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

assert(signal.suite === "native-swarm-readiness", `suite ${signal.suite}`);
assert(signal.passed === true, `passed ${signal.passed}: ${signal.summary}`);
assert(signal.meetsTarget === true, `meetsTarget ${signal.meetsTarget}`);
assert(signal.scoreName === "nativeReadinessSignals", `scoreName ${signal.scoreName}`);
assert(signal.scoreValue === signal.targetValue, `score ${signal.scoreValue}/${signal.targetValue}`);
assert(signal.targetName === "requiredNativeReadinessSignals", `targetName ${signal.targetName}`);
assert(signal.scoreValue >= 10, `scoreValue ${signal.scoreValue}`);
assert(signal.summary.includes("native readiness passed wave 3 run fixture-run"), signal.summary);
assert(signal.summary.includes("verifier=passed"), signal.summary);
assert(signal.summary.includes("merge=pass"), signal.summary);
EOF

printf 'swarm-ready-benchmark-ok\n'
