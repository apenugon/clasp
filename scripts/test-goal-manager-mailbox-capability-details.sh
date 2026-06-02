#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
mkdir -p "$tmp_root"

test_root="$(mktemp -d "$tmp_root/test-goal-manager-mailbox-capability-details.XXXXXX")"
test_xdg_cache_home="${CLASP_TEST_SHARED_XDG_CACHE_HOME:-$tmp_root/clasp-test-xdg-cache}"
if [[ "${CLASP_TEST_ISOLATED_XDG_CACHE:-0}" == "1" ]]; then
  test_xdg_cache_home="$test_root/xdg-cache"
fi
mkdir -p "$test_xdg_cache_home"

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

XDG_CACHE_HOME="$test_xdg_cache_home" \
  "$claspc_bin" run "$project_root/examples/swarm-native/GoalManagerMailboxCapabilityHarness.clasp" \
  >"$output"

grep -F 'capability=local_verifier_gate:fail' "$output" >/dev/null
grep -F 'capability-evidence=local_verifier_gate:typed gate evidence reached mailbox' "$output" >/dev/null
grep -F 'capability-gap=local_verifier_gate:typed gate gap reached mailbox' "$output" >/dev/null
grep -F 'capability-closure=local_verifier_gate:typed gate closure reached mailbox' "$output" >/dev/null
grep -F 'capability=focused_verification_plan:partial' "$output" >/dev/null
grep -F 'capability-evidence=focused_verification_plan:focused-verification-plan-safe-direct:false' "$output" >/dev/null
grep -F 'capability-evidence=focused_verification_plan:focused-verification-launch-mode=managed-required' "$output" >/dev/null
grep -F 'capability-evidence=focused_verification_plan:focused-verification-launch-policy-mode:managed-required' "$output" >/dev/null
grep -F 'capability-evidence=focused_verification_plan:focused-verification-launch-policy-recommendation:focused-verification-launch:managed-required' "$output" >/dev/null
grep -F 'capability-gap=focused_verification_plan:focused verification plan requires managed launch' "$output" >/dev/null
grep -F 'capability-closure=focused_verification_plan:run through scripts/run-managed-job.sh before verifier launch' "$output" >/dev/null
grep -F 'capability=focused_verification_launch_policy:partial' "$output" >/dev/null
grep -F 'capability-evidence=focused_verification_launch_policy:focused-verification-launch-policy-mode:managed-required' "$output" >/dev/null
grep -F 'capability-gap=focused_verification_launch_policy:focused verification launch policy requires managed launch' "$output" >/dev/null
grep -F 'capability-closure=focused_verification_launch_policy:run through scripts/run-managed-job.sh before focused verifier launch' "$output" >/dev/null

printf 'goal-manager-mailbox-capability-details-ok\n'
