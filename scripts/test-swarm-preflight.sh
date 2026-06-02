#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
mkdir -p "$tmp_root"
test_root="$(mktemp -d "$tmp_root/clasp-swarm-preflight.XXXXXX")"
external_pressure_pid=""

cleanup() {
  if [[ -n "${external_pressure_pid:-}" ]]; then
    kill "$external_pressure_pid" >/dev/null 2>&1 || true
    wait "$external_pressure_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$test_root"
}

trap cleanup EXIT

project_dir="$test_root/repo"
mkdir -p \
  "$project_dir/scripts" \
  "$project_dir/agents/swarm" \
  "$project_dir/agents/swarm/test-wave/01-foundation"

cp "$project_root/scripts/clasp-swarm-common.sh" "$project_dir/scripts/"
cp "$project_root/scripts/clasp-swarm-preflight.sh" "$project_dir/scripts/"
cp "$project_root/scripts/clasp-swarm-start.sh" "$project_dir/scripts/"
cp "$project_root/scripts/clasp-swarm-validate-task.mjs" "$project_dir/scripts/"
cp "$project_root/scripts/run-managed-job.sh" "$project_dir/scripts/"
cp "$project_root/scripts/stop-managed-job.sh" "$project_dir/scripts/"
cp "$project_root/agents/swarm/task.schema.json" "$project_dir/agents/swarm/task.schema.json"
chmod +x "$project_dir/scripts/"*.sh "$project_dir/scripts/clasp-swarm-validate-task.mjs"

cat > "$project_dir/.gitignore" <<'EOF'
/.clasp-swarm/
/.clasp-managed-job-admission.lock
EOF

cat > "$project_dir/agents/swarm/test-wave/01-foundation/PF-001-preflight.md" <<'EOF'
# PF-001 Preflight

## Goal

Prove preflight can select a ready lane.

## Why

Swarm launch admission should be checkable before starting workers.

## Scope

- Keep this fixture preflight-only

## Likely Files

- `scripts/clasp-swarm-preflight.sh`

## Batch

foundation

## Dependencies

- None

## Acceptance

- preflight admitted

## Verification

```sh
bash scripts/clasp-swarm-preflight.sh --batch foundation test-wave
```
EOF

git -C "$project_dir" init -q
git -C "$project_dir" checkout -q -b main
git -C "$project_dir" config user.email "clasp-test@example.invalid"
git -C "$project_dir" config user.name "Clasp Test"
git -C "$project_dir" add .
git -C "$project_dir" commit -q -m "initial preflight fixture"

cd "$project_dir"

text_output="$(
  CLASP_MANAGED_JOB_EXTERNAL_AGENT_RESERVE_MB=0 \
  CLASP_MANAGED_JOB_MEMORY_BUDGET_SCOPE=current-root \
  CLASP_SWARM_MAX_RUNNING_LANES=2 \
  CLASP_SWARM_LANE_MEMORY_MB=1 \
  CLASP_SWARM_MIN_AVAILABLE_MEMORY_MB=1 \
  CLASP_SWARM_MIN_AVAILABLE_DISK_MB=0 \
  CLASP_SWARM_MIN_DISK_HEADROOM_MB=0 \
    bash scripts/clasp-swarm-preflight.sh --batch foundation test-wave
)"
[[ "$text_output" == *"swarm-preflight=admitted reason=managed-preflight-passed"* ]]
[[ "$text_output" == *"selected_lane=01-foundation"* ]]
[[ "$text_output" == *"managed_preflight_job="* ]]
[[ -d .clasp-swarm/preflight-jobs ]]
[[ ! -e builder-events.log ]]

json_output="$(
  CLASP_MANAGED_JOB_EXTERNAL_AGENT_RESERVE_MB=0 \
  CLASP_MANAGED_JOB_MEMORY_BUDGET_SCOPE=current-root \
  CLASP_SWARM_MAX_RUNNING_LANES=2 \
  CLASP_SWARM_LANE_MEMORY_MB=1 \
  CLASP_SWARM_MIN_AVAILABLE_MEMORY_MB=1 \
  CLASP_SWARM_MIN_AVAILABLE_DISK_MB=0 \
  CLASP_SWARM_MIN_DISK_HEADROOM_MB=0 \
    bash scripts/clasp-swarm-preflight.sh --json --batch foundation test-wave
)"
node -e '
const report = JSON.parse(process.argv[1]);
if (report.status !== "admitted") throw new Error(`preflight should admit: ${JSON.stringify(report)}`);
if (report.reason !== "managed-preflight-passed") throw new Error(`preflight should use managed admission: ${JSON.stringify(report)}`);
if (report.selectedLane !== "01-foundation") throw new Error(`preflight should select the ready lane: ${JSON.stringify(report)}`);
if (!report.managedPreflight || report.managedPreflight.status !== "completed") {
  throw new Error(`preflight should report completed managed metadata: ${JSON.stringify(report)}`);
}
if (!report.resourcePressure || report.resourcePressure.kind !== "none") {
  throw new Error(`admitted preflight should report no resource pressure: ${JSON.stringify(report)}`);
}
if (!report.repositoryGate || report.repositoryGate.checked !== false) {
  throw new Error(`direct preflight should leave repository gate unchecked: ${JSON.stringify(report)}`);
}
' "$json_output"
[[ ! -e builder-events.log ]]

set +e
memory_block_json="$(
  CLASP_MANAGED_JOB_EXTERNAL_AGENT_RESERVE_MB=0 \
  CLASP_MANAGED_JOB_MEMORY_BUDGET_SCOPE=current-root \
  CLASP_SWARM_MAX_RUNNING_LANES=2 \
  CLASP_SWARM_LANE_MEMORY_MB=1 \
  CLASP_SWARM_MIN_AVAILABLE_MEMORY_MB=999999999 \
  CLASP_SWARM_MIN_AVAILABLE_DISK_MB=0 \
  CLASP_SWARM_MIN_DISK_HEADROOM_MB=0 \
    bash scripts/clasp-swarm-preflight.sh --json --batch foundation test-wave
)"
memory_block_status="$?"
set -e
[[ "$memory_block_status" == "75" ]]
node -e '
const report = JSON.parse(process.argv[1]);
if (report.status !== "blocked") throw new Error(`memory pressure should block: ${JSON.stringify(report)}`);
if (report.reason !== "managed-preflight-memory-exceeded") throw new Error(`expected memory-exceeded reason: ${JSON.stringify(report)}`);
if (!report.resourcePressure || report.resourcePressure.kind !== "memory") {
  throw new Error(`blocked preflight should report memory pressure: ${JSON.stringify(report)}`);
}
if (!(report.resourcePressure.shortfallMb > 0)) {
  throw new Error(`blocked preflight should report a positive shortfall: ${JSON.stringify(report)}`);
}
if (report.resourcePressure.recommendedAction !== "lower-concurrency-or-lane-memory-budget-before-launch") {
  throw new Error(`blocked preflight should report a memory-budget action: ${JSON.stringify(report)}`);
}
if (!report.resourcePressure.safeStopPolicy.includes("do-not-kill-unmanaged-agent-processes")) {
  throw new Error(`blocked preflight should include safe stop policy: ${JSON.stringify(report)}`);
}
if (!report.launchAdjustment || report.launchAdjustment.candidateProfile !== "bounded-low-memory") {
  throw new Error(`blocked preflight should report a launch adjustment candidate: ${JSON.stringify(report)}`);
}
if (report.launchAdjustment.candidateLaneMemoryMb !== 4096) {
  throw new Error(`candidate lane memory should use the default low-memory profile: ${JSON.stringify(report)}`);
}
if (report.launchAdjustment.candidateMinAvailableMemoryMb !== 32768) {
  throw new Error(`candidate memory reserve should use the default low-memory profile: ${JSON.stringify(report)}`);
}
if (!report.launchAdjustment.candidateAdmissible) {
  throw new Error(`low-memory candidate should be admissible in this fixture: ${JSON.stringify(report)}`);
}
if (!report.launchAdjustment.candidateEnv.includes("CLASP_SWARM_LANE_MEMORY_MB=4096")) {
  throw new Error(`candidate should include explicit launch env: ${JSON.stringify(report)}`);
}
' "$memory_block_json"
[[ ! -e builder-events.log ]]

sleep 30 &
external_pressure_pid="$!"
set +e
external_pressure_output="$(
  CLASP_MANAGED_JOB_EXTERNAL_AGENT_PROCESS_NAMES=sleep \
  CLASP_MANAGED_JOB_EXTERNAL_AGENT_RESERVE_MB=999999999 \
  CLASP_MANAGED_JOB_MEMORY_BUDGET_SCOPE=current-root \
  CLASP_SWARM_MAX_RUNNING_LANES=2 \
  CLASP_SWARM_LANE_MEMORY_MB=1 \
  CLASP_SWARM_MIN_AVAILABLE_MEMORY_MB=1 \
  CLASP_SWARM_MIN_AVAILABLE_DISK_MB=0 \
  CLASP_SWARM_MIN_DISK_HEADROOM_MB=0 \
    bash scripts/clasp-swarm-preflight.sh --batch foundation test-wave
)"
external_pressure_status="$?"
set -e
[[ "$external_pressure_status" == "75" ]]
[[ "$external_pressure_output" == *"managed_preflight_recovery:"* ]]
[[ "$external_pressure_output" == *"resource_pressure_kind=memory"* ]]
[[ "$external_pressure_output" == *"recommended_action=wait-for-external-agent-pressure-or-lower-concurrency-and-lane-memory-budget"* ]]
[[ "$external_pressure_output" == *"safe_stop_policy=stop-only-managed-jobs-by-metadata; do-not-kill-unmanaged-agent-processes"* ]]
[[ "$external_pressure_output" == *"external_agent_process_count="* ]]
[[ "$external_pressure_output" == *"external_agent_reserved_memory_mb="* ]]
[[ "$external_pressure_output" == *"launch_adjustment:"* ]]
[[ "$external_pressure_output" == *"candidate_profile=bounded-low-memory"* ]]
[[ "$external_pressure_output" == *"candidate_lane_memory_mb=4096"* ]]
[[ "$external_pressure_output" == *"candidate_min_available_memory_mb=32768"* ]]
[[ "$external_pressure_output" == *"candidate_admissible=false"* ]]
[[ "$external_pressure_output" == *"candidate_env=CLASP_SWARM_LANE_MEMORY_MB=4096 CLASP_SWARM_MIN_AVAILABLE_MEMORY_MB=32768"* ]]
kill "$external_pressure_pid" >/dev/null 2>&1 || true
wait "$external_pressure_pid" >/dev/null 2>&1 || true
external_pressure_pid=""
[[ ! -e builder-events.log ]]

start_text_output="$(
  CLASP_MANAGED_JOB_EXTERNAL_AGENT_RESERVE_MB=0 \
  CLASP_MANAGED_JOB_MEMORY_BUDGET_SCOPE=current-root \
  CLASP_SWARM_MAX_RUNNING_LANES=2 \
  CLASP_SWARM_LANE_MEMORY_MB=1 \
  CLASP_SWARM_MIN_AVAILABLE_MEMORY_MB=1 \
  CLASP_SWARM_MIN_AVAILABLE_DISK_MB=0 \
  CLASP_SWARM_MIN_DISK_HEADROOM_MB=0 \
    bash scripts/clasp-swarm-start.sh --preflight --batch foundation test-wave
)"
[[ "$start_text_output" == *"swarm-preflight=admitted reason=managed-preflight-passed"* ]]
[[ "$start_text_output" == *"selected_lane=01-foundation"* ]]
[[ "$start_text_output" == *"managed_preflight_job="* ]]
[[ "$start_text_output" == *"repository_gate:"* ]]
[[ "$start_text_output" == *"status=admitted"* ]]
[[ "$start_text_output" == *"reason=clean"* ]]
[[ ! -e builder-events.log ]]

start_json_output="$(
  CLASP_MANAGED_JOB_EXTERNAL_AGENT_RESERVE_MB=0 \
  CLASP_MANAGED_JOB_MEMORY_BUDGET_SCOPE=current-root \
  CLASP_SWARM_MAX_RUNNING_LANES=2 \
  CLASP_SWARM_LANE_MEMORY_MB=1 \
  CLASP_SWARM_MIN_AVAILABLE_MEMORY_MB=1 \
  CLASP_SWARM_MIN_AVAILABLE_DISK_MB=0 \
  CLASP_SWARM_MIN_DISK_HEADROOM_MB=0 \
    bash scripts/clasp-swarm-start.sh --preflight-json --batch foundation test-wave
)"
node -e '
const report = JSON.parse(process.argv[1]);
if (report.status !== "admitted") throw new Error(`start preflight should admit: ${JSON.stringify(report)}`);
if (report.reason !== "managed-preflight-passed") throw new Error(`start preflight should use managed admission: ${JSON.stringify(report)}`);
if (report.selectedLane !== "01-foundation") throw new Error(`start preflight should select the ready lane: ${JSON.stringify(report)}`);
if (!report.repositoryGate || report.repositoryGate.checked !== true) {
  throw new Error(`start preflight should check repository gate: ${JSON.stringify(report)}`);
}
if (report.repositoryGate.status !== "admitted" || report.repositoryGate.reason !== "clean") {
  throw new Error(`clean start preflight should admit repository gate: ${JSON.stringify(report)}`);
}
' "$start_json_output"
[[ ! -e builder-events.log ]]

profile_json_output="$(
  CLASP_MANAGED_JOB_EXTERNAL_AGENT_RESERVE_MB=0 \
  CLASP_MANAGED_JOB_MEMORY_BUDGET_SCOPE=current-root \
  CLASP_SWARM_MAX_RUNNING_LANES=2 \
  CLASP_SWARM_MIN_AVAILABLE_DISK_MB=0 \
  CLASP_SWARM_MIN_DISK_HEADROOM_MB=0 \
    bash scripts/clasp-swarm-start.sh --profile bounded-low-memory --preflight-json --batch foundation test-wave
)"
node -e '
const report = JSON.parse(process.argv[1]);
if (report.status !== "admitted") throw new Error(`profile start preflight should admit: ${JSON.stringify(report)}`);
if (report.laneMemoryMb !== 4096) throw new Error(`profile should set lane memory: ${JSON.stringify(report)}`);
if (report.minAvailableMemoryMb !== 32768) throw new Error(`profile should set memory reserve: ${JSON.stringify(report)}`);
if (!report.repositoryGate?.checked || report.repositoryGate.status !== "admitted") {
  throw new Error(`profile start preflight should include an admitted repository gate: ${JSON.stringify(report)}`);
}
' "$profile_json_output"
[[ ! -e builder-events.log ]]

printf 'dirty\n' > dirty.txt
set +e
dirty_repo_json="$(
  CLASP_MANAGED_JOB_EXTERNAL_AGENT_RESERVE_MB=0 \
  CLASP_MANAGED_JOB_MEMORY_BUDGET_SCOPE=current-root \
  CLASP_SWARM_MAX_RUNNING_LANES=2 \
  CLASP_SWARM_LANE_MEMORY_MB=1 \
  CLASP_SWARM_MIN_AVAILABLE_MEMORY_MB=1 \
  CLASP_SWARM_MIN_AVAILABLE_DISK_MB=0 \
  CLASP_SWARM_MIN_DISK_HEADROOM_MB=0 \
    bash scripts/clasp-swarm-start.sh --preflight-json --batch foundation test-wave
)"
dirty_repo_status="$?"
set -e
[[ "$dirty_repo_status" == "75" ]]
node -e '
const report = JSON.parse(process.argv[1]);
if (report.status !== "blocked") throw new Error(`dirty repository should block start preflight: ${JSON.stringify(report)}`);
if (report.reason !== "repository-dirty") throw new Error(`dirty repository should be the top-level reason: ${JSON.stringify(report)}`);
if (!report.repositoryGate?.checked || report.repositoryGate.status !== "blocked") {
  throw new Error(`dirty repository should report a blocked repository gate: ${JSON.stringify(report)}`);
}
if (report.repositoryGate.reason !== "dirty-repo") throw new Error(`dirty gate should report dirty-repo: ${JSON.stringify(report)}`);
if (!(report.repositoryGate.dirtyEntries > 0)) throw new Error(`dirty gate should count entries: ${JSON.stringify(report)}`);
if (report.repositoryGate.recommendedAction !== "commit-or-stash-before-launch") {
  throw new Error(`dirty gate should recommend commit or stash: ${JSON.stringify(report)}`);
}
' "$dirty_repo_json"

allow_dirty_json="$(
  CLASP_MANAGED_JOB_EXTERNAL_AGENT_RESERVE_MB=0 \
  CLASP_MANAGED_JOB_MEMORY_BUDGET_SCOPE=current-root \
  CLASP_SWARM_ALLOW_DIRTY=1 \
  CLASP_SWARM_MAX_RUNNING_LANES=2 \
  CLASP_SWARM_LANE_MEMORY_MB=1 \
  CLASP_SWARM_MIN_AVAILABLE_MEMORY_MB=1 \
  CLASP_SWARM_MIN_AVAILABLE_DISK_MB=0 \
  CLASP_SWARM_MIN_DISK_HEADROOM_MB=0 \
    bash scripts/clasp-swarm-start.sh --preflight-json --batch foundation test-wave
)"
node -e '
const report = JSON.parse(process.argv[1]);
if (report.status !== "admitted") throw new Error(`allow-dirty start preflight should admit resources: ${JSON.stringify(report)}`);
if (!report.repositoryGate?.allowDirty) throw new Error(`allow-dirty flag should be reported: ${JSON.stringify(report)}`);
if (report.repositoryGate.status !== "admitted" || report.repositoryGate.reason !== "dirty-allowed") {
  throw new Error(`allow-dirty repository gate should admit dirty worktree: ${JSON.stringify(report)}`);
}
' "$allow_dirty_json"
rm -f dirty.txt

git checkout -q -b feature/repo-gate
set +e
wrong_branch_json="$(
  CLASP_MANAGED_JOB_EXTERNAL_AGENT_RESERVE_MB=0 \
  CLASP_MANAGED_JOB_MEMORY_BUDGET_SCOPE=current-root \
  CLASP_SWARM_MAX_RUNNING_LANES=2 \
  CLASP_SWARM_LANE_MEMORY_MB=1 \
  CLASP_SWARM_MIN_AVAILABLE_MEMORY_MB=1 \
  CLASP_SWARM_MIN_AVAILABLE_DISK_MB=0 \
  CLASP_SWARM_MIN_DISK_HEADROOM_MB=0 \
    bash scripts/clasp-swarm-start.sh --preflight-json --batch foundation test-wave
)"
wrong_branch_status="$?"
set -e
[[ "$wrong_branch_status" == "75" ]]
node -e '
const report = JSON.parse(process.argv[1]);
if (report.status !== "blocked") throw new Error(`wrong branch should block start preflight: ${JSON.stringify(report)}`);
if (report.reason !== "repository-wrong-branch") throw new Error(`wrong branch should be top-level reason: ${JSON.stringify(report)}`);
if (report.repositoryGate?.reason !== "wrong-branch") throw new Error(`wrong branch gate reason missing: ${JSON.stringify(report)}`);
if (report.repositoryGate.currentBranch !== "feature/repo-gate") throw new Error(`wrong current branch: ${JSON.stringify(report)}`);
if (report.repositoryGate.requiredBranch !== "main") throw new Error(`wrong required branch: ${JSON.stringify(report)}`);
if (report.repositoryGate.recommendedAction !== "checkout-required-branch-before-launch") {
  throw new Error(`wrong branch should recommend checkout: ${JSON.stringify(report)}`);
}
' "$wrong_branch_json"
git checkout -q main

set +e
unknown_profile_output="$(
  bash scripts/clasp-swarm-start.sh --profile not-a-profile --preflight-json --batch foundation test-wave 2>&1
)"
unknown_profile_status="$?"
set -e
[[ "$unknown_profile_status" == "2" ]]
[[ "$unknown_profile_output" == *"unknown launch profile: not-a-profile"* ]]
[[ ! -e builder-events.log ]]

mkdir -p .clasp-swarm/test-wave/01-foundation
printf '%s\n' "$$" > .clasp-swarm/test-wave/01-foundation/pid
set +e
blocked_output="$(
  CLASP_SWARM_MAX_RUNNING_LANES=1 \
  CLASP_SWARM_LANE_MEMORY_MB=1 \
  CLASP_SWARM_MIN_AVAILABLE_MEMORY_MB=1 \
  CLASP_SWARM_MIN_AVAILABLE_DISK_MB=0 \
  CLASP_SWARM_MIN_DISK_HEADROOM_MB=0 \
    bash scripts/clasp-swarm-preflight.sh --batch foundation test-wave
)"
blocked_status="$?"
set -e
[[ "$blocked_status" == "75" ]]
[[ "$blocked_output" == *"swarm-preflight=blocked reason=max-running-lanes"* ]]
[[ ! -e builder-events.log ]]

printf 'swarm-preflight-ok\n'
