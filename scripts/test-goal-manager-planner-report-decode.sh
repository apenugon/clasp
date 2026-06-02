#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
timeout_secs="${CLASP_GOAL_MANAGER_PLANNER_REPORT_DECODE_TIMEOUT_SECS:-700}"

if ! [[ "$timeout_secs" =~ ^[0-9]+$ ]] || (( timeout_secs < 1 )); then
  printf 'CLASP_GOAL_MANAGER_PLANNER_REPORT_DECODE_TIMEOUT_SECS must be a positive integer\n' >&2
  exit 1
fi

mkdir -p "$tmp_root"
export TMPDIR="$tmp_root"
test_root="$(mktemp -d "$TMPDIR/test-goal-manager-planner-report-decode.XXXXXX")"

cleanup() {
  rm -rf "$test_root"
}

trap cleanup EXIT

test_xdg_cache_home="${CLASP_TEST_SHARED_XDG_CACHE_HOME:-${XDG_CACHE_HOME:-$tmp_root/clasp-test-xdg-cache}}"
if [[ "${CLASP_TEST_ISOLATED_XDG_CACHE:-0}" == "1" ]]; then
  test_xdg_cache_home="$test_root/xdg-cache"
fi
mkdir -p "$test_xdg_cache_home"
export XDG_CACHE_HOME="$test_xdg_cache_home"

claspc_bin="$("$project_root/scripts/resolve-claspc.sh")"

grep -F 'trustedPlannerReportFromRaw : Str -> Result TrustedPlannerReport' \
  "$project_root/examples/swarm-native/GoalManagerPlannerIO.clasp" >/dev/null
grep -F 'import GoalManagerPlannerInputTypes' \
  "$project_root/examples/swarm-native/GoalManagerPlannerIO.clasp" >/dev/null
grep -F 'match tryDecode PlannerReport raw' \
  "$project_root/examples/swarm-native/GoalManagerPlannerIO.clasp" >/dev/null
grep -F 'plannerInputStateFromRaw : Str -> Result PlannerInputState' \
  "$project_root/examples/swarm-native/GoalManagerPlannerIO.clasp" >/dev/null
grep -F 'match tryDecode PlannerInputState raw' \
  "$project_root/examples/swarm-native/GoalManagerPlannerIO.clasp" >/dev/null
grep -F 'childLoopStateFromRaw : Str -> Result ChildLoopState' \
  "$project_root/examples/swarm-native/GoalManagerWatch.clasp" >/dev/null
grep -F 'match tryDecode ChildLoopState raw' \
  "$project_root/examples/swarm-native/GoalManagerWatch.clasp" >/dev/null
grep -F 'watchedProcessFromRaw : Str -> Result WatchedProcess' \
  "$project_root/examples/swarm-native/GoalManagerWatch.clasp" >/dev/null
grep -F 'match tryDecode WatchedProcess raw' \
  "$project_root/examples/swarm-native/GoalManagerWatch.clasp" >/dev/null
grep -F 'mailboxMessagesFromRaw : Str -> [SwarmMailboxMessage]' \
  "$project_root/examples/swarm-native/GoalManagerMailboxIO.clasp" >/dev/null
grep -F 'match tryDecode [SwarmMailboxMessage] raw' \
  "$project_root/examples/swarm-native/GoalManagerMailboxIO.clasp" >/dev/null
grep -F 'benchmarkCheckpointFromRaw : Str -> Result BenchmarkCheckpoint' \
  "$project_root/examples/swarm-native/GoalManagerBenchmarkCheckpoint.clasp" >/dev/null
grep -F 'match tryDecode BenchmarkCheckpoint raw' \
  "$project_root/examples/swarm-native/GoalManagerBenchmarkCheckpoint.clasp" >/dev/null
grep -F 'benchmarkSignalFromRaw : Str -> Result BenchmarkSignal' \
  "$project_root/examples/swarm-native/GoalManagerBenchmarkCommand.clasp" >/dev/null
grep -F 'match tryDecode BenchmarkSignal raw' \
  "$project_root/examples/swarm-native/GoalManagerBenchmarkCommand.clasp" >/dev/null
grep -F 'benchmarkCheckpointFromRaw : Str -> Result BenchmarkCheckpoint' \
  "$project_root/examples/swarm-native/GoalManagerRuntime.clasp" >/dev/null
grep -F 'match tryDecode BenchmarkCheckpoint raw' \
  "$project_root/examples/swarm-native/GoalManagerRuntime.clasp" >/dev/null
grep -F 'benchmarkHeartbeatProcess : Str -> Result WatchedProcess' \
  "$project_root/examples/swarm-native/GoalManagerRuntime.clasp" >/dev/null
grep -F 'match tryDecode WatchedProcess heartbeatRaw' \
  "$project_root/examples/swarm-native/GoalManagerRuntime.clasp" >/dev/null
if grep -F 'Ok (decode PlannerReport raw)' \
  "$project_root/examples/swarm-native/GoalManagerPlannerIO.clasp" >/dev/null; then
  printf 'GoalManagerPlannerIO still trusts raw planner reports through decode\n' >&2
  exit 1
fi
if grep -F 'Ok (plannerInputStateFromRaw raw)' \
  "$project_root/examples/swarm-native/GoalManagerPlannerIO.clasp" >/dev/null; then
  printf 'GoalManagerPlannerIO still lets planner input decode throw during read\n' >&2
  exit 1
fi
if grep -F 'Ok raw -> Ok (decode ChildLoopState raw)' \
  "$project_root/examples/swarm-native/GoalManagerWatch.clasp" >/dev/null; then
  printf 'GoalManagerWatch still trusts raw child loop state through decode\n' >&2
  exit 1
fi
if grep -F 'Ok raw -> Ok (decode WatchedProcess raw)' \
  "$project_root/examples/swarm-native/GoalManagerWatch.clasp" >/dev/null; then
  printf 'GoalManagerWatch still trusts raw watched process state through decode\n' >&2
  exit 1
fi
if grep -F 'Ok raw -> decode [SwarmMailboxMessage] raw' \
  "$project_root/examples/swarm-native/GoalManagerMailboxIO.clasp" >/dev/null; then
  printf 'GoalManagerMailboxIO still trusts raw mailbox state through decode\n' >&2
  exit 1
fi
if grep -F 'Ok raw -> Ok (decode BenchmarkCheckpoint raw)' \
  "$project_root/examples/swarm-native/GoalManagerBenchmarkCheckpoint.clasp" >/dev/null; then
  printf 'GoalManagerBenchmarkCheckpoint still trusts raw benchmark checkpoint state through decode\n' >&2
  exit 1
fi
if grep -F 'Ok raw -> Ok (decode BenchmarkCheckpoint raw)' \
  "$project_root/examples/swarm-native/GoalManagerRuntime.clasp" >/dev/null; then
  printf 'GoalManagerRuntime still trusts raw benchmark checkpoint state through decode\n' >&2
  exit 1
fi
if grep -F 'let process = decode WatchedProcess heartbeatRaw' \
  "$project_root/examples/swarm-native/GoalManagerRuntime.clasp" >/dev/null; then
  printf 'GoalManagerRuntime still trusts raw benchmark heartbeat state through decode\n' >&2
  exit 1
fi

output="$(timeout "$timeout_secs" "$claspc_bin" run "$project_root/examples/swarm-native/PlannerReportDecodeHarness.clasp")"

grep -F 'malformed-empty-tasks=err:planner report missing required fields' <<<"$output" >/dev/null
grep -F 'malformed-empty-tasks-trust=untrusted:false:unknown:planner report missing required fields' <<<"$output" >/dev/null
grep -F 'current-bad-tasks=err:planner report decode failed:' <<<"$output" >/dev/null
grep -F 'current-bad-tasks-trust=untrusted:false:unknown:planner report decode failed:' <<<"$output" >/dev/null
grep -F 'current-empty-tasks=ok:0:current empty' <<<"$output" >/dev/null
grep -F 'current-empty-tasks-trust=validated:true:current:' <<<"$output" >/dev/null
grep -F 'current-task=ok:1:current one' <<<"$output" >/dev/null
grep -F 'current-task-trust=validated:true:current:' <<<"$output" >/dev/null
grep -F 'legacy-task=ok:1:legacy one' <<<"$output" >/dev/null
grep -F 'legacy-task-trust=validated:true:legacy:' <<<"$output" >/dev/null
grep -F 'planner-input-current=ok:abc:mailbox' <<<"$output" >/dev/null
grep -F 'planner-input-legacy=ok:legacy:' <<<"$output" >/dev/null
grep -F 'planner-input-bad-current=err:planner input state decode failed:' <<<"$output" >/dev/null
grep -F 'planner-input-bad-legacy=err:legacy planner input state decode failed:' <<<"$output" >/dev/null
grep -F 'child-loop-state-current=ok:verifier:false' <<<"$output" >/dev/null
grep -F 'child-loop-state-bad=err:child loop state decode failed:' <<<"$output" >/dev/null
grep -F 'watched-process-current=ok:42:true' <<<"$output" >/dev/null
grep -F 'watched-process-bad=err:watched process decode failed:' <<<"$output" >/dev/null
grep -F 'mailbox-valid=ok:1' <<<"$output" >/dev/null
grep -F 'mailbox-bad=ok:0' <<<"$output" >/dev/null
grep -F 'benchmark-checkpoint-current=ok:checkpoint:true' <<<"$output" >/dev/null
grep -F 'benchmark-checkpoint-bad=err:benchmark checkpoint decode failed:' <<<"$output" >/dev/null
grep -F 'benchmark-signal-current=ok:signal:true' <<<"$output" >/dev/null
grep -F 'benchmark-signal-bad=err:benchmark signal decode failed:' <<<"$output" >/dev/null

printf 'goal-manager-planner-report-decode-ok\n'
