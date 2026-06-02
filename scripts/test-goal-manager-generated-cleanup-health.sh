#!/usr/bin/env bash
set -euo pipefail

ulimit -c 0 >/dev/null 2>&1 || true

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mode="${1:-${CLASP_GOAL_MANAGER_GENERATED_CLEANUP_HEALTH_MODE:-static}}"
module_path="$project_root/examples/swarm-native/GoalManagerGeneratedCleanupHealth.clasp"
harness_path="$project_root/examples/swarm-native/GoalManagerGeneratedCleanupHealthHarness.clasp"

usage() {
  cat <<'EOF'
usage: scripts/test-goal-manager-generated-cleanup-health.sh [static|full]

static  Validate the small GoalManager generated cleanup-health contract without invoking claspc.
full    Check the ordinary Clasp generated cleanup-health harness through claspc.
EOF
}

case "$mode" in
  --help|-h)
    usage
    exit 0
    ;;
  static|smoke)
    node - "$module_path" "$harness_path" "$0" <<'EOF'
const fs = require("node:fs");

const [modulePath, harnessPath, testPath] = process.argv.slice(2);
const moduleSource = fs.readFileSync(modulePath, "utf8");
const harnessSource = fs.readFileSync(harnessPath, "utf8");
const testSource = fs.readFileSync(testPath, "utf8");

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function includes(source, text, label) {
  assert(source.includes(text), `${label} missing ${text}`);
}

for (const marker of [
  "CLASP_GOAL_MANAGER_GENERATED_CLEANUP_HEALTH_MODE:-static",
  "static  Validate the small GoalManager generated cleanup-health contract without invoking claspc.",
  "full    Check the ordinary Clasp generated cleanup-health harness through claspc.",
  "resolve-claspc.sh",
  "module-summary promoted hit module=GoalManagerGeneratedCleanupHealth",
  "module-summary promoted hit module=GoalManagerGeneratedCleanupHealthHarness",
  "goal-manager-generated-cleanup-health-ok",
]) {
  includes(testSource, marker, "test");
}

for (const marker of [
  "module GoalManagerGeneratedCleanupHealth",
  "import GoalManagerResourceContext",
  "import GeneratedStateCleanupPlan",
  "import HostResources",
  "managerGeneratedCleanupBoolText : Bool -> Str",
  "managerGeneratedCleanupDiskReserveResolvedPath : Str",
  "managerGeneratedCleanupAvailableDiskMbAt : Str -> Result Int",
  "managerGeneratedCleanupDiskHeadroomMbFromAvailable : Int -> Int",
  "managerGeneratedCleanupDiskReserveMetFromAvailable : Int -> Bool",
  "managerGeneratedCleanupDiskHeadroomMetFromAvailable : Int -> Bool",
  "managerGeneratedCleanupDiskPressureDetected : Bool",
  "managerGeneratedStateCleanupPlanEnabled : Bool",
  "CLASP_MANAGER_INCLUDE_GENERATED_CLEANUP_PLAN_JSON",
  "managerGeneratedStateCleanupPlan : GeneratedStateCleanupPlan",
  "generatedStateCleanupPlanFor managerProjectRoot",
  "managerGeneratedStateCleanupPlanSummaryFromPlan : GeneratedStateCleanupPlan -> Str",
  "managerGeneratedStateCleanupPlanSummary : Str",
  "GeneratedStateCleanupPlan:",
  "End GeneratedStateCleanupPlan.",
  "generated-state-cleanup-mode=plan-only",
  "generated-state-cleanup-action=",
  "generated-state-cleanup-safe-to-clean=",
  "generated-state-cleanup-repo-reclaimable-mb=",
  "generated-state-cleanup-external-log-reclaimable-mb=",
  "generated-state-cleanup-total-reclaimable-mb=",
  "generated-state-cleanup-projected-available-mb=",
  "generated-state-cleanup-guard-shortfall-after-cleanup-mb=",
  "generated-state-cleanup-can-satisfy-reserve=",
  "generated-state-cleanup-can-satisfy-guard=",
  "generated-state-cleanup-apply-requires=CLASP_GENERATED_STATE_APPLY_JSON=true",
]) {
  includes(moduleSource, marker, "module");
}

for (const marker of [
  "module GoalManagerGeneratedCleanupHealthHarness",
  "import GoalManagerGeneratedCleanupHealth",
  "record GoalManagerGeneratedCleanupHealthHarnessReport =",
  "enabled : Bool",
  "summary : Str",
  "action : Str",
  "safeToClean : Bool",
  "cleanupCanSatisfyReserve : Bool",
  "cleanupCanSatisfyGuard : Bool",
  "projectedAvailableMb : Int",
  "guardShortfallAfterCleanupMb : Int",
  "managerGeneratedStateCleanupPlanEnabled",
  "managerGeneratedStateCleanupPlanSummary",
  "plan.cleanup.cleanupCanSatisfyGuard",
]) {
  includes(harnessSource, marker, "harness");
}

process.stdout.write("goal-manager-generated-cleanup-health-static-ok\n");
EOF
    exit 0
    ;;
  full)
    ;;
  *)
    printf 'test-goal-manager-generated-cleanup-health: unknown mode: %s\n' "$mode" >&2
    usage >&2
    exit 2
    ;;
esac

tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
test_root="$(mktemp -d "$tmp_root/clasp-goal-manager-generated-cleanup-health.XXXXXX")"

cleanup() {
  if [[ "${CLASP_TEST_KEEP_TMP:-}" == "1" ]]; then
    printf 'kept test root: %s\n' "$test_root" >&2
  else
    rm -rf "$test_root" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

if ! claspc_bin="$(
  CLASP_CLASPC= CLASPC_BIN= CLASP_PROJECT_ROOT="$project_root" \
    CLASP_RESOLVE_CLASPC_BUILD_MEMORY_MB="${CLASP_GOAL_MANAGER_GENERATED_CLEANUP_HEALTH_RESOLVE_MEMORY_MB:-4096}" \
    CLASP_RESOLVE_CLASPC_BUILD_MIN_AVAILABLE_MEMORY_MB="${CLASP_GOAL_MANAGER_GENERATED_CLEANUP_HEALTH_RESOLVE_MIN_AVAILABLE_MEMORY_MB:-24576}" \
    CLASP_RESOLVE_CLASPC_BUILD_MIN_AVAILABLE_DISK_MB="${CLASP_GOAL_MANAGER_GENERATED_CLEANUP_HEALTH_RESOLVE_MIN_AVAILABLE_DISK_MB:-8192}" \
    CLASP_RESOLVE_CLASPC_BUILD_MIN_DISK_HEADROOM_MB="${CLASP_GOAL_MANAGER_GENERATED_CLEANUP_HEALTH_RESOLVE_MIN_DISK_HEADROOM_MB:-512}" \
    "$project_root/scripts/resolve-claspc.sh"
)"; then
  printf 'goal-manager-generated-cleanup-health failed to resolve claspc\n' >&2
  exit 1
fi

check_output_path="$test_root/check.json"
check_trace_path="$test_root/check.trace.log"
timeout_secs="${CLASP_GOAL_MANAGER_GENERATED_CLEANUP_HEALTH_TIMEOUT_SECS:-75}"
memory_mb="${CLASP_GOAL_MANAGER_GENERATED_CLEANUP_HEALTH_MEMORY_MB:-8192}"

(
  if (( memory_mb > 0 )); then
    ulimit -v "$((memory_mb * 1024))" >/dev/null 2>&1 || true
  fi
  XDG_CACHE_HOME="$test_root/cache" \
    CLASP_PROJECT_ROOT="$project_root" \
    CLASP_NATIVE_TRACE_CACHE=1 \
    CLASP_NATIVE_EXPORT_HOST_IDLE_TIMEOUT_SECS=1 \
    timeout "$timeout_secs" "$claspc_bin" --json check "$harness_path"
) >"$check_output_path" 2>"$check_trace_path"

node - "$check_output_path" "$check_trace_path" "$module_path" "$harness_path" <<'EOF'
const fs = require("node:fs");

const [checkOutputPath, checkTracePath, modulePath, harnessPath] = process.argv.slice(2);
const check = JSON.parse(fs.readFileSync(checkOutputPath, "utf8"));
const trace = fs.readFileSync(checkTracePath, "utf8");
const moduleSource = fs.readFileSync(modulePath, "utf8");
const harnessSource = fs.readFileSync(harnessPath, "utf8");

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

assert(check.status === "ok", `generated cleanup-health harness check failed: ${JSON.stringify(check)}`);
assert(typeof check.summary === "string" && check.summary.includes("main : Str"), "check summary should include harness main");
assert(check.summary.includes("managerGeneratedStateCleanupPlanSummary"), "check summary should include cleanup summary");
assert(check.summary.includes("managerGeneratedCleanupDiskPressureDetected"), "check summary should include disk pressure detection");
assert(moduleSource.includes("generated-state-cleanup-can-satisfy-guard="), "module should keep guard sufficiency evidence");
assert(harnessSource.includes("GoalManagerGeneratedCleanupHealthHarnessReport"), "harness should keep typed report shape");
for (const moduleName of [
  "GoalManagerResourceContext",
  "HostResources",
  "GeneratedStateCleanupPlan",
  "GoalManagerGeneratedCleanupHealth",
  "GoalManagerGeneratedCleanupHealthHarness",
]) {
  assert(
    trace.includes(`module-summary promoted hit module=${moduleName}`),
    `fresh cleanup-health check should use promoted module summary for ${moduleName}`,
  );
  assert(
    !trace.includes(`module-summary miss module=${moduleName}`),
    `fresh cleanup-health check should not cold-miss ${moduleName}`,
  );
}

process.stdout.write("goal-manager-generated-cleanup-health-ok\n");
EOF
