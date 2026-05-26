#!/usr/bin/env bash
set -euo pipefail

project_root="${CLASP_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

if [[ -f "$project_root/scripts/normalize-tmpdir.sh" ]]; then
  source "$project_root/scripts/normalize-tmpdir.sh"
fi

cd "$project_root"

export CLASP_PROJECT_ROOT="$project_root"
export CLASP_NATIVE_BUNDLE_JOBS="${CLASP_NATIVE_BUNDLE_JOBS:-1}"
export CLASP_NATIVE_IMAGE_SECTION_JOBS="${CLASP_NATIVE_IMAGE_SECTION_JOBS:-1}"
export CLASP_NATIVE_JOBS_MAX="${CLASP_NATIVE_JOBS_MAX:-1}"
export CLASP_NATIVE_IMAGE_SECTION_JOBS_MAX="${CLASP_NATIVE_IMAGE_SECTION_JOBS_MAX:-1}"
export CLASP_NATIVE_DISABLE_EXPORT_HOST="${CLASP_NATIVE_DISABLE_EXPORT_HOST:-1}"
export CLASP_NATIVE_IMAGE_MODULE_DECL_FRESH_PROCESS="${CLASP_NATIVE_IMAGE_MODULE_DECL_FRESH_PROCESS:-1}"

claspc_bin="$(env -u CLASP_CLASPC -u CLASPC_BIN "$project_root/scripts/resolve-claspc.sh")"
tmp_compiler="$(mktemp -p "$project_root/src" .stage1.compiler.native.image.json.XXXXXX)"
tmp_promoted="$(mktemp -p "$project_root/src" .embedded.native.image.json.XXXXXX)"

cleanup() {
  rm -f "$tmp_compiler" "$tmp_promoted"
}

trap cleanup EXIT

validate_image() {
  node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$1" >/dev/null
}

"$claspc_bin" --json native-image "$project_root/src/CompilerMain.clasp" -o "$tmp_compiler"
validate_image "$tmp_compiler"
mv "$tmp_compiler" "$project_root/src/stage1.compiler.native.image.json"
cp "$project_root/src/stage1.compiler.native.image.json" "$project_root/src/embedded.compiler.native.image.json"

"$claspc_bin" --json native-image "$project_root/src/Main.clasp" -o "$tmp_promoted"
validate_image "$tmp_promoted"
mv "$tmp_promoted" "$project_root/src/embedded.native.image.json"

env -u CLASP_CLASPC -u CLASPC_BIN "$project_root/scripts/resolve-claspc.sh" >/dev/null
node "$project_root/scripts/generate-promoted-module-summary-cache.mjs"
node "$project_root/scripts/generate-promoted-source-export-cache.mjs" --refresh-native-images
node "$project_root/scripts/check-promoted-native-image-exports.mjs"
