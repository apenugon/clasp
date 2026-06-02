#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
timeout_secs="${CLASP_AGENT_ERGONOMICS_TIMEOUT_SECS:-180}"
mode="${1:-${CLASP_AGENT_ERGONOMICS_MODE:-full}}"
harness_path="$project_root/examples/swarm-native/AgentErgonomicsHarness.clasp"
module_path="$project_root/examples/swarm-native/AgentErgonomics.clasp"

usage() {
  cat <<'EOF'
usage: scripts/test-agent-ergonomics-helpers.sh [static|full]

static  Validate the ordinary-Clasp agent ergonomics contract without invoking claspc.
full    Run the ordinary Clasp ergonomics harness through claspc.
EOF
}

case "$mode" in
  --help|-h)
    usage
    exit 0
    ;;
  static|smoke)
    node - "$module_path" "$harness_path" <<'NODE'
const fs = require("node:fs");

const [modulePath, harnessPath] = process.argv.slice(2);
const source = fs.readFileSync(modulePath, "utf8");
const harness = fs.readFileSync(harnessPath, "utf8");

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

for (const marker of [
  "record AgentValidationSummary =",
  "record AgentCheckedProcessRun =",
  "record AgentCommandPlanResult =",
  "record AgentVerifierMemoryPolicy =",
  "record AgentVerifierGate =",
  "record AgentAffectedCommandResource =",
  "record AgentAffectedCommandResourceSummary =",
  "record AgentAffectedVerificationPlan =",
  "record AgentAffectedVerificationPlanDecision =",
  "record AgentAffectedVerificationLaunchPolicy =",
  "record AgentCapabilityAuditClosureDecision =",
  "record AgentCapabilityAuditClosureVerificationPlan =",
  "record AgentFocusedVerificationLaunchPolicy =",
  "record AgentAutonomousLaunchGateInput =",
  "record AgentAutonomousLaunchGate =",
  "record AgentCapabilityAuditClosureInput =",
  "record AgentCapabilityAuditJsonStatus =",
  "record AgentCapabilityAuditJsonReport =",
  "record AgentManagedSwarmProofReport =",
  "record AgentManagedSwarmProofDecision =",
  "record AgentCapabilityMailboxSummary =",
  "agentCapabilityAuditJsonStartMarker : Str",
  "agentCapabilityAuditJsonPathStartMarker : Str",
  "agentCapabilityAuditDecisionJsonStartMarker : Str",
  "agentCapabilityAuditDecisionJsonPathStartMarker : Str",
  "agentManagedSwarmProofJsonStartMarker : Str",
  "agentManagedSwarmProofJsonPathStartMarker : Str",
  "agentAutonomousLaunchGateJsonStartMarker : Str",
  "agentAutonomousLaunchGateJsonEndMarker : Str",
  "agentCapabilityAuditInlineJsonFromPrompt : Str -> Str",
  "agentCapabilityAuditJsonFromPrompt : Str -> Str",
  "agentCapabilityAuditJsonPathFromPrompt : Str -> Str",
  "agentCapabilityAuditJsonBlock : Str -> Str",
  "agentCapabilityAuditJsonBlockFromPath : Str -> Str",
  "agentCapabilityAuditDecisionInlineJsonFromPrompt : Str -> Str",
  "agentCapabilityAuditDecisionJsonFromPrompt : Str -> Str",
  "agentCapabilityAuditDecisionJsonPathFromPrompt : Str -> Str",
  "agentCapabilityAuditDecisionJsonBlock : Str -> Str",
  "agentCapabilityAuditDecisionJsonBlockFromPath : Str -> Str",
  "agentManagedSwarmProofJsonFromPrompt : Str -> Str",
  "agentManagedSwarmProofJsonPathFromPrompt : Str -> Str",
  "agentManagedSwarmProofJsonBlock : Str -> Str",
  "agentManagedSwarmProofJsonBlockFromPath : Str -> Str",
  "agentCapabilityMailboxSummaryFromPrompt : Str -> AgentCapabilityMailboxSummary",
  "agentPromptHasCapabilityMailboxGaps : Str -> Bool",
  "agentCapabilityMailboxClosureDetail : AgentCapabilityMailboxSummary -> Str",
  "agentCapabilityMailboxClosurePrompt : AgentCapabilityMailboxSummary -> Str",
  'agentCapabilityAuditClosureVerificationSectionForKind "capability-mailbox"',
  "compilerStateAccess : Str",
  "compilerStateFreeCommandCount : Int",
  "compilerStateTouchingCommandCount : Int",
  "canRunWithoutCompilerState : Bool",
  "safeDirectCommandCount : Int",
  "managedGuardCommandCount : Int",
  "agentJsonDecodeAndRequireFields : Str -> Str -> Result a -> [Str] -> AgentValidationSummary",
  "agentRunCommandPlanFailFast : Str -> [AgentCommandStep] -> AgentCommandPlanResult",
  "agentVerifierGate : AgentVerifierMemoryPolicySummary -> AgentCommandPlanResult -> AgentVerifierGate",
  "agentAffectedVerificationPlanDecisionFromJson : Str -> AgentAffectedVerificationPlanDecision",
  "agentAffectedVerificationLaunchPolicy : AgentAffectedVerificationPlanDecision -> AgentAffectedVerificationLaunchPolicy",
  "agentAffectedVerificationLaunchPolicyFromJson : Str -> AgentAffectedVerificationLaunchPolicy",
  "agentAffectedCommandResourceConsistencyIssues : AgentAffectedCommandResource -> [AgentValidationIssue]",
  "safe-direct command requires managed guard",
  "safe-direct command has high OOM risk",
  "high OOM risk command must require managed guard",
  "verificationPlanRecommendation : Str",
  "agentPlannerTaskIdProviderNeutral : Str",
  'agentPlannerTaskIdProviderNeutral = "provider-neutral-child"',
  "agentPlannerTaskIdIterationSpeed : Str",
  'agentPlannerTaskIdIterationSpeed = "iteration-speed-loop"',
  "agentPlannerTaskIdSemanticContext : Str",
  'agentPlannerTaskIdSemanticContext = "semantic-context-routing"',
  "agentPlannerTaskIdDiskResourcePressure : Str",
  'agentPlannerTaskIdDiskResourcePressure = "resource-pressure-recovery"',
  "agentPlannerTaskIdMemoryResourcePressure : Str",
  'agentPlannerTaskIdMemoryResourcePressure = "resource-memory-pressure-recovery"',
  "agentPlannerTaskIdAffectedVerifierLaunch : Str",
  'agentPlannerTaskIdAffectedVerifierLaunch = "affected-verifier-launch-preflight"',
  "agentPlannerTaskIdCapabilityAuditClosure : Str",
  'agentPlannerTaskIdCapabilityAuditClosure = "capability-audit-closure"',
  "agentPlannerTaskIdStandaloneSwarmReadiness : Str",
  'agentPlannerTaskIdStandaloneSwarmReadiness = "standalone-swarm-readiness"',
  "agentPromptHasCapabilityAuditSwarmProofGap : Str -> Bool",
  "Broad self-improving swarm",
  "CLASP_SWARM_CAPABILITY_SWARM_PROOF_JSON",
  "managed-swarm-proof",
  "agentPromptHasCapabilityAuditNativeRuntimeGap : Str -> Bool",
  "full native workflow/supervisor/runtime parity",
  "native-runtime-parity",
  "tool-verifier-mergegate",
  "agentPromptHasCapabilityAuditBackendSurfaceGap : Str -> Bool",
  "full backend surface parity without JS helpers",
  "backend-surface-parity",
  "js-helper-free",
  "agentPromptHasCapabilityAuditContextGap : Str -> Bool",
  "agentCapabilityAuditClosureKindFromPrompt : Str -> Str",
  "agentCapabilityAuditClosureRoleForKind : Str -> Str",
  "agentCapabilityAuditClosureRoleFromPrompt : Str -> Str",
  "agentCapabilityAuditClosureVerificationPlanForKind : Str -> AgentCapabilityAuditClosureVerificationPlan",
  "agentCapabilityAuditClosureVerificationSectionForKind : Str -> Str",
  "agentCapabilityAuditClosureVerificationSectionFromPrompt : Str -> Str",
  "agentCapabilityAuditClosureVerificationPromptSection : Str -> Str",
  "agentCapabilityAuditClosureVerificationPromptValue : Str -> Str -> Str",
  "agentCapabilityAuditClosureVerificationPlanFromPrompt : Str -> AgentCapabilityAuditClosureVerificationPlan",
  "agentCapabilityAuditClosureVerificationPlanSafeDirect : AgentCapabilityAuditClosureVerificationPlan -> Bool",
  "agentCapabilityAuditClosureVerificationPlanIssuesFromPrompt : Str -> AgentCapabilityAuditClosureVerificationPlan -> [AgentValidationIssue]",
  "agentCapabilityAuditClosureVerificationPlanValidationFromPrompt : Str -> AgentValidationSummary",
  "agentPromptHasCapabilityAuditClosureVerificationPlan : Str -> Bool",
  "agentFocusedVerificationLaunchPolicy : AgentValidationSummary -> AgentCapabilityAuditClosureVerificationPlan -> AgentFocusedVerificationLaunchPolicy",
  "agentFocusedVerificationLaunchPolicyFromPrompt : Str -> AgentFocusedVerificationLaunchPolicy",
  "agentFocusedVerificationLaunchPolicyInlineJsonFromPrompt : Str -> Str",
  "agentFocusedVerificationLaunchPolicyJsonFromPrompt : Str -> Str",
  "agentHasFocusedVerificationLaunchPolicyJson : Str -> Bool",
  "agentFocusedVerificationLaunchPolicyFromJson : Str -> AgentFocusedVerificationLaunchPolicy",
  "agentAutonomousLaunchGateInlineJsonFromPrompt : Str -> Str",
  "agentAutonomousLaunchGateJsonFromPrompt : Str -> Str",
  "agentHasAutonomousLaunchGateJson : Str -> Bool",
  "agentAutonomousLaunchGateJsonBlock : Str -> Str",
  "agentAutonomousLaunchGateInputStaticTiny : AgentAutonomousLaunchGateInput",
  "agentAutonomousLaunchGateInputCurrentDirty : AgentAutonomousLaunchGateInput",
  "agentAutonomousLaunchGateRepairMaySpawn : AgentAutonomousLaunchGateInput -> Bool",
  "agentAutonomousLaunchGateRepairRecommendation : AgentAutonomousLaunchGateInput -> Str",
  "agentAutonomousLaunchGate : AgentAutonomousLaunchGateInput -> AgentAutonomousLaunchGate",
  "agentAutonomousLaunchGateValidation : AgentAutonomousLaunchGateInput -> AgentValidationSummary",
  "agentAutonomousLaunchGateFromJson : Str -> AgentAutonomousLaunchGate",
  "agentAutonomousLaunchGateDecodeSummary : Str -> AgentValidationSummary",
  "Autonomous launch gate JSON:",
  "autonomous-launch-ready=",
  "autonomous-launch-mode=",
  "blocked-dirty-worktree",
  "autonomous-launch:checkpoint-current-worktree",
  "autonomous-launch:ready-managed-bounded-loop",
  "autonomous-launch:attach-focused-verification-launch-policy",
  "autonomous-launch-repair:ready-managed-gate-repair-loop",
  "autonomous-launch-repair:checkpoint-current-worktree-before-child-repair",
  "Focused verification launch policy JSON:",
  "focused-verification-launch:managed-required",
  "verify-all must be managed",
  "focused-verification-safe-direct=",
  "agentCapabilityAuditClosurePromptBodyForKind : Str -> Str",
  "Focused verification plan:",
  "managedRequired=",
  "bash scripts/test-agent-ergonomics-helpers.sh static",
  "bash scripts/test-agent-backend-static.sh",
  "scripts/run-managed-job.sh",
  "semantic-memory-worker",
  "backend-surface-worker",
  "agentCapabilityAuditClosureDecisionFromPrompt : Str -> AgentCapabilityAuditClosureDecision",
  "agentCapabilityAuditClosureDecisionFromEntries : [Str] -> [Str] -> AgentCapabilityAuditClosureDecision",
  "agentCapabilityAuditClosureDecisionFromJson : Str -> AgentCapabilityAuditClosureDecision",
  "agentCapabilityAuditClosureDecisionFromDecisionJson : Str -> AgentCapabilityAuditClosureDecision",
  "agentCapabilityAuditClosureDecisionFromPromptOrJson : Str -> AgentCapabilityAuditClosureDecision",
  "agentManagedSwarmProofDecisionFromJson : Str -> AgentManagedSwarmProofDecision",
  "agentManagedSwarmProofDecisionFromPromptOrJson : Str -> AgentManagedSwarmProofDecision",
  "agentBoundedCapabilityAuditJsonFromPath : Str -> Str",
  "agentBoundedCapabilityAuditDecisionJsonFromPath : Str -> Str",
  "agentBoundedManagedSwarmProofJsonFromPath : Str -> Str",
  "CLASP_LOOP_CAPABILITY_AUDIT_CONTEXT_MAX_MB_JSON",
  "CLASP_LOOP_MANAGED_SWARM_PROOF_CONTEXT_MAX_MB_JSON",
  "tryDecode AgentCapabilityAuditJsonReport raw",
  "tryDecode AgentCapabilityAuditClosureDecision raw",
  "tryDecode AgentManagedSwarmProofReport raw",
  "capability-audit-json-decode-failed",
  "capability-audit-decision-json-decode-failed",
  "managed-swarm-proof-json-decode-failed",
  "capability-audit-context:oversize",
  "managed-swarm-proof-context:oversize",
  "agentPromptHasCapabilityAuditSafetyGap : Str -> Bool",
  "hostile-tool packaging",
  "safety_governance",
  "filesystem-network-mediation",
  "affected-verification-plan:safe-direct-compiler-state-free",
  "affected-verification-plan:safe-direct-compiler-state-access",
  "affected-verification-plan:run-managed-memory-disk-admission",
  "affected-verification-launch:direct-compiler-state-free",
  "affected-verification-launch:direct-compiler-state-access-preflight",
  "affected-verification-launch:managed-heavy-memory-disk",
]) {
  assert(source.includes(marker), `missing source marker: ${marker}`);
}

for (const marker of [
  "affectedStaticPlanJson : Str",
  "affectedHeavyPlanJson : Str",
  "affectedInvalidPlanJson : Str",
  "affectedInconsistentPlanJson : Str",
  "agentAffectedVerificationPlanDecisionFromJson affectedHeavyPlanJson",
  "agentAffectedVerificationPlanDecisionFromJson affectedInconsistentPlanJson",
  "affectedStaticPlanStatus",
  "affectedStaticPlanSafeDirectCommandCount",
  "affectedStaticPlanCanRunWithoutCompilerState",
  "affectedStaticPlanCompilerStateFreeCommandCount",
  "affectedStaticLaunchMode",
  "affectedStaticLaunchReady",
  "affectedCacheProbePlanStatus",
  "affectedCacheProbePlanRecommendation",
  "affectedCacheProbeLaunchMode",
  "affectedCacheProbeLaunchBlockingGap",
  "affectedDirectLaunchPolicyJson : Str",
  "affectedDirectLaunchPolicyPlanRecommendation",
  "affectedHeavyPlanRequiresManaged",
  "affectedHeavyPlanCanRunWithoutCompilerState",
  "affectedHeavyPlanFocusedCommandCount",
  "affectedHeavyPlanManagedGuardCommandCount",
  "affectedHeavyPlanCompilerStateTouchingCommandCount",
  "affectedHeavyLaunchMode",
  "affectedHeavyLaunchBlockingGap",
  "affectedInvalidPlanIssueText",
  "affectedInconsistentPlanIssueText",
  "autonomousStaticLaunchMode",
  "autonomousStaticLaunchReady",
  "autonomousStaticLaunchRecommendation",
  "autonomousStaticRepairMaySpawn",
  "autonomousDirtyLaunchMode",
  "autonomousDirtyLaunchReady",
  "autonomousDirtyRepairMaySpawn",
  "autonomousDirtyLaunchBlockingGap",
  "autonomousDirtyLaunchRequiredClosure",
  "autonomousDirtyLaunchRecommendation",
  "autonomousCompilerRepairMaySpawn",
  "autonomousCompilerRepairRecommendation",
  "autonomousGateJsonMode",
  "autonomousGateJsonReady",
  "agentAutonomousLaunchGate agentAutonomousLaunchGateInputStaticTiny",
  "agentAutonomousLaunchGate agentAutonomousLaunchGateInputCurrentDirty",
  "agentAutonomousLaunchGateRepairMaySpawn autonomousCompilerRepairInput",
  "agentAutonomousLaunchGateRepairRecommendation autonomousCompilerRepairInput",
  "agentAutonomousLaunchGateJsonBlock (encode autonomousStaticLaunchGate)",
  "agentAutonomousLaunchGateFromJson",
]) {
  assert(harness.includes(marker), `missing harness marker: ${marker}`);
}

process.stdout.write("agent-ergonomics-helpers-static-ok\n");
NODE
    exit 0
    ;;
  full)
    ;;
  *)
    printf 'test-agent-ergonomics-helpers: unknown mode: %s\n' "$mode" >&2
    usage >&2
    exit 2
    ;;
esac

export CLASP_NATIVE_JOBS_MAX="${CLASP_NATIVE_JOBS_MAX:-1}"
export CLASP_NATIVE_BUNDLE_JOBS="${CLASP_NATIVE_BUNDLE_JOBS:-1}"
export CLASP_NATIVE_IMAGE_SECTION_JOBS="${CLASP_NATIVE_IMAGE_SECTION_JOBS:-1}"
export CLASP_NATIVE_IMAGE_SECTION_JOBS_MAX="${CLASP_NATIVE_IMAGE_SECTION_JOBS_MAX:-1}"
export CLASP_NATIVE_IMAGE_MODULE_DECL_FRESH_PROCESS="${CLASP_NATIVE_IMAGE_MODULE_DECL_FRESH_PROCESS:-1}"
export CLASP_NATIVE_IMAGE_MODULE_DECL_CHUNK_SIZE="${CLASP_NATIVE_IMAGE_MODULE_DECL_CHUNK_SIZE:-8}"
export CLASP_NATIVE_EXPORT_HOST_IDLE_TIMEOUT_SECS="${CLASP_NATIVE_EXPORT_HOST_IDLE_TIMEOUT_SECS:-5}"

if ! [[ "$timeout_secs" =~ ^[0-9]+$ ]] || (( timeout_secs < 1 )); then
  printf 'CLASP_AGENT_ERGONOMICS_TIMEOUT_SECS must be a positive integer\n' >&2
  exit 1
fi

mkdir -p "$tmp_root"
test_root="$(mktemp -d "$tmp_root/test-agent-ergonomics.XXXXXX")"
workspace_root="$test_root/workspace"
output_path="$test_root/output.json"

cleanup() {
  if [[ "${CLASP_TEST_KEEP_TMP:-}" == "1" ]]; then
    printf 'kept test root: %s\n' "$test_root" >&2
  else
    rm -rf "$test_root" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

mkdir -p "$workspace_root"

claspc_bin="$(
  CLASP_CLASPC= CLASPC_BIN= CLASP_PROJECT_ROOT="$project_root" \
    "$project_root/scripts/resolve-claspc.sh"
)"

env RUSTC=/definitely-missing-rustc \
  timeout "$timeout_secs" "$claspc_bin" --json check "$harness_path" | grep -F '"status":"ok"' >/dev/null

env RUSTC=/definitely-missing-rustc \
  timeout "$timeout_secs" "$claspc_bin" run "$harness_path" -- "$workspace_root" >"$output_path"

node - "$module_path" "$harness_path" "$output_path" "$workspace_root" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");

const [modulePath, harnessPath, outputPath, workspaceRoot] = process.argv.slice(2);
const source = fs.readFileSync(modulePath, "utf8");
const harness = fs.readFileSync(harnessPath, "utf8");
const report = JSON.parse(fs.readFileSync(outputPath, "utf8"));

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

assert(source.includes("agentResultIsOk : Result a -> Bool"), "missing polymorphic Result ok helper");
assert(source.includes("agentResultWithDefault : a -> Result a -> a"), "missing polymorphic default helper");
assert(source.includes("agentResultToList : Result a -> [a]"), "missing polymorphic Result-to-list helper");
assert(source.includes("record AgentValidationIssue ="), "missing typed validation issue record");
assert(source.includes("record AgentValidationSummary ="), "missing typed validation summary record");
assert(source.includes("record AgentCheckedProcessRun ="), "missing typed checked process run record");
assert(source.includes("record AgentCommandStep ="), "missing typed command step record");
assert(source.includes("record AgentCommandStepResult ="), "missing typed command step result record");
assert(source.includes("record AgentCommandPlanResult ="), "missing typed command plan result record");
assert(source.includes("record AgentVerifierMemoryPolicy ="), "missing typed verifier memory policy record");
assert(source.includes("record AgentVerifierMemoryPolicySummary ="), "missing typed verifier memory policy summary record");
assert(source.includes("record AgentVerifierGate ="), "missing typed verifier gate record");
assert(source.includes("record AgentAffectedCommandResource ="), "missing affected verifier command resource record");
assert(source.includes("record AgentAffectedCommandResourceSummary ="), "missing affected verifier resource summary record");
assert(source.includes("record AgentAffectedVerificationPlan ="), "missing affected verifier plan record");
assert(source.includes("record AgentAffectedVerificationPlanDecision ="), "missing affected verifier plan decision record");
assert(source.includes("record AgentAffectedVerificationLaunchPolicy ="), "missing affected verifier launch policy record");
assert(source.includes("record AgentCapabilityAuditClosureDecision ="), "missing capability audit closure decision record");
assert(source.includes("record AgentFocusedVerificationLaunchPolicy ="), "missing focused verification launch policy record");
assert(source.includes("record AgentCapabilityAuditClosureInput ="), "missing capability audit closure input record");
assert(source.includes("record AgentCapabilityAuditJsonStatus ="), "missing capability audit json status record");
assert(source.includes("record AgentCapabilityAuditJsonReport ="), "missing capability audit json report record");
assert(source.includes("record AgentManagedSwarmProofReport ="), "missing managed swarm proof report record");
assert(source.includes("record AgentManagedSwarmProofDecision ="), "missing managed swarm proof decision record");
assert(source.includes("record AgentCapabilityMailboxSummary ="), "missing capability mailbox summary record");
assert(source.includes("agentCapabilityAuditJsonStartMarker : Str"), "missing capability audit json start marker");
assert(source.includes("agentCapabilityAuditJsonPathStartMarker : Str"), "missing capability audit json path marker");
assert(source.includes("agentCapabilityAuditDecisionJsonStartMarker : Str"), "missing capability audit decision json start marker");
assert(source.includes("agentCapabilityAuditDecisionJsonPathStartMarker : Str"), "missing capability audit decision json path marker");
assert(source.includes("agentManagedSwarmProofJsonStartMarker : Str"), "missing managed swarm proof json start marker");
assert(source.includes("agentManagedSwarmProofJsonPathStartMarker : Str"), "missing managed swarm proof json path marker");
assert(source.includes("agentCapabilityAuditInlineJsonFromPrompt : Str -> Str"), "missing capability audit inline json helper");
assert(source.includes("agentCapabilityAuditJsonFromPrompt : Str -> Str"), "missing capability audit prompt json helper");
assert(source.includes("agentCapabilityAuditJsonPathFromPrompt : Str -> Str"), "missing capability audit prompt path helper");
assert(source.includes("agentHasCapabilityAuditJsonPath : Str -> Bool"), "missing capability audit prompt path presence helper");
assert(source.includes("agentHasCapabilityAuditJson : Str -> Bool"), "missing capability audit prompt json presence helper");
assert(source.includes("agentCapabilityAuditJsonBlock : Str -> Str"), "missing capability audit prompt json render helper");
assert(source.includes("agentCapabilityAuditJsonBlockFromPath : Str -> Str"), "missing capability audit prompt path json render helper");
assert(source.includes("agentCapabilityAuditDecisionInlineJsonFromPrompt : Str -> Str"), "missing capability audit decision inline json helper");
assert(source.includes("agentCapabilityAuditDecisionJsonFromPrompt : Str -> Str"), "missing capability audit decision prompt json helper");
assert(source.includes("agentCapabilityAuditDecisionJsonPathFromPrompt : Str -> Str"), "missing capability audit decision prompt path helper");
assert(source.includes("agentHasCapabilityAuditDecisionJsonPath : Str -> Bool"), "missing capability audit decision path presence helper");
assert(source.includes("agentHasCapabilityAuditDecisionJson : Str -> Bool"), "missing capability audit decision json presence helper");
assert(source.includes("agentCapabilityAuditDecisionJsonBlock : Str -> Str"), "missing capability audit decision prompt json render helper");
assert(source.includes("agentCapabilityAuditDecisionJsonBlockFromPath : Str -> Str"), "missing capability audit decision prompt path json render helper");
assert(source.includes("agentManagedSwarmProofJsonFromPrompt : Str -> Str"), "missing managed swarm proof prompt json helper");
assert(source.includes("agentManagedSwarmProofJsonPathFromPrompt : Str -> Str"), "missing managed swarm proof prompt path helper");
assert(source.includes("agentHasManagedSwarmProofJson : Str -> Bool"), "missing managed swarm proof presence helper");
assert(source.includes('textIncludes prompt "clasp-managed-swarm-proof"'), "managed swarm proof presence helper should accept raw proof JSON text");
assert(source.includes("agentManagedSwarmProofJsonBlock : Str -> Str"), "missing managed swarm proof prompt json render helper");
assert(source.includes("agentManagedSwarmProofJsonBlockFromPath : Str -> Str"), "missing managed swarm proof prompt path render helper");
assert(source.includes("agentPromptPrefixedLines : Str -> Str -> [Str]"), "missing prompt prefixed-line parser helper");
assert(source.includes('textConcat ["- ", prefix]'), "prefixed-line parser should accept bullet-prefixed mailbox details");
assert(source.includes('textConcat ["  - ", prefix]'), "prefixed-line parser should accept indented bullet mailbox details");
assert(source.includes("agentCapabilityMailboxEvidenceFromPrompt : Str -> [Str]"), "missing capability mailbox evidence parser");
assert(source.includes("agentCapabilityMailboxBlockingGapsFromPrompt : Str -> [Str]"), "missing capability mailbox gap parser");
assert(source.includes("agentCapabilityMailboxRequiredClosureFromPrompt : Str -> [Str]"), "missing capability mailbox closure parser");
assert(source.includes("agentCapabilityMailboxSummaryFromPrompt : Str -> AgentCapabilityMailboxSummary"), "missing capability mailbox summary helper");
assert(source.includes("agentPromptHasCapabilityMailboxGaps : Str -> Bool"), "missing capability mailbox gap detector");
assert(source.includes("agentCapabilityMailboxClosureDetail : AgentCapabilityMailboxSummary -> Str"), "missing concrete capability mailbox task detail helper");
assert(source.includes("agentCapabilityMailboxClosurePrompt : AgentCapabilityMailboxSummary -> Str"), "missing concrete capability mailbox task prompt helper");
assert(source.includes('agentCapabilityAuditClosureVerificationSectionForKind "capability-mailbox"'), "capability mailbox prompt should include focused verification plan");
assert(source.includes('agentPromptPrefixedLines prompt "capability-evidence="'), "capability mailbox summary should parse evidence detail lines");
assert(source.includes('agentPromptPrefixedLines prompt "capability-gap="'), "capability mailbox summary should parse gap detail lines");
assert(source.includes('agentPromptPrefixedLines prompt "capability-closure="'), "capability mailbox summary should parse closure detail lines");
assert(source.includes('"capability-mailbox"'), "missing capability mailbox closure kind");
assert(source.includes("detail = agentCapabilityMailboxClosureDetail mailboxSummary"), "capability mailbox decisions should preserve concrete mailbox gap detail");
assert(source.includes("taskPrompt = agentCapabilityMailboxClosurePrompt mailboxSummary"), "capability mailbox decisions should preserve concrete mailbox prompt context");
assert(source.includes("Capability mailbox blocking gaps:"), "capability mailbox prompt should include concrete blocking gaps");
assert(source.includes("Capability mailbox required closure:"), "capability mailbox prompt should include concrete required closure");
assert(source.includes("record AgentWorkspacePatch ="), "missing typed workspace patch record");
assert(source.includes("record AgentWorkspacePatchResult ="), "missing typed workspace patch result record");
assert(source.includes("agentFirstTextOrEmpty : [Str] -> Str"), "missing first text helper");
assert(source.includes("agentSecondTextOrEmpty : [Str] -> Str"), "missing second text helper");
assert(source.includes("agentPromptBlockText : Str -> Str -> Str -> Str"), "missing prompt block text helper");
assert(source.includes("agentPromptBlockPresent : Str -> Str -> Str -> Bool"), "missing prompt block present helper");
assert(source.includes("agentPromptBlockOrEmpty : Str -> Str -> Str -> Str"), "missing prompt block rendering helper");
assert(source.includes("agentAffectedVerificationPlanInlineJsonFromPrompt : Str -> Str"), "missing affected verifier plan inline prompt helper");
assert(source.includes("agentAffectedVerificationPlanPathFromPrompt : Str -> Str"), "missing affected verifier plan path prompt helper");
assert(source.includes("agentAffectedVerificationPlanJsonFromPrompt : Str -> Str"), "missing affected verifier plan prompt resolver");
assert(source.includes("agentAffectedVerificationLaunchPolicyInlineJsonFromPrompt : Str -> Str"), "missing affected verifier launch policy inline prompt helper");
assert(source.includes("agentAffectedVerificationLaunchPolicyPathFromPrompt : Str -> Str"), "missing affected verifier launch policy path prompt helper");
assert(source.includes("agentAffectedVerificationLaunchPolicyJsonFromPrompt : Str -> Str"), "missing affected verifier launch policy prompt resolver");
assert(source.includes("agentAffectedVerificationPlanJsonBlockFromPath : Str -> Str"), "missing affected verifier plan path render helper");
assert(source.includes("agentAffectedVerificationLaunchPolicyJsonBlockFromPath : Str -> Str"), "missing affected verifier launch policy path render helper");
assert(source.includes("agentPromptWithAffectedVerificationPathContext : Str -> Str"), "missing affected verifier path-context prompt helper");
assert(source.includes("agentPromptHasBackendPolicyRepairShape : Str -> Bool"), "missing backend policy repair shape helper");
assert(source.includes("agentPromptHasBackendConfigRepairSignal : Str -> Bool"), "missing backend config repair signal helper");
assert(source.includes("agentPromptHasAgentBackendPolicyRepair : Str -> Bool"), "missing agent backend policy repair prompt helper");
assert(source.includes("agentPromptHasPlannerBackendPolicyRepair : Str -> Bool"), "missing planner backend policy repair prompt helper");
assert(source.includes("agentPromptHasNonEmptySection : Str -> Str -> Bool"), "missing non-empty prompt section helper");
assert(source.includes("agentPromptHasRoleContextPack : Str -> Str -> Str -> Bool"), "missing role context-pack prompt helper");
assert(source.includes("agentPromptHasBuilderContextPack : Str -> Bool"), "missing builder context-pack prompt helper");
assert(source.includes("agentPromptHasVerifierContextPack : Str -> Bool"), "missing verifier context-pack prompt helper");
assert(source.includes("agentPromptHasPlannerContextPack : Str -> Bool"), "missing planner context-pack prompt helper");
assert(source.includes("agentPromptHasTaskFileContent : Str -> Bool"), "missing task-file prompt helper");
assert(source.includes("agentPromptHasDependencyCompletionEvidence : Str -> Bool"), "missing dependency completion prompt helper");
assert(source.includes("agentPromptHasCapabilityAuditVerifyAllGap : Str -> Bool"), "missing capability audit verify-all gap helper");
assert(source.includes("agentPromptHasCapabilityAuditSwarmProofGap : Str -> Bool"), "missing capability audit swarm proof gap helper");
assert(source.includes("agentPromptHasCapabilityAuditNativeRuntimeGap : Str -> Bool"), "missing capability audit native runtime gap helper");
assert(source.includes("agentPromptHasCapabilityAuditBackendSurfaceGap : Str -> Bool"), "missing capability audit backend surface gap helper");
assert(source.includes("agentPromptHasCapabilityAuditCompilerSpeedGap : Str -> Bool"), "missing capability audit compiler speed gap helper");
assert(source.includes("agentPromptHasCapabilityAuditEmbeddingGap : Str -> Bool"), "missing capability audit embedding gap helper");
assert(source.includes("agentPromptHasCapabilityAuditSafetyGap : Str -> Bool"), "missing capability audit safety gap helper");
assert(source.includes("agentPromptHasCapabilityAuditErgonomicsGap : Str -> Bool"), "missing capability audit ergonomics gap helper");
assert(source.includes("agentPromptHasCapabilityAuditContextGap : Str -> Bool"), "missing capability audit context gap helper");
assert(source.includes("agentCapabilityAuditClosureKindFromPrompt : Str -> Str"), "missing capability audit closure kind helper");
assert(source.includes("agentCapabilityAuditClosureRoleForKind : Str -> Str"), "missing capability audit closure role helper");
assert(source.includes("agentCapabilityAuditClosureRoleFromPrompt : Str -> Str"), "missing prompt capability audit closure role helper");
assert(source.includes("agentCapabilityAuditClosureVerificationPlanForKind : Str -> AgentCapabilityAuditClosureVerificationPlan"), "missing capability audit closure verification plan helper");
assert(source.includes("agentCapabilityAuditClosureVerificationSectionForKind : Str -> Str"), "missing capability audit closure verification section helper");
assert(source.includes("agentCapabilityAuditClosureVerificationPlanFromPrompt : Str -> AgentCapabilityAuditClosureVerificationPlan"), "missing prompt parser for capability audit closure verification plan");
assert(source.includes("agentCapabilityAuditClosureVerificationPlanValidationFromPrompt : Str -> AgentValidationSummary"), "missing validation for prompt capability audit closure verification plan");
assert(source.includes("agentPromptHasCapabilityAuditClosureVerificationPlan : Str -> Bool"), "missing prompt capability audit closure verification plan detector");
assert(source.includes("agentFocusedVerificationLaunchPolicy : AgentValidationSummary -> AgentCapabilityAuditClosureVerificationPlan -> AgentFocusedVerificationLaunchPolicy"), "missing focused verification launch policy helper");
assert(source.includes("agentFocusedVerificationLaunchPolicyFromPrompt : Str -> AgentFocusedVerificationLaunchPolicy"), "missing prompt focused verification launch policy helper");
assert(source.includes("agentFocusedVerificationLaunchPolicyInlineJsonFromPrompt : Str -> Str"), "missing focused verification launch policy inline JSON helper");
assert(source.includes("agentFocusedVerificationLaunchPolicyJsonFromPrompt : Str -> Str"), "missing focused verification launch policy prompt JSON resolver");
assert(source.includes("agentHasFocusedVerificationLaunchPolicyJson : Str -> Bool"), "missing focused verification launch policy JSON detector");
assert(source.includes("agentFocusedVerificationLaunchPolicyFromJson : Str -> AgentFocusedVerificationLaunchPolicy"), "missing focused verification launch policy JSON decode helper");
assert(source.includes("Focused verification launch policy JSON:"), "missing focused verification launch policy prompt block");
assert(source.includes("focused-verification-launch:managed-required"), "missing focused verification managed launch recommendation");
assert(source.includes("verify-all must be managed"), "focused verification plan parser should fail closed for verify-all");
assert(source.includes("focused-verification-safe-direct="), "focused verification plan validation should expose safe-direct evidence");
assert(source.includes("Focused verification plan:"), "missing capability audit closure focused verification prompt section");
assert(source.includes("managedRequired="), "missing capability audit closure managed-required prompt field");
assert(source.includes('kind == "semantic-memory"'), "capability audit closure roles should classify semantic-memory");
assert(source.includes('"semantic-memory-worker"'), "capability audit closure roles should expose semantic-memory worker");
assert(source.includes('"backend-surface-worker"'), "capability audit closure roles should expose backend-surface worker");
assert(source.includes("agentCapabilityAuditClosureDecisionFromPrompt : Str -> AgentCapabilityAuditClosureDecision"), "missing capability audit closure decision helper");
assert(source.includes("agentCapabilityAuditClosureDecisionFromEntries : [Str] -> [Str] -> AgentCapabilityAuditClosureDecision"), "missing capability audit closure entries decision helper");
assert(source.includes("agentCapabilityAuditClosureInputFromReport : AgentCapabilityAuditJsonReport -> AgentCapabilityAuditClosureInput"), "missing capability audit report input helper");
assert(source.includes("agentCapabilityAuditClosureDecisionFromReport : AgentCapabilityAuditJsonReport -> AgentCapabilityAuditClosureDecision"), "missing capability audit report decision helper");
assert(source.includes("agentCapabilityAuditJsonDecodeSummary : Str -> AgentValidationSummary"), "missing capability audit json decode summary");
assert(source.includes("agentCapabilityAuditClosureDecisionFromJson : Str -> AgentCapabilityAuditClosureDecision"), "missing capability audit json decision helper");
assert(source.includes("agentCapabilityAuditInvalidDecisionForReason : Str -> AgentCapabilityAuditClosureDecision"), "missing capability audit invalid decision helper");
assert(source.includes("agentCapabilityAuditInvalidDecisionJsonForReason : Str -> Str"), "missing capability audit invalid decision json helper");
assert(source.includes("agentCapabilityAuditClosureDecisionValid : AgentCapabilityAuditClosureDecision -> Bool"), "missing capability audit decision shape helper");
assert(source.includes("agentCapabilityAuditClosureDecisionFromDecisionJson : Str -> AgentCapabilityAuditClosureDecision"), "missing capability audit direct decision json helper");
assert(source.includes("agentCapabilityAuditClosureDecisionFromPromptOrJson : Str -> AgentCapabilityAuditClosureDecision"), "missing capability audit prompt-or-json decision helper");
assert(source.includes("agentManagedSwarmProofReportPassed : AgentManagedSwarmProofReport -> Bool"), "missing managed swarm proof pass helper");
assert(source.includes("agentManagedSwarmProofDecisionFromReport : AgentManagedSwarmProofReport -> AgentManagedSwarmProofDecision"), "missing managed swarm proof report decision helper");
assert(source.includes("agentManagedSwarmProofDecisionFromJson : Str -> AgentManagedSwarmProofDecision"), "missing managed swarm proof json decision helper");
assert(source.includes("agentManagedSwarmProofDecisionFromPromptOrJson : Str -> AgentManagedSwarmProofDecision"), "missing managed swarm proof prompt decision helper");
assert(source.includes("agentCapabilityAuditInvalidReportForReason : Str -> AgentCapabilityAuditJsonReport"), "missing capability audit invalid report helper");
assert(source.includes("agentCapabilityAuditInvalidJsonForReason : Str -> Str"), "missing capability audit invalid json helper");
assert(source.includes("agentManagedSwarmProofInvalidJsonForReason : Str -> Str"), "missing managed swarm proof invalid json helper");
assert(source.includes("agentCapabilityAuditContextMaxMb : Int"), "missing capability audit context size cap helper");
assert(source.includes("agentManagedSwarmProofContextMaxMb : Int"), "missing managed swarm proof context size cap helper");
assert(source.includes("agentBoundedCapabilityAuditJsonFromPathWithLimit : Int -> Str -> Str"), "missing bounded capability audit path reader");
assert(source.includes("agentBoundedCapabilityAuditJsonFromPath : Str -> Str"), "missing default bounded capability audit path reader");
assert(source.includes("agentBoundedCapabilityAuditDecisionJsonFromPathWithLimit : Int -> Str -> Str"), "missing bounded capability audit decision path reader");
assert(source.includes("agentBoundedCapabilityAuditDecisionJsonFromPath : Str -> Str"), "missing default bounded capability audit decision path reader");
assert(source.includes("agentBoundedManagedSwarmProofJsonFromPathWithLimit : Int -> Str -> Str"), "missing bounded managed swarm proof path reader");
assert(source.includes("agentBoundedManagedSwarmProofJsonFromPath : Str -> Str"), "missing default bounded managed swarm proof path reader");
assert(source.includes("CLASP_LOOP_CAPABILITY_AUDIT_CONTEXT_MAX_MB_JSON"), "missing capability audit context cap env var");
assert(source.includes("CLASP_LOOP_MANAGED_SWARM_PROOF_CONTEXT_MAX_MB_JSON"), "missing managed swarm proof context cap env var");
assert(source.includes("capability-audit-context:oversize"), "missing capability audit oversize marker");
assert(source.includes("managed-swarm-proof-context:oversize"), "missing managed swarm proof oversize marker");
assert(source.includes("tryDecode AgentCapabilityAuditJsonReport raw"), "missing capability audit json tryDecode path");
assert(source.includes("tryDecode AgentCapabilityAuditClosureDecision raw"), "missing capability audit decision json tryDecode path");
assert(source.includes("tryDecode AgentManagedSwarmProofReport raw"), "missing managed swarm proof json tryDecode path");
assert(source.includes("capability-audit-json-decode-failed"), "missing capability audit json decode fallback evidence");
assert(source.includes("capability-audit-decision-json-decode-failed"), "missing capability audit decision json decode fallback evidence");
assert(source.includes("managed-swarm-proof-json-decode-failed"), "missing managed swarm proof json decode fallback evidence");
assert(source.includes("agentCapabilityAuditClosureDetailFromPrompt : Str -> Str"), "missing capability audit closure detail helper");
assert(source.includes("agentCapabilityAuditClosurePromptFromPrompt : Str -> Str"), "missing capability audit closure prompt helper");
assert(source.includes("agentCapabilityAuditCoordinationFocusFromPrompt : Str -> [Str]"), "missing capability audit coordination focus helper");
assert(source.includes("agentPlannerTaskBudgetContractLine : Int -> Str"), "missing planner task budget contract line helper");
assert(source.includes("agentPromptHasExactTaskBudget : Str -> Int -> Bool"), "missing exact planner task budget helper");
assert(source.includes("agentPromptHasTaskBudgetContract : Str -> Bool"), "missing planner task budget contract helper");
assert(source.includes("agentPromptTaskBudgetOrDefault : Str -> Int -> Int"), "missing planner task budget default helper");
assert(source.includes("agentPlannerTaskIdProviderNeutral : Str"), "missing provider-neutral planner task id constant");
assert(source.includes('agentPlannerTaskIdProviderNeutral = "provider-neutral-child"'), "missing provider-neutral planner task id value");
assert(source.includes("agentPlannerTaskIdIterationSpeed : Str"), "missing iteration-speed planner task id constant");
assert(source.includes('agentPlannerTaskIdIterationSpeed = "iteration-speed-loop"'), "missing iteration-speed planner task id value");
assert(source.includes("agentPlannerTaskIdSemanticContext : Str"), "missing semantic-context planner task id constant");
assert(source.includes('agentPlannerTaskIdSemanticContext = "semantic-context-routing"'), "missing semantic-context planner task id value");
assert(source.includes("agentPlannerTaskIdDiskResourcePressure : Str"), "missing disk-pressure planner task id constant");
assert(source.includes('agentPlannerTaskIdDiskResourcePressure = "resource-pressure-recovery"'), "missing disk-pressure planner task id value");
assert(source.includes("agentPlannerTaskIdMemoryResourcePressure : Str"), "missing memory-pressure planner task id constant");
assert(source.includes('agentPlannerTaskIdMemoryResourcePressure = "resource-memory-pressure-recovery"'), "missing memory-pressure planner task id value");
assert(source.includes("agentPlannerTaskIdAffectedVerifierLaunch : Str"), "missing affected-verifier launch planner task id constant");
assert(source.includes('agentPlannerTaskIdAffectedVerifierLaunch = "affected-verifier-launch-preflight"'), "missing affected-verifier launch planner task id value");
assert(source.includes("agentPlannerTaskIdCapabilityAuditClosure : Str"), "missing capability-audit planner task id constant");
assert(source.includes('agentPlannerTaskIdCapabilityAuditClosure = "capability-audit-closure"'), "missing capability-audit planner task id value");
assert(source.includes("agentPlannerTaskIdStandaloneSwarmReadiness : Str"), "missing standalone-swarm planner task id constant");
assert(source.includes('agentPlannerTaskIdStandaloneSwarmReadiness = "standalone-swarm-readiness"'), "missing standalone-swarm planner task id value");
assert(source.includes("agentValidationFromIssues : [Str] -> [AgentValidationIssue] -> AgentValidationSummary"), "missing validation summary helper");
assert(source.includes("agentValidationMerge : AgentValidationSummary -> AgentValidationSummary -> AgentValidationSummary"), "missing validation summary merge helper");
assert(source.includes("agentValidationMergeAll : [AgentValidationSummary] -> AgentValidationSummary"), "missing validation summary batch merge helper");
assert(source.includes("agentValidationSummariesOk : [AgentValidationSummary] -> Bool"), "missing validation summary batch ok helper");
assert(source.includes("agentValidationSummariesIssueTexts : [AgentValidationSummary] -> [Str]"), "missing validation summary issue text aggregation helper");
assert(source.includes("agentRequireNonEmptyText : Str -> Str -> [AgentValidationIssue]"), "missing non-empty text validation helper");
assert(source.includes("agentRequireNonEmptyList : Str -> [a] -> [AgentValidationIssue]"), "missing polymorphic non-empty list validation helper");
assert(source.includes("agentRequirePositiveInt : Str -> Int -> [AgentValidationIssue]"), "missing positive int validation helper");
assert(source.includes("agentRequireOk : Str -> Result a -> [AgentValidationIssue]"), "missing polymorphic Result validation helper");
assert(source.includes("agentRequireProcessSucceeded : Str -> AgentProcessResult -> [AgentValidationIssue]"), "missing process validation helper");
assert(source.includes("agentJsonRequireRawFields : Str -> Str -> [Str] -> [AgentValidationIssue]"), "missing JSON required-field validation helper");
assert(source.includes("agentJsonDecodeSummary : Str -> Result a -> AgentValidationSummary"), "missing polymorphic JSON decode summary helper");
assert(source.includes("agentJsonDecodeAndRequireFields : Str -> Str -> Result a -> [Str] -> AgentValidationSummary"), "missing JSON decode-and-required-fields helper");
assert(source.includes("agentJsonDecodeOk : Result a -> Bool"), "missing polymorphic JSON decode ok helper");
assert(source.includes("agentWorkspacePatchPreflightIssues : Str -> AgentWorkspacePatch -> [AgentValidationIssue]"), "missing workspace patch preflight helper");
assert(source.includes("agentWorkspaceApplyPatch : Str -> AgentWorkspacePatch -> AgentWorkspacePatchResult"), "missing workspace patch apply helper");
assert(source.includes("agentWorkspaceApplyPatches : Str -> [AgentWorkspacePatch] -> [AgentWorkspacePatchResult]"), "missing workspace patch batch helper");
assert(source.includes("agentWorkspacePatchResultsOk : [AgentWorkspacePatchResult] -> Bool"), "missing workspace patch result aggregation helper");
assert(source.includes('foreign agentWorkspaceReadFileRaw : Str -> Str -> Result Str = "workspaceReadFile"'), "missing workspace read binding");
assert(source.includes('foreign agentWorkspaceWriteFileRaw : Str -> Str -> Str -> Result Str = "workspaceWriteFile"'), "missing workspace write binding");
assert(source.includes('foreign agentWorkspaceSearchTextRaw : Str -> Str -> Str -> Int -> Int -> Int -> Int -> Result [Str] = "workspaceSearchText"'), "missing workspace search binding");
assert(source.includes('foreign agentWorkspaceReplaceTextRaw : Str -> Str -> Str -> Str -> Int -> Int -> Result Int = "workspaceReplaceText"'), "missing workspace replace binding");
assert(source.includes('foreign agentRunWorkspaceCommandTimeoutRaw : Str -> Str -> Int -> [Str] -> Result Str = "runWorkspaceCommandTimeoutJson"'), "missing process JSON binding");
assert(source.includes('foreign agentHostFileSizeMbRaw : Str -> Result Int = "hostFileSizeMb"'), "missing host file size binding");
assert(source.includes("agentReadTextOr : Str -> Str -> Str"), "missing agent text read fallback helper");
assert(source.includes("agentReadEnvInt : Str -> Int -> Int"), "missing agent env int helper");
assert(source.includes("agentProcessResultFromJson : Result Str -> Result AgentProcessResult"), "missing typed process JSON wrapper");
assert(source.includes("agentProcessRunPreflightIssues : Str -> Str -> Int -> [Str] -> [AgentValidationIssue]"), "missing checked process preflight issues helper");
assert(source.includes("agentProcessRunPreflightSummary : Str -> Str -> Int -> [Str] -> AgentValidationSummary"), "missing checked process preflight summary helper");
assert(source.includes("agentRunWorkspaceCommandTimeoutChecked : Str -> Str -> Int -> [Str] -> AgentCheckedProcessRun"), "missing checked process runner helper");
assert(source.includes("agentRunCommandStep : Str -> AgentCommandStep -> AgentCommandStepResult"), "missing checked command step runner");
assert(source.includes("agentCommandStepResultStatusTexts : [AgentCommandStepResult] -> [Str]"), "missing command step status aggregation helper");
assert(source.includes("agentRunCommandPlan : Str -> [AgentCommandStep] -> AgentCommandPlanResult"), "missing checked command plan runner");
assert(source.includes("agentRunCommandPlanFailFast : Str -> [AgentCommandStep] -> AgentCommandPlanResult"), "missing fail-fast command plan runner");
assert(source.includes("agentVerifierMemoryPolicyDefault : AgentVerifierMemoryPolicy"), "missing default verifier memory policy");
assert(source.includes("agentVerifierMemoryPolicyValidation : AgentVerifierMemoryPolicy -> AgentValidationSummary"), "missing verifier memory policy validation");
assert(source.includes("agentVerifierMemoryPolicySummary : AgentVerifierMemoryPolicy -> AgentVerifierMemoryPolicySummary"), "missing verifier memory policy summary");
assert(source.includes("agentVerifierGateStatus : AgentVerifierMemoryPolicySummary -> AgentCommandPlanResult -> Str"), "missing verifier gate status helper");
assert(source.includes("agentVerifierGate : AgentVerifierMemoryPolicySummary -> AgentCommandPlanResult -> AgentVerifierGate"), "missing verifier gate helper");
assert(source.includes("agentAffectedVerificationPlanValidation : AgentAffectedVerificationPlan -> AgentValidationSummary"), "missing affected verification plan validation helper");
assert(source.includes("agentAffectedCommandResourceConsistencyIssues : AgentAffectedCommandResource -> [AgentValidationIssue]"), "missing affected command consistency validation helper");
assert(source.includes("safe-direct command requires managed guard"), "missing safe-direct managed guard conflict validation");
assert(source.includes("safe-direct command has high OOM risk"), "missing safe-direct OOM conflict validation");
assert(source.includes("high OOM risk command must require managed guard"), "missing high OOM managed guard validation");
assert(source.includes("agentAffectedVerificationPlanDecision : AgentAffectedVerificationPlan -> AgentAffectedVerificationPlanDecision"), "missing affected verification plan decision helper");
assert(source.includes("agentAffectedVerificationPlanDecisionFromJson : Str -> AgentAffectedVerificationPlanDecision"), "missing affected verification plan JSON decision helper");
assert(source.includes("agentAffectedVerificationLaunchPolicy : AgentAffectedVerificationPlanDecision -> AgentAffectedVerificationLaunchPolicy"), "missing affected verification launch policy helper");
assert(source.includes("agentAffectedVerificationLaunchPolicyFromJson : Str -> AgentAffectedVerificationLaunchPolicy"), "missing affected verification launch policy JSON helper");
assert(source.includes("agentAffectedVerificationInvalidPlanJsonForReason : Str -> Str"), "missing invalid affected verifier plan JSON helper");
assert(source.includes("agentAffectedVerificationInvalidLaunchPolicyJsonForReason : Str -> Str"), "missing invalid affected verifier launch policy JSON helper");
assert(source.includes("agentAffectedVerificationContextMaxMb"), "missing affected verifier context size cap");
assert(source.includes("CLASP_LOOP_AFFECTED_VERIFICATION_CONTEXT_MAX_MB_JSON"), "missing affected verifier context cap env");
assert(source.includes("agentBoundedAffectedVerificationPlanJsonFromPath : Str -> Str"), "missing bounded affected verifier plan path helper");
assert(source.includes("agentBoundedAffectedVerificationLaunchPolicyJsonFromPath : Str -> Str"), "missing bounded affected verifier launch policy path helper");
assert(source.includes("affected-verification-context:oversize"), "missing affected verifier oversize marker");
assert(source.includes("affected-verification-context:size-check-failed"), "missing affected verifier size-check marker");
assert(source.includes("verificationPlanRecommendation : Str"), "missing affected verification launch policy plan recommendation field");
assert(source.includes("affected-verification-plan:run-managed-memory-disk-admission"), "missing affected verification heavy managed recommendation");
assert(source.includes("affected-verification-launch:direct-compiler-state-free"), "missing affected verification direct compiler-state-free launch recommendation");
assert(source.includes("affected-verification-launch:direct-compiler-state-access-preflight"), "missing affected verification cache-touching launch recommendation");
assert(source.includes("affected-verification-launch:managed-heavy-memory-disk"), "missing affected verification heavy launch recommendation");
assert(source.includes("CLASP_VERIFY_DIRECT_MEMORY_LIMIT_MB"), "missing direct verifier memory cap evidence");
assert(source.includes("CLASP_VERIFY_AFFECTED_DIRECT_MEMORY_LIMIT_MB"), "missing affected verifier memory cap evidence");
assert(source.includes("agentWorkspaceSearchTextOrEmpty"), "missing search fallback helper");
assert(source.includes("agentWorkspaceReplaceTextCount"), "missing replacement count helper");
assert(harness.includes("harnessEmptyTaskList : [HarnessTask]"), "harness should prove contextual empty list typing for records");
assert(harness.includes("harnessEmptySearch : [Str]"), "harness should prove contextual empty list typing for text lists");
assert(harness.includes("tryDecode HarnessJsonItem validJsonText"), "harness should prove JSON decode validation helpers");
assert(harness.includes("affectedStaticPlanJson : Str"), "harness should include static affected-verifier plan JSON");
assert(harness.includes("affectedHeavyPlanJson : Str"), "harness should include heavy affected-verifier plan JSON");
assert(harness.includes("affectedInconsistentPlanJson : Str"), "harness should include inconsistent affected-verifier plan JSON");
assert(harness.includes("agentAffectedVerificationPlanDecisionFromJson affectedHeavyPlanJson"), "harness should prove affected-verifier plan decision from JSON");

assert(report.resultOk === true, "Result ok helper failed");
assert(report.resultErr === true, "Result err helper failed");
assert(report.resultDefaultText === "fallback", "Result default text failed");
assert(report.resultDefaultInt === 7, "Result default int failed");
assert(report.resultError === "missing-record", "Result error extraction failed");
assert(report.taskListCount === 1, "Result-to-list record helper failed");
assert(report.emptyTaskListCount === 0, "empty record list helper failed");
assert(report.emptySearchCount === 0, "empty search list helper failed");
assert(report.nonEmptyJoined === "alpha,beta", "non-empty join helper failed");
assert(report.workspaceMkdirStatus === "ok", `mkdir status ${report.workspaceMkdirStatus}`);
assert(report.workspaceWriteStatus === "ok", `write status ${report.workspaceWriteStatus}`);
assert(report.workspaceAppendStatus === "ok", `append status ${report.workspaceAppendStatus}`);
assert(report.workspaceReadText.includes("status=done"), "workspace read/replace helper failed");
assert(report.workspaceReadText.includes("extra=done"), "workspace patch batch helper failed");
assert(report.workspaceReplaceCount === 2, `replace count ${report.workspaceReplaceCount}`);
assert(report.workspaceSearchCount >= 1, `search count ${report.workspaceSearchCount}`);
assert(report.workspaceEscapeStatus.includes("workspace_path_escape"), `parent escape status ${report.workspaceEscapeStatus}`);
assert(report.workspacePatchOk === true, "workspace patch batch should pass");
assert(report.workspacePatchResultCount === 2, `workspace patch result count ${report.workspacePatchResultCount}`);
assert(report.workspacePatchIssueCount === 0, `workspace patch issue count ${report.workspacePatchIssueCount}`);
assert(report.workspacePatchFailureOk === false, "missing-text workspace patch should fail preflight");
assert(report.workspacePatchFailureIssue === "notes/input.txt:missing text: does-not-exist", `workspace patch failure issue ${report.workspacePatchFailureIssue}`);
assert(report.validationOk === false, "validation summary should report the deliberate missing field");
assert(report.validationIssueCount === 1, `validation issue count ${report.validationIssueCount}`);
assert(report.validationIssueText === "emptyField:required non-empty text", `validation issue text ${report.validationIssueText}`);
assert(report.validationEvidenceCount === 1, `validation evidence count ${report.validationEvidenceCount}`);
assert(report.validationCombinedOk === false, "combined validation gate should fail on collected issues");
assert(report.validationCombinedIssueCount === 2, `combined validation issue count ${report.validationCombinedIssueCount}`);
assert(report.validationCombinedIssueText === "emptyField:required non-empty text", `combined validation first issue ${report.validationCombinedIssueText}`);
assert(report.validationCombinedEvidenceCount === 6, `combined validation evidence count ${report.validationCombinedEvidenceCount}`);
assert(report.validationPassingBatchOk === true, "passing validation batch should be ok");
assert(report.jsonDecodeOk === true, "JSON decode summary should pass valid input");
assert(report.jsonDecodeIssueCount === 0, `JSON decode issue count ${report.jsonDecodeIssueCount}`);
assert(report.jsonDecodeEvidenceCount === 2, `JSON decode evidence count ${report.jsonDecodeEvidenceCount}`);
assert(report.jsonMissingFieldIssue === "HarnessJsonItem:missing json field: missing", `JSON missing field issue ${report.jsonMissingFieldIssue}`);
assert(report.jsonMalformedIssue.startsWith("HarnessJsonItem:json decode failed:"), `JSON malformed issue ${report.jsonMalformedIssue}`);
assert(report.processValidationOk === true, "process validation helper failed");
assert(report.processValidationIssueCount === 0, `process validation issue count ${report.processValidationIssueCount}`);
assert(report.processOk === true, "process success helper failed");
assert(report.processExitCode === 0, `process exit ${report.processExitCode}`);
assert(report.processStdout === "agent-process-ok", `process stdout ${report.processStdout}`);
assert(report.processSummary === "pass:0:finished:no-error", `process summary ${report.processSummary}`);
assert(report.checkedProcessOk === true, "checked process run helper failed");
assert(report.checkedProcessStatus === "ok", `checked process status ${report.checkedProcessStatus}`);
assert(report.checkedProcessStdout === "checked-process-ok", `checked process stdout ${report.checkedProcessStdout}`);
assert(report.checkedProcessEvidenceCount === 5, `checked process evidence count ${report.checkedProcessEvidenceCount}`);
assert(report.checkedProcessPreflightOk === false, "checked process preflight failure should not run");
assert(report.checkedProcessPreflightStatus === "preflight-error", `checked preflight status ${report.checkedProcessPreflightStatus}`);
assert(report.checkedProcessPreflightIssueCount === 3, `checked preflight issue count ${report.checkedProcessPreflightIssueCount}`);
assert(report.checkedProcessPreflightFirstIssue === "cwd:required non-empty text", `checked preflight first issue ${report.checkedProcessPreflightFirstIssue}`);
assert(report.commandPlanOk === true, "checked command plan should pass");
assert(report.commandPlanCompletedCount === 2, `command plan completed count ${report.commandPlanCompletedCount}`);
assert(report.commandPlanFailedCount === 0, `command plan failed count ${report.commandPlanFailedCount}`);
assert(report.commandPlanEvidenceCount === 12, `command plan evidence count ${report.commandPlanEvidenceCount}`);
assert(report.commandPlanFirstStatus === "plan-a:ok", `command plan first status ${report.commandPlanFirstStatus}`);
assert(report.failFastPlanOk === false, "fail-fast command plan should fail");
assert(report.failFastPlanCompletedCount === 2, `fail-fast completed count ${report.failFastPlanCompletedCount}`);
assert(report.failFastPlanFailedCount === 1, `fail-fast failed count ${report.failFastPlanFailedCount}`);
assert(report.failFastPlanStatusText === "failfast-a:ok,failfast-b:process-failed", `fail-fast status text ${report.failFastPlanStatusText}`);
assert(report.verifierMemoryPolicyOk === true, "default verifier memory policy should pass");
assert(report.verifierMemoryPolicyIssueCount === 0, `verifier memory policy issues ${report.verifierMemoryPolicyIssueCount}`);
assert(report.verifierMemoryPolicyEvidenceCount === 6, `verifier memory policy evidence count ${report.verifierMemoryPolicyEvidenceCount}`);
assert(report.verifierMemoryPolicyRecommendation === "verifier-memory-policy:bounded", `verifier memory policy recommendation ${report.verifierMemoryPolicyRecommendation}`);
assert(report.unsafeVerifierMemoryPolicyOk === false, "unsafe verifier memory policy should fail");
assert(report.unsafeVerifierMemoryPolicyIssueText === "CLASP_VERIFY_DIRECT_MEMORY_LIMIT_MB:memory limit must stay enabled", `unsafe verifier memory issue ${report.unsafeVerifierMemoryPolicyIssueText}`);
assert(report.verifierGateOk === true, "passing verifier gate should pass");
assert(report.verifierGateStatus === "pass", `verifier gate status ${report.verifierGateStatus}`);
assert(report.verifierGateIssueCount === 0, `verifier gate issue count ${report.verifierGateIssueCount}`);
assert(report.verifierGateEvidenceCount === 22, `verifier gate evidence count ${report.verifierGateEvidenceCount}`);
assert(report.verifierGateRecommendation === "verifier-gate:pass", `verifier gate recommendation ${report.verifierGateRecommendation}`);
assert(report.failedVerifierGateOk === false, "failed command verifier gate should fail");
assert(report.failedVerifierGateStatus === "commands-failed", `failed verifier gate status ${report.failedVerifierGateStatus}`);
assert(report.failedVerifierGateRecommendation === "verifier-gate:fix-failed-checks", `failed verifier gate recommendation ${report.failedVerifierGateRecommendation}`);
assert(report.unsafeVerifierGateOk === false, "unsafe memory verifier gate should fail");
assert(report.unsafeVerifierGateStatus === "memory-policy-failed", `unsafe verifier gate status ${report.unsafeVerifierGateStatus}`);
assert(report.unsafeVerifierGateIssueText === "CLASP_VERIFY_DIRECT_MEMORY_LIMIT_MB:memory limit must stay enabled", `unsafe verifier gate issue ${report.unsafeVerifierGateIssueText}`);
assert(report.affectedStaticPlanStatus === "safe-direct", `static affected plan status ${report.affectedStaticPlanStatus}`);
assert(report.affectedStaticPlanCanRunDirect === true, "static affected plan should be runnable directly");
assert(report.affectedStaticPlanCanRunWithoutCompilerState === true, "static affected plan should be runnable without compiler state");
assert(report.affectedStaticPlanRecommendation === "affected-verification-plan:safe-direct-compiler-state-free", `static affected plan recommendation ${report.affectedStaticPlanRecommendation}`);
assert(report.affectedStaticPlanIssueCount === 0, `static affected plan issue count ${report.affectedStaticPlanIssueCount}`);
assert(report.affectedStaticPlanEvidenceCount === 21, `static affected plan evidence count ${report.affectedStaticPlanEvidenceCount}`);
assert(report.affectedStaticPlanCompilerStateFreeCommandCount === 2, `static affected plan compiler-state-free command count ${report.affectedStaticPlanCompilerStateFreeCommandCount}`);
assert(report.affectedStaticLaunchMode === "direct-compiler-state-free", `static affected launch mode ${report.affectedStaticLaunchMode}`);
assert(report.affectedStaticLaunchReady === true, "static affected launch policy should be ready");
assert(report.affectedStaticLaunchRecommendation === "affected-verification-launch:direct-compiler-state-free", `static affected launch recommendation ${report.affectedStaticLaunchRecommendation}`);
assert(report.affectedCacheProbePlanStatus === "safe-direct", `cache-probe affected plan status ${report.affectedCacheProbePlanStatus}`);
assert(report.affectedCacheProbePlanCanRunDirect === true, "cache-probe affected plan should be runnable directly");
assert(report.affectedCacheProbePlanCanRunWithoutCompilerState === false, "cache-probe affected plan should not be compiler-state-free");
assert(report.affectedCacheProbePlanRecommendation === "affected-verification-plan:safe-direct-compiler-state-access", `cache-probe affected plan recommendation ${report.affectedCacheProbePlanRecommendation}`);
assert(report.affectedCacheProbePlanCompilerStateTouchingCommandCount === 1, `cache-probe affected plan compiler-state-touching command count ${report.affectedCacheProbePlanCompilerStateTouchingCommandCount}`);
assert(report.affectedCacheProbeLaunchMode === "direct-compiler-state-access", `cache-probe affected launch mode ${report.affectedCacheProbeLaunchMode}`);
assert(report.affectedCacheProbeLaunchReady === false, "cache-probe affected launch policy should require preflight");
assert(report.affectedCacheProbeLaunchBlockingGap === "affected verifier plan touches compiler/cache state before launch", `cache-probe affected launch blocking gap ${report.affectedCacheProbeLaunchBlockingGap}`);
assert(report.affectedDirectLaunchPolicyMode === "direct-compiler-state-access", `direct affected launch policy mode ${report.affectedDirectLaunchPolicyMode}`);
assert(report.affectedDirectLaunchPolicyReady === false, "direct affected launch policy JSON should require preflight");
assert(report.affectedDirectLaunchPolicyPlanRecommendation === "affected-verification-plan:safe-direct-compiler-state-access", `direct affected launch policy plan recommendation ${report.affectedDirectLaunchPolicyPlanRecommendation}`);
assert(report.affectedDirectLaunchPolicyBlockingGap === "affected verifier plan touches compiler/cache state before launch", `direct affected launch policy gap ${report.affectedDirectLaunchPolicyBlockingGap}`);
assert(report.affectedHeavyPlanStatus === "heavy-managed", `heavy affected plan status ${report.affectedHeavyPlanStatus}`);
assert(report.affectedHeavyPlanCanRunDirect === false, "heavy affected plan should not run directly");
assert(report.affectedHeavyPlanCanRunWithoutCompilerState === false, "heavy affected plan should touch compiler state");
assert(report.affectedHeavyPlanRequiresManaged === true, "heavy affected plan should require managed guard");
assert(report.affectedHeavyPlanRecommendation === "affected-verification-plan:run-managed-memory-disk-admission", `heavy affected plan recommendation ${report.affectedHeavyPlanRecommendation}`);
assert(report.affectedHeavyPlanHeavyCommandCount === 1, `heavy affected plan heavy command count ${report.affectedHeavyPlanHeavyCommandCount}`);
assert(report.affectedHeavyPlanCompilerStateTouchingCommandCount === 2, `heavy affected plan compiler-state-touching command count ${report.affectedHeavyPlanCompilerStateTouchingCommandCount}`);
assert(report.affectedHeavyLaunchMode === "heavy-managed", `heavy affected launch mode ${report.affectedHeavyLaunchMode}`);
assert(report.affectedHeavyLaunchReady === false, "heavy affected launch policy should require managed admission");
assert(report.affectedHeavyLaunchBlockingGap === "affected verifier plan requires managed memory/disk admission before launch", `heavy affected launch blocking gap ${report.affectedHeavyLaunchBlockingGap}`);
assert(report.affectedInvalidPlanStatus === "invalid-plan", `invalid affected plan status ${report.affectedInvalidPlanStatus}`);
assert(report.affectedInvalidPlanIssueText === "commandResourceSummary.commandCount:selected command count mismatch", `invalid affected plan issue ${report.affectedInvalidPlanIssueText}`);
assert(report.affectedInvalidPlanRecommendation === "affected-verification-plan:repair-plan-json", `invalid affected plan recommendation ${report.affectedInvalidPlanRecommendation}`);
assert(report.affectedInconsistentPlanStatus === "invalid-plan", `inconsistent affected plan status ${report.affectedInconsistentPlanStatus}`);
assert(report.affectedInconsistentPlanIssueText === "unsafe-direct:safe-direct command requires managed guard", `inconsistent affected plan issue ${report.affectedInconsistentPlanIssueText}`);
assert(report.affectedInconsistentPlanRecommendation === "affected-verification-plan:repair-plan-json", `inconsistent affected plan recommendation ${report.affectedInconsistentPlanRecommendation}`);
assert(!fs.existsSync(path.join(path.dirname(workspaceRoot), "outside.txt")), "workspace helper should not write outside root");
NODE

printf 'agent-ergonomics-helpers-ok\n'
