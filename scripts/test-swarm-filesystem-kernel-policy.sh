#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
mkdir -p "$tmp_root"
export TMPDIR="$tmp_root"
test_root="$(mktemp -d "$TMPDIR/test-swarm-filesystem-kernel-policy.XXXXXX")"
kernel_run_binary_cache_dir="${CLASP_NATIVE_RUN_BINARY_CACHE_DIR:-$test_root/run-binary-cache-v2}"
export CLASP_NATIVE_RUN_BINARY_CACHE_DIR="$kernel_run_binary_cache_dir"
export CLASP_NATIVE_RUN_BINARY_CACHE_MAX_MB="${CLASP_NATIVE_RUN_BINARY_CACHE_MAX_MB:-512}"
mkdir -p "$CLASP_NATIVE_RUN_BINARY_CACHE_DIR"

cleanup() {
  rm -rf "$test_root"
}

trap cleanup EXIT

claspc_bin="$(env -u CLASP_CLASPC -u CLASPC_BIN -u RUSTC "$project_root/scripts/resolve-claspc.sh")"
state_root="$test_root/state"
workspace_root="$state_root/workspace"
outside_workspace_root="$state_root/outside-workspace"
mkdir -p "$workspace_root" "$outside_workspace_root"

kernel_timeout_secs="${CLASP_SWARM_FILESYSTEM_KERNEL_POLICY_TIMEOUT_SECS:-500}"
node_bin="$(command -v node)"
filesystem_mediator_path="$project_root/scripts/clasp-filesystem-write-enforcer.mjs"
filesystem_kernel_backend_path="$project_root/scripts/clasp-filesystem-write-kernel-backend.mjs"
filesystem_mediator_json="$(node -e 'process.stdout.write(JSON.stringify([process.argv[1], "--jitless", process.argv[2]]))' "$node_bin" "$filesystem_mediator_path")"
filesystem_kernel_backend_json="$(node -e 'process.stdout.write(JSON.stringify([process.argv[1], "--jitless", process.argv[2]]))' "$node_bin" "$filesystem_kernel_backend_path")"

node --check "$filesystem_mediator_path" >/dev/null
node --check "$filesystem_kernel_backend_path" >/dev/null

compile_direct_syscall_client() {
  local output_path="$1"
  local target_path="$2"
  local source_path="$test_root/$(basename "$output_path").c"

  cat >"$source_path" <<EOF
#include <asm/unistd.h>

#define O_WRONLY 01
#define O_CREAT 0100
#define O_TRUNC 01000

static long syscall3(long n, long a, long b, long c) {
  long r;
  __asm__ volatile("syscall" : "=a"(r) : "a"(n), "D"(a), "S"(b), "d"(c) : "rcx", "r11", "memory");
  return r;
}

static long syscall1(long n, long a) {
  long r;
  __asm__ volatile("syscall" : "=a"(r) : "a"(n), "D"(a) : "rcx", "r11", "memory");
  return r;
}

void _start(void) {
  const char *path = "$target_path";
  long fd = syscall3(__NR_open, (long)path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (fd < 0) {
    syscall1(__NR_exit, 1);
  }
  syscall3(__NR_write, fd, (long)"kernel", 6);
  syscall1(__NR_exit, 0);
}
EOF

  cc -nostdlib -static -Os -o "$output_path" "$source_path"
}

compile_dynamic_syscall_client() {
  local output_path="$1"
  local target_path="$2"
  local source_path="$test_root/$(basename "$output_path").c"

  cat >"$source_path" <<EOF
#include <asm/unistd.h>

#define O_WRONLY 01
#define O_CREAT 0100
#define O_TRUNC 01000

static long syscall3(long n, long a, long b, long c) {
  long r;
  __asm__ volatile("syscall" : "=a"(r) : "a"(n), "D"(a), "S"(b), "d"(c) : "rcx", "r11", "memory");
  return r;
}

int main(void) {
  const char *path = "$target_path";
  long fd = syscall3(__NR_open, (long)path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (fd < 0) {
    return 1;
  }
  syscall3(__NR_write, fd, (long)"dynamic", 7);
  return 0;
}
EOF

  cc -O2 -o "$output_path" "$source_path"
}

nix_store_root_for_path() {
  local value="$1"
  local trimmed="${value%%(*}"
  local first=""
  local second=""
  local third=""
  local fourth=""

  if [[ "$trimmed" != /* || ! -e "$trimmed" ]]; then
    return 0
  fi
  trimmed="$(realpath "$trimmed")"
  if [[ "$trimmed" == /nix/store/* ]]; then
    IFS=/ read -r first second third fourth _ <<<"$trimmed"
    if [[ "$second" == "nix" && "$third" == "store" && -n "$fourth" ]]; then
      printf '/nix/store/%s\n' "$fourth"
      return 0
    fi
  fi
  dirname "$trimmed"
}

dynamic_readonly_roots() {
  local binary_path="$1"
  local token=""

  while IFS= read -r line; do
    for token in $line; do
      nix_store_root_for_path "$token"
    done
  done < <(ldd "$binary_path")
}

outside_target="$outside_workspace_root/direct-syscall-outside-target.txt"
inside_target="$workspace_root/direct-syscall-inside-target.txt"
dynamic_outside_target="$outside_workspace_root/dynamic-syscall-outside-target.txt"
dynamic_inside_target="$workspace_root/dynamic-syscall-inside-target.txt"
compile_direct_syscall_client "$workspace_root/direct-syscall-outside-client" "$outside_target"
compile_direct_syscall_client "$workspace_root/direct-syscall-inside-client" "$inside_target"
compile_dynamic_syscall_client "$workspace_root/dynamic-syscall-outside-client" "$dynamic_outside_target"
compile_dynamic_syscall_client "$workspace_root/dynamic-syscall-inside-client" "$dynamic_inside_target"

mapfile -t readonly_roots < <(
  {
    dynamic_readonly_roots "$workspace_root/dynamic-syscall-outside-client"
    dynamic_readonly_roots "$workspace_root/dynamic-syscall-inside-client"
  } | sort -u
)
if [[ "${#readonly_roots[@]}" == "0" ]]; then
  printf 'expected at least one dynamic dependency root\n' >&2
  exit 1
fi
readonly_roots_json="$(node -e 'process.stdout.write(JSON.stringify(process.argv.slice(1)))' "${readonly_roots[@]}")"

env RUSTC=/definitely-missing-rustc \
  CLASP_SWARM_FILESYSTEM_MEDIATOR_JSON="$filesystem_mediator_json" \
  CLASP_SWARM_FILESYSTEM_WRITE_BACKEND_JSON="$filesystem_kernel_backend_json" \
  CLASP_TEST_FILESYSTEM_READONLY_ROOTS_JSON="$readonly_roots_json" \
  timeout "$kernel_timeout_secs" \
  "$claspc_bin" run "$project_root/examples/swarm-native/FilesystemKernelPolicyHarness.clasp" -- "$state_root" \
  >"$test_root/filesystem-kernel-policy-harness.json"

if grep -F 'error:' "$test_root/filesystem-kernel-policy-harness.json" >/dev/null; then
  cat "$test_root/filesystem-kernel-policy-harness.json" >&2
  exit 1
fi

node - "$test_root/filesystem-kernel-policy-harness.json" "$workspace_root" "$inside_target" "$outside_target" "$dynamic_inside_target" "$dynamic_outside_target" "$readonly_roots_json" <<'EOF'
const fs = require("node:fs");
const report = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const workspaceRoot = fs.realpathSync(process.argv[3]);
const insideTarget = process.argv[4];
const outsideTarget = process.argv[5];
const dynamicInsideTarget = process.argv[6];
const dynamicOutsideTarget = process.argv[7];
const readonlyRoots = JSON.parse(process.argv[8]);

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function sameList(actual, expected, label) {
  assert(Array.isArray(actual), `${label} is not an array`);
  assert(
    JSON.stringify(actual) === JSON.stringify(expected),
    `${label} expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
  );
}

assert(report.taskId === "filesystem-kernel-policy-task", `task id ${report.taskId}`);
sameList(report.allowedProcesses, ["direct-syscall-outside-client", "direct-syscall-inside-client", "dynamic-syscall-outside-client", "dynamic-syscall-inside-client"], "allowed processes");
sameList(report.allowedWorkspaceRoots, [workspaceRoot], "allowed workspace roots");
sameList(report.allowedReadonlyRoots, readonlyRoots, "allowed read-only roots");
assert(report.kernelOutsideWriteBlocked === true, "direct syscall outside write should be blocked by kernel filesystem mediator");
assert(report.kernelOutsideWritePrevented === true, "direct syscall outside write should not create outside target");
assert(report.kernelInsideWritePassed === true, "direct syscall inside write should pass through kernel filesystem mediator");
assert(report.kernelInsideWriteCreated === true, "direct syscall inside write should create inside target");
assert(report.dynamicOutsideWriteBlocked === true, "dynamic direct syscall outside write should be blocked by kernel filesystem mediator");
assert(report.dynamicOutsideWritePrevented === true, "dynamic direct syscall outside write should not create outside target");
assert(report.dynamicInsideWritePassed === true, "dynamic direct syscall inside write should pass through read-only dependency mounts");
assert(report.dynamicInsideWriteCreated === true, "dynamic direct syscall inside write should create inside target");
assert(!fs.existsSync(outsideTarget), "outside direct syscall target should not exist");
assert(fs.readFileSync(insideTarget, "utf8") === "kernel", "inside direct syscall target should contain expected text");
assert(!fs.existsSync(dynamicOutsideTarget), "outside dynamic direct syscall target should not exist");
assert(fs.readFileSync(dynamicInsideTarget, "utf8") === "dynamic", "inside dynamic direct syscall target should contain expected text");
assert(report.filesystemMediationStarted === true, "filesystem mediation event should be recorded");
assert(
  report.eventKinds.includes("filesystem_mediation_started"),
  `filesystem mediation event missing ${JSON.stringify(report.eventKinds)}`,
);
assert(report.eventKinds.includes("tool_run_finished"), `tool run event missing ${JSON.stringify(report.eventKinds)}`);
EOF

printf 'swarm-filesystem-kernel-policy-ok\n'
