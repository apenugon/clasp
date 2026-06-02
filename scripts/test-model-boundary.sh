#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
timeout_secs="${CLASP_MODEL_BOUNDARY_TIMEOUT_SECS:-180}"

if ! [[ "$timeout_secs" =~ ^[0-9]+$ ]] || (( timeout_secs < 1 )); then
  printf 'CLASP_MODEL_BOUNDARY_TIMEOUT_SECS must be a positive integer\n' >&2
  exit 1
fi

mkdir -p "$tmp_root"
test_root="$(mktemp -d "$tmp_root/test-model-boundary.XXXXXX")"

cleanup() {
  rm -rf "$test_root"
}

trap cleanup EXIT

claspc_bin="$(env -u CLASP_CLASPC -u CLASPC_BIN CLASP_PROJECT_ROOT="$project_root" "$project_root/scripts/resolve-claspc.sh")"
module_source_path="$project_root/examples/swarm-native/ModelBoundary.clasp"
repo_harness_path="$project_root/examples/swarm-native/ModelBoundaryHarness.clasp"
source_path="$test_root/ModelBoundaryHarness.clasp"
compiled_js="$test_root/model-boundary.mjs"
native_binary="$test_root/model-boundary"
module_check_output="$test_root/module-check-output.json"
check_output="$test_root/check-output.json"
js_output="$test_root/js-output.json"
native_output="$test_root/native-output.json"

cp "$repo_harness_path" "$source_path"

if ! timeout "$timeout_secs" "$claspc_bin" --json check "$module_source_path" >"$module_check_output"; then
  cat "$module_check_output" >&2
  exit 1
fi
if ! grep -F '"status":"ok"' "$module_check_output" >/dev/null; then
  cat "$module_check_output" >&2
  exit 1
fi

if ! timeout "$timeout_secs" "$claspc_bin" --json check "$source_path" >"$check_output"; then
  cat "$check_output" >&2
  exit 1
fi
if ! grep -F '"status":"ok"' "$check_output" >/dev/null; then
  cat "$check_output" >&2
  exit 1
fi

timeout "$timeout_secs" "$claspc_bin" compile "$source_path" -o "$compiled_js" >/dev/null
timeout "$timeout_secs" node --input-type=module - "$compiled_js" >"$js_output" <<'NODE'
import { pathToFileURL } from "node:url";

const modulePath = process.argv[2];
const mod = await import(pathToFileURL(modulePath));
process.stdout.write(mod.main);
NODE

env RUSTC=/definitely-missing-rustc timeout "$timeout_secs" "$claspc_bin" compile "$source_path" -o "$native_binary" >/dev/null
timeout "$timeout_secs" "$native_binary" >"$native_output"

node - "$js_output" "$native_output" <<'NODE'
const fs = require("node:fs");

for (const path of process.argv.slice(2)) {
  const report = JSON.parse(fs.readFileSync(path, "utf8"));

  function assert(condition, message) {
    if (!condition) throw new Error(`${path}: ${message}`);
  }

  assert(report.requestProvider === "fixture-llm", `provider ${report.requestProvider}`);
  assert(report.requestModel === "local-model-boundary-test", `model ${report.requestModel}`);
  assert(report.requestSchema === "PlannerReport", `schema ${report.requestSchema}`);
  assert(report.requestTrustPolicy === "untrusted-until-tryDecode", `trust policy ${report.requestTrustPolicy}`);
  assert(report.promptText.includes("system: You are a planner"), "typed prompt should render system message");
  assert(report.promptText.includes("user: Return a PlannerReport"), "typed prompt should render user message");
  assert(report.untrustedTrusted === false, "raw model output must start untrusted");
  assert(report.validAccepted === true, "valid planner output should validate");
  assert(report.validTrust === "validated", `valid trust ${report.validTrust}`);
  assert(report.validTaskCount === 1, `valid task count ${report.validTaskCount}`);
  assert(report.invalidRejected === true, "invalid planner output should reject");
  assert(
    report.invalidReason === "model-output-missing-planner-fields" ||
      String(report.invalidReason).startsWith("model-output-decode-failed:"),
    `invalid reason ${report.invalidReason}`,
  );
  assert(report.schemaRejected === true, "schema mismatch should reject");
  assert(report.schemaReason === "model-output-schema-mismatch", `schema reason ${report.schemaReason}`);
  assert(report.statusRejected === true, "failed model status should reject");
  assert(report.statusReason === "model-output-status-not-completed:failed", `status reason ${report.statusReason}`);
  assert(report.pretrustedRejected === true, "pretrusted raw output should reject");
  assert(report.pretrustedReason === "model-boundary-rejects-pretrusted-output", `pretrusted reason ${report.pretrustedReason}`);
  assert(
    report.evidence.some((line) => line.includes("tryDecode PlannerReport")),
    "evidence should mention generated tryDecode validation",
  );
}
NODE

printf 'model-boundary-ok\n'
