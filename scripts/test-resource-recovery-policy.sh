#!/usr/bin/env bash
set -euo pipefail

ulimit -c 0 >/dev/null 2>&1 || true

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mode="${1:-${CLASP_RESOURCE_RECOVERY_POLICY_MODE:-static}}"
module_path="$project_root/examples/swarm-native/ResourceRecoveryPolicy.clasp"
harness_path="$project_root/examples/swarm-native/ResourceRecoveryPolicyHarness.clasp"
test_root=""

usage() {
  cat <<'EOF'
usage: scripts/test-resource-recovery-policy.sh [static|full]

static  Validate the resource recovery policy contract without invoking claspc.
full    Run the ordinary Clasp resource recovery policy harness through claspc.
EOF
}

case "$mode" in
  --help|-h)
    usage
    exit 0
    ;;
  static|smoke)
    node - "$module_path" "$harness_path" "$0" <<'NODE'
const fs = require("node:fs");

const [modulePath, harnessPath, testPath] = process.argv.slice(2);
const source = fs.readFileSync(modulePath, "utf8");
const harness = fs.readFileSync(harnessPath, "utf8");
const testSource = fs.readFileSync(testPath, "utf8");

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

for (const marker of [
  "record ResourceRecoveryDecision =",
  "resourceRecoveryMessageIsMemoryPressure : Str -> Bool",
  "resourceRecoveryMessageIsOomKill : Str -> Bool",
  "resourceRecoveryMessageHasMemoryAdmission : Str -> Bool",
  "resourceRecoveryMessageIsAutonomousLaunchGateBlocker : Str -> Bool",
  "resourceRecoveryMessageUsesResourcePolicy : Str -> Bool",
  "resourceRecoveryEvidenceUsesResourcePolicy : Str -> Str -> Str -> Bool",
  "resourceRecoveryPressureKindForMessage : Str -> Str",
  "resourceRecoveryControlPlaneKindForMessage : Str -> Str",
  "resourceRecoveryDecisionForMessage : Str -> ResourceRecoveryDecision",
  "resourceRecoveryDecisionForEvidence : Str -> Str -> Str -> ResourceRecoveryDecision",
  "memory-admission: status=blocked",
  "memory-concurrency-admission: status=reduced",
  "memory-concurrency-admission: status=blocked",
  "reason=host-memory-reserve",
  "reason=projected-child-memory-reserve",
  "reason=external-agent-memory-reserve",
  "reason=configured-concurrency-exceeds-memory-capacity",
  "action=wait-for-memory-or-stop-only-managed-jobs-by-metadata",
  "action=lower-concurrency-or-child-memory-budget",
  "action=lower-concurrency-to-admitted-child-capacity",
  "action=wait-for-external-agent-pressure-or-lower-concurrency",
  "exit-status=137",
  "SIGKILL",
  "standalone-swarm-autonomous-launch-gate-repair",
  "autonomous-launch-gate",
  "manager-replan-blocker=autonomous-launch-gate",
  "GeneratedStateCleanupPlan and generated-state-cleanup-*",
  "cleanupCanSatisfyReserve or cleanupCanSatisfyGuard",
  "pressureKind = \"retry\"",
]) {
  assert(source.includes(marker), `missing source marker: ${marker}`);
}

for (const marker of [
  "boolText : Bool -> Str",
  "checkBool : Str -> Bool -> Bool -> Str",
  "resourceRecoveryDecisionForMessage memoryAdmissionMessage",
  "resourceRecoveryDecisionForMessage concurrencyAdmissionMessage",
  "resourceRecoveryDecisionForMessage oomKilledMessage",
  "resourceRecoveryDecisionForEvidence \"child-loop\" \"retrying\" oomKilledMessage",
  "resourceRecoveryDecisionForEvidence \"child-loop\" \"retrying\" ordinaryRetryEvidence",
  "resourceRecoveryDecisionForEvidence \"autonomous-launch-gate\" \"autonomous-launch-gate-blocker\" autonomousGateBlockerMessage",
  "memory-decision-task",
  "memory-decision-resource-policy",
  "memory-decision-memory-admission",
  "external-decision-guidance",
  "concurrency-decision-guidance",
  "admission-action-decision-control-plane-kind",
  "oom-kill-decision-resource-policy",
  "oom-kill-evidence-decision-task",
  "ordinary-retry-decision-task",
  "ordinary-retry-decision-retry-review",
  "autonomous-gate-decision-task",
  "autonomous-gate-decision-pressure-kind",
  "autonomous-gate-decision-retry-review",
  "admission-evidence-decision-task",
]) {
  assert(harness.includes(marker), `missing harness marker: ${marker}`);
}

for (const marker of [
  "CLASP_RESOURCE_RECOVERY_POLICY_MODE:-static",
  "static  Validate the resource recovery policy contract without invoking claspc.",
  "full    Run the ordinary Clasp resource recovery policy harness through claspc.",
]) {
  assert(testSource.includes(marker), `missing test marker: ${marker}`);
}

process.stdout.write("resource-recovery-policy-static-ok\n");
NODE
    exit 0
    ;;
  full)
    ;;
  *)
    printf 'test-resource-recovery-policy: unknown mode: %s\n' "$mode" >&2
    usage >&2
    exit 2
    ;;
esac

test_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}/clasp-resource-recovery-policy-test.$$"
jobs_root="$test_root/jobs"
wait_secs="${CLASP_RESOURCE_RECOVERY_POLICY_TEST_WAIT_SECS:-120}"
memory_mb="${CLASP_RESOURCE_RECOVERY_POLICY_TEST_MEMORY_MB:-2048}"
min_available_memory_mb="${CLASP_RESOURCE_RECOVERY_POLICY_TEST_MIN_AVAILABLE_MEMORY_MB:-32768}"
min_available_disk_mb="${CLASP_RESOURCE_RECOVERY_POLICY_TEST_MIN_AVAILABLE_DISK_MB:-8192}"
min_disk_headroom_mb="${CLASP_RESOURCE_RECOVERY_POLICY_TEST_MIN_DISK_HEADROOM_MB:-1024}"

cleanup() {
  if [[ -n "${test_root:-}" ]]; then
    rm -rf "$test_root"
  fi
}

trap cleanup EXIT

mkdir -p "$test_root"

claspc_bin="$(
  CLASP_CLASPC= CLASPC_BIN= CLASP_PROJECT_ROOT="$project_root" \
    CLASP_RESOLVE_CLASPC_BUILD_MEMORY_MB="${CLASP_RESOURCE_RECOVERY_POLICY_RESOLVE_MEMORY_MB:-4096}" \
    CLASP_RESOLVE_CLASPC_BUILD_MIN_AVAILABLE_MEMORY_MB="${CLASP_RESOURCE_RECOVERY_POLICY_RESOLVE_MIN_AVAILABLE_MEMORY_MB:-32768}" \
    CLASP_RESOLVE_CLASPC_BUILD_MIN_AVAILABLE_DISK_MB="${CLASP_RESOURCE_RECOVERY_POLICY_RESOLVE_MIN_AVAILABLE_DISK_MB:-16384}" \
    CLASP_RESOLVE_CLASPC_BUILD_MIN_DISK_HEADROOM_MB="${CLASP_RESOURCE_RECOVERY_POLICY_RESOLVE_MIN_DISK_HEADROOM_MB:-1024}" \
    "$project_root/scripts/resolve-claspc.sh"
)"

managed_args=(
  "$project_root/scripts/run-managed-job.sh"
  --jobs-root "$jobs_root"
  --memory-mb "$memory_mb"
  --min-available-memory-mb "$min_available_memory_mb"
  --min-available-disk-mb "$min_available_disk_mb"
  --min-disk-headroom-mb "$min_disk_headroom_mb"
  --disk-reserve-path "$project_root"
)

job_dir="$(
  CLASP_MANAGED_JOB_USE_SYSTEMD_SCOPE="${CLASP_RESOURCE_RECOVERY_POLICY_TEST_USE_SYSTEMD_SCOPE:-auto}" \
    "${managed_args[@]}" -- \
    timeout "$wait_secs" "$claspc_bin" run "$project_root/examples/swarm-native/ResourceRecoveryPolicyHarness.clasp"
)"

waited=0
while true; do
  status="$(sed -n '1p' "$job_dir/status" 2>/dev/null || printf 'missing')"
  case "$status" in
    completed|failed|stopped|memory-exceeded|disk-exceeded)
      break
      ;;
  esac
  if (( waited >= wait_secs )); then
    "$project_root/scripts/stop-managed-job.sh" --jobs-root "$jobs_root" "$job_dir" >/dev/null 2>&1 || true
    printf 'resource-recovery-policy managed job timed out after %s seconds: %s\n' "$wait_secs" "$job_dir" >&2
    exit 124
  fi
  sleep 1
  waited=$((waited + 1))
done

if [[ -f "$job_dir/stderr.log" && -s "$job_dir/stderr.log" ]]; then
  cat "$job_dir/stderr.log" >&2
fi
if [[ -f "$job_dir/memory-exceeded" ]]; then
  printf 'resource-recovery-policy managed job memory guard tripped:\n' >&2
  sed 's/^/  /' "$job_dir/memory-exceeded" >&2 || true
fi
if [[ -f "$job_dir/disk-exceeded" ]]; then
  printf 'resource-recovery-policy managed job disk guard tripped:\n' >&2
  sed 's/^/  /' "$job_dir/disk-exceeded" >&2 || true
fi

exit_status="$(sed -n '1p' "$job_dir/exit-status" 2>/dev/null || printf '1')"
if [[ "$exit_status" != "0" ]]; then
  printf 'resource-recovery-policy failed with status %s\n' "$exit_status" >&2
  sed -n '1,120p' "$job_dir/stdout.log" >&2 || true
  exit "$exit_status"
fi

if ! grep -F 'resource-recovery-policy-ok' "$job_dir/stdout.log" >/dev/null; then
  printf 'resource-recovery-policy harness did not report success\n' >&2
  sed -n '1,120p' "$job_dir/stdout.log" >&2 || true
  exit 1
fi

printf '%s\n' "resource-recovery-policy-ok"
