#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
mkdir -p "$tmp_root"
test_root="$(mktemp -d "$tmp_root/test-unsafe-quarantine.XXXXXX")"

cleanup() {
  rm -rf "$test_root"
}

trap cleanup EXIT

shared_cache_root="${CLASP_TEST_NATIVE_CLASPC_SHARED_CACHE_HOME:-${CLASP_TEST_SHARED_XDG_CACHE_HOME:-$tmp_root/clasp-test-xdg-cache}}"
if [[ "${CLASP_TEST_ISOLATED_XDG_CACHE:-0}" == "1" ]]; then
  shared_cache_root="$test_root/xdg-cache"
fi
export XDG_CACHE_HOME="$shared_cache_root/unsafe-quarantine"
mkdir -p "$XDG_CACHE_HOME"

claspc_bin="$(env -u CLASP_CLASPC -u CLASPC_BIN "$project_root/scripts/resolve-claspc.sh")"
source_file="$test_root/UnsafeQuarantine.clasp"
compiled_output="$test_root/unsafe-quarantine.mjs"

cat >"$source_file" <<'CLASP'
module Main

record Box a = {
  value : a
}

type Option a = Some a | None

foreign unsafe loadBox : Str -> Option (Box Str) = "loadBox"
foreign unsafe badBox : Str -> Option (Box Str) = "badBox"
foreign unsafe opaqueValue : Str -> a = "opaqueValue"

main : Str
main = "ok"
CLASP

"$claspc_bin" compile "$source_file" -o "$compiled_output"

grep -F 'function $claspParseHostTypeDescriptor(rawType)' "$compiled_output" >/dev/null
grep -F '$claspCreateHostTypeCodec("Option (Box Str)", "result")' "$compiled_output" >/dev/null

CLASP_UNSAFE_QUARANTINE_MODULE="$compiled_output" node --input-type=module <<'NODE'
import assert from "node:assert/strict";
import { pathToFileURL } from "node:url";

globalThis.__claspRuntime = {
  loadBox(input) {
    return ["Some", { value: `${input}:checked` }];
  },
  badBox() {
    return ["Some", { value: 42 }];
  },
  opaqueValue() {
    return { raw: true };
  }
};

const moduleUrl = pathToFileURL(process.env.CLASP_UNSAFE_QUARANTINE_MODULE);
const compiled = await import(moduleUrl.href);

const concrete = compiled.loadBox("nested");
assert.equal(concrete[0], "Some");
assert.equal(concrete[1].value, "nested:checked");
assert.notEqual(concrete.kind, "clasp-unsafe-quarantine");

assert.throws(() => compiled.badBox("nested"), /expected a string/);

const opaque = compiled.opaqueValue("x");
assert.equal(opaque.kind, "clasp-unsafe-quarantine");
assert.equal(opaque.tainted, true);
assert.equal(opaque.taint, "foreign-trusted");
assert.equal(opaque.reason, "unresolved-host-type");
assert.equal(opaque.type, "a");
assert.deepEqual(opaque.value, { raw: true });
NODE

printf 'test-unsafe-quarantine: ok\n'
