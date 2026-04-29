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

cat > "$test_root/src/Main.clasp" <<'EOF'
module Main

import Helper

main : Str
main = helper "seed"
EOF

cat > "$test_root/src/Helper.clasp" <<'EOF'
module Helper

helper : Str -> Str
helper value = "hello"
EOF

cat > "$test_root/bin/fake-claspc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

log_path="${CLASP_TEST_FAKE_CLASPC_LOG:?}"
project_root="${CLASP_PROJECT_ROOT:?}"
helper_path="$project_root/src/Helper.clasp"

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

helper_annotation="$(grep -E '^helper :' "$helper_path" | sed 's/^helper : //')"
helper_body="$(grep -E '^helper value =' "$helper_path" | sed 's/^helper value = //')"
helper_iface="iface-helper-v1"
if [[ "$helper_annotation" != "Str -> Str" ]]; then
  helper_iface="iface-helper-v2"
fi

case "$export_name" in
  checkProjectText)
    printf 'checked project\n' > "$output_path"
    ;;
  checkCoreProjectText)
    printf '{"checked":"core"}\n' > "$output_path"
    ;;
  compileProjectText)
    printf 'compiled project\n' > "$output_path"
    ;;
  nativeProjectText)
    printf 'native ir\n' > "$output_path"
    ;;
  nativeImageProjectBuildPlanText)
    cat > "$output_path" <<PLAN
Main
-- CLASP_NATIVE_IMAGE_PLAN_FIELD --
["helper","main"]
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
Helper
-- CLASP_NATIVE_IMAGE_DECL_MODULE_FIELD --
helper
-- CLASP_NATIVE_IMAGE_DECL_MODULE_FIELD --
$helper_iface
-- CLASP_NATIVE_IMAGE_DECL_MODULE --
Main
-- CLASP_NATIVE_IMAGE_DECL_MODULE_FIELD --
main
-- CLASP_NATIVE_IMAGE_DECL_MODULE_FIELD --
iface-main-v1
PLAN
    ;;
  nativeImageProjectModuleDeclsText)
    module_name="$5"
    case "$module_name" in
      Helper)
        printf '[{"kind":"global","name":"helper","annotation":"%s","body":"%s"}]\n' "$helper_annotation" "$helper_body" > "$output_path"
        ;;
      Main)
        printf '[{"kind":"global","name":"main","body":"helper \\"seed\\""}]\n' > "$output_path"
        ;;
      *)
        printf 'unexpected module: %s\n' "$module_name" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    printf 'unexpected export: %s\n' "$export_name" >&2
    exit 1
    ;;
esac

if [[ "$image_path" == *"embedded.compiler.native.image.json" ]]; then
  printf 'rebuilt %s\n' "$export_name" >> "$log_path"
fi
EOF
chmod +x "$test_root/bin/fake-claspc"

printf '{"image":"promoted"}\n' > "$test_root/src/embedded.native.image.json"
printf '{"image":"compiler"}\n' > "$test_root/src/embedded.compiler.native.image.json"

run_one() {
  local log_path="$1"
  local output_path="$2"

  IN_NIX_SHELL=1 \
  CLASP_PROJECT_ROOT="$test_root" \
  CLASPC_BIN="$test_root/bin/fake-claspc" \
  CLASP_TEST_FAKE_CLASPC_LOG="$log_path" \
  CLASP_NATIVE_VERIFY_MODE=full \
  "$bash_bin" "$test_root/src/scripts/verify.sh" >"$output_path"
}

first_log="$test_root/full-first.log"
second_log="$test_root/full-second.log"
third_log="$test_root/full-third.log"
first_output="$test_root/full-first.output"
second_output="$test_root/full-second.output"
third_output="$test_root/full-third.output"

run_one "$first_log" "$first_output"

sed -i 's/"hello"/"hullo"/' "$test_root/src/Helper.clasp"
run_one "$second_log" "$second_output"
grep -F 'exec-image '"$test_root"'/src/embedded.compiler.native.image.json nativeImageProjectModuleDeclsText --project-entry='"$test_root"'/src/Main.clasp Helper' "$second_log" >/dev/null
if grep -F 'exec-image '"$test_root"'/src/embedded.compiler.native.image.json nativeImageProjectModuleDeclsText --project-entry='"$test_root"'/src/Main.clasp Main' "$second_log" >/dev/null; then
  printf 'body-only edit unexpectedly rebuilt Main module decls\n' >&2
  exit 1
fi
grep -F '"nativeSourceChangedModules":["Helper"]' "$second_output" >/dev/null

cat > "$test_root/src/Helper.clasp" <<'EOF'
module Helper

helper : Int -> Str
helper value = "hullo"
EOF
run_one "$third_log" "$third_output"
grep -F 'exec-image '"$test_root"'/src/embedded.compiler.native.image.json nativeImageProjectModuleDeclsText --project-entry='"$test_root"'/src/Main.clasp Helper' "$third_log" >/dev/null
grep -F 'exec-image '"$test_root"'/src/embedded.compiler.native.image.json nativeImageProjectModuleDeclsText --project-entry='"$test_root"'/src/Main.clasp Main' "$third_log" >/dev/null
grep -F '"nativeSourceChangedModules":["Helper","Main"]' "$third_output" >/dev/null
