#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
mkdir -p "$tmp_root"
export TMPDIR="$tmp_root"
test_root="$(mktemp -d "$TMPDIR/test-swarm-context-pack.XXXXXX")"

cleanup() {
  rm -rf "$test_root"
}

trap cleanup EXIT

claspc_bin="$(env -u CLASP_CLASPC -u CLASPC_BIN -u RUSTC "$project_root/scripts/resolve-claspc.sh")"
program_state_root="$test_root/program-state"
output_path="$test_root/context-pack-harness.json"

env RUSTC=/definitely-missing-rustc \
  timeout 120 \
  "$claspc_bin" run "$project_root/examples/swarm-native/ContextPackHarness.clasp" -- "$program_state_root" \
  >"$output_path"

if grep -F 'error:' "$output_path" >/dev/null; then
  cat "$output_path" >&2
  exit 1
fi

node - "$output_path" <<'EOF'
const fs = require("node:fs");

const report = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function includes(list, value, label) {
  assert(Array.isArray(list), `${label} is not an array`);
  assert(list.includes(value), `${label} missing ${value}: ${JSON.stringify(list)}`);
}

assert(report.taskId === "context-repair", `task id ${report.taskId}`);
assert(report.taskStatus === "completed", `task status ${report.taskStatus}`);
assert(report.verificationPassed === false, "verification should fail to prove failed trace context");
includes(report.failedVerifiers, "context-pack-fail", "failed verifiers");
assert(report.taskMemoryCount === 1, `task memory count ${report.taskMemoryCount}`);
assert(report.objectiveMemoryCount === 1, `objective memory count ${report.objectiveMemoryCount}`);
assert(report.memoryValues[0] === "task focused compiler verifier should inspect local evidence", "task memory should be first");
includes(report.memoryValues, "objective focused compiler verifier lesson", "memory values");
assert(report.memoryScores[0] > 0, `first memory score ${report.memoryScores[0]}`);
includes(report.memoryMatchedText, "task focused compiler verifier should inspect local evidence", "matched text");
assert(report.mailboxRunCount === 2, `mailbox run count ${report.mailboxRunCount}`);
assert(report.mailboxArtifactCount === 4, `mailbox artifact count ${report.mailboxArtifactCount}`);
assert(report.latestVerifierStatus === "failed", `latest verifier status ${report.latestVerifierStatus}`);
assert(report.latestVerifier === "context-pack-fail", `latest verifier ${report.latestVerifier}`);
includes(report.traceNames, "context-pack-fail", "trace names");
includes(report.traceStatuses, "failed", "trace statuses");
includes(report.traceClassifications, "exit-code", "trace classifications");
includes(report.artifactKinds, "stdout", "artifact kinds");
includes(report.artifactKinds, "stderr", "artifact kinds");
assert(
  report.artifactPaths.some((artifactPath) => artifactPath.endsWith(".stdout.txt")),
  `stdout artifact path missing: ${JSON.stringify(report.artifactPaths)}`,
);
assert(
  report.artifactPaths.some((artifactPath) => artifactPath.endsWith(".stderr.txt")),
  `stderr artifact path missing: ${JSON.stringify(report.artifactPaths)}`,
);
EOF

printf 'swarm-context-pack-ok\n'
