#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
mkdir -p "$tmp_root"
export TMPDIR="$tmp_root"
mode="${1:-${CLASP_SWARM_CAPABILITY_AUDIT_MODE:-static}}"
test_root=""

cleanup() {
  rm -rf "${test_root:-}"
}

trap cleanup EXIT

usage() {
  cat <<'EOF'
usage: scripts/test-swarm-capability-audit.sh [static|full]

static  Validate the capability-audit readiness contract without invoking claspc.
full    Run the ordinary Clasp audit program through claspc with fixture reports.
EOF
}

case "$mode" in
  --help|-h)
    usage
    exit 0
    ;;
  static|smoke)
    node - "$project_root" <<'EOF'
const fs = require("node:fs");
const path = require("node:path");

const projectRoot = process.argv[2];
const auditPath = path.join(projectRoot, "examples/swarm-native/SwarmCapabilityAudit.clasp");
const testPath = path.join(projectRoot, "scripts/test-swarm-capability-audit.sh");
const readyGatePath = path.join(projectRoot, "scripts/test-swarm-ready-gate.sh");
const docsPath = path.join(projectRoot, "docs/autonomous-swarm-runtime-requirements.md");

const auditSource = fs.readFileSync(auditPath, "utf8");
const testSource = fs.readFileSync(testPath, "utf8");
const readyGate = fs.readFileSync(readyGatePath, "utf8");
const docs = fs.readFileSync(docsPath, "utf8");

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function requireText(label, text, needle) {
  assert(text.includes(needle), `${label} missing ${needle}`);
}

requireText("audit", auditSource, 'kind = "clasp-swarm-capability-audit"');
requireText("audit", auditSource, 'default_agent_model = "gpt-5.5"');
requireText("audit", auditSource, 'default_agent_reasoning = "xhigh"');
for (const capability of [
  "ordinary_program_execution",
  "durable_native_substrate",
  "clasp_native_control_api",
  "orchestration_viability",
  "ergonomics",
  "verification_gate",
  "safety_governance",
  "standalone_swarm_execution",
]) {
  requireText("audit", auditSource, `"${capability}"`);
}

for (const marker of [
  "record ManagedVerifyAllReport =",
  "record ManagedSwarmProofReport =",
  "record StandaloneClosureReport =",
  "CLASP_SWARM_CAPABILITY_VERIFY_REPORT_JSON",
  "CLASP_SWARM_CAPABILITY_SWARM_PROOF_JSON",
  "CLASP_SWARM_CAPABILITY_STANDALONE_CLOSURE_REPORT_JSON",
  "CLASP_SWARM_CAPABILITY_SPEED_REPORT_JSON",
  "CLASP_SWARM_CAPABILITY_COMPILER_MODULE_SPEED_REPORT_JSON",
  "Managed verify-all passed from",
  "Managed swarm proof passed from",
  "Standalone closure report passed from",
  "standaloneClosureReportPassed : StandaloneClosureReport -> Bool",
  "standaloneClosureEvidence = readStandaloneClosureEvidence standaloneClosureReportPath",
  "Selfhost incremental speed report passed from",
  "Large compiler-module speed report passed from",
  "Affected verification reports now expose per-command resourceClass",
  "compilerStateAccess",
  "canRunWithoutCompilerState",
  "verify-affected reports include affectedVerificationLaunchPolicy",
  "AgentAffectedVerificationLaunchPolicy turns affected verification decisions into explicit",
  "command-level consistency validation fails closed",
  "agentAffectedCommandResourceConsistencyIssues",
  "workspace-fingerprint-manifest",
  "workspaceFingerprintManifestSha256",
  "ResourceGuardConcurrencyDecision",
  "memory-concurrency-admission",
  "admittedChildCapacity",
  "standaloneSwarmClosureRepairKindForDecision",
  "swarm-manifest-repair-worker",
  "standaloneSwarmDirectSourceEditProofMetadataPresent",
  "standaloneSwarmDirectSourceEditRepairHints source-edit-specific repair findings",
  "standaloneSwarmSourceEditRepairTaskForPrompt",
  "swarm-source-patch-repair-worker",
  "LocalRouting and LocalPlanner route affected-verifier launch-policy gaps to affected-verifier-launch-preflight",
  "Affected verification routes AgentErgonomics changes through the explicit static ergonomics contract",
  "AgentAffectedVerificationPlanDecision for turning verify-affected --plan-only JSON",
  "LocalPlannerCatalogReadResult",
  "localRoutePlannerRouteKeyKnown",
  "localPlannerCatalogTaskIssues",
  "localPlannerCatalogTaskDependencyIssues",
  "localPlannerCatalogCycleBlockedTaskIds",
  "planner-catalog-error",
  "unknown route",
  "missing taskId",
  "reserved taskId",
  "missing role",
  "missing detail",
  "missing taskPrompt",
  "missing dependency",
  "self dependency",
  "unknown dependency",
  "duplicate taskId",
  "cycle dependency",
  "clasp-local-planner-task-catalog-error",
  "localRouteTaskKindIterationSpeed",
  "localRoutePlannerRouteKeyProviderNeutral",
  "localRoutePlannerRouteKeyWildcard",
  "LocalAgent verifier prompts can include an Affected verification plan JSON block",
  "direct Affected verification launch policy JSON block",
  "Focused verification plan section",
  "direct Focused verification launch policy JSON block",
  "direct Autonomous launch gate JSON block",
  "agentCapabilityAuditClosureVerificationPlanValidationFromPrompt",
  "agentFocusedVerificationLaunchPolicyFromJson",
  "agentAutonomousLaunchGateFromJson",
  "focused_verification_plan",
  "autonomous_launch_gate",
  "unmanaged heavy focused plans",
  "OOM prevention",
  "CLASP_LOOP_BUILDER_MEMORY_MB_JSON and CLASP_LOOP_VERIFIER_MEMORY_MB_JSON as role-specific launch caps",
  "spawnWatchedProcessWithLimits with CLASP_LOOP_BUILDER_MEMORY_MB_JSON",
  "cancel step.heartbeatPath through the watched-process runtime API",
  "Direct verify-all and verify-affected current-shell paths",
  "CLASP_VERIFY_DIRECT_MEMORY_LIMIT_MB",
  "CLASP_VERIFY_AFFECTED_DIRECT_MEMORY_LIMIT_MB",
  "AgentErgonomics exposes reusable bounded affected-verifier path handoff helpers",
  "CLASP_LOOP_AFFECTED_VERIFICATION_CONTEXT_MAX_MB_JSON",
  "AgentManagedSwarmProofReport",
  "agentManagedSwarmProofJsonFromPrompt",
  "agentManagedSwarmProofDecisionFromPromptOrJson",
  "CLASP_LOOP_MANAGED_SWARM_PROOF_CONTEXT_MAX_MB_JSON",
  "localRouteHasManagedSwarmProofHandoff",
  "managedSwarmProofTaskForPrompt",
  "local_verifier_gate",
  "capability-evidence=",
  "capability-gap=",
  "capability-closure=",
  "AgentCapabilityMailboxSummary",
  "agentCapabilityMailboxSummaryFromPrompt",
  "agentPromptHasCapabilityMailboxGaps",
  "agentCapabilityMailboxClosureDetail",
  "agentCapabilityMailboxClosurePrompt",
  "localRouteHasCapabilityMailboxHandoff",
  "localRouteFocusedVerificationPlanRequiresManaged",
  "localRouteHasAutonomousLaunchGateGap",
  "GoalManagerResourceHealth now derives managerAutonomousLaunchGate",
  "GeneratedStateCleanupPlan section in managerResourceHealthSummary",
  "generated-state-cleanup-can-satisfy-guard",
  "generated-state-cleanup-apply-requires",
  "managerResourceHealthSummary so plannerPromptFor carries current launch permission",
  "GoalManagerTaskExecutionHelpers enforces that same gate",
  "task launch blocked by autonomous launch gate",
  "autonomous-launch-gate-blocker retry recovery records",
  "manager-replan-blocker=autonomous-launch-gate",
  "taskIdsHaveManagerReplanBlocker",
  "Prior swarm mailbox/recovery context",
  "mailboxSummaryText wave in plannerPromptFor",
  "resourceRecoveryMessageIsAutonomousLaunchGateBlocker",
  "retryRecordRecoveryTask=standalone-swarm-autonomous-launch-gate-repair",
  "retryRecordRecoveryKind=autonomous-launch-gate",
  "retryRecordLatest=phase=autonomous-launch-gate",
  "LocalPlanner preserves autonomous launch gate JSON and retry-record evidence",
  "focused-verification-plan-safe-direct:false",
  "focused-verification-launch-policy-mode:managed-required",
  "focused-verification-launch-mode=invalid-plan",
  "capability-gap=focused_verification_plan:",
  "capability-gap=focused_verification_launch_policy:",
  "capability-gap=autonomous_launch_gate:",
  "agentCapabilityAuditClosureRoleForKind",
  "AgentCapabilityAuditClosureVerificationPlan",
  "AgentFocusedVerificationLaunchPolicy",
  "AgentAutonomousLaunchGateInput",
  "AgentAutonomousLaunchGate",
  "agentCapabilityAuditClosureVerificationPlanForKind",
  "agentCapabilityAuditClosureVerificationSectionForKind",
  "agentCapabilityAuditClosureVerificationPlanFromPrompt",
  "agentCapabilityAuditClosureVerificationPlanValidationFromPrompt",
  "agentPromptHasCapabilityAuditClosureVerificationPlan",
  "agentFocusedVerificationLaunchPolicyFromPrompt",
  "agentFocusedVerificationLaunchPolicyJsonFromPrompt",
  "agentAutonomousLaunchGate",
  "agentAutonomousLaunchGateJsonFromPrompt",
  "agentAutonomousLaunchGateFromJson",
  "Focused verification launch policy JSON:",
  "Autonomous launch gate JSON:",
  "blocked-dirty-worktree",
  "blocked-resource-admission",
  "blocked-compiler-mutation",
  "focused-verification-launch:managed-required",
  "focused verification plan",
  "semantic-memory-worker",
  "backend-surface-worker",
  "agentPlannerTaskIdProviderNeutral",
  "agentPlannerTaskIdStandaloneSwarmReadiness",
]) {
  requireText("audit", auditSource, marker);
}

requireText("test", testSource, "CLASP_SWARM_CAPABILITY_AUDIT_MODE:-static");
requireText("test", testSource, "static  Validate the capability-audit readiness contract without invoking claspc.");
requireText("test", testSource, "ordinary-loop role memory cap evidence");
requireText("test", testSource, "ordinary feedback-loop scoped cancellation safety evidence");
requireText("test", testSource, "full    Run the ordinary Clasp audit program through claspc with fixture reports.");
requireText("ready gate", readyGate, "bash scripts/test-swarm-capability-audit.sh");
requireText("ready gate", readyGate, "ordinary feedback-loop scoped cancellation safety evidence");
requireText("docs", docs, "heartbeat-scoped watched-process cancellation");
requireText("docs", docs, "CLASP_LOOP_BUILDER_MEMORY_MB_JSON");
requireText("docs", docs, "AgentManagedSwarmProofReport");
requireText("docs", docs, "agentManagedSwarmProofDecisionFromPromptOrJson");
requireText("docs", docs, "AgentCapabilityAuditClosureVerificationPlan");
requireText("docs", docs, "AgentFocusedVerificationLaunchPolicy");
requireText("docs", docs, "AgentAutonomousLaunchGateInput");
requireText("docs", docs, "AgentAutonomousLaunchGate");
requireText("docs", docs, "Focused verification plan");
requireText("docs", docs, "focused_verification_plan");
requireText("docs", docs, "focused_verification_launch_policy");
requireText("docs", docs, "focused-verification-launch-policy-mode:managed-required");
requireText("docs", docs, "focused-verification-launch-mode=invalid-plan");
requireText("docs", docs, "agentCapabilityAuditClosureVerificationPlanFromPrompt");
requireText("docs", docs, "agentCapabilityAuditClosureVerificationPlanValidationFromPrompt");
requireText("docs", docs, "agentFocusedVerificationLaunchPolicyFromPrompt");
requireText("docs", docs, "agentFocusedVerificationLaunchPolicyJsonFromPrompt");
requireText("docs", docs, "Focused verification launch policy JSON");
requireText("docs", docs, "agentAutonomousLaunchGate");
requireText("docs", docs, "agentAutonomousLaunchGateJsonFromPrompt");
requireText("docs", docs, "agentAutonomousLaunchGateFromJson");
requireText("docs", docs, "Autonomous launch gate JSON");
requireText("docs", docs, "autonomous_launch_gate");
requireText("docs", docs, "blocked-dirty-worktree");
requireText("docs", docs, "blocked-resource-admission");
requireText("docs", docs, "blocked-compiler-mutation");
requireText("docs", docs, "agentCapabilityAuditClosureVerificationSectionForKind \"capability-mailbox\"");
requireText("docs", docs, "Each closure prompt appends");
requireText("docs", docs, "localRouteFocusedVerificationPlanRequiresManaged");
requireText("docs", docs, "localRouteHasAutonomousLaunchGateGap");
requireText("docs", docs, "GoalManagerResourceHealth now derives the manager-side gate");
requireText("docs", docs, "managerAutonomousLaunchGateInputForActiveChildren");
requireText("docs", docs, "managerWorkspaceCheckpointReadyDefault");
requireText("docs", docs, "ManagerWorktreeCheckpoint");
requireText("docs", docs, "scripts/clasp-manager-worktree-checkpoint.sh");
requireText("docs", docs, "managerWorktreeCheckpointMatchesCurrentStatus");
requireText("docs", docs, "managerAutonomousLaunchGateSummary");
requireText("docs", docs, "managerAutonomousLaunchGateRepairMaySpawnForActiveChildren");
requireText("docs", docs, "autonomous-launch-gate-may-spawn-repair:");
requireText("docs", docs, "autonomous-launch-worktree-checkpoint-matches:");
requireText("docs", docs, "plannerTaskSpecIsAutonomousLaunchGateRepair");
requireText("docs", docs, "managerResourceHealthSummary");
requireText("docs", docs, "GeneratedStateCleanupPlan:");
requireText("docs", docs, "CLASP_MANAGER_INCLUDE_GENERATED_CLEANUP_PLAN_JSON");
requireText("docs", docs, "generated-state-cleanup-can-satisfy-guard=");
requireText("docs", docs, "generated-state-cleanup-apply-requires=");
requireText("docs", docs, "plannerPromptFor");
requireText("docs", docs, "GoalManagerTaskExecutionHelpers");
requireText("docs", docs, "launchReadyTaskForActiveChildren");
requireText("docs", docs, "launchChildLoopForActiveChildren");
requireText("docs", docs, "task launch blocked by autonomous launch gate");
requireText("docs", docs, "autonomous-launch-gate-blocker");
requireText("docs", docs, "manager-replan-blocker=autonomous-launch-gate");
requireText("docs", docs, "taskIdsHaveManagerReplanBlocker");
requireText("docs", docs, "Prior swarm mailbox/recovery context");
requireText("docs", docs, "mailboxSummaryText wave");
requireText("docs", docs, "resourceRecoveryMessageIsAutonomousLaunchGateBlocker");
requireText("docs", docs, "retryRecordRecoveryTask=standalone-swarm-autonomous-launch-gate-repair");
requireText("docs", docs, "retryRecordRecoveryKind=autonomous-launch-gate");
requireText("docs", docs, "retryRecordLatest=phase=autonomous-launch-gate");
requireText("docs", docs, "LocalPlanner preserves");
requireText("docs", docs, "clasp-managed-swarm-proof");
requireText("docs", docs, "AgentCapabilityMailboxSummary");
requireText("docs", docs, "localRouteHasCapabilityMailboxHandoff");
requireText("docs", docs, "commandResourceSummary");
requireText("docs", docs, "AgentAffectedVerificationPlanDecision");
requireText("docs", docs, "Affected-verifier and capability-audit context handoff is bounded");
requireText("docs", docs, "agentPromptBlockText");
requireText("docs", docs, "agentPromptHasBuilderContextPack");
requireText("docs", docs, "agentPromptHasDependencyCompletionEvidence");
requireText("docs", docs, "agentAffectedVerificationPlanJsonFromPrompt");
requireText("docs", docs, "agentPromptWithAffectedVerificationPathContext");
requireText("docs", docs, "agentPromptHasAgentBackendPolicyRepair");
requireText("docs", docs, "agentPromptHasPlannerBackendPolicyRepair");
requireText("docs", docs, "agentBoundedAffectedVerificationPlanJsonFromPath");
requireText("docs", docs, "sourceEditPromptSection");
requireText("docs", docs, "standaloneSwarmSourceEditPromptSection");
requireText("docs", docs, "AgentCapabilityAuditClosureDecision");
requireText("docs", docs, "AgentCapabilityAuditClosureInput");
requireText("docs", docs, "AgentCapabilityAuditJsonReport");
requireText("docs", docs, "agentCapabilityAuditJsonFromPrompt");
requireText("docs", docs, "agentCapabilityAuditJsonPathFromPrompt");
requireText("docs", docs, "agentBoundedCapabilityAuditJsonFromPath");
requireText("docs", docs, "agentCapabilityAuditDecisionJsonFromPrompt");
requireText("docs", docs, "agentCapabilityAuditDecisionJsonPathFromPrompt");
requireText("docs", docs, "agentBoundedCapabilityAuditDecisionJsonFromPath");
requireText("docs", docs, "agentCapabilityAuditClosureDecisionFromPrompt");
requireText("docs", docs, "agentCapabilityAuditClosureDecisionFromPromptOrJson");
requireText("docs", docs, "agentCapabilityAuditClosureDecisionFromEntries");
requireText("docs", docs, "agentCapabilityAuditClosureDecisionFromJson");
requireText("docs", docs, "agentCapabilityAuditClosureDecisionFromDecisionJson");
requireText("docs", docs, "capabilityAuditTaskForDecisionJson");
requireText("docs", docs, "agentPromptHasCapabilityAuditContextGap");
requireText("docs", docs, "CLASP_LOOP_CAPABILITY_AUDIT_CONTEXT_MAX_MB_JSON");
requireText("docs", docs, "Standalone swarm closure report JSON path");
requireText("docs", docs, "CLASP_LOOP_STANDALONE_SWARM_CLOSURE_CONTEXT_MAX_MB_JSON");
requireText("docs", docs, "CLASP_SWARM_CAPABILITY_STANDALONE_CLOSURE_REPORT_JSON");
requireText("docs", docs, "standaloneSwarmClosureDecisionFromJson");
requireText("docs", docs, "standaloneSwarmTaskForClosureReportPath");
requireText("docs", docs, "agentPromptHasCapabilityAuditVerifyAllGap");
requireText("docs", docs, "agentPromptHasCapabilityAuditSwarmProofGap");
requireText("docs", docs, "agentPromptHasCapabilityAuditNativeRuntimeGap");
requireText("docs", docs, "agentPromptHasCapabilityAuditBackendSurfaceGap");
requireText("docs", docs, "agentPromptHasCapabilityAuditSafetyGap");
requireText("docs", docs, "agentCapabilityAuditClosurePromptFromPrompt");
requireText("docs", docs, "agentPlannerTaskBudgetContractLine");
requireText("docs", docs, "agentPromptTaskBudgetOrDefault");
requireText("docs", docs, "agentPlannerTaskIdProviderNeutral");
requireText("docs", docs, "agentPlannerTaskIdStandaloneSwarmReadiness");
requireText("docs", docs, "agentPlannerReservedTaskId");
requireText("docs", docs, "localRouteSelectsProviderNeutral");
requireText("docs", docs, "localRoutePlannerRouteKeyForPrompt");
requireText("docs", docs, "localRouteTaskKindIterationSpeed");
requireText("docs", docs, "localRoutePlannerRouteKeyProviderNeutral");
requireText("docs", docs, "localRoutePlannerRouteKeyWildcard");
requireText("docs", docs, "LocalPlannerCatalogReadResult");
requireText("docs", docs, "localRoutePlannerRouteKeyKnown");
requireText("docs", docs, "Unknown route keys");
requireText("docs", docs, "missing `detail`");
requireText("docs", docs, "reserved planner task id");
requireText("docs", docs, "empty dependency ids");
requireText("docs", docs, "self-dependencies");
requireText("docs", docs, "unknown dependencies");
requireText("docs", docs, "duplicate task ids");
requireText("docs", docs, "dependency cycles");
requireText("docs", docs, "cycle-blocked dependencies");
requireText("docs", docs, "planner-catalog-error");
requireText("docs", docs, "clasp-local-planner-task-catalog-error");
requireText("docs", docs, "broad managed swarm proof gaps become GoalManager local planner/child-loop proof work");
requireText("docs", docs, "native workflow/supervisor/tool/verifier/mergegate parity gaps become ordinary-Clasp runtime-surface work");
requireText("docs", docs, "full backend surface parity without JS helpers becomes backend-policy/data/runtime-binding work");
requireText("docs", docs, "machine-readable `blocking_gaps` / `required_closure` arrays");
requireText("docs", docs, "one reusable first-task decision from the audit");
requireText("docs", docs, "hostile-tool packaging");
requireText("docs", docs, "safety/governance gaps become hostile-tool policy work");
requireText("docs", docs, "CLASP_LOOP_AFFECTED_VERIFICATION_CONTEXT_MAX_MB_JSON");
requireText("docs", docs, "distinguish static-only/compiler-state-free routes from focused managed routes and heavy managed verifier work");

process.stdout.write("swarm-capability-audit-static-ok\n");
EOF
    exit 0
    ;;
  full)
    ;;
  *)
    printf 'test-swarm-capability-audit: unknown mode: %s\n' "$mode" >&2
    usage >&2
    exit 2
    ;;
esac

test_root="$(mktemp -d "$TMPDIR/test-swarm-capability-audit.XXXXXX")"
claspc_bin="$(env -u CLASP_CLASPC -u CLASPC_BIN -u RUSTC "$project_root/scripts/resolve-claspc.sh")"
program_path="$project_root/examples/swarm-native/SwarmCapabilityAudit.clasp"
output_path="$test_root/swarm-capability-audit-missing-report.json"
verified_output_path="$test_root/swarm-capability-audit-verified-report.json"
swarm_verified_output_path="$test_root/swarm-capability-audit-swarm-verified-report.json"
speed_verified_output_path="$test_root/swarm-capability-audit-speed-verified-report.json"
verify_report_path="$test_root/managed-verify-pass.json"
swarm_proof_path="$test_root/managed-swarm-proof.json"
speed_report_path="$test_root/selfhost-incremental-speed-report.json"
compiler_module_speed_report_path="$test_root/compiler-module-speed-report.json"
audit_timeout_secs="${CLASP_SWARM_CAPABILITY_AUDIT_TIMEOUT_SECS:-120}"

cat >"$verify_report_path" <<'JSON'
{
  "schemaVersion": 1,
  "finalVerdict": "passed",
  "exitStatus": 0,
  "elapsedMs": 375136,
  "commandCount": 72,
  "commands": [
    {"command": "bash scripts/test-selfhost.sh", "elapsedMs": 81700, "exitStatus": 0}
  ]
}
JSON

cat >"$swarm_proof_path" <<'JSON'
{
  "schemaVersion": 1,
  "kind": "clasp-managed-swarm-proof",
  "verdict": "pass",
  "managerCompleted": true,
  "managerFinal": true,
  "plannerBackendKind": "template",
  "plannerBackendTransport": "prompt-path",
  "codexFallbackInvoked": false,
  "taskCount": 3,
  "completedTaskCount": 3,
  "dependencyOrdered": true,
  "localPlannerBackend": true,
  "localAgentCommandPropagated": true,
  "sourceEditPlanDelivered": true,
  "sourcePatchPlanDelivered": true,
  "dependencyEvidenceDelivered": true,
  "taskIds": ["iteration-speed-loop", "semantic-context-routing", "standalone-swarm-readiness"]
}
JSON

cat >"$speed_report_path" <<'JSON'
{
  "schemaVersion": 1,
  "scenario": "selfhost-body-change",
  "matchesExpectations": true,
  "observedCacheBehavior": {
    "image": {
      "buildPlan": "hit",
      "declModule": {
        "Helper": "miss",
        "Main": "hit"
      }
    }
  },
  "advisoryTimings": {
    "checkBodyChange": {
      "realSeconds": 0.62
    },
    "imageBodyChange": {
      "realSeconds": 1.35
    }
  }
}
JSON

cat >"$compiler_module_speed_report_path" <<'JSON'
{
  "schemaVersion": 1,
  "scenario": "selfhost-compiler-module-body-change",
  "matchesExpectations": true,
  "observedCacheBehavior": {
    "check": {
      "moduleSummary": {
        "Compiler.Ast": "validated-hit",
        "CompilerMain": "hit"
      }
    }
  },
  "advisoryTimings": {
    "compilerCheckCold": {
      "realSeconds": 5.64
    },
    "compilerCheckBodyChange": {
      "realSeconds": 7.89
    }
  },
  "meta": {
    "compilerModuleImageProbe": "skipped"
  }
}
JSON

env RUSTC=/definitely-missing-rustc \
  "$claspc_bin" --json check "$program_path" >/dev/null

env RUSTC=/definitely-missing-rustc \
  timeout "$audit_timeout_secs" \
  "$claspc_bin" run "$program_path" \
  >"$output_path"

env RUSTC=/definitely-missing-rustc \
  CLASP_SWARM_CAPABILITY_VERIFY_REPORT_JSON="$verify_report_path" \
  timeout "$audit_timeout_secs" \
  "$claspc_bin" run "$program_path" \
  >"$verified_output_path"

env RUSTC=/definitely-missing-rustc \
  CLASP_SWARM_CAPABILITY_VERIFY_REPORT_JSON="$verify_report_path" \
  CLASP_SWARM_CAPABILITY_SWARM_PROOF_JSON="$swarm_proof_path" \
  timeout "$audit_timeout_secs" \
  "$claspc_bin" run "$program_path" \
  >"$swarm_verified_output_path"

env RUSTC=/definitely-missing-rustc \
  CLASP_SWARM_CAPABILITY_VERIFY_REPORT_JSON="$verify_report_path" \
  CLASP_SWARM_CAPABILITY_SWARM_PROOF_JSON="$swarm_proof_path" \
  CLASP_SWARM_CAPABILITY_SPEED_REPORT_JSON="$speed_report_path" \
  CLASP_SWARM_CAPABILITY_COMPILER_MODULE_SPEED_REPORT_JSON="$compiler_module_speed_report_path" \
  timeout "$audit_timeout_secs" \
  "$claspc_bin" run "$program_path" \
  >"$speed_verified_output_path"

node - "$output_path" "$verified_output_path" "$swarm_verified_output_path" "$speed_verified_output_path" <<'EOF'
const fs = require("node:fs");

const missingAudit = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const verifiedAudit = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
const swarmVerifiedAudit = JSON.parse(fs.readFileSync(process.argv[4], "utf8"));
const speedVerifiedAudit = JSON.parse(fs.readFileSync(process.argv[5], "utf8"));

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function statusFor(audit, name) {
  return audit.capability_statuses.find((status) => status.name === name);
}

const requiredNames = [
  "ordinary_program_execution",
  "durable_native_substrate",
  "clasp_native_control_api",
  "orchestration_viability",
  "ergonomics",
  "verification_gate",
  "safety_governance",
  "standalone_swarm_execution",
];

function assertAuditShape(audit, label) {
  assert(audit.schema_version === 1, `${label} schema_version ${audit.schema_version}`);
  assert(audit.kind === "clasp-swarm-capability-audit", `${label} kind ${audit.kind}`);
  assert(audit.overall_status === "partial", `${label} overall_status ${audit.overall_status}`);
  assert(audit.default_agent_model === "gpt-5.5", `${label} default_agent_model ${audit.default_agent_model}`);
  assert(audit.default_agent_reasoning === "xhigh", `${label} default_agent_reasoning ${audit.default_agent_reasoning}`);
  assert(Array.isArray(audit.capability_statuses), `${label} capability_statuses must be an array`);

  for (const name of requiredNames) {
    const status = statusFor(audit, name);
    assert(status, `${label} missing capability status ${name}`);
    assert(["pass", "partial", "fail"].includes(status.status), `${label} invalid status for ${name}: ${status.status}`);
    assert(Array.isArray(status.evidence) && status.evidence.length > 0, `${label} missing evidence for ${name}`);
    assert(Array.isArray(status.blocking_gaps), `${label} missing blocking_gaps for ${name}`);
    assert(Array.isArray(status.required_closure), `${label} missing required_closure for ${name}`);
  }
}

assertAuditShape(missingAudit, "missing-report");
assertAuditShape(verifiedAudit, "verified-report");
assertAuditShape(swarmVerifiedAudit, "swarm-verified-report");
assertAuditShape(speedVerifiedAudit, "speed-verified-report");

const partialStatuses = missingAudit.capability_statuses.filter((status) => status.status !== "pass");
assert(partialStatuses.length >= 3, "audit should not falsely claim full readiness");
const missingGate = statusFor(missingAudit, "verification_gate");
assert(missingGate.status === "partial", `missing report gate status ${missingGate.status}`);
assert(missingAudit.blocking_gaps.some((gap) => gap.includes("verify-all")), "missing verify-all gap");
assert(missingAudit.blocking_gaps.some((gap) => gap.includes("Compiler rebuild")), "missing iteration-speed gap");
assert(missingAudit.required_closure.some((step) => step.includes("scripts/run-managed-job.sh")), "missing managed verification closure");
assert(missingAudit.verification_notes.some((note) => note.includes("does not launch agents")), "audit should stay lightweight");
assert(missingAudit.verification_notes.some((note) => note.includes("OOM prevention")), "missing OOM prevention note");
assert(missingAudit.verification_notes.some((note) => note.includes("CLASP_SWARM_CAPABILITY_VERIFY_REPORT_JSON")), "missing report env note");
assert(missingAudit.verification_notes.some((note) => note.includes("CLASP_SWARM_CAPABILITY_STANDALONE_CLOSURE_REPORT_JSON")), "missing standalone closure report env note");

const ordinary = statusFor(missingAudit, "ordinary_program_execution");
assert(
  ordinary.evidence.some((item) =>
    item.includes("CLASP_LOOP_BUILDER_MEMORY_MB_JSON") &&
    item.includes("CLASP_LOOP_VERIFIER_MEMORY_MB_JSON") &&
    item.includes("role-specific launch caps") &&
    item.includes("CLASP_LOOP_WATCH_MEMORY_MB_JSON")
  ),
  "missing ordinary-loop role memory cap evidence",
);

const verifiedGate = statusFor(verifiedAudit, "verification_gate");
assert(verifiedGate.status === "pass", `verified report gate status ${verifiedGate.status}`);
assert(
  verifiedGate.evidence.some((item) => item.includes("Managed verify-all passed") && item.includes("commandCount=72") && item.includes("elapsedMs=375136")),
  "missing passing managed verification evidence",
);
assert(!verifiedGate.blocking_gaps.some((gap) => gap.includes("verify-all")), "verified gate should not retain verify-all gaps");
assert(!verifiedAudit.blocking_gaps.some((gap) => gap.includes("verify-all")), "verified audit should not retain verify-all gaps");
assert(verifiedAudit.blocking_gaps.some((gap) => gap.includes("Broad self-improving swarm")), "verified audit should still require broad swarm proof");
assert(verifiedAudit.blocking_gaps.some((gap) => gap.includes("Compiler rebuild")), "verified audit should still require iteration-speed work");
assert(!verifiedAudit.required_closure.some((step) => step.includes("verify-all.sh")), "verified audit should not require rerunning already-proven verification");
assert(
  verifiedAudit.required_closure.some((step) => step.includes("CLASP_GOAL_MANAGER_SWARM_PROOF_REPORT_JSON")),
  "verified audit should still require the managed swarm proof report",
);
assert(verifiedAudit.verification_notes.some((note) => note.includes("Managed verification report consumed")), "missing managed report consumption note");
assert(verifiedAudit.verification_notes.some((note) => note.includes("broad swarm proof")), "verified audit should still explain partial status");

const swarmVerifiedGate = statusFor(swarmVerifiedAudit, "verification_gate");
const swarmVerifiedOrchestration = statusFor(swarmVerifiedAudit, "orchestration_viability");
assert(swarmVerifiedGate.status === "pass", `swarm verified gate status ${swarmVerifiedGate.status}`);
assert(
  swarmVerifiedOrchestration.evidence.some((item) => item.includes("Managed swarm proof passed") && item.includes("taskCount=3") && item.includes("completedTaskCount=3")),
  "missing passing managed swarm proof evidence",
);
assert(!swarmVerifiedAudit.blocking_gaps.some((gap) => gap.includes("Broad self-improving swarm")), "swarm proof should clear the broad swarm proof gap");
assert(swarmVerifiedAudit.blocking_gaps.some((gap) => gap.includes("Compiler rebuild")), "swarm proof should still require iteration-speed work");
assert(!swarmVerifiedAudit.blocking_gaps.some((gap) => gap.includes("hostname-transparent hostile-tool egress")), "hostname-transparent hostile-tool network work should now be covered");
assert(!swarmVerifiedAudit.blocking_gaps.some((gap) => gap.includes("Filesystem mediation")), "first-class read-only filesystem policy should not remain a top-level blocker");
assert(!swarmVerifiedAudit.blocking_gaps.some((gap) => gap.includes("Standalone non-Codex")), "repo-scale local proof should clear the standalone backend gap");
assert(
  !swarmVerifiedAudit.required_closure.some((step) => step.includes("CLASP_GOAL_MANAGER_SWARM_PROOF_REPORT_JSON")),
  "swarm proof should not require rerunning already-proven manager proof",
);
assert(swarmVerifiedAudit.verification_notes.some((note) => note.includes("Managed swarm proof consumed")), "missing managed swarm proof consumption note");
assert(
  swarmVerifiedAudit.verification_notes.some((note) => note.includes("iteration speed and remaining capability ergonomics")),
  "swarm verified audit should explain remaining partial status",
);

const orchestration = statusFor(missingAudit, "orchestration_viability");
assert(
  orchestration.evidence.some((item) => item.includes("typed sparse semantic-memory embeddings") && item.includes("SwarmEmbeddedMemoryValue")),
  "missing sparse semantic-memory evidence",
);
assert(
  orchestration.evidence.some((item) => item.includes("fixed-point weighted semantic-memory embeddings") && item.includes("SwarmWeightedEmbeddedMemoryValue")),
  "missing weighted semantic-memory evidence",
);
assert(
  orchestration.evidence.some((item) => item.includes("provider-style embedding trust boundary") && item.includes("SwarmWeightedVectorIndex") && item.includes("swarmWeightedVectorIndexSearch")),
  "missing provider-validated vector index evidence",
);
assert(
  orchestration.evidence.some((item) => item.includes("sharded weighted vector store") && item.includes("SwarmWeightedVectorStore") && item.includes("swarmWeightedVectorStoreSearch")),
  "missing sharded weighted vector store evidence",
);
assert(
  orchestration.evidence.some((item) => item.includes("command-template embedding provider transport") && item.includes("SwarmEmbeddingProviderCommandTransport") && item.includes("swarmRunEmbeddingProviderCommand")),
  "missing embedding provider command transport evidence",
);
assert(
  orchestration.evidence.some((item) => item.includes("authenticated/network embedding adapter configuration") && item.includes("swarmEmbeddingProviderBearerNetworkAdapter") && item.includes("swarmOpenAiEmbeddingProviderNetworkAdapter") && item.includes("swarmRunEmbeddingProviderNetworkAdapter")),
  "missing embedding provider network adapter configuration evidence",
);
assert(
  orchestration.evidence.some((item) => item.includes("ResourceRecoveryPolicy classifies") && item.includes("OOM-kill") && item.includes("exit-status=137") && item.includes("resource-memory-pressure recovery")),
  "missing OOM-kill resource recovery evidence",
);
assert(
  orchestration.evidence.some((item) => item.includes("ResourceGuardConcurrencyDecision") && item.includes("memory-concurrency-admission") && item.includes("admittedChildCapacity")),
  "missing memory concurrency admission evidence",
);
assert(
  orchestration.evidence.some((item) =>
    item.includes("GoalManagerResourceHealth now includes a read-only GeneratedStateCleanupPlan section") &&
    item.includes("generated-state-cleanup-can-satisfy-guard") &&
    item.includes("generated-state-cleanup-apply-requires")
  ),
  "missing generated-state cleanup projection evidence",
);
assert(
  !orchestration.blocking_gaps.some((gap) => gap.includes("Provider-backed embedding generation")),
  "provider-backed embedding generation should no longer be a missing top-level blocker",
);
assert(
  orchestration.blocking_gaps.some((gap) => gap.includes("reusable bearer/OpenAI-compatible profiles") && gap.includes("native/provider-specific HTTP adapter execution") && gap.includes("approximate vector-store persistence")),
  "missing provider-specific embedding adapter follow-on gap",
);
assert(
  orchestration.required_closure.some((step) => step.includes("native/provider-specific HTTP embedding adapter execution") && step.includes("approximate/vector-database persistence")),
  "missing scaled vector store closure",
);

assert(!speedVerifiedAudit.blocking_gaps.some((gap) => gap.includes("Compiler rebuild and promotion latency still slows autonomous iteration.")), "speed proof should clear the stale compiler rebuild blocker");
assert(!speedVerifiedAudit.blocking_gaps.some((gap) => gap.includes("large real compiler-module edits")), "compiler-module speed proof should clear the larger compiler edit proof blocker");
assert(!speedVerifiedAudit.blocking_gaps.some((gap) => gap.includes("Filesystem mediation")), "speed proof should not reintroduce filesystem policy as a top-level blocker");
assert(
  !speedVerifiedAudit.required_closure.some((step) => step.includes("large compiler-module edit speed proof")),
  "compiler-module speed proof should remove large compiler edit proof closure",
);
assert(
  speedVerifiedAudit.verification_notes.some((note) => note.includes("Selfhost iteration-speed report consumed")),
  "speed proof should record speed report consumption",
);
assert(
  speedVerifiedAudit.verification_notes.some((note) => note.includes("Large compiler-module speed report consumed")),
  "speed proof should record compiler-module speed report consumption",
);
assert(
  speedVerifiedAudit.verification_notes.some((note) => note.includes("remaining capability ergonomics")),
  "speed verified audit should explain remaining capability partial status",
);

const safety = statusFor(missingAudit, "safety_governance");
assert(safety.evidence.some((item) => item.includes("CLASP_SWARM_NETWORK_MEDIATOR_JSON")), "missing network mediator hook evidence");
assert(safety.evidence.some((item) => item.includes("network_mediation_started")), "missing network mediation event evidence");
assert(safety.evidence.some((item) => item.includes("clasp-network-egress-enforcer.mjs")), "missing checked-in egress adapter evidence");
assert(safety.evidence.some((item) => item.includes("CLASP_SWARM_NETWORK_EGRESS_BACKEND_JSON")), "missing egress backend contract evidence");
assert(safety.evidence.some((item) => item.includes("clasp-network-egress-backend.mjs")), "missing checked-in host egress backend evidence");
assert(safety.evidence.some((item) => item.includes("clasp-network-egress-guard.c")), "missing checked-in egress guard evidence");
assert(safety.evidence.some((item) => item.includes("clasp-network-egress-kernel-backend.mjs")), "missing checked-in kernel egress backend evidence");
assert(safety.evidence.some((item) => item.includes("direct SYS_connect client")), "missing direct syscall kernel egress evidence");
assert(safety.evidence.some((item) => item.includes("namespace-private /etc/hosts")), "missing hostname-transparent kernel hosts evidence");
assert(safety.evidence.some((item) => item.includes("CLASP_NETWORK_EGRESS_HOSTNAME_TRANSPARENT")), "missing hostname-transparent env evidence");
assert(safety.evidence.some((item) => item.includes("hostname-resolving direct SYS_connect client")), "missing hostname direct syscall evidence");
assert(safety.evidence.some((item) => item.includes("SwarmTaskCapabilities")), "missing task capability record evidence");
assert(safety.evidence.some((item) => item.includes("destructive-action approval")), "missing destructive action approval evidence");
assert(safety.evidence.some((item) => item.includes("filesystem_permission_denied")), "missing destructive filesystem target denial evidence");
assert(safety.evidence.some((item) => item.includes("rm/rmdir/unlink") && item.includes("git clean/reset")), "missing direct destructive target mediation evidence");
assert(safety.evidence.some((item) => item.includes("bash/sh/zsh -c") && item.includes("dynamic shell filesystem operands")), "missing shell destructive target mediation evidence");
assert(safety.evidence.some((item) => item.includes("CLASP_SWARM_FILESYSTEM_MEDIATOR_JSON")), "missing filesystem mediator hook evidence");
assert(safety.evidence.some((item) => item.includes("clasp-filesystem-write-enforcer.mjs")), "missing filesystem write enforcer evidence");
assert(safety.evidence.some((item) => item.includes("clasp-filesystem-write-guard.c")), "missing filesystem write guard evidence");
assert(safety.evidence.some((item) => item.includes("libc write/create/delete/rename")), "missing libc filesystem write mediation evidence");
assert(safety.evidence.some((item) => item.includes("CLASP_SWARM_FILESYSTEM_WRITE_BACKEND_JSON")), "missing filesystem backend contract evidence");
assert(safety.evidence.some((item) => item.includes("clasp-filesystem-write-kernel-backend.mjs")), "missing filesystem kernel backend evidence");
assert(safety.evidence.some((item) => item.includes("fresh user/mount namespace") && item.includes("chroot")), "missing kernel filesystem namespace evidence");
assert(safety.evidence.some((item) => item.includes("cc -nostdlib -static") && item.includes("out-of-workspace open syscall")), "missing static direct syscall filesystem evidence");
assert(safety.evidence.some((item) => item.includes("allowedReadonlyRoots") && item.includes("readonlyFilesystemRoots")), "missing read-only dependency root policy evidence");
assert(safety.evidence.some((item) => item.includes("--readonly-roots-json") && item.includes("read-only bind mounts")), "missing read-only mediator transport evidence");
assert(safety.evidence.some((item) => item.includes("dynamic direct-syscall clients") && item.includes("read-only dependency mounts")), "missing dynamic direct syscall filesystem evidence");
assert(safety.evidence.some((item) => item.includes("systemd MemoryMax scope")), "missing scoped memory evidence");
assert(
  safety.evidence.some((item) =>
    item.includes("spawnWatchedProcessWithLimits") &&
    item.includes("CLASP_LOOP_BUILDER_MEMORY_MB_JSON") &&
    item.includes("CLASP_LOOP_VERIFIER_MEMORY_MB_JSON") &&
    item.includes("unbounded")
  ),
  "missing ordinary feedback-loop role memory cap safety evidence",
);
assert(
  safety.evidence.some((item) =>
    item.includes("cancel step.heartbeatPath") &&
    item.includes("heartbeat/token-scoped cancellation") &&
    item.includes("ad hoc PID") &&
    item.includes("pkill")
  ),
  "missing ordinary feedback-loop scoped cancellation safety evidence",
);
assert(
  safety.evidence.some((item) =>
    item.includes("Direct verify-all and verify-affected current-shell paths") &&
    item.includes("CLASP_VERIFY_DIRECT_MEMORY_LIMIT_MB") &&
    item.includes("CLASP_VERIFY_AFFECTED_DIRECT_MEMORY_LIMIT_MB") &&
    item.includes("unbounded verifier path")
  ),
  "missing direct verifier memory cap safety evidence",
);
assert(
  safety.evidence.some((item) =>
    item.includes("Managed-job force stops are exact-marker-only") &&
    item.includes("refuses current shell process group or session metadata") &&
    item.includes("refuses unmarked same-session members") &&
    item.includes("CLASP_MANAGED_JOB_ID") &&
    item.includes("CLASP_MANAGED_JOB_ROOT") &&
    item.includes("CLASP_MANAGED_JOB_TOKEN")
  ),
  "missing exact-marker-only managed job stop evidence",
);
assert(
  safety.evidence.some((item) => item.includes("no CLASP_MANAGED_JOB_FORCE_STOP_UNMARKED_SESSION bypass")),
  "missing removed unmarked-session stop bypass evidence",
);
assert(safety.blocking_gaps.some((gap) => gap.includes("richer hostile-tool packaging remains follow-on work")), "missing remaining safety follow-on gap");
assert(!safety.required_closure.some((item) => item.includes("DNS-aware kernel egress mediation")), "hostname-transparent network mediation should not remain required");
assert(!safety.required_closure.some((item) => item.includes("syscall-level")), "static direct syscall filesystem mediation should not remain required");
assert(!safety.required_closure.some((item) => item.includes("non-static hostile native tools")), "dynamic direct syscall filesystem mediation should not remain required");
assert(!safety.required_closure.some((item) => item.includes("read-only dependency roots") && item.includes("task capabilities")), "first-class dependency-root policy should not remain required");

const ergonomics = statusFor(missingAudit, "ergonomics");
assert(
  ergonomics.evidence.some((item) => item.includes("cache-key generation memoizes image and launcher file bytes")),
  "missing native cache-key byte memoization evidence",
);
assert(
  ergonomics.evidence.some((item) => item.includes("routes iteration-speed evidence changes")),
  "missing iteration-speed affected-route evidence",
);
assert(
  ergonomics.evidence.some((item) =>
    item.includes("GoalManagerPlannerInputState") &&
    item.includes("planner memory") &&
    item.includes("rendered mailbox summary/details") &&
    item.includes("workspace task-catalog evidence")
  ),
  "missing planner input reuse evidence",
);
assert(
  ergonomics.evidence.some((item) => item.includes("cutting the focused body-change probe from 21.11s to 1.44s")),
  "missing in-process decl export speed evidence",
);
assert(
  ergonomics.evidence.some((item) => item.includes("bounded recursive workspaceListTree inventory") && item.includes("workspaceSearchText") && item.includes("workspaceReplaceText") && item.includes("checked edits") && item.includes("without shelling out")),
  "missing root-confined workspace tree/search/edit ergonomics evidence",
);
assert(
  ergonomics.evidence.some((item) => item.includes("AgentErgonomics.clasp") && item.includes("typed validation issues/summaries") && item.includes("process preflight errors")),
  "missing typed agent validation ergonomics evidence",
);
assert(
  ergonomics.evidence.some((item) => item.includes("AgentCheckedProcessRun") && item.includes("agentRunWorkspaceCommandTimeoutChecked") && item.includes("preflighted workspace command execution")),
  "missing checked process-run ergonomics evidence",
);
assert(
  ergonomics.evidence.some((item) => item.includes("AgentCommandStep") && item.includes("AgentCommandPlanResult") && item.includes("agentRunCommandPlanFailFast") && item.includes("aggregated evidence")),
  "missing checked command-plan ergonomics evidence",
);
assert(
  ergonomics.evidence.some((item) => item.includes("AgentVerifierMemoryPolicy") && item.includes("agentVerifierMemoryPolicySummary") && item.includes("direct verifier memory caps")),
  "missing verifier memory policy ergonomics evidence",
);
assert(
  ergonomics.evidence.some((item) => item.includes("AgentVerifierGate") && item.includes("agentVerifierGate") && item.includes("memory policy plus command-plan results")),
  "missing typed verifier gate ergonomics evidence",
);
assert(
  ergonomics.evidence.some((item) => item.includes("batch validation-summary aggregation") && item.includes("source-edit preflight errors")),
  "missing batch validation aggregation ergonomics evidence",
);
assert(
  ergonomics.evidence.some((item) => item.includes("JSON decode and required-field validation summaries around tryDecode")),
  "missing JSON decode validation ergonomics evidence",
);
assert(
  ergonomics.evidence.some((item) => item.includes("checked workspace patch specs/results") && item.includes("preflighted root-confined exact replacements")),
  "missing checked workspace patch ergonomics evidence",
);
assert(
  ergonomics.evidence.some((item) => item.includes("agentCapabilityAuditDecisionJsonFromPrompt") && item.includes("agentBoundedCapabilityAuditDecisionJsonFromPath") && item.includes("direct decision JSON/path handoffs")),
  "missing direct capability-audit decision handoff ergonomics evidence",
);
assert(
  ergonomics.evidence.some((item) => item.includes("AgentManagedSwarmProofReport") && item.includes("agentBoundedManagedSwarmProofJsonFromPath") && item.includes("CLASP_LOOP_MANAGED_SWARM_PROOF_CONTEXT_MAX_MB_JSON") && item.includes("managedSwarmProofTaskForPrompt")),
  "missing managed swarm proof handoff ergonomics evidence",
);
assert(
  ergonomics.evidence.some((item) => item.includes("AgentCapabilityMailboxSummary") && item.includes("agentCapabilityMailboxSummaryFromPrompt") && item.includes("agentCapabilityMailboxClosurePrompt") && item.includes("capability-gap=") && item.includes("agentCapabilityAuditClosureVerificationSectionForKind \"capability-mailbox\"") && item.includes("localRouteHasCapabilityMailboxHandoff")),
  "missing capability mailbox summary ergonomics evidence",
);
assert(
  ergonomics.evidence.some((item) => item.includes("agentCapabilityAuditClosureRoleForKind") && item.includes("semantic-memory-worker") && item.includes("backend-surface-worker")),
  "missing typed capability closure role evidence",
);
assert(
  ergonomics.evidence.some((item) => item.includes("AgentCapabilityAuditClosureVerificationPlan") && item.includes("AgentFocusedVerificationLaunchPolicy") && item.includes("agentCapabilityAuditClosureVerificationPlanForKind") && item.includes("agentCapabilityAuditClosureVerificationPlanFromPrompt") && item.includes("agentCapabilityAuditClosureVerificationPlanValidationFromPrompt") && item.includes("agentFocusedVerificationLaunchPolicyFromPrompt") && item.includes("agentFocusedVerificationLaunchPolicyJsonFromPrompt") && item.includes("focused verification plan")),
  "missing capability closure focused verification plan evidence",
);
assert(
  ergonomics.evidence.some((item) => item.includes("AgentAutonomousLaunchGateInput") && item.includes("AgentAutonomousLaunchGate") && item.includes("agentAutonomousLaunchGate") && item.includes("agentAutonomousLaunchGateJsonFromPrompt") && item.includes("agentAutonomousLaunchGateFromJson")),
  "missing autonomous launch gate ergonomics evidence",
);

const speedErgonomics = statusFor(speedVerifiedAudit, "ergonomics");
assert(
  speedErgonomics.evidence.some((item) => item.includes("Selfhost incremental speed report passed") && item.includes("buildPlan is a hit")),
  "missing selfhost body-change buildPlan hit evidence",
);
assert(
  speedErgonomics.evidence.some((item) => item.includes("content-scoped for compiler images across XDG cache roots")),
  "missing compiler export host content-scope evidence",
);
assert(
  speedErgonomics.evidence.some((item) => item.includes("scans arrays once") && item.includes("loaded embedded.compiler.native.image.json in 651ms")),
  "missing single-pass native image array load evidence",
);
assert(
  speedErgonomics.evidence.some((item) => item.includes("native-cli checkCold=1.41s") && item.includes("selfhost imageCold=2.63s")),
  "missing current cold/body-change speed probe evidence",
);
assert(
  speedErgonomics.evidence.some((item) => item.includes("old ~20s selfhost body-change image cliff")),
  "missing selfhost speed cliff guard evidence",
);
assert(
  speedErgonomics.evidence.some((item) => item.includes("Large compiler-module speed report passed") && item.includes("Compiler.Ast body-change check")),
  "missing consumed large compiler-module speed report evidence",
);
assert(
  speedErgonomics.evidence.some((item) => item.includes("compilerCheckCold=5.64s") && item.includes("compilerCheckBodyChange=7.89s")),
  "missing large compiler-module timing evidence",
);
assert(
  !speedErgonomics.blocking_gaps.some((gap) => gap.includes("Compiler/module iteration speed is still a major constraint")),
  "speed proof should remove the stale broad ergonomics blocker",
);
assert(
  !speedErgonomics.blocking_gaps.some((gap) => gap.includes("large real compiler-module edits")),
  "speed ergonomics should clear the larger compiler edit proof blocker",
);

const standalone = statusFor(missingAudit, "standalone_swarm_execution");
assert(standalone.status === "pass", `standalone status ${standalone.status}`);
assert(standalone.blocking_gaps.length === 0, "standalone backend gap should be closed by repo-scale proof");
assert(
  standalone.evidence.some((item) => item.includes("ordinary-Clasp closure source artifact")),
  "missing local agent closure artifact evidence",
);
assert(
  standalone.evidence.some((item) => item.includes("AgentBackend capability profiles record planner, builder, verifier")),
  "missing backend capability profile evidence",
);
assert(
  standalone.evidence.some((item) =>
    item.includes("GoalManagerAgentBackendConfig") &&
    item.includes("agentBackendLocalAgentTemplate") &&
    item.includes("agentBackendLocalPlannerTemplate") &&
    item.includes("explicit CLASP_LOOP_AGENT_COMMAND_JSON and CLASP_MANAGER_PLANNER_AGENT_COMMAND_JSON still override")
  ),
  "missing standalone backend default selection evidence",
);
assert(
  standalone.evidence.some((item) =>
    item.includes("Standalone-required GoalManager runs default loop and planner capability profiles to local-clasp")
  ),
  "missing standalone local-clasp capability default evidence",
);
assert(
  standalone.evidence.some((item) =>
    item.includes("GoalManager planner reuse fingerprints") &&
    item.includes("planner memory") &&
    item.includes("rendered mailbox detail lines") &&
    item.includes("workspace-local task catalogs")
  ),
  "missing standalone planner reuse fingerprint evidence",
);
assert(
  standalone.evidence.some((item) =>
    item.includes("local_verifier_gate") &&
    item.includes("AgentVerifierGate") &&
    item.includes("typed memory-policy and command-plan evidence")
  ),
  "missing local verifier typed gate evidence",
);
assert(
  standalone.evidence.some((item) =>
    item.includes("GoalManager mailbox summaries preserve capability evidence") &&
    item.includes("capability-evidence=") &&
    item.includes("capability-gap=") &&
    item.includes("capability-closure=")
  ),
  "missing mailbox capability-detail propagation evidence",
);
assert(
  standalone.evidence.some((item) =>
    item.includes("focused_verification_plan mailbox evidence") &&
    item.includes("focused-verification-plan-safe-direct:false") &&
    item.includes("focused-verification-launch-policy-mode:managed-required") &&
    item.includes("localRouteFocusedVerificationPlanRequiresManaged")
  ),
  "missing focused verification mailbox route evidence",
);
assert(
  standalone.evidence.some((item) =>
    item.includes("GoalManagerResourceHealth now derives managerAutonomousLaunchGate") &&
    item.includes("CLASP_MANAGER_WORKSPACE_CHECKPOINT_READY_JSON") &&
    item.includes("managerWorkspaceCheckpointReadyDefault") &&
    item.includes("ManagerWorktreeCheckpoint") &&
    item.includes("scripts/clasp-manager-worktree-checkpoint.sh") &&
    item.includes("Autonomous launch gate JSON") &&
    item.includes("GeneratedStateCleanupPlan evidence") &&
    item.includes("generated-state-cleanup-can-satisfy-guard") &&
    item.includes("generated-state-cleanup-apply-requires") &&
    item.includes("plannerPromptFor") &&
    item.includes("GoalManagerTaskExecutionHelpers enforces that same gate") &&
    item.includes("task launch blocked by autonomous launch gate") &&
    item.includes("capability-gap=autonomous_launch_gate") &&
    item.includes("autonomous-launch-gate-may-spawn-repair") &&
    item.includes("autonomous-launch-worktree-checkpoint-matches") &&
    item.includes("managerAutonomousLaunchGateRepairMaySpawnForActiveChildren") &&
    item.includes("plannerTaskSpecIsAutonomousLaunchGateRepair") &&
    item.includes("autonomous-launch-gate-blocker retry recovery records") &&
    item.includes("manager-replan-blocker=autonomous-launch-gate") &&
    item.includes("taskIdsHaveManagerReplanBlocker") &&
    item.includes("Prior swarm mailbox/recovery context") &&
    item.includes("mailboxSummaryText wave in plannerPromptFor") &&
    item.includes("resourceRecoveryMessageIsAutonomousLaunchGateBlocker") &&
    item.includes("retryRecordRecoveryTask=standalone-swarm-autonomous-launch-gate-repair") &&
    item.includes("retryRecordRecoveryKind=autonomous-launch-gate")
  ),
  "missing manager-derived autonomous launch gate evidence",
);
assert(
  standalone.evidence.some((item) =>
    item.includes("LocalRouting recognizes blocked Autonomous launch gate JSON") &&
    item.includes("autonomous-launch-ready=false") &&
    item.includes("localRouteHasAutonomousLaunchGateGap") &&
    item.includes("capability-gap=autonomous_launch_gate:") &&
    item.includes("retryRecordRecoveryTask=standalone-swarm-autonomous-launch-gate-repair") &&
    item.includes("retryRecordLatest=phase=autonomous-launch-gate") &&
    item.includes("LocalPlanner preserves autonomous launch gate JSON and retry-record evidence")
  ),
  "missing autonomous launch gate routing evidence",
);
assert(
  standalone.evidence.some((item) =>
    item.includes("targeted replacements through the root-confined workspaceReplaceText primitive") &&
    item.includes("workspaceReadFile/workspaceWriteFile/workspaceMkdirAll support APIs") &&
    item.includes("existing Clasp, script, doc, and runtime source files")
  ),
  "missing local agent root-confined multi-surface source patch evidence",
);
assert(
  standalone.evidence.some((item) => item.includes("explicit repo-scale multi-surface direct-source-edit requirement, source-edit plan, and source-patch plan")),
  "missing local planner source patch requirement evidence",
);
assert(
  standalone.evidence.some((item) => item.includes("consume prompt source-edit and source-patch plans")),
  "missing local agent source patch plan evidence",
);
assert(
  standalone.evidence.some((item) => item.includes("preflight every planned patch before writing")),
  "missing local agent atomic source patch preflight evidence",
);
assert(
  standalone.evidence.some((item) => item.includes("post-write source fingerprints")),
  "missing local agent post-write source fingerprints evidence",
);
assert(
  standalone.evidence.some((item) => item.includes("standaloneSwarmDirectSourceEditProofMetadataPresent")),
  "missing shared source-edit proof metadata helper evidence",
);
assert(
  standalone.evidence.some((item) => item.includes("localVerifierFindingsFor") && item.includes("standaloneSwarmDirectSourceEditIssueTexts") && item.includes("standaloneSwarmDirectSourceEditRepairHints") && item.includes("source-edit-specific repair findings")),
  "missing source-edit-specific verifier findings evidence",
);
assert(
  standalone.evidence.some((item) => item.includes("workspace fingerprint manifest") && item.includes("Clasp manifest fingerprint") && item.includes("manifest SHA-256")),
  "missing standalone closure manifest fingerprint evidence",
);
assert(
  standalone.evidence.some((item) => item.includes("repo-scale source patching across src, examples, scripts, docs, and runtime")),
  "missing repo-scale source patch evidence",
);
assert(
  standalone.evidence.some((item) => item.includes("StandaloneSwarmClosureReport.clasp") && item.includes("CLASP_LOOP_STANDALONE_SWARM_CLOSURE_CONTEXT_MAX_MB_JSON") && item.includes("standaloneSwarmClosureRepairKindForDecision") && item.includes("manifest-missing")),
  "missing bounded standalone closure-report handoff evidence",
);
assert(
  standalone.evidence.some((item) => item.includes("standaloneSwarmClosureDecisionFromJson") && item.includes("standaloneSwarmClosureDecisionFromPath")),
  "missing direct standalone closure-report decision helper evidence",
);
assert(
  standalone.evidence.some((item) => item.includes("localRouteHasStandaloneSwarmClosureHandoff") && item.includes("standaloneSwarmTaskForPrompt") && item.includes("standaloneSwarmTaskForClosureReportPath") && item.includes("swarm-manifest-repair-worker")),
  "missing planner routing evidence for standalone closure-report handoffs",
);
assert(
  standalone.evidence.some((item) => item.includes("standaloneSwarmSourceEditRepairKindForPrompt") && item.includes("standaloneSwarmSourceEditRepairTaskForPrompt") && item.includes("swarm-source-patch-repair-worker")),
  "missing planner routing evidence for standalone source-edit repair hints",
);
EOF

printf 'swarm-capability-audit-ok\n'
