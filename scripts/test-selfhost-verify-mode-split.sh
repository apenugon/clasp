#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
bash_bin="$(command -v bash)"

cleanup() {
  rm -rf "$test_root"
}

trap cleanup EXIT

mkdir -p "$test_root/bin" "$test_root/src/scripts" "$test_root/src"
cp "$project_root/src/scripts/verify.sh" "$test_root/src/scripts/verify.sh"
cp "$project_root/src/scripts/run-native-tool.sh" "$test_root/src/scripts/run-native-tool.sh"

cat > "$test_root/bin/fake-claspc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

log_path="${CLASP_TEST_FAKE_CLASPC_LOG:?}"
printf '%s\n' "$*" >> "$log_path"

if [[ "$1" == "--json" && "$2" == "check" ]]; then
  printf '{"status":"ok","command":"check","input":"%s"}\n' "$3"
  exit 0
fi

if [[ "$1" != "exec-image" ]]; then
  printf 'unsupported fake-claspc invocation: %s\n' "$*" >&2
  exit 1
fi

image_path="$2"
export_name="$3"
output_path="${@: -1}"

case "$export_name" in
  main)
    printf '{"snapshot":"ok"}\n' > "$output_path"
    ;;
  nativeProjectText)
    printf 'native ir\n' > "$output_path"
    ;;
  nativeImageProjectBuildPlanText)
    cat > "$output_path" <<'PLAN'
Main
-- CLASP_NATIVE_IMAGE_PLAN_FIELD --
["main"]
-- CLASP_NATIVE_IMAGE_PLAN_FIELD --
[{"name":"main"}]
-- CLASP_NATIVE_IMAGE_PLAN_FIELD --
{"abi":"ok"}
-- CLASP_NATIVE_IMAGE_PLAN_FIELD --
{"runtime":"ok"}
-- CLASP_NATIVE_IMAGE_PLAN_FIELD --
{"compatibility":"ok"}
-- CLASP_NATIVE_IMAGE_PLAN_FIELD --
[]
-- CLASP_NATIVE_IMAGE_PLAN_FIELD --
ctx
-- CLASP_NATIVE_IMAGE_DECL_PLAN_FIELD --
Main
-- CLASP_NATIVE_IMAGE_DECL_MODULE_FIELD --
main
-- CLASP_NATIVE_IMAGE_DECL_MODULE_FIELD --
iface-main
PLAN
    ;;
  nativeImageProjectModuleDeclsText)
    printf '[{"kind":"global","name":"main"}]\n' > "$output_path"
    ;;
  checkProjectText)
    printf 'checked project\n' > "$output_path"
    ;;
  checkCoreProjectText)
    printf '{"checked":"core"}\n' > "$output_path"
    ;;
  compileProjectText)
    printf 'compiled project\n' > "$output_path"
    ;;
  checkEntrypoint|explainEntrypoint|compileEntrypoint|nativeEntrypoint)
    printf '%s output\n' "$export_name" > "$output_path"
    ;;
  nativeImageEntrypoint)
    printf '{"entrypoint":"native-image"}\n' > "$output_path"
    ;;
  *)
    printf 'unexpected export: %s\n' "$export_name" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$test_root/bin/fake-claspc"

printf '{"image":"rebuilt"}\n' > "$test_root/src/embedded.native.image.json"
printf '{"image":"rebuilt"}\n' > "$test_root/src/embedded.compiler.native.image.json"

fast_log="$test_root/fake-fast.log"
IN_NIX_SHELL=1 \
CLASP_PROJECT_ROOT="$test_root" \
CLASPC_BIN="$test_root/bin/fake-claspc" \
CLASP_TEST_FAKE_CLASPC_LOG="$fast_log" \
"$bash_bin" "$test_root/src/scripts/verify.sh" >/dev/null

grep -F 'exec-image '"$test_root"'/src/embedded.compiler.native.image.json checkProjectText --project-entry='"$test_root"'/src/native-verify/fast-project/Main.clasp' "$fast_log" >/dev/null
if grep -F 'exec-image '"$test_root"'/src/embedded.native.image.json main' "$fast_log" >/dev/null; then
  printf 'fast hosted verify unexpectedly executed the broad promoted snapshot\n' >&2
  exit 1
fi
if grep -F 'nativeImageProject' "$fast_log" >/dev/null; then
  printf 'fast hosted verify unexpectedly rebuilt the native image\n' >&2
  exit 1
fi
if grep -F -- '--json check '"$test_root"'/src/CompilerMain.clasp' "$fast_log" >/dev/null; then
  printf 'fast hosted verify unexpectedly executed the direct compiler check\n' >&2
  exit 1
fi

full_log="$test_root/fake-full.log"
IN_NIX_SHELL=1 \
CLASP_PROJECT_ROOT="$test_root" \
CLASPC_BIN="$test_root/bin/fake-claspc" \
CLASP_TEST_FAKE_CLASPC_LOG="$full_log" \
CLASP_NATIVE_VERIFY_MODE=full \
"$bash_bin" "$test_root/src/scripts/verify.sh" >/dev/null

grep -F 'exec-image '"$test_root"'/src/embedded.native.image.json nativeImageProjectBuildPlanText' "$full_log" >/dev/null
grep -F 'exec-image '"$test_root"'/src/embedded.compiler.native.image.json nativeImageProjectModuleDeclsText --project-entry='"$test_root"'/src/Main.clasp Main' "$full_log" >/dev/null
