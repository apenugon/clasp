#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
test_root="$(mktemp -d "$tmp_root/standalone-swarm-surfaces.XXXXXX")"

cleanup() {
  rm -rf "$test_root"
}

trap cleanup EXIT

require_pattern() {
  local path="$1"
  local pattern="$2"
  if ! grep -F -- "$pattern" "$project_root/$path" >/dev/null; then
    printf 'missing standalone swarm surface pattern in %s: %s\n' "$path" "$pattern" >&2
    exit 1
  fi
}

readiness_output="$(bash "$project_root/scripts/standalone-swarm-readiness.sh")"
verify_output="$(bash "$project_root/scripts/standalone-swarm-verify.sh")"
verify_json_output="$(bash "$project_root/scripts/standalone-swarm-verify.sh" --json)"

case "$readiness_output" in
  *"standalone-swarm=open"* )
    ;;
  *)
    printf 'unexpected standalone readiness output: %s\n' "$readiness_output" >&2
    exit 1
    ;;
esac

node -e '
const report = JSON.parse(process.argv[1]);
if (report.kind !== "standalone-swarm-verifier-report") throw new Error(`unexpected kind: ${JSON.stringify(report)}`);
if (report.mode !== "open") throw new Error(`unexpected open mode: ${JSON.stringify(report)}`);
if (report.status !== "open") throw new Error(`unexpected open status: ${JSON.stringify(report)}`);
if (report.requiredSurfaceCount !== 8) throw new Error(`unexpected surface count: ${JSON.stringify(report)}`);
if (report.builderReport !== "" || report.verifierReport !== "" || report.proofPath !== "") throw new Error(`open report paths should be empty strings: ${JSON.stringify(report)}`);
if (report.workspaceFingerprintManifest !== "" || report.workspaceFingerprintManifestSha256 !== "") throw new Error(`open report fingerprint fields should be empty strings: ${JSON.stringify(report)}`);
' "$verify_json_output"

case "$verify_output" in
  *"standalone-swarm-verifier=open"* )
    ;;
  *)
    printf 'unexpected standalone verifier output: %s\n' "$verify_output" >&2
    exit 1
    ;;
esac

require_pattern "src/StandaloneSwarmReadiness.clasp" 'readinessStatus = "open"'
require_pattern "src/StandaloneSwarmReadiness.clasp" 'standalone-swarm-fixed-after-feedback'
require_pattern "src/StandaloneSwarmVerifier.clasp" 'verifierStatus = "open"'
require_pattern "src/StandaloneSwarmVerifier.clasp" 'local_verifier_gate'
require_pattern "examples/swarm-native/StandaloneSwarmRouting.clasp" 'standaloneSwarmRouteForEvidence'
require_pattern "examples/swarm-native/StandaloneSwarmRouting.clasp" 'backendConfigRepair=agent-backend'
require_pattern "examples/swarm-native/StandaloneSwarmRouting.clasp" 'plannerBackendConfigRepair=agent-backend'
require_pattern "examples/swarm-native/StandaloneSwarmHarness.clasp" 'standaloneSwarmHarness=canonical-source-edit-surface'
require_pattern "examples/swarm-native/LocalAgent.clasp" 'localVerifierFindingsFor : Str -> Str -> Str -> Str -> [Str]'
require_pattern "examples/swarm-native/LocalAgent.clasp" 'standalone-swarm direct source edit proof missing or invalid'
require_pattern "examples/swarm-native/LocalSourceEdit.clasp" 'standaloneSwarmDirectSourceEditIssueTexts : Str -> Str -> Str -> [Str]'
require_pattern "examples/swarm-native/LocalSourceEdit.clasp" 'standaloneSwarmDirectSourceEditRepairHints : Str -> Str -> Str -> [Str]'
require_pattern "examples/swarm-native/LocalSourceEdit.clasp" 'standalone-source-edit:manifest-target-fingerprints-missing'
require_pattern "examples/swarm-native/LocalSourceEdit.clasp" 'standalone-source-edit-repair:regenerate-direct-source-edit-manifest'
require_pattern "examples/swarm-native/StandaloneSwarmClosureReport.clasp" 'record StandaloneSwarmVerifierReport ='
require_pattern "examples/swarm-native/StandaloneSwarmClosureReport.clasp" 'standaloneSwarmVerifierReportFromRaw : Str -> Result StandaloneSwarmVerifierReport'
require_pattern "examples/swarm-native/StandaloneSwarmClosureReport.clasp" 'standaloneSwarmClosureReportJsonFromPrompt : Str -> Str'
require_pattern "examples/swarm-native/StandaloneSwarmClosureReport.clasp" 'standaloneSwarmClosureReportJsonPathFromPrompt : Str -> Str'
require_pattern "examples/swarm-native/StandaloneSwarmClosureReport.clasp" 'standaloneSwarmBoundedClosureReportJsonFromPath : Str -> Str'
require_pattern "examples/swarm-native/StandaloneSwarmClosureReport.clasp" 'standaloneSwarmClosureDecisionFromJson : Str -> StandaloneSwarmClosureDecision'
require_pattern "examples/swarm-native/StandaloneSwarmClosureReport.clasp" 'standaloneSwarmClosureDecisionFromPath : Str -> StandaloneSwarmClosureDecision'
require_pattern "examples/swarm-native/StandaloneSwarmClosureReport.clasp" 'standaloneSwarmClosureDecisionFromPromptOrRaw : Str -> StandaloneSwarmClosureDecision'
require_pattern "examples/swarm-native/StandaloneSwarmClosureReport.clasp" 'standaloneSwarmClosureDecisionFromRaw : Str -> StandaloneSwarmClosureDecision'
require_pattern "examples/swarm-native/StandaloneSwarmClosureReport.clasp" 'workspaceFingerprintManifest : Str'
require_pattern "examples/swarm-native/StandaloneSwarmClosureReport.clasp" 'workspace-fingerprint-manifest'
require_pattern "examples/swarm-native/StandaloneSwarmClosureReport.clasp" 'standaloneSwarmClosureRepairKindForDecision : StandaloneSwarmClosureDecision -> Str'
require_pattern "examples/swarm-native/StandaloneSwarmClosureReport.clasp" 'repair-workspace-fingerprint-manifest'
require_pattern "examples/swarm-native/StandaloneSwarmClosureReport.clasp" 'standaloneSwarmClosureRepairPromptForDecision : StandaloneSwarmClosureDecision -> Str'
require_pattern "examples/swarm-native/StandaloneSwarmClosureReportHarness.clasp" 'validClosureReportJson'
require_pattern "examples/swarm-native/StandaloneSwarmClosureReportHarness.clasp" 'manifestMissingClosureReportJson'
require_pattern "examples/swarm-native/StandaloneSwarmClosureReportHarness.clasp" 'standalone-swarm-closure-repair-kind='
require_pattern "examples/swarm-native/StandaloneSwarmClosureReportHarness.clasp" 'standaloneSwarmClosureDecisionSummary'
require_pattern "examples/swarm-native/LocalRouting.clasp" 'localRouteHasStandaloneSwarmClosureHandoff : Str -> Bool'
require_pattern "examples/swarm-native/LocalPlanner.clasp" 'standaloneSwarmTaskForPrompt : Str -> PlannedTask'
require_pattern "examples/swarm-native/LocalPlanner.clasp" 'standaloneSwarmTaskForClosureReportJson : Str -> PlannedTask'
require_pattern "examples/swarm-native/LocalPlanner.clasp" 'standaloneSwarmTaskForClosureReportPath : Str -> PlannedTask'
require_pattern "examples/swarm-native/LocalPlanner.clasp" 'standaloneSwarmClosureTaskFromDecision : StandaloneSwarmClosureDecision -> PlannedTask'
require_pattern "examples/swarm-native/LocalPlanner.clasp" 'swarm-manifest-repair-worker'
require_pattern "examples/swarm-native/LocalPlanner.clasp" 'standaloneSwarmClosureRepairPromptForDecision decision'
require_pattern "examples/swarm-native/LocalPlanner.clasp" 'standaloneSwarmSourceEditRepairKindForPrompt : Str -> Str'
require_pattern "examples/swarm-native/LocalPlanner.clasp" 'standaloneSwarmSourceEditRepairTaskForPrompt : Str -> PlannedTask'
require_pattern "examples/swarm-native/LocalPlanner.clasp" 'swarm-source-patch-repair-worker'
require_pattern "examples/swarm-native/LocalPlanner.clasp" 'standaloneSwarmPromptHasSourceEditRepairHint prompt'
require_pattern "examples/swarm-native/LocalPlanner.clasp" 'else if standaloneSwarmPromptHasSourceEditRepairHint prompt then'
require_pattern "docs/standalone-swarm-readiness.md" 'standalone-swarm-status: open'
require_pattern "docs/standalone-swarm-readiness.md" 'local verifier findings distinguish stale workspace content'
require_pattern "docs/standalone-swarm-readiness.md" 'standalone source-edit findings include concrete issue text'
require_pattern "docs/standalone-swarm-readiness.md" 'planner retries consume standalone source-edit repair hints'
require_pattern "docs/standalone-swarm-readiness.md" 'memory-concurrency-admission'
require_pattern "runtime/standalone_swarm_probe.rs" 'pub const STANDALONE_SWARM_STATUS: &str = "open";'
require_pattern "scripts/standalone-swarm-verify.sh" '--closure'
require_pattern "scripts/standalone-swarm-verify.sh" '--json'
require_pattern "scripts/standalone-swarm-verify.sh" 'standalone-swarm-verifier-report'
require_pattern "scripts/standalone-swarm-verify.sh" 'standalone-swarm-verifier=closed'
require_pattern "scripts/standalone-swarm-verify.sh" 'clasp-local-agent-direct-source-edit'
require_pattern "scripts/standalone-swarm-verify.sh" 'clasp-local-agent-source-patch-postcheck'
require_pattern "scripts/standalone-swarm-verify.sh" 'workspaceFingerprintManifest=notes/direct-source-edit-manifest.json'
require_pattern "scripts/standalone-swarm-verify.sh" 'workspace-manifest-fingerprint-mismatch'

workspace_root="$test_root/workspace"
mkdir -p "$workspace_root/src" "$workspace_root/examples/swarm-native" "$workspace_root/scripts" "$workspace_root/docs" "$workspace_root/runtime" "$workspace_root/notes"

cat >"$workspace_root/src/StandaloneSwarmReadiness.clasp" <<'EOF'
module StandaloneSwarmReadiness

readinessStatus : Str
readinessStatus = "standalone-swarm-fixed-after-feedback"
EOF
cat >"$workspace_root/src/StandaloneSwarmVerifier.clasp" <<'EOF'
module StandaloneSwarmVerifier

verifierStatus : Str
verifierStatus = "standalone-swarm-fixed-after-feedback"
EOF
cat >"$workspace_root/examples/swarm-native/StandaloneSwarmHarness.clasp" <<'EOF'
module StandaloneSwarmHarness

harnessStatus : Str
harnessStatus = "standalone-swarm-fixed-after-feedback"
EOF
cat >"$workspace_root/examples/swarm-native/StandaloneSwarmRouting.clasp" <<'EOF'
module StandaloneSwarmRouting

routingStatus : Str
routingStatus = "standalone-swarm-fixed-after-feedback"
EOF
cat >"$workspace_root/scripts/standalone-swarm-readiness.sh" <<'EOF'
#!/usr/bin/env bash
echo "standalone-swarm=standalone-swarm-fixed-after-feedback"
EOF
cat >"$workspace_root/scripts/standalone-swarm-verify.sh" <<'EOF'
#!/usr/bin/env bash
echo "standalone-swarm-verifier=standalone-swarm-fixed-after-feedback"
EOF
cat >"$workspace_root/docs/standalone-swarm-readiness.md" <<'EOF'
standalone-swarm-status: standalone-swarm-fixed-after-feedback
EOF
cat >"$workspace_root/runtime/standalone_swarm_probe.rs" <<'EOF'
pub const STANDALONE_SWARM_STATUS: &str = "standalone-swarm-fixed-after-feedback";
EOF

cat >"$workspace_root/notes/direct-source-edit.txt" <<'EOF'
kind=clasp-local-agent-direct-source-edit
route=standalone-swarm
planDriven=true
multiFile=true
multiSurface=true
repoScale=true
repoScaleRequiredRoots=src,examples,scripts,docs,runtime
atomicPreflight=true
postWriteFingerprintCheck=true
workspaceFingerprintManifest=notes/direct-source-edit-manifest.json
workspaceFingerprintAlgorithm=textFingerprint64Hex
workspaceConfinedWrite=true
sourceEditPrimitive=workspaceReplaceText
operation=targeted-replace
targetCount=8
patchCount=8
sourceFile=src/StandaloneSwarmReadiness.clasp
sourcePreviousSeen=src/StandaloneSwarmReadiness.clasp
targetPatchMode=src/StandaloneSwarmReadiness.clasp:targeted-replace
targetPostcheck=src/StandaloneSwarmReadiness.clasp:present
sourceFile=src/StandaloneSwarmVerifier.clasp
sourcePreviousSeen=src/StandaloneSwarmVerifier.clasp
targetPatchMode=src/StandaloneSwarmVerifier.clasp:targeted-replace
targetPostcheck=src/StandaloneSwarmVerifier.clasp:present
sourceFile=examples/swarm-native/StandaloneSwarmHarness.clasp
sourcePreviousSeen=examples/swarm-native/StandaloneSwarmHarness.clasp
targetPatchMode=examples/swarm-native/StandaloneSwarmHarness.clasp:targeted-replace
targetPostcheck=examples/swarm-native/StandaloneSwarmHarness.clasp:present
sourceFile=examples/swarm-native/StandaloneSwarmRouting.clasp
sourcePreviousSeen=examples/swarm-native/StandaloneSwarmRouting.clasp
targetPatchMode=examples/swarm-native/StandaloneSwarmRouting.clasp:targeted-replace
targetPostcheck=examples/swarm-native/StandaloneSwarmRouting.clasp:present
sourceFile=scripts/standalone-swarm-readiness.sh
sourcePreviousSeen=scripts/standalone-swarm-readiness.sh
targetPatchMode=scripts/standalone-swarm-readiness.sh:targeted-replace
targetPostcheck=scripts/standalone-swarm-readiness.sh:present
sourceFile=scripts/standalone-swarm-verify.sh
sourcePreviousSeen=scripts/standalone-swarm-verify.sh
targetPatchMode=scripts/standalone-swarm-verify.sh:targeted-replace
targetPostcheck=scripts/standalone-swarm-verify.sh:present
sourceFile=docs/standalone-swarm-readiness.md
sourcePreviousSeen=docs/standalone-swarm-readiness.md
targetPatchMode=docs/standalone-swarm-readiness.md:targeted-replace
targetPostcheck=docs/standalone-swarm-readiness.md:present
sourceFile=runtime/standalone_swarm_probe.rs
sourcePreviousSeen=runtime/standalone_swarm_probe.rs
targetPatchMode=runtime/standalone_swarm_probe.rs:targeted-replace
targetPostcheck=runtime/standalone_swarm_probe.rs:present
EOF

manifest_rel="notes/direct-source-edit-manifest.json"
manifest_path="$workspace_root/$manifest_rel"
node - "$workspace_root" "$manifest_path" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const [workspaceRoot, manifestPath] = process.argv.slice(2);
const targets = [
  "src/StandaloneSwarmReadiness.clasp",
  "src/StandaloneSwarmVerifier.clasp",
  "examples/swarm-native/StandaloneSwarmHarness.clasp",
  "examples/swarm-native/StandaloneSwarmRouting.clasp",
  "scripts/standalone-swarm-readiness.sh",
  "scripts/standalone-swarm-verify.sh",
  "docs/standalone-swarm-readiness.md",
  "runtime/standalone_swarm_probe.rs",
];

function textFingerprint64Hex(value) {
  let hash = 0xcbf29ce484222325n;
  for (const byte of Buffer.from(value, "utf8")) {
    hash ^= BigInt(byte);
    hash = (hash * 0x100000001b3n) & 0xffffffffffffffffn;
  }
  return hash.toString(16).padStart(16, "0");
}

const report = {
  schemaVersion: 1,
  kind: "standalone-swarm-direct-source-edit-manifest",
  fingerprintAlgorithm: "textFingerprint64Hex",
  requiredSurfaceCount: targets.length,
  files: targets.map((target) => ({
    path: target,
    fingerprint64Hex: textFingerprint64Hex(fs.readFileSync(path.join(workspaceRoot, target), "utf8")),
  })),
};
fs.writeFileSync(manifestPath, `${JSON.stringify(report)}\n`);
NODE

manifest_fingerprint64="$(
  node - "$manifest_path" <<'NODE'
const fs = require("node:fs");
function textFingerprint64Hex(value) {
  let hash = 0xcbf29ce484222325n;
  for (const byte of Buffer.from(value, "utf8")) {
    hash ^= BigInt(byte);
    hash = (hash * 0x100000001b3n) & 0xffffffffffffffffn;
  }
  return hash.toString(16).padStart(16, "0");
}
process.stdout.write(textFingerprint64Hex(fs.readFileSync(process.argv[2], "utf8")));
NODE
)"

builder_report="$test_root/builder-report.json"
verifier_report="$test_root/verifier-report.json"
cat >"$builder_report" <<'EOF'
{
  "workspace_fingerprint_manifest": "notes/direct-source-edit-manifest.json",
  "workspace_fingerprint_manifest_fingerprint64_hex": "__MANIFEST_FINGERPRINT64__",
  "files_touched": [
    "src/StandaloneSwarmReadiness.clasp",
    "src/StandaloneSwarmVerifier.clasp",
    "examples/swarm-native/StandaloneSwarmHarness.clasp",
    "examples/swarm-native/StandaloneSwarmRouting.clasp",
    "scripts/standalone-swarm-readiness.sh",
    "scripts/standalone-swarm-verify.sh",
    "docs/standalone-swarm-readiness.md",
    "runtime/standalone_swarm_probe.rs",
    "notes/direct-source-edit.txt",
    "notes/direct-source-edit-manifest.json"
  ],
  "tests_run": [
    "clasp-local-agent-source-edit-plan",
    "clasp-local-agent-direct-source-edit",
    "clasp-local-agent-multi-file-source-edit",
    "clasp-local-agent-source-patch-plan",
    "clasp-local-agent-targeted-source-patch",
    "clasp-local-agent-multi-surface-source-patch",
    "clasp-local-agent-repo-scale-source-patch",
    "clasp-local-agent-atomic-source-patch-preflight",
    "clasp-local-agent-source-patch-postcheck"
  ]
}
EOF
cat >"$verifier_report" <<'EOF'
{
  "workspace_fingerprint_manifest": "notes/direct-source-edit-manifest.json",
  "workspace_fingerprint_manifest_fingerprint64_hex": "__MANIFEST_FINGERPRINT64__",
  "verdict": "pass",
  "tests_run": [
    "clasp-local-agent-verifier-gate",
    "clasp-local-agent-direct-source-edit",
    "clasp-local-agent-source-patch-postcheck"
  ],
  "capability_statuses": [
    {
      "name": "clasp_native_agent_backend",
      "status": "pass",
      "evidence": [
        "local Clasp agent completed routed task kind: standalone-swarm",
        "local Clasp agent edited multiple existing ordinary-Clasp source files"
      ]
    },
    {
      "name": "local_verifier_gate",
      "status": "pass",
      "evidence": [
        "local verifier emitted typed gate evidence",
        "local-verifier-gate-recommendation:verifier-gate:pass"
      ]
    }
  ]
}
EOF
node - "$builder_report" "$verifier_report" "$manifest_fingerprint64" <<'NODE'
const fs = require("node:fs");
const [builderPath, verifierPath, manifestFingerprint] = process.argv.slice(2);
for (const reportPath of [builderPath, verifierPath]) {
  const report = JSON.parse(fs.readFileSync(reportPath, "utf8"));
  report.workspace_fingerprint_manifest_fingerprint64_hex = manifestFingerprint;
  fs.writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`);
}
NODE

closure_output="$(
  bash "$project_root/scripts/standalone-swarm-verify.sh" \
    --closure \
    --workspace "$workspace_root" \
    --builder-report "$builder_report" \
    --verifier-report "$verifier_report"
)"
case "$closure_output" in
  *"standalone-swarm-verifier=closed"* )
    ;;
  *)
    printf 'unexpected standalone closure verifier output: %s\n' "$closure_output" >&2
    exit 1
    ;;
esac

closure_json_output="$(
  bash "$project_root/scripts/standalone-swarm-verify.sh" \
    --closure \
    --json \
    --workspace "$workspace_root" \
    --builder-report "$builder_report" \
    --verifier-report "$verifier_report"
)"
node -e '
const report = JSON.parse(process.argv[1]);
if (report.kind !== "standalone-swarm-verifier-report") throw new Error(`unexpected kind: ${JSON.stringify(report)}`);
if (report.mode !== "closure") throw new Error(`unexpected closure mode: ${JSON.stringify(report)}`);
if (report.status !== "closed") throw new Error(`unexpected closure status: ${JSON.stringify(report)}`);
if (report.requiredSurfaceCount !== 8) throw new Error(`unexpected surface count: ${JSON.stringify(report)}`);
if (!report.builderReport || !report.verifierReport || !report.proofPath) throw new Error(`missing closure paths: ${JSON.stringify(report)}`);
if (report.workspaceFingerprintManifest !== "notes/direct-source-edit-manifest.json") throw new Error(`missing closure manifest path: ${JSON.stringify(report)}`);
if (!/^[0-9a-f]{64}$/.test(report.workspaceFingerprintManifestSha256)) throw new Error(`missing closure manifest sha256: ${JSON.stringify(report)}`);
if (!report.evidence?.includes("direct-source-edit-proof")) throw new Error(`missing proof evidence: ${JSON.stringify(report)}`);
if (!report.evidence?.includes("workspace-fingerprint-manifest")) throw new Error(`missing manifest evidence: ${JSON.stringify(report)}`);
' "$closure_json_output"

tampered_workspace_root="$test_root/tampered-workspace"
cp -R "$workspace_root" "$tampered_workspace_root"
printf '\nmutated-after-manifest\n' >>"$tampered_workspace_root/src/StandaloneSwarmReadiness.clasp"
set +e
tampered_output="$(
  bash "$project_root/scripts/standalone-swarm-verify.sh" \
    --closure \
    --workspace "$tampered_workspace_root" \
    --builder-report "$builder_report" \
    --verifier-report "$verifier_report" 2>&1
)"
tampered_status="$?"
set -e
[[ "$tampered_status" != "0" ]]
[[ "$tampered_output" == *"standalone-swarm-verifier=workspace-manifest-fingerprint-mismatch:src/StandaloneSwarmReadiness.clasp"* ]]

bad_builder_report="$test_root/bad-builder-report.json"
cp "$builder_report" "$bad_builder_report"
node - "$bad_builder_report" <<'NODE'
const fs = require("node:fs");
const path = process.argv[2];
const report = JSON.parse(fs.readFileSync(path, "utf8"));
report.tests_run = report.tests_run.filter((name) => name !== "clasp-local-agent-source-patch-postcheck");
fs.writeFileSync(path, `${JSON.stringify(report, null, 2)}\n`);
NODE
set +e
bad_output="$(
  bash "$project_root/scripts/standalone-swarm-verify.sh" \
    --closure \
    --workspace "$workspace_root" \
    --builder-report "$bad_builder_report" \
    --verifier-report "$verifier_report" 2>&1
)"
bad_status="$?"
set -e
[[ "$bad_status" != "0" ]]
[[ "$bad_output" == *"standalone-swarm-verifier=missing-json-evidence:builder.tests_run:clasp-local-agent-source-patch-postcheck"* ]]

printf 'standalone-swarm-surfaces-ok\n'
