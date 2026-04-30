#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

require_pattern() {
  local path="$1"
  local pattern="$2"

  if ! grep -F -- "$pattern" "$project_root/$path" >/dev/null; then
    printf 'missing swarm-ready gate pattern in %s: %s\n' "$path" "$pattern" >&2
    exit 1
  fi
}

bash -n "$project_root/scripts/test-native-claspc.sh"
bash -n "$project_root/examples/swarm-kernel/scripts/verify.sh"
node "$project_root/scripts/check-promoted-native-image-exports.mjs" >/dev/null

require_pattern "examples/feedback-loop/Main.clasp" 'codexModel = readEnvText "CLASP_LOOP_CODEX_MODEL_JSON" "gpt-5.5"'
require_pattern "examples/feedback-loop/Main.clasp" 'codexReasoning = readEnvText "CLASP_LOOP_CODEX_REASONING_JSON" "xhigh"'
require_pattern "examples/feedback-loop/Main.clasp" 'watchModeEnabled'
require_pattern "examples/feedback-loop/Main.clasp" '"builder-running"'
require_pattern "examples/feedback-loop/Main.clasp" '"verifier-running"'
require_pattern "examples/feedback-loop/Main.clasp" 'Verification tier: focused.'
require_pattern "examples/feedback-loop/Main.clasp" 'Do not run `bash scripts/verify-all.sh` for this focused branch.'
require_pattern "examples/feedback-loop/Main.clasp" 'CLASP_LOOP_FOCUSED_VERIFIER_TIMEOUT_MS_JSON'
require_pattern "examples/feedback-loop/Main.clasp" 'ensureStepReportWithTimeout'
require_pattern "examples/feedback-loop/Process.clasp" 'awaitWatchedProcessTimeoutJson'

require_pattern "scripts/test-selfhost.sh" 'generate-promoted-module-summary-cache.mjs" --check'
require_pattern "scripts/test-selfhost.sh" 'check-promoted-native-image-exports.mjs'
require_pattern "scripts/test-selfhost.sh" 'contextSourceText'
require_pattern "scripts/test-selfhost.sh" 'surfaceIndex'
require_pattern "scripts/test-selfhost.sh" 'mockLeadSummaryModel'
require_pattern "scripts/test-selfhost.sh" 'module-summary promoted hit module=Compiler.Ast'
require_pattern "scripts/test-selfhost.sh" 'module-summary promoted hit module=Compiler.Emit.JavaScript'
require_pattern "scripts/test-selfhost.sh" 'module-summary promoted hit module=Main'
require_pattern "runtime/claspc.rs" 'stage1.compiler.module-summary-cache-v2.json'
require_pattern "runtime/claspc.rs" 'read_promoted_module_summary'

require_pattern "scripts/test-native-claspc.sh" 'feedback_loop_live_state_root'
require_pattern "scripts/test-native-claspc.sh" 'swarm_loop_builder_running_output'
require_pattern "scripts/test-native-claspc.sh" 'record-ergonomics-app'
require_pattern "scripts/test-native-claspc.sh" 'polymorphism-app'
require_pattern "scripts/test-native-claspc.sh" 'swarm_sqlite_wrong_tool_marker'
require_pattern "scripts/test-native-claspc.sh" 'swarm_sqlite_wrong_completed_verifier_marker'
require_pattern "scripts/test-native-claspc.sh" 'active lease is owned by `manager`'
require_pattern "scripts/test-native-claspc.sh" 'lease held by `worker-stale` expired'
require_pattern "scripts/test-native-claspc.sh" 'actor `intruder` is not a swarm manager'
require_pattern "scripts/test-native-claspc.sh" '"deadlineAtMs":4102444800000'
require_pattern "scripts/test-native-claspc.sh" '"mergeDecision":{"taskId":"repair-2","mergegateName":"trunk","verdict":"pass"}'

require_pattern "examples/swarm-native/Swarm.clasp" 'objectiveCreateWithDeadline'
require_pattern "examples/swarm-native/Swarm.clasp" 'taskCreateWithDeadline'
require_pattern "examples/swarm-native/Main.clasp" 'objectiveDeadlineAtMs'
require_pattern "runtime/swarm.rs" 'require_active_lease_owner'
require_pattern "runtime/swarm.rs" 'require_unexpired_lease_owner'
require_pattern "runtime/swarm.rs" 'require_manager_actor'
require_pattern "runtime/swarm.rs" 'builtin_swarm_objective_create_with_deadline'
require_pattern "runtime/swarm.rs" 'builtin_swarm_task_create_with_deadline'
