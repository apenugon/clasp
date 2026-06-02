#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mode="open"
workspace_root="$project_root"
builder_report=""
verifier_report=""
json_output=0

usage() {
  cat <<'EOF' >&2
usage: scripts/standalone-swarm-verify.sh
       scripts/standalone-swarm-verify.sh [--json]
       scripts/standalone-swarm-verify.sh --closure [--json] --workspace PATH --builder-report PATH --verifier-report PATH

Default mode checks the canonical open standalone-swarm fixture. Closure mode
checks a candidate workspace plus local-agent builder/verifier reports for the
fixed standalone-swarm markers and concrete direct-source-edit evidence.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --closure)
      mode="closure"
      shift
      ;;
    --json)
      json_output=1
      shift
      ;;
    --workspace)
      if [[ $# -lt 2 ]]; then
        printf 'standalone-swarm-verifier=missing-arg:--workspace\n' >&2
        exit 2
      fi
      workspace_root="$2"
      shift 2
      ;;
    --builder-report)
      if [[ $# -lt 2 ]]; then
        printf 'standalone-swarm-verifier=missing-arg:--builder-report\n' >&2
        exit 2
      fi
      builder_report="$2"
      shift 2
      ;;
    --verifier-report)
      if [[ $# -lt 2 ]]; then
        printf 'standalone-swarm-verifier=missing-arg:--verifier-report\n' >&2
        exit 2
      fi
      verifier_report="$2"
      shift 2
      ;;
    *)
      printf 'standalone-swarm-verifier=unknown-arg:%s\n' "$1" >&2
      usage
      exit 2
      ;;
  esac
done

check_contains() {
  local relative="$1"
  local needle="$2"
  if ! grep -F -- "$needle" "$workspace_root/$relative" >/dev/null; then
    printf 'standalone-swarm-verifier=missing:%s:%s\n' "$relative" "$needle"
    exit 1
  fi
}

check_file_contains() {
  local path="$1"
  local needle="$2"
  if ! grep -F -- "$needle" "$path" >/dev/null; then
    printf 'standalone-swarm-verifier=missing:%s:%s\n' "$path" "$needle"
    exit 1
  fi
}

print_json_report() {
  local status="$1"
  local proof_path="${2:-}"
  local workspace_fingerprint_manifest="${3:-}"
  local workspace_fingerprint_manifest_sha256="${4:-}"

  node - "$mode" "$status" "$workspace_root" "$builder_report" "$verifier_report" "$proof_path" "$workspace_fingerprint_manifest" "$workspace_fingerprint_manifest_sha256" <<'NODE'
const [
  mode,
  status,
  workspaceRoot,
  builderReport,
  verifierReport,
  proofPath,
  workspaceFingerprintManifest,
  workspaceFingerprintManifestSha256,
] = process.argv.slice(2);

const closed = status === "closed";
process.stdout.write(`${JSON.stringify({
  schemaVersion: 1,
  kind: "standalone-swarm-verifier-report",
  mode,
  status,
  workspaceRoot,
  builderReport: builderReport || "",
  verifierReport: verifierReport || "",
  proofPath: proofPath || "",
  workspaceFingerprintManifest: workspaceFingerprintManifest || "",
  workspaceFingerprintManifestSha256: workspaceFingerprintManifestSha256 || "",
  requiredSurfaceCount: 8,
  evidence: closed
    ? [
        "fixed-standalone-swarm-markers",
        "direct-source-edit-proof",
        "workspace-fingerprint-manifest",
        "local-agent-builder-report",
        "local-agent-verifier-report",
        "typed-local-verifier-gate",
      ]
    : [
        "canonical-open-standalone-swarm-fixture",
        "standalone-swarm-routing-markers",
      ],
}, null, 2)}\n`);
NODE
}

check_workspace_manifest() {
  local proof_path="$1"
  local builder_path="$2"
  local verifier_path="$3"

  node - "$workspace_root" "$proof_path" "$builder_path" "$verifier_path" <<'NODE'
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");

const [workspaceRootRaw, proofPath, builderPath, verifierPath] = process.argv.slice(2);
const workspaceRoot = path.resolve(workspaceRootRaw);
const expectedTargets = [
  "src/StandaloneSwarmReadiness.clasp",
  "src/StandaloneSwarmVerifier.clasp",
  "examples/swarm-native/StandaloneSwarmHarness.clasp",
  "examples/swarm-native/StandaloneSwarmRouting.clasp",
  "scripts/standalone-swarm-readiness.sh",
  "scripts/standalone-swarm-verify.sh",
  "docs/standalone-swarm-readiness.md",
  "runtime/standalone_swarm_probe.rs",
];

function fail(marker) {
  console.error(`standalone-swarm-verifier=${marker}`);
  process.exit(1);
}

function failEvidence(marker) {
  console.error(`standalone-swarm-verifier=missing-json-evidence:${marker}`);
  process.exit(1);
}

function readJson(jsonPath) {
  try {
    return JSON.parse(fs.readFileSync(jsonPath, "utf8"));
  } catch (error) {
    fail(`invalid-json:${jsonPath}:${error.message}`);
  }
}

function sha256(bytes) {
  return crypto.createHash("sha256").update(bytes).digest("hex");
}

function textFingerprint64Hex(value) {
  let hash = 0xcbf29ce484222325n;
  for (const byte of Buffer.from(value, "utf8")) {
    hash ^= BigInt(byte);
    hash = (hash * 0x100000001b3n) & 0xffffffffffffffffn;
  }
  return hash.toString(16).padStart(16, "0");
}

function proofLineValue(proof, key) {
  const prefix = `${key}=`;
  for (const line of proof.split(/\r?\n/)) {
    if (line.startsWith(prefix)) return line.slice(prefix.length);
  }
  return "";
}

function resolveWorkspaceRelative(relative, marker) {
  if (!relative || path.isAbsolute(relative) || relative.split(/[\\/]+/).includes("..")) {
    fail(`${marker}:${relative || "missing"}`);
  }
  const resolved = path.resolve(workspaceRoot, relative);
  if (resolved !== workspaceRoot && !resolved.startsWith(`${workspaceRoot}${path.sep}`)) {
    fail(`${marker}:${relative}`);
  }
  return resolved;
}

const proof = fs.readFileSync(proofPath, "utf8");
const manifestRelative = proofLineValue(proof, "workspaceFingerprintManifest");
const algorithm = proofLineValue(proof, "workspaceFingerprintAlgorithm");
if (manifestRelative === "") fail("missing-proof:workspaceFingerprintManifest");
if (algorithm !== "textFingerprint64Hex") fail(`invalid-proof:workspaceFingerprintAlgorithm:${algorithm || "missing"}`);

const manifestPath = resolveWorkspaceRelative(manifestRelative, "invalid-workspace-manifest-path");
if (!fs.existsSync(manifestPath)) fail(`missing-workspace-manifest:${manifestRelative}`);
const manifestBytes = fs.readFileSync(manifestPath);
const manifestDigest = sha256(manifestBytes);
const manifestFingerprint64Hex = textFingerprint64Hex(manifestBytes.toString("utf8"));
const manifest = readJson(manifestPath);

if (manifest.schemaVersion !== 1) fail("workspace-manifest-schema-version");
if (manifest.kind !== "standalone-swarm-direct-source-edit-manifest") fail("workspace-manifest-kind");
if (manifest.fingerprintAlgorithm !== "textFingerprint64Hex") fail("workspace-manifest-fingerprint-algorithm");
if (manifest.requiredSurfaceCount !== expectedTargets.length) fail("workspace-manifest-required-surface-count");
if (!Array.isArray(manifest.files)) fail("workspace-manifest-files");

for (const target of expectedTargets) {
  const matches = manifest.files.filter((entry) => entry && entry.path === target);
  if (matches.length !== 1) fail(`workspace-manifest-entry:${target}`);
  const fullPath = resolveWorkspaceRelative(target, "invalid-workspace-target-path");
  if (!fs.existsSync(fullPath)) fail(`workspace-manifest-missing-file:${target}`);
  const actualFingerprint = textFingerprint64Hex(fs.readFileSync(fullPath, "utf8"));
  if (matches[0].fingerprint64Hex !== actualFingerprint) {
    fail(`workspace-manifest-fingerprint-mismatch:${target}`);
  }
}

const builder = readJson(builderPath);
const verifier = readJson(verifierPath);
if (builder.workspace_fingerprint_manifest !== manifestRelative) {
  failEvidence("builder.workspace_fingerprint_manifest");
}
if (builder.workspace_fingerprint_manifest_fingerprint64_hex !== manifestFingerprint64Hex) {
  failEvidence("builder.workspace_fingerprint_manifest_fingerprint64_hex");
}
if (verifier.workspace_fingerprint_manifest !== manifestRelative) {
  failEvidence("verifier.workspace_fingerprint_manifest");
}
if (verifier.workspace_fingerprint_manifest_fingerprint64_hex !== manifestFingerprint64Hex) {
  failEvidence("verifier.workspace_fingerprint_manifest_fingerprint64_hex");
}

process.stdout.write(`${manifestRelative}\n${manifestDigest}\n`);
NODE
}

check_json_evidence() {
  local builder_path="$1"
  local verifier_path="$2"

  node - "$builder_path" "$verifier_path" <<'NODE'
const fs = require("node:fs");
const [builderPath, verifierPath] = process.argv.slice(2);

function readJson(path) {
  try {
    return JSON.parse(fs.readFileSync(path, "utf8"));
  } catch (error) {
    console.error(`standalone-swarm-verifier=invalid-json:${path}:${error.message}`);
    process.exit(1);
  }
}

function arrayIncludes(report, field, value) {
  return Array.isArray(report[field]) && report[field].includes(value);
}

function hasCapability(report, name, evidence) {
  return Array.isArray(report.capability_statuses) &&
    report.capability_statuses.some((entry) =>
      entry &&
      entry.name === name &&
      entry.status === "pass" &&
      Array.isArray(entry.evidence) &&
      entry.evidence.some((item) => typeof item === "string" && item.includes(evidence))
    );
}

function requireCondition(condition, marker) {
  if (!condition) {
    console.error(`standalone-swarm-verifier=missing-json-evidence:${marker}`);
    process.exit(1);
  }
}

const builder = readJson(builderPath);
const verifier = readJson(verifierPath);
const expectedTouched = [
  "src/StandaloneSwarmReadiness.clasp",
  "src/StandaloneSwarmVerifier.clasp",
  "examples/swarm-native/StandaloneSwarmHarness.clasp",
  "examples/swarm-native/StandaloneSwarmRouting.clasp",
  "scripts/standalone-swarm-readiness.sh",
  "scripts/standalone-swarm-verify.sh",
  "docs/standalone-swarm-readiness.md",
  "runtime/standalone_swarm_probe.rs",
  "notes/direct-source-edit.txt",
  "notes/direct-source-edit-manifest.json",
];
const expectedBuilderTests = [
  "clasp-local-agent-source-edit-plan",
  "clasp-local-agent-direct-source-edit",
  "clasp-local-agent-multi-file-source-edit",
  "clasp-local-agent-source-patch-plan",
  "clasp-local-agent-targeted-source-patch",
  "clasp-local-agent-multi-surface-source-patch",
  "clasp-local-agent-repo-scale-source-patch",
  "clasp-local-agent-atomic-source-patch-preflight",
  "clasp-local-agent-source-patch-postcheck",
];

for (const path of expectedTouched) {
  requireCondition(arrayIncludes(builder, "files_touched", path), `builder.files_touched:${path}`);
}
for (const testName of expectedBuilderTests) {
  requireCondition(arrayIncludes(builder, "tests_run", testName), `builder.tests_run:${testName}`);
}
requireCondition(verifier.verdict === "pass", "verifier.verdict:pass");
requireCondition(arrayIncludes(verifier, "tests_run", "clasp-local-agent-verifier-gate"), "verifier.tests_run:clasp-local-agent-verifier-gate");
requireCondition(arrayIncludes(verifier, "tests_run", "clasp-local-agent-direct-source-edit"), "verifier.tests_run:clasp-local-agent-direct-source-edit");
requireCondition(arrayIncludes(verifier, "tests_run", "clasp-local-agent-source-patch-postcheck"), "verifier.tests_run:clasp-local-agent-source-patch-postcheck");
requireCondition(hasCapability(verifier, "local_verifier_gate", "local verifier emitted typed gate evidence"), "capability:local_verifier_gate");
requireCondition(hasCapability(verifier, "clasp_native_agent_backend", "local Clasp agent completed routed task kind: standalone-swarm"), "capability:standalone-swarm-route");
requireCondition(hasCapability(verifier, "clasp_native_agent_backend", "local Clasp agent edited multiple existing ordinary-Clasp source files"), "capability:standalone-swarm-source-edit");
NODE
}

if [[ "$mode" == "closure" ]]; then
  if [[ -z "$builder_report" || -z "$verifier_report" ]]; then
    printf 'standalone-swarm-verifier=missing-closure-report\n' >&2
    exit 2
  fi
  if [[ ! -d "$workspace_root" ]]; then
    printf 'standalone-swarm-verifier=missing-workspace:%s\n' "$workspace_root" >&2
    exit 1
  fi
  if [[ ! -f "$builder_report" || ! -f "$verifier_report" ]]; then
    printf 'standalone-swarm-verifier=missing-report\n' >&2
    exit 1
  fi

  check_contains "src/StandaloneSwarmReadiness.clasp" 'readinessStatus = "standalone-swarm-fixed-after-feedback"'
  check_contains "src/StandaloneSwarmVerifier.clasp" 'verifierStatus = "standalone-swarm-fixed-after-feedback"'
  check_contains "examples/swarm-native/StandaloneSwarmHarness.clasp" 'harnessStatus = "standalone-swarm-fixed-after-feedback"'
  check_contains "examples/swarm-native/StandaloneSwarmRouting.clasp" 'routingStatus = "standalone-swarm-fixed-after-feedback"'
  check_contains "scripts/standalone-swarm-readiness.sh" 'echo "standalone-swarm=standalone-swarm-fixed-after-feedback"'
  check_contains "scripts/standalone-swarm-verify.sh" 'echo "standalone-swarm-verifier=standalone-swarm-fixed-after-feedback"'
  check_contains "docs/standalone-swarm-readiness.md" 'standalone-swarm-status: standalone-swarm-fixed-after-feedback'
  check_contains "runtime/standalone_swarm_probe.rs" 'STANDALONE_SWARM_STATUS: &str = "standalone-swarm-fixed-after-feedback"'

  proof_path="$workspace_root/notes/direct-source-edit.txt"
  if [[ ! -f "$proof_path" ]]; then
    printf 'standalone-swarm-verifier=missing-proof:notes/direct-source-edit.txt\n'
    exit 1
  fi
  check_file_contains "$proof_path" 'kind=clasp-local-agent-direct-source-edit'
  check_file_contains "$proof_path" 'route=standalone-swarm'
  check_file_contains "$proof_path" 'planDriven=true'
  check_file_contains "$proof_path" 'multiFile=true'
  check_file_contains "$proof_path" 'multiSurface=true'
  check_file_contains "$proof_path" 'repoScale=true'
  check_file_contains "$proof_path" 'repoScaleRequiredRoots=src,examples,scripts,docs,runtime'
  check_file_contains "$proof_path" 'atomicPreflight=true'
  check_file_contains "$proof_path" 'postWriteFingerprintCheck=true'
  check_file_contains "$proof_path" 'workspaceFingerprintManifest=notes/direct-source-edit-manifest.json'
  check_file_contains "$proof_path" 'workspaceFingerprintAlgorithm=textFingerprint64Hex'
  check_file_contains "$proof_path" 'workspaceConfinedWrite=true'
  check_file_contains "$proof_path" 'sourceEditPrimitive=workspaceReplaceText'
  check_file_contains "$proof_path" 'operation=targeted-replace'
  check_file_contains "$proof_path" 'targetCount=8'
  check_file_contains "$proof_path" 'patchCount=8'
  for target in \
    "src/StandaloneSwarmReadiness.clasp" \
    "src/StandaloneSwarmVerifier.clasp" \
    "examples/swarm-native/StandaloneSwarmHarness.clasp" \
    "examples/swarm-native/StandaloneSwarmRouting.clasp" \
    "scripts/standalone-swarm-readiness.sh" \
    "scripts/standalone-swarm-verify.sh" \
    "docs/standalone-swarm-readiness.md" \
    "runtime/standalone_swarm_probe.rs"; do
    check_file_contains "$proof_path" "sourceFile=$target"
    check_file_contains "$proof_path" "sourcePreviousSeen=$target"
    check_file_contains "$proof_path" "targetPatchMode=$target:targeted-replace"
    check_file_contains "$proof_path" "targetPostcheck=$target:present"
  done

  mapfile -t workspace_manifest_check < <(check_workspace_manifest "$proof_path" "$builder_report" "$verifier_report")
  workspace_fingerprint_manifest="${workspace_manifest_check[0]}"
  workspace_fingerprint_manifest_sha256="${workspace_manifest_check[1]}"
  check_json_evidence "$builder_report" "$verifier_report"
  if (( json_output )); then
    print_json_report "closed" "$proof_path" "$workspace_fingerprint_manifest" "$workspace_fingerprint_manifest_sha256"
  else
    echo "standalone-swarm-verifier=closed"
    printf 'standalone-swarm-verifier-surfaces=closed\n'
  fi
  exit 0
fi

check_contains "src/StandaloneSwarmReadiness.clasp" 'readinessStatus = "open"'
check_contains "src/StandaloneSwarmVerifier.clasp" 'verifierStatus = "open"'
check_contains "examples/swarm-native/StandaloneSwarmHarness.clasp" 'harnessStatus = "open"'
check_contains "examples/swarm-native/StandaloneSwarmRouting.clasp" 'routingStatus = "open"'
check_contains "docs/standalone-swarm-readiness.md" 'standalone-swarm-status: open'
check_contains "runtime/standalone_swarm_probe.rs" 'const STANDALONE_SWARM_STATUS: &str = "open";'
check_contains "examples/swarm-native/StandaloneSwarmRouting.clasp" 'backendConfigRepair=agent-backend'
check_contains "examples/swarm-native/StandaloneSwarmRouting.clasp" 'plannerBackendConfigRepair=agent-backend'

if (( json_output )); then
  print_json_report "open"
else
  echo "standalone-swarm-verifier=open"
  printf 'standalone-swarm-verifier-surfaces=present\n'
fi
