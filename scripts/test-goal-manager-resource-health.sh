#!/usr/bin/env bash
set -euo pipefail

ulimit -c 0 >/dev/null 2>&1 || true

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mode="${1:-${CLASP_GOAL_MANAGER_RESOURCE_HEALTH_MODE:-static}}"
harness_path="$project_root/examples/swarm-native/GoalManagerResourceHealthHarness.clasp"
resource_health_path="$project_root/examples/swarm-native/GoalManagerResourceHealth.clasp"
test_root=""

usage() {
  cat <<'EOF'
usage: scripts/test-goal-manager-resource-health.sh [static|full]

static  Validate the GoalManager resource-health contract without invoking claspc.
full    Run the ordinary Clasp GoalManager resource-health harness through claspc.
EOF
}

case "$mode" in
  --help|-h)
    usage
    exit 0
    ;;
  static|smoke)
    node - "$harness_path" "$resource_health_path" "$0" <<'EOF'
const fs = require("node:fs");

const [harnessPath, resourceHealthPath, testPath] = process.argv.slice(2);
const harnessSource = fs.readFileSync(harnessPath, "utf8");
const resourceHealthSource = fs.readFileSync(resourceHealthPath, "utf8");
const testSource = fs.readFileSync(testPath, "utf8");

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function includes(source, text, label) {
  assert(source.includes(text), `${label} missing ${text}`);
}

for (const marker of [
  "CLASP_GOAL_MANAGER_RESOURCE_HEALTH_MODE:-static",
  "static  Validate the GoalManager resource-health contract without invoking claspc.",
  "full    Run the ordinary Clasp GoalManager resource-health harness through claspc.",
  "run_managed_capture",
  "resolve-claspc.sh",
  "goal-manager-resource-health-ok",
]) {
  includes(testSource, marker, "test");
}

for (const marker of [
  "reserveBlockError",
  "childBlockError",
  "projectedBlockError",
  "projectedAllowedError",
  "plannerBlockError",
  "benchmarkBlockError",
  "serviceBlockError",
  "upgradeBlockError",
  "workspaceMaterializationBlockError",
  "explicitExternalBlockMessage",
  "explicitPlannerExternalBlockMessage",
  "explicitBenchmarkExternalBlockMessage",
  "admittedAdmissionStatus",
  "externalBlockedAdmissionReason",
  "externalBlockedAdmissionSummary",
  "admittedConcurrencyStatus",
  "reducedConcurrencyReason",
  "reducedConcurrencyAction",
  "reducedConcurrencySummary",
  "memoryRecoveryTaskId",
  "diskRecoveryTaskId",
  "generatedCleanupPlanEnabled",
  "generatedCleanupPlanAction",
  "generatedCleanupPlanSafeToClean",
  "generatedCleanupPlanCanSatisfyReserve",
  "generatedCleanupPlanCanSatisfyGuard",
  "generatedCleanupPlanProjectedAvailableMb",
  "generatedCleanupPlanGuardShortfallAfterCleanupMb",
  "generatedCleanupPlanSummary",
  "managerResourceHealthLaunchSummary",
  "managerChildLaunchResourceError",
  "managerPlannerLaunchResourceError",
  "managerBenchmarkLaunchResourceError",
  "managerServiceLaunchResourceError",
  "managerUpgradeLaunchResourceError",
  "managerWorkspaceMaterializationResourceError",
  "autonomousGateMode",
  "autonomousGateReady",
  "autonomousGateMaySpawn",
  "autonomousGateMaySpawnRepair",
  "autonomousGateRecommendation",
  "autonomousGateRepairRecommendation",
  "autonomousGateWorktreeCheckpointPath",
  "autonomousGateWorktreeStatusFingerprint64Hex",
  "autonomousGateWorktreeCheckpointMatches",
  "autonomousGateRequestedChildAgents",
  "autonomousGateAdmittedChildCapacity",
  "autonomousGateFirstClosure",
  "autonomousGateSummary",
  "managerAutonomousLaunchGate.mode",
  "managerAutonomousLaunchGateSummary",
]) {
  includes(harnessSource, marker, "harness");
}

for (const marker of [
  "import AgentErgonomics",
  "import ResourceGuardPolicy",
  "import ResourceRecoveryPolicy",
  "import GoalManagerGeneratedCleanupHealth",
  "record ManagerWorktreeCheckpoint =",
  "managerGeneratedStateCleanupPlanSummary",
  "managerWorktreeCheckpointKind : Str",
  "clasp-manager-worktree-checkpoint",
  "managerWorktreeCheckpointPath : Str",
  "CLASP_MANAGER_WORKTREE_CHECKPOINT_PATH_JSON",
  "managerGitWorktreeStatusResult : Result Str",
  "managerGitWorktreeStatusFingerprint64Hex : Str",
  "managerReadWorktreeCheckpoint : Result ManagerWorktreeCheckpoint",
  "managerWorktreeCheckpointMatchesCurrentStatus : Bool",
  "managerGitWorktreeDirtyDefault : Bool -> Bool",
  "git\", \"status\", \"--porcelain\", \"--untracked-files=normal\"",
  "managerWorkspaceCheckpointReadyDefault : Bool",
  "managerWorktreeCheckpointMatchesCurrentStatus",
  "managerWorkspaceCheckpointReady : Bool",
  "CLASP_MANAGER_WORKSPACE_CHECKPOINT_READY_JSON",
  "managerDirtyWorktree : Bool",
  "CLASP_MANAGER_DIRTY_WORKTREE_JSON",
  "managerManagedLaunchReady : Bool",
  "CLASP_MANAGED_JOB_ID",
  "CLASP_MANAGER_ASSUME_MANAGED_LAUNCH_JSON",
  "managerAutonomousFocusedVerificationReady : Bool",
  "CLASP_MANAGER_AUTONOMOUS_FOCUSED_VERIFICATION_READY_JSON",
  "managerAutonomousFullVerificationRequested : Bool",
  "CLASP_MANAGER_AUTONOMOUS_FULL_VERIFICATION_REQUESTED_JSON",
  "managerAutonomousPromotionRequested : Bool",
  "CLASP_MANAGER_AUTONOMOUS_PROMOTION_REQUESTED_JSON",
  "managerAutonomousCompilerMutationRequested : Bool",
  "CLASP_MANAGER_AUTONOMOUS_COMPILER_MUTATION_REQUESTED_JSON",
  "managerAutonomousRequestedChildAgents : Int",
  "managerAutonomousBoundedTaskCount : Int",
  "managerAutonomousAdmittedChildCapacity : Int",
  "managerAutonomousResourceAdmissionOkForActiveChildren : Int -> Bool",
  "managerAutonomousLaunchGateInputForActiveChildren : Int -> AgentAutonomousLaunchGateInput",
  "managerAutonomousLaunchGateForActiveChildren : Int -> AgentAutonomousLaunchGate",
  "managerAutonomousLaunchGateRepairMaySpawnForActiveChildren : Int -> Bool",
  "managerAutonomousLaunchGateRepairRecommendationForActiveChildren : Int -> Str",
  "managerAutonomousLaunchGate : AgentAutonomousLaunchGate",
  "managerAutonomousLaunchGateJson : Str",
  "managerAutonomousLaunchGateSummary : Str",
  "Autonomous launch gate:",
  "Autonomous launch gate JSON:",
  "End autonomous launch gate JSON.",
  "autonomous-launch-gate-mode:",
  "autonomous-launch-gate-may-spawn-repair:",
  "autonomous-launch-gate-repair-recommendation:",
  "autonomous-launch-worktree-checkpoint-path:",
  "autonomous-launch-worktree-status-fingerprint64:",
  "autonomous-launch-worktree-checkpoint-matches:",
  "autonomous-launch-gate-recommendation:",
  "managerMemoryAdmissionDecisionWithExternalStatsForActiveChildren",
  "managerMemoryConcurrencyDecisionWithExternalStats",
  "managerResourceHealthMemoryAdmissionSummaryFromDecision",
  "managerResourceHealthMemoryAdmissionSummary",
  "managerResourceHealthMemoryConcurrencySummaryFromDecision",
  "managerResourceHealthMemoryConcurrencySummary",
  "memory-admission: status=",
  "memory-concurrency-admission: status=",
  "capacityLimit=",
  "managerConfiguredMaxConcurrentChildren",
  "wait-for-external-agent-pressure-or-lower-concurrency",
  "memory external agent reserve unmet",
  "blocked planner launch",
  "blocked benchmark launch",
  "blocked workspace materialization",
  "managerScopedDiskLaunchResourceError \"service\"",
  "managerScopedDiskLaunchResourceError \"upgrade\"",
  "resource-guard:planner-launch-blocked",
  "resource-guard:benchmark-launch-blocked",
  "resource-guard:service-launch-blocked",
  "resource-guard:upgrade-launch-blocked",
  "resource-guard:workspace-materialization-blocked",
  "hostUnmanagedProcessCountByName managerExternalAgentProcessNames",
  "hostUnmanagedProcessRssMbByName managerExternalAgentProcessNames",
  "externalAgentRssMb",
  "managerExternalAgentPressure",
  "managerMemoryLaunchRequiredWithExternalStatsMbForActiveChildren",
  "resourceBlockRecoveryTaskId",
  "resourceRecoveryTaskIdForMessage message",
  "resourceBlockRecoveryKind",
  "resourceRecoveryKindForMessage message",
  "resourceBlockRecoveryGuidance",
  "resourceRecoveryGuidanceForMessage message",
  "resource-guard:child-launch-blocked",
]) {
  includes(resourceHealthSource, marker, "resource health");
}

process.stdout.write("goal-manager-resource-health-static-ok\n");
EOF
    exit 0
    ;;
  full)
    ;;
  *)
    printf 'test-goal-manager-resource-health: unknown mode: %s\n' "$mode" >&2
    usage >&2
    exit 2
    ;;
esac

test_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}/clasp-goal-manager-resource-health-test.$$"
managed_jobs_root="$test_root/jobs"

cleanup() {
  if [[ -n "${test_root:-}" ]]; then
    rm -rf "$test_root"
  fi
}

trap cleanup EXIT

mkdir -p "$test_root"

run_managed_capture() {
  local output_path="$1"
  shift
  local job_dir=""
  local status=""
  local exit_status="1"
  local wait_secs="${CLASP_GOAL_MANAGER_RESOURCE_HEALTH_TEST_WAIT_SECS:-120}"
  local waited=0
  local memory_mb="${CLASP_GOAL_MANAGER_RESOURCE_HEALTH_TEST_MEMORY_MB:-4096}"
  local min_available_memory_mb="${CLASP_GOAL_MANAGER_RESOURCE_HEALTH_TEST_MIN_AVAILABLE_MEMORY_MB:-8192}"
  local min_available_disk_mb="${CLASP_GOAL_MANAGER_RESOURCE_HEALTH_TEST_MIN_AVAILABLE_DISK_MB:-4096}"
  local min_disk_headroom_mb="${CLASP_GOAL_MANAGER_RESOURCE_HEALTH_TEST_MIN_DISK_HEADROOM_MB:-512}"
  local -a managed_args=("$project_root/scripts/run-managed-job.sh" --jobs-root "$managed_jobs_root")

  if (( memory_mb > 0 )); then
    managed_args+=(--memory-mb "$memory_mb")
  fi
  if (( min_available_memory_mb > 0 )); then
    managed_args+=(--min-available-memory-mb "$min_available_memory_mb")
  fi
  if (( min_available_disk_mb > 0 )); then
    managed_args+=(--min-available-disk-mb "$min_available_disk_mb" --disk-reserve-path "$project_root")
  fi
  if (( min_disk_headroom_mb > 0 )); then
    managed_args+=(--min-disk-headroom-mb "$min_disk_headroom_mb" --disk-reserve-path "$project_root")
  fi

  job_dir="$(
    CLASP_MANAGED_JOB_USE_SYSTEMD_SCOPE="${CLASP_GOAL_MANAGER_RESOURCE_HEALTH_TEST_USE_SYSTEMD_SCOPE:-auto}" \
      "${managed_args[@]}" -- "$@"
  )"

  while true; do
    status="$(sed -n '1p' "$job_dir/status" 2>/dev/null || printf 'missing')"
    case "$status" in
      completed|failed|stopped|memory-exceeded|disk-exceeded)
        break
        ;;
    esac
    if (( waited >= wait_secs )); then
      "$project_root/scripts/stop-managed-job.sh" --jobs-root "$managed_jobs_root" "$job_dir" >/dev/null 2>&1 || true
      printf 'goal-manager-resource-health managed job timed out after %s seconds: %s\n' "$wait_secs" "$job_dir" >&2
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done

  if [[ -f "$job_dir/stdout.log" ]]; then
    cp "$job_dir/stdout.log" "$output_path"
  else
    : >"$output_path"
  fi
  if [[ -f "$job_dir/stderr.log" && -s "$job_dir/stderr.log" ]]; then
    cat "$job_dir/stderr.log" >&2
  fi
  if [[ -f "$job_dir/memory-exceeded" ]]; then
    printf 'goal-manager-resource-health managed job memory guard tripped:\n' >&2
    sed 's/^/  /' "$job_dir/memory-exceeded" >&2 || true
  fi
  if [[ -f "$job_dir/disk-exceeded" ]]; then
    printf 'goal-manager-resource-health managed job disk guard tripped:\n' >&2
    sed 's/^/  /' "$job_dir/disk-exceeded" >&2 || true
  fi

  if [[ -f "$job_dir/exit-status" ]]; then
    exit_status="$(tr -d '[:space:]' <"$job_dir/exit-status")"
  elif [[ "$status" == "completed" ]]; then
    exit_status=0
  fi
  if ! [[ "$exit_status" =~ ^[0-9]+$ ]]; then
    exit_status=1
  fi
  return "$exit_status"
}

if ! claspc_bin="$(
  CLASP_CLASPC= CLASPC_BIN= CLASP_PROJECT_ROOT="$project_root" \
    CLASP_RESOLVE_CLASPC_BUILD_MEMORY_MB="${CLASP_GOAL_MANAGER_RESOURCE_HEALTH_RESOLVE_MEMORY_MB:-4096}" \
    CLASP_RESOLVE_CLASPC_BUILD_MIN_AVAILABLE_MEMORY_MB="${CLASP_GOAL_MANAGER_RESOURCE_HEALTH_RESOLVE_MIN_AVAILABLE_MEMORY_MB:-32768}" \
    CLASP_RESOLVE_CLASPC_BUILD_MIN_AVAILABLE_DISK_MB="${CLASP_GOAL_MANAGER_RESOURCE_HEALTH_RESOLVE_MIN_AVAILABLE_DISK_MB:-16384}" \
    CLASP_RESOLVE_CLASPC_BUILD_MIN_DISK_HEADROOM_MB="${CLASP_GOAL_MANAGER_RESOURCE_HEALTH_RESOLVE_MIN_DISK_HEADROOM_MB:-1024}" \
    "$project_root/scripts/resolve-claspc.sh"
)"; then
  printf 'goal-manager-resource-health failed to resolve claspc\n' >&2
  exit 1
fi

check_output_path="$test_root/check.json"

run_managed_capture "$check_output_path" \
  timeout 90 "$claspc_bin" --json check "$harness_path"

node - "$check_output_path" "$harness_path" "$resource_health_path" <<'EOF'
const fs = require("node:fs");

const [checkOutputPath, harnessPath, resourceHealthPath] = process.argv.slice(2);
const check = JSON.parse(fs.readFileSync(checkOutputPath, "utf8"));
const harnessSource = fs.readFileSync(harnessPath, "utf8");
const resourceHealthSource = fs.readFileSync(resourceHealthPath, "utf8");

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function includes(source, text, label) {
  assert(source.includes(text), `${label} missing ${text}`);
}

assert(check.status === "ok", `resource health harness check failed: ${JSON.stringify(check)}`);
assert(typeof check.summary === "string" && check.summary.includes("main : Str"), "check summary should include harness main");
assert(check.summary.includes("managerChildLaunchResourceError"), "check summary should include child launch guard");
assert(check.summary.includes("managerPlannerLaunchResourceError"), "check summary should include planner launch guard");
assert(check.summary.includes("managerBenchmarkLaunchResourceError"), "check summary should include benchmark launch guard");
assert(check.summary.includes("managerServiceLaunchResourceError"), "check summary should include service launch guard");
assert(check.summary.includes("managerUpgradeLaunchResourceError"), "check summary should include upgrade launch guard");
assert(check.summary.includes("managerWorkspaceMaterializationResourceError"), "check summary should include workspace materialization guard");
assert(
  check.summary.includes("managerMemoryLaunchResourceErrorFromAvailableForActiveChildren"),
  "check summary should include projected memory launch guard",
);
assert(
  check.summary.includes("managerMemoryAdmissionDecisionWithExternalStatsForActiveChildren"),
  "check summary should include typed memory admission decision",
);
assert(
  check.summary.includes("managerResourceHealthMemoryAdmissionSummary"),
  "check summary should include planner-facing memory admission summary",
);
assert(
  check.summary.includes("managerGeneratedStateCleanupPlanSummary"),
  "check summary should include manager generated-state cleanup projection",
);
assert(
  check.summary.includes("managerPlannerMemoryLaunchResourceErrorFromAvailable"),
  "check summary should include planner memory launch guard",
);
assert(
  check.summary.includes("managerBenchmarkMemoryLaunchResourceErrorFromAvailable"),
  "check summary should include benchmark memory launch guard",
);
assert(
  check.summary.includes("managerServiceMemoryLaunchResourceErrorFromAvailable"),
  "check summary should include service memory launch guard",
);
assert(
  check.summary.includes("managerUpgradeMemoryLaunchResourceErrorFromAvailable"),
  "check summary should include upgrade memory launch guard",
);
assert(check.summary.includes("managerExternalAgentMemoryResourceGuardBlockMessage"), "check summary should include external agent guard");
assert(check.summary.includes("resourceBlockRecoveryTaskId"), "check summary should include recovery task routing");
assert(check.summary.includes("resourceBlockRecoveryKind"), "check summary should include recovery kind routing");

includes(harnessSource, "reserveBlockError", "harness");
includes(harnessSource, "childBlockError", "harness");
includes(harnessSource, "projectedBlockError", "harness");
includes(harnessSource, "projectedAllowedError", "harness");
includes(harnessSource, "plannerBlockError", "harness");
includes(harnessSource, "benchmarkBlockError", "harness");
includes(harnessSource, "serviceBlockError", "harness");
includes(harnessSource, "upgradeBlockError", "harness");
includes(harnessSource, "workspaceMaterializationBlockError", "harness");
includes(harnessSource, "explicitExternalBlockMessage", "harness");
includes(harnessSource, "explicitPlannerExternalBlockMessage", "harness");
includes(harnessSource, "explicitBenchmarkExternalBlockMessage", "harness");
includes(harnessSource, "admittedAdmissionStatus", "harness");
includes(harnessSource, "externalBlockedAdmissionReason", "harness");
includes(harnessSource, "externalBlockedAdmissionSummary", "harness");
includes(harnessSource, "memoryRecoveryTaskId", "harness");
includes(harnessSource, "diskRecoveryTaskId", "harness");
includes(harnessSource, "generatedCleanupPlanEnabled", "harness");
includes(harnessSource, "generatedCleanupPlanAction", "harness");
includes(harnessSource, "generatedCleanupPlanCanSatisfyGuard", "harness");
includes(harnessSource, "generatedCleanupPlanSummary", "harness");
includes(harnessSource, "managerResourceHealthLaunchSummary", "harness");
includes(harnessSource, "managerChildLaunchResourceError", "harness");
includes(harnessSource, "managerPlannerLaunchResourceError", "harness");
includes(harnessSource, "managerBenchmarkLaunchResourceError", "harness");
includes(harnessSource, "managerServiceLaunchResourceError", "harness");
includes(harnessSource, "managerUpgradeLaunchResourceError", "harness");
includes(harnessSource, "managerWorkspaceMaterializationResourceError", "harness");
includes(resourceHealthSource, "memory external agent reserve unmet", "resource health");
includes(resourceHealthSource, "blocked planner launch", "resource health");
includes(resourceHealthSource, "blocked benchmark launch", "resource health");
includes(resourceHealthSource, "blocked workspace materialization", "resource health");
includes(resourceHealthSource, 'managerScopedDiskLaunchResourceError "service"', "resource health");
includes(resourceHealthSource, 'managerScopedDiskLaunchResourceError "upgrade"', "resource health");
includes(resourceHealthSource, "resource-guard:planner-launch-blocked", "resource health");
includes(resourceHealthSource, "resource-guard:benchmark-launch-blocked", "resource health");
includes(resourceHealthSource, "resource-guard:service-launch-blocked", "resource health");
includes(resourceHealthSource, "resource-guard:upgrade-launch-blocked", "resource health");
includes(resourceHealthSource, "resource-guard:workspace-materialization-blocked", "resource health");
includes(resourceHealthSource, "hostUnmanagedProcessCountByName managerExternalAgentProcessNames", "resource health");
includes(resourceHealthSource, "hostUnmanagedProcessRssMbByName managerExternalAgentProcessNames", "resource health");
includes(resourceHealthSource, "externalAgentRssMb", "resource health");
includes(resourceHealthSource, "managerExternalAgentPressure", "resource health");
includes(resourceHealthSource, "managerMemoryLaunchRequiredWithExternalStatsMbForActiveChildren", "resource health");
includes(resourceHealthSource, "managerMemoryAdmissionDecisionWithExternalStatsForActiveChildren", "resource health");
includes(resourceHealthSource, "managerMemoryConcurrencyDecisionWithExternalStats", "resource health");
includes(resourceHealthSource, "managerResourceHealthMemoryAdmissionSummaryFromDecision", "resource health");
includes(resourceHealthSource, "managerResourceHealthMemoryConcurrencySummaryFromDecision", "resource health");
includes(resourceHealthSource, "memory-admission: status=", "resource health");
includes(resourceHealthSource, "memory-concurrency-admission: status=", "resource health");
includes(resourceHealthSource, "capacityLimit=", "resource health");
includes(resourceHealthSource, "wait-for-external-agent-pressure-or-lower-concurrency", "resource health");
includes(resourceHealthSource, "import ResourceRecoveryPolicy", "resource health");
includes(resourceHealthSource, "import GoalManagerGeneratedCleanupHealth", "resource health");
includes(resourceHealthSource, "managerGeneratedStateCleanupPlanSummary", "resource health");
includes(resourceHealthSource, "resourceBlockRecoveryTaskId", "resource health");
includes(resourceHealthSource, "resourceRecoveryTaskIdForMessage message", "resource health");
includes(resourceHealthSource, "resource-guard:child-launch-blocked", "resource health");
EOF

printf '%s\n' "goal-manager-resource-health-ok"
