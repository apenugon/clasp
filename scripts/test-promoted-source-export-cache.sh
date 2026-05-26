#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
test_root=""

cleanup() {
  rm -rf "${test_root:-}"
}

trap cleanup EXIT

mkdir -p "$tmp_root"
test_root="$(mktemp -d "$tmp_root/test-promoted-source-export-cache.XXXXXX")"
claspc_bin="$(env -u CLASP_CLASPC -u CLASPC_BIN "$project_root/scripts/resolve-claspc.sh")"

node --check "$project_root/scripts/generate-promoted-source-export-cache.mjs" >/dev/null
node --check "$project_root/scripts/check-promoted-native-image-exports.mjs" >/dev/null
node "$project_root/scripts/generate-promoted-source-export-cache.mjs" --check >/dev/null

portable_root="$test_root/portable/.clasp-task-workspaces/task"
mkdir -p "$portable_root/scripts" "$portable_root/src"
cp "$project_root/scripts/check-promoted-native-image-exports.mjs" "$portable_root/scripts/check-promoted-native-image-exports.mjs"
cp "$project_root/src/Main.clasp" "$portable_root/src/Main.clasp"
cp "$project_root/src/CompilerMain.clasp" "$portable_root/src/CompilerMain.clasp"
cp "$project_root/src/stage1.compiler.source-export-cache-v1.json" "$portable_root/src/stage1.compiler.source-export-cache-v1.json"
portable_check_output="$(node "$portable_root/scripts/check-promoted-native-image-exports.mjs")"
case "$portable_check_output" in
  *"portable source-export fallback"*)
    ;;
  *)
    printf 'expected portable source-export fallback, got: %s\n' "$portable_check_output" >&2
    exit 1
    ;;
esac

strict_root="$test_root/portable/strict"
mkdir -p "$strict_root/scripts" "$strict_root/src"
cp "$project_root/scripts/check-promoted-native-image-exports.mjs" "$strict_root/scripts/check-promoted-native-image-exports.mjs"
cp "$project_root/src/Main.clasp" "$strict_root/src/Main.clasp"
cp "$project_root/src/CompilerMain.clasp" "$strict_root/src/CompilerMain.clasp"
cp "$project_root/src/stage1.compiler.source-export-cache-v1.json" "$strict_root/src/stage1.compiler.source-export-cache-v1.json"
if node "$strict_root/scripts/check-promoted-native-image-exports.mjs" >"$test_root/strict-check.out" 2>"$test_root/strict-check.err"; then
  printf 'strict promoted image check unexpectedly passed without native images\n' >&2
  exit 1
fi
grep -F 'missing promoted compiler images:' "$test_root/strict-check.err" >/dev/null

cache_root="$test_root/cache"
check_output="$test_root/checker.check.json"
check_log="$test_root/checker.check.log"
hello_run_log="$test_root/hello.run.log"
hello_run_output="$test_root/hello.run.out"
task_workspace_harness_image="$test_root/task-workspace-runtime-harness.native.image.json"
task_workspace_harness_log="$test_root/task-workspace-runtime-harness.native-image.log"
timeout_secs="${CLASP_PROMOTED_SOURCE_EXPORT_TIMEOUT_SECS:-60}"

(
  cd "$project_root"
  timeout "$timeout_secs" env XDG_CACHE_HOME="$cache_root" CLASP_NATIVE_TRACE_CACHE=1 \
    "$claspc_bin" --json check examples/compiler-checker.clasp \
    >"$check_output" 2>"$check_log"
)

grep -F '"status":"ok"' "$check_output" >/dev/null
grep -F '"implementation":"clasp-native"' "$check_output" >/dev/null
grep -F 'snapshot : CheckSnapshot' "$check_output" >/dev/null
node - "$project_root" "$project_root/src/stage1.compiler.source-export-cache-v1.json" "$check_output" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const [projectRoot, cachePath, checkPath] = process.argv.slice(2);
const cache = JSON.parse(fs.readFileSync(cachePath, "utf8"));
const check = JSON.parse(fs.readFileSync(checkPath, "utf8"));
const entry = cache.entries.find((candidate) => candidate.source === "examples/compiler-checker.clasp");
if (!entry) {
  throw new Error("missing promoted compiler-checker source export entry");
}
if (check.summary !== entry.output) {
  throw new Error("promoted compiler-checker summary changed");
}
const helloEntry = cache.entries.find((candidate) => candidate.source === "examples/hello.clasp");
if (!helloEntry) {
  throw new Error("missing promoted hello native image entry");
}
if (helloEntry.exportName !== "nativeImageSourceText") {
  throw new Error("hello promoted entry should seed nativeImageSourceText");
}
if (helloEntry.outputPath !== "src/stage1.hello.native.image.json") {
  throw new Error("hello promoted entry should use the native source image output path");
}
const helloImage = JSON.parse(fs.readFileSync(path.join(projectRoot, "src/stage1.hello.native.image.json"), "utf8"));
if (helloImage.format !== "clasp-native-image-v1" || helloImage.module !== "Main") {
  throw new Error("hello promoted native image has an unexpected shape");
}
const harnessEntry = cache.entries.find((candidate) => candidate.source === "examples/swarm-native/TaskWorkspaceRuntimeHarness.clasp");
if (!harnessEntry) {
  throw new Error("missing promoted TaskWorkspaceRuntimeHarness native image entry");
}
if (harnessEntry.exportName !== "nativeImageProjectText") {
  throw new Error("TaskWorkspaceRuntimeHarness promoted entry should seed nativeImageProjectText");
}
if (harnessEntry.outputPath !== "src/stage1.task-workspace-runtime-harness.native.image.json") {
  throw new Error("TaskWorkspaceRuntimeHarness promoted entry should use the native image output path");
}
const harnessImage = JSON.parse(fs.readFileSync(path.join(projectRoot, "src/stage1.task-workspace-runtime-harness.native.image.json"), "utf8"));
if (harnessImage.format !== "clasp-native-image-v1") {
  throw new Error("TaskWorkspaceRuntimeHarness promoted native image has an unexpected format");
}
NODE
grep -F '[claspc-cache] source-export promoted hit export=checkSourceText key=' "$check_log" >/dev/null
if grep -F '[claspc-cache] source-export miss export=checkSourceText' "$check_log" >/dev/null; then
  printf 'compiler-checker check should use the promoted source-export cache before reporting a miss\n' >&2
  exit 1
fi

(
  cd "$project_root"
  timeout "$timeout_secs" env XDG_CACHE_HOME="$test_root/hello-run-cache" CLASP_PROJECT_ROOT="$project_root" CLASP_NATIVE_TRACE_CACHE=1 \
    "$claspc_bin" run examples/hello.clasp \
    >"$hello_run_output" 2>"$hello_run_log"
)

grep -Fx 'Hello from Clasp' "$hello_run_output" >/dev/null
grep -F '[claspc-cache] run-binary single-source image export=nativeImageSourceText' "$hello_run_log" >/dev/null
grep -F '[claspc-cache] source-export promoted hit export=nativeImageSourceText key=' "$hello_run_log" >/dev/null
if grep -F '[claspc-cache] source-export miss export=nativeImageSourceText' "$hello_run_log" >/dev/null; then
  printf 'hello source run should use the promoted nativeImageSourceText cache before reporting a miss\n' >&2
  exit 1
fi
if grep -E '\[claspc-cache\] (build-plan|decl-module) ' "$hello_run_log" >/dev/null; then
  printf 'hello source run should not invoke granular native-image planning when promoted source-export is available\n' >&2
  exit 1
fi

(
  cd "$project_root"
  timeout "$timeout_secs" env XDG_CACHE_HOME="$test_root/task-workspace-harness-cache" CLASP_PROJECT_ROOT="$project_root" CLASP_NATIVE_TRACE_CACHE=1 \
    "$claspc_bin" native-image examples/swarm-native/TaskWorkspaceRuntimeHarness.clasp -o "$task_workspace_harness_image" \
    >/dev/null 2>"$task_workspace_harness_log"
)

[[ -s "$task_workspace_harness_image" ]]
grep -F '[claspc-cache] source-export promoted hit export=nativeImageProjectText key=' "$task_workspace_harness_log" >/dev/null

printf 'test-promoted-source-export-cache: ok\n'
