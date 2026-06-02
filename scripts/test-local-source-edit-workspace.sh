#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
timeout_secs="${CLASP_LOCAL_SOURCE_EDIT_WORKSPACE_TIMEOUT_SECS:-180}"

export CLASP_NATIVE_JOBS_MAX="${CLASP_NATIVE_JOBS_MAX:-1}"
export CLASP_NATIVE_BUNDLE_JOBS="${CLASP_NATIVE_BUNDLE_JOBS:-1}"
export CLASP_NATIVE_IMAGE_SECTION_JOBS="${CLASP_NATIVE_IMAGE_SECTION_JOBS:-1}"
export CLASP_NATIVE_IMAGE_SECTION_JOBS_MAX="${CLASP_NATIVE_IMAGE_SECTION_JOBS_MAX:-1}"
export CLASP_NATIVE_IMAGE_MODULE_DECL_FRESH_PROCESS="${CLASP_NATIVE_IMAGE_MODULE_DECL_FRESH_PROCESS:-1}"
export CLASP_NATIVE_IMAGE_MODULE_DECL_CHUNK_SIZE="${CLASP_NATIVE_IMAGE_MODULE_DECL_CHUNK_SIZE:-1}"

if ! [[ "$timeout_secs" =~ ^[0-9]+$ ]] || (( timeout_secs < 1 )); then
  printf 'CLASP_LOCAL_SOURCE_EDIT_WORKSPACE_TIMEOUT_SECS must be a positive integer\n' >&2
  exit 1
fi

mkdir -p "$tmp_root"
test_root="$(mktemp -d "$tmp_root/test-local-source-edit-workspace.XXXXXX")"

cleanup() {
  if [[ "${CLASP_TEST_KEEP_TMP:-}" == "1" ]]; then
    printf 'kept test root: %s\n' "$test_root" >&2
  else
    rm -rf "$test_root" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

claspc_bin="$(
  CLASP_CLASPC= CLASPC_BIN= CLASP_PROJECT_ROOT="$project_root" \
    "$project_root/scripts/resolve-claspc.sh"
)"
harness_path="$project_root/examples/swarm-native/LocalSourceEditHarness.clasp"
source_path="$project_root/examples/swarm-native/LocalSourceEdit.clasp"

timeout "$timeout_secs" "$claspc_bin" --json check "$harness_path" | grep -F '"status":"ok"' >/dev/null

node - "$source_path" "$harness_path" <<'NODE'
const fs = require("node:fs");

const [sourcePath, harnessPath] = process.argv.slice(2);
const source = fs.readFileSync(sourcePath, "utf8");
const harness = fs.readFileSync(harnessPath, "utf8");

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

assert(source.includes('foreign localSourceEditWorkspaceReadFileRaw : Str -> Str -> Result Str = "workspaceReadFile"'), "LocalSourceEdit should bind workspaceReadFile");
assert(source.includes('foreign localSourceEditWorkspaceWriteFileRaw : Str -> Str -> Str -> Result Str = "workspaceWriteFile"'), "LocalSourceEdit should bind workspaceWriteFile");
assert(source.includes('foreign localSourceEditWorkspaceMkdirAllRaw : Str -> Str -> Result Str = "workspaceMkdirAll"'), "LocalSourceEdit should bind workspaceMkdirAll");
assert(source.includes('foreign localSourceEditWorkspaceReplaceTextRaw : Str -> Str -> Str -> Str -> Int -> Int -> Result Int = "workspaceReplaceText"'), "LocalSourceEdit should bind workspaceReplaceText");
assert(!source.includes("readFile path"), "LocalSourceEdit source-edit path should not use raw readFile helper");
assert(!source.includes("writeFile path"), "LocalSourceEdit source-edit path should not use raw writeFile helper");
assert(!source.includes("mkdirAll path"), "LocalSourceEdit source-edit path should not use raw mkdirAll helper");
assert(!source.includes("pathJoin [workspaceRoot, target]"), "LocalSourceEdit should not rebuild absolute target paths for source edits");
assert(source.includes("localSourceEditWorkspaceReadTextOr workspaceRoot target"), "source-edit reads should use workspace-relative targets");
assert(source.includes('localSourceEditWorkspaceWriteTextOrMessage workspaceRoot "notes/direct-source-edit.txt"'), "source-edit proof writes should use workspace-relative targets");
assert(source.includes('standaloneSwarmDirectSourceEditManifestPath = "notes/direct-source-edit-manifest.json"'), "source-edit should define workspace manifest path");
assert(source.includes("standaloneSwarmDirectSourceEditManifestJson : Str -> [Str] -> Str"), "source-edit should render a workspace manifest");
assert(source.includes("sourceEditManifestTargetsPresent : Str -> [Str] -> Bool"), "source-edit verifier should check manifest targets");
assert(source.includes("standaloneSwarmDirectSourceEditIssueTexts : Str -> Str -> Str -> [Str]"), "source-edit verifier should expose structured issue text");
assert(source.includes("standaloneSwarmDirectSourceEditRepairHints : Str -> Str -> Str -> [Str]"), "source-edit verifier should expose structured repair hints");
assert(source.includes("standalone-source-edit:planned-patch-replacement-missing"), "source-edit verifier should report missing patch replacements");
assert(source.includes("standalone-source-edit:manifest-target-fingerprints-missing"), "source-edit verifier should report manifest fingerprint mismatches");
assert(source.includes("standalone-source-edit-repair:regenerate-direct-source-edit-manifest"), "source-edit verifier should suggest manifest regeneration");
assert(source.includes("localSourceEditWorkspaceReplaceTextOrMessage workspaceRoot target patch.findText patch.replaceText"), "source-edit patches should use workspace-relative exact replacement");
assert(source.includes("localSourceEditWorkspaceEnsureDirOrMessage workspaceRoot (pathDirname target)"), "source-edit mkdir should use workspace-relative parent dirs");
assert(source.includes('"workspaceConfinedWrite=true"'), "proof should record workspace-confined writes");
assert(source.includes('"workspaceFingerprintAlgorithm=textFingerprint64Hex"'), "proof should record workspace manifest algorithm");
assert(source.includes('"workspaceApi=workspaceReadFile/workspaceReplaceText/workspaceWriteFile/workspaceMkdirAll"'), "proof should record workspace API use");
assert(source.includes('"sourceEditPrimitive=workspaceReplaceText"'), "proof should record exact replacement primitive");
assert(source.includes('sourceEditManifestTargetsPresent workspaceRoot targets'), "verifier should require manifest target fingerprints");
assert(source.includes('standaloneSwarmDirectSourceEditProofMetadataPresent proof (length targets) (length patches)'), "verifier should use the shared proof metadata helper");
assert(source.includes('localSourceEditTextIncludes proof "workspaceConfinedWrite=true"'), "verifier should require workspace confinement proof");
assert(source.includes('localSourceEditTextIncludes proof "workspaceFingerprintAlgorithm=textFingerprint64Hex"'), "verifier should require workspace manifest algorithm proof");
assert(source.includes('localSourceEditTextIncludes proof "workspaceApi=workspaceReadFile/workspaceReplaceText/workspaceWriteFile/workspaceMkdirAll"'), "verifier should require workspace API proof");
assert(source.includes('localSourceEditTextIncludes proof "sourceEditPrimitive=workspaceReplaceText"'), "verifier should require replacement primitive proof");

assert(harness.includes('writeStandaloneSwarmDirectSourceEdit workspaceRoot "standalone-swarm"'), "harness should exercise source edit write path");
assert(harness.includes('standaloneSwarmDirectSourceEditPresent workspaceRoot "standalone-swarm"'), "harness should exercise source edit verifier path");
assert(harness.includes("proofHasWorkspaceReplaceText"), "harness should report workspace replacement proof");
assert(harness.includes('harnessWorkspaceWriteFileRaw workspaceRoot "../outside.txt" "leaked"'), "harness should include a parent-escape probe");
assert(harness.includes('parentEscapeBlocked = harnessTextIncludes parentEscape "ERR:workspace_path_escape"'), "harness should assert parent escapes are blocked");
NODE

printf '%s\n' "local-source-edit-workspace-ok"
