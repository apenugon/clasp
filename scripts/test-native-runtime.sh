#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
cc_bin="${CC:-cc}"
rustc_bin="${RUSTC:-rustc}"
rust_runtime_source="$project_root/runtime/native/clasp_runtime.rs"
rust_runtime_lib="$test_root/libclasp_runtime.a"

cleanup() {
  rm -rf "$test_root"
}

trap cleanup EXIT

ir_path="$test_root/durable-workflow.native.ir"
image_path="${ir_path%.*}.native.image.json"
harness_path="$test_root/test-native-image"
invalid_image_path="$test_root/invalid.native.image.json"
migrating_upgrade_path="$test_root/migrating-upgrade.native.image.json"
incompatible_upgrade_path="$test_root/incompatible-upgrade.native.image.json"
output_capture="$test_root/native-image-output.txt"

(
  cd "$project_root"
  cabal run -v0 claspc -- native examples/durable-workflow/Main.clasp -o "$ir_path" --compiler=bootstrap --json >/dev/null
)

[[ -f "$ir_path" ]]
[[ -f "$image_path" ]]

python3 - "$image_path" "$migrating_upgrade_path" "$incompatible_upgrade_path" <<'PY'
import json
from copy import deepcopy
import sys

source_path, migrating_output_path, incompatible_output_path = sys.argv[1], sys.argv[2], sys.argv[3]

with open(source_path, "r", encoding="utf-8") as handle:
    payload = json.load(handle)

original_fingerprint = payload["compatibility"]["interfaceFingerprint"]

migrating_payload = deepcopy(payload)
migrating_payload["compatibility"]["interfaceFingerprint"] = f"{original_fingerprint}-upgrade"
migrating_payload["compatibility"]["acceptedPreviousFingerprints"] = [original_fingerprint]
migrating_payload["compatibility"]["migration"]["strategy"] = "state-handoff"

with open(migrating_output_path, "w", encoding="utf-8") as handle:
    json.dump(migrating_payload, handle, separators=(",", ":"))
    handle.write("\n")

incompatible_payload = deepcopy(migrating_payload)
incompatible_payload["compatibility"]["acceptedPreviousFingerprints"] = ["native-compat:incompatible"]

with open(incompatible_output_path, "w", encoding="utf-8") as handle:
    json.dump(incompatible_payload, handle, separators=(",", ":"))
    handle.write("\n")
PY

"$rustc_bin" \
  --edition=2021 \
  --crate-type staticlib \
  -C panic=abort \
  "$rust_runtime_source" \
  -o "$rust_runtime_lib" >/dev/null

rust_native_libs="$(
  "$rustc_bin" \
    --edition=2021 \
    --crate-type staticlib \
    -C panic=abort \
    --print native-static-libs \
    "$rust_runtime_source" 2>&1 >/dev/null |
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
  -I"$project_root/runtime/native" \
  "$project_root/runtime/native/test_native_image.c" \
  "$rust_runtime_lib" \
  "${rust_link_args[@]}" \
  -o "$harness_path"

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

printf '%s\n' '{"format":"broken"}' >"$invalid_image_path"
if "$harness_path" "$invalid_image_path" >/dev/null 2>&1; then
  printf 'native image harness unexpectedly accepted an invalid image\n' >&2
  exit 1
fi
