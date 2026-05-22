#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
mkdir -p "$tmp_root"
test_root="$(mktemp -d "$tmp_root/test-native-runtime-smoke.XXXXXX")"
cc_bin="${CC:-cc}"
cargo_bin="${CARGO:-cargo}"
rustc_bin="${RUSTC:-rustc}"
runtime_target_dir="$project_root/runtime/target"
rust_runtime_lib="$runtime_target_dir/debug/libclasp_runtime.a"
fallback_rust_runtime_lib="$project_root/libclasp_runtime.a"
nix_reentry="${CLASP_NATIVE_RUNTIME_NIX_REENTRY:-0}"

export CARGO_TARGET_DIR="$runtime_target_dir"

cleanup() {
  rm -rf "$test_root"
}

trap cleanup EXIT

native_runtime_artifacts_ready() {
  if [[ ! -x "$project_root/runtime/target/debug/claspc" ]]; then
    return 1
  fi

  if [[ -f "$rust_runtime_lib" ]]; then
    return 0
  fi

  [[ -f "$fallback_rust_runtime_lib" ]]
}

maybe_enter_nix_shell() {
  if command -v "$rustc_bin" >/dev/null 2>&1 && command -v "$cargo_bin" >/dev/null 2>&1; then
    return 0
  fi

  if native_runtime_artifacts_ready; then
    return 0
  fi

  if [[ "$nix_reentry" == "1" ]]; then
    return 0
  fi

  if ! command -v nix >/dev/null 2>&1; then
    return 0
  fi

  nix develop "path:$project_root" --command bash -lc "
    set -euo pipefail
    cd \"$project_root\"
    export CLASP_PROJECT_ROOT=\"$project_root\"
    export CLASP_NATIVE_RUNTIME_NIX_REENTRY=1
    export CARGO_TARGET_DIR=\"$runtime_target_dir\"
    bash scripts/test-native-runtime-smoke.sh
  "
  exit 0
}

maybe_enter_nix_shell

if [[ ! -f "$rust_runtime_lib" && -f "$fallback_rust_runtime_lib" ]]; then
  rust_runtime_lib="$fallback_rust_runtime_lib"
fi

if [[ ! -f "$rust_runtime_lib" ]]; then
  if ! command -v "$cargo_bin" >/dev/null 2>&1; then
    printf 'native runtime library missing and cargo is unavailable\n' >&2
    exit 1
  fi
  cargo build --quiet --manifest-path "$project_root/runtime/Cargo.toml" --lib >/dev/null
fi
[[ -f "$rust_runtime_lib" ]]

claspc_bin="$(env -u CLASP_CLASPC -u CLASPC_BIN CLASP_PROJECT_ROOT="$project_root" "$project_root/scripts/resolve-claspc.sh")"
hello_image_path="$test_root/hello.native.image.json"
hello_structured_image_path="$test_root/hello.structured.native.image.json"
interpreter_harness_path="$test_root/test-native-interpreter"
interpreter_output_capture="$test_root/native-interpreter-output.txt"

"$claspc_bin" native-image "$project_root/examples/hello.clasp" -o "$hello_image_path" --json >/dev/null

node - "$hello_image_path" "$hello_structured_image_path" <<'NODE'
const fs = require("fs");

const [inputPath, outputPath] = process.argv.slice(2);
const image = JSON.parse(fs.readFileSync(inputPath, "utf8"));
if (image.format !== "clasp-native-image-v1") {
  throw new Error(`unexpected native image format: ${image.format}`);
}
if (image.module !== "Main") {
  throw new Error(`unexpected native image module: ${image.module}`);
}
for (const decl of image.decls ?? []) {
  delete decl.bodyText;
}
fs.writeFileSync(outputPath, `${JSON.stringify(image)}\n`, "utf8");
NODE

rust_link_args=()
if command -v "$cargo_bin" >/dev/null 2>&1; then
  rust_native_libs="$(
    cargo rustc --quiet --manifest-path "$project_root/runtime/Cargo.toml" --lib -- --print native-static-libs 2>&1 >/dev/null |
      sed -n 's/^note: native-static-libs: //p' |
      tail -n 1
  )"
  if [[ -n "$rust_native_libs" ]]; then
    read -r -a rust_link_args <<<"$rust_native_libs"
  fi
else
  rust_link_args=(-lm)
fi

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

"$interpreter_harness_path" "$hello_structured_image_path" >"$interpreter_output_capture"
grep -F "interpreted_call[main]=Hello from Clasp" "$interpreter_output_capture" >/dev/null

printf 'test-native-runtime-smoke: ok\n'
