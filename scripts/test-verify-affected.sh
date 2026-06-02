#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
bash_bin="$(command -v bash)"
test_root=""

cleanup() {
  rm -rf "${test_root:-}"
}

trap cleanup EXIT

mkdir -p "$tmp_root"
test_root="$(mktemp -d "$tmp_root/verify-affected.XXXXXX")"
project_copy="$test_root/project"
managed_job_log="$test_root/managed-jobs.log"
mkdir -p "$project_copy/scripts" "$project_copy/src/scripts" "$project_copy/src/Compiler/Emit" \
  "$project_copy/runtime" "$project_copy/examples/swarm-native" "$project_copy/examples/feedback-loop" \
  "$project_copy/examples/safe-workspace" \
  "$project_copy/examples/safe-subprocess" \
  "$project_copy/examples/agent-loop-scenario/scripts" \
  "$project_copy/examples/agent-metadata/scripts" \
  "$project_copy/examples/agent-task-scenario/scripts" \
  "$project_copy/examples/lead-app/Shared" "$project_copy/examples/lead-app/scripts" \
  "$project_copy/examples/lead-app/benchmark-prep" \
  "$project_copy/docs" \
  "$project_copy/agents/feedback" \
  "$project_copy/benchmarks/checkpoints" \
  "$project_copy/benchmarks/tasks/clasp-lead-segment/repo/Shared" \
  "$project_copy/benchmarks/tasks/clasp-lead-segment/repo/scripts" \
  "$test_root/bin"

cp "$project_root/scripts/verify-affected.sh" "$project_copy/scripts/verify-affected.sh"
cp "$project_root/scripts/verify-affected.mjs" "$project_copy/scripts/verify-affected.mjs"
cp "$project_root/scripts/test-verify-all-smoke.sh" "$project_copy/scripts/test-verify-all-smoke.sh"
cp "$project_root/scripts/test-agent-backend-static.sh" "$project_copy/scripts/test-agent-backend-static.sh"
cp "$project_root/scripts/test-agent-ergonomics-helpers.sh" "$project_copy/scripts/test-agent-ergonomics-helpers.sh"
cp "$project_root/scripts/test-safe-workspace-static.sh" "$project_copy/scripts/test-safe-workspace-static.sh"
cp "$project_root/scripts/test-generated-state-cleanup-plan-static.sh" "$project_copy/scripts/test-generated-state-cleanup-plan-static.sh"
grep -F 'CLASP_VERIFY_AFFECTED_MANAGED' "$project_copy/scripts/verify-affected.sh" >/dev/null
grep -F 'CLASP_VERIFY_AFFECTED_DIRECT_MEMORY_LIMIT_MB' "$project_copy/scripts/verify-affected.sh" >/dev/null
grep -F 'apply_affected_direct_memory_limit' "$project_copy/scripts/verify-affected.sh" >/dev/null
grep -F 'ulimit -v "$requested_kb"' "$project_copy/scripts/verify-affected.sh" >/dev/null
grep -F 'CLASP_VERIFY_AFFECTED_DIRECT_HOST_RESERVE' "$project_copy/scripts/verify-affected.sh" >/dev/null
grep -F 'preflight_affected_direct_host_resources' "$project_copy/scripts/verify-affected.sh" >/dev/null
grep -F 'direct affected verification memory guard tripped' "$project_copy/scripts/verify-affected.sh" >/dev/null
grep -F 'direct affected verification disk guard tripped' "$project_copy/scripts/verify-affected.sh" >/dev/null
grep -F 'run-managed-job.sh' "$project_copy/scripts/verify-affected.sh" >/dev/null
grep -F '"$arg" == "--plan-only"' "$project_copy/scripts/verify-affected.sh" >/dev/null
cp "$project_root/scripts/clasp-swarm-validate-task.mjs" "$project_copy/scripts/clasp-swarm-validate-task.mjs"
cp "$project_root/scripts/clasp-swarm-preflight.sh" "$project_copy/scripts/clasp-swarm-preflight.sh"
cp "$project_root/scripts/test-task-manifest.sh" "$project_copy/scripts/test-task-manifest.sh"
cp "$project_root/scripts/test-swarm-control.sh" "$project_copy/scripts/test-swarm-control.sh"
cp "$project_root/scripts/test-swarm-preflight.sh" "$project_copy/scripts/test-swarm-preflight.sh"
cp "$project_root/scripts/test-standalone-swarm-surfaces.sh" "$project_copy/scripts/test-standalone-swarm-surfaces.sh"
cp "$project_root/scripts/standalone-swarm-readiness.sh" "$project_copy/scripts/standalone-swarm-readiness.sh"
cp "$project_root/scripts/standalone-swarm-verify.sh" "$project_copy/scripts/standalone-swarm-verify.sh"
cp "$project_root/scripts/test-local-source-edit-workspace.sh" "$project_copy/scripts/test-local-source-edit-workspace.sh"
cp "$project_root/scripts/test-local-agent-capability-closure.sh" "$project_copy/scripts/test-local-agent-capability-closure.sh"
cp "$project_root/scripts/clasp-network-egress-enforcer.mjs" "$project_copy/scripts/clasp-network-egress-enforcer.mjs"
cp "$project_root/scripts/clasp-network-egress-backend.mjs" "$project_copy/scripts/clasp-network-egress-backend.mjs"
cp "$project_root/scripts/clasp-network-egress-kernel-backend.mjs" "$project_copy/scripts/clasp-network-egress-kernel-backend.mjs"
cp "$project_root/scripts/clasp-network-egress-guard.c" "$project_copy/scripts/clasp-network-egress-guard.c"
cp "$project_root/scripts/clasp-filesystem-write-enforcer.mjs" "$project_copy/scripts/clasp-filesystem-write-enforcer.mjs"
cp "$project_root/scripts/clasp-filesystem-write-kernel-backend.mjs" "$project_copy/scripts/clasp-filesystem-write-kernel-backend.mjs"
cp "$project_root/scripts/clasp-filesystem-write-guard.c" "$project_copy/scripts/clasp-filesystem-write-guard.c"
cp "$project_root/scripts/test-swarm-destructive-policy.sh" "$project_copy/scripts/test-swarm-destructive-policy.sh"
cp "$project_root/scripts/test-swarm-filesystem-kernel-policy.sh" "$project_copy/scripts/test-swarm-filesystem-kernel-policy.sh"
cp "$project_root/scripts/benchmark-checkpoint.mjs" "$project_copy/scripts/benchmark-checkpoint.mjs"
cp "$project_root/scripts/test-benchmark-checkpoint.sh" "$project_copy/scripts/test-benchmark-checkpoint.sh"
cp "$project_root/benchmarks/run-benchmark.mjs" "$project_copy/benchmarks/run-benchmark.mjs"
cp "$project_root/benchmarks/test-benchmark-prep-cache.sh" "$project_copy/benchmarks/test-benchmark-prep-cache.sh"
cp "$project_root/scripts/generate-promoted-source-export-cache.mjs" "$project_copy/scripts/generate-promoted-source-export-cache.mjs"
cp "$project_root/scripts/test-promoted-source-export-cache.sh" "$project_copy/scripts/test-promoted-source-export-cache.sh"
cp "$project_root/scripts/generate-promoted-module-summary-cache.mjs" "$project_copy/scripts/generate-promoted-module-summary-cache.mjs"
cp "$project_root/scripts/test-promoted-module-summary-cache.sh" "$project_copy/scripts/test-promoted-module-summary-cache.sh"
cp "$project_root/scripts/test-native-claspc-diagnostics.sh" "$project_copy/scripts/test-native-claspc-diagnostics.sh"
cp "$project_root/scripts/native-incremental-guard.mjs" "$project_copy/scripts/native-incremental-guard.mjs"
cp "$project_root/scripts/test-native-incremental-guard.sh" "$project_copy/scripts/test-native-incremental-guard.sh"
cp "$project_root/scripts/test-int-builtins.sh" "$project_copy/scripts/test-int-builtins.sh"
cp "$project_root/scripts/test-dict-builtins.sh" "$project_copy/scripts/test-dict-builtins.sh"
cp "$project_root/scripts/test-try-decode.sh" "$project_copy/scripts/test-try-decode.sh"
cp "$project_root/scripts/test-service-decode.sh" "$project_copy/scripts/test-service-decode.sh"
cp "$project_root/scripts/test-record-update-parity.sh" "$project_copy/scripts/test-record-update-parity.sh"
cp "$project_root/scripts/verify-compiler-slice.sh" "$project_copy/scripts/verify-compiler-slice.sh"
cp "$project_root/scripts/test-verify-compiler-slice.sh" "$project_copy/scripts/test-verify-compiler-slice.sh"
cp "$project_root/scripts/verify-runtime-slice.sh" "$project_copy/scripts/verify-runtime-slice.sh"
cp "$project_root/scripts/test-verify-runtime-slice.sh" "$project_copy/scripts/test-verify-runtime-slice.sh"
cp "$project_root/scripts/test-js-emitter-determinism.sh" "$project_copy/scripts/test-js-emitter-determinism.sh"
cp "$project_root/scripts/test-goal-manager-fixture-manager.mjs" "$project_copy/scripts/test-goal-manager-fixture-manager.mjs"
cp "$project_root/scripts/test-goal-manager-resource-health.sh" "$project_copy/scripts/test-goal-manager-resource-health.sh"
cp "$project_root/scripts/test-goal-manager-generated-cleanup-health.sh" "$project_copy/scripts/test-goal-manager-generated-cleanup-health.sh"
cp "$project_root/scripts/test-goal-manager-mailbox-capability-details.sh" "$project_copy/scripts/test-goal-manager-mailbox-capability-details.sh"
cp "$project_root/src/StandaloneSwarmReadiness.clasp" "$project_copy/src/StandaloneSwarmReadiness.clasp"
cp "$project_root/src/StandaloneSwarmVerifier.clasp" "$project_copy/src/StandaloneSwarmVerifier.clasp"
cp "$project_root/examples/swarm-native/StandaloneSwarmHarness.clasp" "$project_copy/examples/swarm-native/StandaloneSwarmHarness.clasp"
cp "$project_root/examples/swarm-native/StandaloneSwarmRouting.clasp" "$project_copy/examples/swarm-native/StandaloneSwarmRouting.clasp"
cp "$project_root/examples/swarm-native/StandaloneSwarmClosureReport.clasp" "$project_copy/examples/swarm-native/StandaloneSwarmClosureReport.clasp"
cp "$project_root/examples/swarm-native/StandaloneSwarmClosureReportHarness.clasp" "$project_copy/examples/swarm-native/StandaloneSwarmClosureReportHarness.clasp"
cp "$project_root/docs/standalone-swarm-readiness.md" "$project_copy/docs/standalone-swarm-readiness.md"
cp "$project_root/runtime/standalone_swarm_probe.rs" "$project_copy/runtime/standalone_swarm_probe.rs"
touch "$project_copy/examples/safe-workspace/Main.clasp"
touch "$project_copy/examples/safe-workspace/Workspace.clasp"
touch "$project_copy/examples/safe-workspace/SafeWorkspaceHarness.clasp"
touch "$project_copy/examples/safe-subprocess/Main.clasp"
touch "$project_copy/examples/safe-subprocess/Process.clasp"
touch "$project_copy/examples/agent-loop-scenario/Main.clasp"
touch "$project_copy/examples/agent-loop-scenario/AgentRuntime.clasp"
touch "$project_copy/examples/agent-loop-scenario/Workspace.clasp"
touch "$project_copy/examples/agent-loop-scenario/Process.clasp"
touch "$project_copy/examples/agent-loop-scenario/scripts/verify.sh"
touch "$project_copy/examples/agent-metadata/Main.clasp"
touch "$project_copy/examples/agent-metadata/scripts/verify.sh"
touch "$project_copy/examples/lead-app/Shared/Lead.clasp"
touch "$project_copy/examples/lead-app/scripts/verify.sh"
touch "$project_copy/examples/agent-task-scenario/Main.clasp"
touch "$project_copy/examples/agent-task-scenario/scripts/verify.sh"
touch "$project_copy/examples/swarm-native/SwarmReadyBenchmark.clasp"
touch "$project_copy/examples/swarm-native/SwarmCapabilityAudit.clasp"
touch "$project_copy/examples/swarm-native/AgentErgonomics.clasp"
touch "$project_copy/examples/swarm-native/AgentErgonomicsHarness.clasp"
touch "$project_copy/examples/swarm-native/PolicyHarness.clasp"
touch "$project_copy/examples/swarm-native/CapabilityPolicyHarness.clasp"
touch "$project_copy/examples/swarm-native/DestructivePolicyHarness.clasp"
touch "$project_copy/examples/swarm-native/FilesystemKernelPolicyHarness.clasp"
touch "$project_copy/examples/swarm-native/PriorityHarness.clasp"
touch "$project_copy/examples/swarm-native/GeneratedStateCleanupPlan.clasp"
touch "$project_copy/examples/swarm-native/GoalManagerGeneratedCleanupHealth.clasp"
touch "$project_copy/examples/swarm-native/GoalManagerGeneratedCleanupHealthHarness.clasp"
touch "$project_copy/examples/swarm-native/LocalRouting.clasp"
touch "$project_copy/examples/swarm-native/LocalRoutingHarness.clasp"
touch "$project_copy/examples/swarm-native/LocalSourceEdit.clasp"
touch "$project_copy/examples/swarm-native/GoalManagerCapabilityMailbox.clasp"
touch "$project_copy/examples/swarm-native/GoalManagerPlannerInputFingerprint.clasp"
touch "$project_copy/examples/swarm-native/GoalManagerPlannerInputTypes.clasp"
touch "$project_copy/examples/swarm-native/GoalManagerPlannerInputState.clasp"
touch "$project_copy/examples/swarm-native/PlannerInputFingerprintHarness.clasp"
touch "$project_copy/examples/swarm-native/GoalManagerMailboxMessages.clasp"
touch "$project_copy/examples/swarm-native/GoalManagerMailboxCapabilityHarness.clasp"
touch "$project_copy/scripts/test-swarm-ready-benchmark.sh"
touch "$project_copy/scripts/test-swarm-capability-audit.sh"
touch "$project_copy/scripts/test-swarm-policy-helpers.sh"
touch "$project_copy/scripts/test-swarm-destructive-policy.sh"
touch "$project_copy/scripts/test-swarm-filesystem-kernel-policy.sh"
touch "$project_copy/scripts/test-swarm-priority.sh"
touch "$project_copy/scripts/test-swarm-native-feedback-loop.sh"
touch "$project_copy/benchmarks/tasks/clasp-lead-segment/repo/Shared/Lead.clasp"
touch "$project_copy/benchmarks/tasks/clasp-lead-segment/repo/scripts/verify.sh"
printf '{"taskId":"test","summary":"ok"}\n' > "$project_copy/agents/feedback/test-feedback.json"
printf '{"schemaVersion":1,"kind":"clasp-baseline-bottleneck-checkpoint","finalStatus":"ok"}\n' \
  > "$project_copy/benchmarks/checkpoints/2026-05-20-baseline-bottleneck.json"
cat > "$project_copy/benchmarks/tasks/clasp-lead-segment/task.json" <<'JSON'
{"id":"clasp-lead-segment","language":"clasp","repo":"repo","verify":["bash","scripts/verify.sh"]}
JSON
cat > "$project_copy/examples/lead-app/benchmark-prep/Main.context.json" <<'JSON'
{
  "format": "clasp-context-v1",
  "module": "Main",
  "sourceModules": [
    {
      "sourceId": "source:Main",
      "moduleId": "module:Main",
      "moduleName": "Main",
      "role": "entry",
      "sourceFingerprint": "0123456789abcdef"
    },
    {
      "sourceId": "source:Shared.Lead",
      "moduleId": "module:Shared.Lead",
      "moduleName": "Shared.Lead",
      "role": "import",
      "sourceFingerprint": "fedcba9876543210"
    }
  ],
  "surfaceIndex": {
    "routes": [
      {
        "id": "route:createLeadRecordRoute",
        "name": "createLeadRecordRoute",
        "requestSchemaId": "schema:LeadIntake",
        "responseSchemaId": "schema:LeadRecord",
        "handlerId": "decl:createLead",
        "affectedSurfaces": [
          "route:createLeadRecordRoute",
          "schema:LeadIntake",
          "schema:LeadRecord",
          "decl:createLead",
          "decl:summarizeLead",
          "foreign:storeLead",
          "foreign:mockLeadSummaryModel"
        ],
        "affectedForeignBoundaries": ["foreign:storeLead", "foreign:mockLeadSummaryModel"],
        "verificationGuidance": {
          "scenarioCommands": ["bash examples/lead-app/scripts/verify.sh"]
        }
      }
    ],
    "foreignBoundaries": [
      {"id": "foreign:storeLead", "name": "storeLead"},
      {"id": "foreign:mockLeadSummaryModel", "name": "mockLeadSummaryModel"}
    ]
  },
  "verificationGuidance": {
    "scenarioCommands": ["bash examples/lead-app/scripts/verify.sh"]
  }
}
JSON

cat > "$test_root/bin/bash" <<EOF
#!$bash_bin
set -euo pipefail
printf '%s\n' "\$*" >> "\${CLASP_TEST_FAKE_COMMAND_LOG:?}"
printf 'fake-bash:%s\n' "\$*"
EOF
chmod +x "$test_root/bin/bash"

printf '#!%s\n' "$bash_bin" > "$project_copy/scripts/run-managed-job.sh"
cat >> "$project_copy/scripts/run-managed-job.sh" <<'EOF'
set -euo pipefail

jobs_root=".clasp-verify/jobs"
memory_mb=""
min_available_memory_mb=""
min_available_disk_mb=""
min_disk_headroom_mb=""
disk_reserve_path=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --jobs-root)
      jobs_root="${2:-}"
      shift 2
      ;;
    --memory-mb)
      memory_mb="${2:-}"
      shift 2
      ;;
    --min-available-memory-mb)
      min_available_memory_mb="${2:-}"
      shift 2
      ;;
    --min-available-disk-mb)
      min_available_disk_mb="${2:-}"
      shift 2
      ;;
    --min-disk-headroom-mb)
      min_disk_headroom_mb="${2:-}"
      shift 2
      ;;
    --disk-reserve-path)
      disk_reserve_path="${2:-}"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *)
      printf 'fake-managed-job: unexpected argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

mkdir -p "$jobs_root"
job_dir="$(mktemp -d "$jobs_root/affected.XXXXXX")"
printf 'started\n' >"$job_dir/status"
printf '%s\n' "$memory_mb" >"$job_dir/memory-mb"
printf '%s\n' "$min_available_memory_mb" >"$job_dir/min-available-memory-mb"
printf '%s\n' "$min_available_disk_mb" >"$job_dir/min-available-disk-mb"
printf '%s\n' "$min_disk_headroom_mb" >"$job_dir/min-disk-headroom-mb"
printf '%s\n' "$disk_reserve_path" >"$job_dir/disk-reserve-path"
if [[ -n "${CLASP_TEST_MANAGED_JOB_LOG:-}" ]]; then
  printf 'memory=%s min=%s disk=%s headroom=%s reserve=%s command=%s\n' "$memory_mb" "$min_available_memory_mb" "$min_available_disk_mb" "$min_disk_headroom_mb" "$disk_reserve_path" "$*" >>"$CLASP_TEST_MANAGED_JOB_LOG"
fi

set +e
"$@" >"$job_dir/stdout.log" 2>"$job_dir/stderr.log"
status="$?"
set -e

printf '%s\n' "$status" >"$job_dir/exit-status"
if [[ "$status" == "0" ]]; then
  printf 'completed\n' >"$job_dir/status"
else
  printf 'failed\n' >"$job_dir/status"
fi
printf '%s\n' "$job_dir"
exit 0
EOF
chmod +x "$project_copy/scripts/run-managed-job.sh"

run_verify_affected() {
  (
    cd "$project_copy"
    env \
      CLASP_VERIFY_AFFECTED_MANAGED=0 \
      CLASP_VERIFY_AFFECTED_DIRECT_HOST_RESERVE="${CLASP_VERIFY_AFFECTED_DIRECT_HOST_RESERVE:-0}" \
      CLASP_TEST_FAKE_COMMAND_LOG="${CLASP_TEST_FAKE_COMMAND_LOG:?}" \
      PATH="$test_root/bin:$PATH" \
      "$bash_bin" scripts/verify-affected.sh "$@"
  )
}

run_verify_affected_managed() {
  (
    cd "$project_copy"
    env \
      -u CLASP_MANAGED_JOB_ID \
      -u CLASP_MANAGED_JOB_ROOT \
      -u CLASP_MANAGED_JOB_TOKEN \
      -u CLASP_MANAGED_JOB_STOP_REQUEST \
      -u CLASP_MANAGED_JOB_MEMORY_MB \
      -u CLASP_MANAGED_JOB_MIN_AVAILABLE_MEMORY_MB \
      -u CLASP_MANAGED_JOB_MIN_AVAILABLE_DISK_MB \
      -u CLASP_MANAGED_JOB_DISK_RESERVE_PATH \
      -u CLASP_VERIFY_AFFECTED_MANAGED_REENTRY \
      -u CLASP_VERIFY_AFFECTED_LABEL \
      -u CLASP_VERIFY_AFFECTED_MEMORY_MB \
      -u CLASP_VERIFY_AFFECTED_MIN_AVAILABLE_MEMORY_MB \
      -u CLASP_VERIFY_AFFECTED_MIN_AVAILABLE_DISK_MB \
      -u CLASP_VERIFY_AFFECTED_MIN_DISK_HEADROOM_MB \
      -u CLASP_VERIFY_MANAGED \
      -u CLASP_VERIFY_MANAGED_MEMORY_MB \
      -u CLASP_VERIFY_MANAGED_MIN_AVAILABLE_MEMORY_MB \
      -u CLASP_VERIFY_MANAGED_MIN_AVAILABLE_DISK_MB \
      -u CLASP_VERIFY_MANAGED_MIN_DISK_HEADROOM_MB \
      CLASP_VERIFY_AFFECTED_MANAGED=auto \
      CLASP_VERIFY_AFFECTED_JOBS_ROOT="$test_root/clasp-verify-affected-jobs" \
      CLASP_TEST_MANAGED_JOB_LOG="$managed_job_log" \
      CLASP_TEST_FAKE_COMMAND_LOG="${CLASP_TEST_FAKE_COMMAND_LOG:?}" \
      PATH="$test_root/bin:$PATH" \
      "$bash_bin" scripts/verify-affected.sh "$@"
  )
}

affected_memory_guard_log="$test_root/affected-memory-guard.log"
affected_memory_guard_stdout="$test_root/affected-memory-guard.stdout"
affected_memory_guard_stderr="$test_root/affected-memory-guard.stderr"
rm -f "$affected_memory_guard_log" "$affected_memory_guard_stdout" "$affected_memory_guard_stderr"
set +e
CLASP_TEST_FAKE_COMMAND_LOG="$affected_memory_guard_log" \
CLASP_VERIFY_AFFECTED_DIRECT_HOST_RESERVE=1 \
CLASP_VERIFY_AFFECTED_MIN_AVAILABLE_MEMORY_MB=999999999 \
CLASP_VERIFY_AFFECTED_MIN_AVAILABLE_DISK_MB=0 \
CLASP_VERIFY_AFFECTED_MIN_DISK_HEADROOM_MB=0 \
  run_verify_affected --changed-file src/Main.clasp >"$affected_memory_guard_stdout" 2>"$affected_memory_guard_stderr"
affected_memory_guard_status="$?"
set -e
[[ "$affected_memory_guard_status" == "75" ]]
[[ ! -s "$affected_memory_guard_stdout" ]]
[[ ! -f "$affected_memory_guard_log" ]]
grep -F 'verify-affected: direct affected verification memory guard tripped:' "$affected_memory_guard_stderr" >/dev/null

affected_disk_guard_log="$test_root/affected-disk-guard.log"
affected_disk_guard_stdout="$test_root/affected-disk-guard.stdout"
affected_disk_guard_stderr="$test_root/affected-disk-guard.stderr"
rm -f "$affected_disk_guard_log" "$affected_disk_guard_stdout" "$affected_disk_guard_stderr"
set +e
CLASP_TEST_FAKE_COMMAND_LOG="$affected_disk_guard_log" \
CLASP_VERIFY_AFFECTED_DIRECT_HOST_RESERVE=1 \
CLASP_VERIFY_AFFECTED_MIN_AVAILABLE_MEMORY_MB=0 \
CLASP_VERIFY_AFFECTED_MIN_AVAILABLE_DISK_MB=999999999 \
CLASP_VERIFY_AFFECTED_MIN_DISK_HEADROOM_MB=0 \
  run_verify_affected --changed-file src/Main.clasp >"$affected_disk_guard_stdout" 2>"$affected_disk_guard_stderr"
affected_disk_guard_status="$?"
set -e
[[ "$affected_disk_guard_status" == "75" ]]
[[ ! -s "$affected_disk_guard_stdout" ]]
[[ ! -f "$affected_disk_guard_log" ]]
grep -F 'verify-affected: direct affected verification disk guard tripped:' "$affected_disk_guard_stderr" >/dev/null

assert_report() {
  local report_path="$1"
  local log_path="$2"
  local scenario="$3"

  node - "$report_path" "$log_path" "$scenario" <<'NODE'
const fs = require("node:fs");
const report = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const logPath = process.argv[3];
const scenario = process.argv[4];
const log = fs.existsSync(logPath) ? fs.readFileSync(logPath, "utf8").trim().split(/\n/).filter(Boolean) : [];

function assert(condition, message) {
  if (!condition) {
    console.error(`${scenario}: ${message}`);
    process.exit(1);
  }
}

function hasCommand(fragment) {
  return report.selectedCommands.some((command) => command.command.includes(fragment));
}

function findCommand(fragment) {
  return report.selectedCommands.find((command) => command.command.includes(fragment));
}

function logHas(fragment) {
  return log.some((line) => line.includes(fragment));
}

function logHasExact(commandLine) {
  return log.some((line) => line === commandLine);
}

const expectedVerdict = scenario.endsWith("-plan") ? "planned" : "passed";
assert(report.schemaVersion === 1, "schema version should be stable");
assert(report.finalVerdict === expectedVerdict, `expected ${expectedVerdict}, got ${report.finalVerdict}`);
assert(report.exitStatus === 0, "exit status should be zero");
assert(Array.isArray(report.commandRecords), "command records should be present");
assert(report.executedCommandCount === report.commandRecords.length, "executed command count should match records");
assert(report.commandResourceSummary && typeof report.commandResourceSummary === "object", "command resource summary should be present");
assert(report.commandResourceSummary.commandCount === report.selectedCommands.length, "resource summary command count should match selected commands");
assert(typeof report.commandResourceSummary.overallAdvice === "string" && report.commandResourceSummary.overallAdvice.length > 0, "resource summary should expose overall advice");
assert(typeof report.commandResourceSummary.requiresManagedGuard === "boolean", "resource summary should expose managed-guard requirement");
assert(Number.isInteger(report.commandResourceSummary.staticCommandCount), "resource summary should expose static command count");
assert(Number.isInteger(report.commandResourceSummary.focusedCommandCount), "resource summary should expose focused command count");
assert(Number.isInteger(report.commandResourceSummary.heavyCommandCount), "resource summary should expose heavy command count");
assert(Number.isInteger(report.commandResourceSummary.safeDirectCommandCount), "resource summary should expose safe-direct command count");
assert(Number.isInteger(report.commandResourceSummary.managedGuardCommandCount), "resource summary should expose managed-guard command count");
assert(Number.isInteger(report.commandResourceSummary.compilerStateFreeCommandCount), "resource summary should expose compiler-state-free command count");
assert(Number.isInteger(report.commandResourceSummary.compilerStateTouchingCommandCount), "resource summary should expose compiler-state-touching command count");
assert(typeof report.commandResourceSummary.canRunWithoutCompilerState === "boolean", "resource summary should expose compiler-state-free run decision");
assert(
  report.commandResourceSummary.safeDirectCommandCount + report.commandResourceSummary.managedGuardCommandCount === report.commandResourceSummary.commandCount,
  "resource summary direct/managed counts should cover selected commands",
);
assert(
  report.commandResourceSummary.compilerStateFreeCommandCount + report.commandResourceSummary.compilerStateTouchingCommandCount === report.commandResourceSummary.commandCount,
  "resource summary compiler-state counts should cover selected commands",
);
assert(
  report.commandResourceSummary.canRunWithoutCompilerState === (report.commandResourceSummary.compilerStateTouchingCommandCount === 0),
  "resource summary compiler-state-free decision should match touching command count",
);
assert(report.affectedVerificationLaunchPolicy && typeof report.affectedVerificationLaunchPolicy === "object", "affected verifier launch policy should be present");
assert(typeof report.affectedVerificationLaunchPolicy.valid === "boolean", "affected verifier launch policy should expose validity");
assert(typeof report.affectedVerificationLaunchPolicy.ready === "boolean", "affected verifier launch policy should expose readiness");
assert(typeof report.affectedVerificationLaunchPolicy.mode === "string" && report.affectedVerificationLaunchPolicy.mode.length > 0, "affected verifier launch policy should expose mode");
assert(typeof report.affectedVerificationLaunchPolicy.canRunDirect === "boolean", "affected verifier launch policy should expose direct-run decision");
assert(typeof report.affectedVerificationLaunchPolicy.canRunWithoutCompilerState === "boolean", "affected verifier launch policy should expose compiler-state-free decision");
assert(typeof report.affectedVerificationLaunchPolicy.requiresManagedGuard === "boolean", "affected verifier launch policy should expose managed-guard requirement");
assert(typeof report.affectedVerificationLaunchPolicy.recommendation === "string" && report.affectedVerificationLaunchPolicy.recommendation.length > 0, "affected verifier launch policy should expose recommendation");
assert(typeof report.affectedVerificationLaunchPolicy.verificationPlanRecommendation === "string" && report.affectedVerificationLaunchPolicy.verificationPlanRecommendation.length > 0, "affected verifier launch policy should expose plan recommendation");
assert(Array.isArray(report.affectedVerificationLaunchPolicy.blockingGaps), "affected verifier launch policy should expose blocking gaps");
assert(Array.isArray(report.affectedVerificationLaunchPolicy.requiredClosure), "affected verifier launch policy should expose required closure");
assert(Array.isArray(report.affectedVerificationLaunchPolicy.evidence), "affected verifier launch policy should expose evidence");
assert(
  report.affectedVerificationLaunchPolicy.canRunWithoutCompilerState === report.commandResourceSummary.canRunWithoutCompilerState,
  "affected verifier launch policy compiler-state decision should match resource summary",
);
assert(
  report.affectedVerificationLaunchPolicy.requiresManagedGuard === report.commandResourceSummary.requiresManagedGuard,
  "affected verifier launch policy managed-guard decision should match resource summary",
);
assert(
  report.affectedVerificationLaunchPolicy.evidence.some((item) => item === `affected-launch-mode=${report.affectedVerificationLaunchPolicy.mode}`),
  "affected verifier launch policy should include mode evidence",
);
for (const command of report.selectedCommands) {
  assert(typeof command.resourceClass === "string" && command.resourceClass.length > 0, "selected command should expose resource class");
  assert(typeof command.oomRisk === "string" && command.oomRisk.length > 0, "selected command should expose OOM risk");
  assert(typeof command.requiresManagedGuard === "boolean", "selected command should expose managed-guard requirement");
  assert(typeof command.executionAdvice === "string" && command.executionAdvice.length > 0, "selected command should expose execution advice");
  assert(typeof command.compilerStateAccess === "string" && command.compilerStateAccess.length > 0, "selected command should expose compiler-state access");
}
for (const record of report.commandRecords) {
  assert(Number.isInteger(record.elapsedMs) && record.elapsedMs >= 0, "command elapsedMs should be structural");
  assert(record.endedAtMs >= record.startedAtMs, "command timestamps should be ordered");
  assert(typeof record.resourceClass === "string" && record.resourceClass.length > 0, "command record should expose resource class");
  assert(typeof record.oomRisk === "string" && record.oomRisk.length > 0, "command record should expose OOM risk");
  assert(typeof record.requiresManagedGuard === "boolean", "command record should expose managed-guard requirement");
  assert(typeof record.executionAdvice === "string" && record.executionAdvice.length > 0, "command record should expose execution advice");
  assert(typeof record.compilerStateAccess === "string" && record.compilerStateAccess.length > 0, "command record should expose compiler-state access");
}

switch (scenario) {
  case "source-no-git":
    assert(report.usedGitFallback === false, "explicit source input should not use git fallback");
    assert(report.inputSources.some((source) => source.kind === "argv"), "argv source should be recorded");
    assert(report.changedFiles.includes("src/Compiler/Checker.clasp"), "source file should be normalized");
    assert(hasCommand("bash scripts/test-selfhost.sh"), "source route should run selfhost coverage");
    assert(findCommand("bash scripts/test-selfhost.sh").resourceClass === "heavy", "selfhost command should be classified as heavy");
    assert(findCommand("bash scripts/test-selfhost.sh").requiresManagedGuard === true, "selfhost command should require managed guard");
    assert(hasCommand("bash src/scripts/verify.sh"), "source route should run hosted source verification");
    assert(hasCommand("bash scripts/test-int-builtins.sh"), "source route should run focused integer builtin coverage");
    assert(hasCommand("bash scripts/test-dict-builtins.sh"), "source route should run focused dictionary builtin coverage");
    assert(hasCommand("bash scripts/test-try-decode.sh"), "source route should run focused tryDecode coverage for safe decode compiler changes");
    assert(hasCommand("bash scripts/verify-compiler-slice.sh --check-only checker"), "compiler implementation route should run cheaper check-only compiler slice coverage");
    assert(!report.selectedCommands.some((command) => command.command === "bash scripts/verify-compiler-slice.sh checker"), "compiler implementation route should not run duplicate compiler fixture execution");
    assert(!hasCommand("benchmarks/"), "source route should avoid broad benchmark commands");
    assert(report.commandResourceSummary.heavyCommandCount > 0, "source route should expose heavy command count");
    assert(report.commandResourceSummary.compilerStateTouchingCommandCount > 0, "source route should expose compiler-state-touching commands");
    assert(report.commandResourceSummary.canRunWithoutCompilerState === false, "source route should not be compiler-state-free");
    assert(report.commandResourceSummary.requiresManagedGuard === true, "source route should require managed execution");
    assert(report.commandResourceSummary.overallAdvice === "run-under-managed-job-with-memory-and-disk-admission", "source route should recommend managed memory/disk admission");
    assert(report.affectedVerificationLaunchPolicy.mode === "heavy-managed", `source route launch mode ${report.affectedVerificationLaunchPolicy.mode}`);
    assert(report.affectedVerificationLaunchPolicy.ready === false, "source route launch policy should not be ready");
    assert(report.affectedVerificationLaunchPolicy.canRunDirect === false, "source route launch policy should not allow direct run");
    assert(report.affectedVerificationLaunchPolicy.recommendation === "affected-verification-launch:managed-heavy-memory-disk", `source route launch recommendation ${report.affectedVerificationLaunchPolicy.recommendation}`);
    assert(report.affectedVerificationLaunchPolicy.requiredClosure.includes("affected-verification-plan:run-managed-memory-disk-admission"), "source route launch policy should require managed memory/disk closure");
    assert(report.usedVerifyFastFallback === false, "known source input should not use verify-fast fallback");
    assert(logHas("scripts/test-selfhost.sh"), "fake selfhost command should execute");
    assert(logHas("src/scripts/verify.sh"), "fake source verify command should execute");
    assert(logHas("scripts/test-int-builtins.sh"), "fake integer builtin command should execute");
    assert(logHas("scripts/test-dict-builtins.sh"), "fake dictionary builtin command should execute");
    assert(logHas("scripts/test-try-decode.sh"), "fake tryDecode command should execute");
    assert(logHas("scripts/verify-compiler-slice.sh --check-only checker"), "fake check-only compiler slice command should execute");
    break;
  case "mixed-swarm-runtime":
    assert(report.inputSources.filter((source) => source.kind === "files-from").length === 2, "repeated files-from sources should be recorded");
    assert(report.inputSources.some((source) => source.kind === "env"), "env source should be recorded");
    assert(report.changedFiles.includes("runtime/swarm.rs"), "runtime file should be present");
    assert(report.changedFiles.includes("examples/swarm-native/GoalManager.clasp"), "swarm file should be present");
    assert(report.changedFiles.includes("examples/feedback-loop/Main.clasp"), "feedback-loop file should be present");
    assert(hasCommand("bash scripts/test-int-builtins.sh"), "runtime route should run focused integer builtin coverage");
    assert(hasCommand("bash scripts/test-dict-builtins.sh"), "runtime route should run focused dictionary builtin coverage");
    assert(hasCommand("bash scripts/test-try-decode.sh"), "runtime route should run focused tryDecode coverage");
    assert(hasCommand("bash scripts/test-native-runtime.sh"), "runtime route should run native runtime coverage");
    assert(hasCommand("bash scripts/test-native-claspc.sh"), "runtime/swarm route should run native claspc coverage");
    assert(hasCommand("bash scripts/test-swarm-ready-gate.sh"), "swarm route should run ready-gate coverage");
    assert(hasCommand("bash scripts/verify-runtime-slice.sh process"), "feedback-loop route should run process runtime slice coverage");
    assert(hasCommand("bash scripts/verify-runtime-slice.sh workflow"), "feedback-loop route should run workflow runtime slice coverage");
    assert(hasCommand("bash scripts/verify-runtime-slice.sh codex-loop"), "feedback-loop route should run ordinary Codex runtime slice coverage");
    assert(hasCommand("bash scripts/verify-runtime-slice.sh managed-loop"), "swarm route should run managed-loop runtime slice coverage");
    assert(!hasCommand("bash scripts/verify-runtime-slice.sh swarm-feedback-loop"), "generic swarm route should avoid the expensive FeedbackLoop runtime slice");
    assert(hasCommand("bash scripts/test-feedback-loop-routing.sh loop-routing"), "feedback-loop route should run the lightweight loop-routing selector probe");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-native-claspc.sh").length === 1, "native claspc command should be deduplicated");
    assert(report.usedVerifyFastFallback === false, "mixed known inputs should not fall back to verify-fast");
    break;
  case "unknown-fallback":
    assert(report.verificationFallbackMode === "unknown-path", "unknown path should mark fallback mode");
    assert(report.usedVerifyFastFallback === true, "unknown path should use verify-fast fallback");
    assert(report.selectedCommands.length === 1, "unknown-only input should select only verify-fast");
    assert(hasCommand("bash scripts/verify-fast.sh"), "unknown path should run verify-fast");
    assert(logHas("scripts/verify-fast.sh"), "fake verify-fast command should execute");
    break;
  case "verification-script":
    assert(report.changedFiles.includes("scripts/verify-affected.mjs"), "affected helper should be present");
    assert(hasCommand("node --check scripts/verify-affected.mjs"), "affected helper should run node syntax check");
    assert(hasCommand("bash scripts/test-verify-affected.sh"), "affected helper should run focused regression");
    assert(report.usedVerifyFastFallback === false, "known verification script should not use verify-fast fallback");
    assert(logHas("scripts/test-verify-affected.sh"), "fake affected regression command should execute");
    break;
  case "selfhost-verify-script":
    assert(report.changedFiles.includes("src/scripts/verify.sh"), "selfhost native verify script should be present");
    assert(hasCommand("bash -n 'src/scripts/verify.sh'"), "selfhost native verify script should run shell syntax check");
    assert(hasCommand("bash scripts/test-selfhost-verify-mode-split.sh"), "selfhost native verify script should run focused mode split regression");
    assert(!hasCommand("bash scripts/test-selfhost.sh"), "selfhost native verify script should avoid broad selfhost routing");
    assert(!hasCommand("bash src/scripts/verify.sh"), "selfhost native verify script should avoid recursive hosted source verification");
    assert(report.usedVerifyFastFallback === false, "known selfhost native verify script should not use verify-fast fallback");
    assert(logHas("scripts/test-selfhost-verify-mode-split.sh"), "fake selfhost verify mode split command should execute");
    break;
  case "selfhost-harness-script":
    assert(report.changedFiles.includes("scripts/test-selfhost.sh"), "selfhost harness should be present");
    assert(hasCommand("bash -n 'scripts/test-selfhost.sh'"), "selfhost harness should run shell syntax check");
    assert(hasCommand("bash scripts/test-selfhost.sh"), "selfhost harness should run focused selfhost coverage");
    assert(!hasCommand("bash scripts/verify-fast.sh"), "selfhost harness route should avoid verify-fast fallback");
    assert(report.usedVerifyFastFallback === false, "known selfhost harness should not use verify-fast fallback");
    assert(logHas("scripts/test-selfhost.sh"), "fake selfhost harness command should execute");
    break;
  case "native-claspc-harness-script":
    assert(report.changedFiles.includes("scripts/test-native-claspc.sh"), "native claspc harness should be present");
    assert(hasCommand("bash -n 'scripts/test-native-claspc.sh'"), "native claspc harness should run shell syntax check");
    assert(hasCommand("bash scripts/test-native-claspc.sh"), "native claspc harness should run focused native coverage");
    assert(!hasCommand("bash scripts/verify-fast.sh"), "native claspc harness route should avoid verify-fast fallback");
    assert(report.usedVerifyFastFallback === false, "known native claspc harness should not use verify-fast fallback");
    assert(logHas("scripts/test-native-claspc.sh"), "fake native claspc harness command should execute");
    break;
  case "native-diagnostics-script":
    assert(report.changedFiles.includes("scripts/test-native-claspc-diagnostics.sh"), "native diagnostics harness should be present");
    assert(hasCommand("bash -n 'scripts/test-native-claspc-diagnostics.sh'"), "native diagnostics harness should run shell syntax check");
    assert(hasCommand("bash scripts/test-native-claspc-diagnostics.sh"), "native diagnostics harness should run focused diagnostics coverage");
    assert(report.usedVerifyFastFallback === false, "known native diagnostics harness should not use verify-fast fallback");
    assert(logHas("scripts/test-native-claspc-diagnostics.sh"), "fake native diagnostics command should execute");
    break;
  case "native-incremental-script":
    assert(report.changedFiles.includes("scripts/measure-native-incremental.sh"), "native incremental measurement script should be present");
    assert(hasCommand("bash -n 'scripts/measure-native-incremental.sh'"), "native incremental measurement script should run shell syntax check");
    assert(hasCommand("bash scripts/measure-native-incremental.sh --scenario native-cli-body-change --assert"), "native incremental route should run the native CLI cache scenario");
    assert(hasCommand("bash scripts/measure-native-incremental.sh --scenario selfhost-body-change --assert"), "native incremental route should run the selfhost cache scenario");
    assert(hasCommand("bash scripts/measure-native-incremental.sh --scenario selfhost-compiler-module-body-change --assert"), "native incremental route should run the compiler-module cache scenario");
    assert(hasCommand("CLASP_NATIVE_INCREMENTAL_COMPILER_MODULE_IMAGE_PROBE=0"), "compiler-module incremental route should skip the expensive native-image diagnostic by default");
    assert(!hasCommand("compilerImageBodyChange=15"), "compiler-module incremental route should not run a full compiler native-image duration guard by default");
    assert(hasCommand("compilerCheckBodyChange=10"), "compiler-module incremental route should keep a body-change check duration guard");
    assert(hasCommand("CLASP_NATIVE_IMAGE_SECTION_JOBS=2"), "native incremental route should force bounded image section jobs");
    assert(!hasCommand("bash scripts/verify-fast.sh"), "native incremental route should avoid verify-fast fallback");
    assert(report.usedVerifyFastFallback === false, "known native incremental measurement script should not use verify-fast fallback");
    assert(logHas("scripts/measure-native-incremental.sh --scenario native-cli-body-change --assert"), "fake native CLI incremental command should execute");
    assert(logHas("scripts/measure-native-incremental.sh --scenario selfhost-body-change --assert"), "fake selfhost incremental command should execute");
    assert(logHas("scripts/measure-native-incremental.sh --scenario selfhost-compiler-module-body-change --assert"), "fake compiler-module incremental command should execute");
    break;
  case "iteration-speed-evidence":
    assert(report.changedFiles.includes("docs/iteration-speed-loop-evidence.md"), "iteration speed evidence doc should be present");
    assert(hasCommand("bash scripts/test-native-incremental-guard.sh"), "iteration speed evidence should run the focused native incremental guard");
    assert(!hasCommand("bash scripts/verify-fast.sh"), "iteration speed evidence route should avoid verify-fast fallback");
    assert(report.usedVerifyFastFallback === false, "known iteration speed evidence should not use verify-fast fallback");
    assert(logHas("scripts/test-native-incremental-guard.sh"), "fake native incremental guard command should execute");
    break;
  case "native-incremental-guard":
    assert(report.changedFiles.includes("scripts/native-incremental-guard.mjs"), "native incremental guard helper should be present");
    assert(report.changedFiles.includes("scripts/test-native-incremental-guard.sh"), "native incremental guard harness should be present");
    assert(hasCommand("node --check 'scripts/native-incremental-guard.mjs'"), "native incremental guard helper should run node syntax check");
    assert(hasCommand("bash -n 'scripts/test-native-incremental-guard.sh'"), "native incremental guard harness should run shell syntax check");
    assert(hasCommand("bash scripts/test-native-incremental-guard.sh"), "native incremental guard route should run focused guard coverage");
    assert(!hasCommand("bash scripts/verify-fast.sh"), "native incremental guard route should avoid verify-fast fallback");
    assert(report.usedVerifyFastFallback === false, "known native incremental guard paths should not use verify-fast fallback");
    assert(logHas("scripts/test-native-incremental-guard.sh"), "fake native incremental guard command should execute");
    break;
  case "swarm-control-script":
    assert(report.changedFiles.includes("scripts/clasp-swarm-common.sh"), "swarm common helper should be present");
    assert(report.changedFiles.includes("scripts/clasp-swarm-start.sh"), "swarm start helper should be present");
    assert(report.changedFiles.includes("scripts/clasp-swarm-lane.sh"), "swarm lane helper should be present");
    assert(report.changedFiles.includes("scripts/clasp-swarm-preflight.sh"), "swarm preflight helper should be present");
    assert(report.changedFiles.includes("scripts/clasp-swarm-validate-task.mjs"), "swarm task validator should be present");
    assert(report.changedFiles.includes("scripts/test-task-manifest.sh"), "task manifest harness should be present");
    assert(hasCommand("bash -n 'scripts/clasp-swarm-common.sh'"), "swarm common helper should run shell syntax check");
    assert(hasCommand("bash -n 'scripts/clasp-swarm-start.sh'"), "swarm start helper should run shell syntax check");
    assert(hasCommand("bash -n 'scripts/clasp-swarm-lane.sh'"), "swarm lane helper should run shell syntax check");
    assert(hasCommand("bash -n 'scripts/clasp-swarm-preflight.sh'"), "swarm preflight helper should run shell syntax check");
    assert(hasCommand("node --check 'scripts/clasp-swarm-validate-task.mjs'"), "swarm task validator should run node syntax check");
    assert(hasCommand("bash -n 'scripts/test-task-manifest.sh'"), "task manifest harness should run shell syntax check");
    assert(hasCommand("bash scripts/test-task-manifest.sh"), "task manifest route should run focused manifest coverage");
    assert(hasCommand("bash scripts/test-swarm-control.sh"), "swarm control route should run focused control-plane coverage");
    assert(!hasCommand("bash scripts/verify-fast.sh"), "swarm control route should avoid verify-fast fallback");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-swarm-control.sh").length === 1, "swarm control command should be deduplicated");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-task-manifest.sh").length === 1, "task manifest command should be deduplicated");
    assert(report.usedVerifyFastFallback === false, "known swarm control files should not use verify-fast fallback");
    assert(logHas("scripts/test-task-manifest.sh"), "fake task manifest command should execute");
    assert(logHas("scripts/test-swarm-control.sh"), "fake swarm control command should execute");
    break;
  case "swarm-preflight-script":
    assert(report.changedFiles.includes("scripts/clasp-swarm-preflight.sh"), "swarm preflight helper should be present");
    assert(report.changedFiles.includes("scripts/test-swarm-preflight.sh"), "swarm preflight harness should be present");
    assert(hasCommand("bash -n 'scripts/clasp-swarm-preflight.sh'"), "swarm preflight helper should run shell syntax check");
    assert(hasCommand("bash -n 'scripts/test-swarm-preflight.sh'"), "swarm preflight harness should run shell syntax check");
    assert(hasCommand("bash scripts/test-swarm-preflight.sh"), "swarm preflight route should run focused preflight-only coverage");
    assert(hasCommand("bash scripts/test-swarm-ready-gate.sh"), "swarm preflight route should keep structural swarm-ready coverage");
    assert(!hasCommand("bash scripts/test-swarm-control.sh"), "swarm preflight route should avoid the broader control-plane suite");
    assert(!hasCommand("bash scripts/verify-fast.sh"), "swarm preflight route should avoid verify-fast fallback");
    assert(report.commandResourceSummary.requiresManagedGuard === false, "swarm preflight route should be safe-direct");
    assert(report.commandResourceSummary.overallAdvice === "safe-direct", "swarm preflight route should be direct static/focused-safe coverage");
    assert(findCommand("bash scripts/test-swarm-preflight.sh").resourceClass === "static", "swarm preflight test should be classified as static");
    assert(findCommand("bash scripts/test-swarm-preflight.sh").requiresManagedGuard === false, "swarm preflight test should not require external managed wrapping");
    assert(report.usedVerifyFastFallback === false, "known swarm preflight files should not use verify-fast fallback");
    assert(logHas("scripts/test-swarm-preflight.sh"), "fake swarm preflight command should execute");
    assert(logHas("scripts/test-swarm-ready-gate.sh"), "fake swarm preflight ready-gate command should execute");
    break;
  case "int-builtins-script":
    assert(report.changedFiles.includes("scripts/test-int-builtins.sh"), "integer builtin harness should be present");
    assert(hasCommand("bash -n 'scripts/test-int-builtins.sh'"), "integer builtin harness should run shell syntax check");
    assert(hasCommand("bash scripts/test-int-builtins.sh"), "integer builtin harness should run focused JS/native coverage");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-int-builtins.sh").length === 1, "integer builtin command should be deduplicated");
    assert(report.usedVerifyFastFallback === false, "known integer builtin harness should not use verify-fast fallback");
    assert(logHas("scripts/test-int-builtins.sh"), "fake integer builtin command should execute");
    break;
  case "dict-builtins-script":
    assert(report.changedFiles.includes("scripts/test-dict-builtins.sh"), "dictionary builtin harness should be present");
    assert(hasCommand("bash -n 'scripts/test-dict-builtins.sh'"), "dictionary builtin harness should run shell syntax check");
    assert(hasCommand("bash scripts/test-dict-builtins.sh"), "dictionary builtin harness should run focused JS/native coverage");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-dict-builtins.sh").length === 1, "dictionary builtin command should be deduplicated");
    assert(report.usedVerifyFastFallback === false, "known dictionary builtin harness should not use verify-fast fallback");
    assert(logHas("scripts/test-dict-builtins.sh"), "fake dictionary builtin command should execute");
    break;
  case "try-decode-script":
    assert(report.changedFiles.includes("scripts/test-try-decode.sh"), "tryDecode harness should be present");
    assert(hasCommand("bash -n 'scripts/test-try-decode.sh'"), "tryDecode harness should run shell syntax check");
    assert(hasCommand("bash scripts/test-try-decode.sh"), "tryDecode harness should run focused JS/native coverage");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-try-decode.sh").length === 1, "tryDecode command should be deduplicated");
    assert(report.usedVerifyFastFallback === false, "known tryDecode harness should not use verify-fast fallback");
    assert(logHas("scripts/test-try-decode.sh"), "fake tryDecode command should execute");
    break;
  case "service-decode":
    assert(report.changedFiles.includes("examples/swarm-native/Service.clasp"), "service source should be present");
    assert(report.changedFiles.includes("examples/swarm-native/ServiceDecodeHarness.clasp"), "service decode harness should be present");
    assert(report.changedFiles.includes("scripts/test-service-decode.sh"), "service decode script should be present");
    assert(hasCommand("bash scripts/test-service-decode.sh"), "service decode route should run focused host JSON recovery coverage");
    assert(hasCommand("bash -n 'scripts/test-service-decode.sh'"), "service decode script should run shell syntax check");
    assert(hasCommand("bash scripts/test-swarm-ready-gate.sh"), "service decode route should retain structural ready-gate coverage");
    assert(!hasCommand("bash scripts/test-native-claspc.sh"), "service decode route should avoid broad native-claspc coverage");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-service-decode.sh").length === 1, "service decode command should be deduplicated");
    assert(report.usedVerifyFastFallback === false, "known service decode paths should not use verify-fast fallback");
    assert(logHas("scripts/test-service-decode.sh"), "fake service decode command should execute");
    assert(logHas("scripts/test-swarm-ready-gate.sh"), "fake swarm-ready command should execute");
    break;
  case "managed-job-safety":
    assert(report.changedFiles.includes("scripts/run-managed-job.sh"), "managed job launcher should be present");
    assert(report.changedFiles.includes("scripts/stop-managed-job.sh"), "managed job stopper should be present");
    assert(report.changedFiles.includes("scripts/test-managed-job.sh"), "managed job test should be present");
    assert(report.changedFiles.includes("scripts/clasp-clean-generated-state.sh"), "generated cleanup helper should be present");
    assert(report.changedFiles.includes("scripts/test-generated-state-cleanup.sh"), "generated cleanup regression should be present");
    assert(hasCommand("bash -n 'scripts/run-managed-job.sh'"), "managed job launcher should run shell syntax check");
    assert(hasCommand("bash -n 'scripts/stop-managed-job.sh'"), "managed job stopper should run shell syntax check");
    assert(hasCommand("bash -n 'scripts/test-managed-job.sh'"), "managed job test should run shell syntax check");
    assert(hasCommand("bash -n 'scripts/clasp-clean-generated-state.sh'"), "generated cleanup helper should run shell syntax check");
    assert(hasCommand("bash -n 'scripts/test-generated-state-cleanup.sh'"), "generated cleanup test should run shell syntax check");
    assert(hasCommand("bash scripts/test-managed-job.sh"), "managed job route should run focused process/memory guard coverage");
    assert(hasCommand("bash scripts/test-generated-state-cleanup.sh"), "managed job route should run generated cleanup coverage");
    assert(hasCommand("bash scripts/test-swarm-ready-gate.sh"), "managed job route should retain structural ready-gate coverage");
    assert(!hasCommand("bash scripts/verify-fast.sh"), "managed job route should avoid verify-fast fallback");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-managed-job.sh").length === 1, "managed job command should be deduplicated");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-generated-state-cleanup.sh").length === 1, "generated cleanup command should be deduplicated");
    assert(report.usedVerifyFastFallback === false, "known managed job safety paths should not use verify-fast fallback");
    assert(logHas("scripts/test-managed-job.sh"), "fake managed job command should execute");
    assert(logHas("scripts/test-generated-state-cleanup.sh"), "fake generated cleanup command should execute");
    assert(logHas("scripts/test-swarm-ready-gate.sh"), "fake swarm-ready command should execute");
    break;
  case "record-update-parity-script":
    assert(report.changedFiles.includes("scripts/test-record-update-parity.sh"), "record update parity harness should be present");
    assert(hasCommand("bash -n 'scripts/test-record-update-parity.sh'"), "record update parity harness should run shell syntax check");
    assert(hasCommand("bash scripts/test-record-update-parity.sh"), "record update parity harness should run focused parity coverage");
    assert(report.usedVerifyFastFallback === false, "known record update parity harness should not use verify-fast fallback");
    assert(logHas("scripts/test-record-update-parity.sh"), "fake record update parity command should execute");
    break;
  case "compiler-slice-script":
    assert(report.changedFiles.includes("scripts/verify-compiler-slice.sh"), "compiler slice verifier should be present");
    assert(report.changedFiles.includes("scripts/test-verify-compiler-slice.sh"), "compiler slice smoke test should be present");
    assert(hasCommand("bash -n 'scripts/verify-compiler-slice.sh'"), "compiler slice verifier should run shell syntax check");
    assert(hasCommand("bash -n 'scripts/test-verify-compiler-slice.sh'"), "compiler slice smoke should run shell syntax check");
    assert(hasCommand("bash scripts/test-verify-compiler-slice.sh"), "compiler slice script changes should run focused smoke");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-verify-compiler-slice.sh").length === 1, "compiler slice smoke should be deduplicated");
    assert(report.usedVerifyFastFallback === false, "known compiler slice scripts should not use verify-fast fallback");
    assert(logHas("scripts/test-verify-compiler-slice.sh"), "fake compiler slice smoke command should execute");
    break;
  case "js-emitter-determinism":
    assert(report.changedFiles.includes("src/Compiler/Emit/JavaScript.clasp"), "JavaScript emitter source should be present");
    assert(report.changedFiles.includes("scripts/test-js-emitter-determinism.sh"), "JavaScript emitter determinism guard should be present");
    assert(hasCommand("bash scripts/test-selfhost.sh"), "JavaScript emitter source route should run selfhost coverage");
    assert(hasCommand("bash src/scripts/verify.sh"), "JavaScript emitter source route should run hosted source verification");
    assert(hasCommand("bash scripts/verify-compiler-slice.sh --check-only emitter"), "JavaScript emitter source route should run focused emitter check");
    assert(hasCommand("bash -n 'scripts/test-js-emitter-determinism.sh'"), "JavaScript emitter determinism guard should run shell syntax check");
    assert(hasCommand("bash scripts/test-js-emitter-determinism.sh"), "JavaScript emitter source route should run deterministic snapshot guard");
    assert(report.usedVerifyFastFallback === false, "known JavaScript emitter determinism paths should not use verify-fast fallback");
    assert(logHas("scripts/test-js-emitter-determinism.sh"), "fake JavaScript emitter determinism guard should execute");
    break;
  case "promoted-source-export-cache":
    assert(report.changedFiles.includes("scripts/generate-promoted-source-export-cache.mjs"), "promoted source export generator should be present");
    assert(report.changedFiles.includes("scripts/test-promoted-source-export-cache.sh"), "promoted source export smoke test should be present");
    assert(report.changedFiles.includes("src/stage1.compiler.source-export-cache-v1.json"), "promoted source export cache should be present");
    assert(report.changedFiles.includes("src/stage1.promoted-project.native.image.json"), "promoted project fixture native image should be present");
    assert(hasCommand("node --check scripts/generate-promoted-source-export-cache.mjs"), "promoted source export generator should run node syntax check");
    assert(hasCommand("bash -n 'scripts/test-promoted-source-export-cache.sh'"), "promoted source export smoke should run shell syntax check");
    assert(hasCommand("bash scripts/test-promoted-source-export-cache.sh"), "promoted source export cache changes should run focused smoke");
    assert(!hasCommand("bash scripts/test-selfhost.sh"), "promoted source export cache should avoid broad selfhost routing");
    assert(report.usedVerifyFastFallback === false, "known promoted source export cache paths should not use verify-fast fallback");
    assert(logHas("scripts/test-promoted-source-export-cache.sh"), "fake promoted source export smoke command should execute");
    break;
  case "promoted-module-summary-cache":
    assert(report.changedFiles.includes("scripts/generate-promoted-module-summary-cache.mjs"), "promoted module summary generator should be present");
    assert(report.changedFiles.includes("scripts/test-promoted-module-summary-cache.sh"), "promoted module summary smoke test should be present");
    assert(report.changedFiles.includes("src/stage1.compiler.module-summary-cache-v2.json"), "promoted module summary cache should be present");
    assert(report.changedFiles.includes("src/stage1.compiler.native.image.json"), "promoted compiler native image should be present");
    assert(hasCommand("node --check scripts/generate-promoted-module-summary-cache.mjs"), "promoted module summary generator should run node syntax check");
    assert(hasCommand("bash -n 'scripts/test-promoted-module-summary-cache.sh'"), "promoted module summary smoke should run shell syntax check");
    assert(hasCommand("bash scripts/test-promoted-module-summary-cache.sh"), "promoted module summary cache changes should run focused freshness check");
    assert(!hasCommand("bash scripts/test-selfhost.sh"), "promoted module summary cache should avoid broad selfhost routing");
    assert(!hasCommand("bash scripts/verify-fast.sh"), "promoted module summary cache should avoid verify-fast fallback");
    assert(report.usedVerifyFastFallback === false, "known promoted module summary cache paths should not use verify-fast fallback");
    assert(logHas("scripts/test-promoted-module-summary-cache.sh"), "fake promoted module summary smoke command should execute");
    break;
  case "runtime-slice-script":
    assert(report.changedFiles.includes("scripts/verify-runtime-slice.sh"), "runtime slice verifier should be present");
    assert(report.changedFiles.includes("scripts/test-verify-runtime-slice.sh"), "runtime slice smoke test should be present");
    assert(hasCommand("bash -n 'scripts/verify-runtime-slice.sh'"), "runtime slice verifier should run shell syntax check");
    assert(hasCommand("bash -n 'scripts/test-verify-runtime-slice.sh'"), "runtime slice smoke should run shell syntax check");
    assert(hasCommand("bash scripts/test-verify-runtime-slice.sh"), "runtime slice script changes should run focused smoke");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-verify-runtime-slice.sh").length === 1, "runtime slice smoke should be deduplicated");
    assert(report.usedVerifyFastFallback === false, "known runtime slice scripts should not use verify-fast fallback");
    assert(logHas("scripts/test-verify-runtime-slice.sh"), "fake runtime slice smoke command should execute");
    break;
  case "swarm-feedback-loop-script":
    assert(report.changedFiles.includes("scripts/test-swarm-native-feedback-loop.sh"), "swarm feedback-loop script should be present");
    assert(hasCommand("bash -n 'scripts/test-swarm-native-feedback-loop.sh'"), "swarm feedback-loop script should run shell syntax check");
    assert(hasCommand("bash scripts/verify-runtime-slice.sh swarm-feedback-loop"), "swarm feedback-loop script should run focused runtime slice");
    assert(report.selectedCommands.filter((command) => command.command.includes("bash scripts/verify-runtime-slice.sh swarm-feedback-loop")).length === 1, "swarm feedback-loop slice should be deduplicated");
    assert(report.usedVerifyFastFallback === false, "known swarm feedback-loop script should not use verify-fast fallback");
    assert(logHas("scripts/test-swarm-native-feedback-loop.sh"), "fake swarm feedback-loop shell syntax should execute");
    assert(logHas("scripts/verify-runtime-slice.sh swarm-feedback-loop"), "fake swarm feedback-loop runtime slice should execute");
    break;
  case "swarm-feedback-loop-program":
    assert(report.changedFiles.includes("examples/swarm-native/FeedbackLoop.clasp"), "FeedbackLoop source should be present");
    assert(report.changedFiles.includes("examples/swarm-native/AttemptLoop.clasp"), "AttemptLoop source should be present");
    assert(report.changedFiles.includes("examples/swarm-native/LocalAgent.clasp"), "LocalAgent source should be present");
    assert(hasCommand("bash scripts/verify-runtime-slice.sh swarm-feedback-loop"), "FeedbackLoop source should run focused runtime slice");
    assert(hasCommand("bash scripts/test-agent-command-template.sh"), "FeedbackLoop source should run provider-neutral/local agent prompt coverage");
    assert(hasCommand("bash scripts/test-swarm-ready-gate.sh"), "FeedbackLoop source should keep structural swarm-ready coverage");
    assert(!hasCommand("bash scripts/test-native-claspc.sh"), "FeedbackLoop source should avoid broad native-claspc routing");
    assert(!hasCommand("bash scripts/verify-runtime-slice.sh managed-loop"), "FeedbackLoop source should avoid unrelated managed-loop runtime slice");
    assert(!hasCommand("bash scripts/test-swarm-memory.sh"), "FeedbackLoop source should avoid standalone memory harness routing");
    assert(report.selectedCommands.filter((command) => command.command.includes("bash scripts/verify-runtime-slice.sh swarm-feedback-loop")).length === 1, "FeedbackLoop runtime slice should be deduplicated");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-agent-command-template.sh").length === 1, "agent command template should be deduplicated");
    assert(report.usedVerifyFastFallback === false, "known FeedbackLoop source should not use verify-fast fallback");
    assert(logHas("scripts/verify-runtime-slice.sh swarm-feedback-loop"), "fake FeedbackLoop runtime slice should execute");
    assert(logHas("scripts/test-agent-command-template.sh"), "fake agent command template should execute");
    assert(logHas("scripts/test-swarm-ready-gate.sh"), "fake swarm-ready command should execute");
    break;
  case "local-agent-capability-closure":
    assert(report.changedFiles.includes("examples/swarm-native/LocalSourceEdit.clasp"), "LocalSourceEdit source should be present");
    assert(report.changedFiles.includes("examples/swarm-native/LocalSourceEditHarness.clasp"), "LocalSourceEdit harness should be present");
    assert(report.changedFiles.includes("scripts/test-local-source-edit-workspace.sh"), "local source-edit workspace harness should be present");
    assert(hasCommand("bash -n 'scripts/test-local-source-edit-workspace.sh'"), "local source-edit workspace harness should run shell syntax check");
    assert(hasCommand("bash scripts/test-local-source-edit-workspace.sh"), "local source-edit route should run focused workspace-confined coverage");
    assert(hasCommand("bash scripts/test-swarm-ready-gate.sh"), "local source-edit route should keep structural swarm-ready coverage");
    assert(!hasCommand("bash scripts/test-local-agent-capability-closure.sh"), "LocalSourceEdit source changes should avoid the heavyweight local-agent closure compile");
    assert(!hasCommand("bash scripts/test-native-claspc.sh"), "local source-edit route should avoid broad native-claspc coverage");
    assert(!hasCommand("bash scripts/verify-runtime-slice.sh managed-loop"), "local source-edit route should avoid unrelated managed-loop slice");
    assert(!hasCommand("bash scripts/test-swarm-memory.sh"), "local source-edit route should avoid standalone memory harness routing");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-local-source-edit-workspace.sh").length === 1, "local source-edit workspace command should be deduplicated");
    assert(report.usedVerifyFastFallback === false, "known local source-edit paths should not use verify-fast fallback");
    assert(logHas("scripts/test-local-source-edit-workspace.sh"), "fake local source-edit workspace command should execute");
    assert(logHas("scripts/test-swarm-ready-gate.sh"), "fake swarm-ready command should execute");
    break;
  case "local-agent-capability-closure-script":
    assert(report.changedFiles.includes("scripts/test-local-agent-capability-closure.sh"), "local-agent capability closure harness should be present");
    assert(hasCommand("bash -n 'scripts/test-local-agent-capability-closure.sh'"), "local-agent capability closure harness should run shell syntax check");
    assert(hasCommand("bash scripts/test-local-agent-capability-closure.sh static"), "local-agent capability closure harness should run static contract coverage");
    assert(findCommand("bash scripts/test-local-agent-capability-closure.sh static").resourceClass === "static", "local-agent capability closure static route should be classified as static");
    assert(findCommand("bash scripts/test-local-agent-capability-closure.sh static").requiresManagedGuard === false, "local-agent capability closure static route should not require managed execution");
    assert(hasCommand("bash scripts/test-swarm-ready-gate.sh"), "local-agent capability closure harness should keep structural swarm-ready coverage");
    assert(!hasCommand("bash scripts/test-native-claspc.sh"), "local-agent capability closure harness should avoid broad native-claspc coverage");
    assert(!hasCommand("bash scripts/verify-runtime-slice.sh managed-loop"), "local-agent capability closure harness should avoid unrelated managed-loop slice");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-local-agent-capability-closure.sh static").length === 1, "local-agent capability closure command should be deduplicated");
    assert(report.usedVerifyFastFallback === false, "known local-agent capability closure harness should not use verify-fast fallback");
    assert(logHas("scripts/test-local-agent-capability-closure.sh static"), "fake local-agent capability closure static command should execute");
    assert(logHas("scripts/test-swarm-ready-gate.sh"), "fake local-agent capability closure ready-gate command should execute");
    break;
  case "goal-manager-planner-prompt":
    assert(report.changedFiles.includes("examples/swarm-native/GoalManagerBootstrapPlanner.clasp"), "GoalManager planner source should be present");
    assert(report.changedFiles.includes("examples/swarm-native/GoalManagerPlannerInputFingerprint.clasp"), "GoalManager planner input fingerprint source should be present");
    assert(report.changedFiles.includes("examples/swarm-native/GoalManagerPlannerInputTypes.clasp"), "GoalManager planner input type source should be present");
    assert(report.changedFiles.includes("examples/swarm-native/GoalManagerPlannerInputState.clasp"), "GoalManager planner input state source should be present");
    assert(report.changedFiles.includes("examples/swarm-native/PlannerInputFingerprintHarness.clasp"), "planner input fingerprint harness should be present");
    assert(report.changedFiles.includes("examples/swarm-native/LocalPlanner.clasp"), "LocalPlanner source should be present");
    assert(report.changedFiles.includes("scripts/test-goal-manager-agent-command-template.sh"), "provider-neutral planner harness should be present");
    assert(report.changedFiles.includes("scripts/test-goal-manager-default-planner-command.sh"), "default planner harness should be present");
    assert(report.changedFiles.includes("scripts/test-goal-manager-fixture-manager.mjs"), "GoalManager fixture manager should be present");
    assert(hasCommand("bash -n 'scripts/test-goal-manager-agent-command-template.sh'"), "provider-neutral planner harness should run shell syntax check");
    assert(hasCommand("bash -n 'scripts/test-goal-manager-default-planner-command.sh'"), "default planner harness should run shell syntax check");
    assert(hasCommand("node --check 'scripts/test-goal-manager-fixture-manager.mjs'"), "fixture manager should run node syntax check");
    assert(hasCommand("bash scripts/test-goal-manager-agent-command-template.sh"), "planner prompt route should run provider-neutral planner coverage");
    assert(hasCommand("bash scripts/test-goal-manager-default-planner-command.sh"), "planner prompt route should run default planner command coverage");
    assert(hasCommand("bash scripts/test-swarm-ready-gate.sh"), "planner prompt route should keep structural swarm-ready coverage");
    assert(!hasCommand("bash scripts/test-native-claspc.sh"), "planner prompt route should avoid broad native-claspc routing");
    assert(!hasCommand("bash scripts/verify-runtime-slice.sh managed-loop"), "planner prompt route should avoid unrelated managed-loop slice");
    assert(!hasCommand("bash scripts/test-swarm-memory.sh"), "planner prompt route should avoid standalone memory harness routing");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-goal-manager-agent-command-template.sh").length === 1, "provider-neutral planner command should be deduplicated");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-goal-manager-default-planner-command.sh").length === 1, "default planner command should be deduplicated");
    assert(report.usedVerifyFastFallback === false, "known planner prompt paths should not use verify-fast fallback");
    assert(logHas("scripts/test-goal-manager-agent-command-template.sh"), "fake provider-neutral planner harness should execute");
    assert(logHas("scripts/test-goal-manager-default-planner-command.sh"), "fake default planner harness should execute");
    assert(logHas("scripts/test-swarm-ready-gate.sh"), "fake swarm-ready command should execute");
    break;
  case "feedback-loop-resume-script":
    assert(report.changedFiles.includes("scripts/test-feedback-loop-resume.sh"), "feedback-loop resume script should be present");
    assert(hasCommand("bash -n 'scripts/test-feedback-loop-resume.sh'"), "feedback-loop resume script should run shell syntax check");
    assert(hasCommand("bash scripts/test-feedback-loop-resume.sh smoke"), "feedback-loop resume script should run the focused smoke split");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-feedback-loop-resume.sh smoke").length === 1, "feedback-loop resume smoke command should be deduplicated");
    assert(report.usedVerifyFastFallback === false, "known feedback-loop resume script should not use verify-fast fallback");
    assert(logHas("scripts/test-feedback-loop-resume.sh smoke"), "fake feedback-loop resume smoke command should execute");
    break;
  case "feedback-loop-routing-script":
    assert(report.changedFiles.includes("scripts/test-feedback-loop-routing.sh"), "feedback-loop routing script should be present");
    assert(hasCommand("bash -n 'scripts/test-feedback-loop-routing.sh'"), "feedback-loop routing script should run shell syntax check");
    assert(hasCommand("bash scripts/test-feedback-loop-routing.sh"), "feedback-loop routing script should run the lightweight selector probe");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-feedback-loop-routing.sh").length === 1, "feedback-loop routing command should be deduplicated");
    assert(report.usedVerifyFastFallback === false, "known feedback-loop routing script should not use verify-fast fallback");
    assert(logHas("scripts/test-feedback-loop-routing.sh"), "fake feedback-loop routing command should execute");
    break;
  case "compiler-slice-fixture":
    assert(report.changedFiles.includes("examples/compiler-checker.clasp"), "compiler checker fixture should be present");
    assert(report.changedFiles.includes("examples/compiler-lower.clasp"), "compiler lower fixture should be present");
    assert(report.changedFiles.includes("examples/compiler-ergonomics.clasp"), "compiler ergonomics fixture should be present");
    assert(hasCommand("bash scripts/verify-compiler-slice.sh checker"), "checker fixture should run focused compiler slice verifier");
    assert(hasCommand("bash scripts/verify-compiler-slice.sh lower"), "lower fixture should run focused compiler slice verifier");
    assert(hasCommand("bash scripts/verify-compiler-slice.sh ergonomics"), "ergonomics fixture should run focused compiler slice verifier");
    assert(report.usedVerifyFastFallback === false, "known compiler fixture should not use verify-fast fallback");
    assert(logHas("scripts/verify-compiler-slice.sh checker"), "fake compiler slice verifier command should execute");
    assert(logHas("scripts/verify-compiler-slice.sh lower"), "fake lower slice verifier command should execute");
    assert(logHas("scripts/verify-compiler-slice.sh ergonomics"), "fake ergonomics slice verifier command should execute");
    break;
  case "agent-feedback":
    assert(report.changedFiles.includes("agents/feedback/test-feedback.json"), "agent feedback artifact should be present");
    assert(hasCommand("node -e 'const fs=require(\"node:fs\"); JSON.parse(fs.readFileSync(process.argv[1],\"utf8\"));' 'agents/feedback/test-feedback.json'"), "agent feedback route should parse JSON");
    assert(report.usedVerifyFastFallback === false, "known agent feedback artifact should not use verify-fast fallback");
    break;
  case "agent-task-scenario":
    assert(report.changedFiles.includes("examples/agent-task-scenario/Main.clasp"), "agent task scenario source should be present");
    assert(report.changedFiles.includes("examples/agent-task-scenario/scripts/verify.sh"), "agent task scenario verifier should be present");
    assert(hasCommand("bash examples/agent-task-scenario/scripts/verify.sh"), "agent task scenario should run its scenario verifier");
    assert(hasCommand("bash -n 'examples/agent-task-scenario/scripts/verify.sh'"), "agent task scenario verifier should run shell syntax check");
    assert(report.selectedCommands.filter((command) => command.command === "bash examples/agent-task-scenario/scripts/verify.sh").length === 1, "agent task scenario verifier should be deduplicated");
    assert(report.usedVerifyFastFallback === false, "known agent task scenario inputs should not use verify-fast fallback");
    assert(logHas("examples/agent-task-scenario/scripts/verify.sh"), "fake agent task scenario verifier command should execute");
    break;
  case "agent-metadata":
    assert(report.changedFiles.includes("examples/agent-metadata/Main.clasp"), "agent metadata source should be present");
    assert(report.changedFiles.includes("examples/agent-metadata/scripts/verify.sh"), "agent metadata verifier should be present");
    assert(hasCommand("bash examples/agent-metadata/scripts/verify.sh"), "agent metadata should run its scenario verifier");
    assert(hasCommand("bash -n 'examples/agent-metadata/scripts/verify.sh'"), "agent metadata verifier should run shell syntax check");
    assert(report.selectedCommands.filter((command) => command.command === "bash examples/agent-metadata/scripts/verify.sh").length === 1, "agent metadata verifier should be deduplicated");
    assert(report.usedVerifyFastFallback === false, "known agent metadata inputs should not use verify-fast fallback");
    assert(logHas("examples/agent-metadata/scripts/verify.sh"), "fake agent metadata verifier command should execute");
    break;
  case "agent-loop-scenario":
    assert(report.changedFiles.includes("examples/agent-loop-scenario/Main.clasp"), "agent loop scenario source should be present");
    assert(report.changedFiles.includes("examples/agent-loop-scenario/AgentRuntime.clasp"), "agent loop runtime helpers should be present");
    assert(report.changedFiles.includes("examples/agent-loop-scenario/Workspace.clasp"), "agent loop workspace wrapper should be present");
    assert(report.changedFiles.includes("examples/agent-loop-scenario/Process.clasp"), "agent loop process wrapper should be present");
    assert(report.changedFiles.includes("examples/agent-loop-scenario/scripts/verify.sh"), "agent loop verifier should be present");
    assert(hasCommand("bash examples/agent-loop-scenario/scripts/verify.sh"), "agent loop scenario should run its scenario verifier");
    assert(hasCommand("bash -n 'examples/agent-loop-scenario/scripts/verify.sh'"), "agent loop verifier should run shell syntax check");
    assert(report.selectedCommands.filter((command) => command.command === "bash examples/agent-loop-scenario/scripts/verify.sh").length === 1, "agent loop verifier should be deduplicated");
    assert(report.usedVerifyFastFallback === false, "known agent loop scenario inputs should not use verify-fast fallback");
    assert(logHas("examples/agent-loop-scenario/scripts/verify.sh"), "fake agent loop scenario verifier command should execute");
    break;
  case "monitored-workflow-script":
    assert(report.changedFiles.includes("scripts/test-monitored-workflow.sh"), "monitored workflow harness should be present");
    assert(hasCommand("bash -n 'scripts/test-monitored-workflow.sh'"), "monitored workflow harness should run shell syntax check");
    assert(hasCommand("bash scripts/verify-runtime-slice.sh workflow"), "monitored workflow harness should run focused runtime slice coverage");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/verify-runtime-slice.sh workflow").length === 1, "monitored workflow runtime slice should be deduplicated");
    assert(report.usedVerifyFastFallback === false, "known monitored workflow harness should not use verify-fast fallback");
    assert(logHas("scripts/verify-runtime-slice.sh workflow"), "fake monitored workflow slice command should execute");
    break;
  case "monitored-run-log-script":
    assert(report.changedFiles.includes("scripts/test-monitored-run-log.sh"), "monitored run-log harness should be present");
    assert(hasCommand("bash -n 'scripts/test-monitored-run-log.sh'"), "monitored run-log harness should run shell syntax check");
    assert(hasCommand("bash scripts/verify-runtime-slice.sh process"), "monitored run-log harness should run focused process runtime slice coverage");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/verify-runtime-slice.sh process").length === 1, "monitored run-log process slice should be deduplicated");
    assert(report.usedVerifyFastFallback === false, "known monitored run-log harness should not use verify-fast fallback");
    assert(logHas("scripts/verify-runtime-slice.sh process"), "fake monitored run-log process slice command should execute");
    break;
  case "codex-loop-program-script":
    assert(report.changedFiles.includes("scripts/test-codex-loop-program.sh"), "ordinary Codex loop harness should be present");
    assert(hasCommand("bash -n 'scripts/test-codex-loop-program.sh'"), "ordinary Codex loop harness should run shell syntax check");
    assert(hasCommand("bash scripts/verify-runtime-slice.sh codex-loop"), "ordinary Codex loop harness should run focused runtime slice coverage");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/verify-runtime-slice.sh codex-loop").length === 1, "ordinary Codex runtime slice should be deduplicated");
    assert(report.usedVerifyFastFallback === false, "known ordinary Codex loop harness should not use verify-fast fallback");
    assert(logHas("scripts/verify-runtime-slice.sh codex-loop"), "fake ordinary Codex loop slice command should execute");
    break;
  case "host-runtime":
    assert(report.changedFiles.includes("examples/host-runtime/Main.clasp"), "host runtime source should be present");
    assert(report.changedFiles.includes("examples/host-runtime/Host.clasp"), "host runtime wrapper should be present");
    assert(report.changedFiles.includes("scripts/test-host-runtime.sh"), "host runtime harness should be present");
    assert(report.changedFiles.includes("docs/clasp-spec-v0.md"), "host runtime spec doc should be present");
    assert(report.changedFiles.includes("docs/autonomous-swarm-build-plan.md"), "host runtime build-plan doc should be present");
    assert(!report.changedFiles.includes(".workspace-ready"), "workspace sentinel should be ignored");
    assert(hasCommand("bash -n 'scripts/test-host-runtime.sh'"), "host runtime harness should run shell syntax check");
    assert(hasCommand("bash scripts/test-host-runtime.sh"), "host runtime route should run focused host API coverage");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-host-runtime.sh").length === 1, "host runtime command should be deduplicated");
    assert(report.usedVerifyFastFallback === false, "known host runtime inputs should not use verify-fast fallback");
    assert(logHas("scripts/test-host-runtime.sh"), "fake host runtime command should execute");
    break;
  case "host-resources":
    assert(report.changedFiles.includes("examples/swarm-native/HostResources.clasp"), "host resources API should be present");
    assert(report.changedFiles.includes("examples/swarm-native/HostResourcesHarness.clasp"), "host resources harness should be present");
    assert(hasCommand("bash scripts/test-host-runtime.sh"), "host resources should run focused host runtime coverage");
    assert(hasCommand("bash scripts/test-swarm-ready-gate.sh"), "host resources should keep the structural swarm gate");
    assert(!hasCommand("bash scripts/test-swarm-memory.sh"), "host resources should avoid unrelated swarm memory coverage");
    assert(!hasCommand("bash scripts/test-swarm-priority.sh"), "host resources should avoid unrelated swarm priority coverage");
    assert(!hasCommand("bash scripts/test-native-claspc.sh"), "host resources should avoid broad native claspc coverage");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-host-runtime.sh").length === 1, "host resources host runtime command should be deduplicated");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-swarm-ready-gate.sh").length === 1, "host resources ready-gate command should be deduplicated");
    assert(report.usedVerifyFastFallback === false, "known host resources inputs should not use verify-fast fallback");
    assert(logHas("scripts/test-host-runtime.sh"), "fake host resources runtime command should execute");
    assert(logHas("scripts/test-swarm-ready-gate.sh"), "fake host resources ready-gate command should execute");
    break;
  case "goal-manager-resource-health":
    assert(report.changedFiles.includes("examples/swarm-native/GoalManagerResourceHealth.clasp"), "GoalManager resource health source should be present");
	    assert(hasCommand("bash scripts/test-resource-guard-policy.sh"), "GoalManager resource health should run static resource guard policy coverage");
	    assert(hasCommand("bash scripts/test-resource-recovery-policy.sh static"), "GoalManager resource health should run static resource recovery policy coverage");
	    assert(hasCommand("bash scripts/test-goal-manager-resource-health.sh static"), "GoalManager resource health should run static manager resource health coverage");
	    assert(hasCommand("bash scripts/test-swarm-ready-gate.sh"), "GoalManager resource health should keep the structural swarm gate");
    assert(!hasCommand("bash scripts/test-host-runtime.sh"), "GoalManager resource health should avoid broader host runtime coverage");
    assert(!hasCommand("bash scripts/test-swarm-memory.sh"), "GoalManager resource health should avoid unrelated swarm memory coverage");
    assert(!hasCommand("bash scripts/test-swarm-priority.sh"), "GoalManager resource health should avoid unrelated swarm priority coverage");
	    assert(!hasCommand("bash scripts/test-native-claspc.sh"), "GoalManager resource health should avoid broad native claspc coverage");
	    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-resource-guard-policy.sh").length === 1, "GoalManager resource health static policy command should be deduplicated");
	    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-resource-recovery-policy.sh static").length === 1, "GoalManager resource recovery policy command should be deduplicated");
	    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-goal-manager-resource-health.sh static").length === 1, "GoalManager resource health focused command should be deduplicated");
	    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-swarm-ready-gate.sh").length === 1, "GoalManager resource health ready-gate command should be deduplicated");
	    assert(report.usedVerifyFastFallback === false, "known GoalManager resource health input should not use verify-fast fallback");
	    assert(logHas("scripts/test-resource-guard-policy.sh"), "fake GoalManager resource health policy command should execute");
	    assert(logHas("scripts/test-resource-recovery-policy.sh"), "fake GoalManager resource recovery policy command should execute");
	    assert(logHas("scripts/test-goal-manager-resource-health.sh"), "fake GoalManager resource health focused command should execute");
    assert(!logHas("scripts/test-host-runtime.sh"), "fake GoalManager resource health should not execute host runtime command");
    assert(logHas("scripts/test-swarm-ready-gate.sh"), "fake GoalManager resource health ready-gate command should execute");
    break;
  case "goal-manager-generated-cleanup-health":
    assert(report.changedFiles.includes("examples/swarm-native/GoalManagerGeneratedCleanupHealth.clasp"), "GoalManager generated cleanup health source should be present");
    assert(report.changedFiles.includes("examples/swarm-native/GoalManagerGeneratedCleanupHealthHarness.clasp"), "GoalManager generated cleanup health harness should be present");
    assert(report.changedFiles.includes("scripts/test-goal-manager-generated-cleanup-health.sh"), "GoalManager generated cleanup health script should be present");
    assert(hasCommand("bash scripts/test-goal-manager-generated-cleanup-health.sh static"), "GoalManager generated cleanup health should run focused static coverage");
    assert(hasCommand("bash scripts/test-generated-state-cleanup-plan-static.sh"), "GoalManager generated cleanup health should keep cleanup-plan contract coverage");
    assert(hasCommand("bash scripts/test-swarm-ready-gate.sh"), "GoalManager generated cleanup health should keep the structural swarm gate");
    assert(!hasCommand("bash scripts/test-goal-manager-resource-health.sh static"), "GoalManager generated cleanup health should avoid the heavier resource-health coverage");
    assert(!hasCommand("bash scripts/test-generated-state-cleanup-plan.sh"), "GoalManager generated cleanup health should avoid the heavier runtime cleanup plan test");
    assert(!hasCommand("bash scripts/test-native-claspc.sh"), "GoalManager generated cleanup health should avoid broad native claspc coverage");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-goal-manager-generated-cleanup-health.sh static").length === 1, "GoalManager generated cleanup health focused command should be deduplicated");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-generated-state-cleanup-plan-static.sh").length === 1, "GoalManager generated cleanup health cleanup-plan command should be deduplicated");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-swarm-ready-gate.sh").length === 1, "GoalManager generated cleanup health ready-gate command should be deduplicated");
    assert(report.usedVerifyFastFallback === false, "known GoalManager generated cleanup health input should not use verify-fast fallback");
    assert(findCommand("bash scripts/test-goal-manager-generated-cleanup-health.sh static")?.resourceClass === "static", "GoalManager generated cleanup health command should be classified as static");
    assert(findCommand("bash scripts/test-goal-manager-generated-cleanup-health.sh static")?.oomRisk === "low", "GoalManager generated cleanup health command should be low OOM risk");
    assert(findCommand("bash scripts/test-goal-manager-generated-cleanup-health.sh static")?.requiresManagedGuard === false, "GoalManager generated cleanup health command should not require managed guard");
    assert(logHas("scripts/test-goal-manager-generated-cleanup-health.sh"), "fake GoalManager generated cleanup health focused command should execute");
    assert(logHas("scripts/test-generated-state-cleanup-plan-static.sh"), "fake GoalManager generated cleanup health cleanup-plan command should execute");
    assert(logHas("scripts/test-swarm-ready-gate.sh"), "fake GoalManager generated cleanup health ready-gate command should execute");
    break;
  case "goal-manager-mailbox-capability-details":
    assert(report.changedFiles.includes("examples/swarm-native/GoalManagerCapabilityMailbox.clasp"), "GoalManager capability mailbox helper should be present");
    assert(report.changedFiles.includes("examples/swarm-native/GoalManagerMailboxMessages.clasp"), "GoalManager mailbox messages source should be present");
    assert(report.changedFiles.includes("examples/swarm-native/GoalManagerMailboxCapabilityHarness.clasp"), "GoalManager mailbox capability harness should be present");
    assert(hasCommand("bash scripts/test-goal-manager-mailbox-capability-details.sh"), "GoalManager mailbox capability path should run focused mailbox capability coverage");
    assert(hasCommand("bash scripts/test-swarm-ready-gate.sh"), "GoalManager mailbox capability path should keep the structural swarm gate");
    assert(!hasCommand("bash scripts/test-native-claspc.sh"), "GoalManager mailbox capability path should avoid broad native claspc coverage");
    assert(!hasCommand("CLASP_GOAL_MANAGER_FAST_CACHE_PROBE_ONLY=1 bash scripts/test-goal-manager-fast.sh"), "GoalManager mailbox capability path should avoid broad GoalManager fast coverage");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-goal-manager-mailbox-capability-details.sh").length === 1, "GoalManager mailbox capability command should be deduplicated");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-swarm-ready-gate.sh").length === 1, "GoalManager mailbox capability ready-gate command should be deduplicated");
    assert(report.usedVerifyFastFallback === false, "known GoalManager mailbox capability input should not use verify-fast fallback");
    assert(logHas("scripts/test-goal-manager-mailbox-capability-details.sh"), "fake GoalManager mailbox capability focused command should execute");
    assert(logHas("scripts/test-swarm-ready-gate.sh"), "fake GoalManager mailbox capability ready-gate command should execute");
    break;
  case "resource-guard-policy-script":
    assert(report.changedFiles.includes("scripts/test-resource-guard-policy.sh"), "resource guard policy test should be present");
    assert(hasCommand("bash -n 'scripts/test-resource-guard-policy.sh'"), "resource guard policy test should run shell syntax check");
    assert(hasCommand("bash scripts/test-resource-guard-policy.sh"), "resource guard policy test should run static coverage");
    assert(hasCommand("bash scripts/test-swarm-ready-gate.sh"), "resource guard policy test should retain structural ready-gate coverage");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-resource-guard-policy.sh").length === 1, "resource guard policy command should be deduplicated");
    assert(findCommand("bash scripts/test-resource-guard-policy.sh")?.resourceClass === "static", "resource guard policy command should be static");
    assert(findCommand("bash scripts/test-resource-guard-policy.sh")?.oomRisk === "low", "resource guard policy command should be low OOM risk");
    assert(findCommand("bash scripts/test-resource-guard-policy.sh")?.requiresManagedGuard === false, "resource guard policy command should not require managed guard");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-swarm-ready-gate.sh").length === 1, "resource guard policy ready-gate command should be deduplicated");
    assert(report.usedVerifyFastFallback === false, "known resource guard policy test input should not use verify-fast fallback");
    assert(logHas("scripts/test-resource-guard-policy.sh"), "fake resource guard policy command should execute");
    assert(logHas("scripts/test-swarm-ready-gate.sh"), "fake resource guard policy ready-gate should execute");
    break;
  case "generated-state-cleanup-program":
    assert(report.changedFiles.includes("examples/swarm-native/GeneratedStateCleanupPlan.clasp"), "Clasp generated-state cleanup plan should be present");
    assert(hasCommand("bash scripts/test-generated-state-cleanup.sh"), "Clasp generated-state cleanup plan should run focused cleanup coverage");
    assert(hasCommand("bash scripts/test-generated-state-cleanup-plan-static.sh"), "Clasp generated-state cleanup plan should run fast cleanup-plan contract coverage");
    assert(hasCommand("bash scripts/test-swarm-ready-gate.sh"), "Clasp generated-state cleanup plan should keep the structural swarm gate");
    assert(!hasCommand("bash scripts/test-generated-state-cleanup-plan.sh"), "Clasp generated-state cleanup plan should avoid the heavier ordinary Clasp runtime cleanup plan test");
    assert(!hasCommand("bash scripts/test-native-claspc.sh"), "Clasp generated-state cleanup plan should avoid broad native claspc coverage");
    assert(!hasCommand("bash scripts/test-swarm-memory.sh"), "Clasp generated-state cleanup plan should avoid unrelated swarm memory coverage");
    assert(!hasCommand("bash scripts/verify-runtime-slice.sh managed-loop"), "Clasp generated-state cleanup plan should avoid unrelated managed-loop coverage");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-generated-state-cleanup.sh").length === 1, "Clasp generated-state cleanup command should be deduplicated");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-generated-state-cleanup-plan-static.sh").length === 1, "Clasp generated-state cleanup plan static command should be deduplicated");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-swarm-ready-gate.sh").length === 1, "Clasp generated-state cleanup ready-gate command should be deduplicated");
    assert(report.usedVerifyFastFallback === false, "known Clasp generated-state cleanup plan input should not use verify-fast fallback");
    assert(logHas("scripts/test-generated-state-cleanup.sh"), "fake generated-state cleanup command should execute");
    assert(logHas("scripts/test-generated-state-cleanup-plan-static.sh"), "fake generated-state cleanup plan static command should execute");
    assert(!logHas("scripts/test-generated-state-cleanup-plan.sh"), "fake generated-state cleanup plan runtime command should not execute");
    assert(logHas("scripts/test-swarm-ready-gate.sh"), "fake generated-state cleanup ready-gate command should execute");
    break;
  case "generated-state-cleanup-plan-script":
    assert(report.changedFiles.includes("scripts/test-generated-state-cleanup-plan.sh"), "generated cleanup plan runtime test should be present");
    assert(hasCommand("bash -n 'scripts/test-generated-state-cleanup-plan.sh'"), "generated cleanup plan test should run shell syntax check");
    assert(hasCommand("bash scripts/test-generated-state-cleanup-plan-static.sh"), "generated cleanup plan test should run the fast static contract");
    assert(hasCommand("bash scripts/test-swarm-ready-gate.sh"), "generated cleanup plan test should keep the structural swarm gate");
    assert(!hasCommand("bash scripts/test-generated-state-cleanup-plan.sh"), "generated cleanup plan test should avoid the heavier runtime test in affected verification");
    assert(!hasCommand("bash scripts/test-managed-job.sh"), "generated cleanup plan test should avoid unrelated managed job coverage");
    assert(!hasCommand("bash scripts/test-native-claspc.sh"), "generated cleanup plan test should avoid broad native claspc coverage");
    assert(report.usedVerifyFastFallback === false, "known generated cleanup plan test should not use verify-fast fallback");
    assert(logHas("scripts/test-generated-state-cleanup-plan-static.sh"), "fake generated cleanup plan static test should execute");
    assert(!logHasExact("scripts/test-generated-state-cleanup-plan.sh"), "fake generated cleanup plan runtime test should not execute");
    assert(logHas("scripts/test-swarm-ready-gate.sh"), "fake generated cleanup plan ready-gate command should execute");
    break;
  case "generated-state-cleanup-plan-static-script":
    assert(report.changedFiles.includes("scripts/test-generated-state-cleanup-plan-static.sh"), "generated cleanup plan static test should be present");
    assert(hasCommand("bash -n 'scripts/test-generated-state-cleanup-plan-static.sh'"), "generated cleanup plan static test should run shell syntax check");
    assert(hasCommand("bash scripts/test-generated-state-cleanup-plan-static.sh"), "generated cleanup plan static test should run itself");
    assert(hasCommand("bash scripts/test-swarm-ready-gate.sh"), "generated cleanup plan static test should keep the structural swarm gate");
    assert(!hasCommand("bash scripts/test-generated-state-cleanup-plan.sh"), "generated cleanup plan static test should avoid the heavier runtime cleanup plan test");
    assert(!hasCommand("bash scripts/test-managed-job.sh"), "generated cleanup plan static test should avoid unrelated managed job coverage");
    assert(!hasCommand("bash scripts/test-native-claspc.sh"), "generated cleanup plan static test should avoid broad native claspc coverage");
    assert(report.usedVerifyFastFallback === false, "known generated cleanup plan static test should not use verify-fast fallback");
    assert(findCommand("bash scripts/test-generated-state-cleanup-plan-static.sh")?.resourceClass === "static", "generated cleanup plan static harness should be classified as static");
    assert(findCommand("bash scripts/test-generated-state-cleanup-plan-static.sh")?.oomRisk === "low", "generated cleanup plan static harness should be low OOM risk");
    assert(findCommand("bash scripts/test-generated-state-cleanup-plan-static.sh")?.requiresManagedGuard === false, "generated cleanup plan static harness should not require managed guard");
    assert(logHas("scripts/test-generated-state-cleanup-plan-static.sh"), "fake generated cleanup plan static test should execute");
    assert(!logHas("scripts/test-generated-state-cleanup-plan.sh"), "fake generated cleanup plan runtime test should not execute");
    assert(logHas("scripts/test-swarm-ready-gate.sh"), "fake generated cleanup plan static ready-gate command should execute");
    break;
  case "local-routing":
    assert(report.changedFiles.includes("examples/swarm-native/LocalRouting.clasp"), "local routing source should be present");
    assert(report.changedFiles.includes("examples/swarm-native/LocalRoutingHarness.clasp"), "local routing harness should be present");
    assert(hasCommand("bash scripts/test-agent-command-template.sh"), "local routing should run focused local agent/template coverage");
    assert(hasCommand("bash scripts/test-goal-manager-agent-command-template.sh"), "local routing should run focused GoalManager planner coverage");
    assert(hasCommand("bash scripts/test-swarm-ready-gate.sh"), "local routing should keep the structural swarm gate");
    assert(!hasCommand("bash scripts/test-native-claspc.sh"), "local routing should avoid broad native claspc coverage");
    assert(!hasCommand("bash scripts/test-swarm-memory.sh"), "local routing should avoid unrelated swarm memory coverage");
    assert(!hasCommand("bash scripts/verify-runtime-slice.sh managed-loop"), "local routing should avoid unrelated managed-loop coverage");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-agent-command-template.sh").length === 1, "local routing agent-template command should be deduplicated");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-goal-manager-agent-command-template.sh").length === 1, "local routing GoalManager command should be deduplicated");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-swarm-ready-gate.sh").length === 1, "local routing ready-gate command should be deduplicated");
    assert(report.usedVerifyFastFallback === false, "known local routing inputs should not use verify-fast fallback");
    assert(logHas("scripts/test-agent-command-template.sh"), "fake local routing agent-template command should execute");
    assert(logHas("scripts/test-goal-manager-agent-command-template.sh"), "fake local routing GoalManager command should execute");
    assert(logHas("scripts/test-swarm-ready-gate.sh"), "fake local routing ready-gate command should execute");
    break;
  case "standalone-swarm-surfaces":
    assert(report.changedFiles.includes("src/StandaloneSwarmReadiness.clasp"), "standalone readiness source should be present");
    assert(report.changedFiles.includes("src/StandaloneSwarmVerifier.clasp"), "standalone verifier source should be present");
    assert(report.changedFiles.includes("examples/swarm-native/StandaloneSwarmHarness.clasp"), "standalone harness surface should be present");
    assert(report.changedFiles.includes("examples/swarm-native/StandaloneSwarmRouting.clasp"), "standalone routing surface should be present");
    assert(report.changedFiles.includes("examples/swarm-native/StandaloneSwarmClosureReport.clasp"), "standalone closure report surface should be present");
    assert(report.changedFiles.includes("examples/swarm-native/StandaloneSwarmClosureReportHarness.clasp"), "standalone closure report harness should be present");
    assert(report.changedFiles.includes("scripts/standalone-swarm-readiness.sh"), "standalone readiness script should be present");
    assert(report.changedFiles.includes("scripts/standalone-swarm-verify.sh"), "standalone verifier script should be present");
    assert(report.changedFiles.includes("scripts/test-standalone-swarm-surfaces.sh"), "standalone surface test should be present");
    assert(report.changedFiles.includes("docs/standalone-swarm-readiness.md"), "standalone readiness doc should be present");
    assert(report.changedFiles.includes("runtime/standalone_swarm_probe.rs"), "standalone runtime probe should be present");
    assert(hasCommand("bash -n 'scripts/standalone-swarm-readiness.sh'"), "standalone readiness script should run shell syntax check");
    assert(hasCommand("bash -n 'scripts/standalone-swarm-verify.sh'"), "standalone verifier script should run shell syntax check");
    assert(hasCommand("bash -n 'scripts/test-standalone-swarm-surfaces.sh'"), "standalone surface test should run shell syntax check");
    assert(hasCommand("bash scripts/test-standalone-swarm-surfaces.sh"), "standalone surfaces should run focused surface coverage");
    assert(hasCommand("bash scripts/test-swarm-ready-gate.sh"), "standalone surfaces should keep structural swarm-ready coverage");
    assert(!hasCommand("bash scripts/test-native-claspc.sh"), "standalone surfaces should avoid broad native-claspc coverage");
    assert(!hasCommand("bash scripts/test-swarm-memory.sh"), "standalone surfaces should avoid unrelated swarm memory coverage");
    assert(!hasCommand("bash scripts/test-local-agent-capability-closure.sh"), "standalone surfaces should avoid heavyweight local-agent closure compile");
    assert(!hasCommand("CLASP_TEST_SELFHOST_SHARED_CACHE_HOME=.clasp-verify/cache/selfhost bash scripts/test-selfhost.sh"), "standalone surfaces should avoid selfhost coverage");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-standalone-swarm-surfaces.sh").length === 1, "standalone surface command should be deduplicated");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-swarm-ready-gate.sh").length === 1, "standalone ready-gate command should be deduplicated");
    assert(report.usedVerifyFastFallback === false, "known standalone surface inputs should not use verify-fast fallback");
    assert(logHas("scripts/test-standalone-swarm-surfaces.sh"), "fake standalone surface command should execute");
    assert(logHas("scripts/test-swarm-ready-gate.sh"), "fake standalone ready-gate command should execute");
    break;
  case "safe-workspace":
    assert(report.changedFiles.includes("examples/safe-workspace/Main.clasp"), "safe workspace source should be present");
    assert(report.changedFiles.includes("examples/safe-workspace/Workspace.clasp"), "safe workspace wrapper should be present");
    assert(report.changedFiles.includes("examples/safe-workspace/SafeWorkspaceHarness.clasp"), "safe workspace report harness should be present");
    assert(report.changedFiles.includes("scripts/test-safe-workspace.sh"), "safe workspace harness should be present");
    assert(hasCommand("bash -n 'scripts/test-safe-workspace.sh'"), "safe workspace harness should run shell syntax check");
    assert(hasCommand("bash scripts/test-safe-workspace-static.sh"), "safe workspace route should run fast host-binding contract coverage");
    assert(hasCommand("bash scripts/test-safe-workspace.sh"), "safe workspace source route should run focused scenario coverage");
    assert(hasCommand("bash scripts/verify-runtime-slice.sh workspace"), "safe workspace route should run focused runtime slice coverage");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-safe-workspace-static.sh").length === 1, "safe workspace static contract should be deduplicated");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/verify-runtime-slice.sh workspace").length === 1, "safe workspace slice should be deduplicated");
    assert(report.usedVerifyFastFallback === false, "known safe workspace inputs should not use verify-fast fallback");
    assert(logHas("scripts/test-safe-workspace-static.sh"), "fake safe workspace static command should execute");
    assert(logHas("scripts/test-safe-workspace.sh"), "fake safe workspace scenario command should execute");
    assert(logHas("scripts/verify-runtime-slice.sh workspace"), "fake safe workspace slice command should execute");
    break;
  case "safe-workspace-static-script":
    assert(report.changedFiles.includes("scripts/test-safe-workspace-static.sh"), "safe workspace static harness should be present");
    assert(hasCommand("bash -n 'scripts/test-safe-workspace-static.sh'"), "safe workspace static harness should run shell syntax check");
    assert(hasCommand("bash scripts/test-safe-workspace-static.sh"), "safe workspace static harness should run fast host-binding coverage");
    assert(hasCommand("bash scripts/test-swarm-ready-gate.sh"), "safe workspace static harness should keep structural swarm coverage");
    assert(!hasCommand("bash scripts/verify-runtime-slice.sh workspace"), "safe workspace static harness should avoid runtime slice coverage");
    assert(!hasCommand("bash scripts/test-native-claspc.sh"), "safe workspace static harness should avoid broad native claspc coverage");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-safe-workspace-static.sh").length === 1, "safe workspace static command should be deduplicated");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-swarm-ready-gate.sh").length === 1, "safe workspace static ready-gate command should be deduplicated");
    assert(report.usedVerifyFastFallback === false, "known safe workspace static harness should not use verify-fast fallback");
    assert(findCommand("bash scripts/test-safe-workspace-static.sh")?.resourceClass === "static", "safe workspace static harness should be classified as static");
    assert(findCommand("bash scripts/test-safe-workspace-static.sh")?.oomRisk === "low", "safe workspace static harness should be low OOM risk");
    assert(findCommand("bash scripts/test-safe-workspace-static.sh")?.requiresManagedGuard === false, "safe workspace static harness should not require managed guard");
    assert(logHas("scripts/test-safe-workspace-static.sh"), "fake safe workspace static command should execute");
    assert(logHas("scripts/test-swarm-ready-gate.sh"), "fake safe workspace static ready-gate command should execute");
    break;
  case "safe-subprocess":
    assert(report.changedFiles.includes("examples/safe-subprocess/Main.clasp"), "safe subprocess source should be present");
    assert(report.changedFiles.includes("examples/safe-subprocess/Process.clasp"), "safe subprocess wrapper should be present");
    assert(report.changedFiles.includes("scripts/test-safe-subprocess.sh"), "safe subprocess harness should be present");
    assert(hasCommand("bash -n 'scripts/test-safe-subprocess.sh'"), "safe subprocess harness should run shell syntax check");
    assert(hasCommand("bash scripts/verify-runtime-slice.sh process"), "safe subprocess harness should run focused process runtime slice coverage");
    assert(hasCommand("bash scripts/test-safe-subprocess.sh"), "safe subprocess source route should run focused scenario coverage");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/verify-runtime-slice.sh process").length === 1, "safe subprocess process slice should be deduplicated");
    assert(report.usedVerifyFastFallback === false, "known safe subprocess inputs should not use verify-fast fallback");
    assert(logHas("scripts/verify-runtime-slice.sh process"), "fake safe subprocess process slice command should execute");
    assert(logHas("scripts/test-safe-subprocess.sh"), "fake safe subprocess command should execute");
    break;
  case "source-benchmark-mixed":
    assert(report.changedFiles.includes("src/Compiler/SemanticArtifacts.clasp"), "source context artifact file should be present");
    assert(report.changedFiles.includes("benchmarks/tasks/clasp-lead-segment/repo/Shared/Lead.clasp"), "benchmark app source should be present");
    assert(hasCommand("bash scripts/test-selfhost.sh"), "mixed source+benchmark should keep selfhost/source coverage");
    assert(hasCommand("bash src/scripts/verify.sh"), "mixed source+benchmark should keep hosted source verification");
    assert(hasCommand("bash benchmarks/test-task-prep.sh"), "mixed source+benchmark should run benchmark prep coverage");
    assert(hasCommand("benchmarks/tasks/clasp-lead-segment/repo/scripts/verify.sh"), "mixed source+benchmark should run task app-flow verification");
    assert(report.selectedCommands.filter((command) => command.command === "bash benchmarks/test-task-prep.sh").length === 1, "benchmark prep command should be deduplicated");
    assert(report.usedVerifyFastFallback === false, "known source+benchmark inputs should not use verify-fast fallback");
    break;
  case "app-context-plan":
    assert(report.planOnly === true, "context scenario should be plan-only");
    assert(report.finalVerdict === "planned", `expected planned verdict, got ${report.finalVerdict}`);
    assert(report.executedCommandCount === 0, "plan-only should not execute commands");
    assert(report.changedFiles.includes("examples/lead-app/Shared/Lead.clasp"), "app source should be normalized");
    assert(hasCommand("bash examples/lead-app/scripts/verify.sh"), "context-aware app route should include app-flow verifier");
    assert(!hasCommand("bash scripts/test-selfhost.sh"), "app-only route should avoid source/compiler selfhost coverage");
    assert(report.semanticContextArtifacts.some((artifact) => artifact.path === "examples/lead-app/benchmark-prep/Main.context.json" && artifact.status === "ok"), "context artifact should be recorded");
    assert(report.semanticContextByChangedFile.some((entry) => entry.file === "examples/lead-app/Shared/Lead.clasp" && entry.artifactPaths.includes("examples/lead-app/benchmark-prep/Main.context.json")), "changed file should be linked to context artifact");
    assert(report.planExplanations.length > 0, "plan-only report should include semantic explanations");
    {
      const explanation = JSON.stringify(report.planExplanations);
      assert(explanation.includes("route:createLeadRecordRoute"), "plan explanation should name affected route surface");
      assert(explanation.includes("schema:LeadIntake"), "plan explanation should name request schema surface");
      assert(explanation.includes("decl:summarizeLead"), "plan explanation should name affected declaration surface");
      assert(explanation.includes("foreign:mockLeadSummaryModel"), "plan explanation should name foreign boundary surface");
    }
    break;
  case "goal-manager-fast-script":
    assert(report.changedFiles.includes("scripts/test-goal-manager-fast.sh"), "GoalManager harness should be present");
    assert(report.changedFiles.includes("scripts/test-swarm-ready-gate.sh"), "swarm-ready harness should be present");
    assert(hasCommand("bash -n 'scripts/test-goal-manager-fast.sh'"), "GoalManager harness should run shell syntax check");
    assert(hasCommand("CLASP_GOAL_MANAGER_FAST_CACHE_PROBE_ONLY=1 bash scripts/test-goal-manager-fast.sh"), "GoalManager harness should run focused cache-probe coverage");
    assert(hasCommand("bash -n 'scripts/test-swarm-ready-gate.sh'"), "swarm-ready harness should run shell syntax check");
    assert(hasCommand("bash scripts/test-swarm-ready-gate.sh"), "swarm-ready harness should run focused coverage");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-swarm-ready-gate.sh").length === 1, "swarm-ready command should be deduplicated");
    assert(report.usedVerifyFastFallback === false, "known focused harnesses should not use verify-fast fallback");
    assert(findCommand("CLASP_GOAL_MANAGER_FAST_CACHE_PROBE_ONLY=1 bash scripts/test-goal-manager-fast.sh")?.resourceClass === "static", "GoalManager cache-probe-only command should be classified as static");
    assert(findCommand("CLASP_GOAL_MANAGER_FAST_CACHE_PROBE_ONLY=1 bash scripts/test-goal-manager-fast.sh")?.oomRisk === "low", "GoalManager cache-probe-only command should be low OOM risk");
    assert(findCommand("CLASP_GOAL_MANAGER_FAST_CACHE_PROBE_ONLY=1 bash scripts/test-goal-manager-fast.sh")?.requiresManagedGuard === false, "GoalManager cache-probe-only command should not require managed execution");
    assert(findCommand("CLASP_GOAL_MANAGER_FAST_CACHE_PROBE_ONLY=1 bash scripts/test-goal-manager-fast.sh")?.compilerStateAccess === "temporary-cache-probe", "GoalManager cache-probe-only command should expose temporary cache-probe state access");
    assert(report.commandResourceSummary.compilerStateTouchingCommandCount === 1, "GoalManager cache-probe route should expose one temporary compiler-state access command");
    assert(report.commandResourceSummary.canRunWithoutCompilerState === false, "GoalManager cache-probe route should not be compiler-state-free");
    assert(report.commandResourceSummary.requiresManagedGuard === false, "GoalManager cache-probe route should be safe-direct");
    assert(report.commandResourceSummary.overallAdvice === "safe-direct", "GoalManager cache-probe route should advise direct execution");
    assert(report.affectedVerificationLaunchPolicy.mode === "direct-compiler-state-access", `GoalManager cache-probe launch mode ${report.affectedVerificationLaunchPolicy.mode}`);
    assert(report.affectedVerificationLaunchPolicy.ready === false, "GoalManager cache-probe launch policy should require preflight");
    assert(report.affectedVerificationLaunchPolicy.canRunDirect === true, "GoalManager cache-probe launch policy should allow direct run");
    assert(report.affectedVerificationLaunchPolicy.recommendation === "affected-verification-launch:direct-compiler-state-access-preflight", `GoalManager cache-probe launch recommendation ${report.affectedVerificationLaunchPolicy.recommendation}`);
    assert(report.affectedVerificationLaunchPolicy.blockingGaps.includes("affected verifier plan touches compiler/cache state before launch"), "GoalManager cache-probe launch policy should expose compiler/cache state gap");
    assert(report.affectedVerificationLaunchPolicy.requiredClosure.includes("affected-verification-plan:safe-direct-compiler-state-access"), "GoalManager cache-probe launch policy should require compiler-state-access closure");
    assert(logHas("scripts/test-goal-manager-fast.sh"), "fake GoalManager fast command should execute");
    assert(logHas("scripts/test-swarm-ready-gate.sh"), "fake swarm-ready command should execute");
    break;
  case "swarm-ready-benchmark-script":
    assert(report.changedFiles.includes("scripts/test-swarm-ready-benchmark.sh"), "swarm-ready benchmark harness should be present");
    assert(hasCommand("bash -n 'scripts/test-swarm-ready-benchmark.sh'"), "swarm-ready benchmark harness should run shell syntax check");
    assert(hasCommand("CLASP_SWARM_READY_BENCHMARK_TIMEOUT_SECS=700 bash scripts/test-swarm-ready-benchmark.sh"), "swarm-ready benchmark harness should run focused native coverage");
    assert(report.selectedCommands.filter((command) => command.command === "CLASP_SWARM_READY_BENCHMARK_TIMEOUT_SECS=700 bash scripts/test-swarm-ready-benchmark.sh").length === 1, "swarm-ready benchmark command should be deduplicated");
    assert(report.usedVerifyFastFallback === false, "known swarm-ready benchmark harness should not use verify-fast fallback");
    assert(logHas("scripts/test-swarm-ready-benchmark.sh"), "fake swarm-ready benchmark command should execute");
    break;
  case "swarm-capability-audit-script":
    assert(report.changedFiles.includes("scripts/test-swarm-capability-audit.sh"), "swarm capability audit harness should be present");
    assert(hasCommand("bash -n 'scripts/test-swarm-capability-audit.sh'"), "swarm capability audit harness should run shell syntax check");
    assert(hasCommand("bash scripts/test-swarm-ready-gate.sh"), "swarm capability audit harness should retain structural ready-gate coverage");
    assert(hasCommand("bash scripts/test-swarm-capability-audit.sh"), "swarm capability audit harness should run focused static audit coverage");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-swarm-capability-audit.sh").length === 1, "swarm capability audit command should be deduplicated");
    assert(report.usedVerifyFastFallback === false, "known swarm capability audit harness should not use verify-fast fallback");
    assert(logHas("scripts/test-swarm-capability-audit.sh"), "fake swarm capability audit command should execute");
    break;
  case "swarm-policy-helpers-script":
    assert(report.changedFiles.includes("scripts/test-swarm-policy-helpers.sh"), "swarm policy helper harness should be present");
    assert(report.changedFiles.includes("scripts/clasp-network-egress-enforcer.mjs"), "network egress enforcer should be present");
    assert(report.changedFiles.includes("scripts/clasp-network-egress-backend.mjs"), "network egress backend should be present");
    assert(report.changedFiles.includes("scripts/clasp-network-egress-kernel-backend.mjs"), "network kernel egress backend should be present");
    assert(report.changedFiles.includes("scripts/clasp-network-egress-guard.c"), "network egress guard should be present");
    assert(report.changedFiles.includes("scripts/clasp-filesystem-write-enforcer.mjs"), "filesystem write enforcer should be present");
    assert(report.changedFiles.includes("scripts/clasp-filesystem-write-kernel-backend.mjs"), "filesystem kernel backend should be present");
    assert(report.changedFiles.includes("scripts/clasp-filesystem-write-guard.c"), "filesystem write guard should be present");
    assert(report.changedFiles.includes("scripts/test-swarm-destructive-policy.sh"), "destructive policy harness should be present");
    assert(report.changedFiles.includes("scripts/test-swarm-filesystem-kernel-policy.sh"), "filesystem kernel policy harness should be present");
    assert(hasCommand("bash -n 'scripts/test-swarm-policy-helpers.sh'"), "swarm policy helper harness should run shell syntax check");
    assert(hasCommand("bash -n 'scripts/test-swarm-destructive-policy.sh'"), "destructive policy harness should run shell syntax check");
    assert(hasCommand("bash -n 'scripts/test-swarm-filesystem-kernel-policy.sh'"), "filesystem kernel policy harness should run shell syntax check");
    assert(hasCommand("node --check 'scripts/clasp-network-egress-enforcer.mjs'"), "network egress enforcer should run node syntax check");
    assert(hasCommand("node --check 'scripts/clasp-network-egress-backend.mjs'"), "network egress backend should run node syntax check");
    assert(hasCommand("node --check 'scripts/clasp-network-egress-kernel-backend.mjs'"), "network kernel egress backend should run node syntax check");
    assert(hasCommand("cc -fsyntax-only 'scripts/clasp-network-egress-guard.c'"), "network egress guard should run C syntax check");
    assert(hasCommand("node --check 'scripts/clasp-filesystem-write-enforcer.mjs'"), "filesystem write enforcer should run node syntax check");
    assert(hasCommand("node --check 'scripts/clasp-filesystem-write-kernel-backend.mjs'"), "filesystem kernel backend should run node syntax check");
    assert(hasCommand("cc -fsyntax-only 'scripts/clasp-filesystem-write-guard.c'"), "filesystem write guard should run C syntax check");
    assert(hasCommand("bash scripts/test-swarm-policy-helpers.sh"), "swarm policy helper harness should run focused ordinary Clasp coverage");
    assert(hasCommand("bash scripts/test-swarm-destructive-policy.sh"), "filesystem write mediator should run destructive filesystem policy coverage");
    assert(hasCommand("bash scripts/test-swarm-filesystem-kernel-policy.sh"), "filesystem kernel backend should run direct-syscall policy coverage");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-swarm-policy-helpers.sh").length === 1, "swarm policy helper command should be deduplicated");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-swarm-destructive-policy.sh").length === 1, "destructive policy command should be deduplicated");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-swarm-filesystem-kernel-policy.sh").length === 1, "filesystem kernel policy command should be deduplicated");
    assert(report.usedVerifyFastFallback === false, "known swarm policy helper harness should not use verify-fast fallback");
    assert(logHas("scripts/test-swarm-policy-helpers.sh"), "fake swarm policy helper command should execute");
    assert(logHas("scripts/test-swarm-destructive-policy.sh"), "fake swarm destructive policy command should execute");
    assert(logHas("scripts/test-swarm-filesystem-kernel-policy.sh"), "fake swarm filesystem kernel policy command should execute");
    break;
  case "swarm-policy-helpers-program":
    assert(
      report.changedFiles.some((file) =>
        file === "examples/swarm-native/CapabilityPolicyHarness.clasp" ||
        file === "examples/swarm-native/PolicyHarness.clasp" ||
        file === "examples/swarm-native/GoalManagerTaskPolicyHarness.clasp"
      ),
      "swarm policy helper program should be present",
    );
    assert(hasCommand("bash scripts/test-swarm-policy-helpers.sh"), "policy helper program should run focused ordinary Clasp coverage");
    assert(hasCommand("bash scripts/test-swarm-ready-gate.sh"), "policy helper program should retain structural ready-gate coverage");
    assert(!hasCommand("bash scripts/test-native-claspc.sh"), "focused policy helper program should avoid broad native-claspc coverage");
    assert(!hasCommand("bash scripts/verify-runtime-slice.sh managed-loop"), "focused policy helper program should avoid unrelated managed-loop coverage");
    assert(!hasCommand("bash scripts/test-swarm-memory.sh"), "focused policy helper program should avoid standalone memory coverage");
    assert(!hasCommand("bash scripts/test-swarm-context-pack.sh"), "focused policy helper program should avoid context-pack coverage");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-swarm-policy-helpers.sh").length === 1, "policy helper program should deduplicate focused coverage");
    assert(report.usedVerifyFastFallback === false, "known policy helper program should not use verify-fast fallback");
    assert(logHas("scripts/test-swarm-policy-helpers.sh"), "fake policy helper command should execute");
    break;
  case "swarm-priority-script":
    assert(report.changedFiles.includes("scripts/test-swarm-priority.sh"), "swarm priority harness should be present");
    assert(hasCommand("bash -n 'scripts/test-swarm-priority.sh'"), "swarm priority harness should run shell syntax check");
    assert(hasCommand("bash scripts/test-swarm-priority.sh"), "swarm priority harness should run focused ordinary Clasp coverage");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-swarm-priority.sh").length === 1, "swarm priority command should be deduplicated");
    assert(report.usedVerifyFastFallback === false, "known swarm priority harness should not use verify-fast fallback");
    assert(logHas("scripts/test-swarm-priority.sh"), "fake swarm priority command should execute");
    break;
  case "swarm-priority-program":
    assert(report.changedFiles.includes("examples/swarm-native/PriorityHarness.clasp"), "swarm priority program should be present");
    assert(hasCommand("bash scripts/test-swarm-priority.sh"), "priority program should run focused ordinary Clasp coverage");
    assert(hasCommand("bash scripts/test-swarm-ready-gate.sh"), "priority program should retain structural ready-gate coverage");
    assert(!hasCommand("bash scripts/test-native-claspc.sh"), "focused priority program should avoid broad native-claspc coverage");
    assert(!hasCommand("bash scripts/verify-runtime-slice.sh managed-loop"), "focused priority program should avoid unrelated managed-loop coverage");
    assert(!hasCommand("bash scripts/test-swarm-memory.sh"), "focused priority program should avoid standalone memory coverage");
    assert(!hasCommand("bash scripts/test-swarm-context-pack.sh"), "focused priority program should avoid context-pack coverage");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-swarm-priority.sh").length === 1, "priority program should deduplicate focused coverage");
    assert(report.usedVerifyFastFallback === false, "known priority program should not use verify-fast fallback");
    assert(logHas("scripts/test-swarm-priority.sh"), "fake priority command should execute");
    break;
  case "swarm-ready-benchmark-program":
    assert(report.changedFiles.includes("examples/swarm-native/SwarmReadyBenchmark.clasp"), "swarm-ready benchmark program should be present");
    assert(hasCommand("bash scripts/test-native-claspc.sh"), "benchmark program should retain native claspc coverage");
    assert(hasCommand("bash scripts/test-swarm-ready-gate.sh"), "benchmark program should retain structural ready-gate coverage");
    assert(hasCommand("CLASP_SWARM_READY_BENCHMARK_TIMEOUT_SECS=700 bash scripts/test-swarm-ready-benchmark.sh"), "benchmark program should run focused native readiness coverage");
    assert(report.selectedCommands.filter((command) => command.command === "CLASP_SWARM_READY_BENCHMARK_TIMEOUT_SECS=700 bash scripts/test-swarm-ready-benchmark.sh").length === 1, "benchmark program should deduplicate focused coverage");
    assert(report.usedVerifyFastFallback === false, "known swarm-ready benchmark program should not use verify-fast fallback");
    assert(logHas("scripts/test-swarm-ready-benchmark.sh"), "fake swarm-ready benchmark command should execute");
    break;
  case "swarm-capability-audit-program":
    assert(report.changedFiles.includes("examples/swarm-native/SwarmCapabilityAudit.clasp"), "swarm capability audit program should be present");
    assert(hasCommand("bash scripts/test-swarm-ready-gate.sh"), "swarm capability audit program should retain structural ready-gate coverage");
    assert(hasCommand("bash scripts/test-swarm-capability-audit.sh"), "swarm capability audit program should run focused static audit coverage");
    assert(!hasCommand("bash scripts/test-native-claspc.sh"), "swarm capability audit program should avoid broad native-claspc coverage");
    assert(!hasCommand("bash scripts/test-swarm-memory.sh"), "swarm capability audit program should avoid unrelated swarm memory coverage");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-swarm-capability-audit.sh").length === 1, "swarm capability audit program should deduplicate focused coverage");
    assert(report.usedVerifyFastFallback === false, "known swarm capability audit program should not use verify-fast fallback");
    assert(logHas("scripts/test-swarm-capability-audit.sh"), "fake swarm capability audit command should execute");
    break;
  case "swarm-capability-audit-doc":
    assert(report.changedFiles.includes("docs/autonomous-swarm-runtime-requirements.md"), "swarm capability audit requirements doc should be present");
    assert(hasCommand("bash scripts/test-swarm-ready-gate.sh"), "swarm capability audit doc should retain structural ready-gate coverage");
    assert(hasCommand("bash scripts/test-swarm-capability-audit.sh"), "swarm capability audit doc should run focused static audit coverage");
    assert(findCommand("bash scripts/test-swarm-capability-audit.sh").resourceClass === "static", "static capability audit should be classified as static");
    assert(findCommand("bash scripts/test-swarm-capability-audit.sh").oomRisk === "low", "static capability audit should be low OOM risk");
    assert(!hasCommand("bash scripts/test-native-claspc.sh"), "swarm capability audit doc should avoid broad native-claspc coverage");
    assert(!hasCommand("bash scripts/test-swarm-memory.sh"), "swarm capability audit doc should avoid unrelated swarm memory coverage");
    assert(!hasCommand("bash scripts/test-swarm-priority.sh"), "swarm capability audit doc should avoid unrelated swarm priority coverage");
    assert(!hasCommand("bash scripts/test-swarm-spawn-policy.sh"), "swarm capability audit doc should avoid unrelated swarm spawn-policy coverage");
    assert(!hasCommand("bash scripts/test-swarm-policy-helpers.sh"), "swarm capability audit doc should avoid unrelated swarm policy-helper coverage");
    assert(!hasCommand("bash scripts/test-swarm-destructive-policy.sh"), "swarm capability audit doc should avoid unrelated destructive-policy coverage");
    assert(!hasCommand("bash scripts/test-swarm-filesystem-kernel-policy.sh"), "swarm capability audit doc should avoid unrelated filesystem-kernel coverage");
    assert(!hasCommand("bash scripts/test-swarm-context-pack.sh"), "swarm capability audit doc should avoid unrelated context-pack coverage");
    assert(!hasCommand("bash scripts/test-swarm-semantic-summary-index.sh"), "swarm capability audit doc should avoid unrelated semantic-summary coverage");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-swarm-capability-audit.sh").length === 1, "swarm capability audit doc should deduplicate focused coverage");
    assert(report.commandResourceSummary.staticCommandCount === report.selectedCommands.length, "swarm capability audit doc route should be static-only");
    assert(report.commandResourceSummary.requiresManagedGuard === false, "swarm capability audit doc route should not require managed execution");
    assert(report.commandResourceSummary.overallAdvice === "safe-direct", "swarm capability audit doc route should be safe for direct static execution");
    assert(report.usedVerifyFastFallback === false, "known swarm capability audit doc should not use verify-fast fallback");
    assert(logHas("scripts/test-swarm-capability-audit.sh"), "fake swarm capability audit doc command should execute");
    break;
  case "agent-command-template-script":
    assert(report.changedFiles.includes("scripts/test-agent-command-template.sh"), "agent command template harness should be present");
    assert(hasCommand("bash -n 'scripts/test-agent-command-template.sh'"), "agent command template harness should run shell syntax check");
    assert(hasCommand("bash scripts/test-agent-command-template.sh"), "agent command template harness should run focused prompt coverage");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-agent-command-template.sh").length === 1, "agent command template command should be deduplicated");
    assert(report.usedVerifyFastFallback === false, "known agent command template harness should not use verify-fast fallback");
    assert(logHas("scripts/test-agent-command-template.sh"), "fake agent command template command should execute");
    break;
  case "agent-backend-api":
    assert(report.changedFiles.includes("examples/swarm-native/AgentBackend.clasp"), "agent backend API should be present");
    assert(report.changedFiles.includes("examples/swarm-native/AgentBackendHarness.clasp"), "agent backend harness should be present");
    assert(hasCommand("bash scripts/test-agent-backend-static.sh"), "agent backend API should run fast standalone policy contract coverage");
    assert(hasCommand("bash scripts/verify-runtime-slice.sh swarm-feedback-loop"), "agent backend API should run focused FeedbackLoop coverage");
    assert(hasCommand("bash scripts/test-agent-command-template.sh"), "agent backend API should run local agent command coverage");
    assert(hasCommand("bash scripts/test-goal-manager-agent-command-template.sh"), "agent backend API should run GoalManager provider-neutral coverage");
    assert(hasCommand("bash scripts/test-goal-manager-default-planner-command.sh"), "agent backend API should run default planner command coverage");
    assert(hasCommand("bash scripts/test-swarm-ready-gate.sh"), "agent backend API should keep structural swarm-ready coverage");
    assert(!hasCommand("bash scripts/test-native-claspc.sh"), "agent backend API should avoid broad native-claspc routing");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-agent-backend-static.sh").length === 1, "agent backend static coverage should be deduplicated");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-agent-command-template.sh").length === 1, "agent backend local command coverage should be deduplicated");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-goal-manager-agent-command-template.sh").length === 1, "agent backend GoalManager command coverage should be deduplicated");
    assert(report.usedVerifyFastFallback === false, "known agent backend API should not use verify-fast fallback");
    assert(logHas("scripts/test-agent-backend-static.sh"), "fake agent backend static coverage should execute");
    assert(logHas("scripts/test-agent-command-template.sh"), "fake local agent command coverage should execute");
    assert(logHas("scripts/test-goal-manager-agent-command-template.sh"), "fake GoalManager agent command coverage should execute");
    assert(logHas("scripts/test-goal-manager-default-planner-command.sh"), "fake default planner command coverage should execute");
    assert(logHas("scripts/test-swarm-ready-gate.sh"), "fake swarm-ready command should execute");
    break;
  case "agent-backend-static-script":
    assert(report.changedFiles.includes("scripts/test-agent-backend-static.sh"), "agent backend static harness should be present");
    assert(hasCommand("bash -n 'scripts/test-agent-backend-static.sh'"), "agent backend static harness should run shell syntax check");
    assert(hasCommand("bash scripts/test-agent-backend-static.sh"), "agent backend static harness should run fast standalone policy coverage");
    assert(hasCommand("bash scripts/test-swarm-ready-gate.sh"), "agent backend static harness should keep structural swarm coverage");
    assert(!hasCommand("bash scripts/verify-runtime-slice.sh swarm-feedback-loop"), "agent backend static harness should avoid runtime slice coverage");
    assert(!hasCommand("bash scripts/test-native-claspc.sh"), "agent backend static harness should avoid broad native-claspc coverage");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-agent-backend-static.sh").length === 1, "agent backend static command should be deduplicated");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-swarm-ready-gate.sh").length === 1, "agent backend static ready-gate command should be deduplicated");
    assert(report.usedVerifyFastFallback === false, "known agent backend static harness should not use verify-fast fallback");
    assert(findCommand("bash scripts/test-agent-backend-static.sh")?.resourceClass === "static", "agent backend static harness should be classified as static");
    assert(findCommand("bash scripts/test-agent-backend-static.sh")?.oomRisk === "low", "agent backend static harness should be low OOM risk");
    assert(findCommand("bash scripts/test-agent-backend-static.sh")?.requiresManagedGuard === false, "agent backend static harness should not require managed guard");
    assert(logHas("scripts/test-agent-backend-static.sh"), "fake agent backend static command should execute");
    assert(logHas("scripts/test-swarm-ready-gate.sh"), "fake agent backend static ready-gate command should execute");
    break;
  case "agent-ergonomics":
    assert(report.changedFiles.includes("examples/swarm-native/AgentErgonomics.clasp"), "agent ergonomics source should be present");
    assert(report.changedFiles.includes("examples/swarm-native/AgentErgonomicsHarness.clasp"), "agent ergonomics harness should be present");
    assert(report.changedFiles.includes("scripts/test-agent-ergonomics-helpers.sh"), "agent ergonomics helper test should be present");
    assert(hasCommand("bash -n 'scripts/test-agent-ergonomics-helpers.sh'"), "agent ergonomics helper test should run shell syntax check");
    assert(hasCommand("bash scripts/test-agent-ergonomics-helpers.sh static"), "agent ergonomics route should run static helper coverage");
    assert(findCommand("bash scripts/test-agent-ergonomics-helpers.sh static").resourceClass === "static", "agent ergonomics static route should be classified as static");
    assert(findCommand("bash scripts/test-agent-ergonomics-helpers.sh static").requiresManagedGuard === false, "agent ergonomics static route should not require managed execution");
    assert(hasCommand("bash scripts/test-swarm-ready-gate.sh"), "agent ergonomics route should keep structural swarm-ready coverage");
    assert(!hasCommand("bash scripts/test-native-claspc.sh"), "agent ergonomics route should avoid broad native-claspc coverage");
    assert(!hasCommand("bash scripts/test-swarm-memory.sh"), "agent ergonomics route should avoid unrelated swarm memory coverage");
    assert(!hasCommand("bash scripts/verify-runtime-slice.sh managed-loop"), "agent ergonomics route should avoid unrelated managed-loop coverage");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-agent-ergonomics-helpers.sh static").length === 1, "agent ergonomics command should be deduplicated");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-swarm-ready-gate.sh").length === 1, "agent ergonomics ready-gate command should be deduplicated");
    assert(report.usedVerifyFastFallback === false, "known agent ergonomics inputs should not use verify-fast fallback");
    assert(logHas("scripts/test-agent-ergonomics-helpers.sh"), "fake agent ergonomics command should execute");
    assert(logHas("scripts/test-swarm-ready-gate.sh"), "fake agent ergonomics ready-gate command should execute");
    break;
  case "goal-manager-binary-helper":
    assert(report.changedFiles.includes("scripts/ensure-goal-manager-binary.sh"), "GoalManager binary helper should be present");
    assert(hasCommand("bash -n 'scripts/ensure-goal-manager-binary.sh'"), "GoalManager binary helper should run shell syntax check");
    assert(hasCommand("bash scripts/test-verify-all.sh"), "GoalManager binary helper should run focused cache/stale regression coverage");
    assert(!hasCommand("bash scripts/test-selfhost.sh"), "GoalManager binary helper route should avoid broad selfhost coverage");
    assert(report.usedVerifyFastFallback === false, "known GoalManager binary helper should not use verify-fast fallback");
    assert(logHas("scripts/test-verify-all.sh"), "fake verify-all regression command should execute");
    break;
  case "verify-all-smoke-script":
    assert(report.changedFiles.includes("scripts/test-verify-all-smoke.sh"), "verify-all smoke harness should be present");
    assert(hasCommand("bash -n 'scripts/test-verify-all-smoke.sh'"), "verify-all smoke harness should run shell syntax check");
    assert(hasCommand("bash scripts/test-verify-all-smoke.sh"), "verify-all smoke harness should run direct smoke coverage");
    assert(!hasCommand("bash scripts/test-verify-all.sh"), "verify-all smoke harness should avoid the heavier verify-all regression");
    assert(!hasCommand("bash scripts/verify-fast.sh"), "verify-all smoke harness should avoid verify-fast fallback");
    assert(findCommand("bash scripts/test-verify-all-smoke.sh")?.resourceClass === "static", "verify-all smoke harness should be classified as static");
    assert(findCommand("bash scripts/test-verify-all-smoke.sh")?.oomRisk === "low", "verify-all smoke harness should be low OOM risk");
    assert(findCommand("bash scripts/test-verify-all-smoke.sh")?.requiresManagedGuard === false, "verify-all smoke harness should not require managed execution");
    assert(findCommand("bash scripts/test-verify-all-smoke.sh")?.compilerStateAccess === "none", "verify-all smoke harness should not touch compiler state");
    assert(report.commandResourceSummary.compilerStateFreeCommandCount === report.commandResourceSummary.commandCount, "verify-all smoke route should be compiler-state-free");
    assert(report.commandResourceSummary.canRunWithoutCompilerState === true, "verify-all smoke route should expose compiler-state-free run decision");
    assert(report.commandResourceSummary.requiresManagedGuard === false, "verify-all smoke route should be safe-direct");
    assert(report.commandResourceSummary.overallAdvice === "safe-direct", "verify-all smoke route should advise direct execution");
    assert(report.affectedVerificationLaunchPolicy.mode === "direct-compiler-state-free", `verify-all smoke launch mode ${report.affectedVerificationLaunchPolicy.mode}`);
    assert(report.affectedVerificationLaunchPolicy.ready === true, "verify-all smoke launch policy should be ready");
    assert(report.affectedVerificationLaunchPolicy.canRunDirect === true, "verify-all smoke launch policy should allow direct run");
    assert(report.affectedVerificationLaunchPolicy.requiredClosure.length === 0, "verify-all smoke launch policy should not require closure");
    assert(report.affectedVerificationLaunchPolicy.recommendation === "affected-verification-launch:direct-compiler-state-free", `verify-all smoke launch recommendation ${report.affectedVerificationLaunchPolicy.recommendation}`);
    assert(report.usedVerifyFastFallback === false, "known verify-all smoke harness should not use verify-fast fallback");
    assert(logHas("scripts/test-verify-all-smoke.sh"), "fake verify-all smoke command should execute");
    assert(!logHas("scripts/test-verify-all.sh"), "fake verify-all regression should not execute for smoke-only route");
    break;
  case "verify-harness-mixed":
    assert(report.changedFiles.includes("scripts/verify-all.sh"), "verify-all harness should be present");
    assert(report.changedFiles.includes("scripts/test-verify-all.sh"), "verify-all regression harness should be present");
    assert(report.changedFiles.includes("src/scripts/verify.sh"), "selfhost native verify script should be present");
    assert(hasCommand("bash -n 'scripts/verify-all.sh'"), "verify-all harness should run shell syntax check");
    assert(hasCommand("bash -n 'scripts/test-verify-all.sh'"), "verify-all regression harness should run shell syntax check");
    assert(hasCommand("bash -n 'src/scripts/verify.sh'"), "selfhost native verify script should run shell syntax check");
    assert(hasCommand("bash scripts/test-verify-all.sh"), "verify harness changes should run focused verify-all regression");
    assert(hasCommand("bash scripts/test-selfhost-verify-mode-split.sh"), "selfhost native verify script should run focused mode split regression");
    assert(!hasCommand("bash scripts/test-selfhost.sh"), "mixed verifier harness route should avoid broad selfhost coverage");
    assert(!hasCommand("bash src/scripts/verify.sh"), "mixed verifier harness route should avoid recursive hosted source verification");
    assert(report.usedVerifyFastFallback === false, "known mixed verifier harness inputs should not use verify-fast fallback");
    assert(logHas("scripts/test-verify-all.sh"), "fake verify-all regression command should execute");
    assert(logHas("scripts/test-selfhost-verify-mode-split.sh"), "fake selfhost verify mode split command should execute");
    break;
  case "planner-report-decode":
    assert(report.changedFiles.includes("examples/swarm-native/GoalManagerReportIO.clasp"), "planner report IO source should be present");
    assert(report.changedFiles.includes("examples/swarm-native/GoalManagerBenchmarkCommand.clasp"), "benchmark signal decoder should be present");
    assert(report.changedFiles.includes("scripts/test-goal-manager-planner-report-decode.sh"), "planner report decode harness should be present");
    assert(hasCommand("bash scripts/test-goal-manager-planner-report-decode.sh"), "planner report decode route should run focused coverage");
    assert(hasCommand("bash -n 'scripts/test-goal-manager-planner-report-decode.sh'"), "planner report decode harness should run shell syntax check");
    assert(hasCommand("bash scripts/test-swarm-ready-gate.sh"), "planner report decode route should retain structural ready-gate coverage");
    assert(!hasCommand("bash scripts/test-native-claspc.sh"), "focused decode route should avoid broad native-claspc coverage");
    assert(!hasCommand("bash scripts/verify-runtime-slice.sh managed-loop"), "focused decode route should avoid unrelated managed-loop coverage");
    assert(!hasCommand("bash scripts/test-swarm-memory.sh"), "focused decode route should avoid standalone memory coverage");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-goal-manager-planner-report-decode.sh").length === 1, "planner report decode command should be deduplicated");
    assert(report.usedVerifyFastFallback === false, "known planner report decode paths should not use verify-fast fallback");
    assert(logHas("scripts/test-goal-manager-planner-report-decode.sh"), "fake planner report decode command should execute");
    assert(logHas("scripts/test-swarm-ready-gate.sh"), "fake swarm-ready command should execute");
    break;
  case "retired-goal-manager-monolith":
    assert(report.changedFiles.includes("examples/swarm-native/GoalManagerProgram.clasp"), "retired GoalManagerProgram path should be present");
    assert(report.changedFiles.includes("examples/swarm-native/GoalManagerProgram2.clasp"), "retired GoalManagerProgram2 path should be present");
    assert(hasCommand("bash scripts/test-swarm-ready-gate.sh"), "retired monolith route should run the ready-gate absence check");
    assert(!hasCommand("bash scripts/test-native-claspc.sh"), "retired monolith route should avoid broad native-claspc coverage");
    assert(!hasCommand("bash scripts/verify-runtime-slice.sh managed-loop"), "retired monolith route should avoid managed-loop coverage");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-swarm-ready-gate.sh").length === 1, "retired monolith ready-gate command should be deduplicated");
    assert(report.usedVerifyFastFallback === false, "known retired monolith paths should not use verify-fast fallback");
    assert(logHas("scripts/test-swarm-ready-gate.sh"), "fake ready-gate command should execute");
    break;
  case "benchmark-checkpoint":
    assert(report.changedFiles.includes("scripts/benchmark-checkpoint.mjs"), "benchmark checkpoint runner should be present");
    assert(report.changedFiles.includes("scripts/test-benchmark-checkpoint.sh"), "benchmark checkpoint test should be present");
    assert(report.changedFiles.includes("benchmarks/checkpoints/2026-05-20-baseline-bottleneck.json"), "checkpoint artifact should be present");
    assert(hasCommand("node --check scripts/benchmark-checkpoint.mjs"), "checkpoint runner should run node syntax check");
    assert(hasCommand("bash -n 'scripts/test-benchmark-checkpoint.sh'"), "checkpoint test should run shell syntax check");
    assert(hasCommand("bash scripts/test-benchmark-checkpoint.sh"), "checkpoint route should run focused fixture regression");
    assert(!hasCommand("bash benchmarks/test-task-prep.sh"), "checkpoint route should avoid broad benchmark prep coverage");
    assert(report.usedVerifyFastFallback === false, "known benchmark checkpoint inputs should not use verify-fast fallback");
    assert(logHas("scripts/test-benchmark-checkpoint.sh"), "fake checkpoint regression command should execute");
    break;
  case "benchmark-prep-cache":
    assert(report.changedFiles.includes("benchmarks/run-benchmark.mjs"), "benchmark runner should be present");
    assert(report.changedFiles.includes("benchmarks/test-benchmark-prep-cache.sh"), "benchmark prep cache test should be present");
    assert(hasCommand("node --check benchmarks/run-benchmark.mjs"), "benchmark runner should run node syntax check");
    assert(hasCommand("bash -n 'benchmarks/test-benchmark-prep-cache.sh'"), "benchmark prep cache test should run shell syntax check");
    assert(hasCommand("bash benchmarks/test-benchmark-prep-cache.sh"), "benchmark prep cache route should run focused cache regression");
    assert(!hasCommand("bash benchmarks/test-task-prep.sh"), "benchmark prep cache route should avoid broad benchmark prep coverage");
    assert(report.usedVerifyFastFallback === false, "known benchmark prep cache inputs should not use verify-fast fallback");
    assert(logHas("benchmarks/test-benchmark-prep-cache.sh"), "fake benchmark prep cache regression command should execute");
    break;
  case "empty-no-git":
    assert(report.usedGitFallback === true, "empty explicit input should try git fallback");
    assert(report.inputFallbackMode === "git-unavailable" || report.inputFallbackMode === "git-empty", `unexpected input fallback mode: ${report.inputFallbackMode}`);
    assert(report.verificationFallbackMode === "git-unavailable-empty-input" || report.verificationFallbackMode === "empty-input", `unexpected verification fallback mode: ${report.verificationFallbackMode}`);
    assert(report.changedFiles.length === 0, "empty no-git scenario should have no changed files");
    assert(hasCommand("bash scripts/verify-fast.sh"), "empty input should run verify-fast");
    break;
  case "empty-git":
    assert(report.usedGitFallback === true, "empty explicit input should try git fallback");
    assert(report.inputFallbackMode === "git-empty", `expected git-empty, got ${report.inputFallbackMode}`);
    assert(report.verificationFallbackMode === "empty-input", `expected empty-input, got ${report.verificationFallbackMode}`);
    assert(report.changedFiles.length === 0, "empty git scenario should have no changed files");
    assert(hasCommand("bash scripts/verify-fast.sh"), "empty git input should run verify-fast");
    break;
  case "generated-state-noise":
    assert(report.usedGitFallback === false, "explicit generated state should not use git fallback");
    assert(report.inputSources.some((source) => source.kind === "argv"), "argv source should be recorded");
    assert(report.inputFallbackMode === "ignored-input", `expected ignored-input, got ${report.inputFallbackMode}`);
    assert(report.verificationFallbackMode === "ignored-input", `expected ignored-input verification, got ${report.verificationFallbackMode}`);
    assert(report.changedFiles.length === 0, `generated noise should be filtered: ${JSON.stringify(report.changedFiles)}`);
    assert(report.selectedCommands.length === 0, "generated noise should not select commands");
    assert(report.commandCount === 0, `generated noise command count ${report.commandCount}`);
    assert(report.executedCommandCount === 0, `generated noise executed count ${report.executedCommandCount}`);
    assert(report.usedVerifyFastFallback === false, "generated noise should not use verify-fast fallback");
    assert(log.length === 0, `generated noise should not execute fake commands: ${JSON.stringify(log)}`);
    break;
  case "generated-state-ignore":
    assert(report.changedFiles.includes(".gitignore"), "gitignore should be present");
    assert(hasCommand("bash scripts/test-generated-state-cleanup.sh"), "gitignore generated-state route should run cleanup coverage");
    assert(hasCommand("bash scripts/test-swarm-ready-gate.sh"), "gitignore generated-state route should run structural coverage");
    assert(!hasCommand("bash scripts/verify-fast.sh"), "gitignore generated-state route should avoid verify-fast fallback");
    assert(report.usedVerifyFastFallback === false, "gitignore generated-state route should not use verify-fast fallback");
    assert(logHas("scripts/test-generated-state-cleanup.sh"), "fake gitignore cleanup command should execute");
    assert(logHas("scripts/test-swarm-ready-gate.sh"), "fake gitignore ready-gate command should execute");
    break;
  default:
    assert(false, `unknown scenario ${scenario}`);
}
NODE
}

managed_smoke_report="$test_root/managed-smoke-report.json"
managed_smoke_log="$test_root/managed-smoke.log"
CLASP_TEST_FAKE_COMMAND_LOG="$managed_smoke_log" \
  run_verify_affected_managed --plan-only --changed-file examples/lead-app/Shared/Lead.clasp > "$managed_smoke_report"
assert_report "$managed_smoke_report" "$managed_smoke_log" app-context-plan
if [[ -s "$managed_job_log" ]]; then
  printf 'affected verifier --plan-only should bypass managed-job admission\n' >&2
  exit 1
fi

managed_execution_report="$test_root/managed-execution-report.json"
managed_execution_log="$test_root/managed-execution.log"
CLASP_TEST_FAKE_COMMAND_LOG="$managed_execution_log" \
  run_verify_affected_managed --changed-file scripts/verify-affected.mjs > "$managed_execution_report"
assert_report "$managed_execution_report" "$managed_execution_log" verification-script

source_report="$test_root/source-report.json"
source_log="$test_root/source.log"
CLASP_TEST_FAKE_COMMAND_LOG="$source_log" \
  run_verify_affected --changed-file ./src/Compiler/Checker.clasp --changed-file src/Main.clasp > "$source_report"
assert_report "$source_report" "$source_log" source-no-git

mixed_report="$test_root/mixed-report.json"
mixed_log="$test_root/mixed.log"
mixed_files_one="$test_root/mixed-one.txt"
mixed_files_two="$test_root/mixed-two.txt"
printf 'runtime/swarm.rs\n' > "$mixed_files_one"
printf 'examples/feedback-loop/Main.clasp\n' > "$mixed_files_two"
CLASP_TEST_FAKE_COMMAND_LOG="$mixed_log" \
  CLASP_VERIFY_CHANGED_FILES='examples/swarm-native/GoalManager.clasp,runtime/claspc.rs' \
  run_verify_affected --files-from "$mixed_files_one" --files-from "$mixed_files_two" > "$mixed_report"
assert_report "$mixed_report" "$mixed_log" mixed-swarm-runtime

unknown_report="$test_root/unknown-report.json"
unknown_log="$test_root/unknown.log"
CLASP_TEST_FAKE_COMMAND_LOG="$unknown_log" \
  run_verify_affected --changed-file docs/notes.md > "$unknown_report"
assert_report "$unknown_report" "$unknown_log" unknown-fallback

script_report="$test_root/script-report.json"
script_log="$test_root/script.log"
CLASP_TEST_FAKE_COMMAND_LOG="$script_log" \
  run_verify_affected --changed-file scripts/verify-affected.mjs > "$script_report"
assert_report "$script_report" "$script_log" verification-script

selfhost_verify_script_report="$test_root/selfhost-verify-script-report.json"
selfhost_verify_script_log="$test_root/selfhost-verify-script.log"
CLASP_TEST_FAKE_COMMAND_LOG="$selfhost_verify_script_log" \
  run_verify_affected --changed-file src/scripts/verify.sh > "$selfhost_verify_script_report"
assert_report "$selfhost_verify_script_report" "$selfhost_verify_script_log" selfhost-verify-script

selfhost_harness_report="$test_root/selfhost-harness-report.json"
selfhost_harness_log="$test_root/selfhost-harness.log"
CLASP_TEST_FAKE_COMMAND_LOG="$selfhost_harness_log" \
  run_verify_affected --changed-file scripts/test-selfhost.sh > "$selfhost_harness_report"
assert_report "$selfhost_harness_report" "$selfhost_harness_log" selfhost-harness-script

native_claspc_harness_report="$test_root/native-claspc-harness-report.json"
native_claspc_harness_log="$test_root/native-claspc-harness.log"
CLASP_TEST_FAKE_COMMAND_LOG="$native_claspc_harness_log" \
  run_verify_affected --changed-file scripts/test-native-claspc.sh > "$native_claspc_harness_report"
assert_report "$native_claspc_harness_report" "$native_claspc_harness_log" native-claspc-harness-script

native_diagnostics_report="$test_root/native-diagnostics-report.json"
native_diagnostics_log="$test_root/native-diagnostics.log"
CLASP_TEST_FAKE_COMMAND_LOG="$native_diagnostics_log" \
  run_verify_affected --changed-file scripts/test-native-claspc-diagnostics.sh > "$native_diagnostics_report"
assert_report "$native_diagnostics_report" "$native_diagnostics_log" native-diagnostics-script

native_incremental_report="$test_root/native-incremental-report.json"
native_incremental_log="$test_root/native-incremental.log"
CLASP_TEST_FAKE_COMMAND_LOG="$native_incremental_log" \
  run_verify_affected --changed-file scripts/measure-native-incremental.sh > "$native_incremental_report"
assert_report "$native_incremental_report" "$native_incremental_log" native-incremental-script

iteration_speed_evidence_report="$test_root/iteration-speed-evidence-report.json"
iteration_speed_evidence_log="$test_root/iteration-speed-evidence.log"
CLASP_TEST_FAKE_COMMAND_LOG="$iteration_speed_evidence_log" \
  run_verify_affected --changed-file docs/iteration-speed-loop-evidence.md > "$iteration_speed_evidence_report"
assert_report "$iteration_speed_evidence_report" "$iteration_speed_evidence_log" iteration-speed-evidence

native_incremental_guard_report="$test_root/native-incremental-guard-report.json"
native_incremental_guard_log="$test_root/native-incremental-guard.log"
CLASP_TEST_FAKE_COMMAND_LOG="$native_incremental_guard_log" \
  run_verify_affected \
    --changed-file scripts/native-incremental-guard.mjs \
    --changed-file scripts/test-native-incremental-guard.sh \
    > "$native_incremental_guard_report"
assert_report "$native_incremental_guard_report" "$native_incremental_guard_log" native-incremental-guard

swarm_control_report="$test_root/swarm-control-report.json"
swarm_control_log="$test_root/swarm-control.log"
CLASP_TEST_FAKE_COMMAND_LOG="$swarm_control_log" \
  run_verify_affected \
    --changed-file scripts/clasp-swarm-common.sh \
    --changed-file scripts/clasp-swarm-start.sh \
    --changed-file scripts/clasp-swarm-lane.sh \
    --changed-file scripts/clasp-swarm-preflight.sh \
    --changed-file scripts/clasp-swarm-validate-task.mjs \
    --changed-file scripts/test-task-manifest.sh > "$swarm_control_report"
assert_report "$swarm_control_report" "$swarm_control_log" swarm-control-script

swarm_preflight_report="$test_root/swarm-preflight-report.json"
swarm_preflight_log="$test_root/swarm-preflight.log"
CLASP_TEST_FAKE_COMMAND_LOG="$swarm_preflight_log" \
  run_verify_affected \
    --changed-file scripts/clasp-swarm-preflight.sh \
    --changed-file scripts/test-swarm-preflight.sh > "$swarm_preflight_report"
assert_report "$swarm_preflight_report" "$swarm_preflight_log" swarm-preflight-script

int_builtins_report="$test_root/int-builtins-report.json"
int_builtins_log="$test_root/int-builtins.log"
CLASP_TEST_FAKE_COMMAND_LOG="$int_builtins_log" \
  run_verify_affected --changed-file scripts/test-int-builtins.sh > "$int_builtins_report"
assert_report "$int_builtins_report" "$int_builtins_log" int-builtins-script

dict_builtins_report="$test_root/dict-builtins-report.json"
dict_builtins_log="$test_root/dict-builtins.log"
CLASP_TEST_FAKE_COMMAND_LOG="$dict_builtins_log" \
  run_verify_affected --changed-file scripts/test-dict-builtins.sh > "$dict_builtins_report"
assert_report "$dict_builtins_report" "$dict_builtins_log" dict-builtins-script

try_decode_report="$test_root/try-decode-report.json"
try_decode_log="$test_root/try-decode.log"
CLASP_TEST_FAKE_COMMAND_LOG="$try_decode_log" \
  run_verify_affected --changed-file scripts/test-try-decode.sh > "$try_decode_report"
assert_report "$try_decode_report" "$try_decode_log" try-decode-script

service_decode_report="$test_root/service-decode-report.json"
service_decode_log="$test_root/service-decode.log"
CLASP_TEST_FAKE_COMMAND_LOG="$service_decode_log" \
  run_verify_affected \
    --changed-file examples/swarm-native/Service.clasp \
    --changed-file examples/swarm-native/ServiceDecodeHarness.clasp \
    --changed-file scripts/test-service-decode.sh > "$service_decode_report"
assert_report "$service_decode_report" "$service_decode_log" service-decode

record_update_parity_report="$test_root/record-update-parity-report.json"
record_update_parity_log="$test_root/record-update-parity.log"
CLASP_TEST_FAKE_COMMAND_LOG="$record_update_parity_log" \
  run_verify_affected --changed-file scripts/test-record-update-parity.sh > "$record_update_parity_report"
assert_report "$record_update_parity_report" "$record_update_parity_log" record-update-parity-script

compiler_slice_script_report="$test_root/compiler-slice-script-report.json"
compiler_slice_script_log="$test_root/compiler-slice-script.log"
CLASP_TEST_FAKE_COMMAND_LOG="$compiler_slice_script_log" \
  run_verify_affected \
    --changed-file scripts/verify-compiler-slice.sh \
    --changed-file scripts/test-verify-compiler-slice.sh > "$compiler_slice_script_report"
assert_report "$compiler_slice_script_report" "$compiler_slice_script_log" compiler-slice-script

compiler_slice_fixture_report="$test_root/compiler-slice-fixture-report.json"
compiler_slice_fixture_log="$test_root/compiler-slice-fixture.log"
CLASP_TEST_FAKE_COMMAND_LOG="$compiler_slice_fixture_log" \
  run_verify_affected \
    --changed-file examples/compiler-checker.clasp \
    --changed-file examples/compiler-lower.clasp \
    --changed-file examples/compiler-ergonomics.clasp > "$compiler_slice_fixture_report"
assert_report "$compiler_slice_fixture_report" "$compiler_slice_fixture_log" compiler-slice-fixture

js_emitter_determinism_report="$test_root/js-emitter-determinism-report.json"
js_emitter_determinism_log="$test_root/js-emitter-determinism.log"
CLASP_TEST_FAKE_COMMAND_LOG="$js_emitter_determinism_log" \
  run_verify_affected \
    --changed-file src/Compiler/Emit/JavaScript.clasp \
    --changed-file scripts/test-js-emitter-determinism.sh > "$js_emitter_determinism_report"
assert_report "$js_emitter_determinism_report" "$js_emitter_determinism_log" js-emitter-determinism

agent_feedback_report="$test_root/agent-feedback-report.json"
agent_feedback_log="$test_root/agent-feedback.log"
CLASP_TEST_FAKE_COMMAND_LOG="$agent_feedback_log" \
  run_verify_affected \
    --changed-file agents/feedback/test-feedback.json > "$agent_feedback_report"
assert_report "$agent_feedback_report" "$agent_feedback_log" agent-feedback

promoted_source_export_report="$test_root/promoted-source-export-report.json"
promoted_source_export_log="$test_root/promoted-source-export.log"
CLASP_TEST_FAKE_COMMAND_LOG="$promoted_source_export_log" \
  run_verify_affected \
    --changed-file scripts/generate-promoted-source-export-cache.mjs \
    --changed-file scripts/test-promoted-source-export-cache.sh \
    --changed-file src/stage1.compiler.source-export-cache-v1.json \
    --changed-file src/stage1.promoted-project.native.image.json > "$promoted_source_export_report"
assert_report "$promoted_source_export_report" "$promoted_source_export_log" promoted-source-export-cache

promoted_module_summary_report="$test_root/promoted-module-summary-report.json"
promoted_module_summary_log="$test_root/promoted-module-summary.log"
CLASP_TEST_FAKE_COMMAND_LOG="$promoted_module_summary_log" \
  run_verify_affected \
    --changed-file scripts/generate-promoted-module-summary-cache.mjs \
    --changed-file scripts/test-promoted-module-summary-cache.sh \
    --changed-file src/stage1.compiler.module-summary-cache-v2.json \
    --changed-file src/stage1.compiler.native.image.json > "$promoted_module_summary_report"
assert_report "$promoted_module_summary_report" "$promoted_module_summary_log" promoted-module-summary-cache

runtime_slice_script_report="$test_root/runtime-slice-script-report.json"
runtime_slice_script_log="$test_root/runtime-slice-script.log"
CLASP_TEST_FAKE_COMMAND_LOG="$runtime_slice_script_log" \
  run_verify_affected \
    --changed-file scripts/verify-runtime-slice.sh \
    --changed-file scripts/test-verify-runtime-slice.sh > "$runtime_slice_script_report"
assert_report "$runtime_slice_script_report" "$runtime_slice_script_log" runtime-slice-script

swarm_feedback_loop_script_report="$test_root/swarm-feedback-loop-script-report.json"
swarm_feedback_loop_script_log="$test_root/swarm-feedback-loop-script.log"
CLASP_TEST_FAKE_COMMAND_LOG="$swarm_feedback_loop_script_log" \
  run_verify_affected \
    --changed-file scripts/test-swarm-native-feedback-loop.sh > "$swarm_feedback_loop_script_report"
assert_report "$swarm_feedback_loop_script_report" "$swarm_feedback_loop_script_log" swarm-feedback-loop-script

swarm_feedback_loop_program_report="$test_root/swarm-feedback-loop-program-report.json"
swarm_feedback_loop_program_log="$test_root/swarm-feedback-loop-program.log"
CLASP_TEST_FAKE_COMMAND_LOG="$swarm_feedback_loop_program_log" \
  run_verify_affected \
    --changed-file examples/swarm-native/FeedbackLoop.clasp \
    --changed-file examples/swarm-native/AttemptLoop.clasp \
    --changed-file examples/swarm-native/LocalAgent.clasp > "$swarm_feedback_loop_program_report"
assert_report "$swarm_feedback_loop_program_report" "$swarm_feedback_loop_program_log" swarm-feedback-loop-program

local_agent_capability_closure_report="$test_root/local-agent-capability-closure-report.json"
local_agent_capability_closure_log="$test_root/local-agent-capability-closure.log"
CLASP_TEST_FAKE_COMMAND_LOG="$local_agent_capability_closure_log" \
  run_verify_affected \
    --changed-file examples/swarm-native/LocalSourceEdit.clasp \
    --changed-file examples/swarm-native/LocalSourceEditHarness.clasp \
    --changed-file scripts/test-local-source-edit-workspace.sh > "$local_agent_capability_closure_report"
assert_report "$local_agent_capability_closure_report" "$local_agent_capability_closure_log" local-agent-capability-closure

local_agent_capability_closure_script_report="$test_root/local-agent-capability-closure-script-report.json"
local_agent_capability_closure_script_log="$test_root/local-agent-capability-closure-script.log"
CLASP_TEST_FAKE_COMMAND_LOG="$local_agent_capability_closure_script_log" \
  run_verify_affected --changed-file scripts/test-local-agent-capability-closure.sh > "$local_agent_capability_closure_script_report"
assert_report "$local_agent_capability_closure_script_report" "$local_agent_capability_closure_script_log" local-agent-capability-closure-script

feedback_loop_resume_script_report="$test_root/feedback-loop-resume-script-report.json"
feedback_loop_resume_script_log="$test_root/feedback-loop-resume-script.log"
CLASP_TEST_FAKE_COMMAND_LOG="$feedback_loop_resume_script_log" \
  run_verify_affected \
    --changed-file scripts/test-feedback-loop-resume.sh > "$feedback_loop_resume_script_report"
assert_report "$feedback_loop_resume_script_report" "$feedback_loop_resume_script_log" feedback-loop-resume-script

feedback_loop_routing_script_report="$test_root/feedback-loop-routing-script-report.json"
feedback_loop_routing_script_log="$test_root/feedback-loop-routing-script.log"
CLASP_TEST_FAKE_COMMAND_LOG="$feedback_loop_routing_script_log" \
  run_verify_affected \
    --changed-file scripts/test-feedback-loop-routing.sh > "$feedback_loop_routing_script_report"
assert_report "$feedback_loop_routing_script_report" "$feedback_loop_routing_script_log" feedback-loop-routing-script

agent_task_scenario_report="$test_root/agent-task-scenario-report.json"
agent_task_scenario_log="$test_root/agent-task-scenario.log"
CLASP_TEST_FAKE_COMMAND_LOG="$agent_task_scenario_log" \
  run_verify_affected \
    --changed-file examples/agent-task-scenario/Main.clasp \
    --changed-file examples/agent-task-scenario/scripts/verify.sh > "$agent_task_scenario_report"
assert_report "$agent_task_scenario_report" "$agent_task_scenario_log" agent-task-scenario

agent_metadata_report="$test_root/agent-metadata-report.json"
agent_metadata_log="$test_root/agent-metadata.log"
CLASP_TEST_FAKE_COMMAND_LOG="$agent_metadata_log" \
  run_verify_affected \
    --changed-file examples/agent-metadata/Main.clasp \
    --changed-file examples/agent-metadata/scripts/verify.sh > "$agent_metadata_report"
assert_report "$agent_metadata_report" "$agent_metadata_log" agent-metadata

agent_loop_scenario_report="$test_root/agent-loop-scenario-report.json"
agent_loop_scenario_log="$test_root/agent-loop-scenario.log"
CLASP_TEST_FAKE_COMMAND_LOG="$agent_loop_scenario_log" \
  run_verify_affected \
    --changed-file examples/agent-loop-scenario/Main.clasp \
    --changed-file examples/agent-loop-scenario/AgentRuntime.clasp \
    --changed-file examples/agent-loop-scenario/Workspace.clasp \
    --changed-file examples/agent-loop-scenario/Process.clasp \
    --changed-file examples/agent-loop-scenario/scripts/verify.sh > "$agent_loop_scenario_report"
assert_report "$agent_loop_scenario_report" "$agent_loop_scenario_log" agent-loop-scenario

monitored_workflow_script_report="$test_root/monitored-workflow-script-report.json"
monitored_workflow_script_log="$test_root/monitored-workflow-script.log"
CLASP_TEST_FAKE_COMMAND_LOG="$monitored_workflow_script_log" \
  run_verify_affected --changed-file scripts/test-monitored-workflow.sh > "$monitored_workflow_script_report"
assert_report "$monitored_workflow_script_report" "$monitored_workflow_script_log" monitored-workflow-script

monitored_run_log_script_report="$test_root/monitored-run-log-script-report.json"
monitored_run_log_script_log="$test_root/monitored-run-log-script.log"
CLASP_TEST_FAKE_COMMAND_LOG="$monitored_run_log_script_log" \
  run_verify_affected --changed-file scripts/test-monitored-run-log.sh > "$monitored_run_log_script_report"
assert_report "$monitored_run_log_script_report" "$monitored_run_log_script_log" monitored-run-log-script

codex_loop_program_script_report="$test_root/codex-loop-program-script-report.json"
codex_loop_program_script_log="$test_root/codex-loop-program-script.log"
CLASP_TEST_FAKE_COMMAND_LOG="$codex_loop_program_script_log" \
  run_verify_affected --changed-file scripts/test-codex-loop-program.sh > "$codex_loop_program_script_report"
assert_report "$codex_loop_program_script_report" "$codex_loop_program_script_log" codex-loop-program-script

host_runtime_report="$test_root/host-runtime-report.json"
host_runtime_log="$test_root/host-runtime.log"
CLASP_TEST_FAKE_COMMAND_LOG="$host_runtime_log" \
  run_verify_affected \
    --changed-file examples/host-runtime/Main.clasp \
    --changed-file examples/host-runtime/Host.clasp \
    --changed-file scripts/test-host-runtime.sh \
    --changed-file docs/clasp-spec-v0.md \
    --changed-file docs/autonomous-swarm-build-plan.md \
    --changed-file .workspace-ready > "$host_runtime_report"
assert_report "$host_runtime_report" "$host_runtime_log" host-runtime

host_resources_report="$test_root/host-resources-report.json"
host_resources_log="$test_root/host-resources.log"
CLASP_TEST_FAKE_COMMAND_LOG="$host_resources_log" \
  run_verify_affected \
    --changed-file examples/swarm-native/HostResources.clasp \
    --changed-file examples/swarm-native/HostResourcesHarness.clasp > "$host_resources_report"
assert_report "$host_resources_report" "$host_resources_log" host-resources

goal_manager_resource_health_report="$test_root/goal-manager-resource-health-report.json"
goal_manager_resource_health_log="$test_root/goal-manager-resource-health.log"
CLASP_TEST_FAKE_COMMAND_LOG="$goal_manager_resource_health_log" \
  run_verify_affected \
    --changed-file examples/swarm-native/GoalManagerResourceHealth.clasp > "$goal_manager_resource_health_report"
assert_report "$goal_manager_resource_health_report" "$goal_manager_resource_health_log" goal-manager-resource-health

goal_manager_generated_cleanup_health_report="$test_root/goal-manager-generated-cleanup-health-report.json"
goal_manager_generated_cleanup_health_log="$test_root/goal-manager-generated-cleanup-health.log"
CLASP_TEST_FAKE_COMMAND_LOG="$goal_manager_generated_cleanup_health_log" \
  run_verify_affected \
    --changed-file examples/swarm-native/GoalManagerGeneratedCleanupHealth.clasp \
    --changed-file examples/swarm-native/GoalManagerGeneratedCleanupHealthHarness.clasp \
    --changed-file scripts/test-goal-manager-generated-cleanup-health.sh > "$goal_manager_generated_cleanup_health_report"
assert_report "$goal_manager_generated_cleanup_health_report" "$goal_manager_generated_cleanup_health_log" goal-manager-generated-cleanup-health

goal_manager_mailbox_capability_report="$test_root/goal-manager-mailbox-capability-report.json"
goal_manager_mailbox_capability_log="$test_root/goal-manager-mailbox-capability.log"
CLASP_TEST_FAKE_COMMAND_LOG="$goal_manager_mailbox_capability_log" \
  run_verify_affected \
    --changed-file examples/swarm-native/GoalManagerCapabilityMailbox.clasp \
    --changed-file examples/swarm-native/GoalManagerMailboxMessages.clasp \
    --changed-file examples/swarm-native/GoalManagerMailboxCapabilityHarness.clasp > "$goal_manager_mailbox_capability_report"
assert_report "$goal_manager_mailbox_capability_report" "$goal_manager_mailbox_capability_log" goal-manager-mailbox-capability-details

resource_guard_policy_script_report="$test_root/resource-guard-policy-script-report.json"
resource_guard_policy_script_log="$test_root/resource-guard-policy-script.log"
CLASP_TEST_FAKE_COMMAND_LOG="$resource_guard_policy_script_log" \
  run_verify_affected \
    --changed-file scripts/test-resource-guard-policy.sh > "$resource_guard_policy_script_report"
assert_report "$resource_guard_policy_script_report" "$resource_guard_policy_script_log" resource-guard-policy-script

generated_state_cleanup_plan_report="$test_root/generated-state-cleanup-plan-report.json"
generated_state_cleanup_plan_log="$test_root/generated-state-cleanup-plan.log"
CLASP_TEST_FAKE_COMMAND_LOG="$generated_state_cleanup_plan_log" \
  run_verify_affected \
    --changed-file examples/swarm-native/GeneratedStateCleanupPlan.clasp > "$generated_state_cleanup_plan_report"
assert_report "$generated_state_cleanup_plan_report" "$generated_state_cleanup_plan_log" generated-state-cleanup-program

generated_state_cleanup_plan_script_report="$test_root/generated-state-cleanup-plan-script-report.json"
generated_state_cleanup_plan_script_log="$test_root/generated-state-cleanup-plan-script.log"
CLASP_TEST_FAKE_COMMAND_LOG="$generated_state_cleanup_plan_script_log" \
  run_verify_affected \
    --changed-file scripts/test-generated-state-cleanup-plan.sh > "$generated_state_cleanup_plan_script_report"
assert_report "$generated_state_cleanup_plan_script_report" "$generated_state_cleanup_plan_script_log" generated-state-cleanup-plan-script

generated_state_cleanup_plan_static_script_report="$test_root/generated-state-cleanup-plan-static-script-report.json"
generated_state_cleanup_plan_static_script_log="$test_root/generated-state-cleanup-plan-static-script.log"
CLASP_TEST_FAKE_COMMAND_LOG="$generated_state_cleanup_plan_static_script_log" \
  run_verify_affected \
    --changed-file scripts/test-generated-state-cleanup-plan-static.sh > "$generated_state_cleanup_plan_static_script_report"
assert_report "$generated_state_cleanup_plan_static_script_report" "$generated_state_cleanup_plan_static_script_log" generated-state-cleanup-plan-static-script

local_routing_report="$test_root/local-routing-report.json"
local_routing_log="$test_root/local-routing.log"
CLASP_TEST_FAKE_COMMAND_LOG="$local_routing_log" \
  run_verify_affected \
    --changed-file examples/swarm-native/LocalRouting.clasp \
    --changed-file examples/swarm-native/LocalRoutingHarness.clasp > "$local_routing_report"
assert_report "$local_routing_report" "$local_routing_log" local-routing

standalone_swarm_surfaces_report="$test_root/standalone-swarm-surfaces-report.json"
standalone_swarm_surfaces_log="$test_root/standalone-swarm-surfaces.log"
CLASP_TEST_FAKE_COMMAND_LOG="$standalone_swarm_surfaces_log" \
  run_verify_affected \
    --changed-file src/StandaloneSwarmReadiness.clasp \
    --changed-file src/StandaloneSwarmVerifier.clasp \
    --changed-file examples/swarm-native/StandaloneSwarmHarness.clasp \
    --changed-file examples/swarm-native/StandaloneSwarmRouting.clasp \
    --changed-file examples/swarm-native/StandaloneSwarmClosureReport.clasp \
    --changed-file examples/swarm-native/StandaloneSwarmClosureReportHarness.clasp \
    --changed-file scripts/standalone-swarm-readiness.sh \
    --changed-file scripts/standalone-swarm-verify.sh \
    --changed-file scripts/test-standalone-swarm-surfaces.sh \
    --changed-file docs/standalone-swarm-readiness.md \
    --changed-file runtime/standalone_swarm_probe.rs > "$standalone_swarm_surfaces_report"
assert_report "$standalone_swarm_surfaces_report" "$standalone_swarm_surfaces_log" standalone-swarm-surfaces

safe_workspace_report="$test_root/safe-workspace-report.json"
safe_workspace_log="$test_root/safe-workspace.log"
CLASP_TEST_FAKE_COMMAND_LOG="$safe_workspace_log" \
  run_verify_affected \
    --changed-file examples/safe-workspace/Main.clasp \
    --changed-file examples/safe-workspace/Workspace.clasp \
    --changed-file examples/safe-workspace/SafeWorkspaceHarness.clasp \
    --changed-file scripts/test-safe-workspace.sh > "$safe_workspace_report"
assert_report "$safe_workspace_report" "$safe_workspace_log" safe-workspace

safe_workspace_static_script_report="$test_root/safe-workspace-static-script-report.json"
safe_workspace_static_script_log="$test_root/safe-workspace-static-script.log"
CLASP_TEST_FAKE_COMMAND_LOG="$safe_workspace_static_script_log" \
  run_verify_affected \
    --changed-file scripts/test-safe-workspace-static.sh > "$safe_workspace_static_script_report"
assert_report "$safe_workspace_static_script_report" "$safe_workspace_static_script_log" safe-workspace-static-script

safe_subprocess_report="$test_root/safe-subprocess-report.json"
safe_subprocess_log="$test_root/safe-subprocess.log"
CLASP_TEST_FAKE_COMMAND_LOG="$safe_subprocess_log" \
  run_verify_affected \
    --changed-file examples/safe-subprocess/Main.clasp \
    --changed-file examples/safe-subprocess/Process.clasp \
    --changed-file scripts/test-safe-subprocess.sh > "$safe_subprocess_report"
assert_report "$safe_subprocess_report" "$safe_subprocess_log" safe-subprocess

source_benchmark_report="$test_root/source-benchmark-report.json"
source_benchmark_log="$test_root/source-benchmark.log"
CLASP_TEST_FAKE_COMMAND_LOG="$source_benchmark_log" \
  run_verify_affected \
    --changed-file src/Compiler/SemanticArtifacts.clasp \
    --changed-file benchmarks/tasks/clasp-lead-segment/repo/Shared/Lead.clasp > "$source_benchmark_report"
assert_report "$source_benchmark_report" "$source_benchmark_log" source-benchmark-mixed

app_context_report="$test_root/app-context-report.json"
app_context_log="$test_root/app-context.log"
CLASP_TEST_FAKE_COMMAND_LOG="$app_context_log" \
  run_verify_affected --plan-only --changed-file examples/lead-app/Shared/Lead.clasp > "$app_context_report"
assert_report "$app_context_report" "$app_context_log" app-context-plan

goal_manager_report="$test_root/goal-manager-report.json"
goal_manager_log="$test_root/goal-manager.log"
CLASP_TEST_FAKE_COMMAND_LOG="$goal_manager_log" \
  run_verify_affected --changed-file scripts/test-goal-manager-fast.sh --changed-file scripts/test-swarm-ready-gate.sh > "$goal_manager_report"
assert_report "$goal_manager_report" "$goal_manager_log" goal-manager-fast-script

swarm_ready_benchmark_script_report="$test_root/swarm-ready-benchmark-script-report.json"
swarm_ready_benchmark_script_log="$test_root/swarm-ready-benchmark-script.log"
CLASP_TEST_FAKE_COMMAND_LOG="$swarm_ready_benchmark_script_log" \
  run_verify_affected --changed-file scripts/test-swarm-ready-benchmark.sh > "$swarm_ready_benchmark_script_report"
assert_report "$swarm_ready_benchmark_script_report" "$swarm_ready_benchmark_script_log" swarm-ready-benchmark-script

swarm_capability_audit_script_report="$test_root/swarm-capability-audit-script-report.json"
swarm_capability_audit_script_log="$test_root/swarm-capability-audit-script.log"
CLASP_TEST_FAKE_COMMAND_LOG="$swarm_capability_audit_script_log" \
  run_verify_affected --changed-file scripts/test-swarm-capability-audit.sh > "$swarm_capability_audit_script_report"
assert_report "$swarm_capability_audit_script_report" "$swarm_capability_audit_script_log" swarm-capability-audit-script

swarm_policy_helpers_script_report="$test_root/swarm-policy-helpers-script-report.json"
swarm_policy_helpers_script_log="$test_root/swarm-policy-helpers-script.log"
CLASP_TEST_FAKE_COMMAND_LOG="$swarm_policy_helpers_script_log" \
  run_verify_affected \
    --changed-file scripts/test-swarm-policy-helpers.sh \
    --changed-file scripts/clasp-network-egress-enforcer.mjs \
    --changed-file scripts/clasp-network-egress-backend.mjs \
    --changed-file scripts/clasp-network-egress-kernel-backend.mjs \
    --changed-file scripts/clasp-network-egress-guard.c \
    --changed-file scripts/clasp-filesystem-write-enforcer.mjs \
    --changed-file scripts/clasp-filesystem-write-kernel-backend.mjs \
    --changed-file scripts/clasp-filesystem-write-guard.c \
    --changed-file scripts/test-swarm-destructive-policy.sh \
    --changed-file scripts/test-swarm-filesystem-kernel-policy.sh > "$swarm_policy_helpers_script_report"
assert_report "$swarm_policy_helpers_script_report" "$swarm_policy_helpers_script_log" swarm-policy-helpers-script

swarm_policy_helpers_program_report="$test_root/swarm-policy-helpers-program-report.json"
swarm_policy_helpers_program_log="$test_root/swarm-policy-helpers-program.log"
CLASP_TEST_FAKE_COMMAND_LOG="$swarm_policy_helpers_program_log" \
  run_verify_affected --changed-file examples/swarm-native/PolicyHarness.clasp > "$swarm_policy_helpers_program_report"
assert_report "$swarm_policy_helpers_program_report" "$swarm_policy_helpers_program_log" swarm-policy-helpers-program

goal_manager_task_policy_program_report="$test_root/goal-manager-task-policy-program-report.json"
goal_manager_task_policy_program_log="$test_root/goal-manager-task-policy-program.log"
CLASP_TEST_FAKE_COMMAND_LOG="$goal_manager_task_policy_program_log" \
  run_verify_affected --changed-file examples/swarm-native/GoalManagerTaskPolicyHarness.clasp > "$goal_manager_task_policy_program_report"
assert_report "$goal_manager_task_policy_program_report" "$goal_manager_task_policy_program_log" swarm-policy-helpers-program

capability_policy_program_report="$test_root/capability-policy-program-report.json"
capability_policy_program_log="$test_root/capability-policy-program.log"
CLASP_TEST_FAKE_COMMAND_LOG="$capability_policy_program_log" \
  run_verify_affected --changed-file examples/swarm-native/CapabilityPolicyHarness.clasp > "$capability_policy_program_report"
assert_report "$capability_policy_program_report" "$capability_policy_program_log" swarm-policy-helpers-program

swarm_priority_script_report="$test_root/swarm-priority-script-report.json"
swarm_priority_script_log="$test_root/swarm-priority-script.log"
CLASP_TEST_FAKE_COMMAND_LOG="$swarm_priority_script_log" \
  run_verify_affected --changed-file scripts/test-swarm-priority.sh > "$swarm_priority_script_report"
assert_report "$swarm_priority_script_report" "$swarm_priority_script_log" swarm-priority-script

swarm_priority_program_report="$test_root/swarm-priority-program-report.json"
swarm_priority_program_log="$test_root/swarm-priority-program.log"
CLASP_TEST_FAKE_COMMAND_LOG="$swarm_priority_program_log" \
  run_verify_affected --changed-file examples/swarm-native/PriorityHarness.clasp > "$swarm_priority_program_report"
assert_report "$swarm_priority_program_report" "$swarm_priority_program_log" swarm-priority-program

swarm_ready_benchmark_program_report="$test_root/swarm-ready-benchmark-program-report.json"
swarm_ready_benchmark_program_log="$test_root/swarm-ready-benchmark-program.log"
CLASP_TEST_FAKE_COMMAND_LOG="$swarm_ready_benchmark_program_log" \
  run_verify_affected --changed-file examples/swarm-native/SwarmReadyBenchmark.clasp > "$swarm_ready_benchmark_program_report"
assert_report "$swarm_ready_benchmark_program_report" "$swarm_ready_benchmark_program_log" swarm-ready-benchmark-program

swarm_capability_audit_program_report="$test_root/swarm-capability-audit-program-report.json"
swarm_capability_audit_program_log="$test_root/swarm-capability-audit-program.log"
CLASP_TEST_FAKE_COMMAND_LOG="$swarm_capability_audit_program_log" \
  run_verify_affected --changed-file examples/swarm-native/SwarmCapabilityAudit.clasp > "$swarm_capability_audit_program_report"
assert_report "$swarm_capability_audit_program_report" "$swarm_capability_audit_program_log" swarm-capability-audit-program

swarm_capability_audit_doc_report="$test_root/swarm-capability-audit-doc-report.json"
swarm_capability_audit_doc_log="$test_root/swarm-capability-audit-doc.log"
CLASP_TEST_FAKE_COMMAND_LOG="$swarm_capability_audit_doc_log" \
  run_verify_affected --changed-file docs/autonomous-swarm-runtime-requirements.md > "$swarm_capability_audit_doc_report"
assert_report "$swarm_capability_audit_doc_report" "$swarm_capability_audit_doc_log" swarm-capability-audit-doc

agent_command_template_report="$test_root/agent-command-template-report.json"
agent_command_template_log="$test_root/agent-command-template.log"
CLASP_TEST_FAKE_COMMAND_LOG="$agent_command_template_log" \
  run_verify_affected --changed-file scripts/test-agent-command-template.sh > "$agent_command_template_report"
assert_report "$agent_command_template_report" "$agent_command_template_log" agent-command-template-script

agent_backend_api_report="$test_root/agent-backend-api-report.json"
agent_backend_api_log="$test_root/agent-backend-api.log"
CLASP_TEST_FAKE_COMMAND_LOG="$agent_backend_api_log" \
  run_verify_affected \
    --changed-file examples/swarm-native/AgentBackend.clasp \
    --changed-file examples/swarm-native/AgentBackendHarness.clasp > "$agent_backend_api_report"
assert_report "$agent_backend_api_report" "$agent_backend_api_log" agent-backend-api

agent_backend_static_script_report="$test_root/agent-backend-static-script-report.json"
agent_backend_static_script_log="$test_root/agent-backend-static-script.log"
CLASP_TEST_FAKE_COMMAND_LOG="$agent_backend_static_script_log" \
  run_verify_affected --changed-file scripts/test-agent-backend-static.sh > "$agent_backend_static_script_report"
assert_report "$agent_backend_static_script_report" "$agent_backend_static_script_log" agent-backend-static-script

agent_ergonomics_report="$test_root/agent-ergonomics-report.json"
agent_ergonomics_log="$test_root/agent-ergonomics.log"
CLASP_TEST_FAKE_COMMAND_LOG="$agent_ergonomics_log" \
  run_verify_affected \
    --changed-file examples/swarm-native/AgentErgonomics.clasp \
    --changed-file examples/swarm-native/AgentErgonomicsHarness.clasp \
    --changed-file scripts/test-agent-ergonomics-helpers.sh > "$agent_ergonomics_report"
assert_report "$agent_ergonomics_report" "$agent_ergonomics_log" agent-ergonomics

goal_manager_planner_prompt_report="$test_root/goal-manager-planner-prompt-report.json"
goal_manager_planner_prompt_log="$test_root/goal-manager-planner-prompt.log"
CLASP_TEST_FAKE_COMMAND_LOG="$goal_manager_planner_prompt_log" \
  run_verify_affected \
    --changed-file examples/swarm-native/GoalManagerBootstrapPlanner.clasp \
    --changed-file examples/swarm-native/GoalManagerPlannerInputFingerprint.clasp \
    --changed-file examples/swarm-native/GoalManagerPlannerInputTypes.clasp \
    --changed-file examples/swarm-native/GoalManagerPlannerInputState.clasp \
    --changed-file examples/swarm-native/PlannerInputFingerprintHarness.clasp \
    --changed-file examples/swarm-native/LocalPlanner.clasp \
    --changed-file scripts/test-goal-manager-agent-command-template.sh \
    --changed-file scripts/test-goal-manager-default-planner-command.sh \
    --changed-file scripts/test-goal-manager-fixture-manager.mjs > "$goal_manager_planner_prompt_report"
assert_report "$goal_manager_planner_prompt_report" "$goal_manager_planner_prompt_log" goal-manager-planner-prompt

goal_manager_binary_helper_report="$test_root/goal-manager-binary-helper-report.json"
goal_manager_binary_helper_log="$test_root/goal-manager-binary-helper.log"
CLASP_TEST_FAKE_COMMAND_LOG="$goal_manager_binary_helper_log" \
  run_verify_affected --changed-file scripts/ensure-goal-manager-binary.sh > "$goal_manager_binary_helper_report"
assert_report "$goal_manager_binary_helper_report" "$goal_manager_binary_helper_log" goal-manager-binary-helper

verify_all_smoke_script_report="$test_root/verify-all-smoke-script-report.json"
verify_all_smoke_script_log="$test_root/verify-all-smoke-script.log"
CLASP_TEST_FAKE_COMMAND_LOG="$verify_all_smoke_script_log" \
  run_verify_affected --changed-file scripts/test-verify-all-smoke.sh > "$verify_all_smoke_script_report"
assert_report "$verify_all_smoke_script_report" "$verify_all_smoke_script_log" verify-all-smoke-script

verify_harness_mixed_report="$test_root/verify-harness-mixed-report.json"
verify_harness_mixed_log="$test_root/verify-harness-mixed.log"
CLASP_TEST_FAKE_COMMAND_LOG="$verify_harness_mixed_log" \
  run_verify_affected \
    --changed-file scripts/verify-all.sh \
    --changed-file scripts/test-verify-all.sh \
    --changed-file src/scripts/verify.sh > "$verify_harness_mixed_report"
assert_report "$verify_harness_mixed_report" "$verify_harness_mixed_log" verify-harness-mixed

planner_report_decode_report="$test_root/planner-report-decode-report.json"
planner_report_decode_log="$test_root/planner-report-decode.log"
CLASP_TEST_FAKE_COMMAND_LOG="$planner_report_decode_log" \
  run_verify_affected \
    --changed-file examples/swarm-native/GoalManagerReportIO.clasp \
    --changed-file examples/swarm-native/GoalManagerBenchmarkCommand.clasp \
    --changed-file scripts/test-goal-manager-planner-report-decode.sh > "$planner_report_decode_report"
assert_report "$planner_report_decode_report" "$planner_report_decode_log" planner-report-decode

retired_goal_manager_monolith_report="$test_root/retired-goal-manager-monolith-report.json"
retired_goal_manager_monolith_log="$test_root/retired-goal-manager-monolith.log"
CLASP_TEST_FAKE_COMMAND_LOG="$retired_goal_manager_monolith_log" \
  run_verify_affected \
    --changed-file examples/swarm-native/GoalManagerProgram.clasp \
    --changed-file examples/swarm-native/GoalManagerProgram2.clasp > "$retired_goal_manager_monolith_report"
assert_report "$retired_goal_manager_monolith_report" "$retired_goal_manager_monolith_log" retired-goal-manager-monolith

benchmark_checkpoint_report="$test_root/benchmark-checkpoint-report.json"
benchmark_checkpoint_log="$test_root/benchmark-checkpoint.log"
CLASP_TEST_FAKE_COMMAND_LOG="$benchmark_checkpoint_log" \
  run_verify_affected \
    --changed-file scripts/benchmark-checkpoint.mjs \
    --changed-file scripts/test-benchmark-checkpoint.sh \
    --changed-file benchmarks/checkpoints/2026-05-20-baseline-bottleneck.json > "$benchmark_checkpoint_report"
assert_report "$benchmark_checkpoint_report" "$benchmark_checkpoint_log" benchmark-checkpoint

benchmark_prep_cache_report="$test_root/benchmark-prep-cache-report.json"
benchmark_prep_cache_log="$test_root/benchmark-prep-cache.log"
CLASP_TEST_FAKE_COMMAND_LOG="$benchmark_prep_cache_log" \
  run_verify_affected \
    --changed-file benchmarks/run-benchmark.mjs \
    --changed-file benchmarks/test-benchmark-prep-cache.sh > "$benchmark_prep_cache_report"
assert_report "$benchmark_prep_cache_report" "$benchmark_prep_cache_log" benchmark-prep-cache

managed_job_safety_report="$test_root/managed-job-safety-report.json"
managed_job_safety_log="$test_root/managed-job-safety.log"
CLASP_TEST_FAKE_COMMAND_LOG="$managed_job_safety_log" \
  run_verify_affected \
    --changed-file scripts/run-managed-job.sh \
    --changed-file scripts/stop-managed-job.sh \
    --changed-file scripts/test-managed-job.sh \
    --changed-file scripts/clasp-clean-generated-state.sh \
    --changed-file scripts/test-generated-state-cleanup.sh > "$managed_job_safety_report"
assert_report "$managed_job_safety_report" "$managed_job_safety_log" managed-job-safety

empty_report="$test_root/empty-report.json"
empty_log="$test_root/empty.log"
CLASP_TEST_FAKE_COMMAND_LOG="$empty_log" \
  run_verify_affected > "$empty_report"
assert_report "$empty_report" "$empty_log" empty-no-git

git -C "$project_copy" init -q >/dev/null
git -C "$project_copy" config user.email "verify-affected@example.test"
git -C "$project_copy" config user.name "verify affected"
git -C "$project_copy" add .
git -C "$project_copy" commit -m "fixture" >/dev/null

empty_git_report="$test_root/empty-git-report.json"
empty_git_log="$test_root/empty-git.log"
CLASP_TEST_FAKE_COMMAND_LOG="$empty_git_log" \
  run_verify_affected > "$empty_git_report"
assert_report "$empty_git_report" "$empty_git_log" empty-git

generated_state_report="$test_root/generated-state-report.json"
generated_state_log="$test_root/generated-state.log"
CLASP_TEST_FAKE_COMMAND_LOG="$generated_state_log" \
  run_verify_affected \
    --changed-file .clasp-verify \
    --changed-file .clasp-verify/jobs/job-1/stdout.log \
    --changed-file .clasp-loops \
    --changed-file .clasp-loops/jobs/job-2/status \
    --changed-file .clasp-managed-job-admission.lock \
    --changed-file benchmarks/workspaces/generated/noise.txt \
    --changed-file runtime/target/debug/noise.o > "$generated_state_report"
assert_report "$generated_state_report" "$generated_state_log" generated-state-noise

generated_state_ignore_report="$test_root/generated-state-ignore-report.json"
generated_state_ignore_log="$test_root/generated-state-ignore.log"
CLASP_TEST_FAKE_COMMAND_LOG="$generated_state_ignore_log" \
  run_verify_affected --changed-file .gitignore > "$generated_state_ignore_report"
assert_report "$generated_state_ignore_report" "$generated_state_ignore_log" generated-state-ignore

grep -F "memory=8192 min=45056 disk=16384 headroom=1024 reserve=$project_copy command=env CLASP_VERIFY_AFFECTED_MANAGED_REENTRY=1" "$managed_job_log" >/dev/null
if grep -F 'memory= min= disk= headroom= reserve= command=' "$managed_job_log" >/dev/null 2>&1; then
  printf 'affected verifier should preserve default managed memory guard settings\n' >&2
  exit 1
fi
