#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
mkdir -p "$tmp_root"

test_root="$(mktemp -d "$tmp_root/test-goal-manager-child-loop-monitor.XXXXXX")"
cleanup() {
  if [[ "${CLASP_KEEP_TEST_TMP:-}" != "1" ]]; then
    rm -rf "$test_root"
  else
    printf 'kept test root: %s\n' "$test_root" >&2
  fi
}
trap cleanup EXIT

claspc_bin="$("$project_root/scripts/resolve-claspc.sh")"
output="$test_root/output.txt"

XDG_CACHE_HOME="$test_root/xdg-cache" \
  CLASP_MANAGER_CHILD_AWAIT_TIMEOUT_MS_JSON='50' \
  CLASP_LOOP_WATCH_POLL_MS_JSON='10' \
  "$claspc_bin" run "$project_root/examples/swarm-native/GoalManagerChildLoopMonitorHarness.clasp" -- "$test_root/state" \
  >"$output"

grep -F 'missing-launch=missing-heartbeat' "$output" >/dev/null
grep -F 'malformed-launch=malformed-unresolved-heartbeat' "$output" >/dev/null
grep -F 'unresolved-launch=malformed-unresolved-heartbeat' "$output" >/dev/null
grep -F 'stale-live-running=true' "$output" >/dev/null
grep -F 'stale-live-completed=false' "$output" >/dev/null
grep -F 'stale-inner-completed-running=false' "$output" >/dev/null
grep -F 'stale-inner-completed-completed=true' "$output" >/dev/null
grep -F 'lease-spawn=running' "$output" >/dev/null
grep -F 'lease-await=timeout' "$output" >/dev/null
grep -F 'lease-heartbeat-seen=true' "$output" >/dev/null

printf 'goal-manager-child-loop-monitor-ok\n'
