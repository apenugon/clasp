#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
mkdir -p "$tmp_root"
export TMPDIR="$tmp_root"
test_root="$(mktemp -d "$TMPDIR/test-swarm-native-managed-loop.XXXXXX")"

cleanup() {
  rm -rf "$test_root"
}

trap cleanup EXIT

claspc_bin="$(env -u CLASP_CLASPC -u CLASPC_BIN -u RUSTC "$project_root/scripts/resolve-claspc.sh")"
state_root="$test_root/state"
output_path="$test_root/managed-loop-output.json"

env RUSTC=/definitely-missing-rustc \
  timeout 120 \
  "$claspc_bin" run "$project_root/examples/swarm-native/ManagedLoopHarness.clasp" -- "$state_root" \
  >"$output_path"

if grep -F 'error:' "$output_path" >/dev/null; then
  cat "$output_path" >&2
  exit 1
fi

node - "$output_path" <<'EOF'
const fs = require("node:fs");

const outputPath = process.argv[2];
const report = JSON.parse(fs.readFileSync(outputPath, "utf8"));

function fail(message) {
  throw new Error(`${outputPath}: ${message}`);
}

function assert(condition, message) {
  if (!condition) fail(message);
}

function sameList(actual, expected, label) {
  assert(Array.isArray(actual), `${label} is not an array`);
  assert(
    JSON.stringify(actual) === JSON.stringify(expected),
    `${label} expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
  );
}

function artifactText(path, expected, label) {
  assert(typeof path === "string" && path.length > 0, `${label} missing artifact path`);
  assert(fs.existsSync(path), `${label} artifact missing: ${path}`);
  const text = fs.readFileSync(path, "utf8");
  assert(text === expected, `${label} expected ${JSON.stringify(expected)}, got ${JSON.stringify(text)}`);
}

function checkTrace(actual, expected, label) {
  assert(Array.isArray(actual), `${label} is not an array`);
  assert(actual.length === expected.length, `${label} length ${actual.length}`);
  actual.forEach((entry, index) => {
    const exp = expected[index];
    assert(entry.verifierName === exp.verifierName, `${label} verifier ${index}`);
    assert(entry.status === exp.status, `${label} status ${index}`);
    assert(entry.exitCode === exp.exitCode, `${label} exit ${index}`);
    assert(entry.timedOut === false, `${label} timedOut ${index}`);
    assert(entry.failedVerifierClassification === exp.classification, `${label} classification ${index}`);
    artifactText(entry.stdoutArtifactPath, exp.stdout, `${label} stdout ${entry.verifierName}`);
    artifactText(entry.stderrArtifactPath, "", `${label} stderr ${entry.verifierName}`);
  });
}

const managed = report.managed;
assert(managed, "missing managed report");
assert(managed.phase === "completed", `managed phase ${managed.phase}`);
assert(managed.attempt === 2, `managed attempt ${managed.attempt}`);
assert(managed.maxAttempts === 2, `managed maxAttempts ${managed.maxAttempts}`);
assert(managed.completed === true, "managed loop should complete");
assert(managed.exhausted === false, "managed loop should not exhaust attempts");
assert(managed.requeued === true, "managed loop should requeue after first verifier failure");
assert(managed.requeueCount === 1, `managed requeueCount ${managed.requeueCount}`);
assert(managed.objectiveId === "managed-loop", `managed objective ${managed.objectiveId}`);
assert(managed.taskId === "managed-attempt", `managed task ${managed.taskId}`);
assert(managed.taskStatus === "completed", `managed taskStatus ${managed.taskStatus}`);
assert(managed.objectiveProjectedStatus === "completed", `managed projected status ${managed.objectiveProjectedStatus}`);
assert(managed.verificationPlanName === "managed-two-verifier-plan", `managed verification plan ${managed.verificationPlanName}`);
sameList(managed.requiredVerifiers, ["managed-primary", "managed-secondary"], "managed required verifiers");
sameList(managed.failedVerifiers, ["managed-primary"], "managed failed verifiers");
sameList(managed.verificationTraceClassifications, ["none", "none"], "managed final trace classifications");
sameList(managed.failedVerificationTraceClassifications, ["exit-code", "none"], "managed failed trace classifications");
checkTrace(
  managed.verificationTrace,
  [
    { verifierName: "managed-primary", status: "passed", exitCode: 0, classification: "none", stdout: "managed-primary-pass" },
    { verifierName: "managed-secondary", status: "passed", exitCode: 0, classification: "none", stdout: "managed-secondary-pass" },
  ],
  "managed final verification trace",
);
checkTrace(
  managed.failedVerificationTrace,
  [
    { verifierName: "managed-primary", status: "failed", exitCode: 6, classification: "exit-code", stdout: "managed-primary-first-fail" },
    { verifierName: "managed-secondary", status: "passed", exitCode: 0, classification: "none", stdout: "managed-secondary-pass" },
  ],
  "managed failed verification trace",
);
assert(managed.managerAction === "objective-complete", `managed action ${managed.managerAction}`);
assert(managed.latestRunStatus === "passed", `managed latest run status ${managed.latestRunStatus}`);
assert(managed.latestVerifierStatus === "passed", `managed latest verifier status ${managed.latestVerifierStatus}`);
assert(managed.latestVerifier === "managed-secondary", `managed latest verifier ${managed.latestVerifier}`);
assert(managed.latestFailureClassification === "exit-code", `managed failure classification ${managed.latestFailureClassification}`);
assert(managed.approvalCount === 1, `managed approval count ${managed.approvalCount}`);
assert(managed.mergegateVerdict === "pass", `managed mergegate ${managed.mergegateVerdict}`);
sameList(managed.readyTaskIds, [], "managed ready task ids");
sameList(managed.blockerTaskIds, [], "managed blocker task ids");
assert(managed.mailboxSummary.runCount === 6, `managed run count ${managed.mailboxSummary.runCount}`);
assert(managed.mailboxSummary.artifactCount === 12, `managed artifact count ${managed.mailboxSummary.artifactCount}`);
assert(managed.mailboxSummary.latestVerifierStatus === "passed", "managed mailbox latest verifier status");
for (const artifactPath of managed.mailboxSummary.artifactPaths) {
  assert(fs.existsSync(artifactPath), `managed artifact path missing: ${artifactPath}`);
}

assert(report.statusFileExists === true, "managed status file should be written");
assert(report.statusFileMatches === true, "managed status file should match returned report");
assert(typeof report.statusPath === "string" && report.statusPath.endsWith("managed-loop-report.json"), "unexpected status path");
assert(fs.existsSync(report.statusPath), `status file missing: ${report.statusPath}`);

const blocked = report.blocked;
assert(blocked, "missing blocked report");
assert(blocked.phase === "inspect", `blocked phase ${blocked.phase}`);
assert(blocked.completed === false, "blocked task should not complete");
assert(blocked.objectiveId === "blocked-loop", `blocked objective ${blocked.objectiveId}`);
assert(blocked.taskId === "blocked-child", `blocked task ${blocked.taskId}`);
assert(blocked.taskStatus === "created", `blocked task status ${blocked.taskStatus}`);
assert(blocked.objectiveProjectedStatus === "waiting", `blocked projected status ${blocked.objectiveProjectedStatus}`);
sameList(blocked.requiredVerifiers, ["blocked-smoke"], "blocked required verifiers");
sameList(blocked.failedVerifiers, [], "blocked failed verifiers");
sameList(blocked.verificationTrace, [], "blocked verification trace");
assert(blocked.managerAction === "wait", `blocked manager action ${blocked.managerAction}`);
sameList(blocked.readyTaskIds, [], "blocked ready task ids");
sameList(blocked.blockerTaskIds, ["missing-parent"], "blocked blocker task ids");
assert(blocked.blockedBy.includes("waiting on missing-parent"), `blocked reasons ${JSON.stringify(blocked.blockedBy)}`);
assert(blocked.latestRunStatus === "", `blocked latest run ${blocked.latestRunStatus}`);
assert(blocked.approvalCount === 0, `blocked approval count ${blocked.approvalCount}`);

const budget = report.budget;
assert(budget, "missing budget report");
assert(budget.phase === "builder-failed", `budget phase ${budget.phase}`);
assert(budget.attempt === 11, `budget attempt ${budget.attempt}`);
assert(budget.maxAttempts === 11, `budget maxAttempts ${budget.maxAttempts}`);
assert(budget.completed === false, "budget loop should not complete");
assert(budget.exhausted === true, "budget loop should exhaust attempts");
assert(budget.requeued === true, "budget loop should requeue before exhaustion");
assert(budget.requeueCount === 10, `budget requeueCount ${budget.requeueCount}`);
assert(budget.taskStatus === "failed", `budget task status ${budget.taskStatus}`);
assert(budget.latestRunStatus === "failed", `budget latest run ${budget.latestRunStatus}`);
assert(budget.latestVerifierStatus === "", `budget verifier status ${budget.latestVerifierStatus}`);
assert(budget.latestFailureClassification === "exit-code", `budget classification ${budget.latestFailureClassification}`);
sameList(budget.requiredVerifiers, ["budget-unused"], "budget required verifiers");
sameList(budget.failedVerifiers, [], "budget failed verifiers");
sameList(budget.verificationTrace, [], "budget verification trace");
assert(budget.mailboxSummary.runCount === 11, `budget run count ${budget.mailboxSummary.runCount}`);
EOF
