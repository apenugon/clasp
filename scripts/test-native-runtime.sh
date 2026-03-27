#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-$project_root/.clasp-test-tmp}"
mkdir -p "$tmp_root"
export TMPDIR="$tmp_root"
test_root="$(mktemp -d "$TMPDIR/test-native-runtime.XXXXXX")"
cc_bin="${CC:-cc}"
cargo_bin="${CARGO:-cargo}"
rustc_bin="${RUSTC:-rustc}"
rust_runtime_lib="$project_root/runtime/target/debug/libclasp_runtime.a"
claspc_bin="$("$project_root/scripts/resolve-claspc.sh")"
node_bin="${NODE:-node}"
nix_reentry="${CLASP_NATIVE_RUNTIME_NIX_REENTRY:-0}"

cleanup() {
  rm -rf "$test_root"
}

trap cleanup EXIT

maybe_enter_nix_shell() {
  if command -v "$rustc_bin" >/dev/null 2>&1 && command -v "$cargo_bin" >/dev/null 2>&1; then
    return 0
  fi

  if [[ "$nix_reentry" == "1" ]]; then
    return 0
  fi

  if ! command -v nix >/dev/null 2>&1; then
    return 0
  fi

  nix develop "$project_root" --command bash -lc "
    set -euo pipefail
    cd \"$project_root\"
    export CLASP_PROJECT_ROOT=\"$project_root\"
    export CLASP_NATIVE_RUNTIME_NIX_REENTRY=1
    bash scripts/test-native-runtime.sh
  "
  exit 0
}

maybe_enter_nix_shell

ir_path="$test_root/durable-workflow.native.ir"
image_path="${ir_path%.*}.image.json"
harness_path="$test_root/test-native-image"
hello_ir_path="$test_root/hello.native.ir"
hello_image_path="${hello_ir_path%.*}.image.json"
hello_structured_image_path="$test_root/hello.structured.native.image.json"
parser_ir_path="$test_root/compiler-parser.native.ir"
parser_image_path="${parser_ir_path%.*}.image.json"
parser_structured_image_path="$test_root/compiler-parser.structured.native.image.json"
hosted_image_path="$project_root/src/embedded.native.image.json"
hosted_structured_image_path="$test_root/compiler-hosted.structured.native.image.json"
hosted_durable_ir_path="$test_root/durable-workflow-hosted.native.ir"
hosted_durable_image_path="${hosted_durable_ir_path%.*}.image.json"
hosted_migrating_upgrade_path="$test_root/durable-workflow-hosted-upgrade.native.image.json"
hosted_incompatible_upgrade_path="$test_root/durable-workflow-hosted-incompatible.native.image.json"
interpreter_harness_path="$test_root/test-native-interpreter"
route_harness_path="$test_root/test-native-route"
invalid_image_path="$test_root/invalid.native.image.json"
migrating_upgrade_path="$test_root/migrating-upgrade.native.image.json"
incompatible_upgrade_path="$test_root/incompatible-upgrade.native.image.json"
output_capture="$test_root/native-image-output.txt"
interpreter_output_capture="$test_root/native-interpreter-output.txt"
hosted_output_capture="$test_root/hosted-native-image-output.txt"
route_output_capture="$test_root/native-route-output.txt"
project_entry_dir="$test_root/project"
project_entry_path="$project_entry_dir/Main.clasp"
route_project_dir="$test_root/route-project"
route_project_path="$route_project_dir/Main.clasp"
route_ir_path="$test_root/route.native.ir"
route_image_path="${route_ir_path%.*}.image.json"

mkdir -p "$project_entry_dir"
cat >"$project_entry_path" <<'EOF'
module Main

import Helper

main : Str
main = helper "hello"
EOF

cat >"$project_entry_dir/Helper.clasp" <<'EOF'
module Helper

helper : Str -> Str
helper value = value
EOF

mkdir -p "$route_project_dir"
cat >"$route_project_path" <<'EOF'
module Main

record LeadRequest = { company : Str }
record LeadSummary = { summary : Str }

summarizeLead : LeadRequest -> LeadSummary
summarizeLead lead = LeadSummary { summary = lead.company }

route summarizeLeadRoute = POST "/lead/summary" LeadRequest -> LeadSummary summarizeLead

main : Str
main = "ok"
EOF

(
  cd "$project_root"
  "$claspc_bin" native examples/durable-workflow/Main.clasp -o "$ir_path" --json >/dev/null
  "$claspc_bin" native-image examples/durable-workflow/Main.clasp -o "$image_path" --json >/dev/null
  "$claspc_bin" native examples/hello.clasp -o "$hello_ir_path" --json >/dev/null
  "$claspc_bin" native-image examples/hello.clasp -o "$hello_image_path" --json >/dev/null
  "$claspc_bin" native examples/compiler-parser.clasp -o "$parser_ir_path" --json >/dev/null
  "$claspc_bin" native-image examples/compiler-parser.clasp -o "$parser_image_path" --json >/dev/null
  "$claspc_bin" native examples/durable-workflow/Main.clasp -o "$hosted_durable_ir_path" --json >/dev/null
  "$claspc_bin" native-image examples/durable-workflow/Main.clasp -o "$hosted_durable_image_path" --json >/dev/null
  "$claspc_bin" native "$route_project_path" -o "$route_ir_path" --json >/dev/null
  "$claspc_bin" native-image "$route_project_path" -o "$route_image_path" --json >/dev/null
)

[[ -f "$ir_path" ]]
[[ -f "$image_path" ]]
[[ -f "$hello_ir_path" ]]
[[ -f "$hello_image_path" ]]
[[ -f "$parser_ir_path" ]]
[[ -f "$parser_image_path" ]]
[[ -f "$hosted_image_path" ]]
[[ -f "$hosted_durable_ir_path" ]]
[[ -f "$hosted_durable_image_path" ]]
[[ -f "$route_ir_path" ]]
[[ -f "$route_image_path" ]]

"$node_bin" - "$image_path" "$migrating_upgrade_path" "$incompatible_upgrade_path" "$hello_image_path" "$hello_structured_image_path" "$parser_image_path" "$parser_structured_image_path" "$hosted_image_path" "$hosted_structured_image_path" <<'NODE'
const fs = require("fs");

const [
  sourcePath,
  migratingOutputPath,
  incompatibleOutputPath,
  helloSourcePath,
  helloStructuredOutputPath,
  parserSourcePath,
  parserStructuredOutputPath,
  hostedSourcePath,
  hostedStructuredOutputPath,
] = process.argv.slice(2);

const writeJson = (outputPath, payload) => {
  fs.writeFileSync(outputPath, `${JSON.stringify(payload)}\n`, "utf8");
};

const payload = JSON.parse(fs.readFileSync(sourcePath, "utf8"));
const originalFingerprint = payload.compatibility.interfaceFingerprint;
const migratingPayload = structuredClone(payload);
migratingPayload.compatibility.interfaceFingerprint = `${originalFingerprint}-upgrade`;
migratingPayload.compatibility.acceptedPreviousFingerprints = [originalFingerprint];
migratingPayload.compatibility.migration.strategy = "state-handoff";
writeJson(migratingOutputPath, migratingPayload);

const incompatiblePayload = structuredClone(migratingPayload);
incompatiblePayload.compatibility.acceptedPreviousFingerprints = ["native-compat:incompatible"];
writeJson(incompatibleOutputPath, incompatiblePayload);

for (const [inputPath, outputPath] of [
  [helloSourcePath, helloStructuredOutputPath],
  [parserSourcePath, parserStructuredOutputPath],
  [hostedSourcePath, hostedStructuredOutputPath],
]) {
  const structuredPayload = JSON.parse(fs.readFileSync(inputPath, "utf8"));
  for (const decl of structuredPayload.decls ?? []) {
    delete decl.bodyText;
  }
  writeJson(outputPath, structuredPayload);
}
NODE

"$node_bin" - "$hosted_durable_image_path" "$hosted_migrating_upgrade_path" "$hosted_incompatible_upgrade_path" <<'NODE'
const fs = require("fs");

const [sourcePath, migratingOutputPath, incompatibleOutputPath] = process.argv.slice(2);

const writeJson = (outputPath, payload) => {
  fs.writeFileSync(outputPath, `${JSON.stringify(payload)}\n`, "utf8");
};

const payload = JSON.parse(fs.readFileSync(sourcePath, "utf8"));
const originalFingerprint = payload.compatibility.interfaceFingerprint;
const migratingPayload = structuredClone(payload);
migratingPayload.compatibility.interfaceFingerprint = `${originalFingerprint}-upgrade`;
migratingPayload.compatibility.acceptedPreviousFingerprints = [originalFingerprint];
migratingPayload.compatibility.migration.strategy = "state-handoff";
writeJson(migratingOutputPath, migratingPayload);

const incompatiblePayload = structuredClone(migratingPayload);
incompatiblePayload.compatibility.acceptedPreviousFingerprints = ["native-compat:incompatible"];
writeJson(incompatibleOutputPath, incompatiblePayload);
NODE

cargo build --quiet --manifest-path "$project_root/runtime/Cargo.toml" --lib >/dev/null
[[ -f "$rust_runtime_lib" ]]

rust_native_libs="$(
  cargo rustc --quiet --manifest-path "$project_root/runtime/Cargo.toml" --lib -- --print native-static-libs 2>&1 >/dev/null |
    sed -n 's/^note: native-static-libs: //p' |
    tail -n 1
)"

rust_link_args=()
if [[ -n "$rust_native_libs" ]]; then
  read -r -a rust_link_args <<<"$rust_native_libs"
fi

"$cc_bin" \
  -std=c11 \
  -Wall \
  -Wextra \
  -Werror \
  -I"$project_root/runtime" \
  "$project_root/runtime/test_native_image.c" \
  "$rust_runtime_lib" \
  "${rust_link_args[@]}" \
  -o "$harness_path"

"$cc_bin" \
  -std=c11 \
  -Wall \
  -Wextra \
  -Werror \
  -I"$project_root/runtime" \
  "$project_root/runtime/test_native_interpreter.c" \
  "$rust_runtime_lib" \
  "${rust_link_args[@]}" \
  -o "$interpreter_harness_path"

"$cc_bin" \
  -std=c11 \
  -Wall \
  -Wextra \
  -Werror \
  -I"$project_root/runtime" \
  "$project_root/runtime/test_native_route.c" \
  "$rust_runtime_lib" \
  "${rust_link_args[@]}" \
  -o "$route_harness_path"

"$harness_path" "$image_path" "$migrating_upgrade_path" "$incompatible_upgrade_path" >"$output_capture"
grep -F "native-image-ok module=Main profile=compiler_backend_minimal" "$output_capture" >/dev/null
grep -F "fingerprint=native-compat:" "$output_capture" >/dev/null
grep -F "next_fingerprint=native-compat:" "$output_capture" >/dev/null
grep -F "handoff_strategy=state-handoff" "$output_capture" >/dev/null
grep -F "state_type=Counter" "$output_capture" >/dev/null
grep -F 'snapshot_symbol=$encode_Counter' "$output_capture" >/dev/null
grep -F 'handoff_symbol=clasp_native__Main__CounterFlow__handoff' "$output_capture" >/dev/null
grep -F 'snapshot={"count":7,"status":"warm"}' "$output_capture" >/dev/null
grep -F "snapshot_hook=1" "$output_capture" >/dev/null
grep -F "handoff=1" "$output_capture" >/dev/null
grep -F "active_modules=1" "$output_capture" >/dev/null
grep -F "latest_generation=2" "$output_capture" >/dev/null
grep -F "overlap=2" "$output_capture" >/dev/null
grep -F "rejected_incompatible_upgrade=1" "$output_capture" >/dev/null
grep -F "symbol=clasp_native__Main__main" "$output_capture" >/dev/null
grep -F "dispatch=Main@2::main" "$output_capture" >/dev/null
grep -F "old_dispatch=Main@1::main" "$output_capture" >/dev/null
grep -F "call=runtime-dispatched-v2" "$output_capture" >/dev/null
grep -F "old_call=runtime-dispatched-v1" "$output_capture" >/dev/null
grep -F "exports=" "$output_capture" >/dev/null

"$harness_path" "$hosted_durable_image_path" "$hosted_migrating_upgrade_path" "$hosted_incompatible_upgrade_path" >"$hosted_output_capture"
grep -F "native-image-ok module=Main profile=compiler_backend_minimal" "$hosted_output_capture" >/dev/null
grep -F "fingerprint=native-compat:" "$hosted_output_capture" >/dev/null
grep -F "next_fingerprint=native-compat:" "$hosted_output_capture" >/dev/null
grep -F "handoff_strategy=state-handoff" "$hosted_output_capture" >/dev/null
grep -F "state_type=Counter" "$hosted_output_capture" >/dev/null
grep -F 'snapshot_symbol=$encode_Counter' "$hosted_output_capture" >/dev/null
grep -F 'handoff_symbol=clasp_native__Main__CounterFlow__handoff' "$hosted_output_capture" >/dev/null
grep -F "snapshot_hook=1" "$hosted_output_capture" >/dev/null
grep -F "handoff=1" "$hosted_output_capture" >/dev/null
grep -F "dispatch=Main@2::main" "$hosted_output_capture" >/dev/null
grep -F "old_dispatch=Main@1::main" "$hosted_output_capture" >/dev/null
grep -F "call=runtime-dispatched-v2" "$hosted_output_capture" >/dev/null
grep -F "old_call=runtime-dispatched-v1" "$hosted_output_capture" >/dev/null

"$interpreter_harness_path" "$hello_structured_image_path" >"$interpreter_output_capture"
grep -F "interpreted_call[main]=Hello from Clasp" "$interpreter_output_capture" >/dev/null

"$interpreter_harness_path" "$parser_structured_image_path" firstDeclarationPayload $'parseModule source\nsource' >"$interpreter_output_capture"
grep -F $'interpreted_call[firstDeclarationPayload]=parseModule source\nsource' "$interpreter_output_capture" >/dev/null

"$interpreter_harness_path" "$parser_structured_image_path" remainingSegments "import Bdecl = value" $'module A\nimport B\ndecl = value' >"$interpreter_output_capture"
grep -F "interpreted_call[remainingSegments]=import Bdecl = value" "$interpreter_output_capture" >/dev/null

"$interpreter_harness_path" "$parser_structured_image_path" sampleImports "|Compiler.Loader|Compiler.Renderers" >"$interpreter_output_capture"
grep -F "interpreted_call[sampleImports]=|Compiler.Loader|Compiler.Renderers" "$interpreter_output_capture" >/dev/null

"$route_harness_path" "$route_image_path" >"$route_output_capture"
grep -F 'native_route_response={"summary":"Acme"}' "$route_output_capture" >/dev/null

"$interpreter_harness_path" "$hosted_structured_image_path" compileSourceText '*' $'module Main\n\nmain : Str\nmain = "hello"\n' >"$interpreter_output_capture"
grep -F 'interpreted_call[compileSourceText]=// Generated by compiler-selfhost' "$interpreter_output_capture" >/dev/null
grep -F 'export const main = "hello";' "$interpreter_output_capture" >/dev/null

CLASP_PROJECT_ROOT="$project_root" bash "$project_root/src/scripts/run-native-tool.sh" "$hosted_image_path" checkSourceText "$project_root/examples/hello.clasp" "$test_root/hosted-tool-hello.check"
grep -F "hello : Str" "$test_root/hosted-tool-hello.check" >/dev/null
grep -F "id : Str -> Str" "$test_root/hosted-tool-hello.check" >/dev/null
grep -F "main : Str" "$test_root/hosted-tool-hello.check" >/dev/null

CLASP_PROJECT_ROOT="$project_root" bash "$project_root/src/scripts/run-native-tool.sh" "$hosted_image_path" checkSourceText "$project_root/examples/compiler-parser.clasp" "$test_root/hosted-tool-parser.check"
grep -F "firstSegment : Str -> Str" "$test_root/hosted-tool-parser.check" >/dev/null
grep -F "remainingSegments : Str -> Str" "$test_root/hosted-tool-parser.check" >/dev/null
grep -F "parseModuleSummary : Str -> ParserState" "$test_root/hosted-tool-parser.check" >/dev/null

CLASP_PROJECT_ROOT="$project_root" bash "$project_root/src/scripts/run-native-tool.sh" "$hosted_image_path" compileSourceText "$project_root/examples/hello.clasp" "$test_root/hosted-tool-hello.mjs"
grep -F 'export const hello = "Hello from Clasp";' "$test_root/hosted-tool-hello.mjs" >/dev/null
grep -F 'export function id(v) { return v; }' "$test_root/hosted-tool-hello.mjs" >/dev/null
grep -F 'export const main = id(hello);' "$test_root/hosted-tool-hello.mjs" >/dev/null

CLASP_PROJECT_ROOT="$project_root" bash "$project_root/src/scripts/run-native-tool.sh" "$hosted_image_path" nativeSourceText "$project_root/examples/hello.clasp" "$test_root/hosted-tool-hello.native.ir"
grep -F 'exports [hello, id, main]' "$test_root/hosted-tool-hello.native.ir" >/dev/null
grep -F 'global hello = string("Hello from Clasp")' "$test_root/hosted-tool-hello.native.ir" >/dev/null
grep -F 'function id(v) = local(v)' "$test_root/hosted-tool-hello.native.ir" >/dev/null
grep -F 'global main = call(local(id), [local(hello)])' "$test_root/hosted-tool-hello.native.ir" >/dev/null

CLASP_PROJECT_ROOT="$project_root" bash "$project_root/src/scripts/run-native-tool.sh" "$hosted_image_path" checkCoreSourceText "$project_root/examples/hello.clasp" "$test_root/hosted-tool-hello.core.json"
grep -F 'CheckedCoreDeclArtifact' "$test_root/hosted-tool-hello.core.json" >/dev/null
grep -F '"hello"' "$test_root/hosted-tool-hello.core.json" >/dev/null
grep -F '"main"' "$test_root/hosted-tool-hello.core.json" >/dev/null

CLASP_PROJECT_ROOT="$project_root" bash "$project_root/src/scripts/run-native-tool.sh" "$hosted_image_path" nativeImageSourceText "$project_root/examples/hello.clasp" "$test_root/hosted-tool-hello.native.image.json"
grep -F 'clasp-native-image-v1' "$test_root/hosted-tool-hello.native.image.json" >/dev/null
grep -F '"module": "Main"' "$test_root/hosted-tool-hello.native.image.json" >/dev/null
grep -F '"name": "main"' "$test_root/hosted-tool-hello.native.image.json" >/dev/null

CLASP_PROJECT_ROOT="$project_root" bash "$project_root/src/scripts/run-native-tool.sh" "$hosted_image_path" checkProjectText "--project-entry=$project_entry_path" "$test_root/hosted-tool-project.check"
grep -F "helper : Str -> Str" "$test_root/hosted-tool-project.check" >/dev/null
grep -F "main : Str" "$test_root/hosted-tool-project.check" >/dev/null

CLASP_PROJECT_ROOT="$project_root" bash "$project_root/src/scripts/run-native-tool.sh" "$hosted_image_path" compileProjectText "--project-entry=$project_entry_path" "$test_root/hosted-tool-project.mjs"
grep -F 'export function helper(value) { return value; }' "$test_root/hosted-tool-project.mjs" >/dev/null
grep -F 'export const main = helper("hello");' "$test_root/hosted-tool-project.mjs" >/dev/null

CLASP_PROJECT_ROOT="$project_root" bash "$project_root/src/scripts/run-native-tool.sh" "$hosted_image_path" nativeImageProjectText "--project-entry=$project_entry_path" "$test_root/hosted-tool-project.native.image.json"
grep -F 'clasp-native-image-v1' "$test_root/hosted-tool-project.native.image.json" >/dev/null
grep -F '"name": "helper"' "$test_root/hosted-tool-project.native.image.json" >/dev/null
grep -F '"name": "main"' "$test_root/hosted-tool-project.native.image.json" >/dev/null

printf '%s\n' '{"format":"broken"}' >"$invalid_image_path"
if "$harness_path" "$invalid_image_path" >/dev/null 2>&1; then
  printf 'native image harness unexpectedly accepted an invalid image\n' >&2
  exit 1
fi
