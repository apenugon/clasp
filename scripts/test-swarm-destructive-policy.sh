#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
mkdir -p "$tmp_root"
export TMPDIR="$tmp_root"
test_root="$(mktemp -d "$TMPDIR/test-swarm-destructive-policy.XXXXXX")"
destructive_run_binary_cache_dir="${CLASP_NATIVE_RUN_BINARY_CACHE_DIR:-$test_root/run-binary-cache-v2}"
export CLASP_NATIVE_RUN_BINARY_CACHE_DIR="$destructive_run_binary_cache_dir"
export CLASP_NATIVE_RUN_BINARY_CACHE_MAX_MB="${CLASP_NATIVE_RUN_BINARY_CACHE_MAX_MB:-512}"
mkdir -p "$CLASP_NATIVE_RUN_BINARY_CACHE_DIR"

cleanup() {
  rm -rf "$test_root"
}

trap cleanup EXIT

claspc_bin="$(env -u CLASP_CLASPC -u CLASPC_BIN -u RUSTC "$project_root/scripts/resolve-claspc.sh")"
state_root="$test_root/state"
destructive_timeout_secs="${CLASP_SWARM_DESTRUCTIVE_POLICY_TIMEOUT_SECS:-500}"
node_bin="$(command -v node)"
filesystem_mediator_path="$project_root/scripts/clasp-filesystem-write-enforcer.mjs"
filesystem_guard_path="$project_root/scripts/clasp-filesystem-write-guard.c"
filesystem_mediator_json="$(node -e 'process.stdout.write(JSON.stringify([process.argv[1], "--jitless", process.argv[2]]))' "$node_bin" "$filesystem_mediator_path")"

node --check "$filesystem_mediator_path" >/dev/null
cc -fsyntax-only "$filesystem_guard_path" >/dev/null

env RUSTC=/definitely-missing-rustc \
  CLASP_SWARM_FILESYSTEM_MEDIATOR_JSON="$filesystem_mediator_json" \
  timeout "$destructive_timeout_secs" \
  "$claspc_bin" run "$project_root/examples/swarm-native/DestructivePolicyHarness.clasp" -- "$state_root" \
  >"$test_root/destructive-policy-harness.json"

if grep -F 'error:' "$test_root/destructive-policy-harness.json" >/dev/null; then
  cat "$test_root/destructive-policy-harness.json" >&2
  exit 1
fi

node - "$test_root/destructive-policy-harness.json" "$state_root/workspace" "$state_root/outside-workspace/destructive-target.txt" <<'EOF'
const fs = require("node:fs");
const path = require("node:path");
const report = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const workspaceRoot = fs.realpathSync(process.argv[3]);
const outsideTarget = process.argv[4];
const opaqueOutsideTarget = `${path.dirname(outsideTarget)}/opaque-write-target.txt`;

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function sameList(actual, expected, label) {
  assert(Array.isArray(actual), `${label} is not an array`);
  assert(
    JSON.stringify(actual) === JSON.stringify(expected),
    `${label} expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
  );
}

assert(report.taskId === "destructive-policy-task", `task id ${report.taskId}`);
sameList(report.requiredApprovals, ["destructive-action"], "required approvals");
sameList(report.allowedProcesses, ["rm", "bash", "node"], "allowed processes");
sameList(report.allowedWorkspaceRoots, [workspaceRoot], "allowed workspace roots");
assert(report.destructiveApprovalBlocked === true, "destructive run should require approval");
assert(report.outsideTargetBlocked === true, "approved destructive run should still block outside target");
assert(report.shellOutsideTargetBlocked === true, "approved destructive shell run should block outside target");
assert(report.shellDynamicTargetBlocked === true, "approved destructive shell run should fail closed on dynamic targets");
assert(report.opaqueOutsideWriteBlocked === true, "opaque subprocess write should be blocked by filesystem mediator");
assert(report.opaqueOutsideWritePrevented === true, "opaque subprocess write should not create outside target");
assert(report.filesystemMediationStarted === true, "filesystem mediation event should be recorded");
assert(report.outsideTargetSurvived === true, "outside destructive target should survive policy denial");
assert(fs.existsSync(outsideTarget), "outside target file should still exist");
assert(!fs.existsSync(opaqueOutsideTarget), "opaque outside write target should not exist");
assert(report.approvedRunStatus === "passed", `approved destructive run status ${report.approvedRunStatus}`);
assert(report.approvedRunExitCode === 0, `approved destructive run exit ${report.approvedRunExitCode}`);
assert(
  report.eventKinds.includes("destructive_action_approval_required"),
  `destructive approval event missing ${JSON.stringify(report.eventKinds)}`,
);
assert(report.eventKinds.includes("approval_granted"), `approval grant event missing ${JSON.stringify(report.eventKinds)}`);
assert(
  report.eventKinds.includes("filesystem_permission_denied"),
  `filesystem denial event missing ${JSON.stringify(report.eventKinds)}`,
);
assert(
  report.eventKinds.includes("filesystem_mediation_started"),
  `filesystem mediation event missing ${JSON.stringify(report.eventKinds)}`,
);
assert(report.eventKinds.includes("tool_run_finished"), `approved run event missing ${JSON.stringify(report.eventKinds)}`);
EOF

printf 'swarm-destructive-policy-ok\n'
