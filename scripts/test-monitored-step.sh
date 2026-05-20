#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
timeout_secs="${CLASP_MONITORED_STEP_TIMEOUT_SECS:-120}"

if ! [[ "$timeout_secs" =~ ^[0-9]+$ ]] || (( timeout_secs < 1 )); then
  printf 'CLASP_MONITORED_STEP_TIMEOUT_SECS must be a positive integer\n' >&2
  exit 1
fi

mkdir -p "$tmp_root"
test_root="$(mktemp -d "$tmp_root/test-monitored-step.XXXXXX")"
output_path="$test_root/output.json"
state_root="$test_root/state"
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
demo_path="$project_root/examples/feedback-loop/MonitoredStepDemo.clasp"

if grep -F '"bash"' "$demo_path" >/dev/null; then
  printf 'MonitoredStepDemo should exercise a direct executable, not a shell wrapper\n' >&2
  exit 1
fi

timeout "$timeout_secs" "$claspc_bin" --json check "$demo_path" | grep -F '"status":"ok"' >/dev/null
timeout "$timeout_secs" "$claspc_bin" run "$demo_path" -- "$state_root" >"$output_path"

grep -F '"status":"completed-fail"' "$output_path" >/dev/null
grep -F '"exitCode":3' "$output_path" >/dev/null
grep -F '"stdout":"monitored-step-out"' "$output_path" >/dev/null
grep -F '"stderr":"monitored-step-err"' "$output_path" >/dev/null
grep -F '"completed":true' "$output_path" >/dev/null
grep -F '"timedOut":false' "$output_path" >/dev/null
grep -F '"completed":true' "$state_root/step.heartbeat.json" >/dev/null
grep -F '"exitCode":3' "$state_root/step.heartbeat.json" >/dev/null
grep -Fx 'monitored-step-out' "$state_root/step.stdout.log" >/dev/null
grep -Fx 'monitored-step-err' "$state_root/step.stderr.log" >/dev/null

printf 'monitored-step-ok\n'
