#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

node - "$project_root" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");

const [projectRoot] = process.argv.slice(2);

function read(relativePath) {
  return fs.readFileSync(path.join(projectRoot, relativePath), "utf8");
}

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

const runtime = read("runtime/clasp_runtime.rs");
const header = read("runtime/clasp_runtime.h");
const workspace = read("examples/safe-workspace/Workspace.clasp");
const harness = read("examples/safe-workspace/SafeWorkspaceHarness.clasp");
const test = read("scripts/test-safe-workspace.sh");
const cleanupPlan = read("examples/swarm-native/GeneratedStateCleanupPlan.clasp");

assert(runtime.includes("fn workspace_path_size_bytes(path: &Path) -> Result<u128, String>"), "runtime should define recursive workspace size measurement");
assert(runtime.includes("fs::symlink_metadata(path)"), "runtime size measurement should inspect symlinks without following nested escapes");
assert(runtime.includes("metadata.file_type().is_dir() && !metadata.file_type().is_symlink()"), "runtime size measurement should only recurse into real directories");
assert(runtime.includes("fn workspace_path_size_mb(root: &str, relative: &str) -> Result<i64, String>"), "runtime should expose MB-rounded workspace size helper");
assert(runtime.includes("resolve_existing_workspace_path(root, relative)?"), "runtime size helper should stay root-confined");
assert(runtime.includes('pub unsafe extern "C" fn clasp_rt_workspace_path_size_mb'), "runtime should expose C ABI workspace size binding");
assert(runtime.includes('("workspacePathSizeMb", 2)'), "runtime dispatch should include workspacePathSizeMb");
assert(runtime.includes('| "workspacePathSizeMb"'), "runtime allowlist should include workspacePathSizeMb");
assert(header.includes("clasp_rt_workspace_path_size_mb"), "runtime header should expose workspace size binding");
assert(runtime.includes("fn workspace_list_tree("), "runtime should define bounded recursive workspace listing");
assert(runtime.includes("workspace_limit_exceeded: workspaceListTree reached maxEntries"), "runtime recursive listing should fail closed at maxEntries");
assert(runtime.includes('pub unsafe extern "C" fn clasp_rt_workspace_list_tree'), "runtime should expose C ABI workspace tree binding");
assert(runtime.includes('("workspaceListTree", 4)'), "runtime dispatch should include workspaceListTree");
assert(runtime.includes('| "workspaceListTree"'), "runtime allowlist should include workspaceListTree");
assert(header.includes("clasp_rt_workspace_list_tree"), "runtime header should expose workspace tree binding");
assert(runtime.includes("fn workspace_search_text("), "runtime should define bounded root-confined workspace text search");
assert(runtime.includes("workspaceSearchText reached maxFiles"), "runtime workspace text search should fail closed at maxFiles");
assert(runtime.includes("workspaceSearchText reached maxMatches"), "runtime workspace text search should fail closed at maxMatches");
assert(runtime.includes('pub unsafe extern "C" fn clasp_rt_workspace_search_text'), "runtime should expose C ABI workspace text search binding");
assert(runtime.includes('("workspaceSearchText", 7)'), "runtime dispatch should include workspaceSearchText");
assert(runtime.includes('| "workspaceSearchText"'), "runtime allowlist should include workspaceSearchText");
assert(header.includes("clasp_rt_workspace_search_text"), "runtime header should expose workspace search binding");
assert(runtime.includes("fn workspace_replace_text("), "runtime should define bounded root-confined workspace text replacement");
assert(runtime.includes("workspace_replace_missing: findText was not found"), "runtime workspace text replacement should report missing targets");
assert(runtime.includes("workspaceReplaceText output exceeds maxFileBytes"), "runtime workspace text replacement should cap output size");
assert(runtime.includes('pub unsafe extern "C" fn clasp_rt_workspace_replace_text'), "runtime should expose C ABI workspace text replacement binding");
assert(runtime.includes('("workspaceReplaceText", 6)'), "runtime dispatch should include workspaceReplaceText");
assert(runtime.includes('| "workspaceReplaceText"'), "runtime allowlist should include workspaceReplaceText");
assert(header.includes("clasp_rt_workspace_replace_text"), "runtime header should expose workspace replacement binding");

assert(workspace.includes('foreign workspacePathSizeMbRaw : Str -> Str -> Result Int = "workspacePathSizeMb"'), "safe workspace wrapper should declare raw workspace size binding");
assert(workspace.includes("workspacePathSizeMb : Str -> Str -> Result Int"), "safe workspace wrapper should expose typed workspace size helper");
assert(workspace.includes('foreign workspaceListTreeRaw : Str -> Str -> Int -> Int -> Result [Str] = "workspaceListTree"'), "safe workspace wrapper should declare raw workspace tree binding");
assert(workspace.includes("workspaceListTree : Str -> Str -> Int -> Int -> Result [Str]"), "safe workspace wrapper should expose typed workspace tree helper");
assert(workspace.includes('foreign workspaceSearchTextRaw : Str -> Str -> Str -> Int -> Int -> Int -> Int -> Result [Str] = "workspaceSearchText"'), "safe workspace wrapper should declare raw workspace search binding");
assert(workspace.includes("workspaceSearchTextBounded : Str -> Str -> Str -> Int -> Int -> Int -> Int -> Result [Str]"), "safe workspace wrapper should expose bounded workspace search helper");
assert(workspace.includes("workspaceSearchText : Str -> Str -> Str -> Result [Str]"), "safe workspace wrapper should expose ergonomic workspace search helper");
assert(workspace.includes('foreign workspaceReplaceTextRaw : Str -> Str -> Str -> Str -> Int -> Int -> Result Int = "workspaceReplaceText"'), "safe workspace wrapper should declare raw workspace replacement binding");
assert(workspace.includes("workspaceReplaceTextBounded : Str -> Str -> Str -> Str -> Int -> Int -> Result Int"), "safe workspace wrapper should expose bounded workspace replacement helper");
assert(workspace.includes("workspaceReplaceText : Str -> Str -> Str -> Str -> Result Int"), "safe workspace wrapper should expose ergonomic workspace replacement helper");
assert(harness.includes('foreign workspacePathSizeMbRaw : Str -> Str -> Result Int = "workspacePathSizeMb"'), "safe workspace harness should declare raw workspace size binding");
assert(harness.includes("workspacePathSizeMb : Str -> Str -> Result Int"), "safe workspace harness should expose workspace size helper");
assert(harness.includes('foreign workspaceListTreeRaw : Str -> Str -> Int -> Int -> Result [Str] = "workspaceListTree"'), "safe workspace harness should declare raw workspace tree binding");
assert(harness.includes("workspaceListTree : Str -> Str -> Int -> Int -> Result [Str]"), "safe workspace harness should expose workspace tree helper");
assert(harness.includes('foreign workspaceSearchTextRaw : Str -> Str -> Str -> Int -> Int -> Int -> Int -> Result [Str] = "workspaceSearchText"'), "safe workspace harness should declare raw workspace search binding");
assert(harness.includes("workspaceSearchTextBounded : Str -> Str -> Str -> Int -> Int -> Int -> Int -> Result [Str]"), "safe workspace harness should expose bounded workspace search helper");
assert(harness.includes('foreign workspaceReplaceTextRaw : Str -> Str -> Str -> Str -> Int -> Int -> Result Int = "workspaceReplaceText"'), "safe workspace harness should declare raw workspace replacement binding");
assert(harness.includes("workspaceReplaceTextBounded : Str -> Str -> Str -> Str -> Int -> Int -> Result Int"), "safe workspace harness should expose bounded workspace replacement helper");
assert(harness.includes("treeListing : Str"), "safe workspace report should include recursive tree listing");
assert(harness.includes("searchListing : Str"), "safe workspace report should include text search listing");
assert(harness.includes("replaceCount : Int"), "safe workspace report should include replacement count");
assert(harness.includes("limitedReplaceResult : Str"), "safe workspace report should include replacement limit result");
assert(harness.includes("nestedSizeMb : Int"), "safe workspace report should include nested size");
assert(harness.includes("rootSizeMb : Int"), "safe workspace report should include root size");
assert(harness.includes("resultIntOrNegativeOne"), "safe workspace harness should convert failed size reads into sentinel values");
assert(harness.includes('workspacePathSizeMb workspaceRoot "nested"'), "safe workspace harness should measure nested path");
assert(harness.includes('workspacePathSizeMb workspaceRoot "."'), "safe workspace harness should measure root path");
assert(test.includes("nested size should be rounded up"), "safe workspace runtime test should assert rounded nested size");
assert(test.includes("root size should include nested content"), "safe workspace runtime test should assert root size includes nested content");
assert(test.includes("tree listing should include nested files"), "safe workspace runtime test should assert recursive tree listing");
assert(test.includes("bounded tree listing"), "safe workspace runtime test should assert tree listing limits");
assert(test.includes("workspace search should include matching source line"), "safe workspace runtime test should assert text search matches");
assert(test.includes("empty search needle"), "safe workspace runtime test should assert text search rejects empty needles");
assert(test.includes("workspace replace should report the number of exact replacements"), "safe workspace runtime test should assert replacement count");
assert(test.includes("replacement count limit"), "safe workspace runtime test should assert replacement count limits");

assert(cleanupPlan.includes('foreign workspacePathSizeMbRaw : Str -> Str -> Result Int = "workspacePathSizeMb"'), "cleanup plan should use root-confined workspace size host boundary");
assert(cleanupPlan.includes("record GeneratedCleanupProjection ="), "cleanup plan should expose cleanup projection record");
assert(cleanupPlan.includes("generatedCleanupProjectionFor : Str -> Bool -> [GeneratedCleanupTarget] -> [GeneratedExternalLog] -> GeneratedCleanupDisk -> GeneratedCleanupProjection"), "cleanup plan should compute cleanup projection");
assert(cleanupPlan.includes("generatedCleanupTargetsSizeMb"), "cleanup plan should total reclaimable repo targets");
assert(cleanupPlan.includes("cleanupCanSatisfyGuard"), "cleanup plan should project guard sufficiency");

console.log("safe-workspace-static-ok");
NODE
