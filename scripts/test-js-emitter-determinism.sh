#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node_bin="${NODE:-node}"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
mkdir -p "$tmp_root"
test_root="$(mktemp -d "$tmp_root/test-js-emitter-determinism.XXXXXX")"
cleanup() {
  rm -rf "$test_root"
}
trap cleanup EXIT

"$node_bin" - "$project_root/src/Compiler/Emit/JavaScript.clasp" <<'NODE'
const fs = require("node:fs");

const [emitterPath] = process.argv.slice(2);
const source = fs.readFileSync(emitterPath, "utf8");

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

assert(
  source.includes('textConcat ["$claspStableStringify(", emitExpr value, ")"]'),
  "LowerEncode should use the stable stringify helper",
);
assert(
  source.includes('function $claspStableStringify(value) {'),
  "emitted runtime prelude should define $claspStableStringify",
);
assert(
  source.includes('Object.keys(value).sort().map((key) => [key, $claspSnapshotValue(value[key])])'),
  "snapshot helper should canonicalize object keys",
);
assert(
  source.includes('Object.keys($claspExpectObject(dict, \\"dict\\")).sort()'),
  "dictKeys should expose sorted keys in emitted JavaScript",
);
assert(
  source.includes('Object.keys(objectValue).sort().map((key) => $claspSnapshotValue(objectValue[key]))'),
  "dictValues should follow sorted key order in emitted JavaScript",
);
assert(
  source.includes('return $claspSnapshotValue({ ...objectValue, [key]: value });'),
  "dictSet should preserve canonical Dict object key order",
);
assert(
  source.includes('return $claspSnapshotValue(next);'),
  "dictRemove should preserve canonical Dict object key order",
);
assert(
  source.includes('encodeJson(value) { return $claspStableStringify(this.toHost(value, \\"value\\")); }'),
  "schema encodeJson should use stable stringify",
);

function snapshotValue(value) {
  if (value === null || typeof value !== "object") {
    return value;
  }
  if (Array.isArray(value)) {
    return Object.freeze(value.map((item) => snapshotValue(item)));
  }
  const entries = Object.keys(value).sort().map((key) => [key, snapshotValue(value[key])]);
  return Object.freeze(Object.fromEntries(entries));
}

function stableStringify(value) {
  return JSON.stringify(snapshotValue(value));
}

const left = { zeta: 3, alpha: { gamma: 2, beta: 1 }, tasks: [{ status: "done", id: "b" }] };
const right = { tasks: [{ id: "b", status: "done" }], alpha: { beta: 1, gamma: 2 }, zeta: 3 };
assert(stableStringify(left) === stableStringify(right), "stable stringify should ignore object insertion order");
assert(
  stableStringify(left) === '{"alpha":{"beta":1,"gamma":2},"tasks":[{"id":"b","status":"done"}],"zeta":3}',
  "stable stringify should produce the expected canonical object order",
);

const dict = Object.freeze({ repair: "running", alpha: "queued", zeta: "done" });
const keys = Object.keys(dict).sort();
const values = keys.map((key) => snapshotValue(dict[key]));
assert(JSON.stringify(keys) === '["alpha","repair","zeta"]', "dictKeys should be key-sorted");
assert(JSON.stringify(values) === '["queued","running","done"]', "dictValues should follow sorted keys");

console.log("test-js-emitter-determinism: ok");
NODE

claspc_bin="$(
  timeout 240 env -u CLASP_CLASPC -u CLASPC_BIN CLASP_PROJECT_ROOT="$project_root" \
    "$project_root/scripts/resolve-claspc.sh"
)"
determinism_source="$test_root/Main.clasp"
cat >"$determinism_source" <<'EOF'
module Main

record Task = { id : Str, status : Str }

statusMap : Dict Str Str
statusMap = dictSet "alpha" "queued" (dictSet "zeta" "done" dictEmpty)

encoded : Str
encoded = encode (Task { id = "b", status = "done" })

main : Str
main = textJoin ":" [encoded, textJoin "," (dictKeys statusMap), textJoin "," (dictValues statusMap)]
EOF
compiled_output="$test_root/main.js"
timeout 180 "$claspc_bin" compile "$determinism_source" -o "$compiled_output" >/dev/null
"$node_bin" - "$compiled_output" <<'NODE'
const fs = require("node:fs");

const [compiledPath] = process.argv.slice(2);
const emitted = fs.readFileSync(compiledPath, "utf8");

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

assert(
  emitted.includes("function $claspStableStringify(value) {"),
  "ordinary claspc compile output should define $claspStableStringify",
);
assert(
  emitted.includes('export const encoded = $claspStableStringify({ id: "b", status: "done" });'),
  "ordinary claspc compile output should use stable stringify for encode",
);
assert(
  emitted.includes("Object.keys(value).sort().map((key) => [key, $claspSnapshotValue(value[key])])"),
  "ordinary claspc compile output should canonicalize snapshot object keys",
);
assert(
  emitted.includes('encodeJson(value) { return $claspStableStringify(this.toHost(value, "value")); }'),
  "ordinary claspc compile output should use stable stringify for schema JSON",
);
assert(
  emitted.includes('Object.keys($claspExpectObject(dict, "dict")).sort()'),
  "ordinary claspc compile output should sort dictKeys",
);
assert(
  emitted.includes("Object.keys(objectValue).sort().map((key) => $claspSnapshotValue(objectValue[key]))"),
  "ordinary claspc compile output should sort dictValues by key",
);
assert(
  emitted.includes("return $claspSnapshotValue({ ...objectValue, [key]: value });"),
  "ordinary claspc compile output should canonicalize dictSet object order",
);
assert(
  emitted.includes("return $claspSnapshotValue(next);"),
  "ordinary claspc compile output should canonicalize dictRemove object order",
);
assert(
  !emitted.includes("structuredClone(value)"),
  "ordinary claspc compile output should not use structuredClone for snapshots",
);
assert(
  !emitted.includes("JSON.stringify(this.toHost(value"),
  "ordinary claspc compile output should not use raw JSON.stringify for schema JSON",
);
assert(
  !emitted.includes("Object.values($claspExpectObject(dict"),
  "ordinary claspc compile output should not use insertion-ordered Object.values for Dict values",
);

import(`file://${compiledPath}`).then((compiledModule) => {
  assert(compiledModule.main === '{"id":"b","status":"done"}:alpha,zeta:queued,done', "compiled main should preserve sorted Dict projections");
  assert(
    JSON.stringify(compiledModule.statusMap) === '{"alpha":"queued","zeta":"done"}',
    "exported Dict object should have canonical key order",
  );
}).catch((error) => {
  console.error(error && error.stack ? error.stack : error);
  process.exit(1);
});
NODE
