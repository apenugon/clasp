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
assert(report.mailboxArtifactCount === 5, `mailbox artifact count ${report.mailboxArtifactCount}`);
assert(report.latestVerifierStatus === "failed", `latest verifier status ${report.latestVerifierStatus}`);
assert(report.latestVerifier === "context-pack-fail", `latest verifier ${report.latestVerifier}`);
includes(report.traceNames, "context-pack-fail", "trace names");
includes(report.traceStatuses, "failed", "trace statuses");
includes(report.traceClassifications, "exit-code", "trace classifications");
includes(report.artifactKinds, "stdout", "artifact kinds");
includes(report.artifactKinds, "stderr", "artifact kinds");
includes(report.artifactKinds, "note", "artifact kinds");
assert(report.artifactExcerptCount >= 2, `artifact excerpt count ${report.artifactExcerptCount}`);
includes(report.artifactExcerptKinds, "stdout", "artifact excerpt kinds");
includes(report.artifactExcerptKinds, "stderr", "artifact excerpt kinds");
includes(report.artifactExcerptKinds, "note", "artifact excerpt kinds");
includes(report.artifactExcerptTexts, "context-verifier-warning", "artifact excerpt texts");
includes(report.artifactExcerptTexts, "published context artifact from ordinary clasp", "artifact excerpt texts");
assert(report.publishedArtifactKind === "note", `published artifact kind ${report.publishedArtifactKind}`);
assert(
  report.publishedArtifactReadText === "published context artifact from ordinary clasp",
  `published artifact text ${JSON.stringify(report.publishedArtifactReadText)}`,
);
assert(report.publishedArtifactReadBytes > 0, `published artifact read bytes ${report.publishedArtifactReadBytes}`);
assert(report.artifactSearchCount >= 1, `artifact search count ${report.artifactSearchCount}`);
assert(report.artifactSearchTopKind === "note", `artifact search top kind ${report.artifactSearchTopKind}`);
assert(report.artifactSearchTopScore > 0, `artifact search top score ${report.artifactSearchTopScore}`);
includes([report.artifactSearchMatchedText], "published context artifact from ordinary clasp", "artifact search match");
assert(
  report.artifactSearchExcerptText === "published context artifact from ordinary clasp",
  `artifact search excerpt ${JSON.stringify(report.artifactSearchExcerptText)}`,
);
assert(report.artifactReadKind === "stdout", `artifact read kind ${report.artifactReadKind}`);
assert(report.artifactReadBytes === 16, `artifact read bytes ${report.artifactReadBytes}`);
assert(report.artifactReadTotalBytes >= 16, `artifact read total bytes ${report.artifactReadTotalBytes}`);
assert(report.artifactReadTruncated === true, "artifact read should report truncation");
assert(report.artifactReadText === "context-verifier", `artifact read text ${JSON.stringify(report.artifactReadText)}`);
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
