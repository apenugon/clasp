#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root=""
bash_bin="$(command -v bash)"
tmp_root="${TMPDIR:-/tmp}"

unset CLASP_VERIFY_IN_PROGRESS
unset CLASP_VERIFY_ACTIVE_ROOT
unset CLASP_VERIFY_LOCK_HELD
unset CLASP_VERIFY_LABEL
unset CLASP_VERIFY_TOPLEVEL_REENTRY
unset CLASP_VERIFY_USE_CURRENT_SHELL
unset CLASP_VERIFY_LOCK_TIMEOUT_SECS
unset CLASP_VERIFY_ON_LOCK_TIMEOUT
unset CLASP_VERIFY_REPORT_JSON
unset CLASP_CLASPC
unset CLASPC_BIN

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
cp "$project_root/scripts/resolve-claspc.sh" "$test_root/scripts/resolve-claspc.sh"
cp "$project_root/scripts/verify-compiler-slice.sh" "$test_root/scripts/verify-compiler-slice.sh"
cp "$project_root/scripts/verify-runtime-slice.sh" "$test_root/scripts/verify-runtime-slice.sh"
cp "$project_root/scripts/verify-affected.sh" "$test_root/scripts/verify-affected.sh"
cp "$project_root/scripts/verify-affected.mjs" "$test_root/scripts/verify-affected.mjs"
cp "$project_root/scripts/generate-promoted-source-export-cache.mjs" "$test_root/scripts/generate-promoted-source-export-cache.mjs"
cp "$project_root/scripts/test-verify-affected.sh" "$test_root/scripts/test-verify-affected.sh"
cp "$project_root/scripts/test-js-emitter-determinism.sh" "$test_root/scripts/test-js-emitter-determinism.sh"
cp "$project_root/scripts/test-unsafe-quarantine.sh" "$test_root/scripts/test-unsafe-quarantine.sh"
cp "$project_root/scripts/test-verify-compiler-slice.sh" "$test_root/scripts/test-verify-compiler-slice.sh"
cp "$project_root/scripts/test-verify-runtime-slice.sh" "$test_root/scripts/test-verify-runtime-slice.sh"
cp "$project_root/scripts/test-promoted-source-export-cache.sh" "$test_root/scripts/test-promoted-source-export-cache.sh"
cp "$project_root/scripts/test-native-incremental-guard.sh" "$test_root/scripts/test-native-incremental-guard.sh"
cp "$project_root/scripts/test-native-claspc-diagnostics.sh" "$test_root/scripts/test-native-claspc-diagnostics.sh"
cp "$project_root/scripts/test-native-claspc-smoke.sh" "$test_root/scripts/test-native-claspc-smoke.sh"
cp "$project_root/scripts/test-source-run-cache.sh" "$test_root/scripts/test-source-run-cache.sh"
cp "$project_root/scripts/test-native-claspc.sh" "$test_root/scripts/test-native-claspc.sh"
cp "$project_root/scripts/test-native-runtime-smoke.sh" "$test_root/scripts/test-native-runtime-smoke.sh"
cp "$project_root/scripts/test-verify-all-smoke.sh" "$test_root/scripts/test-verify-all-smoke.sh"
cp "$project_root/scripts/test-record-update-parity.sh" "$test_root/scripts/test-record-update-parity.sh"
cp "$project_root/scripts/test-monitored-loop.sh" "$test_root/scripts/test-monitored-loop.sh"
cp "$project_root/scripts/test-monitored-step.sh" "$test_root/scripts/test-monitored-step.sh"
cp "$project_root/scripts/test-monitored-run-log.sh" "$test_root/scripts/test-monitored-run-log.sh"
cp "$project_root/scripts/test-safe-subprocess.sh" "$test_root/scripts/test-safe-subprocess.sh"
cp "$project_root/scripts/run-managed-job.sh" "$test_root/scripts/run-managed-job.sh"
cp "$project_root/scripts/stop-managed-job.sh" "$test_root/scripts/stop-managed-job.sh"
cp "$project_root/scripts/test-managed-job.sh" "$test_root/scripts/test-managed-job.sh"
cp "$project_root/scripts/test-monitored-workflow.sh" "$test_root/scripts/test-monitored-workflow.sh"
cp "$project_root/scripts/test-codex-loop-program.sh" "$test_root/scripts/test-codex-loop-program.sh"
cp "$project_root/scripts/test-agent-command-template.sh" "$test_root/scripts/test-agent-command-template.sh"
cp "$project_root/scripts/test-goal-manager-agent-command-template.sh" "$test_root/scripts/test-goal-manager-agent-command-template.sh"
cp "$project_root/scripts/test-host-runtime.sh" "$test_root/scripts/test-host-runtime.sh"
cp "$project_root/scripts/test-safe-workspace.sh" "$test_root/scripts/test-safe-workspace.sh"
cp "$project_root/scripts/test-goal-manager-child-loop-monitor.sh" "$test_root/scripts/test-goal-manager-child-loop-monitor.sh"
cp "$project_root/scripts/test-goal-manager-fast.sh" "$test_root/scripts/test-goal-manager-fast.sh"
cp "$project_root/scripts/test-swarm-ready-gate.sh" "$test_root/scripts/test-swarm-ready-gate.sh"
cp "$project_root/scripts/test-swarm-native-feedback-loop.sh" "$test_root/scripts/test-swarm-native-feedback-loop.sh"
cp "$project_root/scripts/test-feedback-loop-resume.sh" "$test_root/scripts/test-feedback-loop-resume.sh"
cp "$project_root/scripts/test-feedback-loop-routing.sh" "$test_root/scripts/test-feedback-loop-routing.sh"
cp "$project_root/scripts/ensure-goal-manager-binary.sh" "$test_root/scripts/ensure-goal-manager-binary.sh"
cp "$project_root/src/scripts/verify.sh" "$test_root/src/scripts/verify.sh"
cp "$project_root/src/scripts/run-native-tool.sh" "$test_root/src/scripts/run-native-tool.sh"
mkdir -p "$test_root/examples/swarm-native" "$test_root/runtime"
printf 'module Main\n\nimport Service\nimport Swarm\n\nmain : Str\nmain = service\n' > "$test_root/examples/swarm-native/GoalManager.clasp"
printf 'module Main\n\nimport Service\n\nmain : Str\nmain = service\n' > "$test_root/examples/swarm-native/GoalManager.wrapper.clasp"
printf 'module Main\n\nimport Service\n\nmain : Str\nmain = service\n' > "$test_root/examples/swarm-native/GoalManagerProgram2.split.clasp"
printf 'module Service\nservice : Str\nservice = "service"\n' > "$test_root/examples/swarm-native/Service.clasp"
printf 'module Swarm\nswarm : Str\nswarm = "swarm"\n' > "$test_root/examples/swarm-native/Swarm.clasp"
printf '[package]\nname = "fake-runtime"\nversion = "0.0.0"\n' > "$test_root/runtime/Cargo.toml"
cat > "$test_root/bin/fake-claspc" <<'EOF'
#!/usr/bin/env bash
printf 'fake-claspc\n'
EOF
chmod +x "$test_root/bin/fake-claspc"

grep -F 'bash src/scripts/verify.sh' "$test_root/scripts/verify-fast.sh" >/dev/null
if grep -F 'bash scripts/test-selfhost.sh' "$test_root/scripts/verify-fast.sh" >/dev/null 2>&1; then
  printf 'fast verification should use the focused selfhost verifier, not broad test-selfhost\n' >&2
  exit 1
fi
grep -F 'bash scripts/test-native-claspc-diagnostics.sh' "$test_root/scripts/verify-fast.sh" >/dev/null
grep -F 'bash scripts/test-source-run-cache.sh' "$test_root/scripts/verify-fast.sh" >/dev/null
grep -F 'bash scripts/test-promoted-source-export-cache.sh' "$test_root/scripts/verify-fast.sh" >/dev/null
grep -F 'bash scripts/test-native-claspc-smoke.sh' "$test_root/scripts/verify-fast.sh" >/dev/null
grep -F 'bash scripts/test-native-runtime-smoke.sh' "$test_root/scripts/verify-fast.sh" >/dev/null
grep -F 'bash scripts/test-managed-job.sh' "$test_root/scripts/verify-fast.sh" >/dev/null
if grep -F 'bash scripts/test-native-runtime.sh' "$test_root/scripts/verify-fast.sh" >/dev/null 2>&1; then
  printf 'fast verification should use native runtime smoke, not broad native runtime\n' >&2
  exit 1
fi
grep -F 'bash scripts/verify-compiler-slice.sh all' "$test_root/scripts/verify-fast.sh" >/dev/null
grep -F 'bash scripts/test-record-update-parity.sh' "$test_root/scripts/verify-fast.sh" >/dev/null
grep -F 'bash scripts/verify-runtime-slice.sh process workflow codex-loop agent-loop workspace' "$test_root/scripts/verify-fast.sh" >/dev/null
grep -F 'bash examples/agent-metadata/scripts/verify.sh' "$test_root/scripts/verify-fast.sh" >/dev/null
grep -F 'bash examples/agent-task-scenario/scripts/verify.sh' "$test_root/scripts/verify-fast.sh" >/dev/null
grep -F 'bash scripts/test-js-emitter-determinism.sh' "$test_root/scripts/verify-fast.sh" >/dev/null
grep -F 'bash scripts/test-unsafe-quarantine.sh' "$test_root/scripts/verify-fast.sh" >/dev/null
grep -F 'bash scripts/test-verify-all-smoke.sh' "$test_root/scripts/verify-fast.sh" >/dev/null
if grep -F 'bash scripts/test-verify-all.sh' "$test_root/scripts/verify-fast.sh" >/dev/null 2>&1; then
  printf 'fast verification should use test-verify-all-smoke, not exhaustive test-verify-all\n' >&2
  exit 1
fi
grep -F 'bash scripts/test-verify-affected.sh' "$test_root/scripts/verify-fast.sh" >/dev/null
grep -F 'bash scripts/test-verify-compiler-slice.sh' "$test_root/scripts/verify-fast.sh" >/dev/null
grep -F 'bash scripts/test-verify-runtime-slice.sh' "$test_root/scripts/verify-fast.sh" >/dev/null
node - "$test_root/scripts/verify-fast.sh" <<'NODE'
const fs = require("fs");
const script = fs.readFileSync(process.argv[2], "utf8");
function extract(name) {
  const match = script.match(new RegExp(`${name}=\\$'([\\s\\S]*?)'`));
  if (!match) {
    throw new Error(`missing ${name}`);
  }
  return match[1];
}
const parallelCommands = extract("fast_parallel_verify_commands");
const sequentialCommands = extract("fast_sequential_verify_commands");
if (parallelCommands.includes("bash scripts/test-native-claspc.sh")) {
  throw new Error("fast native claspc harness should not run in the parallel batch");
}
if (sequentialCommands.includes("bash scripts/test-native-claspc.sh")) {
  throw new Error("fast verification should not run the full native claspc harness");
}
if (!parallelCommands.includes("bash scripts/test-native-claspc-smoke.sh")) {
  throw new Error("fast native claspc smoke harness should run in the parallel batch");
}
if (sequentialCommands.includes("bash scripts/test-native-claspc-smoke.sh")) {
  throw new Error("fast native claspc smoke should not block the sequential batch");
}
NODE
grep -F 'CLASP_GOAL_MANAGER_BUILD_XDG_CACHE_HOME' "$test_root/scripts/test-goal-manager-fast.sh" >/dev/null
grep -F 'CLASP_GOAL_MANAGER_CACHE_DIR="$goal_manager_build_cache_dir"' "$test_root/scripts/test-goal-manager-fast.sh" >/dev/null
grep -F 'CLASP_GOAL_MANAGER_SHARED_CACHE_PROJECT_ROOT' "$test_root/scripts/test-goal-manager-fast.sh" >/dev/null
grep -F 'CLASP_GOAL_MANAGER_COMPILE_TIMEOUT_SECS="${CLASP_GOAL_MANAGER_COMPILE_TIMEOUT_SECS:-180}"' "$test_root/scripts/test-goal-manager-fast.sh" >/dev/null
grep -F 'CLASP_GOAL_MANAGER_COMPILE_ATTEMPTS="${CLASP_GOAL_MANAGER_COMPILE_ATTEMPTS:-2}"' "$test_root/scripts/test-goal-manager-fast.sh" >/dev/null
grep -F 'CLASP_GOAL_MANAGER_ALLOW_STALE_ON_COMPILE_FAILURE="${CLASP_GOAL_MANAGER_ALLOW_STALE_ON_COMPILE_FAILURE:-1}"' "$test_root/scripts/test-goal-manager-fast.sh" >/dev/null
grep -F 'TaskWorkspaceRuntimeHarness.clasp' "$test_root/scripts/test-goal-manager-fast.sh" >/dev/null
grep -F 'goal_manager_binary_fresh=0' "$test_root/scripts/test-goal-manager-fast.sh" >/dev/null
grep -F 'measure-native-incremental.sh' "$test_root/scripts/test-native-incremental-guard.sh" >/dev/null
grep -F 'CLASP_TEST_NATIVE_CLASPC_SHARED_CACHE_HOME' "$test_root/scripts/test-native-claspc.sh" >/dev/null
grep -F 'CLASP_TEST_SHARED_XDG_CACHE_HOME' "$test_root/scripts/test-native-claspc.sh" >/dev/null
grep -F 'CLASP_TEST_ISOLATED_XDG_CACHE' "$test_root/scripts/test-native-claspc.sh" >/dev/null
grep -F 'test-native-claspc-smoke: ok' "$test_root/scripts/test-native-claspc-smoke.sh" >/dev/null
grep -F 'CLASP_TEST_NATIVE_CLASPC_SHARED_CACHE_HOME' "$test_root/scripts/test-native-claspc-smoke.sh" >/dev/null
grep -F 'CLASP_TEST_ISOLATED_XDG_CACHE' "$test_root/scripts/test-native-claspc-smoke.sh" >/dev/null
grep -F 'test-native-runtime-smoke: ok' "$test_root/scripts/test-native-runtime-smoke.sh" >/dev/null
grep -F 'test_native_interpreter.c' "$test_root/scripts/test-native-runtime-smoke.sh" >/dev/null
grep -F 'interpreted_call[main]=Hello from Clasp' "$test_root/scripts/test-native-runtime-smoke.sh" >/dev/null
grep -F 'test-verify-all-smoke: ok' "$test_root/scripts/test-verify-all-smoke.sh" >/dev/null
grep -F 'CLASP_VERIFY_USE_CURRENT_SHELL=1' "$test_root/scripts/test-verify-all-smoke.sh" >/dev/null
grep -F 'bash scripts/test-verify-all.sh' "$test_root/scripts/test-verify-all-smoke.sh" >/dev/null
grep -F 'setup_exhaustive_native_cases()' "$test_root/scripts/test-native-claspc.sh" >/dev/null
grep -F 'CLASP_NATIVE_CLASPC_EXHAUSTIVE' "$test_root/scripts/test-native-claspc.sh" >/dev/null
grep -F 'ensure-goal-manager-binary.sh' "$test_root/scripts/test-native-claspc.sh" >/dev/null
grep -F 'CLASP_GOAL_MANAGER_CACHE_DIR="$goal_manager_build_cache_dir"' "$test_root/scripts/test-native-claspc.sh" >/dev/null
grep -F 'CLASP_GOAL_MANAGER_ALLOW_STALE_ON_COMPILE_FAILURE=0' "$test_root/scripts/test-native-claspc.sh" >/dev/null
if grep -F '"$claspc_bin" --json check "$project_root/examples/swarm-native/GoalManager.clasp"' "$test_root/scripts/test-native-claspc.sh" >/dev/null 2>&1; then
  printf 'test-native-claspc should rely on ensure-goal-manager-binary instead of a redundant GoalManager check\n' >&2
  exit 1
fi
grep -F 'CLASP_TEST_SHARED_XDG_CACHE_HOME' "$test_root/scripts/test-monitored-loop.sh" >/dev/null
grep -F 'CLASP_TEST_ISOLATED_XDG_CACHE' "$test_root/scripts/test-monitored-loop.sh" >/dev/null
grep -F 'CLASP_TEST_SHARED_XDG_CACHE_HOME' "$test_root/scripts/test-goal-manager-child-loop-monitor.sh" >/dev/null
grep -F 'CLASP_TEST_ISOLATED_XDG_CACHE' "$test_root/scripts/test-goal-manager-child-loop-monitor.sh" >/dev/null
grep -F 'CLASP_VERIFY_PARALLEL_COMMANDS' "$test_root/scripts/verify-fast.sh" >/dev/null
grep -F 'CLASP_VERIFY_SEQUENTIAL_COMMANDS' "$test_root/scripts/verify-fast.sh" >/dev/null
grep -F '[claspc-cache] run-binary fast hit path=' "$test_root/scripts/test-source-run-cache.sh" >/dev/null
grep -F 'env -u CLASP_CLASPC -u CLASPC_BIN CLASP_PROJECT_ROOT="$project_root"' "$test_root/scripts/verify-fast.sh" >/dev/null
grep -F 'export CLASP_CLASPC="$resolved_claspc_bin"' "$test_root/scripts/verify-fast.sh" >/dev/null
grep -F 'export CLASPC_BIN="$resolved_claspc_bin"' "$test_root/scripts/verify-fast.sh" >/dev/null
grep -F 'bash scripts/test-selfhost.sh' "$test_root/scripts/verify-all.sh" >/dev/null
grep -F 'bash scripts/test-source-run-cache.sh' "$test_root/scripts/verify-all.sh" >/dev/null
grep -F 'bash scripts/test-promoted-source-export-cache.sh' "$test_root/scripts/verify-all.sh" >/dev/null
grep -F 'bash scripts/test-codex-loop.sh' "$test_root/scripts/verify-all.sh" >/dev/null
grep -F 'bash scripts/test-record-update-parity.sh' "$test_root/scripts/verify-all.sh" >/dev/null
grep -F 'CLASP_VERIFY_REPORT_JSON' "$test_root/scripts/verify-all.sh" >/dev/null
grep -F '"finalVerdict"' "$test_root/scripts/verify-all.sh" >/dev/null
grep -F '"firstFailedCommand"' "$test_root/scripts/verify-all.sh" >/dev/null
grep -F 'command failed (exit %s)' "$test_root/scripts/verify-all.sh" >/dev/null
grep -F 'bash scripts/test-native-claspc.sh' "$test_root/scripts/verify-all.sh" >/dev/null
grep -F 'bash scripts/test-swarm-ready-gate.sh' "$test_root/scripts/verify-all.sh" >/dev/null
grep -F 'bash scripts/test-swarm-native-feedback-loop.sh' "$test_root/scripts/verify-all.sh" >/dev/null
grep -F 'bash scripts/test-monitored-step.sh' "$test_root/scripts/verify-all.sh" >/dev/null
grep -F 'bash scripts/test-monitored-run-log.sh' "$test_root/scripts/verify-all.sh" >/dev/null
grep -F 'bash scripts/test-safe-subprocess.sh' "$test_root/scripts/verify-all.sh" >/dev/null
grep -F 'bash scripts/test-managed-job.sh' "$test_root/scripts/verify-all.sh" >/dev/null
grep -F 'bash scripts/test-monitored-workflow.sh' "$test_root/scripts/verify-all.sh" >/dev/null
grep -F 'bash scripts/test-codex-loop-program.sh' "$test_root/scripts/verify-all.sh" >/dev/null
grep -F 'bash examples/agent-loop-scenario/scripts/verify.sh' "$test_root/scripts/verify-all.sh" >/dev/null
grep -F 'bash scripts/test-agent-command-template.sh' "$test_root/scripts/verify-all.sh" >/dev/null
grep -F 'CLASP_AGENT_COMMAND_TEMPLATE_FEEDBACK=0 CLASP_AGENT_COMMAND_TEMPLATE_NATIVE=1 bash scripts/test-agent-command-template.sh' "$test_root/scripts/verify-all.sh" >/dev/null
grep -F 'bash scripts/test-goal-manager-agent-command-template.sh' "$test_root/scripts/verify-all.sh" >/dev/null
grep -F 'bash examples/browser-counter/scripts/verify.sh' "$test_root/scripts/verify-all.sh" >/dev/null
grep -F 'bash scripts/test-host-runtime.sh' "$test_root/scripts/verify-all.sh" >/dev/null
grep -F 'bash scripts/test-safe-workspace.sh' "$test_root/scripts/verify-all.sh" >/dev/null
grep -F 'bash scripts/test-feedback-loop-resume.sh' "$test_root/scripts/verify-all.sh" >/dev/null
grep -F 'bash src/scripts/verify.sh' "$test_root/scripts/verify-all.sh" >/dev/null
grep -F 'selfhost-native-verify: parallel wait returned without a pid and no tracked jobs remain' "$test_root/src/scripts/verify.sh" >/dev/null
grep -F 'local fallback_pid=""' "$test_root/src/scripts/verify.sh" >/dev/null
grep -F 'wait "$finished_pid"' "$test_root/src/scripts/verify.sh" >/dev/null
grep -F 'bash examples/agent-metadata/scripts/verify.sh' "$test_root/scripts/verify-all.sh" >/dev/null
grep -F 'bash examples/agent-task-scenario/scripts/verify.sh' "$test_root/scripts/verify-all.sh" >/dev/null
grep -F 'bash scripts/test-js-emitter-determinism.sh' "$test_root/scripts/verify-all.sh" >/dev/null
grep -F 'bash scripts/test-unsafe-quarantine.sh' "$test_root/scripts/verify-all.sh" >/dev/null
grep -F 'parallel wait returned without a pid and no tracked jobs remain' "$test_root/scripts/verify-all.sh" >/dev/null
grep -F 'local fallback_pid=""' "$test_root/scripts/verify-all.sh" >/dev/null
grep -F 'wait "$finished_pid"' "$test_root/scripts/verify-all.sh" >/dev/null
node - "$test_root/scripts/verify-all.sh" <<'NODE'
const fs = require("fs");
const script = fs.readFileSync(process.argv[2], "utf8");
const match = script.match(/full_sequential_verify_commands=\$'([\s\S]*?)'\n/);
if (!match) {
  throw new Error("missing full sequential verify commands");
}
const count = match[1]
  .split(/\n/)
  .filter((line) => line.trim() === "bash scripts/test-js-emitter-determinism.sh")
  .length;
if (count !== 1) {
  throw new Error(`verify-all should run test-js-emitter-determinism exactly once, saw ${count}`);
}
NODE
grep -F 'bash scripts/test-verify-affected.sh' "$test_root/scripts/verify-all.sh" >/dev/null
grep -F 'bash scripts/test-verify-compiler-slice.sh' "$test_root/scripts/verify-all.sh" >/dev/null
grep -F 'bash scripts/test-verify-runtime-slice.sh' "$test_root/scripts/verify-all.sh" >/dev/null
grep -F 'usage: scripts/verify-compiler-slice.sh' "$test_root/scripts/verify-compiler-slice.sh" >/dev/null
grep -F -- '--check-only' "$test_root/scripts/verify-compiler-slice.sh" >/dev/null
grep -F 'CLASP_COMPILER_SLICE_TIMEOUT_SECS' "$test_root/scripts/verify-compiler-slice.sh" >/dev/null
grep -F 'parser checker lower emitter' "$test_root/scripts/verify-compiler-slice.sh" >/dev/null
grep -F 'ergonomics' "$test_root/scripts/verify-compiler-slice.sh" >/dev/null
grep -F 'examples/compiler-checker.clasp' "$test_root/scripts/test-verify-compiler-slice.sh" >/dev/null
grep -F 'examples/compiler-lower.clasp' "$test_root/scripts/test-verify-compiler-slice.sh" >/dev/null
grep -F 'examples/compiler-ergonomics.clasp' "$test_root/scripts/test-verify-compiler-slice.sh" >/dev/null
grep -F 'verify-compiler-slice: ok (checker, check-only)' "$test_root/scripts/test-verify-compiler-slice.sh" >/dev/null
grep -F 'usage: scripts/verify-runtime-slice.sh' "$test_root/scripts/verify-runtime-slice.sh" >/dev/null
grep -F 'CLASP_RUNTIME_SLICE_TIMEOUT_SECS' "$test_root/scripts/verify-runtime-slice.sh" >/dev/null
grep -F 'scripts/test-monitored-run-log.sh' "$test_root/scripts/verify-runtime-slice.sh" >/dev/null
grep -F 'process workflow codex-loop agent-loop workspace managed-loop swarm-feedback-loop' "$test_root/scripts/verify-runtime-slice.sh" >/dev/null
grep -F 'scripts/test-safe-subprocess.sh' "$test_root/scripts/verify-runtime-slice.sh" >/dev/null
grep -F 'scripts/test-monitored-workflow.sh' "$test_root/scripts/test-verify-runtime-slice.sh" >/dev/null
grep -F 'scripts/test-monitored-run-log.sh' "$test_root/scripts/test-verify-runtime-slice.sh" >/dev/null
grep -F 'scripts/test-safe-subprocess.sh' "$test_root/scripts/test-verify-runtime-slice.sh" >/dev/null
grep -F 'examples/agent-loop-scenario/scripts/verify.sh' "$test_root/scripts/test-verify-runtime-slice.sh" >/dev/null
grep -F 'scripts/test-agent-command-template.sh' "$test_root/scripts/test-verify-runtime-slice.sh" >/dev/null
grep -F 'scripts/test-swarm-native-managed-loop.sh' "$test_root/scripts/test-verify-runtime-slice.sh" >/dev/null
grep -F 'scripts/test-swarm-native-feedback-loop.sh' "$test_root/scripts/test-verify-runtime-slice.sh" >/dev/null
grep -F 'CLASP_VERIFY_CHANGED_FILES' "$test_root/scripts/verify-affected.mjs" >/dev/null
grep -F 'verificationFallbackMode' "$test_root/scripts/verify-affected.mjs" >/dev/null
grep -F 'usedVerifyFastFallback' "$test_root/scripts/verify-affected.mjs" >/dev/null
grep -F 'bash scripts/verify-fast.sh' "$test_root/scripts/verify-affected.mjs" >/dev/null
grep -F 'bash scripts/test-native-claspc-diagnostics.sh' "$test_root/scripts/verify-affected.mjs" >/dev/null
grep -F 'bash scripts/test-native-claspc.sh' "$test_root/scripts/verify-affected.mjs" >/dev/null
grep -F 'bash scripts/verify-runtime-slice.sh swarm-feedback-loop' "$test_root/scripts/verify-affected.mjs" >/dev/null
grep -F 'bash scripts/test-verify-compiler-slice.sh' "$test_root/scripts/verify-affected.mjs" >/dev/null
grep -F 'bash scripts/test-verify-runtime-slice.sh' "$test_root/scripts/verify-affected.mjs" >/dev/null
grep -F 'bash scripts/test-selfhost-verify-mode-split.sh' "$test_root/scripts/verify-affected.mjs" >/dev/null
grep -F 'bash scripts/verify-runtime-slice.sh' "$test_root/scripts/verify-affected.mjs" >/dev/null
grep -F 'bash scripts/test-codex-loop-program.sh' "$test_root/scripts/verify-affected.mjs" >/dev/null
grep -F 'bash scripts/test-safe-subprocess.sh' "$test_root/scripts/verify-affected.mjs" >/dev/null
grep -F 'bash scripts/test-feedback-loop-routing.sh loop-routing' "$test_root/scripts/verify-affected.mjs" >/dev/null
grep -F 'bash scripts/test-feedback-loop-routing.sh' "$test_root/scripts/verify-affected.mjs" >/dev/null
grep -F 'bash scripts/test-feedback-loop-resume.sh smoke' "$test_root/scripts/verify-affected.mjs" >/dev/null
grep -F 'bash scripts/test-record-update-parity.sh' "$test_root/scripts/verify-affected.mjs" >/dev/null
grep -F 'bash scripts/verify-compiler-slice.sh' "$test_root/scripts/verify-affected.mjs" >/dev/null
grep -F 'bash scripts/verify-compiler-slice.sh --check-only' "$test_root/scripts/verify-affected.mjs" >/dev/null
grep -F 'bash scripts/test-js-emitter-determinism.sh' "$test_root/scripts/verify-affected.mjs" >/dev/null
grep -F 'bash scripts/test-promoted-source-export-cache.sh' "$test_root/scripts/verify-affected.mjs" >/dev/null
grep -F 'node --check scripts/generate-promoted-source-export-cache.mjs' "$test_root/scripts/verify-affected.mjs" >/dev/null
grep -F 'source-export-cache-v1' "$test_root/scripts/generate-promoted-source-export-cache.mjs" >/dev/null
grep -F 'src/stage1.goal-manager.native.image.json' "$test_root/scripts/generate-promoted-source-export-cache.mjs" >/dev/null
grep -F 'src/stage1.task-workspace-runtime-harness.native.image.json' "$test_root/scripts/generate-promoted-source-export-cache.mjs" >/dev/null
grep -F 'env -u CLASP_CLASPC -u CLASPC_BIN "$project_root/scripts/resolve-claspc.sh"' "$test_root/scripts/test-promoted-source-export-cache.sh" >/dev/null
grep -F 'source-export promoted hit export=checkSourceText' "$test_root/scripts/test-promoted-source-export-cache.sh" >/dev/null
grep -F 'source-export promoted hit export=nativeImageProjectText' "$test_root/scripts/test-promoted-source-export-cache.sh" >/dev/null
grep -F 'source-no-git' "$test_root/scripts/test-verify-affected.sh" >/dev/null
grep -F 'compiler-slice-fixture' "$test_root/scripts/test-verify-affected.sh" >/dev/null
grep -F 'selfhost-verify-script' "$test_root/scripts/test-verify-affected.sh" >/dev/null
grep -F 'feedback-loop-resume-script' "$test_root/scripts/test-verify-affected.sh" >/dev/null
grep -F 'js-emitter-determinism' "$test_root/scripts/test-verify-affected.sh" >/dev/null
grep -F 'record-update-parity-script' "$test_root/scripts/test-verify-affected.sh" >/dev/null
grep -F 'runtime-slice-script' "$test_root/scripts/test-verify-affected.sh" >/dev/null
grep -F 'CLASP_NATIVE_VERIFY_MODE=full bash src/scripts/verify.sh' "$test_root/scripts/verify-selfhost.sh" >/dev/null
grep -F 'bash scripts/test-selfhost-incremental-full-verify.sh' "$test_root/scripts/verify-selfhost.sh" >/dev/null
grep -F 'CLASP_VERIFY_PARALLEL_COMMANDS' "$test_root/scripts/verify-selfhost.sh" >/dev/null
grep -F 'CLASP_VERIFY_SEQUENTIAL_COMMANDS' "$test_root/scripts/verify-selfhost.sh" >/dev/null
grep -F 'verify_mode="${CLASP_NATIVE_VERIFY_MODE:-fast}"' "$test_root/src/scripts/verify.sh" >/dev/null
grep -F 'if [[ "$verify_mode" == "full" ]]; then' "$test_root/src/scripts/verify.sh" >/dev/null
grep -F 'verify_output="$(run_verify)"' "$test_root/src/scripts/verify.sh" >/dev/null
grep -F "summary_line=\"\${verify_output##*\$'\n'}\"" "$test_root/src/scripts/verify.sh" >/dev/null
grep -F '"promotedCompilerFixtureCheckExecutes":true' "$test_root/src/scripts/verify.sh" >/dev/null
grep -F 'acquire_verify_lock()' "$test_root/src/scripts/verify.sh" >/dev/null
grep -F 'nativeImageProjectBuildPlanText' "$test_root/src/scripts/verify.sh" >/dev/null
grep -F 'nativeImageProjectModuleDeclsText' "$test_root/src/scripts/verify.sh" >/dev/null
grep -F 'fast_verify_fixture_root="$verify_root/fast-project"' "$test_root/src/scripts/verify.sh" >/dev/null
grep -F 'CLASP_GOAL_MANAGER_COMPILE_TIMEOUT_SECS' "$test_root/scripts/ensure-goal-manager-binary.sh" >/dev/null
grep -F 'CLASP_GOAL_MANAGER_COMPILE_ATTEMPTS' "$test_root/scripts/ensure-goal-manager-binary.sh" >/dev/null
grep -F 'CLASP_GOAL_MANAGER_ALLOW_STALE_ON_COMPILE_FAILURE' "$test_root/scripts/ensure-goal-manager-binary.sh" >/dev/null
grep -F 'CLASP_GOAL_MANAGER_ALLOW_UNMANAGED_STALE' "$test_root/scripts/ensure-goal-manager-binary.sh" >/dev/null
grep -F 'CLASP_GOAL_MANAGER_STALE_SMOKE_TIMEOUT_SECS' "$test_root/scripts/ensure-goal-manager-binary.sh" >/dev/null
grep -F 'GoalManager.clasp' "$test_root/scripts/ensure-goal-manager-binary.sh" >/dev/null
grep -F 'GoalManager.wrapper.clasp' "$test_root/scripts/ensure-goal-manager-binary.sh" >/dev/null
grep -F 'GoalManagerProgram2.split.clasp' "$test_root/scripts/ensure-goal-manager-binary.sh" >/dev/null
grep -F 'select_default_goal_manager_source()' "$test_root/scripts/ensure-goal-manager-binary.sh" >/dev/null
grep -F 'emit_goal_manager_import_closure_hashes()' "$test_root/scripts/ensure-goal-manager-binary.sh" >/dev/null
grep -F 'emit_goal_manager_build_mode_key()' "$test_root/scripts/ensure-goal-manager-binary.sh" >/dev/null
grep -F 'goal-manager-source-content' "$test_root/scripts/ensure-goal-manager-binary.sh" >/dev/null
grep -F 'goal-manager-source-dependencies' "$test_root/scripts/ensure-goal-manager-binary.sh" >/dev/null
grep -F 'goal-manager-build-mode' "$test_root/scripts/ensure-goal-manager-binary.sh" >/dev/null
grep -F 'CLASP_NATIVE_IMAGE_MONOLITHIC_DECL_THRESHOLD' "$test_root/scripts/ensure-goal-manager-binary.sh" >/dev/null
grep -F 'goal-manager-source' "$test_root/scripts/ensure-goal-manager-binary.sh" >/dev/null
grep -F 'goal_manager_cache_path_id()' "$test_root/scripts/ensure-goal-manager-binary.sh" >/dev/null
grep -F 'goal_manager_metadata_path()' "$test_root/scripts/ensure-goal-manager-binary.sh" >/dev/null
grep -F 'write_goal_manager_binary_metadata()' "$test_root/scripts/ensure-goal-manager-binary.sh" >/dev/null
grep -F 'emit_goal_manager_file_cache_hash()' "$test_root/scripts/ensure-goal-manager-binary.sh" >/dev/null
grep -F 'sha256sum "$claspc_bin" | awk' "$test_root/scripts/ensure-goal-manager-binary.sh" >/dev/null
grep -F 'default_cache_parent="${XDG_CACHE_HOME:-/tmp/clasp-nix-cache}"' "$test_root/scripts/ensure-goal-manager-binary.sh" >/dev/null
grep -F 'compile_lock="$(dirname "$goal_manager_binary")/compile.lock"' "$test_root/scripts/ensure-goal-manager-binary.sh" >/dev/null
grep -F 'emit_stale_goal_manager_candidates()' "$test_root/scripts/ensure-goal-manager-binary.sh" >/dev/null
grep -F 'validate_cached_goal_manager_binary()' "$test_root/scripts/ensure-goal-manager-binary.sh" >/dev/null
grep -F 'validate_goal_manager_binary_metadata()' "$test_root/scripts/ensure-goal-manager-binary.sh" >/dev/null
grep -F 'validate_stale_goal_manager_binary()' "$test_root/scripts/ensure-goal-manager-binary.sh" >/dev/null
grep -F 'find_stale_goal_manager_binary()' "$test_root/scripts/ensure-goal-manager-binary.sh" >/dev/null
grep -F 'use_stale_goal_manager_binary()' "$test_root/scripts/ensure-goal-manager-binary.sh" >/dev/null

cat > "$test_root/bin/fake-slow-claspc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
sleep 10
EOF
chmod +x "$test_root/bin/fake-slow-claspc"

goal_manager_timeout_stderr="$test_root/goal-manager-timeout.stderr"
if CLASP_GOAL_MANAGER_CLASPC_BIN="$test_root/bin/fake-slow-claspc" \
  CLASP_GOAL_MANAGER_CACHE_DIR="$test_root/goal-manager-timeout-cache" \
  CLASP_GOAL_MANAGER_COMPILE_TIMEOUT_SECS=1 \
  CLASP_GOAL_MANAGER_COMPILE_ATTEMPTS=2 \
  CLASP_GOAL_MANAGER_ALLOW_STALE_ON_COMPILE_FAILURE=0 \
  "$bash_bin" "$test_root/scripts/ensure-goal-manager-binary.sh" \
  >/dev/null 2>"$goal_manager_timeout_stderr"; then
  echo "expected goal manager compile timeout" >&2
  exit 1
fi
grep -F 'goal manager compile timed out after 1s on attempt 1/2; retrying with warmed caches' "$goal_manager_timeout_stderr" >/dev/null
grep -F 'goal manager compile timed out after 1s across 2 attempt(s)' "$goal_manager_timeout_stderr" >/dev/null

goal_manager_stale_alias="$test_root/goal-manager-stale-alias/swarm-goal-manager"
goal_manager_stale_stderr="$test_root/goal-manager-stale.stderr"
mkdir -p "$(dirname "$goal_manager_stale_alias")"
cat > "$goal_manager_stale_alias" <<'EOF'
#!/usr/bin/env bash
if [[ "${CLASP_MANAGER_COMMAND:-}" == "status" || "${CLASP_LOOP_COMMAND:-}" == "status" ]]; then
  printf '{"state":{"phase":"needs-planner","verdict":"pending"}}\n'
  exit 0
fi
printf 'stale-goal-manager-ok\n'
EOF
chmod +x "$goal_manager_stale_alias"
cat > "$goal_manager_stale_alias.metadata.json" <<'JSON'
{
  "schemaVersion": 1,
  "kind": "clasp-goal-manager-binary",
  "source": "examples/swarm-native/GoalManager.wrapper.clasp",
  "cacheKey": "stale-fixture"
}
JSON
goal_manager_stale_binary="$(
  CLASP_GOAL_MANAGER_CLASPC_BIN="$test_root/bin/fake-slow-claspc" \
  CLASP_GOAL_MANAGER_CACHE_DIR="$test_root/goal-manager-stale-cache" \
  CLASP_GOAL_MANAGER_COMPILE_TIMEOUT_SECS=1 \
  CLASP_GOAL_MANAGER_COMPILE_ATTEMPTS=1 \
  "$bash_bin" "$test_root/scripts/ensure-goal-manager-binary.sh" \
  --alias "$goal_manager_stale_alias" \
  2>"$goal_manager_stale_stderr"
)"
[[ "$goal_manager_stale_binary" == "$goal_manager_stale_alias" ]]
"$goal_manager_stale_binary" | grep -F 'stale-goal-manager-ok' >/dev/null
grep -F 'goal manager compile failed; using validated stale goal manager binary:' "$goal_manager_stale_stderr" >/dev/null

goal_manager_invalid_stale_alias="$test_root/goal-manager-invalid-stale-alias/swarm-goal-manager"
goal_manager_invalid_stale_stderr="$test_root/goal-manager-invalid-stale.stderr"
mkdir -p "$(dirname "$goal_manager_invalid_stale_alias")"
cat > "$goal_manager_invalid_stale_alias" <<'EOF'
#!/usr/bin/env bash
printf 'stale-goal-manager-without-status-smoke\n'
EOF
chmod +x "$goal_manager_invalid_stale_alias"
if CLASP_GOAL_MANAGER_CLASPC_BIN="$test_root/bin/fake-slow-claspc" \
  CLASP_GOAL_MANAGER_CACHE_DIR="$test_root/goal-manager-invalid-stale-cache" \
  CLASP_GOAL_MANAGER_COMPILE_TIMEOUT_SECS=1 \
  CLASP_GOAL_MANAGER_COMPILE_ATTEMPTS=1 \
  "$bash_bin" "$test_root/scripts/ensure-goal-manager-binary.sh" \
  --alias "$goal_manager_invalid_stale_alias" \
  >/dev/null 2>"$goal_manager_invalid_stale_stderr"; then
  echo "expected invalid stale goal manager binary to be rejected" >&2
  exit 1
fi
grep -F 'stale goal manager candidate missing helper metadata:' "$goal_manager_invalid_stale_stderr" >/dev/null

cat > "$test_root/bin/fake-fast-claspc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=""
source_path=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      output="$2"
      shift 2
      ;;
    *.clasp)
      source_path="$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done
if [[ -z "$output" ]]; then
  echo "missing -o" >&2
  exit 1
fi
if [[ -n "${CLASP_TEST_FAKE_FAST_CLASPC_LOG:-}" ]]; then
  printf 'compile-source=%s\n' "$source_path" >>"$CLASP_TEST_FAKE_FAST_CLASPC_LOG"
  printf 'compile-output=%s\n' "$output" >>"$CLASP_TEST_FAKE_FAST_CLASPC_LOG"
fi
cat > "$output" <<SCRIPT
#!/usr/bin/env bash
if [[ "\${CLASP_MANAGER_COMMAND:-}" == "status" || "\${CLASP_LOOP_COMMAND:-}" == "status" ]]; then
  printf '{"state":{"phase":"needs-planner","verdict":"pending"}}\n'
  exit 0
fi
printf 'compiled-source=%s\n' '$source_path'
printf 'compiled-output=%s\n' '$output'
printf 'compiled-threshold=%s\n' '$CLASP_NATIVE_IMAGE_MONOLITHIC_DECL_THRESHOLD'
exit 0
SCRIPT
EOF
chmod +x "$test_root/bin/fake-fast-claspc"

goal_manager_cache="$test_root/goal-manager-cache"
goal_manager_alias="$test_root/goal-manager-alias/swarm-goal-manager"
goal_manager_fast_log="$test_root/fake-fast.log"
mkdir -p "$(dirname "$goal_manager_alias")"
printf '#!/usr/bin/env bash\nexit 42\n' >"$goal_manager_alias"
chmod +x "$goal_manager_alias"
goal_manager_binary_one="$(
  CLASP_TEST_FAKE_FAST_CLASPC_LOG="$goal_manager_fast_log" \
    CLASP_GOAL_MANAGER_CLASPC_BIN="$test_root/bin/fake-fast-claspc" \
    CLASP_GOAL_MANAGER_CACHE_DIR="$goal_manager_cache" \
    "$bash_bin" "$test_root/scripts/ensure-goal-manager-binary.sh" \
    --alias "$goal_manager_alias"
)"
goal_manager_binary_two="$(
  CLASP_TEST_FAKE_FAST_CLASPC_LOG="$goal_manager_fast_log" \
    CLASP_GOAL_MANAGER_CLASPC_BIN="$test_root/bin/fake-fast-claspc" \
    CLASP_GOAL_MANAGER_CACHE_DIR="$goal_manager_cache" \
    "$bash_bin" "$test_root/scripts/ensure-goal-manager-binary.sh"
)"
[[ "$goal_manager_binary_one" == "$goal_manager_binary_two" ]]
[[ -x "$goal_manager_binary_one" ]]
cmp -s "$goal_manager_binary_one" "$goal_manager_alias"
[[ -f "$goal_manager_binary_one.metadata.json" ]]
[[ -f "$goal_manager_alias.metadata.json" ]]
cmp -s "$goal_manager_binary_one.metadata.json" "$goal_manager_alias.metadata.json"
grep -F '"kind": "clasp-goal-manager-binary"' "$goal_manager_binary_one.metadata.json" >/dev/null
grep -F '"source": "examples/swarm-native/GoalManager.wrapper.clasp"' "$goal_manager_binary_one.metadata.json" >/dev/null
grep -F "compile-source=$test_root/examples/swarm-native/GoalManager.wrapper.clasp" "$goal_manager_fast_log" >/dev/null
"$goal_manager_alias" | grep -F "compiled-source=$test_root/examples/swarm-native/GoalManager.wrapper.clasp" >/dev/null
[[ "$(grep -c '^compile-source=' "$goal_manager_fast_log")" == "1" ]]
[[ -f "$(dirname "$goal_manager_binary_one")/compile.lock" ]]
[[ ! -e "$goal_manager_cache/compile.lock" ]]

goal_manager_missing_metadata_cache="$test_root/goal-manager-missing-metadata-cache"
goal_manager_missing_metadata_log="$test_root/fake-fast-missing-metadata.log"
goal_manager_missing_metadata_stderr="$test_root/fake-fast-missing-metadata.stderr"
goal_manager_missing_metadata_binary_one="$(
  CLASP_TEST_FAKE_FAST_CLASPC_LOG="$goal_manager_missing_metadata_log" \
    CLASP_GOAL_MANAGER_CLASPC_BIN="$test_root/bin/fake-fast-claspc" \
    CLASP_GOAL_MANAGER_CACHE_DIR="$goal_manager_missing_metadata_cache" \
    "$bash_bin" "$test_root/scripts/ensure-goal-manager-binary.sh"
)"
rm -f "$goal_manager_missing_metadata_binary_one.metadata.json"
goal_manager_missing_metadata_binary_two="$(
  CLASP_TEST_FAKE_FAST_CLASPC_LOG="$goal_manager_missing_metadata_log" \
    CLASP_GOAL_MANAGER_CLASPC_BIN="$test_root/bin/fake-fast-claspc" \
    CLASP_GOAL_MANAGER_CACHE_DIR="$goal_manager_missing_metadata_cache" \
    "$bash_bin" "$test_root/scripts/ensure-goal-manager-binary.sh" \
    2>"$goal_manager_missing_metadata_stderr"
)"
[[ "$goal_manager_missing_metadata_binary_one" == "$goal_manager_missing_metadata_binary_two" ]]
[[ -f "$goal_manager_missing_metadata_binary_two.metadata.json" ]]
[[ "$(grep -c '^compile-source=' "$goal_manager_missing_metadata_log")" == "2" ]]
grep -F 'cached goal manager candidate missing helper metadata:' "$goal_manager_missing_metadata_stderr" >/dev/null

goal_manager_cross_workspace_cache="$test_root/goal-manager-cross-workspace-cache"
goal_manager_cross_workspace_log="$test_root/fake-fast-cross-workspace.log"
for cross_workspace in "$test_root/cross-workspace-a" "$test_root/cross-workspace-b"; do
  mkdir -p "$cross_workspace/bin" "$cross_workspace/scripts" "$cross_workspace/examples/swarm-native"
  cp "$test_root/scripts/ensure-goal-manager-binary.sh" "$cross_workspace/scripts/ensure-goal-manager-binary.sh"
  cp "$test_root/bin/fake-fast-claspc" "$cross_workspace/bin/fake-fast-claspc"
  printf 'module Main\n\nimport Service\n\nmain : Str\nmain = service\n' > "$cross_workspace/examples/swarm-native/GoalManager.wrapper.clasp"
  printf 'module Service\nservice : Str\nservice = "same dependency"\n' > "$cross_workspace/examples/swarm-native/Service.clasp"
done
goal_manager_cross_workspace_binary_one="$(
  CLASP_TEST_FAKE_FAST_CLASPC_LOG="$goal_manager_cross_workspace_log" \
    CLASP_GOAL_MANAGER_CLASPC_BIN="$test_root/cross-workspace-a/bin/fake-fast-claspc" \
    CLASP_GOAL_MANAGER_CACHE_DIR="$goal_manager_cross_workspace_cache" \
    "$bash_bin" "$test_root/cross-workspace-a/scripts/ensure-goal-manager-binary.sh"
)"
goal_manager_cross_workspace_binary_two="$(
  CLASP_TEST_FAKE_FAST_CLASPC_LOG="$goal_manager_cross_workspace_log" \
    CLASP_GOAL_MANAGER_CLASPC_BIN="$test_root/cross-workspace-b/bin/fake-fast-claspc" \
    CLASP_GOAL_MANAGER_CACHE_DIR="$goal_manager_cross_workspace_cache" \
    "$bash_bin" "$test_root/cross-workspace-b/scripts/ensure-goal-manager-binary.sh"
)"
[[ "$goal_manager_cross_workspace_binary_one" == "$goal_manager_cross_workspace_binary_two" ]]
[[ "$(grep -c '^compile-source=' "$goal_manager_cross_workspace_log")" == "1" ]]

printf 'module Extra\nextra : Str\nextra = "ignored by wrapper import closure cache key"\n' > "$test_root/examples/swarm-native/Extra.clasp"
goal_manager_binary_after_unrelated_module="$(
  CLASP_TEST_FAKE_FAST_CLASPC_LOG="$goal_manager_fast_log" \
    CLASP_GOAL_MANAGER_CLASPC_BIN="$test_root/bin/fake-fast-claspc" \
    CLASP_GOAL_MANAGER_CACHE_DIR="$goal_manager_cache" \
    "$bash_bin" "$test_root/scripts/ensure-goal-manager-binary.sh"
)"
[[ "$goal_manager_binary_after_unrelated_module" == "$goal_manager_binary_two" ]]
[[ "$(grep -c '^compile-source=' "$goal_manager_fast_log")" == "1" ]]

printf 'module Service\nservice : Str\nservice = "changed dependency"\n' > "$test_root/examples/swarm-native/Service.clasp"
goal_manager_binary_after_dependency_change="$(
  CLASP_TEST_FAKE_FAST_CLASPC_LOG="$goal_manager_fast_log" \
    CLASP_GOAL_MANAGER_CLASPC_BIN="$test_root/bin/fake-fast-claspc" \
    CLASP_GOAL_MANAGER_CACHE_DIR="$goal_manager_cache" \
    "$bash_bin" "$test_root/scripts/ensure-goal-manager-binary.sh" \
    --alias "$goal_manager_alias"
)"
[[ "$goal_manager_binary_after_dependency_change" != "$goal_manager_binary_two" ]]
cmp -s "$goal_manager_binary_after_dependency_change" "$goal_manager_alias"
[[ "$(grep -c '^compile-source=' "$goal_manager_fast_log")" == "2" ]]

goal_manager_binary_after_build_mode_change="$(
  CLASP_TEST_FAKE_FAST_CLASPC_LOG="$goal_manager_fast_log" \
    CLASP_NATIVE_IMAGE_MONOLITHIC_DECL_THRESHOLD=1 \
    CLASP_GOAL_MANAGER_CLASPC_BIN="$test_root/bin/fake-fast-claspc" \
    CLASP_GOAL_MANAGER_CACHE_DIR="$goal_manager_cache" \
    "$bash_bin" "$test_root/scripts/ensure-goal-manager-binary.sh"
)"
[[ "$goal_manager_binary_after_build_mode_change" != "$goal_manager_binary_after_dependency_change" ]]
[[ "$(grep -c '^compile-source=' "$goal_manager_fast_log")" == "3" ]]

printf '\n# cache key content change\n' >>"$test_root/bin/fake-fast-claspc"
goal_manager_binary_after_claspc_change="$(
  CLASP_TEST_FAKE_FAST_CLASPC_LOG="$goal_manager_fast_log" \
    CLASP_GOAL_MANAGER_CLASPC_BIN="$test_root/bin/fake-fast-claspc" \
    CLASP_GOAL_MANAGER_CACHE_DIR="$goal_manager_cache" \
    "$bash_bin" "$test_root/scripts/ensure-goal-manager-binary.sh"
)"
[[ "$goal_manager_binary_after_claspc_change" != "$goal_manager_binary_after_dependency_change" ]]
[[ "$(grep -c '^compile-source=' "$goal_manager_fast_log")" == "4" ]]

mv "$test_root/examples/swarm-native/GoalManager.clasp" "$test_root/examples/swarm-native/GoalManager.clasp.off"
mv "$test_root/examples/swarm-native/GoalManager.wrapper.clasp" "$test_root/examples/swarm-native/GoalManager.wrapper.clasp.off"
goal_manager_split_fallback_log="$test_root/fake-fast-split-fallback.log"
goal_manager_split_fallback_binary="$(
  CLASP_TEST_FAKE_FAST_CLASPC_LOG="$goal_manager_split_fallback_log" \
    CLASP_GOAL_MANAGER_CLASPC_BIN="$test_root/bin/fake-fast-claspc" \
    CLASP_GOAL_MANAGER_CACHE_DIR="$test_root/goal-manager-split-fallback-cache" \
    "$bash_bin" "$test_root/scripts/ensure-goal-manager-binary.sh"
)"
[[ -x "$goal_manager_split_fallback_binary" ]]
grep -F "compile-source=$test_root/examples/swarm-native/GoalManagerProgram2.split.clasp" "$goal_manager_split_fallback_log" >/dev/null
mv "$test_root/examples/swarm-native/GoalManager.wrapper.clasp.off" "$test_root/examples/swarm-native/GoalManager.wrapper.clasp"
mv "$test_root/examples/swarm-native/GoalManager.clasp.off" "$test_root/examples/swarm-native/GoalManager.clasp"

goal_manager_xdg_cache="$test_root/xdg-goal-manager-cache"
goal_manager_xdg_binary="$(
  XDG_CACHE_HOME="$goal_manager_xdg_cache" \
    CLASP_TEST_FAKE_FAST_CLASPC_LOG="$goal_manager_fast_log" \
    CLASP_GOAL_MANAGER_CLASPC_BIN="$test_root/bin/fake-fast-claspc" \
    "$bash_bin" "$test_root/scripts/ensure-goal-manager-binary.sh"
)"
case "$goal_manager_xdg_binary" in
  "$goal_manager_xdg_cache"/goal-manager-fast/*/swarm-goal-manager)
    ;;
  *)
    printf 'goal manager cache did not respect XDG_CACHE_HOME: %s\n' "$goal_manager_xdg_binary" >&2
    exit 1
    ;;
esac

goal_manager_monolithic_cache="$test_root/goal-manager-monolithic-cache"
goal_manager_monolithic_log="$test_root/fake-fast-monolithic.log"
goal_manager_source_binary="$(
  CLASP_GOAL_MANAGER_SOURCE="$test_root/examples/swarm-native/GoalManager.clasp" \
    CLASP_TEST_FAKE_FAST_CLASPC_LOG="$goal_manager_monolithic_log" \
    CLASP_GOAL_MANAGER_CLASPC_BIN="$test_root/bin/fake-fast-claspc" \
    CLASP_GOAL_MANAGER_CACHE_DIR="$goal_manager_monolithic_cache" \
    "$bash_bin" "$test_root/scripts/ensure-goal-manager-binary.sh"
)"
goal_manager_source_binary_two="$(
  CLASP_GOAL_MANAGER_SOURCE="$test_root/examples/swarm-native/GoalManager.clasp" \
    CLASP_TEST_FAKE_FAST_CLASPC_LOG="$goal_manager_monolithic_log" \
    CLASP_GOAL_MANAGER_CLASPC_BIN="$test_root/bin/fake-fast-claspc" \
    CLASP_GOAL_MANAGER_CACHE_DIR="$goal_manager_monolithic_cache" \
    "$bash_bin" "$test_root/scripts/ensure-goal-manager-binary.sh"
)"
[[ "$goal_manager_source_binary" == "$goal_manager_source_binary_two" ]]
[[ -x "$goal_manager_source_binary" ]]
grep -F "compile-source=$test_root/examples/swarm-native/GoalManager.clasp" "$goal_manager_monolithic_log" >/dev/null
[[ "$(grep -c '^compile-source=' "$goal_manager_monolithic_log")" == "1" ]]
printf 'module Extra\nextra : Str\nextra = "still ignored by monolithic manager cache key"\n' > "$test_root/examples/swarm-native/Extra.clasp"
goal_manager_source_binary_after_extra="$(
  CLASP_GOAL_MANAGER_SOURCE="$test_root/examples/swarm-native/GoalManager.clasp" \
    CLASP_TEST_FAKE_FAST_CLASPC_LOG="$goal_manager_monolithic_log" \
    CLASP_GOAL_MANAGER_CLASPC_BIN="$test_root/bin/fake-fast-claspc" \
    CLASP_GOAL_MANAGER_CACHE_DIR="$goal_manager_monolithic_cache" \
    "$bash_bin" "$test_root/scripts/ensure-goal-manager-binary.sh"
)"
[[ "$goal_manager_source_binary_after_extra" == "$goal_manager_source_binary" ]]
[[ "$(grep -c '^compile-source=' "$goal_manager_monolithic_log")" == "1" ]]
printf 'module Swarm\nswarm : Str\nswarm = "changed monolithic dependency"\n' > "$test_root/examples/swarm-native/Swarm.clasp"
goal_manager_source_binary_after_swarm="$(
  CLASP_GOAL_MANAGER_SOURCE="$test_root/examples/swarm-native/GoalManager.clasp" \
    CLASP_TEST_FAKE_FAST_CLASPC_LOG="$goal_manager_monolithic_log" \
    CLASP_GOAL_MANAGER_CLASPC_BIN="$test_root/bin/fake-fast-claspc" \
    CLASP_GOAL_MANAGER_CACHE_DIR="$goal_manager_monolithic_cache" \
    "$bash_bin" "$test_root/scripts/ensure-goal-manager-binary.sh"
)"
[[ "$goal_manager_source_binary_after_swarm" != "$goal_manager_source_binary" ]]
[[ "$(grep -c '^compile-source=' "$goal_manager_monolithic_log")" == "2" ]]

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
lock_timeout_capture="$test_root/lock-timeout-nested.txt"
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
XDG_CACHE_HOME="$writable_cache_root" \
CLASP_TEST_NIX_ENV_CAPTURE="$env_capture" \
CLASP_TEST_NIX_MESSAGE='error: Path ".clasp-task-workspaces/task" in the repository "/repo" is not tracked by Git.' \
CLASP_VERIFY_FALLBACK_COMMANDS="$fallback_commands" \
CLASP_VERIFY_LOCK_FILE="$explicit_lock_file" \
"$bash_bin" "$test_root/scripts/verify-all.sh" >/dev/null 2>"$stderr_capture"

[[ "$(< "$fallback_capture")" == "fallback-ok" ]]
grep -F 'verify-all: falling back to sandbox verification because Nix is unavailable in this environment' "$stderr_capture" >/dev/null

rm -f "$fallback_capture" "$stderr_capture"
verify_fast_resolve_count="$test_root/verify-fast-resolve-count.txt"
verify_fast_claspc_capture="$test_root/verify-fast-claspc.txt"
verify_fast_claspc_bin_capture="$test_root/verify-fast-claspc-bin.txt"
cat > "$test_root/scripts/resolve-claspc.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
count_path="$verify_fast_resolve_count"
count=0
if [[ -f "\$count_path" ]]; then
  count="\$(cat "\$count_path")"
fi
count=\$((count + 1))
printf '%s' "\$count" >"\$count_path"
printf '%s\n' "$test_root/bin/fake-claspc"
EOF
chmod +x "$test_root/scripts/resolve-claspc.sh"
verify_fast_fallback_commands=$'printf fallback-ok > '"$fallback_capture"$'\nprintf %s "$CLASP_CLASPC" > '"$verify_fast_claspc_capture"$'\nprintf %s "$CLASPC_BIN" > '"$verify_fast_claspc_bin_capture"
PATH="$test_root/bin:$PATH" \
IN_NIX_SHELL= \
XDG_CACHE_HOME= \
CLASP_CLASPC="$test_root/bin/stale-claspc" \
CLASPC_BIN="$test_root/bin/stale-claspc" \
CLASP_TEST_NIX_ENV_CAPTURE="$env_capture" \
CLASP_VERIFY_FALLBACK_COMMANDS="$verify_fast_fallback_commands" \
CLASP_VERIFY_LOCK_FILE="$explicit_lock_file" \
"$bash_bin" "$test_root/scripts/verify-fast.sh" >/dev/null 2>"$stderr_capture"

[[ "$(< "$fallback_capture")" == "fallback-ok" ]]
[[ "$(< "$verify_fast_resolve_count")" == "1" ]]
[[ "$(< "$verify_fast_claspc_capture")" == "$test_root/bin/fake-claspc" ]]
[[ "$(< "$verify_fast_claspc_bin_capture")" == "$test_root/bin/fake-claspc" ]]
grep -F 'verify-fast: falling back to sandbox verification because Nix is unavailable in this environment' "$stderr_capture" >/dev/null

CLASP_PROJECT_ROOT="$test_root" "$bash_bin" "$test_root/scripts/verify-fast.sh" --help |
  grep -F 'usage: scripts/verify-fast.sh' >/dev/null
CLASP_PROJECT_ROOT="$test_root" "$bash_bin" "$test_root/scripts/verify-fast.sh" --help |
  grep -F -- '--changed-file PATH' >/dev/null
CLASP_PROJECT_ROOT="$test_root" "$bash_bin" "$test_root/scripts/verify-fast.sh" --help |
  grep -F -- '--affected' >/dev/null

verify_fast_report_arg="$test_root/verify-fast-report-arg.json"
verify_fast_report_arg_capture="$test_root/verify-fast-report-arg.txt"
rm -f "$verify_fast_report_arg" "$verify_fast_report_arg_capture" "$stderr_capture"
PATH="$test_root/bin:$PATH" \
IN_NIX_SHELL= \
XDG_CACHE_HOME= \
CLASP_TEST_NIX_ENV_CAPTURE="$env_capture" \
CLASP_VERIFY_FALLBACK_COMMANDS=$'printf report-arg-ok > '"$verify_fast_report_arg_capture" \
CLASP_VERIFY_LOCK_FILE="$explicit_lock_file" \
"$bash_bin" "$test_root/scripts/verify-fast.sh" --report-json "$verify_fast_report_arg" >/dev/null 2>"$stderr_capture"

[[ "$(< "$verify_fast_report_arg_capture")" == "report-arg-ok" ]]
node - "$verify_fast_report_arg" <<'NODE'
const fs = require("fs");
const report = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (report.label !== "verify-fast" || report.finalVerdict !== "passed" || report.mode !== "fallback") {
  console.error(`unexpected verify-fast --report-json report: ${JSON.stringify(report)}`);
  process.exit(1);
}
NODE

verify_fast_affected_args="$test_root/verify-fast-affected-args.txt"
cat > "$test_root/scripts/verify-affected.sh" <<EOF
#!$bash_bin
set -euo pipefail
printf '%s\n' "\$*" > "$verify_fast_affected_args"
EOF
chmod +x "$test_root/scripts/verify-affected.sh"
"$bash_bin" "$test_root/scripts/verify-fast.sh" \
  --changed-file src/Compiler/Checker.clasp \
  --report-json "$test_root/affected-report.json" \
  --plan-only >/dev/null
[[ "$(< "$verify_fast_affected_args")" == "--changed-file src/Compiler/Checker.clasp --report-json $test_root/affected-report.json --plan-only" ]]

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

fallback_report="$test_root/report-fallback.json"
fallback_report_capture="$test_root/fallback-report.txt"
rm -f "$fallback_report" "$fallback_report_capture" "$stderr_capture"
PATH="$test_root/bin:$PATH" \
IN_NIX_SHELL= \
XDG_CACHE_HOME= \
CLASP_TEST_NIX_ENV_CAPTURE="$env_capture" \
CLASP_VERIFY_FALLBACK_COMMANDS=$'printf fallback-report > '"$fallback_report_capture" \
CLASP_VERIFY_LOCK_FILE="$explicit_lock_file" \
CLASP_VERIFY_REPORT_JSON="$fallback_report" \
"$bash_bin" "$test_root/scripts/verify-all.sh" >/dev/null 2>"$stderr_capture"

[[ "$(< "$fallback_report_capture")" == "fallback-report" ]]
node - "$fallback_report" "$explicit_lock_file" <<'NODE'
const fs = require("fs");
const report = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const lockFile = process.argv[3];
function assert(condition, message) {
  if (!condition) {
    console.error(message);
    process.exit(1);
  }
}
assert(report.finalVerdict === "passed", "fallback report should pass");
assert(report.exitStatus === 0, "fallback report exit status should be zero");
assert(report.firstFailedCommand === null, "fallback success should not record a failed command");
assert(report.firstFailedExitStatus === null, "fallback success should not record a failed exit status");
assert(report.mode === "fallback", `unexpected fallback mode: ${report.mode}`);
assert(report.usedFallback === true, "fallback mode should be marked");
assert(report.usedNested === false, "fallback mode should not be nested");
assert(report.effectiveLockFile === lockFile, "fallback report should include effective lock file");
assert(report.commandCount === 1 && report.commands.length === 1, "fallback report should contain one fake command");
assert(report.commands[0].phase === "fallback", "fallback command should be tagged with fallback phase");
assert(Number.isInteger(report.commands[0].elapsedMs) && report.commands[0].elapsedMs >= 0, "fallback elapsedMs should be structural");
NODE

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

report_success="$test_root/report-success.json"
report_success_parallel_one="$test_root/report-parallel-one.txt"
report_success_parallel_two="$test_root/report-parallel-two.txt"
report_success_sequential="$test_root/report-sequential.txt"
rm -f "$report_success" "$report_success_parallel_one" "$report_success_parallel_two" "$report_success_sequential"
IN_NIX_SHELL= \
CLASP_VERIFY_USE_CURRENT_SHELL=1 \
CLASP_VERIFY_PARALLEL_JOBS=2 \
CLASP_VERIFY_PARALLEL_COMMANDS=$'printf report-parallel-one > '"$report_success_parallel_one"$'\nprintf report-parallel-two > '"$report_success_parallel_two" \
CLASP_VERIFY_SEQUENTIAL_COMMANDS=$'printf report-sequential > '"$report_success_sequential" \
CLASP_VERIFY_LOCK_FILE="$explicit_lock_file" \
CLASP_VERIFY_REPORT_JSON="$report_success" \
"$bash_bin" "$test_root/scripts/verify-all.sh" >/dev/null

[[ "$(< "$report_success_parallel_one")" == "report-parallel-one" ]]
[[ "$(< "$report_success_parallel_two")" == "report-parallel-two" ]]
[[ "$(< "$report_success_sequential")" == "report-sequential" ]]
node - "$report_success" "$explicit_lock_file" <<'NODE'
const fs = require("fs");
const report = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const lockFile = process.argv[3];
function assert(condition, message) {
  if (!condition) {
    console.error(message);
    process.exit(1);
  }
}
assert(report.schemaVersion === 1, "report schema version should be stable");
assert(report.label === "verify-all", "report should preserve the verify label");
assert(report.finalVerdict === "passed", "success report should pass");
assert(report.exitStatus === 0, "success exit status should be zero");
assert(report.firstFailedPhase === null, "success should not record a failed phase");
assert(report.firstFailedGroup === null, "success should not record a failed group");
assert(report.firstFailedCommand === null, "success should not record a failed command");
assert(report.firstFailedExitStatus === null, "success should not record a failed exit status");
assert(report.mode === "normal", `unexpected success mode: ${report.mode}`);
assert(report.usedFallback === false, "success should not use fallback");
assert(report.usedNested === false, "success should not use nested verification");
assert(report.lockHeld === true, "success report should observe the verify lock");
assert(report.effectiveLockFile === lockFile, "success report should include effective lock file");
assert(report.commandCount === 3 && report.commands.length === 3, "success report should contain all fake commands");
const phases = new Set(report.commands.map((command) => command.phase));
const groups = new Set(report.commands.map((command) => command.group));
assert(phases.has("parallel") && phases.has("sequential"), "success report should include parallel and sequential phases");
assert(groups.has("parallel") && groups.has("sequential"), "success report should include parallel and sequential groups");
assert(report.commands.filter((command) => command.group === "parallel").length === 2, "parallel group should contain two commands");
for (const command of report.commands) {
  assert(typeof command.command === "string" && command.command.length > 0, "command text should be recorded");
  assert(Number.isInteger(command.exitStatus), "command exit status should be an integer");
  assert(Number.isInteger(command.elapsedMs) && command.elapsedMs >= 0, "command elapsedMs should be structural");
  assert(command.endedAtMs >= command.startedAtMs, "command timestamps should be ordered");
}
assert(Number.isInteger(report.elapsedMs) && report.elapsedMs >= 0, "report elapsedMs should be structural");
NODE

report_failure="$test_root/report-failure.json"
report_failure_before="$test_root/report-failure-before.txt"
report_failure_after="$test_root/report-failure-after.txt"
rm -f "$report_failure" "$report_failure_before" "$report_failure_after"
if IN_NIX_SHELL= \
  CLASP_VERIFY_USE_CURRENT_SHELL=1 \
  CLASP_VERIFY_PARALLEL_COMMANDS= \
  CLASP_VERIFY_SEQUENTIAL_COMMANDS=$'printf before-failure > '"$report_failure_before"$'\nfalse\nprintf after-failure > '"$report_failure_after" \
  CLASP_VERIFY_LOCK_FILE="$explicit_lock_file" \
  CLASP_VERIFY_REPORT_JSON="$report_failure" \
  "$bash_bin" "$test_root/scripts/verify-all.sh" >/dev/null 2>"$test_root/report-failure.stderr"; then
  printf 'verify-all unexpectedly succeeded for report failure scenario\n' >&2
  exit 1
fi

[[ "$(< "$report_failure_before")" == "before-failure" ]]
[[ ! -f "$report_failure_after" ]]
grep -F 'verify-all: sequential command failed (exit 1): false' "$test_root/report-failure.stderr" >/dev/null
node - "$report_failure" <<'NODE'
const fs = require("fs");
const report = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
function assert(condition, message) {
  if (!condition) {
    console.error(message);
    process.exit(1);
  }
}
assert(report.finalVerdict === "failed", "failure report should fail");
assert(report.exitStatus !== 0, "failure report exit status should be non-zero");
assert(report.mode === "normal", `unexpected failure mode: ${report.mode}`);
assert(report.firstFailedPhase === "sequential", `failure phase: ${report.firstFailedPhase}`);
assert(report.firstFailedGroup === "sequential", `failure group: ${report.firstFailedGroup}`);
assert(report.firstFailedCommand === "false", `failure command: ${report.firstFailedCommand}`);
assert(report.firstFailedExitStatus !== 0, "failure exit status should be non-zero");
assert(report.commandCount === 2 && report.commands.length === 2, "failure report should stop after the failing command");
assert(report.commands[0].exitStatus === 0, "first failure scenario command should pass");
const failed = report.commands.find((command) => command.command === "false");
assert(failed && failed.exitStatus !== 0, "failing command should be recorded with non-zero status");
assert(!report.commands.some((command) => command.command.includes("after-failure")), "commands after failure should not be recorded");
for (const command of report.commands) {
  assert(command.phase === "sequential", "failure commands should be sequential");
  assert(Number.isInteger(command.elapsedMs) && command.elapsedMs >= 0, "failure elapsedMs should be structural");
}
NODE

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
nested_report="$test_root/report-nested.json"
PATH="$test_root/bin:$PATH" \
IN_NIX_SHELL= \
CLASP_VERIFY_IN_PROGRESS=1 \
CLASP_VERIFY_ACTIVE_ROOT="$test_root" \
CLASP_VERIFY_NESTED_COMMANDS=$'printf nested-ok > '"$writable_nested_capture" \
CLASP_VERIFY_LOCK_FILE="$explicit_lock_file" \
CLASP_VERIFY_REPORT_JSON="$nested_report" \
"$bash_bin" "$test_root/scripts/verify-all.sh" >/dev/null

[[ "$(< "$writable_nested_capture")" == "nested-ok" ]]
node - "$nested_report" <<'NODE'
const fs = require("fs");
const report = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
function assert(condition, message) {
  if (!condition) {
    console.error(message);
    process.exit(1);
  }
}
assert(report.finalVerdict === "passed", "nested report should pass");
assert(report.mode === "nested", `unexpected nested mode: ${report.mode}`);
assert(report.usedNested === true, "nested mode should be marked");
assert(report.usedFallback === false, "nested mode should not be fallback");
assert(report.commandCount === 1 && report.commands[0].phase === "nested", "nested command should be tagged");
assert(Number.isInteger(report.commands[0].elapsedMs) && report.commands[0].elapsedMs >= 0, "nested elapsedMs should be structural");
NODE

lock_timeout_report="$test_root/report-lock-timeout-nested.json"
rm -f "$lock_timeout_capture" "$stderr_capture" "$lock_timeout_report"
mkdir -p "${explicit_lock_file}.d"
printf '%s\n' "$$" > "${explicit_lock_file}.d/pid"
PATH="$test_root/bin:$PATH" \
IN_NIX_SHELL= \
CLASP_VERIFY_LOCK_FILE="$explicit_lock_file" \
CLASP_VERIFY_LOCK_TIMEOUT_SECS=1 \
CLASP_VERIFY_ON_LOCK_TIMEOUT=run-nested \
CLASP_VERIFY_NESTED_COMMANDS=$'printf lock-timeout-nested > '"$lock_timeout_capture" \
CLASP_VERIFY_REPORT_JSON="$lock_timeout_report" \
"$bash_bin" "$test_root/scripts/verify-all.sh" >/dev/null 2>"$stderr_capture"
rm -f "${explicit_lock_file}.d/pid"
rmdir "${explicit_lock_file}.d" >/dev/null 2>&1 || true

[[ "$(< "$lock_timeout_capture")" == "lock-timeout-nested" ]]
grep -F 'verify-all: verify lock busy after 1s; running nested verification' "$stderr_capture" >/dev/null
node - "$lock_timeout_report" <<'NODE'
const fs = require("fs");
const report = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
function assert(condition, message) {
  if (!condition) {
    console.error(message);
    process.exit(1);
  }
}
assert(report.finalVerdict === "passed", "lock-timeout nested report should pass");
assert(report.mode === "lock-timeout-nested", `unexpected lock-timeout nested mode: ${report.mode}`);
assert(report.usedNested === true, "lock-timeout nested mode should be marked");
assert(report.commandCount === 1 && report.commands[0].phase === "nested", "lock-timeout nested command should be tagged");
assert(Number.isInteger(report.commands[0].elapsedMs) && report.commands[0].elapsedMs >= 0, "lock-timeout elapsedMs should be structural");
NODE

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
