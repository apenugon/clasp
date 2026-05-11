#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
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

claspc_bin="$("$project_root/scripts/resolve-claspc.sh")"

"$claspc_bin" run "$project_root/examples/swarm-native/MonitoredLoopHarness.clasp" -- "$test_root/state" \
  >"$output_path"

grep -F 'running=running:retryExhausted=false' "$output_path" >/dev/null
grep -F 'completed-pass=completed-pass:retryExhausted=false' "$output_path" >/dev/null
grep -F 'completed-fail=completed-fail:retryExhausted=false' "$output_path" >/dev/null
grep -F 'timeout=timeout:retryExhausted=false' "$output_path" >/dev/null
grep -F 'missing=missing-heartbeat:retryExhausted=false' "$output_path" >/dev/null
grep -F 'malformed=malformed-unresolved-heartbeat:retryExhausted=false' "$output_path" >/dev/null
grep -F 'unresolved=malformed-unresolved-heartbeat:retryExhausted=false' "$output_path" >/dev/null
grep -F 'retry-exhausted=retry-exhausted:retryExhausted=true' "$output_path" >/dev/null
grep -F 'completed-after-timeout=completed-pass:retryExhausted=false' "$output_path" >/dev/null
grep -F 'watch-pass=completed-pass:retryExhausted=false' "$output_path" >/dev/null
grep -F 'resume-existing=completed-pass:retryExhausted=false' "$output_path" >/dev/null
grep -F 'launch-or-resume-new=running:retryExhausted=false' "$output_path" >/dev/null

printf 'monitored-loop-ok\n'
