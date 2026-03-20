#!/usr/bin/env bash
set -euo pipefail

project_root="${CLASP_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
compiler_root="$project_root/compiler/hosted"
stage1_native_path="$compiler_root/stage1.native.image.json"
stage1_verify_ir_path="$compiler_root/stage1.verify.ir"
stage1_verify_native_path="$compiler_root/stage1.verify.native.image.json"
verify_root="$compiler_root/native-verify"

cleanup() {
  rm -rf "$verify_root"
  rm -f "$stage1_verify_ir_path" "$stage1_verify_native_path"
}

trap cleanup EXIT

run_native_export() {
  bash "$project_root/compiler/hosted/scripts/run-native-tool.sh" "$@"
}

run_verify() {
  cd "$project_root"
  run_native_export "$stage1_native_path" nativeProjectText "--project-entry=$project_root/compiler/hosted/Main.clasp" "$stage1_verify_ir_path"
  run_native_export "$stage1_native_path" nativeImageProjectText "--project-entry=$project_root/compiler/hosted/Main.clasp" "$stage1_verify_native_path"
  cmp -s "$stage1_native_path" "$stage1_verify_native_path"
  mkdir -p "$verify_root"

  run_native_export "$stage1_native_path" main "$verify_root/promoted.snapshot.json"
  run_native_export "$stage1_verify_native_path" main "$verify_root/rebuilt.snapshot.json"
  cmp -s "$verify_root/promoted.snapshot.json" "$verify_root/rebuilt.snapshot.json"

  run_native_export "$stage1_native_path" checkEntrypoint "$verify_root/promoted.check.txt"
  run_native_export "$stage1_verify_native_path" checkEntrypoint "$verify_root/rebuilt.check.txt"
  cmp -s "$verify_root/promoted.check.txt" "$verify_root/rebuilt.check.txt"

  run_native_export "$stage1_native_path" explainEntrypoint "$verify_root/promoted.explain.txt"
  run_native_export "$stage1_verify_native_path" explainEntrypoint "$verify_root/rebuilt.explain.txt"
  cmp -s "$verify_root/promoted.explain.txt" "$verify_root/rebuilt.explain.txt"

  run_native_export "$stage1_native_path" compileEntrypoint "$verify_root/promoted.compile.mjs"
  run_native_export "$stage1_verify_native_path" compileEntrypoint "$verify_root/rebuilt.compile.mjs"
  cmp -s "$verify_root/promoted.compile.mjs" "$verify_root/rebuilt.compile.mjs"

  run_native_export "$stage1_native_path" nativeEntrypoint "$verify_root/promoted.native.ir"
  run_native_export "$stage1_verify_native_path" nativeEntrypoint "$verify_root/rebuilt.native.ir"
  cmp -s "$verify_root/promoted.native.ir" "$verify_root/rebuilt.native.ir"

  run_native_export "$stage1_native_path" nativeImageEntrypoint "$verify_root/promoted.native.image.json"
  run_native_export "$stage1_verify_native_path" nativeImageEntrypoint "$verify_root/rebuilt.native.image.json"
  cmp -s "$verify_root/promoted.native.image.json" "$verify_root/rebuilt.native.image.json"

  run_native_export "$stage1_native_path" checkProjectText "--project-entry=$project_root/compiler/hosted/Main.clasp" "$verify_root/promoted.source.check.txt"
  run_native_export "$stage1_verify_native_path" checkProjectText "--project-entry=$project_root/compiler/hosted/Main.clasp" "$verify_root/rebuilt.source.check.txt"
  cmp -s "$verify_root/promoted.source.check.txt" "$verify_root/rebuilt.source.check.txt"

  run_native_export "$stage1_native_path" checkCoreProjectText "--project-entry=$project_root/compiler/hosted/Main.clasp" "$verify_root/promoted.source.check-core.json"
  run_native_export "$stage1_verify_native_path" checkCoreProjectText "--project-entry=$project_root/compiler/hosted/Main.clasp" "$verify_root/rebuilt.source.check-core.json"
  cmp -s "$verify_root/promoted.source.check-core.json" "$verify_root/rebuilt.source.check-core.json"

  run_native_export "$stage1_native_path" compileProjectText "--project-entry=$project_root/compiler/hosted/Main.clasp" "$verify_root/promoted.source.compile.mjs"
  run_native_export "$stage1_verify_native_path" compileProjectText "--project-entry=$project_root/compiler/hosted/Main.clasp" "$verify_root/rebuilt.source.compile.mjs"
  cmp -s "$verify_root/promoted.source.compile.mjs" "$verify_root/rebuilt.source.compile.mjs"

  run_native_export "$stage1_native_path" nativeProjectText "--project-entry=$project_root/compiler/hosted/Main.clasp" "$verify_root/promoted.source.native.ir"
  run_native_export "$stage1_verify_native_path" nativeProjectText "--project-entry=$project_root/compiler/hosted/Main.clasp" "$verify_root/rebuilt.source.native.ir"
  cmp -s "$verify_root/promoted.source.native.ir" "$verify_root/rebuilt.source.native.ir"

  run_native_export "$stage1_native_path" nativeImageProjectText "--project-entry=$project_root/compiler/hosted/Main.clasp" "$verify_root/promoted.source.native.image.json"
  run_native_export "$stage1_verify_native_path" nativeImageProjectText "--project-entry=$project_root/compiler/hosted/Main.clasp" "$verify_root/rebuilt.source.native.image.json"
  cmp -s "$verify_root/promoted.source.native.image.json" "$verify_root/rebuilt.source.native.image.json"

  printf '%s\n' '{"nativeSeedMatchesPromoted":true,"nativeCheckMatchesPromoted":true,"nativeExplainMatchesPromoted":true,"nativeCompileMatchesPromoted":true,"nativeIrMatchesPromoted":true,"nativeImageMatchesPromoted":true,"nativeSourceCheckMatchesPromoted":true,"nativeSourceCheckCoreMatchesPromoted":true,"nativeSourceCompileMatchesPromoted":true,"nativeSourceIrMatchesPromoted":true,"nativeSourceImageMatchesPromoted":true}'
}

if [[ -n "${IN_NIX_SHELL:-}" ]]; then
  run_verify | tail -n 1 | grep -F '"nativeSeedMatchesPromoted":true,"nativeCheckMatchesPromoted":true,"nativeExplainMatchesPromoted":true,"nativeCompileMatchesPromoted":true,"nativeIrMatchesPromoted":true,"nativeImageMatchesPromoted":true,"nativeSourceCheckMatchesPromoted":true,"nativeSourceCheckCoreMatchesPromoted":true,"nativeSourceCompileMatchesPromoted":true,"nativeSourceIrMatchesPromoted":true,"nativeSourceImageMatchesPromoted":true'
else
  nix develop "$project_root" --command bash -lc "
    set -euo pipefail
    export CLASP_PROJECT_ROOT=\"$project_root\"
    bash compiler/hosted/scripts/verify.sh
  "
fi
