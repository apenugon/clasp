#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
mode="${1:-${CLASP_LOCAL_AGENT_CAPABILITY_CLOSURE_MODE:-full}}"

usage() {
  cat <<'EOF'
usage: scripts/test-local-agent-capability-closure.sh [static|full]

static  Validate the LocalAgent capability-closure contract without invoking claspc.
full    Compile and run the ordinary Clasp LocalAgent capability-closure fixture.
EOF
}

case "$mode" in
  --help|-h)
    usage
    exit 0
    ;;
  static|smoke)
    node - "$project_root" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");

const projectRoot = process.argv[2];
const localAgent = fs.readFileSync(path.join(projectRoot, "examples/swarm-native/LocalAgent.clasp"), "utf8");
const localSourceEdit = fs.readFileSync(path.join(projectRoot, "examples/swarm-native/LocalSourceEdit.clasp"), "utf8");
const testSource = fs.readFileSync(path.join(projectRoot, "scripts/test-local-agent-capability-closure.sh"), "utf8");

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

for (const marker of [
  "promptAffectedVerificationPlanJson : Str -> Str",
  "promptHasAffectedVerificationPlanJson : Str -> Bool",
  "promptAffectedVerificationPlanPath : Str -> Str",
  "promptHasAffectedVerificationPlanPath : Str -> Bool",
  "promptAffectedVerificationLaunchPolicyJson : Str -> Str",
  "promptHasAffectedVerificationLaunchPolicyJson : Str -> Bool",
  "promptAffectedVerificationLaunchPolicyPath : Str -> Str",
  "promptHasAffectedVerificationLaunchPolicyPath : Str -> Bool",
  "promptFocusedVerificationLaunchPolicyJson : Str -> Str",
  "promptHasFocusedVerificationLaunchPolicyJson : Str -> Bool",
  "promptAutonomousLaunchGateJson : Str -> Str",
  "promptHasAutonomousLaunchGateJson : Str -> Bool",
  "agentAffectedVerificationPlanJsonFromPrompt prompt",
  "agentAffectedVerificationLaunchPolicyJsonFromPrompt prompt",
  "agentFocusedVerificationLaunchPolicyJsonFromPrompt prompt",
  "agentAutonomousLaunchGateJsonFromPrompt prompt",
  "affectedVerificationPlanCapabilityStatus : AgentAffectedVerificationPlanDecision -> CapabilityStatus",
  "affectedVerificationLaunchPolicyCapabilityStatus : AgentAffectedVerificationLaunchPolicy -> CapabilityStatus",
  "affectedVerificationPlanCapabilityStatuses : Str -> [CapabilityStatus]",
  "affectedVerificationPlanTestsRun : Str -> [Str]",
  "promptHasFocusedVerificationPlanSection : Str -> Bool",
  "focusedVerificationPlanCapabilityStatus : Str -> CapabilityStatus",
  "focusedVerificationLaunchPolicyCapabilityStatus : AgentFocusedVerificationLaunchPolicy -> CapabilityStatus",
  "focusedVerificationPlanCapabilityStatuses : Str -> [CapabilityStatus]",
  "focusedVerificationPlanTestsRun : Str -> [Str]",
  "autonomousLaunchGateCapabilityStatus : AgentAutonomousLaunchGate -> CapabilityStatus",
  "autonomousLaunchGateCapabilityStatuses : Str -> [CapabilityStatus]",
  "autonomousLaunchGateTestsRun : Str -> [Str]",
  "agentFocusedVerificationLaunchPolicyFromPrompt prompt",
  "agentFocusedVerificationLaunchPolicyFromJson",
  "agentAutonomousLaunchGateFromJson",
  "autonomous_launch_gate",
  "autonomous-launch-gate-mode:",
  "autonomous-launch-gate-recommendation:",
  "clasp-local-agent-autonomous-launch-gate",
  "focused-verification-launch-policy-mode:",
  "focused-verification-launch-policy-recommendation:",
  "focused_verification_launch_policy",
  "focused_verification_plan",
  "clasp-local-agent-focused-verification-plan",
  "clasp-local-agent-focused-verification-launch-policy",
  "focused-verification-plan-safe-direct:",
  "blocking_gaps = launchPolicy.blockingGaps",
  "agentAffectedVerificationPlanDecisionFromJson",
  "agentAffectedVerificationLaunchPolicyFromJson",
  "agentAffectedVerificationLaunchPolicy decision",
  "affected_verification_plan",
  "affected_verification_launch_policy",
  "clasp-local-agent-affected-verification-plan",
  "clasp-local-agent-affected-verification-launch-policy",
  "affected-verification-plan-status:",
  "affected-verification-plan-recommendation:",
  "affected-verification-plan-safe-direct-command-count:",
  "affected-verification-plan-managed-guard-command-count:",
  "affected-verification-plan-compiler-state-free-command-count:",
  "affected-verification-plan-compiler-state-touching-command-count:",
  "affected-verification-plan-can-run-without-compiler-state:",
  "affected-verification-plan-requires-managed:",
  "blocking_gaps = launchPolicy.blockingGaps",
  "required_closure = launchPolicy.requiredClosure",
  "workspace_fingerprint_manifest : Str",
  "workspace_fingerprint_manifest_fingerprint64_hex : Str",
  "standaloneSwarmWorkspaceFingerprintManifestForPrompt : Str -> Str -> Str",
  "standaloneSwarmWorkspaceFingerprintManifestFingerprint64Hex : Str -> Str -> Str -> Str",
  "localVerifierFindingsFor : Str -> Str -> Str -> Str -> [Str]",
  "standaloneSwarmDirectSourceEditIssueTexts workspaceRoot route prompt",
  "standaloneSwarmDirectSourceEditRepairHints workspaceRoot route prompt",
  "standalone-swarm direct source edit proof missing or invalid",
  "Check notes/direct-source-edit.txt and notes/direct-source-edit-manifest.json",
  "capability-audit closure artifacts missing or invalid",
  "capabilityAuditClosureDecisionForPrompt : Str -> AgentCapabilityAuditClosureDecision",
  "capabilityAuditClosureDecisionEvidence : AgentCapabilityAuditClosureDecision -> [Str]",
  "capabilityAuditClosureDecisionBuilderErgonomics : Str -> Str -> [Str]",
  "capabilityAuditClosureDecisionCapabilityStatus : Str -> CapabilityStatus",
  "capabilityAuditClosureDecisionCapabilityStatuses : Str -> Str -> [CapabilityStatus]",
  "agentCapabilityAuditClosureDecisionFromPromptOrJson prompt",
  "capability_audit_closure_decision",
  "capability-audit-decision-kind:",
  "clasp-local-agent-capability-audit-decision",
  "notes/capability-audit-decision.json",
  "decisionKind : Str",
  "decisionKind=",
  "decisionFile=notes/capability-audit-decision.json",
  "encode decision",
  "capabilityAuditDecisionJsonValid : Str -> Bool",
  "tryDecode AgentCapabilityAuditClosureDecision raw",
  "capabilityAuditDecisionJsonValid decisionJson",
]) {
  assert(localAgent.includes(marker), `missing LocalAgent marker: ${marker}`);
}

for (const marker of [
  "standaloneSwarmDirectSourceEditIssueTexts : Str -> Str -> Str -> [Str]",
  "standaloneSwarmDirectSourceEditRepairHints : Str -> Str -> Str -> [Str]",
  "standaloneSwarmDirectSourceEditRepairHintForIssue : Str -> Str",
  "standalone-source-edit:planned-patch-replacement-missing",
  "standalone-source-edit:manifest-target-fingerprints-missing",
  "standalone-source-edit:proof-metadata-missing",
  "standalone-source-edit-repair:apply-planned-patch-replacements",
  "standalone-source-edit-repair:regenerate-direct-source-edit-manifest",
]) {
  assert(localSourceEdit.includes(marker), `missing LocalSourceEdit marker: ${marker}`);
}

for (const marker of [
  "Affected verification plan JSON:",
  "End affected verification plan JSON.",
  "Affected verification plan path:",
  "End affected verification plan path.",
  "Affected verification launch policy JSON:",
  "End affected verification launch policy JSON.",
  "Affected verification launch policy path:",
  "End affected verification launch policy path.",
  "Focused verification launch policy JSON:",
  "End focused verification launch policy JSON.",
  "Autonomous launch gate JSON:",
  "End autonomous launch gate JSON.",
  "Focused verification plan:",
  "verifier should record focused verification plan coverage",
  "verifier should emit focused verification plan status",
  "verifier should record affected verification plan coverage",
  "verifier should emit affected verification plan launch decision",
  "workspaceFingerprintManifest=notes/direct-source-edit-manifest.json",
  "workspace_fingerprint_manifest_fingerprint64_hex",
  "local-agent-capability-closure-static-ok",
]) {
  assert(testSource.includes(marker), `missing test marker: ${marker}`);
}

process.stdout.write("local-agent-capability-closure-static-ok\n");
NODE
    exit 0
    ;;
  full)
    ;;
  *)
    printf 'test-local-agent-capability-closure: unknown mode: %s\n' "$mode" >&2
    usage >&2
    exit 2
    ;;
esac

mkdir -p "$tmp_root"
export TMPDIR="$tmp_root"
test_root="$(mktemp -d "$TMPDIR/test-local-agent-capability-closure.XXXXXX")"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$test_root/xdg-cache}"
export CLASP_NATIVE_RUN_BINARY_CACHE_DIR="${CLASP_NATIVE_RUN_BINARY_CACHE_DIR:-$test_root/run-binary-cache-v2}"
export CLASP_NATIVE_RUN_BINARY_CACHE_MAX_MB="${CLASP_NATIVE_RUN_BINARY_CACHE_MAX_MB:-512}"
mkdir -p "$XDG_CACHE_HOME"
mkdir -p "$CLASP_NATIVE_RUN_BINARY_CACHE_DIR"

cleanup() {
  if [[ "${CLASP_TEST_KEEP_TMP:-0}" != "1" ]]; then
    rm -rf "$test_root"
  fi
}

trap cleanup EXIT

timeout_secs="${CLASP_LOCAL_AGENT_CAPABILITY_CLOSURE_TIMEOUT_SECS:-900}"
export CLASP_NATIVE_IMAGE_MODULE_DECL_CHUNK_SIZE="${CLASP_LOCAL_AGENT_CAPABILITY_CLOSURE_MODULE_DECL_CHUNK_SIZE:-8}"
export CLASP_NATIVE_IMAGE_MODULE_DECL_FRESH_PROCESS="${CLASP_LOCAL_AGENT_CAPABILITY_CLOSURE_MODULE_DECL_FRESH_PROCESS:-1}"
export CLASP_NATIVE_EXPORT_HOST_IDLE_TIMEOUT_SECS="${CLASP_LOCAL_AGENT_CAPABILITY_CLOSURE_EXPORT_HOST_IDLE_TIMEOUT_SECS:-5}"
claspc_bin="$(env -u CLASP_CLASPC -u CLASPC_BIN -u RUSTC "$project_root/scripts/resolve-claspc.sh")"
local_agent_bin="$test_root/local-agent-bin"
workspace_root="$test_root/workspace"
prompt_root="$test_root/prompts"
builder_report="$test_root/builder-report.json"
verifier_report="$test_root/verifier-report.json"
source_workspace_root="$test_root/source-edit-workspace"
source_builder_report="$test_root/source-builder-report.json"
source_verifier_report="$test_root/source-verifier-report.json"
source_drift_verifier_report="$test_root/source-drift-verifier-report.json"
source_negative_verifier_report="$test_root/source-negative-verifier-report.json"
source_transaction_workspace_root="$test_root/source-edit-transaction-workspace"
source_transaction_builder_report="$test_root/source-transaction-builder-report.json"
source_transaction_builder_output="$test_root/source-transaction-builder-output.txt"

mkdir -p "$workspace_root" "$prompt_root"

env RUSTC=/definitely-missing-rustc CLASP_PROJECT_ROOT="$project_root" \
  timeout "$timeout_secs" "$claspc_bin" compile "$project_root/examples/swarm-native/LocalAgent.clasp" \
    -o "$local_agent_bin" >/dev/null

cat >"$prompt_root/builder.prompt.md" <<'EOF'
You are the builder subagent.
Swarm context pack:
task: builder-1 status=ready ready=true attempts=1
artifact search matches:
- verifier feedback exists
Verifier feedback from the previous attempt:
force-close-category
Task file content:
Read the capability audit and close one bounded standalone swarm gap without Codex-specific control flow.
{"schema_version":1,"kind":"clasp-swarm-capability-audit","overall_status":"partial","capability_statuses":[{"name":"standalone_swarm_execution","status":"partial","evidence":["local planner exists"],"blocking_gaps":["Standalone non-Codex agent backend has not yet demonstrated repo-scale improvement."],"required_closure":["Add a stronger local agent backend proof."]}],"blocking_gaps":["Standalone non-Codex agent backend has not yet demonstrated repo-scale improvement."]}
EOF

cat >"$prompt_root/verifier.prompt.md" <<'EOF'
You are the verifier subagent.
Swarm context pack:
task: verifier-1 status=ready ready=true attempts=1
run trace:
- builder-1 completed
Task file content:
Verify the capability-audit closure from the ordinary Clasp local agent.
{"schema_version":1,"kind":"clasp-swarm-capability-audit","overall_status":"partial","capability_statuses":[{"name":"standalone_swarm_execution","status":"partial","blocking_gaps":["Standalone non-Codex agent backend has not yet demonstrated repo-scale improvement."]}]}
Affected verification plan JSON:
{"selectedCommands":[{"id":"swarm-ready","command":"bash scripts/test-swarm-ready-gate.sh","resourceClass":"static","oomRisk":"low","requiresManagedGuard":false,"executionAdvice":"safe-direct","compilerStateAccess":"none"},{"id":"swarm-capability-audit","command":"bash scripts/test-swarm-capability-audit.sh","resourceClass":"static","oomRisk":"low","requiresManagedGuard":false,"executionAdvice":"safe-direct","compilerStateAccess":"none"}],"commandResourceSummary":{"commandCount":2,"staticCommandCount":2,"focusedCommandCount":0,"heavyCommandCount":0,"safeDirectCommandCount":2,"managedGuardCommandCount":0,"compilerStateFreeCommandCount":2,"compilerStateTouchingCommandCount":0,"canRunWithoutCompilerState":true,"requiresManagedGuard":false,"overallAdvice":"safe-direct"},"planOnly":true,"finalVerdict":"planned"}
End affected verification plan JSON.
Affected verification launch policy JSON:
{"valid":true,"ready":false,"mode":"direct-compiler-state-access","canRunDirect":true,"canRunWithoutCompilerState":false,"requiresManagedGuard":false,"recommendation":"affected-verification-launch:direct-compiler-state-access-preflight","verificationPlanRecommendation":"affected-verification-plan:safe-direct-compiler-state-access","blockingGaps":["affected verifier plan touches compiler/cache state before launch"],"requiredClosure":["affected-verification-plan:safe-direct-compiler-state-access"],"evidence":["affected-launch-mode=direct-compiler-state-access","affected-launch-ready=false"]}
End affected verification launch policy JSON.
Focused verification plan:
- command=bash scripts/test-local-agent-capability-closure.sh static
- resourceClass=static
- oomRisk=low
- managedRequired=false
- recommendation=Use the static LocalAgent capability-closure contract before any managed full fixture.
Focused verification launch policy JSON:
{"valid":true,"ready":true,"mode":"direct-safe","command":"bash scripts/test-local-agent-capability-closure.sh static","resourceClass":"static","oomRisk":"low","managedRequired":false,"safeDirect":true,"recommendation":"focused-verification-launch:direct-safe","verificationPlanRecommendation":"Use the static LocalAgent capability-closure contract before any managed full fixture.","blockingGaps":[],"requiredClosure":[],"evidence":["focused-verification-launch-mode=direct-safe","focused-verification-launch-ready=true"]}
End focused verification launch policy JSON.
EOF

timeout "$timeout_secs" "$local_agent_bin" \
  --role builder \
  --report "$builder_report" \
  --prompt-path "$prompt_root/builder.prompt.md" \
  --workspace "$workspace_root" >/dev/null

timeout "$timeout_secs" "$local_agent_bin" \
  --role verifier \
  --report "$verifier_report" \
  --prompt-path "$prompt_root/verifier.prompt.md" \
  --workspace "$workspace_root" >/dev/null

node - "$builder_report" "$verifier_report" "$workspace_root" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const [builderPath, verifierPath, workspaceRoot] = process.argv.slice(2);

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

function textFingerprint64Hex(value) {
  let hash = 0xcbf29ce484222325n;
  for (const byte of Buffer.from(value, "utf8")) {
    hash ^= BigInt(byte);
    hash = (hash * 0x100000001b3n) & 0xffffffffffffffffn;
  }
  return hash.toString(16).padStart(16, "0");
}

const builder = readJson(builderPath);
const verifier = readJson(verifierPath);
const routeText = fs.readFileSync(path.join(workspaceRoot, "notes", "local-agent-route.txt"), "utf8");
const sourceText = fs.readFileSync(path.join(workspaceRoot, "src", "CapabilityAuditClosure.clasp"), "utf8");
const closureText = fs.readFileSync(path.join(workspaceRoot, "notes", "capability-audit-closure.txt"), "utf8");
const decisionText = fs.readFileSync(path.join(workspaceRoot, "notes", "capability-audit-decision.json"), "utf8");
const decisionJson = JSON.parse(decisionText);

assert(routeText === "capability-audit\n", `route ${routeText}`);
assert(builder.files_touched?.includes("src/CapabilityAuditClosure.clasp"), "builder should report closure source");
assert(builder.files_touched?.includes("notes/capability-audit-closure.txt"), "builder should report closure proof");
assert(builder.files_touched?.includes("notes/capability-audit-decision.json"), "builder should report decision json");
assert(builder.tests_run?.includes("clasp-local-agent-capability-audit-closure"), "builder should record closure coverage");
assert(builder.tests_run?.includes("clasp-local-agent-capability-audit-decision"), "builder should record audit decision coverage");
assert(
  builder.feedback?.ergonomics?.includes("local builder produced a concrete capability-audit closure source artifact"),
  "builder ergonomics should mention concrete closure source",
);
assert(
  builder.feedback?.ergonomics?.some((entry) => entry.startsWith("capability-audit-decision-kind:")),
  "builder ergonomics should include decoded audit decision kind",
);
assert(sourceText.includes("module CapabilityAuditClosure"), "closure source should be ordinary Clasp");
assert(sourceText.includes("local-agent-non-codex-source-artifact"), "closure source should carry non-Codex evidence");
assert(sourceText.includes("decisionKind"), "closure source should include decoded audit decision kind");
assert(closureText.includes("kind=clasp-local-agent-capability-audit-closure"), "closure proof should name kind");
assert(closureText.includes("route=capability-audit"), "closure proof should name route");
assert(closureText.includes("decisionKind="), "closure proof should name decoded audit decision kind");
assert(closureText.includes("sourceFile=src/CapabilityAuditClosure.clasp"), "closure proof should name source file");
assert(closureText.includes("decisionFile=notes/capability-audit-decision.json"), "closure proof should name decision json");
assert(closureText.includes("verification=bash scripts/test-local-agent-capability-closure.sh"), "closure proof should name focused verification");
assert(decisionJson.kind, "decision json should include kind");
assert(decisionJson.taskPrompt, "decision json should include task prompt");
assert(Array.isArray(decisionJson.coordinationFocus), "decision json should include coordination focus");
assert(verifier.verdict === "pass", `verifier verdict ${verifier.verdict}`);
assert(verifier.tests_run?.includes("clasp-local-agent-capability-audit-closure"), "verifier should record closure coverage");
assert(verifier.tests_run?.includes("clasp-local-agent-capability-audit-decision"), "verifier should record audit decision coverage");
assert(verifier.tests_run?.includes("clasp-local-agent-verifier-gate"), "verifier should record typed gate coverage");
assert(verifier.tests_run?.includes("clasp-local-agent-affected-verification-plan"), "verifier should record affected verification plan coverage");
assert(verifier.tests_run?.includes("clasp-local-agent-affected-verification-launch-policy"), "verifier should record affected verification launch-policy coverage");
assert(verifier.tests_run?.includes("clasp-local-agent-focused-verification-plan"), "verifier should record focused verification plan coverage");
assert(
  verifier.capability_statuses?.some((entry) =>
    entry.evidence?.includes("local Clasp agent produced capability-audit closure source artifact")
  ),
  "verifier should prove closure source artifact",
);
assert(
  verifier.capability_statuses?.some((entry) =>
    entry.name === "capability_audit_closure_decision" &&
    entry.evidence?.some((evidence) => evidence.startsWith("capability-audit-decision-kind:"))
  ),
  "verifier should expose decoded capability-audit closure decision",
);
assert(
  verifier.capability_statuses?.some((entry) =>
    entry.name === "local_verifier_gate" &&
    entry.status === "pass" &&
    entry.evidence?.includes("local verifier emitted typed gate evidence") &&
    entry.evidence?.includes("local-verifier-gate-recommendation:verifier-gate:pass")
  ),
  "verifier should emit typed pass gate evidence",
);
assert(
  verifier.capability_statuses?.some((entry) =>
    entry.name === "affected_verification_plan" &&
    entry.status === "pass" &&
    entry.evidence?.includes("affected-verification-plan-status:safe-direct") &&
    entry.evidence?.includes("affected-verification-plan-recommendation:affected-verification-plan:safe-direct-compiler-state-free") &&
    entry.evidence?.includes("affected-verification-plan-safe-direct-command-count:2") &&
    entry.evidence?.includes("affected-verification-plan-managed-guard-command-count:0") &&
    entry.evidence?.includes("affected-verification-plan-compiler-state-free-command-count:2") &&
    entry.evidence?.includes("affected-verification-plan-compiler-state-touching-command-count:0") &&
    entry.evidence?.includes("affected-verification-plan-can-run-without-compiler-state:true") &&
    entry.evidence?.includes("affected-verification-plan-requires-managed:false") &&
    entry.evidence?.includes("affected-launch-mode=direct-compiler-state-free") &&
    entry.evidence?.includes("affected-launch-ready=true") &&
    entry.evidence?.includes("affected-launch-recommendation=affected-verification-launch:direct-compiler-state-free")
  ),
  "verifier should emit affected verification plan launch decision",
);
assert(
  verifier.capability_statuses?.some((entry) =>
    entry.name === "affected_verification_launch_policy" &&
    entry.status === "partial" &&
    entry.evidence?.includes("affected-launch-mode=direct-compiler-state-access") &&
    entry.evidence?.includes("affected-launch-ready=false") &&
    entry.evidence?.includes("affected-verification-launch-policy-mode:direct-compiler-state-access") &&
    entry.evidence?.includes("affected-verification-launch-policy-recommendation:affected-verification-launch:direct-compiler-state-access-preflight") &&
    entry.evidence?.includes("affected-verification-launch-policy-plan-recommendation:affected-verification-plan:safe-direct-compiler-state-access") &&
    entry.blocking_gaps?.includes("affected verifier plan touches compiler/cache state before launch") &&
    entry.required_closure?.includes("affected-verification-plan:safe-direct-compiler-state-access")
  ),
  "verifier should emit direct affected verification launch-policy decision",
);
assert(
  verifier.capability_statuses?.some((entry) =>
    entry.name === "focused_verification_plan" &&
    entry.status === "pass" &&
    entry.evidence?.includes("focused-verification-plan-command:bash scripts/test-local-agent-capability-closure.sh static") &&
    entry.evidence?.includes("focused-verification-plan-resource-class:static") &&
    entry.evidence?.includes("focused-verification-plan-oom-risk:low") &&
    entry.evidence?.includes("focused-verification-plan-managed-required:false") &&
    entry.evidence?.includes("focused-verification-plan-safe-direct:true") &&
    entry.evidence?.includes("focused-verification-launch-policy-mode:direct-safe") &&
    entry.evidence?.includes("focused-verification-launch-policy-recommendation:focused-verification-launch:direct-safe")
  ),
  "verifier should emit focused verification plan status",
);
assert(
  verifier.capability_statuses?.some((entry) =>
    entry.name === "focused_verification_launch_policy" &&
    entry.status === "pass" &&
    entry.evidence?.includes("focused-verification-launch-policy-mode:direct-safe") &&
    entry.evidence?.includes("focused-verification-launch-policy-recommendation:focused-verification-launch:direct-safe") &&
    entry.evidence?.includes("focused-verification-launch-policy-plan-recommendation:Use the static LocalAgent capability-closure contract before any managed full fixture.")
  ),
  "verifier should emit direct focused verification launch-policy decision",
);
NODE

mkdir -p "$source_workspace_root/src" "$source_workspace_root/examples/swarm-native" "$source_workspace_root/scripts" "$source_workspace_root/docs" "$source_workspace_root/runtime"
cat >"$source_workspace_root/src/StandaloneSwarmReadiness.clasp" <<'EOF'
module StandaloneSwarmReadiness

readinessStatus : Str
readinessStatus = "open"
EOF
cat >"$source_workspace_root/src/StandaloneSwarmVerifier.clasp" <<'EOF'
module StandaloneSwarmVerifier

verifierStatus : Str
verifierStatus = "open"
EOF
cat >"$source_workspace_root/examples/swarm-native/StandaloneSwarmHarness.clasp" <<'EOF'
module StandaloneSwarmHarness

harnessStatus : Str
harnessStatus = "open"
EOF
cat >"$source_workspace_root/examples/swarm-native/StandaloneSwarmRouting.clasp" <<'EOF'
module StandaloneSwarmRouting

routingStatus : Str
routingStatus = "open"
EOF
cat >"$source_workspace_root/scripts/standalone-swarm-readiness.sh" <<'EOF'
#!/usr/bin/env bash
echo "standalone-swarm=open"
EOF
cat >"$source_workspace_root/scripts/standalone-swarm-verify.sh" <<'EOF'
#!/usr/bin/env bash
echo "standalone-swarm-verifier=open"
EOF
cat >"$source_workspace_root/docs/standalone-swarm-readiness.md" <<'EOF'
standalone-swarm-status: open
EOF
cat >"$source_workspace_root/runtime/standalone_swarm_probe.rs" <<'EOF'
const STANDALONE_SWARM_STATUS: &str = "open";
EOF

cat >"$prompt_root/source-builder.prompt.md" <<'EOF'
You are the builder subagent.
Swarm context pack:
task: builder-2 status=ready ready=true attempts=1
artifact search matches:
- verifier feedback exists
Verifier feedback from the previous attempt:
force-close-category
Task file content:
Make the standalone swarm proof concrete. The swarm could run without Codex-specific control flow, but the local agent must edit existing Clasp source rather than only writing generated artifacts.
Source edit plan:
- src/StandaloneSwarmReadiness.clasp
- src/StandaloneSwarmVerifier.clasp
- examples/swarm-native/StandaloneSwarmHarness.clasp
- examples/swarm-native/StandaloneSwarmRouting.clasp
- scripts/standalone-swarm-readiness.sh
- scripts/standalone-swarm-verify.sh
- docs/standalone-swarm-readiness.md
- runtime/standalone_swarm_probe.rs
Source edit patches:
- src/StandaloneSwarmReadiness.clasp :: readinessStatus = "open" => readinessStatus = "standalone-swarm-fixed-after-feedback"
- src/StandaloneSwarmVerifier.clasp :: verifierStatus = "open" => verifierStatus = "standalone-swarm-fixed-after-feedback"
- examples/swarm-native/StandaloneSwarmHarness.clasp :: harnessStatus = "open" => harnessStatus = "standalone-swarm-fixed-after-feedback"
- examples/swarm-native/StandaloneSwarmRouting.clasp :: routingStatus = "open" => routingStatus = "standalone-swarm-fixed-after-feedback"
- scripts/standalone-swarm-readiness.sh :: echo "standalone-swarm=open" => echo "standalone-swarm=standalone-swarm-fixed-after-feedback"
- scripts/standalone-swarm-verify.sh :: echo "standalone-swarm-verifier=open" => echo "standalone-swarm-verifier=standalone-swarm-fixed-after-feedback"
- docs/standalone-swarm-readiness.md :: standalone-swarm-status: open => standalone-swarm-status: standalone-swarm-fixed-after-feedback
- runtime/standalone_swarm_probe.rs :: const STANDALONE_SWARM_STATUS: &str = "open"; => const STANDALONE_SWARM_STATUS: &str = "standalone-swarm-fixed-after-feedback";
EOF

cat >"$prompt_root/source-verifier.prompt.md" <<'EOF'
You are the verifier subagent.
Swarm context pack:
task: verifier-2 status=ready ready=true attempts=1
run trace:
- builder-2 completed
Task file content:
Verify the standalone swarm source edit from the ordinary Clasp local agent.
Source edit plan:
- src/StandaloneSwarmReadiness.clasp
- src/StandaloneSwarmVerifier.clasp
- examples/swarm-native/StandaloneSwarmHarness.clasp
- examples/swarm-native/StandaloneSwarmRouting.clasp
- scripts/standalone-swarm-readiness.sh
- scripts/standalone-swarm-verify.sh
- docs/standalone-swarm-readiness.md
- runtime/standalone_swarm_probe.rs
Source edit patches:
- src/StandaloneSwarmReadiness.clasp :: readinessStatus = "open" => readinessStatus = "standalone-swarm-fixed-after-feedback"
- src/StandaloneSwarmVerifier.clasp :: verifierStatus = "open" => verifierStatus = "standalone-swarm-fixed-after-feedback"
- examples/swarm-native/StandaloneSwarmHarness.clasp :: harnessStatus = "open" => harnessStatus = "standalone-swarm-fixed-after-feedback"
- examples/swarm-native/StandaloneSwarmRouting.clasp :: routingStatus = "open" => routingStatus = "standalone-swarm-fixed-after-feedback"
- scripts/standalone-swarm-readiness.sh :: echo "standalone-swarm=open" => echo "standalone-swarm=standalone-swarm-fixed-after-feedback"
- scripts/standalone-swarm-verify.sh :: echo "standalone-swarm-verifier=open" => echo "standalone-swarm-verifier=standalone-swarm-fixed-after-feedback"
- docs/standalone-swarm-readiness.md :: standalone-swarm-status: open => standalone-swarm-status: standalone-swarm-fixed-after-feedback
- runtime/standalone_swarm_probe.rs :: const STANDALONE_SWARM_STATUS: &str = "open"; => const STANDALONE_SWARM_STATUS: &str = "standalone-swarm-fixed-after-feedback";
EOF

timeout "$timeout_secs" "$local_agent_bin" \
  --role builder \
  --report "$source_builder_report" \
  --prompt-path "$prompt_root/source-builder.prompt.md" \
  --workspace "$source_workspace_root" >/dev/null

timeout "$timeout_secs" "$local_agent_bin" \
  --role verifier \
  --report "$source_verifier_report" \
  --prompt-path "$prompt_root/source-verifier.prompt.md" \
  --workspace "$source_workspace_root" >/dev/null

node - "$source_builder_report" "$source_verifier_report" "$source_workspace_root" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const [builderPath, verifierPath, workspaceRoot] = process.argv.slice(2);

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

const builder = readJson(builderPath);
const verifier = readJson(verifierPath);
const routeText = fs.readFileSync(path.join(workspaceRoot, "notes", "local-agent-route.txt"), "utf8");
const sourceText = fs.readFileSync(path.join(workspaceRoot, "src", "StandaloneSwarmReadiness.clasp"), "utf8");
const verifierSourceText = fs.readFileSync(path.join(workspaceRoot, "src", "StandaloneSwarmVerifier.clasp"), "utf8");
const harnessSourceText = fs.readFileSync(path.join(workspaceRoot, "examples", "swarm-native", "StandaloneSwarmHarness.clasp"), "utf8");
const routingSourceText = fs.readFileSync(path.join(workspaceRoot, "examples", "swarm-native", "StandaloneSwarmRouting.clasp"), "utf8");
const scriptText = fs.readFileSync(path.join(workspaceRoot, "scripts", "standalone-swarm-readiness.sh"), "utf8");
const verifyScriptText = fs.readFileSync(path.join(workspaceRoot, "scripts", "standalone-swarm-verify.sh"), "utf8");
const docText = fs.readFileSync(path.join(workspaceRoot, "docs", "standalone-swarm-readiness.md"), "utf8");
const runtimeText = fs.readFileSync(path.join(workspaceRoot, "runtime", "standalone_swarm_probe.rs"), "utf8");
const proofText = fs.readFileSync(path.join(workspaceRoot, "notes", "direct-source-edit.txt"), "utf8");
const manifestText = fs.readFileSync(path.join(workspaceRoot, "notes", "direct-source-edit-manifest.json"), "utf8");
const manifest = JSON.parse(manifestText);
const manifestFingerprint = textFingerprint64Hex(manifestText);

assert(routeText === "standalone-swarm\n", `route ${routeText}`);
assert(builder.files_touched?.includes("src/StandaloneSwarmReadiness.clasp"), "builder should report edited source");
assert(builder.files_touched?.includes("src/StandaloneSwarmVerifier.clasp"), "builder should report second edited source");
assert(builder.files_touched?.includes("examples/swarm-native/StandaloneSwarmHarness.clasp"), "builder should report harness source");
assert(builder.files_touched?.includes("examples/swarm-native/StandaloneSwarmRouting.clasp"), "builder should report routing source");
assert(builder.files_touched?.includes("scripts/standalone-swarm-readiness.sh"), "builder should report edited script source");
assert(builder.files_touched?.includes("scripts/standalone-swarm-verify.sh"), "builder should report verifier script source");
assert(builder.files_touched?.includes("docs/standalone-swarm-readiness.md"), "builder should report edited doc source");
assert(builder.files_touched?.includes("runtime/standalone_swarm_probe.rs"), "builder should report runtime source");
assert(builder.files_touched?.includes("notes/direct-source-edit.txt"), "builder should report edit proof");
assert(builder.files_touched?.includes("notes/direct-source-edit-manifest.json"), "builder should report edit manifest");
assert(builder.workspace_fingerprint_manifest === "notes/direct-source-edit-manifest.json", `builder manifest path ${builder.workspace_fingerprint_manifest}`);
assert(builder.workspace_fingerprint_manifest_fingerprint64_hex === manifestFingerprint, `builder manifest fingerprint ${builder.workspace_fingerprint_manifest_fingerprint64_hex}`);
assert(builder.tests_run?.includes("clasp-local-agent-source-edit-plan"), "builder should record source-edit plan coverage");
assert(builder.tests_run?.includes("clasp-local-agent-direct-source-edit"), "builder should record source-edit coverage");
assert(builder.tests_run?.includes("clasp-local-agent-multi-file-source-edit"), "builder should record multi-file source-edit coverage");
assert(builder.tests_run?.includes("clasp-local-agent-source-patch-plan"), "builder should record source-patch plan coverage");
assert(builder.tests_run?.includes("clasp-local-agent-targeted-source-patch"), "builder should record targeted source patch coverage");
assert(builder.tests_run?.includes("clasp-local-agent-repo-surface-source-patch"), "builder should record safe repo surface source patch coverage");
assert(builder.tests_run?.includes("clasp-local-agent-multi-surface-source-patch"), "builder should record multi-surface source patch coverage");
assert(builder.tests_run?.includes("clasp-local-agent-repo-scale-source-patch"), "builder should record repo-scale source patch coverage");
assert(builder.tests_run?.includes("clasp-local-agent-atomic-source-patch-preflight"), "builder should record atomic source patch preflight coverage");
assert(builder.tests_run?.includes("clasp-local-agent-source-patch-postcheck"), "builder should record source patch postcheck coverage");
assert(
  builder.feedback?.ergonomics?.includes("local builder edited an existing ordinary-Clasp source file"),
  "builder ergonomics should mention direct source edit",
);
assert(
  builder.feedback?.ergonomics?.includes("local builder edited multiple existing ordinary-Clasp source files"),
  "builder ergonomics should mention multi-file source edit",
);
assert(
  builder.feedback?.ergonomics?.includes("local builder applied targeted replacements inside existing source files"),
  "builder ergonomics should mention targeted source patches",
);
assert(
  builder.feedback?.ergonomics?.includes("local builder applied targeted replacements across safe repo source surfaces"),
  "builder ergonomics should mention multi-surface source patches",
);
assert(
  builder.feedback?.ergonomics?.includes("local builder preflighted all planned source patches before writing files"),
  "builder ergonomics should mention atomic source patch preflight",
);
assert(
  builder.feedback?.ergonomics?.includes("local builder postchecked patched source fingerprints before reporting success"),
  "builder ergonomics should mention source patch postcheck",
);
assert(
  builder.feedback?.ergonomics?.includes("local builder demonstrated repo-scale source patching across src, examples, scripts, docs, and runtime"),
  "builder ergonomics should mention repo-scale source patching",
);
assert(sourceText.includes("module StandaloneSwarmReadiness"), "source should preserve module");
assert(sourceText.includes('readinessStatus = "standalone-swarm-fixed-after-feedback"'), "source should apply readiness replacement");
assert(sourceText.includes("plannedSourceFile = \"src/StandaloneSwarmReadiness.clasp\""), "source should name planned file");
assert(sourceText.includes("plannedStatus = \"standalone-swarm-fixed-after-feedback\""), "source should contain fixed status");
assert(sourceText.includes("sourceEditEvidence = \"local-agent-plan-driven-source-edit\""), "source should contain edit evidence");
assert(sourceText.includes("patchEditMode = \"targeted-replace\""), "source should contain patch mode evidence");
assert(sourceText.includes("previousSourceSeen = \"yes\""), "source edit should prove it saw existing source");
assert(verifierSourceText.includes("module StandaloneSwarmVerifier"), "second source should preserve module");
assert(verifierSourceText.includes('verifierStatus = "standalone-swarm-fixed-after-feedback"'), "second source should apply verifier replacement");
assert(verifierSourceText.includes("plannedSourceFile = \"src/StandaloneSwarmVerifier.clasp\""), "second source should name planned file");
assert(verifierSourceText.includes("plannedStatus = \"standalone-swarm-fixed-after-feedback\""), "second source should contain fixed status");
assert(verifierSourceText.includes("sourceEditEvidence = \"local-agent-plan-driven-source-edit\""), "second source should contain edit evidence");
assert(verifierSourceText.includes("patchEditMode = \"targeted-replace\""), "second source should contain patch mode evidence");
assert(verifierSourceText.includes("previousSourceSeen = \"yes\""), "second source edit should prove it saw existing source");
assert(harnessSourceText.includes('harnessStatus = "standalone-swarm-fixed-after-feedback"'), "harness source should apply replacement");
assert(harnessSourceText.includes("plannedSourceFile = \"examples/swarm-native/StandaloneSwarmHarness.clasp\""), "harness source should name planned file");
assert(routingSourceText.includes('routingStatus = "standalone-swarm-fixed-after-feedback"'), "routing source should apply replacement");
assert(routingSourceText.includes("plannedSourceFile = \"examples/swarm-native/StandaloneSwarmRouting.clasp\""), "routing source should name planned file");
assert(scriptText.includes('echo "standalone-swarm=standalone-swarm-fixed-after-feedback"'), "script source should apply script replacement");
assert(!scriptText.includes("plannedSourceFile ="), "script source should not receive Clasp declarations");
assert(verifyScriptText.includes('echo "standalone-swarm-verifier=standalone-swarm-fixed-after-feedback"'), "verifier script source should apply script replacement");
assert(docText.includes("standalone-swarm-status: standalone-swarm-fixed-after-feedback"), "doc source should apply doc replacement");
assert(!docText.includes("plannedSourceFile ="), "doc source should not receive Clasp declarations");
assert(runtimeText.includes('const STANDALONE_SWARM_STATUS: &str = "standalone-swarm-fixed-after-feedback";'), "runtime source should apply rust replacement");
assert(proofText.includes("kind=clasp-local-agent-direct-source-edit"), "source edit proof should name kind");
assert(proofText.includes("route=standalone-swarm"), "source edit proof should name route");
assert(proofText.includes("planDriven=true"), "source edit proof should name plan-driven edit");
assert(proofText.includes("multiFile=true"), "source edit proof should name multi-file edit");
assert(proofText.includes("multiSurface=true"), "source edit proof should name multi-surface edit");
assert(proofText.includes("repoScale=true"), "source edit proof should name repo-scale edit");
assert(proofText.includes("repoScaleRequiredRoots=src,examples,scripts,docs,runtime"), "source edit proof should name repo-scale roots");
assert(proofText.includes("patchDriven=true"), "source edit proof should name patch-driven edit");
assert(proofText.includes("atomicPreflight=true"), "source edit proof should name atomic preflight");
assert(proofText.includes("postWriteFingerprintCheck=true"), "source edit proof should name post-write fingerprint check");
assert(proofText.includes("workspaceFingerprintManifest=notes/direct-source-edit-manifest.json"), "source edit proof should name workspace manifest");
assert(proofText.includes("workspaceFingerprintAlgorithm=textFingerprint64Hex"), "source edit proof should name workspace manifest algorithm");
assert(proofText.includes("workspaceConfinedWrite=true"), "source edit proof should name root-confined workspace writes");
assert(proofText.includes("workspaceApi=workspaceReadFile/workspaceReplaceText/workspaceWriteFile/workspaceMkdirAll"), "source edit proof should name workspace filesystem API");
assert(proofText.includes("sourceEditPrimitive=workspaceReplaceText"), "source edit proof should name exact replacement primitive");
assert(proofText.includes("operation=targeted-replace"), "source edit proof should name source patch operation");
assert(proofText.includes("targetCount=8"), "source edit proof should name target count");
assert(proofText.includes("patchCount=8"), "source edit proof should name patch count");
assert(proofText.includes("sourceFile=src/StandaloneSwarmReadiness.clasp"), "source edit proof should name source file");
assert(proofText.includes("sourceFile=src/StandaloneSwarmVerifier.clasp"), "source edit proof should name second source file");
assert(proofText.includes("sourceFile=examples/swarm-native/StandaloneSwarmHarness.clasp"), "source edit proof should name harness source file");
assert(proofText.includes("sourceFile=examples/swarm-native/StandaloneSwarmRouting.clasp"), "source edit proof should name routing source file");
assert(proofText.includes("sourceFile=scripts/standalone-swarm-readiness.sh"), "source edit proof should name script source file");
assert(proofText.includes("sourceFile=scripts/standalone-swarm-verify.sh"), "source edit proof should name verifier script source file");
assert(proofText.includes("sourceFile=docs/standalone-swarm-readiness.md"), "source edit proof should name doc source file");
assert(proofText.includes("sourceFile=runtime/standalone_swarm_probe.rs"), "source edit proof should name runtime source file");
assert(proofText.includes("sourcePreviousSeen=scripts/standalone-swarm-readiness.sh"), "source edit proof should prove script source existed");
assert(proofText.includes("sourcePreviousSeen=docs/standalone-swarm-readiness.md"), "source edit proof should prove doc source existed");
assert(proofText.includes("targetPatchMode=scripts/standalone-swarm-readiness.sh:targeted-replace"), "source edit proof should prove script patch mode");
assert(proofText.includes("targetPatchMode=docs/standalone-swarm-readiness.md:targeted-replace"), "source edit proof should prove doc patch mode");
assert(proofText.includes("targetPostcheck=src/StandaloneSwarmReadiness.clasp:present"), "source edit proof should postcheck first source");
assert(proofText.includes("targetPostcheck=src/StandaloneSwarmVerifier.clasp:present"), "source edit proof should postcheck second source");
assert(proofText.includes("targetPostcheck=examples/swarm-native/StandaloneSwarmHarness.clasp:present"), "source edit proof should postcheck harness source");
assert(proofText.includes("targetPostcheck=examples/swarm-native/StandaloneSwarmRouting.clasp:present"), "source edit proof should postcheck routing source");
assert(proofText.includes("targetPostcheck=scripts/standalone-swarm-readiness.sh:present"), "source edit proof should postcheck script source");
assert(proofText.includes("targetPostcheck=scripts/standalone-swarm-verify.sh:present"), "source edit proof should postcheck verifier script source");
assert(proofText.includes("targetPostcheck=docs/standalone-swarm-readiness.md:present"), "source edit proof should postcheck doc source");
assert(proofText.includes("targetPostcheck=runtime/standalone_swarm_probe.rs:present"), "source edit proof should postcheck runtime source");
assert(proofText.includes("targetResultFingerprint=src/StandaloneSwarmReadiness.clasp:"), "source edit proof should fingerprint first result");
assert(proofText.includes("targetResultFingerprint=src/StandaloneSwarmVerifier.clasp:"), "source edit proof should fingerprint second result");
assert(proofText.includes("targetResultFingerprint=scripts/standalone-swarm-readiness.sh:"), "source edit proof should fingerprint script result");
assert(proofText.includes("targetResultFingerprint=docs/standalone-swarm-readiness.md:"), "source edit proof should fingerprint doc result");
assert(proofText.includes("patchFile=src/StandaloneSwarmReadiness.clasp"), "source edit proof should name patch file");
assert(proofText.includes("patchFile=src/StandaloneSwarmVerifier.clasp"), "source edit proof should name second patch file");
assert(proofText.includes("patchFile=examples/swarm-native/StandaloneSwarmHarness.clasp"), "source edit proof should name harness patch file");
assert(proofText.includes("patchFile=examples/swarm-native/StandaloneSwarmRouting.clasp"), "source edit proof should name routing patch file");
assert(proofText.includes("patchFile=scripts/standalone-swarm-readiness.sh"), "source edit proof should name script patch file");
assert(proofText.includes("patchFile=scripts/standalone-swarm-verify.sh"), "source edit proof should name verifier script patch file");
assert(proofText.includes("patchFile=docs/standalone-swarm-readiness.md"), "source edit proof should name doc patch file");
assert(proofText.includes("patchFile=runtime/standalone_swarm_probe.rs"), "source edit proof should name runtime patch file");
assert(proofText.includes("patchFindFingerprint="), "source edit proof should fingerprint find text");
assert(proofText.includes("patchReplacementFingerprint="), "source edit proof should fingerprint replacement text");
assert(manifest.kind === "standalone-swarm-direct-source-edit-manifest", `manifest kind ${manifest.kind}`);
assert(manifest.fingerprintAlgorithm === "textFingerprint64Hex", `manifest algorithm ${manifest.fingerprintAlgorithm}`);
assert(manifest.requiredSurfaceCount === 8, `manifest surface count ${manifest.requiredSurfaceCount}`);
assert(manifest.files?.some((entry) => entry.path === "src/StandaloneSwarmReadiness.clasp"), "manifest should include readiness source");
assert(verifier.verdict === "pass", `verifier verdict ${verifier.verdict}`);
assert(verifier.workspace_fingerprint_manifest === "notes/direct-source-edit-manifest.json", `verifier manifest path ${verifier.workspace_fingerprint_manifest}`);
assert(verifier.workspace_fingerprint_manifest_fingerprint64_hex === manifestFingerprint, `verifier manifest fingerprint ${verifier.workspace_fingerprint_manifest_fingerprint64_hex}`);
assert(verifier.tests_run?.includes("clasp-local-agent-source-edit-plan"), "verifier should record source-edit plan coverage");
assert(verifier.tests_run?.includes("clasp-local-agent-direct-source-edit"), "verifier should record source-edit coverage");
assert(verifier.tests_run?.includes("clasp-local-agent-multi-file-source-edit"), "verifier should record multi-file source-edit coverage");
assert(verifier.tests_run?.includes("clasp-local-agent-source-patch-plan"), "verifier should record source-patch plan coverage");
assert(verifier.tests_run?.includes("clasp-local-agent-targeted-source-patch"), "verifier should record targeted source patch coverage");
assert(verifier.tests_run?.includes("clasp-local-agent-repo-surface-source-patch"), "verifier should record safe repo surface source patch coverage");
assert(verifier.tests_run?.includes("clasp-local-agent-multi-surface-source-patch"), "verifier should record multi-surface source patch coverage");
assert(verifier.tests_run?.includes("clasp-local-agent-repo-scale-source-patch"), "verifier should record repo-scale source patch coverage");
assert(verifier.tests_run?.includes("clasp-local-agent-atomic-source-patch-preflight"), "verifier should record atomic source patch preflight coverage");
assert(verifier.tests_run?.includes("clasp-local-agent-source-patch-postcheck"), "verifier should record source patch postcheck coverage");
assert(verifier.tests_run?.includes("clasp-local-agent-verifier-gate"), "verifier should record typed gate coverage");
assert(
  verifier.capability_statuses?.some((entry) =>
    entry.evidence?.includes("local Clasp agent edited an existing ordinary-Clasp source file")
  ),
  "verifier should prove direct source edit",
);
assert(
  verifier.capability_statuses?.some((entry) =>
    entry.evidence?.includes("local Clasp agent consumed a prompt source-edit plan")
  ),
  "verifier should prove source edit plan consumption",
);
assert(
  verifier.capability_statuses?.some((entry) =>
    entry.evidence?.includes("local Clasp agent consumed a prompt source-patch plan")
  ),
  "verifier should prove source patch plan consumption",
);
assert(
  verifier.capability_statuses?.some((entry) =>
    entry.evidence?.includes("local Clasp agent edited multiple existing ordinary-Clasp source files")
  ),
  "verifier should prove multi-file source edit",
);
assert(
  verifier.capability_statuses?.some((entry) =>
    entry.evidence?.includes("local Clasp agent applied targeted replacements inside existing source files")
  ),
  "verifier should prove targeted source patching",
);
assert(
  verifier.capability_statuses?.some((entry) =>
    entry.evidence?.includes("local Clasp agent applied targeted replacements across safe repo source surfaces")
  ),
  "verifier should prove multi-surface source patching",
);
assert(
  verifier.capability_statuses?.some((entry) =>
    entry.evidence?.includes("local Clasp agent preflighted all planned source patches before writing files")
  ),
  "verifier should prove atomic source patch preflight",
);
assert(
  verifier.capability_statuses?.some((entry) =>
    entry.evidence?.includes("local Clasp agent postchecked patched source fingerprints before reporting success")
  ),
  "verifier should prove source patch postcheck",
);
assert(
  verifier.capability_statuses?.some((entry) =>
    entry.evidence?.includes("local Clasp agent demonstrated repo-scale source patching across src, examples, scripts, docs, and runtime")
  ),
  "verifier should prove repo-scale source patching",
);
assert(
  verifier.capability_statuses?.some((entry) =>
    entry.name === "local_verifier_gate" &&
    entry.status === "pass" &&
    entry.evidence?.includes("local verifier emitted typed gate evidence") &&
    entry.evidence?.includes("local-verifier-gate-recommendation:verifier-gate:pass")
  ),
  "verifier should emit typed pass gate evidence for source-edit closure",
);
NODE

node - "$source_workspace_root" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const workspaceRoot = process.argv[2];
const docPath = path.join(workspaceRoot, "docs", "standalone-swarm-readiness.md");
const doc = fs.readFileSync(docPath, "utf8");
fs.writeFileSync(docPath, `${doc}\npostcheck-drift=true\n`);
NODE

timeout "$timeout_secs" "$local_agent_bin" \
  --role verifier \
  --report "$source_drift_verifier_report" \
  --prompt-path "$prompt_root/source-verifier.prompt.md" \
  --workspace "$source_workspace_root" >/dev/null

node - "$source_drift_verifier_report" <<'NODE'
const fs = require("node:fs");
const reportPath = process.argv[2];
const verifier = JSON.parse(fs.readFileSync(reportPath, "utf8"));
function assert(condition, message) {
  if (!condition) throw new Error(message);
}
if (verifier.verdict !== "fail") {
  throw new Error(`verifier should reject post-write source drift, got ${verifier.verdict}`);
}
assert(
  verifier.findings?.includes("standalone-swarm direct source edit proof missing or invalid"),
  "verifier should report source-edit proof failure for post-write drift",
);
assert(
  verifier.findings?.includes("Check notes/direct-source-edit.txt and notes/direct-source-edit-manifest.json"),
  "verifier should point at source-edit proof and manifest artifacts",
);
assert(
  verifier.findings?.includes("standalone-source-edit:target-postcheck-or-proof-missing"),
  "verifier should report target postcheck failure for post-write drift",
);
assert(
  verifier.findings?.includes("standalone-source-edit:manifest-target-fingerprints-missing"),
  "verifier should report manifest drift for post-write drift",
);
assert(
  verifier.findings?.includes("standalone-source-edit-repair:rerun-target-postchecks-and-proof-lines"),
  "verifier should suggest postcheck repair for post-write drift",
);
assert(
  verifier.findings?.includes("standalone-source-edit-repair:regenerate-direct-source-edit-manifest"),
  "verifier should suggest manifest regeneration for post-write drift",
);
assert(verifier.tests_run?.includes("clasp-local-agent-verifier-gate"), "verifier should record typed gate coverage");
assert(
  verifier.capability_statuses?.some((entry) =>
    entry.name === "local_verifier_gate" &&
    entry.status === "fail" &&
    entry.required_closure?.includes("verifier-gate:fix-failed-checks")
  ),
  "verifier should emit typed fail gate evidence",
);
NODE

node - "$source_workspace_root" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const workspaceRoot = process.argv[2];
const docPath = path.join(workspaceRoot, "docs", "standalone-swarm-readiness.md");
const doc = fs.readFileSync(docPath, "utf8");
fs.writeFileSync(docPath, doc.replace("\npostcheck-drift=true\n", ""));
NODE

node - "$source_workspace_root" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const workspaceRoot = process.argv[2];
const readinessPath = path.join(workspaceRoot, "src", "StandaloneSwarmReadiness.clasp");
const source = fs.readFileSync(readinessPath, "utf8");
fs.writeFileSync(
  readinessPath,
  source.replace('readinessStatus = "standalone-swarm-fixed-after-feedback"', 'readinessStatus = "open"'),
);
NODE

timeout "$timeout_secs" "$local_agent_bin" \
  --role verifier \
  --report "$source_negative_verifier_report" \
  --prompt-path "$prompt_root/source-verifier.prompt.md" \
  --workspace "$source_workspace_root" >/dev/null

node - "$source_negative_verifier_report" <<'NODE'
const fs = require("node:fs");
const reportPath = process.argv[2];
const verifier = JSON.parse(fs.readFileSync(reportPath, "utf8"));
function assert(condition, message) {
  if (!condition) throw new Error(message);
}
if (verifier.verdict !== "fail") {
  throw new Error(`verifier should reject missing planned patch replacement, got ${verifier.verdict}`);
}
assert(
  verifier.findings?.includes("standalone-swarm direct source edit proof missing or invalid"),
  "verifier should report source-edit proof failure for missing patch replacement",
);
assert(
  verifier.findings?.includes("standalone-source-edit:planned-patch-replacement-missing"),
  "verifier should report missing planned patch replacement",
);
assert(
  verifier.findings?.includes("standalone-source-edit:manifest-target-fingerprints-missing"),
  "verifier should report manifest mismatch after missing patch replacement",
);
assert(
  verifier.findings?.includes("standalone-source-edit-repair:apply-planned-patch-replacements"),
  "verifier should suggest reapplying planned patch replacements",
);
assert(
  verifier.findings?.includes("standalone-source-edit-repair:regenerate-direct-source-edit-manifest"),
  "verifier should suggest manifest regeneration after missing patch replacement",
);
assert(verifier.tests_run?.includes("clasp-local-agent-verifier-gate"), "verifier should record typed gate coverage");
assert(
  verifier.capability_statuses?.some((entry) =>
    entry.name === "local_verifier_gate" &&
    entry.status === "fail" &&
    entry.required_closure?.includes("verifier-gate:fix-failed-checks")
  ),
  "verifier should emit typed fail gate evidence for missing patch",
);
NODE

mkdir -p "$source_transaction_workspace_root/src" "$source_transaction_workspace_root/docs"
cat >"$source_transaction_workspace_root/src/StandaloneSwarmReadiness.clasp" <<'EOF'
module StandaloneSwarmReadiness

readinessStatus : Str
readinessStatus = "open"
EOF
cat >"$source_transaction_workspace_root/docs/standalone-swarm-readiness.md" <<'EOF'
standalone-swarm-status: open
EOF

cat >"$prompt_root/source-transaction-builder.prompt.md" <<'EOF'
You are the builder subagent.
Swarm context pack:
task: builder-3 status=ready ready=true attempts=1
artifact search matches:
- verifier feedback exists
Verifier feedback from the previous attempt:
force-close-category
Task file content:
Prove source patch execution is atomic: if any planned target does not match, no source file should be rewritten.
Source edit plan:
- src/StandaloneSwarmReadiness.clasp
- docs/standalone-swarm-readiness.md
Source edit patches:
- src/StandaloneSwarmReadiness.clasp :: readinessStatus = "open" => readinessStatus = "standalone-swarm-fixed-after-feedback"
- docs/standalone-swarm-readiness.md :: missing-status: open => standalone-swarm-status: standalone-swarm-fixed-after-feedback
EOF

timeout "$timeout_secs" "$local_agent_bin" \
  --role builder \
  --report "$source_transaction_builder_report" \
  --prompt-path "$prompt_root/source-transaction-builder.prompt.md" \
  --workspace "$source_transaction_workspace_root" >"$source_transaction_builder_output"

node - "$source_transaction_workspace_root" "$source_transaction_builder_report" "$source_transaction_builder_output" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const [workspaceRoot, reportPath, outputPath] = process.argv.slice(2);

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const sourceText = fs.readFileSync(path.join(workspaceRoot, "src", "StandaloneSwarmReadiness.clasp"), "utf8");
const docText = fs.readFileSync(path.join(workspaceRoot, "docs", "standalone-swarm-readiness.md"), "utf8");
const outputText = fs.readFileSync(outputPath, "utf8");
const proofPath = path.join(workspaceRoot, "notes", "direct-source-edit.txt");

assert(outputText.includes("local-agent-error:source patch preflight failed:docs/standalone-swarm-readiness.md"), "builder should report the failed preflight target");
assert(sourceText.includes('readinessStatus = "open"'), "preflight failure should not rewrite the first matching source");
assert(!sourceText.includes("standalone-swarm-fixed-after-feedback"), "preflight failure should not partially apply source replacement");
assert(docText.includes("standalone-swarm-status: open"), "preflight failure should preserve mismatched doc source");
assert(!fs.existsSync(proofPath), "preflight failure should not write direct source edit proof");
assert(!fs.existsSync(reportPath), "preflight failure should not write a success builder report");
NODE

printf 'local-agent-capability-closure-ok\n'
