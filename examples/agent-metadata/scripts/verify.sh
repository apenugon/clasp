#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
timeout_secs="${CLASP_AGENT_METADATA_TIMEOUT_SECS:-60}"

mkdir -p "$tmp_root"
test_root="$(mktemp -d "$tmp_root/agent-metadata.XXXXXX")"

cleanup() {
  rm -rf "$test_root"
}

trap cleanup EXIT

claspc_bin="${CLASP_CLASPC:-${CLASPC_BIN:-}}"
if [[ -n "$claspc_bin" && "$claspc_bin" != "$project_root"/* ]]; then
  claspc_bin=""
fi
if [[ -z "$claspc_bin" ]]; then
  claspc_bin="$(
    env -u CLASP_CLASPC -u CLASPC_BIN CLASP_PROJECT_ROOT="$project_root" \
      "$project_root/scripts/resolve-claspc.sh"
  )"
fi

main_check_output="$test_root/main-check.json"
compiled_js="$test_root/Main.mjs"
invalid_source="$test_root/InvalidMetadata.clasp"
invalid_check_output="$test_root/invalid-check.json"
no_metadata_source="$test_root/NoMetadata.clasp"
no_metadata_check_output="$test_root/no-metadata-check.json"
no_metadata_js="$test_root/NoMetadata.mjs"

(
  cd "$project_root"
  timeout "$timeout_secs" "$claspc_bin" --json check examples/agent-metadata/Main.clasp >"$main_check_output"
  timeout "$timeout_secs" "$claspc_bin" compile examples/agent-metadata/Main.clasp -o "$compiled_js" >/dev/null
)

node - "$main_check_output" "$compiled_js" <<'NODE'
const fs = require("node:fs");
const { pathToFileURL } = require("node:url");

const [mainCheckPath, compiledPath] = process.argv.slice(2);
const mainCheck = JSON.parse(fs.readFileSync(mainCheckPath, "utf8"));
const expectedMetadata = Object.freeze([
  Object.freeze({ key: "task", value: "wave-4-W4-T5" }),
  Object.freeze({ key: "role", value: "builder" }),
  Object.freeze({ key: "capability", value: "deterministic-agent-metadata" }),
]);

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

function stable(value) {
  return JSON.stringify(value);
}

(async () => {
  assert(mainCheck.status === "ok", `expected Main.clasp check status ok, got ${mainCheck.status}`);
  assert(mainCheck.summary === "main : Str", `expected metadata declarations to be omitted from summary, got ${mainCheck.summary}`);

  const mod = await import(pathToFileURL(compiledPath).href);
  assert(stable(mod.__claspMetadata) === stable(expectedMetadata), "compiled module exported unexpected __claspMetadata");
  assert(Object.isFrozen(mod.__claspMetadata), "__claspMetadata should be frozen");
  for (const entry of mod.__claspMetadata) {
    assert(Object.isFrozen(entry), `metadata entry ${entry.key} should be frozen`);
  }
  assert(mod.__claspModule.metadata === mod.__claspMetadata, "__claspModule should reference metadata export");
  assert(Object.isFrozen(mod.__claspModule.metadataByKey), "__claspModule.metadataByKey should be frozen");
  assert(mod.__claspModule.metadataByKey.task === "wave-4-W4-T5", "metadataByKey.task mismatch");
  assert(mod.__claspModule.metadataByKey.role === "builder", "metadataByKey.role mismatch");
  assert(mod.__claspModule.metadataByKey.capability === "deterministic-agent-metadata", "metadataByKey.capability mismatch");
  assert(mod.__claspBindings.metadata === mod.__claspMetadata, "__claspBindings should expose metadata");
  assert(mod.main === "metadata-ready", `unexpected main export: ${mod.main}`);
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
NODE

cat >"$no_metadata_source" <<'EOF'
module Main

main : Str
main = "plain-ready"
EOF

timeout "$timeout_secs" "$claspc_bin" --json check "$no_metadata_source" >"$no_metadata_check_output"
timeout "$timeout_secs" "$claspc_bin" compile "$no_metadata_source" -o "$no_metadata_js" >/dev/null

node - "$no_metadata_check_output" "$no_metadata_js" <<'NODE'
const fs = require("node:fs");
const { pathToFileURL } = require("node:url");

const [checkPath, compiledPath] = process.argv.slice(2);
const check = JSON.parse(fs.readFileSync(checkPath, "utf8"));
const compiledText = fs.readFileSync(compiledPath, "utf8");

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

(async () => {
  assert(check.status === "ok", `expected no-metadata check status ok, got ${check.status}`);
  assert(check.summary === "main : Str", `unexpected no-metadata summary: ${check.summary}`);
  for (const forbidden of [
    "export const __claspMetadata",
    "$claspMetadataMap",
    "metadata: __claspMetadata",
    "metadataByKey: $claspMetadataMap",
  ]) {
    assert(!compiledText.includes(forbidden), `ordinary module unexpectedly emitted metadata scaffold: ${forbidden}`);
  }
  const mod = await import(pathToFileURL(compiledPath).href);
  assert(!("__claspMetadata" in mod), "ordinary module should not export __claspMetadata");
  assert(!("metadata" in mod.__claspModule), "ordinary module should not expose module metadata");
  assert(!("metadataByKey" in mod.__claspModule), "ordinary module should not expose metadataByKey");
  assert(!("metadata" in mod.__claspBindings), "ordinary bindings should not expose metadata");
  assert(mod.main === "plain-ready", `unexpected no-metadata main export: ${mod.main}`);
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
NODE

cat >"$invalid_source" <<'EOF'
module Main

metadata task = 42

main : Str
main = "invalid"
EOF

set +e
timeout "$timeout_secs" "$claspc_bin" --json check "$invalid_source" >"$invalid_check_output"
invalid_status=$?
set -e

node - "$invalid_check_output" "$invalid_status" <<'NODE'
const fs = require("node:fs");

const [invalidCheckPath, statusText] = process.argv.slice(2);
const invalidCheck = JSON.parse(fs.readFileSync(invalidCheckPath, "utf8"));
if (Number(statusText) === 0) {
  throw new Error("invalid metadata check unexpectedly exited successfully");
}
if (invalidCheck.status !== "error") {
  throw new Error(`expected invalid metadata status error, got ${invalidCheck.status}`);
}
const invalidMessage = String(invalidCheck.error ?? invalidCheck.summary ?? "");
if (!invalidMessage.includes('Reserved declaration `metadata` must use `metadata <key> = "value"`')) {
  throw new Error(`invalid metadata diagnostic missing reservation guidance: ${invalidMessage}`);
}
NODE

printf 'agent-metadata: ok\n'
