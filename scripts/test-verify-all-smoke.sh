#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
mkdir -p "$tmp_root"
test_root="$(mktemp -d "$tmp_root/test-verify-all-smoke.XXXXXX")"

cleanup() {
  rm -rf "$test_root" >/dev/null 2>&1 || true
}
trap cleanup EXIT

report_path="$test_root/verify-fast-report.json"
parallel_marker="$test_root/parallel.txt"
sequential_marker="$test_root/sequential.txt"

grep -F 'bash scripts/test-verify-all-smoke.sh' "$project_root/scripts/verify-fast.sh" >/dev/null
grep -F 'bash scripts/test-managed-job.sh' "$project_root/scripts/verify-fast.sh" >/dev/null
grep -F 'verify_fast_should_resolve_claspc' "$project_root/scripts/verify-fast.sh" >/dev/null
grep -F 'caller_provided_verify_parallel_commands' "$project_root/scripts/verify-fast.sh" >/dev/null
if grep -F 'bash scripts/test-verify-all.sh' "$project_root/scripts/verify-fast.sh" >/dev/null 2>&1; then
  printf 'verify-fast should use test-verify-all-smoke, not exhaustive test-verify-all\n' >&2
  exit 1
fi
grep -F 'bash scripts/test-verify-all.sh' "$project_root/scripts/verify-all.sh" >/dev/null
grep -F 'bash scripts/test-managed-job.sh' "$project_root/scripts/verify-all.sh" >/dev/null
grep -F 'CLASP_VERIFY_MANAGED_MEMORY_MB' "$project_root/scripts/verify-all.sh" >/dev/null
grep -F 'CLASP_VERIFY_DIRECT_MEMORY_LIMIT_MB' "$project_root/scripts/verify-all.sh" >/dev/null
grep -F 'CLASP_VERIFY_MAX_PARALLEL_JOBS' "$project_root/scripts/verify-all.sh" >/dev/null
grep -F 'run-managed-job.sh' "$project_root/scripts/verify-all.sh" >/dev/null
grep -F 'apply_direct_memory_limit' "$project_root/scripts/verify-all.sh" >/dev/null
grep -F 'ulimit -v "$requested_kb"' "$project_root/scripts/verify-all.sh" >/dev/null

direct_limit_marker="$test_root/direct-limit.txt"
env \
  -u CLASP_VERIFY_IN_PROGRESS \
  -u CLASP_VERIFY_ACTIVE_ROOT \
  -u CLASP_VERIFY_LOCK_HELD \
  CLASP_VERIFY_LOCK_FILE="$test_root/direct-limit.lock" \
  CLASP_VERIFY_USE_CURRENT_SHELL=1 \
  CLASP_VERIFY_DIRECT_MEMORY_LIMIT_MB=512 \
  CLASP_VERIFY_PARALLEL_COMMANDS= \
  CLASP_VERIFY_SEQUENTIAL_COMMANDS="ulimit -v > '$direct_limit_marker'" \
  CLASP_VERIFY_FALLBACK_COMMANDS="printf fallback-smoke" \
  bash "$project_root/scripts/verify-fast.sh" >/dev/null

direct_limit_kb="$(tr -d '[:space:]' <"$direct_limit_marker")"
if ! [[ "$direct_limit_kb" =~ ^[0-9]+$ ]] || (( direct_limit_kb > 524288 )); then
  printf 'direct verifier should inherit a bounded memory limit, got %s\n' "$direct_limit_kb" >&2
  exit 1
fi

env \
  -u CLASP_VERIFY_IN_PROGRESS \
  -u CLASP_VERIFY_ACTIVE_ROOT \
  -u CLASP_VERIFY_LOCK_HELD \
  CLASP_VERIFY_LOCK_FILE="$test_root/verify-smoke.lock" \
  CLASP_VERIFY_USE_CURRENT_SHELL=1 \
  CLASP_VERIFY_PARALLEL_COMMANDS="printf parallel-smoke > '$parallel_marker'" \
  CLASP_VERIFY_SEQUENTIAL_COMMANDS="printf sequential-smoke > '$sequential_marker'" \
  CLASP_VERIFY_FALLBACK_COMMANDS="printf fallback-smoke" \
  CLASP_VERIFY_REPORT_JSON="$report_path" \
  bash "$project_root/scripts/verify-fast.sh" >/dev/null

grep -Fx 'parallel-smoke' "$parallel_marker" >/dev/null
grep -Fx 'sequential-smoke' "$sequential_marker" >/dev/null

node - "$report_path" <<'NODE'
const fs = require("fs");
const report = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}
assert(report.label === "verify-fast", `unexpected label: ${report.label}`);
assert(report.finalVerdict === "passed", `unexpected verdict: ${report.finalVerdict}`);
assert(report.mode === "normal", `unexpected mode: ${report.mode}`);
assert(report.commandCount === 2, `unexpected command count: ${report.commandCount}`);
const phases = report.commands.map((command) => command.phase).join(",");
assert(phases === "parallel,sequential", `unexpected phases: ${phases}`);
assert(report.commands[0].command.includes("parallel-smoke"), "missing parallel smoke command");
assert(report.commands[1].command.includes("sequential-smoke"), "missing sequential smoke command");
NODE

printf 'test-verify-all-smoke: ok\n'
