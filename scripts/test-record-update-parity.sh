#!/usr/bin/env bash
set -euo pipefail

project_root="${CLASP_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
timeout_secs="${CLASP_RECORD_UPDATE_PARITY_TIMEOUT_SECS:-120}"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
test_root=""

cleanup() {
  rm -rf "${test_root:-}"
}

trap cleanup EXIT

fail() {
  printf 'test-record-update-parity: %s\n' "$*" >&2
  exit 1
}

if ! [[ "$timeout_secs" =~ ^[0-9]+$ ]] || (( timeout_secs < 1 )); then
  fail "CLASP_RECORD_UPDATE_PARITY_TIMEOUT_SECS must be a positive integer"
fi

mkdir -p "$tmp_root"
test_root="$(mktemp -d "$tmp_root/test-record-update-parity.XXXXXX")"
source_path="$test_root/Main.clasp"
check_output="$test_root/check.json"
native_output="$test_root/main.native.ir"
compiled_output="$test_root/main.mjs"
run_output="$test_root/run.txt"

claspc_bin="$(
  env -u CLASP_CLASPC -u CLASPC_BIN CLASP_PROJECT_ROOT="$project_root" \
    "$project_root/scripts/resolve-claspc.sh"
)"

cat >"$source_path" <<'EOF'
module Main

record AgentTask = {
  taskId : Str,
  status : Str,
  priority : Int,
  blockers : [Str]
}

emptyTexts : [Str]
emptyTexts = []

seedTask : AgentTask
seedTask = AgentTask { taskId = "repair", status = "queued", priority = 7, blockers = ["needs-review"] }

promote : AgentTask -> AgentTask
promote task = with task { status = "running", blockers = emptyTexts }

main : Str
main = {
  let running = promote seedTask;
  textJoin ":" [running.taskId, running.status, encode running.priority, encode (length running.blockers)]
}
EOF

(
  cd "$project_root"
  timeout "$timeout_secs" "$claspc_bin" --json check "$source_path" >"$check_output"
)

node - "$check_output" <<'NODE'
const fs = require("node:fs");

const check = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (check.status !== "ok") {
  throw new Error(`expected check status ok, got ${check.status}`);
}
if (check.implementation !== "clasp-native") {
  throw new Error(`expected clasp-native implementation, got ${check.implementation}`);
}
if (!String(check.summary || "").includes("promote : AgentTask -> AgentTask")) {
  throw new Error("check summary missing record-update function type");
}
NODE

(
  cd "$project_root"
  node - src/Compiler/CheckedCore.clasp src/stage1.primary.clasp src/embedded.primary.clasp <<'NODE'
const fs = require("node:fs");

const requiredSnippets = [
  "if callee == recordUpdateBuiltinName then",
  "HostedRecord recordName fields ->",
  "if recordName == recordUpdatePlaceholderName then",
  "match checkedCoreExpr typeDecls recordDecls env localEnv fnContext subjectExpr",
  "match checkedCoreRecordFieldList typeDecls recordDecls env localEnv fnContext fields",
  "CheckedCoreRecordArtifact resultType recordUpdatePlaceholderName fieldArtifacts",
  "CheckedCoreExprBuildError \"Record update expects override fields.\""
];

for (const sourcePath of process.argv.slice(2)) {
  const source = fs.readFileSync(sourcePath, "utf8");
  for (const snippet of requiredSnippets) {
    if (!source.includes(snippet)) {
      throw new Error(`${sourcePath} record-update guard missing snippet: ${snippet}`);
    }
  }

  const specialCaseIndex = source.indexOf("if callee == recordUpdateBuiltinName then");
  const genericListIndex = source.indexOf("match checkedCoreExprList typeDecls recordDecls env localEnv fnContext args", specialCaseIndex);
  if (specialCaseIndex < 0 || genericListIndex < specialCaseIndex) {
    throw new Error(`${sourcePath} should handle record update before the generic call-argument builder`);
  }
}
NODE
)

(
  cd "$project_root"
  timeout "$timeout_secs" "$claspc_bin" native "$source_path" -o "$native_output" --json >/dev/null
)
grep -F 'function promote(task) = let.immutable __clasp_record_update_subject__ = local(task) in record AgentTask' "$native_output" >/dev/null
grep -F 'taskId = field(AgentTask, local(__clasp_record_update_subject__), taskId)' "$native_output" >/dev/null
grep -F 'status = string("running")' "$native_output" >/dev/null
grep -F 'priority = field(AgentTask, local(__clasp_record_update_subject__), priority)' "$native_output" >/dev/null
grep -F 'blockers = local(emptyTexts)' "$native_output" >/dev/null

(
  cd "$project_root"
  timeout "$timeout_secs" "$claspc_bin" compile "$source_path" -o "$compiled_output" --json >/dev/null
)
grep -F 'export function promote(task)' "$compiled_output" >/dev/null
grep -F 'const __clasp_record_update_subject__ = task;' "$compiled_output" >/dev/null
grep -F 'return { taskId: (__clasp_record_update_subject__).taskId, status: "running", priority: (__clasp_record_update_subject__).priority, blockers: emptyTexts };' "$compiled_output" >/dev/null

(
  cd "$project_root"
  timeout "$timeout_secs" "$claspc_bin" run "$source_path" >"$run_output"
)

if [[ "$(cat "$run_output")" != "repair:running:7:0" ]]; then
  printf 'unexpected record-update run output:\n' >&2
  cat "$run_output" >&2
  exit 1
fi

printf 'record-update-parity-ok\n'
