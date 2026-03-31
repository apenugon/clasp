#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root=""
bash_bin="$(command -v bash)"
tmp_root="${TMPDIR:-/tmp}"

unset CLASP_VERIFY_IN_PROGRESS
unset CLASP_VERIFY_ACTIVE_ROOT
unset CLASP_VERIFY_LOCK_HELD
unset CLASP_VERIFY_TOPLEVEL_REENTRY
unset CLASP_VERIFY_USE_CURRENT_SHELL

if [[ ! -d "$tmp_root" || ! -w "$tmp_root" ]]; then
  tmp_root="/tmp"
fi
export TMPDIR="$tmp_root"

cleanup() {
  rm -rf "${test_root:-}"
}

trap cleanup EXIT

test_root="$(mktemp -d)"
mkdir -p "$test_root/bin" "$test_root/scripts" "$test_root/src/scripts" "$test_root/src"
cp "$project_root/scripts/verify-all.sh" "$test_root/scripts/verify-all.sh"
cp "$project_root/scripts/verify-fast.sh" "$test_root/scripts/verify-fast.sh"
cp "$project_root/scripts/verify-selfhost.sh" "$test_root/scripts/verify-selfhost.sh"
cp "$project_root/scripts/test-native-claspc.sh" "$test_root/scripts/test-native-claspc.sh"
cp "$project_root/src/scripts/verify.sh" "$test_root/src/scripts/verify.sh"
cp "$project_root/src/scripts/run-native-tool.sh" "$test_root/src/scripts/run-native-tool.sh"

grep -F 'bash scripts/test-selfhost.sh' "$test_root/scripts/verify-fast.sh" >/dev/null
grep -F 'bash scripts/test-native-claspc.sh' "$test_root/scripts/verify-fast.sh" >/dev/null
grep -F 'bash scripts/test-native-runtime.sh' "$test_root/scripts/verify-fast.sh" >/dev/null
grep -F 'export XDG_CACHE_HOME="$test_root/xdg-cache"' "$test_root/scripts/test-native-claspc.sh" >/dev/null
grep -F 'CLASP_VERIFY_PARALLEL_COMMANDS' "$test_root/scripts/verify-fast.sh" >/dev/null
grep -F 'CLASP_VERIFY_SEQUENTIAL_COMMANDS' "$test_root/scripts/verify-fast.sh" >/dev/null
grep -F 'bash scripts/test-selfhost.sh' "$test_root/scripts/verify-all.sh" >/dev/null
grep -F 'bash scripts/test-codex-loop.sh' "$test_root/scripts/verify-all.sh" >/dev/null
grep -F 'bash scripts/test-native-claspc.sh' "$test_root/scripts/verify-all.sh" >/dev/null
grep -F 'bash src/scripts/verify.sh' "$test_root/scripts/verify-all.sh" >/dev/null
grep -F 'CLASP_NATIVE_VERIFY_MODE=full bash src/scripts/verify.sh' "$test_root/scripts/verify-selfhost.sh" >/dev/null
grep -F 'bash scripts/test-selfhost-incremental-full-verify.sh' "$test_root/scripts/verify-selfhost.sh" >/dev/null
grep -F 'CLASP_VERIFY_PARALLEL_COMMANDS' "$test_root/scripts/verify-selfhost.sh" >/dev/null
grep -F 'CLASP_VERIFY_SEQUENTIAL_COMMANDS' "$test_root/scripts/verify-selfhost.sh" >/dev/null
grep -F 'verify_mode="${CLASP_NATIVE_VERIFY_MODE:-fast}"' "$test_root/src/scripts/verify.sh" >/dev/null
grep -F 'if [[ "$verify_mode" == "full" ]]; then' "$test_root/src/scripts/verify.sh" >/dev/null
grep -F '"promotedCompilerFixtureCheckExecutes":true' "$test_root/src/scripts/verify.sh" >/dev/null
grep -F 'acquire_verify_lock()' "$test_root/src/scripts/verify.sh" >/dev/null
grep -F 'nativeImageProjectBuildPlanText' "$test_root/src/scripts/verify.sh" >/dev/null
grep -F 'nativeImageProjectModuleDeclsText' "$test_root/src/scripts/verify.sh" >/dev/null
grep -F 'fast_verify_fixture_root="$verify_root/fast-project"' "$test_root/src/scripts/verify.sh" >/dev/null

cat > "$test_root/bin/nix" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "${XDG_CACHE_HOME:-}" > "${CLASP_TEST_NIX_ENV_CAPTURE:?}"
printf '%s\n' "${CLASP_TEST_NIX_MESSAGE:-error: cannot connect to socket at /nix/var/nix/daemon-socket/socket: Operation not permitted}" >&2
exit 1
EOF
chmod +x "$test_root/bin/nix"

fallback_capture="$test_root/fallback.txt"
env_capture="$test_root/nix-env.txt"
lock_capture="$test_root/lock-path.txt"
tmpdir_capture="$test_root/tmpdir.txt"
stderr_capture="$test_root/stderr.txt"
writable_nested_capture="$test_root/nested.txt"
writable_cache_root="$test_root/writable-cache"
expected_lock_path="$test_root/.clasp-verify.lock"
explicit_lock_file="$expected_lock_path"
mkdir -p "$writable_cache_root"
fallback_commands=$'printf fallback-ok > '"$fallback_capture"$'\nprintf %s "$CLASP_VERIFY_EFFECTIVE_LOCK_FILE" > '"$lock_capture"$'\nprintf %s "$TMPDIR" > '"$tmpdir_capture"

PATH="$test_root/bin:$PATH" \
IN_NIX_SHELL= \
XDG_CACHE_HOME= \
CLASP_TEST_NIX_ENV_CAPTURE="$env_capture" \
CLASP_VERIFY_FALLBACK_COMMANDS="$fallback_commands" \
CLASP_VERIFY_LOCK_FILE="$explicit_lock_file" \
"$bash_bin" "$test_root/scripts/verify-all.sh" >/dev/null

[[ "$(< "$fallback_capture")" == "fallback-ok" ]]
[[ "$(< "$env_capture")" == "/tmp/clasp-nix-cache" ]]
[[ "$(< "$lock_capture")" == "$expected_lock_path" ]]
[[ "$(< "$tmpdir_capture")" == "$tmp_root" ]]

rm -f "$fallback_capture" "$env_capture" "$lock_capture" "$tmpdir_capture"
PATH="$test_root/bin:$PATH" \
IN_NIX_SHELL= \
XDG_CACHE_HOME="$writable_cache_root" \
CLASP_TEST_NIX_ENV_CAPTURE="$env_capture" \
CLASP_VERIFY_FALLBACK_COMMANDS="$fallback_commands" \
CLASP_VERIFY_LOCK_FILE="$explicit_lock_file" \
"$bash_bin" "$test_root/scripts/verify-all.sh" >/dev/null

[[ "$(< "$fallback_capture")" == "fallback-ok" ]]
[[ "$(< "$env_capture")" == "$writable_cache_root" ]]
[[ "$(< "$lock_capture")" == "$expected_lock_path" ]]
[[ "$(< "$tmpdir_capture")" == "$tmp_root" ]]

rm -f "$fallback_capture" "$stderr_capture"
PATH="$test_root/bin:$PATH" \
IN_NIX_SHELL= \
XDG_CACHE_HOME= \
CLASP_TEST_NIX_ENV_CAPTURE="$env_capture" \
CLASP_VERIFY_FALLBACK_COMMANDS="$fallback_commands" \
CLASP_VERIFY_LOCK_FILE="$explicit_lock_file" \
"$bash_bin" "$test_root/scripts/verify-fast.sh" >/dev/null 2>"$stderr_capture"

[[ "$(< "$fallback_capture")" == "fallback-ok" ]]
grep -F 'verify-fast: falling back to sandbox verification because Nix is unavailable in this environment' "$stderr_capture" >/dev/null

rm -f "$fallback_capture" "$stderr_capture"
PATH="$test_root/bin:$PATH" \
IN_NIX_SHELL= \
XDG_CACHE_HOME= \
CLASP_TEST_NIX_ENV_CAPTURE="$env_capture" \
CLASP_VERIFY_FALLBACK_COMMANDS="$fallback_commands" \
CLASP_VERIFY_LOCK_FILE="$explicit_lock_file" \
"$bash_bin" "$test_root/scripts/verify-selfhost.sh" >/dev/null 2>"$stderr_capture"

[[ "$(< "$fallback_capture")" == "fallback-ok" ]]
grep -F 'verify-selfhost: falling back to sandbox verification because Nix is unavailable in this environment' "$stderr_capture" >/dev/null

parallel_capture_one="$test_root/parallel-one.txt"
parallel_capture_two="$test_root/parallel-two.txt"
sequential_capture="$test_root/sequential.txt"
parallel_commands=$'sleep 1\nprintf parallel-one > '"$parallel_capture_one"$'\nprintf parallel-two > '"$parallel_capture_two"
sequential_commands=$'printf sequential-ok > '"$sequential_capture"
IN_NIX_SHELL= \
CLASP_VERIFY_USE_CURRENT_SHELL=1 \
CLASP_VERIFY_PARALLEL_JOBS=2 \
CLASP_VERIFY_PARALLEL_COMMANDS="$parallel_commands" \
CLASP_VERIFY_SEQUENTIAL_COMMANDS="$sequential_commands" \
CLASP_VERIFY_LOCK_FILE="$explicit_lock_file" \
"$bash_bin" "$test_root/scripts/verify-all.sh" >/dev/null

[[ "$(< "$parallel_capture_one")" == "parallel-one" ]]
[[ "$(< "$parallel_capture_two")" == "parallel-two" ]]
[[ "$(< "$sequential_capture")" == "sequential-ok" ]]

git_test_root="$test_root/git-repo"
mkdir -p "$git_test_root/scripts"
cp "$project_root/scripts/verify-all.sh" "$git_test_root/scripts/verify-all.sh"
(
  cd "$git_test_root"
  git init -b main >/dev/null
  git config user.name 'Verify All Test'
  git config user.email 'verify-all-test@example.com'
  git add scripts/verify-all.sh
  git commit -m 'init' >/dev/null
)
chmod a-w "$git_test_root/.git"
chmod_restore_needed=1
trap 'if [[ "${chmod_restore_needed:-0}" == "1" && -d "$git_test_root/.git" ]]; then chmod u+w "$git_test_root/.git" >/dev/null 2>&1 || true; fi; rm -rf "${test_root:-}"' EXIT
rm -f "$fallback_capture" "$env_capture" "$lock_capture" "$tmpdir_capture"
PATH="$test_root/bin:$PATH" \
IN_NIX_SHELL= \
XDG_CACHE_HOME="$writable_cache_root" \
CLASP_TEST_NIX_ENV_CAPTURE="$env_capture" \
CLASP_VERIFY_FALLBACK_COMMANDS="$fallback_commands" \
"$bash_bin" "$git_test_root/scripts/verify-all.sh" >/dev/null

[[ "$(< "$fallback_capture")" == "fallback-ok" ]]
[[ "$(< "$env_capture")" == "$writable_cache_root" ]]
[[ "$(< "$lock_capture")" == /tmp/clasp-verify-*".lock" ]]
[[ ! -e "$git_test_root/.git/clasp-verify.lock.d" ]]
chmod u+w "$git_test_root/.git"
chmod_restore_needed=0

rm -f "$writable_nested_capture"
PATH="$test_root/bin:$PATH" \
IN_NIX_SHELL= \
CLASP_VERIFY_IN_PROGRESS=1 \
CLASP_VERIFY_ACTIVE_ROOT="$test_root" \
CLASP_VERIFY_NESTED_COMMANDS=$'printf nested-ok > '"$writable_nested_capture" \
CLASP_VERIFY_LOCK_FILE="$explicit_lock_file" \
"$bash_bin" "$test_root/scripts/verify-all.sh" >/dev/null

[[ "$(< "$writable_nested_capture")" == "nested-ok" ]]

rm -f "$fallback_capture"
if PATH="$test_root/bin:$PATH" \
  IN_NIX_SHELL= \
  XDG_CACHE_HOME= \
  CLASP_TEST_NIX_ENV_CAPTURE="$env_capture" \
  CLASP_TEST_NIX_MESSAGE='error: unexpected nix failure' \
  CLASP_VERIFY_FALLBACK_COMMANDS=$'printf should-not-run > fallback.txt' \
  CLASP_VERIFY_LOCK_FILE="$explicit_lock_file" \
  "$bash_bin" "$test_root/scripts/verify-all.sh" >/dev/null 2>"$test_root/unexpected.log"; then
  printf 'verify-all unexpectedly succeeded on an unknown nix failure\n' >&2
  exit 1
fi

[[ ! -f "$fallback_capture" ]]

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
printf '{"image":"compiler"}\n' > "$test_root/src/embedded.compiler.native.image.json"

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
