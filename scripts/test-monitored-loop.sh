#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
timeout_secs="${CLASP_MONITORED_LOOP_TIMEOUT_SECS:-240}"

if ! [[ "$timeout_secs" =~ ^[0-9]+$ ]] || (( timeout_secs < 1 )); then
  printf 'CLASP_MONITORED_LOOP_TIMEOUT_SECS must be a positive integer\n' >&2
  exit 1
fi

mkdir -p "$tmp_root"
test_root="$(mktemp -d "$tmp_root/test-monitored-loop.XXXXXX")"
output_path="$test_root/output.txt"
test_xdg_cache_home="${CLASP_TEST_SHARED_XDG_CACHE_HOME:-$tmp_root/clasp-test-xdg-cache}"
if [[ "${CLASP_TEST_ISOLATED_XDG_CACHE:-0}" == "1" ]]; then
  test_xdg_cache_home="$test_root/xdg-cache"
fi
mkdir -p "$test_xdg_cache_home"
export XDG_CACHE_HOME="$test_xdg_cache_home"

cleanup() {
  if [[ "${CLASP_TEST_KEEP_TMP:-}" == "1" ]]; then
    printf 'kept test root: %s\n' "$test_root" >&2
  else
    rm -rf "$test_root" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

claspc_bin="$(
  env -u CLASP_CLASPC -u CLASPC_BIN CLASP_PROJECT_ROOT="$project_root" \
    "$project_root/scripts/resolve-claspc.sh"
)"

timeout "$timeout_secs" "$claspc_bin" run "$project_root/examples/swarm-native/MonitoredLoopHarness.clasp" -- "$test_root/state" \
  >"$output_path"

grep -F 'running=running:retryExhausted=false' "$output_path" >/dev/null
grep -F 'completed-pass=completed-pass:retryExhausted=false' "$output_path" >/dev/null
grep -F 'completed-fail=completed-fail:retryExhausted=false' "$output_path" >/dev/null
grep -F 'timeout=timeout:retryExhausted=false' "$output_path" >/dev/null
grep -F 'missing=missing-heartbeat:retryExhausted=false' "$output_path" >/dev/null
grep -F 'malformed=malformed-unresolved-heartbeat:retryExhausted=false' "$output_path" >/dev/null
grep -F 'unresolved=malformed-unresolved-heartbeat:retryExhausted=false' "$output_path" >/dev/null
grep -F 'retry-exhausted=retry-exhausted:retryExhausted=true' "$output_path" >/dev/null
grep -F 'completed-after-timeout=timeout:retryExhausted=false' "$output_path" >/dev/null
grep -F 'watch-pass=completed-pass:retryExhausted=false' "$output_path" >/dev/null
grep -F 'resume-existing=completed-pass:retryExhausted=false' "$output_path" >/dev/null
grep -F 'launch-or-resume-new=running:retryExhausted=false' "$output_path" >/dev/null

node - "$test_root/state/running.heartbeat.json" <<'NODE'
const fs = require("node:fs");
const heartbeatPath = process.argv[2];
const heartbeat = JSON.parse(fs.readFileSync(heartbeatPath, "utf8"));

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

assert(heartbeat.status === "timeout", `unexpected persisted timeout status ${heartbeat.status}`);
assert(heartbeat.completed === true, "timeout heartbeat should be final");
assert(heartbeat.running === false, "timeout heartbeat should not remain running");
assert(heartbeat.timedOut === true, "timeout heartbeat should mark timedOut");
assert(heartbeat.exitCode === 124, `unexpected timeout exit ${heartbeat.exitCode}`);
assert(heartbeat.error === "timeout", `unexpected timeout error ${JSON.stringify(heartbeat.error)}`);
assert(Array.isArray(heartbeat.command) && heartbeat.command[0] === "bash", "heartbeat should persist the command");
assert(typeof heartbeat.startedAtMs === "number" && heartbeat.startedAtMs > 0, "heartbeat should persist start time");
assert(typeof heartbeat.endedAtMs === "number" && heartbeat.endedAtMs >= heartbeat.startedAtMs, "heartbeat should persist end time");
assert(typeof heartbeat.durationMs === "number" && heartbeat.durationMs >= 0, "heartbeat should persist duration");
NODE

printf 'monitored-loop-ok\n'
