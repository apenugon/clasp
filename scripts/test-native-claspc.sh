#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
mkdir -p "$tmp_root"
export TMPDIR="$tmp_root"
test_root="$(mktemp -d "$TMPDIR/test-native-claspc.XXXXXX")"
test_root_abs="$(cd "$test_root" && pwd -P)"
export XDG_CACHE_HOME="$test_root/xdg-cache"
mkdir -p "$XDG_CACHE_HOME"
server_pid=""
feedback_loop_live_pid=""
goal_manager_live_pid=""

cleanup() {
  set +e
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" >/dev/null 2>&1 || true
    wait "$server_pid" >/dev/null 2>&1 || true
  fi
  if [[ -n "$feedback_loop_live_pid" ]]; then
    kill "$feedback_loop_live_pid" >/dev/null 2>&1 || true
    wait "$feedback_loop_live_pid" >/dev/null 2>&1 || true
  fi
  if [[ -n "$goal_manager_live_pid" ]]; then
    kill "$goal_manager_live_pid" >/dev/null 2>&1 || true
    wait "$goal_manager_live_pid" >/dev/null 2>&1 || true
  fi
  mapfile -t cleanup_descendant_pids < <(pgrep -f "$test_root" 2>/dev/null || true)
  if [[ ${#cleanup_descendant_pids[@]} -gt 0 ]]; then
    kill "${cleanup_descendant_pids[@]}" >/dev/null 2>&1 || true
    sleep 0.1
    kill -9 "${cleanup_descendant_pids[@]}" >/dev/null 2>&1 || true
  fi
  for _ in $(seq 1 20); do
    rm -rf "$test_root" >/dev/null 2>&1 && break
    sleep 0.1
  done
  rm -rf "$test_root" >/dev/null 2>&1 || true
}

finish() {
  local status=$?

  if [[ "${CLASP_TEST_KEEP_TMP:-}" == "1" && "$status" != "0" ]]; then
    printf 'preserved test root: %s\n' "$test_root_abs" >&2
  else
    cleanup
  fi

  exit "$status"
}

trap finish EXIT

stop_server() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" >/dev/null 2>&1 || true
    wait "$server_pid" >/dev/null 2>&1 || true
    server_pid=""
  fi
}

trace_case() {
  if [[ "${CLASP_TRACE_NATIVE_TESTS:-}" == "1" ]]; then
    printf '[test-native-claspc] %s\n' "$1" >&2
  fi
}

expect_command_failure_contains() {
  local expected="$1"
  shift
  local output
  local status

  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e

  if [[ "$status" == "0" ]]; then
    printf 'expected command to fail: %s\n' "$*" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
  if ! printf '%s\n' "$output" | grep -F "$expected" >/dev/null; then
    printf 'expected failure output to contain: %s\n' "$expected" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
}

wait_for_path_contains() {
  local path="$1"
  local pattern="$2"
  local live_pid="${3:-}"
  local attempts="${4:-300}"
  local sleep_seconds="${5:-0.05}"
  local attempt

  for attempt in $(seq 1 "$attempts"); do
    if [[ -f "$path" ]] && grep -F "$pattern" "$path" >/dev/null 2>&1; then
      return 0
    fi
    if [[ -n "$live_pid" ]] && ! kill -0 "$live_pid" >/dev/null 2>&1; then
      break
    fi
    sleep "$sleep_seconds"
  done

  echo "timed out waiting for '$pattern' in $path" >&2
  if [[ -f "$path" ]]; then
    sed -n '1,40p' "$path" >&2 || true
  fi
  return 1
}

json_number_field() {
  local path="$1"
  local field="$2"

  if [[ ! -f "$path" ]]; then
    return 0
  fi

  grep -o "\"$field\":[0-9]*" "$path" 2>/dev/null | head -1 | cut -d: -f2
}

service_supervisor_pid_for() {
  local state_root="$1"
  local supervisor_config="$state_root/service/supervisor.config.json"

  ps -eo pid=,args= | while read -r pid args; do
    case "$args" in
      *"$supervisor_config"*)
        if [[ "$pid" != "$$" ]]; then
          printf '%s\n' "$pid"
          break
        fi
        ;;
    esac
  done
}

kill_pid_if_live() {
  local pid="$1"

  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" >/dev/null 2>&1; then
    kill "$pid" >/dev/null 2>&1 || true
  fi
}

wait_or_kill_pid() {
  local pid="$1"
  local attempts="${2:-200}"
  local attempt

  if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
    return 0
  fi

  for attempt in $(seq 1 "$attempts"); do
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.05
  done

  kill "$pid" >/dev/null 2>&1 || true
  sleep 0.1
  kill -9 "$pid" >/dev/null 2>&1 || true
}

stop_goal_manager_service() {
  local state_root="$1"
  local service_json="$state_root/service/service.json"
  local owner_pid
  local supervisor_pid

  owner_pid="$(json_number_field "$service_json" "ownerPid")"
  supervisor_pid="$(service_supervisor_pid_for "$state_root" | head -1)"
  kill_pid_if_live "$supervisor_pid"
  kill_pid_if_live "$owner_pid"
  wait_or_kill_pid "$supervisor_pid" 100
  wait_or_kill_pid "$owner_pid" 100
  rm -f "$state_root/service/supervisor.lock"
}

native_export_host_socket_path() {
  local claspc_path="$1"
  local image_path="$2"
  local cache_root="$3"

  node - "$claspc_path" "$image_path" "$cache_root" <<'EOF'
const fs = require('node:fs');
const path = require('node:path');

const [claspcPath, imagePath, cacheRoot] = process.argv.slice(2);

function stableFingerprint(buffer) {
  let hash = 0xcbf29ce484222325n;
  for (const byte of buffer) {
    hash ^= BigInt(byte);
    hash = (hash * 0x100000001b3n) & 0xffffffffffffffffn;
  }
  return hash.toString(16).padStart(16, '0');
}

const hostKey = stableFingerprint(Buffer.concat([
  fs.readFileSync(claspcPath),
  fs.readFileSync(imagePath),
]));
const nativeDir = path.join(cacheRoot, 'claspc-native', 'export-host-v1');
const fileName = `${hostKey}.sock`;
let socketPath = path.join(nativeDir, fileName);

if (Buffer.byteLength(socketPath) >= 104) {
  const cacheRootKey = stableFingerprint(Buffer.from(nativeDir));
  socketPath = path.join('/tmp/clasp-native-export-host', 'export-host-v1', cacheRootKey, fileName);
}

process.stdout.write(`${socketPath}\n`);
EOF
}

build_root="$project_root/runtime"
claspc_bin="$("$project_root/scripts/resolve-claspc.sh")"
frontend_output="$test_root/hello.mjs"
backend_project_dir="$test_root/backend-project"
backend_project_path="$backend_project_dir/Main.clasp"
backend_binary="$test_root/backend-app"
cli_project_dir="$test_root/cli-project"
cli_project_path="$cli_project_dir/Main.clasp"
cli_binary="$test_root/cli-app"
cli_output_path="$test_root/argv.txt"
imported_cli_project_dir="$test_root/imported-cli-project"
imported_cli_project_path="$imported_cli_project_dir/Main.clasp"
imported_cli_binary="$test_root/imported-cli-app"
imported_cli_output_path="$test_root/imported-output.txt"
imported_cli_serial_image="$test_root/imported-cli-serial.native.image.json"
imported_cli_parallel_image="$test_root/imported-cli-parallel.native.image.json"
imported_cli_monolithic_image="$test_root/imported-cli-monolithic.native.image.json"
imported_cli_whole_monolithic_image="$test_root/imported-cli-whole-monolithic.native.image.json"
shared_cache_first_image="$test_root/shared-cache-first.native.image.json"
shared_cache_second_image="$test_root/shared-cache-second.native.image.json"
shared_cache_trace_log="$test_root/shared-cache-trace.log"
source_export_cache_root="$test_root/source-export-cache-root"
source_export_first_output="$test_root/source-export-first.txt"
source_export_second_output="$test_root/source-export-second.txt"
source_export_first_log="$test_root/source-export-first.log"
source_export_second_log="$test_root/source-export-second.log"
stale_host_cache_root="$test_root/stale-host-cache-root"
stale_host_output="$test_root/stale-host-output.txt"
stale_host_log="$test_root/stale-host.log"
native_incremental_report="$test_root/native-incremental-report.json"
list_ops_project_dir="$test_root/list-ops-project"
list_ops_project_path="$list_ops_project_dir/Main.clasp"
list_ops_binary="$test_root/list-ops-app"
record_ergonomics_project_dir="$test_root/record-ergonomics-project"
record_ergonomics_project_path="$record_ergonomics_project_dir/Main.clasp"
record_ergonomics_binary="$test_root/record-ergonomics-app"
polymorphism_binary="$test_root/polymorphism-app"
feedback_loop_binary="$test_root/feedback-loop-app"
feedback_loop_process_demo_binary="$test_root/feedback-loop-process-demo-app"
feedback_loop_codex_bin="$test_root/codex"
feedback_loop_benchmark_bin="$test_root/fake-benchmark"
feedback_loop_slow_benchmark_bin="$test_root/fake-benchmark-slow"
feedback_loop_task_file="$test_root/feedback-loop-task.md"
feedback_loop_state_root="$test_root/feedback-loop-state"
feedback_loop_workspace_root="$test_root/feedback-loop-workspace"
feedback_loop_workspace="$feedback_loop_workspace_root/workspace.txt"
feedback_loop_noise_root="$feedback_loop_workspace_root/.clasp-test-tmp"
feedback_loop_noise_path="$feedback_loop_noise_root/noise.txt"
feedback_loop_first_verifier_path="$feedback_loop_state_root/verifier-1.json"
feedback_loop_feedback_path="$feedback_loop_state_root/feedback.json"
feedback_loop_first_diff_path="$feedback_loop_state_root/changes-1.diff"
feedback_loop_second_diff_path="$feedback_loop_state_root/changes-2.diff"
feedback_loop_cache_root="$test_root/feedback-loop-baseline-cache"
feedback_loop_cache_baseline_workspace="$feedback_loop_cache_root/current-cache"
feedback_loop_cache_stale_root="$feedback_loop_cache_root/stale-cache"
feedback_loop_cache_stale_payload="$feedback_loop_cache_stale_root/payload.bin"
feedback_loop_cache_state_root="$test_root/feedback-loop-cache-state"
feedback_loop_cache_workspace_root="$test_root/feedback-loop-cache-workspace"
feedback_loop_cache_workspace="$feedback_loop_cache_workspace_root/workspace.txt"
feedback_loop_cache_noise_root="$feedback_loop_cache_workspace_root/.clasp-task-workspaces"
feedback_loop_cache_noise_path="$feedback_loop_cache_noise_root/noise.txt"
feedback_loop_cache_diff_path="$feedback_loop_cache_state_root/changes-1.diff"
feedback_loop_live_state_root="$test_root/feedback-loop-live-state"
feedback_loop_live_workspace_root="$test_root/feedback-loop-live-workspace"
feedback_loop_live_builder_stdout="$feedback_loop_live_state_root/builder-1.stdout.jsonl"
feedback_loop_live_builder_stderr="$feedback_loop_live_state_root/builder-1.stderr.log"
feedback_loop_live_builder_heartbeat="$feedback_loop_live_state_root/builder-1.heartbeat.json"
feedback_loop_live_output="$test_root/feedback-loop-live-output.txt"
feedback_loop_fail_state_root="$test_root/feedback-loop-fail-state"
feedback_loop_fail_workspace_root="$test_root/feedback-loop-fail-workspace"
feedback_loop_fail_feedback_path="$feedback_loop_fail_state_root/feedback.json"
feedback_loop_recovery_state_root="$test_root/feedback-loop-recovery-state"
feedback_loop_recovery_workspace_root="$test_root/feedback-loop-recovery-workspace"
feedback_loop_recovery_workspace="$feedback_loop_recovery_workspace_root/workspace.txt"
feedback_loop_recovery_feedback_path="$feedback_loop_recovery_state_root/feedback.json"
feedback_loop_recovery_builder_stdout="$feedback_loop_recovery_state_root/builder-2.stdout.jsonl"
feedback_loop_recovery_builder_stderr="$feedback_loop_recovery_state_root/builder-2.stderr.log"
feedback_loop_recovery_builder_heartbeat="$feedback_loop_recovery_state_root/builder-2.heartbeat.json"
feedback_loop_stdout_recovery_state_root="$test_root/feedback-loop-stdout-recovery-state"
feedback_loop_stdout_recovery_workspace_root="$test_root/feedback-loop-stdout-recovery-workspace"
feedback_loop_stdout_recovery_workspace="$feedback_loop_stdout_recovery_workspace_root/workspace.txt"
feedback_loop_handoff_state_root="$test_root/feedback-loop-handoff-state"
feedback_loop_handoff_child_state_root="$test_root/feedback-loop-handoff-child-state"
feedback_loop_handoff_child_workspace_root="$test_root/feedback-loop-handoff-child-workspace"
feedback_loop_handoff_child_workspace="$feedback_loop_handoff_child_workspace_root/workspace.txt"
feedback_loop_handoff_child_ready_path="$feedback_loop_handoff_child_state_root/loop.ready"
feedback_loop_handoff_output="$test_root/feedback-loop-handoff-output.txt"
feedback_loop_upgrade_child_workspace_root="$test_root/feedback-loop-upgrade-child-workspace"
swarm_kernel_binary="$test_root/swarm-kernel"
swarm_state_root="$test_root/swarm/state"
swarm_event_log="$swarm_state_root/events.jsonl"
swarm_loop_state_root="$test_root/swarm-loop/state"
swarm_loop_event_log="$swarm_loop_state_root/events.jsonl"
swarm_sqlite_state_root="$test_root/swarm-sqlite/state"
swarm_sqlite_db="$swarm_sqlite_state_root/swarm.db"
swarm_native_run_state_root="$test_root/swarm-native-run-state"
swarm_native_binary="$test_root/bin/swarm-native"
swarm_native_state_root="$test_root/swarm-native-state"
swarm_feedback_loop_binary="$test_root/bin/swarm-feedback-loop"
swarm_feedback_loop_state_root="$test_root/swarm-feedback-loop-state"
swarm_feedback_loop_workspace_root="$test_root/swarm-feedback-loop-workspace"
swarm_feedback_loop_workspace="$swarm_feedback_loop_workspace_root/workspace.txt"
swarm_feedback_loop_feedback_path="$swarm_feedback_loop_state_root/feedback.json"
swarm_feedback_loop_status_output="$test_root/swarm-feedback-loop-status.json"
swarm_feedback_loop_native_state_root="$test_root/swarm-feedback-loop-native-state"
swarm_feedback_loop_native_workspace_root="$test_root/swarm-feedback-loop-native-workspace"
swarm_feedback_loop_native_workspace="$swarm_feedback_loop_native_workspace_root/workspace.txt"
goal_manager_binary="$test_root/bin/swarm-goal-manager"
goal_manager_state_root="$test_root/swarm-goal-manager-state"
goal_manager_workspace_root="$test_root/swarm-goal-manager-workspace"
goal_manager_workspace="$goal_manager_workspace_root/workspace.txt"
goal_manager_feedback_path="$goal_manager_state_root/feedback.json"
goal_manager_status_output="$test_root/swarm-goal-manager-status.json"
goal_manager_native_state_root="$test_root/swarm-goal-manager-native-state"
goal_manager_native_workspace_root="$test_root/swarm-goal-manager-native-workspace"
goal_manager_native_workspace="$goal_manager_native_workspace_root/workspace.txt"
goal_manager_live_state_root="$test_root/swarm-goal-manager-live-state"
goal_manager_live_workspace_root="$test_root/swarm-goal-manager-live-workspace"
goal_manager_live_output="$test_root/swarm-goal-manager-live-output.txt"
goal_manager_live_status_output="$test_root/swarm-goal-manager-live-status.json"
support_console_binary="$test_root/support-console-app"
release_gate_binary="$test_root/release-gate-app"
lead_app_binary="$test_root/lead-app"
bootstrap_rejection="$test_root/bootstrap-rejection.json"
server_log="$test_root/native-server.log"
server_headers="$test_root/server-headers.txt"
server_body="$test_root/server-body.txt"
support_server_log="$test_root/support-server.log"
release_server_log="$test_root/release-server.log"
lead_server_log="$test_root/lead-server.log"

mkdir -p "$backend_project_dir"
cat >"$backend_project_path" <<'EOF'
module Main

record LeadRequest = { company : Str }
record LeadSummary = { summary : Str }

summarizeLead : LeadRequest -> LeadSummary
summarizeLead lead = LeadSummary { summary = lead.company }

showInbox : LeadRequest -> Page
showInbox lead = page lead.company (styled "lead_shell" (element "main" (append (element "p" (text "ready")) (append (link "/lead/redirect" (text "Open redirect")) (form "POST" "/lead/redirect" (append (input "company" "text" lead.company) (submit "Save")))))))

redirectToInbox : LeadRequest -> Redirect
redirectToInbox lead = redirect "/lead/inbox"

route summarizeLeadRoute = POST "/lead/summary" LeadRequest -> LeadSummary summarizeLead
route inboxRoute = GET "/lead/inbox" LeadRequest -> Page showInbox
route redirectRoute = POST "/lead/redirect" LeadRequest -> Redirect redirectToInbox

main : Str
main = "ok"
EOF

mkdir -p "$cli_project_dir"
cat >"$cli_project_path" <<EOF
module Main

argsText : Str
argsText = textJoin "," argv

main : Str
main = match writeFile "$(printf '%s' "$cli_output_path")" argsText {
  Ok written -> argsText,
  Err message -> message
}
EOF

mkdir -p "$imported_cli_project_dir/Shared"
cat >"$imported_cli_project_path" <<EOF
module Main
import Shared.User
import Shared.Render

main : Str
main = match writeFile "$(printf '%s' "$imported_cli_output_path")" (renderUser primaryUser) {
  Ok written -> renderUser primaryUser,
  Err message -> message
}
EOF

cat >"$imported_cli_project_dir/Shared/User.clasp" <<'EOF'
module Shared.User

record User = { name : Str, role : Str }

primaryUser : User
primaryUser = User { name = "Ada", role = "planner" }
EOF

cat >"$imported_cli_project_dir/Shared/Render.clasp" <<'EOF'
module Shared.Render
import Shared.User

renderUser : User -> Str
renderUser user = textJoin ":" [user.name, user.role]
EOF

mkdir -p "$list_ops_project_dir"
cat >"$list_ops_project_path" <<'EOF'
module Main

mark : Str -> Str
mark value = textJoin ":" [value, "reviewed"]

joinMarked : Str -> Str -> Str
joinMarked acc value = if acc == "" then value else textJoin "," [acc, value]

keepReviewed : Str -> Bool
keepReviewed value = value != "Ada:reviewed"

isGraceReviewed : Str -> Bool
isGraceReviewed value = value == "Grace:reviewed"

isReviewed : Str -> Bool
isReviewed value = textSplit value ":" != [value]

names : [Str]
names = reverse (prepend "Ada" ["Grace", "Linus"])

marked : [Str]
marked = map mark names

filtered : [Str]
filtered = filter keepReviewed marked

filteredCountIsTwo : Bool
filteredCountIsTwo = length filtered == 2

hasGrace : Bool
hasGrace = any isGraceReviewed filtered

allReviewed : Bool
allReviewed = all isReviewed filtered

adaLengthIsThree : Bool
adaLengthIsThree = length "Ada" == 3

main : Str
main = textJoin "|" [fold joinMarked "" filtered, if filteredCountIsTwo then "true" else "false", if hasGrace then "true" else "false", if allReviewed then "true" else "false", if adaLengthIsThree then "true" else "false"]
EOF

mkdir -p "$record_ergonomics_project_dir"
cat >"$record_ergonomics_project_path" <<'EOF'
module Main

record User = { name : Str, role : Str }

promote : User -> User
promote user = with user { name = "Grace" }

main : Str
main = let { name, role } = promote (User { name = "Ada", role = "planner" }) in textJoin ":" [name, role]
EOF

native_claspc_exhaustive="${CLASP_NATIVE_CLASPC_EXHAUSTIVE:-0}"

setup_exhaustive_native_cases() {
  mkdir -p "$feedback_loop_cache_workspace_root" "$feedback_loop_cache_noise_root" "$feedback_loop_cache_stale_root"
  printf '%s\n' 'cache-noise' >"$feedback_loop_cache_noise_path"
  dd if=/dev/zero of="$feedback_loop_cache_stale_payload" bs=1024 count=2048 status=none
}

if [[ "$native_claspc_exhaustive" != "0" ]]; then
  setup_exhaustive_native_cases
fi

mkdir -p "$feedback_loop_workspace_root"
mkdir -p "$feedback_loop_noise_root"
mkdir -p "$feedback_loop_live_workspace_root"
mkdir -p "$feedback_loop_fail_workspace_root"
mkdir -p "$feedback_loop_recovery_workspace_root"
mkdir -p "$feedback_loop_stdout_recovery_workspace_root"
mkdir -p "$feedback_loop_handoff_child_workspace_root"
mkdir -p "$feedback_loop_upgrade_child_workspace_root"
mkdir -p "$swarm_feedback_loop_workspace_root"
mkdir -p "$swarm_feedback_loop_native_workspace_root"
mkdir -p "$goal_manager_workspace_root"
mkdir -p "$goal_manager_native_workspace_root"
mkdir -p "$goal_manager_live_workspace_root"
cat >"$feedback_loop_task_file" <<'EOF'
Make the feedback loop converge after verifier feedback.
EOF
printf '%s\n' 'transient-noise' >"$feedback_loop_noise_path"

cat >"$feedback_loop_codex_bin" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

workspace_root="."
report_path=""
prompt=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    exec)
      shift
      ;;
    --json|--skip-git-repo-check|--ephemeral)
      shift
      ;;
    --cd)
      workspace_root="$2"
      shift 2
      ;;
    -m|-c|--sandbox|--output-schema)
      shift 2
      ;;
    -o|--output-last-message)
      report_path="$2"
      shift 2
      ;;
    *)
      prompt="$1"
      shift
      ;;
  esac
done

if [[ -z "$report_path" ]]; then
  printf 'missing report path\n' >&2
  exit 1
fi

feedback_path="$(dirname "$report_path")/feedback.json"
builder_policy_path="$(dirname "$report_path")/builder-policy.md"
planner_mode="${CLASP_TEST_FAKE_PLANNER_MODE:-default}"
task_loop="$(basename "$(dirname "$report_path")")"
task_id="${task_loop#loop-}"
workspace_file="workspace.txt"
artifact_file="child-artifact.txt"
if [[ "$planner_mode" == "parallel-ready" && "${CLASP_TEST_FAKE_PROMOTION_CONFLICT:-0}" != "1" ]]; then
  workspace_file="$task_id.txt"
  artifact_file="$task_id.txt"
fi
workspace_path="$workspace_root/$workspace_file"
artifact_path="$workspace_root/notes/$artifact_file"

emit_report_payload() {
  local payload
  payload="$(cat)"
  if [[ "${CLASP_TEST_FAKE_STDOUT_ONLY_REPORT:-0}" == "1" ]]; then
    node -e 'const fs = require("fs"); const payload = fs.readFileSync(0, "utf8"); process.stdout.write(JSON.stringify({ type: "agent_message", text: payload }) + "\n");' <<<"$payload"
    return 0
  fi
  if [[ "${CLASP_TEST_FAKE_DELAYED_REPORT_SECS:-0}" != "0" ]]; then
    (
      sleep "${CLASP_TEST_FAKE_DELAYED_REPORT_SECS:-0}"
      printf '%s\n' "$payload" >"$report_path"
    ) &
    return 0
  fi
  printf '%s\n' "$payload" >"$report_path"
}

if [[ "$prompt" == *"planner subagent"* ]]; then
  printf '{"phase":"planner-start"}\n'
  printf 'planner-progress\n' >&2
  sleep "${CLASP_TEST_FAKE_CODEX_SLEEP_SECS:-0.3}"
  if [[ "$planner_mode" == "cycle" ]]; then
    emit_report_payload <<'JSON'
{"objectiveSummary":"Improve Clasp with a cyclic planner DAG.","strategy":"Return an invalid cyclic plan so the goal manager has to reject it before spawning work.","tasks":[{"taskId":"cycle-a","role":"speculative-branch","detail":"First cyclic task.","dependencies":["cycle-b"],"taskPrompt":"This task participates in a cycle.","coordinationFocus":["cycle-detection","preflight-validation"]},{"taskId":"cycle-b","role":"speculative-branch","detail":"Second cyclic task.","dependencies":["cycle-a"],"taskPrompt":"This task participates in a cycle.","coordinationFocus":["cycle-detection","preflight-validation"]}],"testsRun":["planned-with-fake-codex"],"residualRisks":[]}
JSON
  elif [[ "$planner_mode" == "reserved-dependency" ]]; then
    emit_report_payload <<'JSON'
{"objectiveSummary":"Improve Clasp with an invalid planner dependency.","strategy":"Return a planner report that incorrectly depends on the reserved planner task.","tasks":[{"taskId":"stabilize-loop","role":"control-plane-hardener","detail":"Stabilize the ordinary Clasp feedback loop manager path.","dependencies":["planner"],"taskPrompt":"Strengthen the ordinary Clasp loop path so it remains durable and easy to inspect.","coordinationFocus":["service-continuity","ordinary-program-execution"]}],"testsRun":["planned-with-fake-codex"],"residualRisks":[]}
JSON
  elif [[ "$planner_mode" == "replan" ]]; then
    emit_report_payload <<'JSON'
{"objectiveSummary":"Improve Clasp with a replanned task DAG.","strategy":"Ignore stale planner state and produce a fresh bounded task graph.","tasks":[{"taskId":"refresh-plan","role":"replanner","detail":"Refresh the planner-managed ordinary loop path after planner inputs change.","dependencies":[],"taskPrompt":"Refresh the ordinary loop plan after planner inputs change and keep the execution path durable.","coordinationFocus":["planner-input-refresh","durable-state"]},{"taskId":"close-gap","role":"verification-closer","detail":"Close the remaining verification gap after the replanned ordinary loop task lands.","dependencies":["refresh-plan"],"taskPrompt":"Close the remaining verification gap after replanning the ordinary loop path.","coordinationFocus":["verification-gate","scenario-closure"]}],"testsRun":["planned-with-fake-codex","replanned-after-input-change"],"residualRisks":[]}
JSON
  elif [[ "$planner_mode" == "parallel-ready" ]]; then
    emit_report_payload <<'JSON'
{"objectiveSummary":"Improve Clasp with parallel bounded branches.","strategy":"Run two independent bounded branches at the same time so the manager has to fan out child loops.","tasks":[{"taskId":"stabilize-loop","role":"control-plane-hardener","detail":"Stabilize the ordinary Clasp feedback loop manager path.","dependencies":[],"taskPrompt":"Strengthen the ordinary Clasp loop path so it remains durable and easy to inspect.","coordinationFocus":["service-continuity","loop-durability"]},{"taskId":"tighten-verify","role":"verification-closer","detail":"Tighten verification and substrate inspection in parallel.","dependencies":[],"taskPrompt":"Tighten verification coverage and substrate inspection as a parallel improvement branch.","coordinationFocus":["verification-gate","inspection-artifacts"]}],"testsRun":["planned-with-fake-codex","parallel-ready-plan"],"residualRisks":[]}
JSON
  elif [[ "$planner_mode" == "parallel-branch-failure" ]]; then
    emit_report_payload <<'JSON'
{"objectiveSummary":"Improve Clasp with speculative parallel branches.","strategy":"Run two parallel improvement branches so the manager can keep going even if one branch fails.","tasks":[{"taskId":"winning-branch","role":"primary-closer","detail":"Land the bounded improvement branch that should converge.","dependencies":[],"taskPrompt":"Close the winning bounded improvement branch and converge it through the ordinary feedback loop.","coordinationFocus":["landing-path","benchmark-closure"]},{"taskId":"failing-branch","role":"speculative-probe","detail":"Try a speculative branch that is expected to fail verification.","dependencies":[],"taskPrompt":"Attempt the speculative branch even though it is expected to fail verification so the manager can keep exploring other branches.","coordinationFocus":["risk-probing","alternative-approach"]}],"testsRun":["planned-with-fake-codex","parallel-branch-failure"],"residualRisks":[]}
JSON
  elif [[ "$planner_mode" == "benchmark-replan" ]]; then
    if [[ "$prompt" == *"Current wave: 2 of"* ]]; then
      emit_report_payload <<'JSON'
{"objectiveSummary":"Finish the remaining AppBench closure wave.","strategy":"Use the benchmark checkpoint from wave 1 to close the remaining gap with one more bounded wave.","tasks":[{"taskId":"benchmark-finish","role":"benchmark-closer","detail":"Close the remaining benchmark gap.","dependencies":[],"taskPrompt":"Finish the remaining bounded improvement wave so the benchmark target can pass.","coordinationFocus":["score-improvement","checkpoint-reuse"]}],"testsRun":["planned-with-fake-codex","benchmark-replanned"],"residualRisks":[]}
JSON
    else
      emit_report_payload <<'JSON'
{"objectiveSummary":"Reduce the AppBench gap with an initial wave.","strategy":"Start with one bounded implementation wave, then re-check the benchmark before deciding whether to continue.","tasks":[{"taskId":"benchmark-gap","role":"benchmark-operator","detail":"Close the first benchmark gap.","dependencies":[],"taskPrompt":"Make the first bounded improvement wave toward beating the benchmark target.","coordinationFocus":["baseline-gap","wave-planning"]}],"testsRun":["planned-with-fake-codex","benchmark-wave-1"],"residualRisks":[]}
JSON
    fi
  else
    emit_report_payload <<'JSON'
{"objectiveSummary":"Improve Clasp with a planner-managed task DAG.","strategy":"Stabilize the ordinary loop first, then tighten verification and substrate confidence.","tasks":[{"taskId":"stabilize-loop","role":"control-plane-hardener","detail":"Stabilize the ordinary Clasp feedback loop manager path.","dependencies":[],"taskPrompt":"Strengthen the ordinary Clasp loop path so it remains durable and easy to inspect.","coordinationFocus":["service-continuity","loop-durability"]},{"taskId":"tighten-verify","role":"verification-closer","detail":"Tighten verification and substrate inspection after the loop is stable.","dependencies":["stabilize-loop"],"taskPrompt":"Tighten verification coverage and substrate inspection once the ordinary loop path is stable.","coordinationFocus":["verification-gate","inspection-artifacts"]}],"testsRun":["planned-with-fake-codex"],"residualRisks":[]}
JSON
  fi
elif [[ "$prompt" == *"builder subagent"* ]]; then
  printf '{"phase":"builder-start"}\n'
  printf 'builder-progress\n' >&2
  sleep "${CLASP_TEST_FAKE_CODEX_SLEEP_SECS:-0.3}"
  content="first-attempt"
  if [[ -f "$feedback_path" && "$prompt" == *"Verifier feedback from the previous attempt:"* && "$prompt" == *"force-close-category"* ]]; then
    content="fixed-after-feedback"
  fi
  if [[ "${CLASP_TEST_FAKE_PROMOTION_CONFLICT:-0}" == "1" && "$content" == "fixed-after-feedback" ]]; then
    content="fixed-after-feedback-$task_id"
  fi
  printf '%s\n' "$content" >"$workspace_path"
  mkdir -p "$workspace_root/notes"
  printf '%s\n' "$content" >"$artifact_path"
  mkdir -p "$workspace_root/.clasp-test-tmp"
  printf '%s\n' 'transient-noise' >"$workspace_root/.clasp-test-tmp/noise.txt"
  mkdir -p "$workspace_root/benchmarks/workspaces/generated" "$workspace_root/benchmarks/results"
  printf '%s\n' 'generated-benchmark-noise' >"$workspace_root/benchmarks/workspaces/generated/noise.txt"
  printf '%s\n' 'generated-benchmark-result' >"$workspace_root/benchmarks/results/noise.txt"
  emit_report_payload <<JSON
{"summary":"builder wrote $content","files_touched":["$workspace_file","notes/$artifact_file"],"tests_run":[],"residual_risks":[],"feedback":{"summary":"use verifier feedback","ergonomics":["ordinary loop works"],"follow_ups":["keep direct codex invocation"],"warnings":[]}}
JSON
elif [[ "$prompt" == *"verifier subagent"* ]]; then
  printf '{"phase":"verifier-start"}\n'
  printf 'verifier-progress\n' >&2
  sleep "${CLASP_TEST_FAKE_CODEX_SLEEP_SECS:-0.3}"
  content=""
  if [[ -f "$workspace_path" ]]; then
    content="$(cat "$workspace_path")"
  fi
  if [[ "$prompt" == *"task-failing-branch.md"* ]]; then
    emit_report_payload <<'JSON'
{"verdict":"fail","summary":"speculative branch should not land","findings":["This branch intentionally fails so the manager has to keep going with other branches."],"tests_run":["speculative branch review"],"follow_up":["Keep the successful parallel branches moving and let the benchmark checkpoint decide whether another wave is needed."],"capability_statuses":[{"name":"ordinary_program_execution","status":"fail","evidence":["speculative branch stayed red"],"blocking_gaps":["this branch does not converge"],"required_closure":["Use another branch or a later wave instead of landing this task."]},{"name":"durable_native_substrate","status":"pass","evidence":["failure is deliberate, not a substrate crash"],"blocking_gaps":[],"required_closure":[]},{"name":"clasp_native_control_api","status":"pass","evidence":["manager can consume this structured verifier failure"],"blocking_gaps":[],"required_closure":[]},{"name":"orchestration_viability","status":"pass","evidence":["manager should continue after this failed branch"],"blocking_gaps":[],"required_closure":[]},{"name":"ergonomics","status":"pass","evidence":["fixture does not model ergonomic blockers"],"blocking_gaps":[],"required_closure":[]},{"name":"verification_gate","status":"fail","evidence":["branch is intentionally non-landing"],"blocking_gaps":["speculative branch should stay out of the landing set"],"required_closure":["Let another branch or another wave carry the benchmark target."]}]}
JSON
  elif [[ "$content" == fixed-after-feedback* ]]; then
    emit_report_payload <<'JSON'
{"verdict":"pass","summary":"feedback loop converged","findings":[],"tests_run":["workspace converged"],"follow_up":[],"capability_statuses":[{"name":"ordinary_program_execution","status":"pass","evidence":["workspace converged after verifier feedback"],"blocking_gaps":[],"required_closure":[]},{"name":"durable_native_substrate","status":"pass","evidence":["test fixture does not model substrate gaps"],"blocking_gaps":[],"required_closure":[]},{"name":"clasp_native_control_api","status":"pass","evidence":["feedback loop prompt included previous verifier feedback directly"],"blocking_gaps":[],"required_closure":[]},{"name":"orchestration_viability","status":"pass","evidence":["ordinary loop completed end to end"],"blocking_gaps":[],"required_closure":[]},{"name":"ergonomics","status":"pass","evidence":["test fixture did not expose ergonomic blockers"],"blocking_gaps":[],"required_closure":[]},{"name":"verification_gate","status":"pass","evidence":["workspace converged"],"blocking_gaps":[],"required_closure":[]}]}
JSON
  else
    printf '%s\n' 'force-close-category' >"$builder_policy_path"
    emit_report_payload <<'JSON'
{"verdict":"fail","summary":"workspace still needs feedback","findings":["workspace.txt still has the first-attempt content"],"tests_run":["workspace converged"],"follow_up":["Close the ordinary_program_execution category by using the verifier feedback to update workspace.txt."],"capability_statuses":[{"name":"ordinary_program_execution","status":"fail","evidence":["workspace.txt still has the first-attempt content"],"blocking_gaps":["builder did not consume the previous verifier feedback"],"required_closure":["Use the verifier feedback to update workspace.txt."]},{"name":"durable_native_substrate","status":"pass","evidence":["test fixture does not model substrate gaps"],"blocking_gaps":[],"required_closure":[]},{"name":"clasp_native_control_api","status":"pass","evidence":["direct Codex invocation path is present in the fixture"],"blocking_gaps":[],"required_closure":[]},{"name":"orchestration_viability","status":"fail","evidence":["loop has not converged yet"],"blocking_gaps":["builder/verifier cycle has not closed the blocking category"],"required_closure":["Make the next builder attempt consume the previous verifier feedback and converge."]},{"name":"ergonomics","status":"pass","evidence":["test fixture does not expose ergonomic blockers"],"blocking_gaps":[],"required_closure":[]},{"name":"verification_gate","status":"fail","evidence":["final convergence has not happened yet"],"blocking_gaps":["workspace still fails the acceptance check"],"required_closure":["Converge the workspace on the next attempt."]}]}
JSON
  fi
else
  printf 'unknown prompt\n' >&2
  exit 1
fi
EOF
chmod +x "$feedback_loop_codex_bin"

cat >"$feedback_loop_benchmark_bin" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

mode="${CLASP_TEST_FAKE_BENCHMARK_MODE:-replan-pass}"
counter_root="${CLASP_MANAGER_STATE_ROOT:-$PWD}"
counter_path="${counter_root}/.clasp-fake-benchmark-count"
mkdir -p "$counter_root"
count=0
if [[ -f "$counter_path" ]]; then
  count="$(cat "$counter_path")"
fi
count=$((count + 1))
printf '%s\n' "$count" >"$counter_path"

case "$mode" in
  replan-pass)
    if [[ "$count" -eq 1 ]]; then
      cat <<'JSON'
{"suite":"appbench","summary":"AppBench target still unmet after wave 1.","passed":true,"meetsTarget":false,"scoreName":"timeToGreenMs","scoreValue":140,"targetName":"maxTimeToGreenMs","targetValue":120}
JSON
    else
      cat <<'JSON'
{"suite":"appbench","summary":"AppBench target met after wave 2.","passed":true,"meetsTarget":true,"scoreName":"timeToGreenMs","scoreValue":110,"targetName":"maxTimeToGreenMs","targetValue":120}
JSON
    fi
    ;;
  always-fail)
    cat <<'JSON'
{"suite":"appbench","summary":"AppBench target is still unmet after the allowed waves.","passed":true,"meetsTarget":false,"scoreName":"timeToGreenMs","scoreValue":145,"targetName":"maxTimeToGreenMs","targetValue":120}
JSON
    ;;
  already-pass)
    cat <<'JSON'
{"suite":"appbench","summary":"AppBench target is already met.","passed":true,"meetsTarget":true,"scoreName":"timeToGreenMs","scoreValue":100,"targetName":"maxTimeToGreenMs","targetValue":120}
JSON
    ;;
  *)
    printf 'unknown fake benchmark mode: %s\n' "$mode" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$feedback_loop_benchmark_bin"

cat >"$feedback_loop_slow_benchmark_bin" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${CLASP_TEST_FAKE_BENCHMARK_SLOW_MODE:-}" == "signal-before-sleep" ]]; then
cat <<'JSON'
{"suite":"appbench","summary":"slow benchmark eventually finished.","passed":true,"meetsTarget":true,"scoreName":"timeToGreenMs","scoreValue":100,"targetName":"maxTimeToGreenMs","targetValue":120}
JSON
fi
sleep "${CLASP_TEST_FAKE_BENCHMARK_SLEEP_SECS:-5}"
if [[ "${CLASP_TEST_FAKE_BENCHMARK_SLOW_MODE:-}" == "signal-before-sleep" ]]; then
  exit 0
fi
printf 'fake benchmark log before signal\n'
cat <<'JSON'
{"suite":"appbench","summary":"slow benchmark eventually finished.","passed":true,"meetsTarget":true,"scoreName":"timeToGreenMs","scoreValue":100,"targetName":"maxTimeToGreenMs","targetValue":120}
JSON
EOF
chmod +x "$feedback_loop_slow_benchmark_bin"

[[ -x "$claspc_bin" ]]

"$claspc_bin" --json check "$project_root/examples/hello.clasp" | grep -F '"status":"ok"' >/dev/null
"$claspc_bin" compile "$project_root/examples/hello.clasp" -o "$frontend_output"
grep -F '// Generated by compiler-selfhost' "$frontend_output" >/dev/null
release_gate_check="$("$claspc_bin" --json check "$project_root/examples/release-gate/Main.clasp")"
printf '%s\n' "$release_gate_check" | grep -F '"status":"ok"' >/dev/null
printf '%s\n' "$release_gate_check" | grep -F 'opsSession : AuthSession' >/dev/null
printf '%s\n' "$release_gate_check" | grep -F 'opsTenantId : AuthSession -> Str' >/dev/null
printf '%s\n' "$release_gate_check" | grep -F 'dashboard : Empty -> Page' >/dev/null
lead_app_check="$("$claspc_bin" --json check "$project_root/examples/lead-app/Main.clasp")"
printf '%s\n' "$lead_app_check" | grep -F '"status":"ok"' >/dev/null
printf '%s\n' "$lead_app_check" | grep -F 'outreachPrompt : LeadRecord -> LeadPlaybook -> Prompt' >/dev/null
printf '%s\n' "$lead_app_check" | grep -F 'outreachPromptText : LeadRecord -> LeadPlaybook -> Str' >/dev/null
printf '%s\n' "$lead_app_check" | grep -F 'draftLeadOutreach : LeadRecord -> LeadPlaybook -> LeadOutreachDraft' >/dev/null
support_console_check="$("$claspc_bin" --json check "$project_root/examples/support-console/Main.clasp")"
printf '%s\n' "$support_console_check" | grep -F '"status":"ok"' >/dev/null
printf '%s\n' "$support_console_check" | grep -F 'supportSession : AuthSession' >/dev/null
printf '%s\n' "$support_console_check" | grep -F 'currentCustomer : SupportCustomer' >/dev/null
printf '%s\n' "$support_console_check" | grep -F 'dashboard : Empty -> Page' >/dev/null

env RUSTC=/definitely-missing-rustc "$claspc_bin" compile "$backend_project_path" -o "$backend_binary"
[[ -x "$backend_binary" ]]
"$backend_binary" | grep -F 'ok' >/dev/null
"$backend_binary" route POST /lead/summary '{"company":"Acme"}' | grep -F '{"summary":"Acme"}' >/dev/null
page_json="$("$backend_binary" route GET /lead/inbox '{"company":"Inbox"}')"
printf '%s\n' "$page_json" | grep -F '"kind":"page"' >/dev/null
printf '%s\n' "$page_json" | grep -F '"title":"Inbox"' >/dev/null
printf '%s\n' "$page_json" | grep -F '"body":{"kind":"styled","styleRef":"lead_shell"' >/dev/null
printf '%s\n' "$page_json" | grep -F '"tag":"main"' >/dev/null
printf '%s\n' "$page_json" | grep -F '"kind":"link","href":"/lead/redirect"' >/dev/null
printf '%s\n' "$page_json" | grep -F '"kind":"form","method":"POST","action":"/lead/redirect"' >/dev/null
printf '%s\n' "$page_json" | grep -F '"kind":"input","fieldName":"company","inputKind":"text","value":"Inbox"' >/dev/null
printf '%s\n' "$page_json" | grep -F '"kind":"submit","label":"Save"' >/dev/null
"$backend_binary" route POST /lead/redirect '{"company":"Inbox"}' | grep -F '{"kind":"redirect","location":"/lead/inbox"}' >/dev/null

server_port="$(node -e 'const net=require("node:net"); const server=net.createServer(); server.listen(0, "127.0.0.1", () => { console.log(server.address().port); server.close(); });')"
server_addr="127.0.0.1:$server_port"
"$backend_binary" serve "$server_addr" >"$server_log" 2>&1 &
server_pid=$!
for _ in $(seq 1 50); do
  if curl -sS -o /dev/null -X GET -H 'content-type: application/json' --data '{"company":"Inbox"}' "http://$server_addr/lead/inbox" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
server_page_json="$(curl -sS -X GET -H 'content-type: application/json' --data '{"company":"Inbox"}' "http://$server_addr/lead/inbox")"
printf '%s\n' "$server_page_json" | grep -F '"kind":"page"' >/dev/null
printf '%s\n' "$server_page_json" | grep -F '"title":"Inbox"' >/dev/null
curl -sS -D "$server_headers" -o "$server_body" -X POST -H 'content-type: application/json' --data '{"company":"Inbox"}' "http://$server_addr/lead/redirect" >/dev/null
grep -F 'HTTP/1.1 303 See Other' "$server_headers" >/dev/null
grep -Fi 'Location: /lead/inbox' "$server_headers" >/dev/null
grep -F '{"kind":"redirect","location":"/lead/inbox"}' "$server_body" >/dev/null
stop_server

env RUSTC=/definitely-missing-rustc "$claspc_bin" compile "$cli_project_path" -o "$cli_binary"
[[ -x "$cli_binary" ]]
"$cli_binary" alpha beta | grep -F 'alpha,beta' >/dev/null
grep -F 'alpha,beta' "$cli_output_path" >/dev/null

env RUSTC=/definitely-missing-rustc "$claspc_bin" compile "$imported_cli_project_path" -o "$imported_cli_binary"
[[ -x "$imported_cli_binary" ]]
"$imported_cli_binary" | grep -F 'Ada:planner' >/dev/null
grep -F 'Ada:planner' "$imported_cli_output_path" >/dev/null
if [[ "$native_claspc_exhaustive" != "0" ]]; then
  CLASP_NATIVE_BUNDLE_JOBS=1 CLASP_NATIVE_IMAGE_SECTION_JOBS=1 "$claspc_bin" native-image "$imported_cli_project_path" -o "$imported_cli_serial_image"
  CLASP_NATIVE_BUNDLE_JOBS=4 CLASP_NATIVE_IMAGE_SECTION_JOBS=4 "$claspc_bin" native-image "$imported_cli_project_path" -o "$imported_cli_parallel_image"
  CLASP_NATIVE_BUNDLE_JOBS=4 CLASP_NATIVE_IMAGE_SECTION_JOBS=4 CLASP_NATIVE_IMAGE_MONOLITHIC_DECL_THRESHOLD=1 "$claspc_bin" native-image "$imported_cli_project_path" -o "$imported_cli_monolithic_image"
  CLASP_NATIVE_BUNDLE_JOBS=4 CLASP_NATIVE_IMAGE_SECTION_JOBS=4 CLASP_NATIVE_IMAGE_MONOLITHIC_BUNDLE_BYTES_THRESHOLD=1 "$claspc_bin" native-image "$imported_cli_project_path" -o "$imported_cli_whole_monolithic_image"
  cmp -s "$imported_cli_serial_image" "$imported_cli_parallel_image"
  cmp -s "$imported_cli_serial_image" "$imported_cli_monolithic_image"
  cmp -s "$imported_cli_serial_image" "$imported_cli_whole_monolithic_image"

  (
    unset XDG_CACHE_HOME
    CLASP_NATIVE_TRACE_CACHE=1 "$claspc_bin" native-image "$project_root/examples/hello.clasp" -o "$shared_cache_first_image" >/dev/null 2>"$shared_cache_trace_log.first"
  )
  (
    unset XDG_CACHE_HOME
    CLASP_NATIVE_TRACE_CACHE=1 "$claspc_bin" native-image "$project_root/examples/hello.clasp" -o "$shared_cache_second_image" >/dev/null 2>"$shared_cache_trace_log"
  )
  cmp -s "$shared_cache_first_image" "$shared_cache_second_image"
  grep -F '[claspc-cache] native-image hit path=/tmp/clasp-nix-cache/claspc-native/native-image-cache-v1/' "$shared_cache_trace_log" >/dev/null

  rm -rf "$source_export_cache_root"
  mkdir -p "$source_export_cache_root"
  XDG_CACHE_HOME="$source_export_cache_root" CLASP_NATIVE_TRACE_CACHE=1 "$claspc_bin" exec-image "$project_root/src/embedded.native.image.json" checkProjectText "--project-entry=$imported_cli_project_path" "$source_export_first_output" >/dev/null 2>"$source_export_first_log"
  XDG_CACHE_HOME="$source_export_cache_root" CLASP_NATIVE_TRACE_CACHE=1 "$claspc_bin" exec-image "$project_root/src/embedded.native.image.json" checkProjectText "--project-entry=$imported_cli_project_path" "$source_export_second_output" >/dev/null 2>"$source_export_second_log"
  cmp -s "$source_export_first_output" "$source_export_second_output"
  grep -F '[claspc-cache] source-export hit export=checkProjectText path=' "$source_export_second_log" >/dev/null

  rm -rf "$stale_host_cache_root"
  mkdir -p "$stale_host_cache_root"
  stale_host_socket_path="$(native_export_host_socket_path "$claspc_bin" "$project_root/src/embedded.native.image.json" "$stale_host_cache_root")"
  stale_host_lock_path="${stale_host_socket_path}.lock"
  mkdir -p "$(dirname "$stale_host_socket_path")"
  node - "$stale_host_socket_path" <<'EOF' &
const fs = require('node:fs');
const net = require('node:net');

const socketPath = process.argv[2];
fs.rmSync(socketPath, { force: true });
const server = net.createServer();
server.listen(socketPath, () => {});
setInterval(() => {}, 1000);
EOF
  stale_host_pid=$!
  for _ in $(seq 1 100); do
    if [[ -S "$stale_host_socket_path" ]]; then
      break
    fi
    sleep 0.01
  done
  [[ -S "$stale_host_socket_path" ]]
  kill -9 "$stale_host_pid" >/dev/null 2>&1 || true
  wait "$stale_host_pid" >/dev/null 2>&1 || true
  : >"$stale_host_lock_path"
  env XDG_CACHE_HOME="$stale_host_cache_root" CLASP_NATIVE_TRACE_HOST=1 \
    timeout 25 "$claspc_bin" exec-image "$project_root/src/embedded.native.image.json" checkProjectText "--project-entry=$imported_cli_project_path" "$stale_host_output" >/dev/null 2>"$stale_host_log"
  cmp -s "$source_export_first_output" "$stale_host_output"
  grep -F '[claspc-host] cleared stale host lock socket=' "$stale_host_log" >/dev/null
  grep -F '[claspc-host] cleared orphaned host socket socket=' "$stale_host_log" >/dev/null
fi

env RUSTC=/definitely-missing-rustc "$claspc_bin" compile "$list_ops_project_path" -o "$list_ops_binary"
[[ -x "$list_ops_binary" ]]
list_ops_output="$("$list_ops_binary")"
printf '%s\n' "$list_ops_output" | grep -Fx 'Linus:reviewed,Grace:reviewed|true|true|true|true' >/dev/null

env RUSTC=/definitely-missing-rustc "$claspc_bin" compile "$record_ergonomics_project_path" -o "$record_ergonomics_binary"
[[ -x "$record_ergonomics_binary" ]]
record_ergonomics_output="$("$record_ergonomics_binary")"
printf '%s\n' "$record_ergonomics_output" | grep -Fx 'Grace:planner' >/dev/null

"$claspc_bin" --json check "$project_root/examples/polymorphism/Main.clasp" | grep -F '"status":"ok"' >/dev/null
env RUSTC=/definitely-missing-rustc "$claspc_bin" compile "$project_root/examples/polymorphism/Main.clasp" -o "$polymorphism_binary"
[[ -x "$polymorphism_binary" ]]
polymorphism_output="$("$polymorphism_binary")"
printf '%s\n' "$polymorphism_output" | grep -Fx 'ok|true|true|true' >/dev/null

if [[ "$native_claspc_exhaustive" != "0" ]]; then
"$claspc_bin" --json check "$project_root/examples/feedback-loop/Main.clasp" | grep -F '"status":"ok"' >/dev/null
env RUSTC=/definitely-missing-rustc "$claspc_bin" compile "$project_root/examples/feedback-loop/Main.clasp" -o "$feedback_loop_binary"
[[ -x "$feedback_loop_binary" ]]
feedback_loop_output="$(
  CLASP_LOOP_CODEX_BIN_JSON="\"$feedback_loop_codex_bin\"" \
  CLASP_LOOP_TASK_FILE_JSON="\"$feedback_loop_task_file\"" \
  CLASP_LOOP_WORKSPACE_JSON="\"$feedback_loop_workspace_root\"" \
  CLASP_LOOP_MAX_ATTEMPTS_JSON='2' \
  "$claspc_bin" run "$project_root/examples/feedback-loop/Main.clasp" -- "$feedback_loop_state_root"
)"
printf '%s\n' "$feedback_loop_output" | grep -Fx 'pass:2' >/dev/null
grep -Fx 'fixed-after-feedback' "$feedback_loop_workspace" >/dev/null
grep -F '"verdict":"fail"' "$feedback_loop_first_verifier_path" >/dev/null
grep -F '"verdict":"pass"' "$feedback_loop_feedback_path" >/dev/null
test -f "$feedback_loop_first_diff_path"
test -f "$feedback_loop_second_diff_path"
grep -F 'workspace.txt' "$feedback_loop_first_diff_path" >/dev/null
grep -F 'workspace.txt' "$feedback_loop_second_diff_path" >/dev/null
grep -F 'notes/child-artifact.txt' "$feedback_loop_first_diff_path" >/dev/null
grep -F 'notes/child-artifact.txt' "$feedback_loop_second_diff_path" >/dev/null
if grep -F 'noise.txt' "$feedback_loop_first_diff_path" >/dev/null; then
  printf 'feedback loop diff unexpectedly included transient directories\n' >&2
  exit 1
fi
if grep -F 'noise.txt' "$feedback_loop_second_diff_path" >/dev/null; then
  printf 'feedback loop diff unexpectedly included transient directories on retry\n' >&2
  exit 1
fi

if [[ "$native_claspc_exhaustive" != "0" ]]; then
  feedback_loop_cache_output="$(
    CLASP_LOOP_CODEX_BIN_JSON="\"$feedback_loop_codex_bin\"" \
    CLASP_LOOP_TASK_FILE_JSON="\"$feedback_loop_task_file\"" \
    CLASP_LOOP_WORKSPACE_JSON="\"$feedback_loop_cache_workspace_root\"" \
    CLASP_LOOP_BASELINE_CACHE_ROOT_JSON="\"$feedback_loop_cache_root\"" \
    CLASP_LOOP_BASELINE_WORKSPACE_JSON="\"$feedback_loop_cache_baseline_workspace\"" \
    CLASP_LOOP_BASELINE_CACHE_MAX_MB_JSON='1' \
    CLASP_LOOP_MAX_ATTEMPTS_JSON='2' \
    "$claspc_bin" run "$project_root/examples/feedback-loop/Main.clasp" -- "$feedback_loop_cache_state_root"
  )"
  printf '%s\n' "$feedback_loop_cache_output" | grep -Fx 'pass:2' >/dev/null
  test ! -e "$feedback_loop_cache_stale_root"
  if grep -F '/.clasp-task-workspaces/' "$feedback_loop_cache_diff_path" >/dev/null; then
    printf 'feedback loop diff unexpectedly included task workspaces\n' >&2
    exit 1
  fi
fi
feedback_loop_status_output="$(
  CLASP_LOOP_COMMAND=status \
  "$claspc_bin" run "$project_root/examples/feedback-loop/Main.clasp" -- "$feedback_loop_state_root"
)"
printf '%s\n' "$feedback_loop_status_output" | grep -F '"attempt":2' >/dev/null
printf '%s\n' "$feedback_loop_status_output" | grep -F '"phase":"completed"' >/dev/null
printf '%s\n' "$feedback_loop_status_output" | grep -F '"verdict":"pass"' >/dev/null
printf '%s\n' "$feedback_loop_status_output" | grep -F '"completed":true' >/dev/null
printf '%s\n' "$feedback_loop_status_output" | grep -F '"builderRuns":2' >/dev/null
printf '%s\n' "$feedback_loop_status_output" | grep -F '"verifierRuns":2' >/dev/null
printf '%s\n' "$feedback_loop_status_output" | grep -F '"final":true' >/dev/null

feedback_loop_fail_output="$(
  CLASP_LOOP_CODEX_BIN_JSON="\"$feedback_loop_codex_bin\"" \
  CLASP_LOOP_TASK_FILE_JSON="\"$feedback_loop_task_file\"" \
  CLASP_LOOP_WORKSPACE_JSON="\"$feedback_loop_fail_workspace_root\"" \
  CLASP_LOOP_MAX_ATTEMPTS_JSON='1' \
  "$claspc_bin" run "$project_root/examples/feedback-loop/Main.clasp" -- "$feedback_loop_fail_state_root"
)"
printf '%s\n' "$feedback_loop_fail_output" | grep -Fx 'fail:1' >/dev/null
grep -Fx 'first-attempt' "$feedback_loop_fail_workspace_root/workspace.txt" >/dev/null
grep -F '"verdict":"fail"' "$feedback_loop_fail_feedback_path" >/dev/null
feedback_loop_fail_status_output="$(
  CLASP_LOOP_COMMAND=status \
  "$claspc_bin" run "$project_root/examples/feedback-loop/Main.clasp" -- "$feedback_loop_fail_state_root"
)"
printf '%s\n' "$feedback_loop_fail_status_output" | grep -F '"attempt":1' >/dev/null
printf '%s\n' "$feedback_loop_fail_status_output" | grep -F '"phase":"failed"' >/dev/null
printf '%s\n' "$feedback_loop_fail_status_output" | grep -F '"verdict":"fail"' >/dev/null
printf '%s\n' "$feedback_loop_fail_status_output" | grep -F '"healthy":false' >/dev/null
printf '%s\n' "$feedback_loop_fail_status_output" | grep -F '"needsAttention":true' >/dev/null
printf '%s\n' "$feedback_loop_fail_status_output" | grep -F '"final":true' >/dev/null

mkdir -p "$feedback_loop_recovery_state_root"
printf '%s\n' 'first-attempt' >"$feedback_loop_recovery_workspace"
cp "$feedback_loop_first_verifier_path" "$feedback_loop_recovery_feedback_path"
printf '%s\n' 'force-close-category' >"$feedback_loop_recovery_state_root/builder-policy.md"
cat >"$feedback_loop_recovery_state_root/state.json" <<JSON
{"attempt":2,"phase":"builder-running","verdict":"pending","completed":false,"builderRuns":2,"verifierRuns":1,"healthy":true,"needsAttention":false,"attentionReason":"","final":false}
JSON
cat >"$feedback_loop_recovery_builder_heartbeat" <<JSON
{"pid":999999,"running":true,"completed":false,"exitCode":0,"stdoutPath":"$feedback_loop_recovery_builder_stdout","stderrPath":"$feedback_loop_recovery_builder_stderr","heartbeatPath":"$feedback_loop_recovery_builder_heartbeat","updatedAtMs":0}
JSON
feedback_loop_recovery_output="$(
  CLASP_LOOP_CODEX_BIN_JSON="\"$feedback_loop_codex_bin\"" \
  CLASP_LOOP_TASK_FILE_JSON="\"$feedback_loop_task_file\"" \
  CLASP_LOOP_WORKSPACE_JSON="\"$feedback_loop_recovery_workspace_root\"" \
  CLASP_LOOP_MAX_ATTEMPTS_JSON='2' \
  "$claspc_bin" run "$project_root/examples/feedback-loop/Main.clasp" -- "$feedback_loop_recovery_state_root"
)"
printf '%s\n' "$feedback_loop_recovery_output" | grep -Fx 'pass:2' >/dev/null
grep -Fx 'fixed-after-feedback' "$feedback_loop_recovery_workspace" >/dev/null
grep -F 'builder-start' "$feedback_loop_recovery_builder_stdout" >/dev/null
grep -F 'builder-progress' "$feedback_loop_recovery_builder_stderr" >/dev/null
grep -F '"completed":true' "$feedback_loop_recovery_builder_heartbeat" >/dev/null
grep -F '"verdict":"pass"' "$feedback_loop_recovery_feedback_path" >/dev/null

CLASP_LOOP_CODEX_BIN_JSON="\"$feedback_loop_codex_bin\"" \
CLASP_LOOP_TASK_FILE_JSON="\"$feedback_loop_task_file\"" \
CLASP_LOOP_WORKSPACE_JSON="\"$feedback_loop_live_workspace_root\"" \
CLASP_LOOP_MAX_ATTEMPTS_JSON='2' \
CLASP_LOOP_WATCH_POLL_MS_JSON='50' \
CLASP_TEST_FAKE_DELAYED_REPORT_SECS='0.1' \
  "$claspc_bin" run "$project_root/examples/feedback-loop/Main.clasp" -- "$feedback_loop_live_state_root" >"$feedback_loop_live_output" 2>&1 &
feedback_loop_live_pid=$!
for _ in $(seq 1 300); do
  if [[ -f "$feedback_loop_live_builder_heartbeat" && -f "$feedback_loop_live_builder_stdout" && -f "$feedback_loop_live_builder_stderr" ]]; then
    break
  fi
  if ! kill -0 "$feedback_loop_live_pid" >/dev/null 2>&1; then
    break
  fi
  sleep 0.05
done
kill -0 "$feedback_loop_live_pid" >/dev/null 2>&1
wait_for_path_contains "$feedback_loop_live_builder_stdout" 'builder-start' "$feedback_loop_live_pid"
wait_for_path_contains "$feedback_loop_live_builder_stderr" 'builder-progress' "$feedback_loop_live_pid"
wait_for_path_contains "$feedback_loop_live_builder_heartbeat" '"pid":' "$feedback_loop_live_pid"
wait "$feedback_loop_live_pid"
feedback_loop_live_pid=""
grep -F '"completed":true' "$feedback_loop_live_builder_heartbeat" >/dev/null
grep -F '"exitCode":0' "$feedback_loop_live_builder_heartbeat" >/dev/null
grep -F '"verdict":"pass"' "$feedback_loop_live_state_root/feedback.json" >/dev/null
grep -F '"verdict":"fail"' "$feedback_loop_live_state_root/verifier-1.json" >/dev/null
grep -F '"verdict":"pass"' "$feedback_loop_live_state_root/verifier-2.json" >/dev/null
grep -F 'pass:2' "$feedback_loop_live_output" >/dev/null

feedback_loop_stdout_recovery_output="$(
  CLASP_LOOP_CODEX_BIN_JSON="\"$feedback_loop_codex_bin\"" \
  CLASP_LOOP_TASK_FILE_JSON="\"$feedback_loop_task_file\"" \
  CLASP_LOOP_WORKSPACE_JSON="\"$feedback_loop_stdout_recovery_workspace_root\"" \
  CLASP_LOOP_MAX_ATTEMPTS_JSON='2' \
  CLASP_LOOP_WATCH_POLL_MS_JSON='50' \
  CLASP_TEST_FAKE_STDOUT_ONLY_REPORT='1' \
  "$claspc_bin" run "$project_root/examples/feedback-loop/Main.clasp" -- "$feedback_loop_stdout_recovery_state_root"
)"
printf '%s\n' "$feedback_loop_stdout_recovery_output" | grep -Fx 'pass:2' >/dev/null
grep -Fx 'fixed-after-feedback' "$feedback_loop_stdout_recovery_workspace" >/dev/null
grep -F '"summary":"builder wrote first-attempt"' "$feedback_loop_stdout_recovery_state_root/builder-1.json" >/dev/null
grep -F '"verdict":"fail"' "$feedback_loop_stdout_recovery_state_root/verifier-1.json" >/dev/null
grep -F '"verdict":"pass"' "$feedback_loop_stdout_recovery_state_root/feedback.json" >/dev/null

"$claspc_bin" --json check "$project_root/examples/feedback-loop/ProcessDemo.clasp" | grep -F '"status":"ok"' >/dev/null
env RUSTC=/definitely-missing-rustc "$claspc_bin" compile "$project_root/examples/feedback-loop/ProcessDemo.clasp" -o "$feedback_loop_process_demo_binary"
[[ -x "$feedback_loop_process_demo_binary" ]]
feedback_loop_process_demo_state_root="$test_root/feedback-loop-process-demo-state"
feedback_loop_process_demo_launch_output="$(
  "$claspc_bin" run "$project_root/examples/feedback-loop/ProcessDemo.clasp" -- "$feedback_loop_process_demo_state_root"
)"
printf '%s\n' "$feedback_loop_process_demo_launch_output" | grep -F '"heartbeatPath":"'"$feedback_loop_process_demo_state_root"'/demo.heartbeat.json"' >/dev/null
printf '%s\n' "$feedback_loop_process_demo_launch_output" | grep -F '"stdoutPath":"'"$feedback_loop_process_demo_state_root"'/demo.stdout.log"' >/dev/null
for _ in $(seq 1 100); do
  feedback_loop_process_demo_status_output="$(
    CLASP_PROCESS_DEMO_COMMAND=status \
    "$claspc_bin" run "$project_root/examples/feedback-loop/ProcessDemo.clasp" -- "$feedback_loop_process_demo_state_root"
  )"
  if printf '%s\n' "$feedback_loop_process_demo_status_output" | grep -F '"running":true' >/dev/null; then
    break
  fi
  sleep 0.02
done
printf '%s\n' "$feedback_loop_process_demo_status_output" | grep -F '"heartbeatPath":"'"$feedback_loop_process_demo_state_root"'/demo.heartbeat.json"' >/dev/null
feedback_loop_process_demo_await_output="$(
  CLASP_PROCESS_DEMO_COMMAND=await \
  "$claspc_bin" run "$project_root/examples/feedback-loop/ProcessDemo.clasp" -- "$feedback_loop_process_demo_state_root"
)"
printf '%s\n' "$feedback_loop_process_demo_await_output" | grep -F '"completed":true' >/dev/null
printf '%s\n' "$feedback_loop_process_demo_await_output" | grep -F '"running":false' >/dev/null
grep -Fx 'process-demo-start' "$feedback_loop_process_demo_state_root/demo.stdout.log" >/dev/null
grep -Fx 'process-demo-err' "$feedback_loop_process_demo_state_root/demo.stderr.log" >/dev/null

feedback_loop_native_state_root="$test_root/feedback-loop-native-state"
feedback_loop_native_workspace_root="$test_root/feedback-loop-native-workspace"
feedback_loop_native_workspace="$feedback_loop_native_workspace_root/workspace.txt"
feedback_loop_native_feedback_path="$feedback_loop_native_state_root/feedback.json"
feedback_loop_native_first_diff_path="$feedback_loop_native_state_root/changes-1.diff"
feedback_loop_native_status_output="$test_root/feedback-loop-native-status.json"
mkdir -p "$feedback_loop_native_workspace_root"
feedback_loop_native_state_root_abs="$test_root_abs/feedback-loop-native-state"
feedback_loop_native_workspace_root_abs="$test_root_abs/feedback-loop-native-workspace"
feedback_loop_native_workspace_abs="$feedback_loop_native_workspace_root_abs/workspace.txt"
feedback_loop_native_feedback_path_abs="$feedback_loop_native_state_root_abs/feedback.json"
feedback_loop_native_first_diff_path_abs="$feedback_loop_native_state_root_abs/changes-1.diff"
feedback_loop_native_status_output_abs="$test_root_abs/feedback-loop-native-status.json"
feedback_loop_native_output="$(
  CLASP_LOOP_CODEX_BIN_JSON="\"$test_root_abs/codex\"" \
  CLASP_LOOP_TASK_FILE_JSON="\"$test_root_abs/feedback-loop-task.md\"" \
  CLASP_LOOP_WORKSPACE_JSON="\"$feedback_loop_native_workspace_root_abs\"" \
  CLASP_LOOP_MAX_ATTEMPTS_JSON='2' \
  "$feedback_loop_binary" "$feedback_loop_native_state_root_abs"
)"
printf '%s\n' "$feedback_loop_native_output" | grep -Fx 'pass:2' >/dev/null
grep -Fx 'fixed-after-feedback' "$feedback_loop_native_workspace_abs" >/dev/null
grep -F '"verdict":"pass"' "$feedback_loop_native_feedback_path_abs" >/dev/null
test -f "$feedback_loop_native_first_diff_path_abs"
grep -F 'workspace.txt' "$feedback_loop_native_first_diff_path_abs" >/dev/null
grep -F 'notes/child-artifact.txt' "$feedback_loop_native_first_diff_path_abs" >/dev/null
if grep -F 'noise.txt' "$feedback_loop_native_first_diff_path_abs" >/dev/null; then
  printf 'feedback loop native diff unexpectedly included transient directories\n' >&2
  exit 1
fi
CLASP_LOOP_COMMAND=status "$feedback_loop_binary" "$feedback_loop_native_state_root_abs" >"$feedback_loop_native_status_output_abs"
grep -F '"attempt":2' "$feedback_loop_native_status_output_abs" >/dev/null
grep -F '"phase":"completed"' "$feedback_loop_native_status_output_abs" >/dev/null
grep -F '"verdict":"pass"' "$feedback_loop_native_status_output_abs" >/dev/null
grep -F '"builderRuns":2' "$feedback_loop_native_status_output_abs" >/dev/null
grep -F '"verifierRuns":2' "$feedback_loop_native_status_output_abs" >/dev/null
grep -F '"final":true' "$feedback_loop_native_status_output_abs" >/dev/null

feedback_loop_handoff_state_root_abs="$test_root_abs/feedback-loop-handoff-state"
feedback_loop_handoff_child_state_root_abs="$test_root_abs/feedback-loop-handoff-child-state"
feedback_loop_handoff_child_workspace_root_abs="$test_root_abs/feedback-loop-handoff-child-workspace"
feedback_loop_handoff_child_workspace_abs="$feedback_loop_handoff_child_workspace_root_abs/workspace.txt"
feedback_loop_handoff_child_ready_path_abs="$feedback_loop_handoff_child_state_root_abs/loop.ready"
feedback_loop_handoff_output="$(
  CLASP_LOOP_COMMAND=handoff \
  CLASP_LOOP_CODEX_BIN_JSON="\"$test_root_abs/codex\"" \
  CLASP_LOOP_TASK_FILE_JSON="\"$test_root_abs/feedback-loop-task.md\"" \
  CLASP_LOOP_WORKSPACE_JSON="\"$feedback_loop_handoff_child_workspace_root_abs\"" \
  CLASP_LOOP_READY_PATH_JSON="\"$feedback_loop_handoff_child_ready_path_abs\"" \
  CLASP_LOOP_HANDOFF_READY_PATH_JSON="\"$feedback_loop_handoff_child_ready_path_abs\"" \
  CLASP_LOOP_HANDOFF_READY_CONTAINS_JSON='"ready"' \
  CLASP_LOOP_HANDOFF_READY_TIMEOUT_MS_JSON='5000' \
  CLASP_LOOP_HANDOFF_COMMAND_JSON="[\"env\",\"CLASP_LOOP_COMMAND=run\",\"$feedback_loop_binary\",\"$feedback_loop_handoff_child_state_root_abs\"]" \
  "$feedback_loop_binary" "$feedback_loop_handoff_state_root_abs"
)"
printf '%s\n' "$feedback_loop_handoff_output" | grep -F '"heartbeatPath":"'"$feedback_loop_handoff_state_root_abs"'/handoff.heartbeat.json"' >/dev/null
printf '%s\n' "$feedback_loop_handoff_output" | grep -F '"running":true' >/dev/null
for _ in $(seq 1 300); do
  if [[ -f "$feedback_loop_handoff_child_ready_path_abs" ]] \
    && [[ -f "$feedback_loop_handoff_child_state_root_abs/feedback.json" ]] \
    && grep -F '"verdict":"pass"' "$feedback_loop_handoff_child_state_root_abs/feedback.json" >/dev/null 2>&1 \
    && [[ -f "$feedback_loop_handoff_child_workspace_abs" ]] \
    && grep -Fx 'fixed-after-feedback' "$feedback_loop_handoff_child_workspace_abs" >/dev/null 2>&1; then
    break
  fi
  sleep 0.05
done
grep -Fx 'ready' "$feedback_loop_handoff_child_ready_path_abs" >/dev/null
grep -F '"verdict":"pass"' "$feedback_loop_handoff_child_state_root_abs/feedback.json" >/dev/null
grep -Fx 'fixed-after-feedback' "$feedback_loop_handoff_child_workspace_abs" >/dev/null
grep -F '"heartbeatPath":"'"$feedback_loop_handoff_state_root_abs"'/handoff.heartbeat.json"' <<<"$feedback_loop_handoff_output" >/dev/null

feedback_loop_upgrade_state_root_abs="$test_root_abs/feedback-loop-upgrade-state"
feedback_loop_upgrade_child_state_root_abs="$test_root_abs/feedback-loop-upgrade-child-state"
feedback_loop_upgrade_child_workspace_root_abs="$test_root_abs/feedback-loop-upgrade-child-workspace"
feedback_loop_upgrade_child_workspace_abs="$feedback_loop_upgrade_child_workspace_root_abs/workspace.txt"
feedback_loop_upgrade_child_ready_path_abs="$feedback_loop_upgrade_child_state_root_abs/loop.ready"
feedback_loop_upgrade_child_restored_path_abs="$feedback_loop_upgrade_child_state_root_abs/restored-snapshot.json"
feedback_loop_upgrade_service_root_abs="$test_root_abs/feedback-loop-upgrade-service"
feedback_loop_upgrade_command_json="$(
  node -e 'console.log(JSON.stringify(process.argv.slice(1)))' \
    env \
    CLASP_LOOP_COMMAND=run \
    "CLASP_LOOP_CODEX_BIN_JSON=\"$test_root_abs/codex\"" \
    "CLASP_LOOP_TASK_FILE_JSON=\"$test_root_abs/feedback-loop-task.md\"" \
    "CLASP_LOOP_WORKSPACE_JSON=\"$feedback_loop_upgrade_child_workspace_root_abs\"" \
    "CLASP_LOOP_READY_PATH_JSON=\"$feedback_loop_upgrade_child_ready_path_abs\"" \
    CLASP_LOOP_MAX_ATTEMPTS_JSON=2 \
    "$feedback_loop_binary" \
    "$feedback_loop_upgrade_child_state_root_abs"
)"
feedback_loop_upgrade_output="$(
  CLASP_LOOP_COMMAND=upgrade \
  CLASP_LOOP_CODEX_BIN_JSON="\"$test_root_abs/codex\"" \
  CLASP_LOOP_TASK_FILE_JSON="\"$test_root_abs/feedback-loop-task.md\"" \
  CLASP_LOOP_WORKSPACE_JSON="\"$feedback_loop_upgrade_child_workspace_root_abs\"" \
  CLASP_LOOP_MAX_ATTEMPTS_JSON='2' \
  CLASP_LOOP_SERVICE_ROOT_JSON="\"$feedback_loop_upgrade_service_root_abs\"" \
  CLASP_LOOP_SERVICE_ID_JSON='"feedback-loop-service"' \
  CLASP_LOOP_UPGRADE_READY_PATH_JSON="\"$feedback_loop_upgrade_child_ready_path_abs\"" \
  CLASP_LOOP_UPGRADE_READY_CONTAINS_JSON='"ready"' \
  CLASP_LOOP_UPGRADE_COMMIT_GRACE_MS_JSON='100' \
  CLASP_LOOP_UPGRADE_COMMAND_JSON="$feedback_loop_upgrade_command_json" \
  "$feedback_loop_binary" "$feedback_loop_upgrade_state_root_abs"
)"
printf '%s\n' "$feedback_loop_upgrade_output" | grep -F '"phase":"committed"' >/dev/null
printf '%s\n' "$feedback_loop_upgrade_output" | grep -F '"committed":true' >/dev/null
for _ in $(seq 1 300); do
  if [[ -f "$feedback_loop_upgrade_service_root_abs/service.json" ]] \
    && grep -F '"status":"completed"' "$feedback_loop_upgrade_service_root_abs/service.json" >/dev/null 2>&1 \
    && [[ -f "$feedback_loop_upgrade_child_state_root_abs/feedback.json" ]] \
    && grep -F '"verdict":"pass"' "$feedback_loop_upgrade_child_state_root_abs/feedback.json" >/dev/null 2>&1 \
    && [[ -f "$feedback_loop_upgrade_child_restored_path_abs" ]] \
    && [[ -f "$feedback_loop_upgrade_child_workspace_abs" ]] \
    && grep -Fx 'fixed-after-feedback' "$feedback_loop_upgrade_child_workspace_abs" >/dev/null 2>&1; then
    break
  fi
  sleep 0.05
done
grep -Fx 'fixed-after-feedback' "$feedback_loop_upgrade_child_workspace_abs" >/dev/null
grep -F '"verdict":"pass"' "$feedback_loop_upgrade_child_state_root_abs/feedback.json" >/dev/null
grep -F '"serviceId":"feedback-loop-service"' "$feedback_loop_upgrade_service_root_abs/service.json" >/dev/null
grep -F '"status":"completed"' "$feedback_loop_upgrade_service_root_abs/service.json" >/dev/null
grep -F '"generation":1' "$feedback_loop_upgrade_service_root_abs/service.json" >/dev/null
grep -F '"serviceRoot":"'"$feedback_loop_upgrade_service_root_abs"'"' "$feedback_loop_upgrade_child_restored_path_abs" >/dev/null
grep -F '"serviceId":"feedback-loop-service"' "$feedback_loop_upgrade_child_restored_path_abs" >/dev/null
grep -F '"generation":1' "$feedback_loop_upgrade_child_restored_path_abs" >/dev/null
feedback_loop_upgrade_transaction_path_abs="$(find "$feedback_loop_upgrade_service_root_abs/transactions" -name transaction.json | head -n 1)"
test -n "$feedback_loop_upgrade_transaction_path_abs"
grep -F '"phase":"completed"' "$feedback_loop_upgrade_transaction_path_abs" >/dev/null
grep -F '"committed":true' "$feedback_loop_upgrade_transaction_path_abs" >/dev/null
grep -F '"exitCode":0' "$feedback_loop_upgrade_transaction_path_abs" >/dev/null

feedback_loop_upgrade_rollback_state_root_abs="$test_root_abs/feedback-loop-upgrade-rollback-state"
feedback_loop_upgrade_rollback_child_state_root_abs="$test_root_abs/feedback-loop-upgrade-rollback-child-state"
feedback_loop_upgrade_rollback_service_root_abs="$test_root_abs/feedback-loop-upgrade-rollback-service"
feedback_loop_upgrade_rollback_command_json="$(
  printf '[\"env\",\"CLASP_LOOP_COMMAND=status\",\"%s\",\"%s\"]' \
    "$feedback_loop_binary" \
    "$feedback_loop_upgrade_rollback_child_state_root_abs"
)"
feedback_loop_upgrade_rollback_output="$(
  CLASP_LOOP_COMMAND=upgrade \
  CLASP_LOOP_SERVICE_ROOT_JSON="\"$feedback_loop_upgrade_rollback_service_root_abs\"" \
  CLASP_LOOP_SERVICE_ID_JSON='"feedback-loop-service"' \
  CLASP_LOOP_UPGRADE_READY_PATH_JSON="\"$feedback_loop_upgrade_rollback_child_state_root_abs/loop.ready\"" \
  CLASP_LOOP_UPGRADE_READY_CONTAINS_JSON='"ready"' \
  CLASP_LOOP_UPGRADE_READY_TIMEOUT_MS_JSON='500' \
  CLASP_LOOP_UPGRADE_COMMAND_JSON="$feedback_loop_upgrade_rollback_command_json" \
  "$feedback_loop_binary" "$feedback_loop_upgrade_rollback_state_root_abs"
)"
printf '%s\n' "$feedback_loop_upgrade_rollback_output" | grep -F 'error:upgrade_rolled_back:' >/dev/null
feedback_loop_upgrade_rollback_transaction_path_abs="$(find "$feedback_loop_upgrade_rollback_service_root_abs/transactions" -name transaction.json | head -n 1)"
test -n "$feedback_loop_upgrade_rollback_transaction_path_abs"
grep -F '"phase":"rolled_back"' "$feedback_loop_upgrade_rollback_transaction_path_abs" >/dev/null
grep -F '"rolledBack":true' "$feedback_loop_upgrade_rollback_transaction_path_abs" >/dev/null
[[ ! -f "$feedback_loop_upgrade_rollback_service_root_abs/service.json" ]]

feedback_loop_process_demo_native_state_root="$test_root/feedback-loop-process-demo-native-state"
feedback_loop_process_demo_native_state_root_abs="$test_root_abs/feedback-loop-process-demo-native-state"
feedback_loop_process_demo_native_output="$(
  "$feedback_loop_process_demo_binary" "$feedback_loop_process_demo_native_state_root_abs"
)"
printf '%s\n' "$feedback_loop_process_demo_native_output" | grep -F '"heartbeatPath":"'"$feedback_loop_process_demo_native_state_root_abs"'/demo.heartbeat.json"' >/dev/null
printf '%s\n' "$feedback_loop_process_demo_native_output" | grep -F '"stdoutPath":"'"$feedback_loop_process_demo_native_state_root_abs"'/demo.stdout.log"' >/dev/null
for _ in $(seq 1 100); do
  feedback_loop_process_demo_native_status_output="$(
    CLASP_PROCESS_DEMO_COMMAND=status \
    "$feedback_loop_process_demo_binary" "$feedback_loop_process_demo_native_state_root_abs"
  )"
  if printf '%s\n' "$feedback_loop_process_demo_native_status_output" | grep -F '"running":true' >/dev/null; then
    break
  fi
  sleep 0.02
done
feedback_loop_process_demo_native_await_output="$(
  CLASP_PROCESS_DEMO_COMMAND=await \
  "$feedback_loop_process_demo_binary" "$feedback_loop_process_demo_native_state_root_abs"
)"
printf '%s\n' "$feedback_loop_process_demo_native_await_output" | grep -F '"completed":true' >/dev/null
printf '%s\n' "$feedback_loop_process_demo_native_await_output" | grep -F '"running":false' >/dev/null
grep -Fx 'process-demo-start' "$feedback_loop_process_demo_native_state_root_abs/demo.stdout.log" >/dev/null
grep -Fx 'process-demo-err' "$feedback_loop_process_demo_native_state_root_abs/demo.stderr.log" >/dev/null

env RUSTC=/definitely-missing-rustc "$claspc_bin" compile "$project_root/examples/swarm-kernel/Main.clasp" -o "$swarm_kernel_binary"
[[ -x "$swarm_kernel_binary" ]]
swarm_result_path="$(CLASP_SWARM_ACTOR=planner "$swarm_kernel_binary" "$swarm_state_root")"
[[ "$swarm_result_path" == "$swarm_event_log" ]]
[[ -f "$swarm_event_log" ]]
grep -F '"kind":"task_created"' "$swarm_event_log" >/dev/null
grep -F '"taskId":"bootstrap"' "$swarm_event_log" >/dev/null
grep -F '"actor":"planner"' "$swarm_event_log" >/dev/null
grep -F '"detail":"Initialize swarm kernel state."' "$swarm_event_log" >/dev/null
swarm_lease_path="$(CLASP_SWARM_ACTOR=worker-1 CLASP_SWARM_COMMAND=lease CLASP_SWARM_TASK_ID=bootstrap "$swarm_kernel_binary" "$swarm_state_root")"
[[ "$swarm_lease_path" == "$swarm_event_log" ]]
grep -F '"kind":"lease_acquired"' "$swarm_event_log" >/dev/null
grep -F '"actor":"worker-1"' "$swarm_event_log" >/dev/null
grep -F '"detail":"Acquire lease for bootstrap."' "$swarm_event_log" >/dev/null
swarm_heartbeat_path="$(CLASP_SWARM_ACTOR=worker-1 CLASP_SWARM_COMMAND=heartbeat CLASP_SWARM_TASK_ID=bootstrap "$swarm_kernel_binary" "$swarm_state_root")"
[[ "$swarm_heartbeat_path" == "$swarm_event_log" ]]
grep -F '"kind":"worker_heartbeat"' "$swarm_event_log" >/dev/null
grep -F '"detail":"Heartbeat for bootstrap."' "$swarm_event_log" >/dev/null
swarm_complete_path="$(CLASP_SWARM_ACTOR=worker-1 CLASP_SWARM_COMMAND=complete CLASP_SWARM_TASK_ID=bootstrap "$swarm_kernel_binary" "$swarm_state_root")"
[[ "$swarm_complete_path" == "$swarm_event_log" ]]
grep -F '"kind":"task_completed"' "$swarm_event_log" >/dev/null
grep -F '"detail":"Complete task bootstrap."' "$swarm_event_log" >/dev/null
swarm_status_output="$(CLASP_SWARM_COMMAND=status CLASP_SWARM_TASK_ID=bootstrap "$swarm_kernel_binary" "$swarm_state_root")"
printf '%s\n' "$swarm_status_output" | grep -F '"taskId":"bootstrap"' >/dev/null
printf '%s\n' "$swarm_status_output" | grep -F '"status":"completed"' >/dev/null
printf '%s\n' "$swarm_status_output" | grep -F '"leaseActor":"worker-1"' >/dev/null
printf '%s\n' "$swarm_status_output" | grep -E '"lastHeartbeatAtMs":[0-9]+' >/dev/null
printf '%s\n' "$swarm_status_output" | grep -F '"heartbeatSeen":true' >/dev/null
swarm_repair_bootstrap_path="$(CLASP_SWARM_ACTOR=planner CLASP_SWARM_COMMAND=bootstrap CLASP_SWARM_TASK_ID=repair "$swarm_kernel_binary" "$swarm_state_root")"
[[ "$swarm_repair_bootstrap_path" == "$swarm_event_log" ]]
swarm_repair_lease_path="$(CLASP_SWARM_ACTOR=worker-2 CLASP_SWARM_COMMAND=lease CLASP_SWARM_TASK_ID=repair "$swarm_kernel_binary" "$swarm_state_root")"
[[ "$swarm_repair_lease_path" == "$swarm_event_log" ]]
swarm_repair_fail_path="$(CLASP_SWARM_ACTOR=worker-2 CLASP_SWARM_COMMAND=fail CLASP_SWARM_TASK_ID=repair "$swarm_kernel_binary" "$swarm_state_root")"
[[ "$swarm_repair_fail_path" == "$swarm_event_log" ]]
grep -F '"kind":"task_failed"' "$swarm_event_log" >/dev/null
grep -F '"detail":"Fail task repair."' "$swarm_event_log" >/dev/null
swarm_repair_status_output="$(CLASP_SWARM_COMMAND=status CLASP_SWARM_TASK_ID=repair "$swarm_kernel_binary" "$swarm_state_root")"
printf '%s\n' "$swarm_repair_status_output" | grep -F '"taskId":"repair"' >/dev/null
printf '%s\n' "$swarm_repair_status_output" | grep -F '"status":"failed"' >/dev/null
printf '%s\n' "$swarm_repair_status_output" | grep -F '"leaseActor":"worker-2"' >/dev/null
printf '%s\n' "$swarm_repair_status_output" | grep -F '"heartbeatSeen":false' >/dev/null
swarm_repair_retry_path="$(CLASP_SWARM_ACTOR=planner CLASP_SWARM_COMMAND=retry CLASP_SWARM_TASK_ID=repair "$swarm_kernel_binary" "$swarm_state_root")"
[[ "$swarm_repair_retry_path" == "$swarm_event_log" ]]
grep -F '"kind":"task_requeued"' "$swarm_event_log" >/dev/null
grep -F '"detail":"Requeue task repair."' "$swarm_event_log" >/dev/null
swarm_repair_retry_status_output="$(CLASP_SWARM_COMMAND=status CLASP_SWARM_TASK_ID=repair "$swarm_kernel_binary" "$swarm_state_root")"
printf '%s\n' "$swarm_repair_retry_status_output" | grep -F '"taskId":"repair"' >/dev/null
printf '%s\n' "$swarm_repair_retry_status_output" | grep -F '"status":"queued"' >/dev/null
printf '%s\n' "$swarm_repair_retry_status_output" | grep -F '"leaseActor":""' >/dev/null
printf '%s\n' "$swarm_repair_retry_status_output" | grep -F '"heartbeatSeen":false' >/dev/null
swarm_repair_history_output="$(CLASP_SWARM_COMMAND=history CLASP_SWARM_TASK_ID=repair "$swarm_kernel_binary" "$swarm_state_root")"
printf '%s\n' "$swarm_repair_history_output" | grep -F '"kind":"task_created"' >/dev/null
printf '%s\n' "$swarm_repair_history_output" | grep -F '"kind":"lease_acquired"' >/dev/null
printf '%s\n' "$swarm_repair_history_output" | grep -F '"kind":"task_failed"' >/dev/null
printf '%s\n' "$swarm_repair_history_output" | grep -F '"kind":"task_requeued"' >/dev/null
printf '%s\n' "$swarm_repair_history_output" | grep -F '"actor":"worker-2"' >/dev/null
swarm_draft_bootstrap_path="$(CLASP_SWARM_ACTOR=planner CLASP_SWARM_COMMAND=bootstrap CLASP_SWARM_TASK_ID=draft "$swarm_kernel_binary" "$swarm_state_root")"
[[ "$swarm_draft_bootstrap_path" == "$swarm_event_log" ]]
swarm_draft_lease_path="$(CLASP_SWARM_ACTOR=worker-3 CLASP_SWARM_COMMAND=lease CLASP_SWARM_TASK_ID=draft "$swarm_kernel_binary" "$swarm_state_root")"
[[ "$swarm_draft_lease_path" == "$swarm_event_log" ]]
swarm_draft_release_path="$(CLASP_SWARM_ACTOR=worker-3 CLASP_SWARM_COMMAND=release CLASP_SWARM_TASK_ID=draft "$swarm_kernel_binary" "$swarm_state_root")"
[[ "$swarm_draft_release_path" == "$swarm_event_log" ]]
grep -F '"kind":"lease_released"' "$swarm_event_log" >/dev/null
grep -F '"detail":"Release lease for draft."' "$swarm_event_log" >/dev/null
swarm_draft_status_output="$(CLASP_SWARM_COMMAND=status CLASP_SWARM_TASK_ID=draft "$swarm_kernel_binary" "$swarm_state_root")"
printf '%s\n' "$swarm_draft_status_output" | grep -F '"taskId":"draft"' >/dev/null
printf '%s\n' "$swarm_draft_status_output" | grep -F '"status":"queued"' >/dev/null
printf '%s\n' "$swarm_draft_status_output" | grep -F '"leaseActor":""' >/dev/null
printf '%s\n' "$swarm_draft_status_output" | grep -F '"heartbeatSeen":false' >/dev/null
swarm_tasks_output="$(CLASP_SWARM_COMMAND=tasks "$swarm_kernel_binary" "$swarm_state_root")"
printf '%s\n' "$swarm_tasks_output" | grep -F '"taskId":"bootstrap"' >/dev/null
printf '%s\n' "$swarm_tasks_output" | grep -F '"status":"completed"' >/dev/null
printf '%s\n' "$swarm_tasks_output" | grep -F '"taskId":"repair"' >/dev/null
printf '%s\n' "$swarm_tasks_output" | grep -F '"status":"queued"' >/dev/null
printf '%s\n' "$swarm_tasks_output" | grep -F '"taskId":"draft"' >/dev/null
swarm_summary_output="$(CLASP_SWARM_COMMAND=summary "$swarm_kernel_binary" "$swarm_state_root")"
printf '%s\n' "$swarm_summary_output" | grep -F '"allTaskIds":["bootstrap","repair","draft"]' >/dev/null
printf '%s\n' "$swarm_summary_output" | grep -F '"queuedTaskIds":["repair","draft"]' >/dev/null
printf '%s\n' "$swarm_summary_output" | grep -F '"completedTaskIds":["bootstrap"]' >/dev/null
printf '%s\n' "$swarm_summary_output" | grep -F '"failedTaskIds":[]' >/dev/null
printf '%s\n' "$swarm_summary_output" | grep -F '"heartbeatTaskIds":["bootstrap"]' >/dev/null

swarm_loop_initial_output="$(CLASP_SWARM_COMMAND=monitor CLASP_SWARM_TASK_ID=language-loop "$swarm_kernel_binary" "$swarm_loop_state_root")"
printf '%s\n' "$swarm_loop_initial_output" | grep -F '"taskId":"language-loop"' >/dev/null
printf '%s\n' "$swarm_loop_initial_output" | grep -F '"attempt":1' >/dev/null
printf '%s\n' "$swarm_loop_initial_output" | grep -F '"phase":"needs-builder"' >/dev/null
printf '%s\n' "$swarm_loop_initial_output" | grep -F '"healthy":true' >/dev/null
printf '%s\n' "$swarm_loop_initial_output" | grep -F '"needsAttention":false' >/dev/null
printf '%s\n' "$swarm_loop_initial_output" | grep -F '"suggestedCommand":"CLASP_SWARM_COMMAND=builder-start CLASP_SWARM_TASK_ID=language-loop"' >/dev/null

swarm_loop_builder_start_path="$(CLASP_SWARM_ACTOR=builder CLASP_SWARM_COMMAND=builder-start CLASP_SWARM_TASK_ID=language-loop "$swarm_kernel_binary" "$swarm_loop_state_root")"
[[ "$swarm_loop_builder_start_path" == "$swarm_loop_event_log" ]]
grep -F '"kind":"builder_started"' "$swarm_loop_event_log" >/dev/null

swarm_loop_builder_running_output="$(CLASP_SWARM_COMMAND=loop-status CLASP_SWARM_TASK_ID=language-loop "$swarm_kernel_binary" "$swarm_loop_state_root")"
printf '%s\n' "$swarm_loop_builder_running_output" | grep -F '"phase":"builder-running"' >/dev/null
printf '%s\n' "$swarm_loop_builder_running_output" | grep -F '"builderRuns":1' >/dev/null

swarm_loop_builder_complete_path="$(CLASP_SWARM_ACTOR=builder CLASP_SWARM_COMMAND=builder-complete CLASP_SWARM_TASK_ID=language-loop "$swarm_kernel_binary" "$swarm_loop_state_root")"
[[ "$swarm_loop_builder_complete_path" == "$swarm_loop_event_log" ]]

swarm_loop_needs_verifier_output="$(CLASP_SWARM_COMMAND=monitor CLASP_SWARM_TASK_ID=language-loop "$swarm_kernel_binary" "$swarm_loop_state_root")"
printf '%s\n' "$swarm_loop_needs_verifier_output" | grep -F '"phase":"needs-verifier"' >/dev/null
printf '%s\n' "$swarm_loop_needs_verifier_output" | grep -F '"suggestedRole":"verifier"' >/dev/null

swarm_loop_verifier_start_path="$(CLASP_SWARM_ACTOR=verifier CLASP_SWARM_COMMAND=verifier-start CLASP_SWARM_TASK_ID=language-loop "$swarm_kernel_binary" "$swarm_loop_state_root")"
[[ "$swarm_loop_verifier_start_path" == "$swarm_loop_event_log" ]]
swarm_loop_verifier_fail_path="$(CLASP_SWARM_ACTOR=verifier CLASP_SWARM_COMMAND=verifier-fail CLASP_SWARM_TASK_ID=language-loop CLASP_SWARM_DETAIL='native summary crashed' "$swarm_kernel_binary" "$swarm_loop_state_root")"
[[ "$swarm_loop_verifier_fail_path" == "$swarm_loop_event_log" ]]
grep -F '"kind":"verifier_failed"' "$swarm_loop_event_log" >/dev/null

swarm_loop_after_fail_output="$(CLASP_SWARM_COMMAND=monitor CLASP_SWARM_TASK_ID=language-loop "$swarm_kernel_binary" "$swarm_loop_state_root")"
printf '%s\n' "$swarm_loop_after_fail_output" | grep -F '"attempt":2' >/dev/null
printf '%s\n' "$swarm_loop_after_fail_output" | grep -F '"phase":"needs-builder"' >/dev/null
printf '%s\n' "$swarm_loop_after_fail_output" | grep -F '"healthy":false' >/dev/null
printf '%s\n' "$swarm_loop_after_fail_output" | grep -F '"needsAttention":true' >/dev/null
printf '%s\n' "$swarm_loop_after_fail_output" | grep -F '"attentionReason":"native summary crashed"' >/dev/null

swarm_loop_builder_retry_path="$(CLASP_SWARM_ACTOR=builder CLASP_SWARM_COMMAND=builder-start CLASP_SWARM_TASK_ID=language-loop "$swarm_kernel_binary" "$swarm_loop_state_root")"
[[ "$swarm_loop_builder_retry_path" == "$swarm_loop_event_log" ]]
swarm_loop_builder_retry_complete_path="$(CLASP_SWARM_ACTOR=builder CLASP_SWARM_COMMAND=builder-complete CLASP_SWARM_TASK_ID=language-loop "$swarm_kernel_binary" "$swarm_loop_state_root")"
[[ "$swarm_loop_builder_retry_complete_path" == "$swarm_loop_event_log" ]]
swarm_loop_verifier_retry_start_path="$(CLASP_SWARM_ACTOR=verifier CLASP_SWARM_COMMAND=verifier-start CLASP_SWARM_TASK_ID=language-loop "$swarm_kernel_binary" "$swarm_loop_state_root")"
[[ "$swarm_loop_verifier_retry_start_path" == "$swarm_loop_event_log" ]]
swarm_loop_verifier_pass_path="$(CLASP_SWARM_ACTOR=verifier CLASP_SWARM_COMMAND=verifier-pass CLASP_SWARM_TASK_ID=language-loop "$swarm_kernel_binary" "$swarm_loop_state_root")"
[[ "$swarm_loop_verifier_pass_path" == "$swarm_loop_event_log" ]]
grep -F '"kind":"verifier_passed"' "$swarm_loop_event_log" >/dev/null

swarm_loop_completed_output="$(CLASP_SWARM_COMMAND=monitor CLASP_SWARM_TASK_ID=language-loop "$swarm_kernel_binary" "$swarm_loop_state_root")"
printf '%s\n' "$swarm_loop_completed_output" | grep -F '"attempt":2' >/dev/null
printf '%s\n' "$swarm_loop_completed_output" | grep -F '"phase":"completed"' >/dev/null
printf '%s\n' "$swarm_loop_completed_output" | grep -F '"completed":true' >/dev/null
printf '%s\n' "$swarm_loop_completed_output" | grep -F '"builderRuns":2' >/dev/null
printf '%s\n' "$swarm_loop_completed_output" | grep -F '"verifierRuns":2' >/dev/null
printf '%s\n' "$swarm_loop_completed_output" | grep -F '"healthy":true' >/dev/null
printf '%s\n' "$swarm_loop_completed_output" | grep -F '"needsAttention":false' >/dev/null

grep -E '"atMs":[0-9]+' "$swarm_event_log" >/dev/null

swarm_sqlite_bootstrap_output="$("$claspc_bin" --json swarm bootstrap "$swarm_sqlite_state_root" bootstrap)"
printf '%s\n' "$swarm_sqlite_bootstrap_output" | grep -F "\"database\":\"$swarm_sqlite_db\"" >/dev/null
printf '%s\n' "$swarm_sqlite_bootstrap_output" | grep -F '"kind":"task_created"' >/dev/null
swarm_sqlite_lease_output="$(CLASP_SWARM_ACTOR=worker-1 "$claspc_bin" --json swarm lease "$swarm_sqlite_state_root" bootstrap)"
printf '%s\n' "$swarm_sqlite_lease_output" | grep -F '"kind":"lease_acquired"' >/dev/null
swarm_sqlite_heartbeat_output="$(CLASP_SWARM_ACTOR=worker-1 "$claspc_bin" --json swarm heartbeat "$swarm_sqlite_state_root" bootstrap)"
printf '%s\n' "$swarm_sqlite_heartbeat_output" | grep -F '"kind":"worker_heartbeat"' >/dev/null
swarm_sqlite_complete_output="$(CLASP_SWARM_ACTOR=worker-1 "$claspc_bin" --json swarm complete "$swarm_sqlite_state_root" bootstrap)"
printf '%s\n' "$swarm_sqlite_complete_output" | grep -F '"kind":"task_completed"' >/dev/null
swarm_sqlite_status_output="$("$claspc_bin" --json swarm status "$swarm_sqlite_state_root" bootstrap)"
printf '%s\n' "$swarm_sqlite_status_output" | grep -F '"taskId":"bootstrap"' >/dev/null
printf '%s\n' "$swarm_sqlite_status_output" | grep -F '"status":"completed"' >/dev/null
printf '%s\n' "$swarm_sqlite_status_output" | grep -F '"attempts":1' >/dev/null
swarm_sqlite_bootstrap_repair_output="$("$claspc_bin" --json swarm bootstrap "$swarm_sqlite_state_root" repair)"
printf '%s\n' "$swarm_sqlite_bootstrap_repair_output" | grep -F '"taskId":"repair"' >/dev/null
swarm_sqlite_repair_lease_output="$(CLASP_SWARM_ACTOR=manager "$claspc_bin" --json swarm lease "$swarm_sqlite_state_root" repair)"
printf '%s\n' "$swarm_sqlite_repair_lease_output" | grep -F '"kind":"lease_acquired"' >/dev/null
swarm_sqlite_wrong_tool_marker="$test_root_abs/swarm-sqlite-wrong-tool.marker"
swarm_sqlite_wrong_verifier_marker="$test_root_abs/swarm-sqlite-wrong-verifier.marker"
expect_command_failure_contains 'active lease is owned by `manager`' env CLASP_SWARM_ACTOR=intruder "$claspc_bin" --json swarm heartbeat "$swarm_sqlite_state_root" repair
expect_command_failure_contains 'active lease is owned by `manager`' env CLASP_SWARM_ACTOR=intruder "$claspc_bin" --json swarm complete "$swarm_sqlite_state_root" repair
expect_command_failure_contains 'active lease is owned by `manager`' env CLASP_SWARM_ACTOR=intruder "$claspc_bin" --json swarm fail "$swarm_sqlite_state_root" repair
expect_command_failure_contains 'active lease is owned by `manager`' env CLASP_SWARM_ACTOR=intruder "$claspc_bin" --json swarm release "$swarm_sqlite_state_root" repair
expect_command_failure_contains 'actor `intruder` is not a swarm manager' env CLASP_SWARM_ACTOR=intruder "$claspc_bin" --json swarm retry "$swarm_sqlite_state_root" repair
expect_command_failure_contains 'actor `intruder` is not a swarm manager' env CLASP_SWARM_ACTOR=intruder "$claspc_bin" --json swarm stop "$swarm_sqlite_state_root" repair
expect_command_failure_contains 'active lease is owned by `manager`' env CLASP_SWARM_ACTOR=intruder "$claspc_bin" --json swarm tool "$swarm_sqlite_state_root" repair --cwd "$project_root" -- bash -lc 'printf wrong-tool > "$1"' bash "$swarm_sqlite_wrong_tool_marker"
expect_command_failure_contains 'lease is owned by `manager`' env CLASP_SWARM_ACTOR=intruder "$claspc_bin" --json swarm verifier run "$swarm_sqlite_state_root" repair native-smoke --cwd "$project_root" -- bash -lc 'printf wrong-verifier > "$1"' bash "$swarm_sqlite_wrong_verifier_marker"
[[ ! -e "$swarm_sqlite_wrong_tool_marker" ]]
[[ ! -e "$swarm_sqlite_wrong_verifier_marker" ]]
swarm_sqlite_repair_owned_status_output="$("$claspc_bin" --json swarm status "$swarm_sqlite_state_root" repair)"
printf '%s\n' "$swarm_sqlite_repair_owned_status_output" | grep -F '"status":"leased"' >/dev/null
printf '%s\n' "$swarm_sqlite_repair_owned_status_output" | grep -F '"leaseActor":"manager"' >/dev/null
swarm_sqlite_tool_output="$(CLASP_SWARM_ACTOR=manager "$claspc_bin" --json swarm tool "$swarm_sqlite_state_root" repair --cwd "$project_root" -- bash -lc 'printf tool-ok; >&2 printf tool-err')"
printf '%s\n' "$swarm_sqlite_tool_output" | grep -F '"role":"tool"' >/dev/null
printf '%s\n' "$swarm_sqlite_tool_output" | grep -F '"status":"passed"' >/dev/null
swarm_sqlite_tool_stdout_path="$(printf '%s\n' "$swarm_sqlite_tool_output" | sed -n 's/.*"stdoutArtifactPath":"\([^"]*\)".*/\1/p')"
swarm_sqlite_tool_stderr_path="$(printf '%s\n' "$swarm_sqlite_tool_output" | sed -n 's/.*"stderrArtifactPath":"\([^"]*\)".*/\1/p')"
[[ -f "$swarm_sqlite_tool_stdout_path" ]]
[[ -f "$swarm_sqlite_tool_stderr_path" ]]
grep -Fx 'tool-ok' "$swarm_sqlite_tool_stdout_path" >/dev/null
grep -Fx 'tool-err' "$swarm_sqlite_tool_stderr_path" >/dev/null
swarm_sqlite_verifier_output="$(CLASP_SWARM_ACTOR=manager "$claspc_bin" --json swarm verifier run "$swarm_sqlite_state_root" repair native-smoke --cwd "$project_root" -- bash -lc 'printf verifier-ok')"
printf '%s\n' "$swarm_sqlite_verifier_output" | grep -F '"role":"verifier"' >/dev/null
printf '%s\n' "$swarm_sqlite_verifier_output" | grep -F '"status":"passed"' >/dev/null
swarm_sqlite_mergegate_output="$("$claspc_bin" --json swarm mergegate decide "$swarm_sqlite_state_root" repair trunk native-smoke)"
printf '%s\n' "$swarm_sqlite_mergegate_output" | grep -F '"mergegateName":"trunk"' >/dev/null
printf '%s\n' "$swarm_sqlite_mergegate_output" | grep -F '"verdict":"pass"' >/dev/null
swarm_sqlite_start_output="$("$claspc_bin" --json swarm start "$swarm_sqlite_state_root" manager-task)"
printf '%s\n' "$swarm_sqlite_start_output" | grep -F '"kind":"task_created"' >/dev/null
printf '%s\n' "$swarm_sqlite_start_output" | grep -F '"taskId":"manager-task"' >/dev/null
swarm_sqlite_manager_lease_output="$(CLASP_SWARM_ACTOR=manager "$claspc_bin" --json swarm lease "$swarm_sqlite_state_root" manager-task)"
printf '%s\n' "$swarm_sqlite_manager_lease_output" | grep -F '"kind":"lease_acquired"' >/dev/null
expect_command_failure_contains 'actor `intruder` is not a swarm manager' env CLASP_SWARM_ACTOR=intruder "$claspc_bin" --json swarm stop "$swarm_sqlite_state_root" manager-task
swarm_sqlite_stop_output="$(CLASP_SWARM_ACTOR=manager "$claspc_bin" --json swarm stop "$swarm_sqlite_state_root" manager-task)"
printf '%s\n' "$swarm_sqlite_stop_output" | grep -F '"kind":"task_stopped"' >/dev/null
swarm_sqlite_stopped_status_output="$("$claspc_bin" --json swarm status "$swarm_sqlite_state_root" manager-task)"
printf '%s\n' "$swarm_sqlite_stopped_status_output" | grep -F '"status":"stopped"' >/dev/null
printf '%s\n' "$swarm_sqlite_stopped_status_output" | grep -F '"leaseActor":""' >/dev/null
expect_command_failure_contains 'actor `intruder` is not a swarm manager' env CLASP_SWARM_ACTOR=intruder "$claspc_bin" --json swarm resume "$swarm_sqlite_state_root" manager-task
swarm_sqlite_resume_output="$(CLASP_SWARM_ACTOR=manager "$claspc_bin" --json swarm resume "$swarm_sqlite_state_root" manager-task)"
printf '%s\n' "$swarm_sqlite_resume_output" | grep -F '"kind":"task_resumed"' >/dev/null
swarm_sqlite_resumed_status_output="$("$claspc_bin" --json swarm status "$swarm_sqlite_state_root" manager-task)"
printf '%s\n' "$swarm_sqlite_resumed_status_output" | grep -F '"status":"queued"' >/dev/null
swarm_sqlite_tail_output="$("$claspc_bin" --json swarm tail "$swarm_sqlite_state_root" manager-task --limit 4)"
printf '%s\n' "$swarm_sqlite_tail_output" | grep -F '"kind":"task_created"' >/dev/null
printf '%s\n' "$swarm_sqlite_tail_output" | grep -F '"kind":"task_stopped"' >/dev/null
printf '%s\n' "$swarm_sqlite_tail_output" | grep -F '"kind":"task_resumed"' >/dev/null
swarm_sqlite_approval_output="$(CLASP_SWARM_ACTOR=manager "$claspc_bin" --json swarm approve "$swarm_sqlite_state_root" repair merge-ready)"
printf '%s\n' "$swarm_sqlite_approval_output" | grep -F '"name":"merge-ready"' >/dev/null
printf '%s\n' "$swarm_sqlite_approval_output" | grep -F '"taskId":"repair"' >/dev/null
swarm_sqlite_approvals_output="$("$claspc_bin" --json swarm approvals "$swarm_sqlite_state_root" repair)"
printf '%s\n' "$swarm_sqlite_approvals_output" | grep -F '"name":"merge-ready"' >/dev/null
printf '%s\n' "$swarm_sqlite_approvals_output" | grep -F '"actor":"manager"' >/dev/null
swarm_sqlite_objective_output="$("$claspc_bin" --json swarm objective create "$swarm_sqlite_state_root" appbench --detail 'Beat appbench' --max-tasks 2 --max-runs 3)"
printf '%s\n' "$swarm_sqlite_objective_output" | grep -F '"objectiveId":"appbench"' >/dev/null
printf '%s\n' "$swarm_sqlite_objective_output" | grep -F '"maxTasks":2' >/dev/null
swarm_sqlite_empty_objective_output="$("$claspc_bin" --json swarm objective create "$swarm_sqlite_state_root" empty-loop --detail 'Plan work from scratch')"
printf '%s\n' "$swarm_sqlite_empty_objective_output" | grep -F '"objectiveId":"empty-loop"' >/dev/null
swarm_sqlite_empty_manager_output="$("$claspc_bin" --json swarm manager next "$swarm_sqlite_state_root" empty-loop)"
printf '%s\n' "$swarm_sqlite_empty_manager_output" | grep -F '"status":"empty"' >/dev/null
printf '%s\n' "$swarm_sqlite_empty_manager_output" | grep -F '"action":"plan-tasks"' >/dev/null
printf '%s\n' "$swarm_sqlite_empty_manager_output" | grep -F '"taskCount":0' >/dev/null
printf '%s\n' "$swarm_sqlite_empty_manager_output" | grep -F '"suggestedCommand":["claspc","swarm","task","create","<state-root>","empty-loop","<task-id>"]' >/dev/null
swarm_sqlite_empty_manager_text="$("$claspc_bin" swarm manager next "$swarm_sqlite_state_root" empty-loop)"
printf '%s\n' "$swarm_sqlite_empty_manager_text" | grep -F 'objective empty-loop' >/dev/null
printf '%s\n' "$swarm_sqlite_empty_manager_text" | grep -F 'status: empty' >/dev/null
printf '%s\n' "$swarm_sqlite_empty_manager_text" | grep -F 'action: plan-tasks' >/dev/null
printf '%s\n' "$swarm_sqlite_empty_manager_text" | grep -F 'command: claspc swarm task create <state-root> empty-loop <task-id>' >/dev/null
swarm_sqlite_recovery_objective_output="$("$claspc_bin" --json swarm objective create "$swarm_sqlite_state_root" recovery-loop --detail 'Recover expired leases')"
printf '%s\n' "$swarm_sqlite_recovery_objective_output" | grep -F '"objectiveId":"recovery-loop"' >/dev/null
swarm_sqlite_recovery_task_output="$("$claspc_bin" --json swarm task create "$swarm_sqlite_state_root" recovery-loop expired-lease --detail 'Recover stale worker lease' --lease-timeout-ms 1)"
printf '%s\n' "$swarm_sqlite_recovery_task_output" | grep -F '"taskId":"expired-lease"' >/dev/null
CLASP_SWARM_ACTOR=worker-stale "$claspc_bin" --json swarm lease "$swarm_sqlite_state_root" expired-lease >/dev/null
sleep 0.05
swarm_sqlite_recovery_status_output="$("$claspc_bin" --json swarm status "$swarm_sqlite_state_root" expired-lease)"
printf '%s\n' "$swarm_sqlite_recovery_status_output" | grep -F '"leaseExpired":true' >/dev/null
swarm_sqlite_expired_tool_marker="$test_root_abs/swarm-sqlite-expired-tool.marker"
expect_command_failure_contains 'lease held by `worker-stale` expired' env CLASP_SWARM_ACTOR=worker-stale "$claspc_bin" --json swarm complete "$swarm_sqlite_state_root" expired-lease
expect_command_failure_contains 'lease held by `worker-stale` expired' env CLASP_SWARM_ACTOR=worker-stale "$claspc_bin" --json swarm tool "$swarm_sqlite_state_root" expired-lease --cwd "$project_root" -- bash -lc 'printf expired-tool > "$1"' bash "$swarm_sqlite_expired_tool_marker"
[[ ! -e "$swarm_sqlite_expired_tool_marker" ]]
swarm_sqlite_recovery_manager_output="$("$claspc_bin" --json swarm manager next "$swarm_sqlite_state_root" recovery-loop)"
printf '%s\n' "$swarm_sqlite_recovery_manager_output" | grep -F '"action":"recover-lease"' >/dev/null
printf '%s\n' "$swarm_sqlite_recovery_manager_output" | grep -F '"taskId":"expired-lease"' >/dev/null
swarm_sqlite_recovery_lease_output="$(CLASP_SWARM_ACTOR=manager "$claspc_bin" --json swarm lease "$swarm_sqlite_state_root" expired-lease)"
printf '%s\n' "$swarm_sqlite_recovery_lease_output" | grep -F '"attempts":2' >/dev/null
swarm_sqlite_recovery_complete_output="$(CLASP_SWARM_ACTOR=manager "$claspc_bin" --json swarm complete "$swarm_sqlite_state_root" expired-lease)"
printf '%s\n' "$swarm_sqlite_recovery_complete_output" | grep -F '"kind":"task_completed"' >/dev/null
swarm_sqlite_task_plan_output="$("$claspc_bin" --json swarm task create "$swarm_sqlite_state_root" appbench plan --detail 'Plan work' --max-runs 1)"
printf '%s\n' "$swarm_sqlite_task_plan_output" | grep -F '"taskId":"plan"' >/dev/null
printf '%s\n' "$swarm_sqlite_task_plan_output" | grep -F '"ready":true' >/dev/null
swarm_sqlite_task_repair_output="$("$claspc_bin" --json swarm task create "$swarm_sqlite_state_root" appbench repair-2 --detail 'Repair runtime path' --depends-on plan --max-runs 1)"
printf '%s\n' "$swarm_sqlite_task_repair_output" | grep -F '"taskId":"repair-2"' >/dev/null
printf '%s\n' "$swarm_sqlite_task_repair_output" | grep -F '"ready":false' >/dev/null
swarm_sqlite_policy_output="$("$claspc_bin" --json swarm policy set "$swarm_sqlite_state_root" repair-2 trunk --require-approval merge-ready --require-verifier native-smoke)"
printf '%s\n' "$swarm_sqlite_policy_output" | grep -F '"taskId":"repair-2"' >/dev/null
printf '%s\n' "$swarm_sqlite_policy_output" | grep -F '"mergegateName":"trunk"' >/dev/null
swarm_sqlite_manager_initial_output="$("$claspc_bin" --json swarm manager next "$swarm_sqlite_state_root" appbench)"
printf '%s\n' "$swarm_sqlite_manager_initial_output" | grep -F '"action":"run-task"' >/dev/null
printf '%s\n' "$swarm_sqlite_manager_initial_output" | grep -F '"taskId":"plan"' >/dev/null
swarm_sqlite_ready_before_output="$("$claspc_bin" --json swarm ready "$swarm_sqlite_state_root" appbench)"
printf '%s\n' "$swarm_sqlite_ready_before_output" | grep -F '"taskId":"plan"' >/dev/null
if printf '%s\n' "$swarm_sqlite_ready_before_output" | grep -F '"taskId":"repair-2"' >/dev/null; then
  echo "repair-2 should not be ready before plan completes" >&2
  exit 1
fi
swarm_sqlite_plan_lease_output="$(CLASP_SWARM_ACTOR=manager "$claspc_bin" --json swarm lease "$swarm_sqlite_state_root" plan)"
printf '%s\n' "$swarm_sqlite_plan_lease_output" | grep -F '"kind":"lease_acquired"' >/dev/null
swarm_sqlite_plan_complete_output="$(CLASP_SWARM_ACTOR=manager "$claspc_bin" --json swarm complete "$swarm_sqlite_state_root" plan)"
printf '%s\n' "$swarm_sqlite_plan_complete_output" | grep -F '"taskId":"plan"' >/dev/null
swarm_sqlite_ready_after_output="$("$claspc_bin" --json swarm ready "$swarm_sqlite_state_root" appbench)"
printf '%s\n' "$swarm_sqlite_ready_after_output" | grep -F '"taskId":"repair-2"' >/dev/null
swarm_sqlite_manager_after_plan_output="$("$claspc_bin" --json swarm manager next "$swarm_sqlite_state_root" appbench)"
printf '%s\n' "$swarm_sqlite_manager_after_plan_output" | grep -F '"action":"run-task"' >/dev/null
printf '%s\n' "$swarm_sqlite_manager_after_plan_output" | grep -F '"taskId":"repair-2"' >/dev/null
swarm_sqlite_repair_lease_output="$(CLASP_SWARM_ACTOR=manager "$claspc_bin" --json swarm lease "$swarm_sqlite_state_root" repair-2)"
printf '%s\n' "$swarm_sqlite_repair_lease_output" | grep -F '"kind":"lease_acquired"' >/dev/null
swarm_sqlite_repair_complete_output="$(CLASP_SWARM_ACTOR=manager "$claspc_bin" --json swarm complete "$swarm_sqlite_state_root" repair-2)"
printf '%s\n' "$swarm_sqlite_repair_complete_output" | grep -F '"taskId":"repair-2"' >/dev/null
swarm_sqlite_repair_status_output="$("$claspc_bin" --json swarm status "$swarm_sqlite_state_root" repair-2)"
printf '%s\n' "$swarm_sqlite_repair_status_output" | grep -F '"missingVerifiers":["native-smoke"]' >/dev/null
swarm_sqlite_manager_after_repair_output="$("$claspc_bin" --json swarm manager next "$swarm_sqlite_state_root" appbench)"
printf '%s\n' "$swarm_sqlite_manager_after_repair_output" | grep -F '"action":"run-verifier"' >/dev/null
swarm_sqlite_wrong_completed_verifier_marker="$test_root_abs/swarm-sqlite-wrong-completed-verifier.marker"
expect_command_failure_contains 'lease is owned by `manager`' env CLASP_SWARM_ACTOR=intruder "$claspc_bin" --json swarm verifier run "$swarm_sqlite_state_root" repair-2 native-smoke --cwd "$project_root" -- bash -lc 'printf wrong-completed-verifier > "$1"' bash "$swarm_sqlite_wrong_completed_verifier_marker"
[[ ! -e "$swarm_sqlite_wrong_completed_verifier_marker" ]]
swarm_sqlite_repair_verifier_output="$(CLASP_SWARM_ACTOR=manager "$claspc_bin" --json swarm verifier run "$swarm_sqlite_state_root" repair-2 native-smoke --cwd "$project_root" -- bash -lc 'printf verifier-ok')"
printf '%s\n' "$swarm_sqlite_repair_verifier_output" | grep -F '"taskId":"repair-2"' >/dev/null
swarm_sqlite_manager_after_verifier_output="$("$claspc_bin" --json swarm manager next "$swarm_sqlite_state_root" appbench)"
printf '%s\n' "$swarm_sqlite_manager_after_verifier_output" | grep -F '"action":"request-approval"' >/dev/null
swarm_sqlite_manager_after_verifier_text="$("$claspc_bin" swarm manager next "$swarm_sqlite_state_root" appbench)"
printf '%s\n' "$swarm_sqlite_manager_after_verifier_text" | grep -F 'objective appbench' >/dev/null
printf '%s\n' "$swarm_sqlite_manager_after_verifier_text" | grep -F 'action: request-approval' >/dev/null
printf '%s\n' "$swarm_sqlite_manager_after_verifier_text" | grep -F 'approval: merge-ready' >/dev/null
printf '%s\n' "$swarm_sqlite_manager_after_verifier_text" | grep -F 'command: claspc swarm approve <state-root> repair-2 merge-ready' >/dev/null
swarm_sqlite_repair_approval_output="$(CLASP_SWARM_ACTOR=manager "$claspc_bin" --json swarm approve "$swarm_sqlite_state_root" repair-2 merge-ready)"
printf '%s\n' "$swarm_sqlite_repair_approval_output" | grep -F '"taskId":"repair-2"' >/dev/null
swarm_sqlite_repair_approval_text="$(CLASP_SWARM_ACTOR=manager "$claspc_bin" swarm approve "$swarm_sqlite_state_root" repair-2 merge-ready)"
printf '%s\n' "$swarm_sqlite_repair_approval_text" | grep -F 'approval repair-2 merge-ready' >/dev/null
printf '%s\n' "$swarm_sqlite_repair_approval_text" | grep -F 'actor: manager' >/dev/null
swarm_sqlite_manager_after_approval_output="$("$claspc_bin" --json swarm manager next "$swarm_sqlite_state_root" appbench)"
printf '%s\n' "$swarm_sqlite_manager_after_approval_output" | grep -F '"action":"decide-mergegate"' >/dev/null
swarm_sqlite_repair_mergegate_output="$("$claspc_bin" --json swarm mergegate decide "$swarm_sqlite_state_root" repair-2 trunk native-smoke)"
printf '%s\n' "$swarm_sqlite_repair_mergegate_output" | grep -F '"taskId":"repair-2"' >/dev/null
printf '%s\n' "$swarm_sqlite_repair_mergegate_output" | grep -F '"verdict":"pass"' >/dev/null
swarm_sqlite_repair_status_text="$("$claspc_bin" swarm status "$swarm_sqlite_state_root" repair-2)"
printf '%s\n' "$swarm_sqlite_repair_status_text" | grep -F 'task repair-2' >/dev/null
printf '%s\n' "$swarm_sqlite_repair_status_text" | grep -F 'status: completed' >/dev/null
printf '%s\n' "$swarm_sqlite_repair_status_text" | grep -F 'objective: appbench' >/dev/null
printf '%s\n' "$swarm_sqlite_repair_status_text" | grep -F 'merge policy: trunk satisfied=true' >/dev/null
swarm_sqlite_repair_tail_text="$("$claspc_bin" swarm tail "$swarm_sqlite_state_root" repair-2 --limit 4)"
printf '%s\n' "$swarm_sqlite_repair_tail_text" | grep -F 'repair-2 verifier_run_finished by manager' >/dev/null
printf '%s\n' "$swarm_sqlite_repair_tail_text" | grep -F 'repair-2 approval_granted by manager' >/dev/null
printf '%s\n' "$swarm_sqlite_repair_tail_text" | grep -F 'repair-2 mergegate_decision by manager' >/dev/null
swarm_sqlite_manager_complete_output="$("$claspc_bin" --json swarm manager next "$swarm_sqlite_state_root" appbench)"
printf '%s\n' "$swarm_sqlite_manager_complete_output" | grep -F '"action":"objective-complete"' >/dev/null
swarm_sqlite_objective_status_output="$("$claspc_bin" --json swarm objective status "$swarm_sqlite_state_root" appbench)"
printf '%s\n' "$swarm_sqlite_objective_status_output" | grep -F '"objectiveId":"appbench"' >/dev/null
printf '%s\n' "$swarm_sqlite_objective_status_output" | grep -F '"projectedStatus":"completed"' >/dev/null
printf '%s\n' "$swarm_sqlite_objective_status_output" | grep -F '"taskCount":2' >/dev/null
printf '%s\n' "$swarm_sqlite_objective_status_output" | grep -F '"taskId":"repair-2"' >/dev/null
printf '%s\n' "$swarm_sqlite_objective_status_output" | grep -F '"satisfied":true' >/dev/null
swarm_sqlite_objectives_output="$("$claspc_bin" --json swarm objectives "$swarm_sqlite_state_root")"
printf '%s\n' "$swarm_sqlite_objectives_output" | grep -F '"objectiveId":"appbench"' >/dev/null
printf '%s\n' "$swarm_sqlite_objectives_output" | grep -F '"projectedStatus":"completed"' >/dev/null
swarm_sqlite_runs_output="$("$claspc_bin" --json swarm runs "$swarm_sqlite_state_root" repair)"
printf '%s\n' "$swarm_sqlite_runs_output" | grep -F '"role":"tool"' >/dev/null
printf '%s\n' "$swarm_sqlite_runs_output" | grep -F '"role":"verifier"' >/dev/null
printf '%s\n' "$swarm_sqlite_runs_output" | grep -F '"name":"native-smoke"' >/dev/null
swarm_sqlite_artifacts_output="$("$claspc_bin" --json swarm artifacts "$swarm_sqlite_state_root" repair)"
printf '%s\n' "$swarm_sqlite_artifacts_output" | grep -F '"kind":"stdout"' >/dev/null
printf '%s\n' "$swarm_sqlite_artifacts_output" | grep -F '"kind":"stderr"' >/dev/null

swarm_native_run_output="$(
  CLASP_SWARM_CWD="$project_root" \
  CLASP_SWARM_ACTOR=manager \
  "$claspc_bin" run "$project_root/examples/swarm-native/Main.clasp" -- "$swarm_native_run_state_root"
)"
printf '%s\n' "$swarm_native_run_output" | grep -F '"objective":"appbench"' >/dev/null
printf '%s\n' "$swarm_native_run_output" | grep -F '"planningTask":"plan"' >/dev/null
printf '%s\n' "$swarm_native_run_output" | grep -F '"repairTask":"repair-2"' >/dev/null
printf '%s\n' "$swarm_native_run_output" | grep -F '"deadlineAtMs":4102444800000' >/dev/null
printf '%s\n' "$swarm_native_run_output" | grep -F '"deadlineAtMs":4102444200000' >/dev/null
printf '%s\n' "$swarm_native_run_output" | grep -F '"deadlineAtMs":4102444500000' >/dev/null
printf '%s\n' "$swarm_native_run_output" | grep -F '"managerBefore":{"objectiveId":"appbench","status":"ready","action":"run-task"' >/dev/null
printf '%s\n' "$swarm_native_run_output" | grep -F '"planningStep":{"lease":{"database":"' >/dev/null
printf '%s\n' "$swarm_native_run_output" | grep -F '"kind":"lease_acquired","taskId":"plan"' >/dev/null
printf '%s\n' "$swarm_native_run_output" | grep -F '"task":{"attempts":1,"taskId":"plan"' >/dev/null
printf '%s\n' "$swarm_native_run_output" | grep -F '"run":{"actor":"manager","command":["bash","-lc","printf planner-ok"]' >/dev/null
printf '%s\n' "$swarm_native_run_output" | grep -F '"status":{"database":"' >/dev/null
printf '%s\n' "$swarm_native_run_output" | grep -F '"kind":"task_completed","taskId":"plan"' >/dev/null
printf '%s\n' "$swarm_native_run_output" | grep -F '"mailbox":{"history":[{"actor":"manager","atMs":' >/dev/null
printf '%s\n' "$swarm_native_run_output" | grep -F '"managerAfterPlan":{"objectiveId":"appbench","status":"ready","action":"run-task"' >/dev/null
printf '%s\n' "$swarm_native_run_output" | grep -F '"repairStep":{"lease":{"database":"' >/dev/null
printf '%s\n' "$swarm_native_run_output" | grep -F '"kind":"lease_acquired","taskId":"repair-2"' >/dev/null
printf '%s\n' "$swarm_native_run_output" | grep -F '"run":{"actor":"manager","command":["bash","-lc","printf builder-ok"]' >/dev/null
printf '%s\n' "$swarm_native_run_output" | grep -F '"kind":"task_completed","taskId":"repair-2"' >/dev/null
printf '%s\n' "$swarm_native_run_output" | grep -F '"managerAfterRepair":{"objectiveId":"appbench","status":"ready","action":"run-verifier"' >/dev/null
printf '%s\n' "$swarm_native_run_output" | grep -F '"verifierStep":{"run":{"actor":"manager","command":["bash","-lc","printf verifier-ok"]' >/dev/null
printf '%s\n' "$swarm_native_run_output" | grep -F '"name":"native-smoke","role":"verifier"' >/dev/null
printf '%s\n' "$swarm_native_run_output" | grep -F '"managerAfterVerifier":{"objectiveId":"appbench","status":"ready","action":"request-approval"' >/dev/null
printf '%s\n' "$swarm_native_run_output" | grep -F '"reviewStep":{"approval":{"actor":"manager","approvalId":1' >/dev/null
printf '%s\n' "$swarm_native_run_output" | grep -F '"mergeDecision":{"taskId":"repair-2","mergegateName":"trunk","verdict":"pass"}' >/dev/null
printf '%s\n' "$swarm_native_run_output" | grep -F '"approvals":[{"actor":"manager","approvalId":1' >/dev/null
printf '%s\n' "$swarm_native_run_output" | grep -F '"kind":"approval_granted","taskId":"repair-2"' >/dev/null
printf '%s\n' "$swarm_native_run_output" | grep -F '"kind":"mergegate_decision","taskId":"repair-2"' >/dev/null
printf '%s\n' "$swarm_native_run_output" | grep -F '"objectiveStatus":{"objective":{"createdAtMs":' >/dev/null
printf '%s\n' "$swarm_native_run_output" | grep -F '"projectedStatus":"completed"' >/dev/null
printf '%s\n' "$swarm_native_run_output" | grep -F '"tasks":[{"attempts":1,"taskId":"plan"' >/dev/null
printf '%s\n' "$swarm_native_run_output" | grep -F '"summary":{"allTaskIds":["plan","repair-2"]' >/dev/null
printf '%s\n' "$swarm_native_run_output" | grep -F '"completedTaskIds":["plan","repair-2"]' >/dev/null
printf '%s\n' "$swarm_native_run_output" | grep -F '"managerAfter":{"objectiveId":"appbench","status":"completed","action":"objective-complete"' >/dev/null

env RUSTC=/definitely-missing-rustc "$claspc_bin" compile "$project_root/examples/swarm-native/Main.clasp" -o "$swarm_native_binary"
[[ -x "$swarm_native_binary" ]]
swarm_native_output="$(CLASP_SWARM_CWD="$project_root" CLASP_SWARM_ACTOR=manager "$swarm_native_binary" "$swarm_native_state_root")"
printf '%s\n' "$swarm_native_output" | grep -F '"objective":"appbench"' >/dev/null
printf '%s\n' "$swarm_native_output" | grep -F '"planningTask":"plan"' >/dev/null
printf '%s\n' "$swarm_native_output" | grep -F '"repairTask":"repair-2"' >/dev/null
printf '%s\n' "$swarm_native_output" | grep -F '"deadlineAtMs":4102444800000' >/dev/null
printf '%s\n' "$swarm_native_output" | grep -F '"deadlineAtMs":4102444200000' >/dev/null
printf '%s\n' "$swarm_native_output" | grep -F '"deadlineAtMs":4102444500000' >/dev/null
printf '%s\n' "$swarm_native_output" | grep -F '"planningStep":{"lease":{"database":"' >/dev/null
printf '%s\n' "$swarm_native_output" | grep -F '"managerAfterRepair":{"objectiveId":"appbench","status":"ready","action":"run-verifier"' >/dev/null
printf '%s\n' "$swarm_native_output" | grep -F '"managerAfterVerifier":{"objectiveId":"appbench","status":"ready","action":"request-approval"' >/dev/null
printf '%s\n' "$swarm_native_output" | grep -F '"reviewStep":{"approval":{"actor":"manager","approvalId":1' >/dev/null
printf '%s\n' "$swarm_native_output" | grep -F '"mergeDecision":{"taskId":"repair-2","mergegateName":"trunk","verdict":"pass"}' >/dev/null
printf '%s\n' "$swarm_native_output" | grep -F '"kind":"approval_granted","taskId":"repair-2"' >/dev/null
printf '%s\n' "$swarm_native_output" | grep -F '"projectedStatus":"completed"' >/dev/null
printf '%s\n' "$swarm_native_output" | grep -F '"completedTaskIds":["plan","repair-2"]' >/dev/null
printf '%s\n' "$swarm_native_output" | grep -F '"managerAfter":{"objectiveId":"appbench","status":"completed","action":"objective-complete"' >/dev/null

swarm_feedback_loop_state_root_abs="$test_root_abs/swarm-feedback-loop-state"
swarm_feedback_loop_workspace_root_abs="$test_root_abs/swarm-feedback-loop-workspace"
swarm_feedback_loop_workspace_abs="$swarm_feedback_loop_workspace_root_abs/workspace.txt"
swarm_feedback_loop_feedback_path_abs="$swarm_feedback_loop_state_root_abs/feedback.json"
swarm_feedback_loop_status_output_abs="$test_root_abs/swarm-feedback-loop-status.json"
swarm_feedback_loop_native_state_root_abs="$test_root_abs/swarm-feedback-loop-native-state"
swarm_feedback_loop_native_workspace_root_abs="$test_root_abs/swarm-feedback-loop-native-workspace"
swarm_feedback_loop_native_workspace_abs="$swarm_feedback_loop_native_workspace_root_abs/workspace.txt"

swarm_feedback_loop_output="$(
  CLASP_LOOP_CODEX_BIN_JSON="\"$test_root_abs/codex\"" \
  CLASP_LOOP_TASK_FILE_JSON="\"$test_root_abs/feedback-loop-task.md\"" \
  CLASP_LOOP_WORKSPACE_JSON="\"$swarm_feedback_loop_workspace_root_abs\"" \
  CLASP_LOOP_MAX_ATTEMPTS_JSON='2' \
  "$claspc_bin" run "$project_root/examples/swarm-native/FeedbackLoop.clasp" -- "$swarm_feedback_loop_state_root_abs"
)"
printf '%s\n' "$swarm_feedback_loop_output" | grep -F '"objectiveId":"autonomous-confidence"' >/dev/null
printf '%s\n' "$swarm_feedback_loop_output" | grep -F '"attempt":2' >/dev/null
printf '%s\n' "$swarm_feedback_loop_output" | grep -F '"phase":"completed"' >/dev/null
printf '%s\n' "$swarm_feedback_loop_output" | grep -F '"verdict":"pass"' >/dev/null
printf '%s\n' "$swarm_feedback_loop_output" | grep -F '"objectiveProjectedStatus":"completed"' >/dev/null
printf '%s\n' "$swarm_feedback_loop_output" | grep -F '"taskCount":4' >/dev/null
printf '%s\n' "$swarm_feedback_loop_output" | grep -F '"approvalCount":1' >/dev/null
printf '%s\n' "$swarm_feedback_loop_output" | grep -F '"mergeDecisionDetail":"Mergegate `autonomous-confidence` decided pass."' >/dev/null
printf '%s\n' "$swarm_feedback_loop_output" | grep -F '"mergeGateSatisfied":true' >/dev/null
printf '%s\n' "$swarm_feedback_loop_output" | grep -F '"builder-1"' >/dev/null
printf '%s\n' "$swarm_feedback_loop_output" | grep -F '"verifier-2"' >/dev/null
grep -Fx 'fixed-after-feedback' "$swarm_feedback_loop_workspace_abs" >/dev/null
grep -F '"verdict":"pass"' "$swarm_feedback_loop_feedback_path_abs" >/dev/null
CLASP_LOOP_COMMAND=status "$claspc_bin" run "$project_root/examples/swarm-native/FeedbackLoop.clasp" -- "$swarm_feedback_loop_state_root_abs" >"$swarm_feedback_loop_status_output_abs"
grep -F '"attempt":2' "$swarm_feedback_loop_status_output_abs" >/dev/null
grep -F '"phase":"completed"' "$swarm_feedback_loop_status_output_abs" >/dev/null
grep -F '"verdict":"pass"' "$swarm_feedback_loop_status_output_abs" >/dev/null
grep -F '"readyTaskIds":[]' "$swarm_feedback_loop_status_output_abs" >/dev/null
grep -F '"approvalCount":1' "$swarm_feedback_loop_status_output_abs" >/dev/null
grep -F '"mergeGateSatisfied":true' "$swarm_feedback_loop_status_output_abs" >/dev/null
swarm_feedback_loop_objective_status_output="$("$claspc_bin" --json swarm objective status "$swarm_feedback_loop_state_root_abs" autonomous-confidence)"
printf '%s\n' "$swarm_feedback_loop_objective_status_output" | grep -F '"objectiveId":"autonomous-confidence"' >/dev/null
printf '%s\n' "$swarm_feedback_loop_objective_status_output" | grep -F '"projectedStatus":"completed"' >/dev/null
printf '%s\n' "$swarm_feedback_loop_objective_status_output" | grep -F '"taskCount":4' >/dev/null
printf '%s\n' "$swarm_feedback_loop_objective_status_output" | grep -F '"taskId":"builder-2"' >/dev/null
printf '%s\n' "$swarm_feedback_loop_objective_status_output" | grep -F '"taskId":"verifier-2"' >/dev/null
printf '%s\n' "$swarm_feedback_loop_objective_status_output" | grep -F '"mergegateName":"autonomous-confidence"' >/dev/null
printf '%s\n' "$swarm_feedback_loop_objective_status_output" | grep -F '"satisfied":true' >/dev/null
swarm_feedback_loop_verifier_status_text="$("$claspc_bin" swarm status "$swarm_feedback_loop_state_root_abs" verifier-2)"
printf '%s\n' "$swarm_feedback_loop_verifier_status_text" | grep -F 'merge policy: autonomous-confidence satisfied=true' >/dev/null
swarm_feedback_loop_approvals_output="$("$claspc_bin" --json swarm approvals "$swarm_feedback_loop_state_root_abs" verifier-2)"
printf '%s\n' "$swarm_feedback_loop_approvals_output" | grep -F '"name":"merge-ready"' >/dev/null
swarm_feedback_loop_tail_output="$("$claspc_bin" --json swarm tail "$swarm_feedback_loop_state_root_abs" verifier-2 --limit 6)"
printf '%s\n' "$swarm_feedback_loop_tail_output" | grep -F '"kind":"approval_granted"' >/dev/null
printf '%s\n' "$swarm_feedback_loop_tail_output" | grep -F '"kind":"mergegate_decision"' >/dev/null
printf '%s\n' "$swarm_feedback_loop_tail_output" | grep -F '"verdict":"pass"' >/dev/null
swarm_feedback_loop_builder_runs_output="$("$claspc_bin" --json swarm runs "$swarm_feedback_loop_state_root_abs" builder-2)"
printf '%s\n' "$swarm_feedback_loop_builder_runs_output" | grep -F '"role":"tool"' >/dev/null
printf '%s\n' "$swarm_feedback_loop_builder_runs_output" | grep -F '"status":"passed"' >/dev/null
swarm_feedback_loop_verifier_runs_output="$("$claspc_bin" --json swarm runs "$swarm_feedback_loop_state_root_abs" verifier-2)"
printf '%s\n' "$swarm_feedback_loop_verifier_runs_output" | grep -F '"role":"verifier"' >/dev/null
printf '%s\n' "$swarm_feedback_loop_verifier_runs_output" | grep -F '"status":"passed"' >/dev/null
swarm_feedback_loop_builder_artifacts_output="$("$claspc_bin" --json swarm artifacts "$swarm_feedback_loop_state_root_abs" builder-2)"
printf '%s\n' "$swarm_feedback_loop_builder_artifacts_output" | grep -F '"kind":"stdout"' >/dev/null
printf '%s\n' "$swarm_feedback_loop_builder_artifacts_output" | grep -F '"kind":"stderr"' >/dev/null

env RUSTC=/definitely-missing-rustc "$claspc_bin" compile "$project_root/examples/swarm-native/FeedbackLoop.clasp" -o "$swarm_feedback_loop_binary"
[[ -x "$swarm_feedback_loop_binary" ]]
swarm_feedback_loop_native_output="$(
  CLASP_LOOP_CODEX_BIN_JSON="\"$test_root_abs/codex\"" \
  CLASP_LOOP_TASK_FILE_JSON="\"$test_root_abs/feedback-loop-task.md\"" \
  CLASP_LOOP_WORKSPACE_JSON="\"$swarm_feedback_loop_native_workspace_root_abs\"" \
  CLASP_LOOP_MAX_ATTEMPTS_JSON='2' \
  "$swarm_feedback_loop_binary" "$swarm_feedback_loop_native_state_root_abs"
)"
printf '%s\n' "$swarm_feedback_loop_native_output" | grep -F '"objectiveId":"autonomous-confidence"' >/dev/null
printf '%s\n' "$swarm_feedback_loop_native_output" | grep -F '"attempt":2' >/dev/null
printf '%s\n' "$swarm_feedback_loop_native_output" | grep -F '"verdict":"pass"' >/dev/null
printf '%s\n' "$swarm_feedback_loop_native_output" | grep -F '"objectiveProjectedStatus":"completed"' >/dev/null
printf '%s\n' "$swarm_feedback_loop_native_output" | grep -F '"approvalCount":1' >/dev/null
printf '%s\n' "$swarm_feedback_loop_native_output" | grep -F '"mergeGateSatisfied":true' >/dev/null
grep -Fx 'fixed-after-feedback' "$swarm_feedback_loop_native_workspace_abs" >/dev/null
CLASP_LOOP_COMMAND=status "$swarm_feedback_loop_binary" "$swarm_feedback_loop_native_state_root_abs" >"$swarm_feedback_loop_status_output_abs.native"
grep -F '"attempt":2' "$swarm_feedback_loop_status_output_abs.native" >/dev/null
grep -F '"phase":"completed"' "$swarm_feedback_loop_status_output_abs.native" >/dev/null
grep -F '"verdict":"pass"' "$swarm_feedback_loop_status_output_abs.native" >/dev/null
grep -F '"approvalCount":1' "$swarm_feedback_loop_status_output_abs.native" >/dev/null
grep -F '"mergeGateSatisfied":true' "$swarm_feedback_loop_status_output_abs.native" >/dev/null

goal_manager_state_root_abs="$test_root_abs/swarm-goal-manager-state"
goal_manager_workspace_root_abs="$test_root_abs/swarm-goal-manager-workspace"
goal_manager_workspace_abs="$goal_manager_workspace_root_abs/workspace.txt"
goal_manager_feedback_path_abs="$goal_manager_state_root_abs/feedback.json"
goal_manager_status_output_abs="$test_root_abs/swarm-goal-manager-status.json"
goal_manager_native_state_root_abs="$test_root_abs/swarm-goal-manager-native-state"
goal_manager_native_workspace_root_abs="$test_root_abs/swarm-goal-manager-native-workspace"
goal_manager_native_workspace_abs="$goal_manager_native_workspace_root_abs/workspace.txt"
goal_manager_live_state_root_abs="$test_root_abs/swarm-goal-manager-live-state"
goal_manager_live_workspace_root_abs="$test_root_abs/swarm-goal-manager-live-workspace"
goal_manager_live_output_abs="$test_root_abs/swarm-goal-manager-live-output.txt"
goal_manager_live_status_output_abs="$test_root_abs/swarm-goal-manager-live-status.json"
goal_manager_live_state_status_abs="$goal_manager_live_state_root_abs/status.json"
goal_manager_resume_state_root_abs="$test_root_abs/swarm-goal-manager-resume-state"
goal_manager_resume_workspace_root_abs="$test_root_abs/swarm-goal-manager-resume-workspace"
goal_manager_resume_output_abs="$test_root_abs/swarm-goal-manager-resume-output.txt"
goal_manager_resume_status_output_abs="$test_root_abs/swarm-goal-manager-resume-status.json"
goal_manager_resume_state_status_abs="$goal_manager_resume_state_root_abs/status.json"
goal_manager_dirty_resume_state_root_abs="$test_root_abs/swarm-goal-manager-dirty-resume-state"
goal_manager_dirty_resume_workspace_root_abs="$test_root_abs/swarm-goal-manager-dirty-resume-workspace"
goal_manager_dirty_resume_output_abs="$test_root_abs/swarm-goal-manager-dirty-resume-output.txt"
goal_manager_dirty_resume_status_output_abs="$test_root_abs/swarm-goal-manager-dirty-resume-status.json"
goal_manager_dirty_resume_service_output_abs="$test_root_abs/swarm-goal-manager-dirty-resume-service-status.json"
goal_manager_dirty_resume_state_status_abs="$goal_manager_dirty_resume_state_root_abs/status.json"
goal_manager_service_restart_state_root_abs="$test_root_abs/swarm-goal-manager-service-restart-state"
goal_manager_service_restart_workspace_root_abs="$test_root_abs/swarm-goal-manager-service-restart-workspace"
goal_manager_service_restart_output_abs="$test_root_abs/swarm-goal-manager-service-restart-output.txt"
goal_manager_service_restart_status_output_abs="$test_root_abs/swarm-goal-manager-service-restart-status.json"
goal_manager_service_restart_service_output_abs="$test_root_abs/swarm-goal-manager-service-restart-service-status.json"
goal_manager_service_restart_state_status_abs="$goal_manager_service_restart_state_root_abs/status.json"
goal_manager_parallel_live_state_root_abs="$test_root_abs/swarm-goal-manager-parallel-live-state"
goal_manager_parallel_live_workspace_root_abs="$test_root_abs/swarm-goal-manager-parallel-live-workspace"
goal_manager_parallel_live_output_abs="$test_root_abs/swarm-goal-manager-parallel-live-output.txt"
goal_manager_parallel_live_status_output_abs="$test_root_abs/swarm-goal-manager-parallel-live-status.json"
goal_manager_parallel_live_state_status_abs="$goal_manager_parallel_live_state_root_abs/status.json"
goal_manager_promotion_conflict_state_root_abs="$test_root_abs/swarm-goal-manager-promotion-conflict-state"
goal_manager_promotion_conflict_workspace_root_abs="$test_root_abs/swarm-goal-manager-promotion-conflict-workspace"
goal_manager_budget_fail_state_root_abs="$test_root_abs/swarm-goal-manager-budget-fail-state"
goal_manager_cycle_fail_state_root_abs="$test_root_abs/swarm-goal-manager-cycle-fail-state"
goal_manager_reserved_dep_fail_state_root_abs="$test_root_abs/swarm-goal-manager-reserved-dep-fail-state"
goal_manager_replan_state_root_abs="$test_root_abs/swarm-goal-manager-replan-state"
goal_manager_replan_workspace_root_abs="$test_root_abs/swarm-goal-manager-replan-workspace"
goal_manager_replan_workspace_abs="$goal_manager_replan_workspace_root_abs/workspace.txt"
goal_manager_benchmark_state_root_abs="$test_root_abs/swarm-goal-manager-benchmark-state"
goal_manager_benchmark_workspace_root_abs="$test_root_abs/swarm-goal-manager-benchmark-workspace"
goal_manager_benchmark_workspace_abs="$goal_manager_benchmark_workspace_root_abs/workspace.txt"
goal_manager_benchmark_resume_state_root_abs="$test_root_abs/swarm-goal-manager-benchmark-resume-state"
goal_manager_benchmark_resume_workspace_root_abs="$test_root_abs/swarm-goal-manager-benchmark-resume-workspace"
goal_manager_benchmark_resume_output_abs="$test_root_abs/swarm-goal-manager-benchmark-resume-output.txt"
goal_manager_benchmark_resume_status_output_abs="$test_root_abs/swarm-goal-manager-benchmark-resume-status.json"
goal_manager_benchmark_resume_state_status_abs="$goal_manager_benchmark_resume_state_root_abs/status.json"
goal_manager_parallel_benchmark_state_root_abs="$test_root_abs/swarm-goal-manager-parallel-benchmark-state"
goal_manager_parallel_benchmark_workspace_root_abs="$test_root_abs/swarm-goal-manager-parallel-benchmark-workspace"
goal_manager_parallel_benchmark_workspace_abs="$goal_manager_parallel_benchmark_workspace_root_abs/workspace.txt"
goal_manager_benchmark_fail_state_root_abs="$test_root_abs/swarm-goal-manager-benchmark-fail-state"
goal_manager_benchmark_fail_workspace_root_abs="$test_root_abs/swarm-goal-manager-benchmark-fail-workspace"
goal_manager_benchmark_timeout_state_root_abs="$test_root_abs/swarm-goal-manager-benchmark-timeout-state"
goal_manager_benchmark_timeout_workspace_root_abs="$test_root_abs/swarm-goal-manager-benchmark-timeout-workspace"
goal_manager_benchmark_timeout_signal_state_root_abs="$test_root_abs/swarm-goal-manager-benchmark-timeout-signal-state"
goal_manager_benchmark_timeout_signal_workspace_root_abs="$test_root_abs/swarm-goal-manager-benchmark-timeout-signal-workspace"

mkdir -p "$goal_manager_workspace_root_abs"
mkdir -p "$goal_manager_native_workspace_root_abs"
mkdir -p "$goal_manager_live_workspace_root_abs"
mkdir -p "$goal_manager_resume_workspace_root_abs"
mkdir -p "$goal_manager_dirty_resume_workspace_root_abs"
mkdir -p "$goal_manager_service_restart_workspace_root_abs"
mkdir -p "$goal_manager_parallel_live_workspace_root_abs"
mkdir -p "$goal_manager_promotion_conflict_workspace_root_abs"
mkdir -p "$goal_manager_replan_workspace_root_abs"
mkdir -p "$goal_manager_benchmark_workspace_root_abs"
mkdir -p "$goal_manager_benchmark_resume_workspace_root_abs"
mkdir -p "$goal_manager_parallel_benchmark_workspace_root_abs"
mkdir -p "$goal_manager_benchmark_fail_workspace_root_abs"
mkdir -p "$goal_manager_benchmark_timeout_workspace_root_abs"
mkdir -p "$goal_manager_benchmark_timeout_signal_workspace_root_abs"

"$claspc_bin" --json check "$project_root/examples/swarm-native/GoalManager.clasp" | grep -F '"status":"ok"' >/dev/null
env RUSTC=/definitely-missing-rustc "$claspc_bin" compile "$project_root/examples/swarm-native/GoalManager.clasp" -o "$goal_manager_binary"
[[ -x "$goal_manager_binary" ]]
goal_manager_output="$(
  CLASP_LOOP_CODEX_BIN_JSON="\"$test_root_abs/codex\"" \
  CLASP_LOOP_WORKSPACE_JSON="\"$goal_manager_workspace_root_abs\"" \
  CLASP_MANAGER_CLASPC_BIN_JSON="\"$claspc_bin\"" \
  CLASP_MANAGER_GOAL_JSON='"Improve Clasp autonomously."' \
  CLASP_MANAGER_MAX_TASKS_JSON='2' \
  "$goal_manager_binary" "$goal_manager_state_root_abs"
)"
printf '%s\n' "$goal_manager_output" | grep -F '"phase":"completed"' >/dev/null
printf '%s\n' "$goal_manager_output" | grep -F '"verdict":"pass"' >/dev/null
printf '%s\n' "$goal_manager_output" | grep -F '"objectiveId":"improve-clasp"' >/dev/null
printf '%s\n' "$goal_manager_output" | grep -F '"plannerSummary":"Improve Clasp with a planner-managed task DAG."' >/dev/null
printf '%s\n' "$goal_manager_output" | grep -F '"plannedTaskIds":["stabilize-loop","tighten-verify"]' >/dev/null
printf '%s\n' "$goal_manager_output" | grep -F '"objectiveProjectedStatus":"completed"' >/dev/null
printf '%s\n' "$goal_manager_output" | grep -F '"allTaskIds":["planner","stabilize-loop","tighten-verify"]' >/dev/null
printf '%s\n' "$goal_manager_output" | grep -F '"completedTaskIds":["planner","stabilize-loop","tighten-verify"]' >/dev/null
goal_manager_workspace_stabilize_actual="$(readlink -f "$goal_manager_state_root_abs/workspace-stabilize-loop")"
goal_manager_workspace_tighten_actual="$(readlink -f "$goal_manager_state_root_abs/workspace-tighten-verify")"
[[ "$goal_manager_workspace_stabilize_actual" != "$goal_manager_state_root_abs/"* ]]
[[ "$goal_manager_workspace_tighten_actual" != "$goal_manager_state_root_abs/"* ]]
grep -Fx 'fixed-after-feedback' "$goal_manager_state_root_abs/workspace-stabilize-loop/workspace.txt" >/dev/null
grep -Fx 'fixed-after-feedback' "$goal_manager_state_root_abs/workspace-tighten-verify/workspace.txt" >/dev/null
grep -Fx 'fixed-after-feedback' "$goal_manager_workspace_root_abs/workspace.txt" >/dev/null
grep -Fx 'fixed-after-feedback' "$goal_manager_workspace_root_abs/notes/child-artifact.txt" >/dev/null
grep -F '"verdict":"pass"' "$goal_manager_feedback_path_abs" >/dev/null
grep -F '"objectiveSummary":"Improve Clasp with a planner-managed task DAG."' "$goal_manager_state_root_abs/planner-1.json" >/dev/null
grep -F '"role":"control-plane-hardener"' "$goal_manager_state_root_abs/planner-1.json" >/dev/null
grep -F '"role":"verification-closer"' "$goal_manager_state_root_abs/planner-1.json" >/dev/null
grep -F '"verdict":"pass"' "$goal_manager_state_root_abs/loop-stabilize-loop/feedback.json" >/dev/null
grep -F '"verdict":"pass"' "$goal_manager_state_root_abs/loop-tighten-verify/feedback.json" >/dev/null
grep -F 'stabilize-loop' "$goal_manager_state_root_abs/task-stabilize-loop.md" >/dev/null
grep -F 'tighten-verify' "$goal_manager_state_root_abs/task-tighten-verify.md" >/dev/null
grep -F 'Assigned role: control-plane-hardener' "$goal_manager_state_root_abs/task-stabilize-loop.md" >/dev/null
grep -F 'Sibling branches in this wave:' "$goal_manager_state_root_abs/task-stabilize-loop.md" >/dev/null
grep -F 'tighten-verify [role verification-closer;' "$goal_manager_state_root_abs/task-stabilize-loop.md" >/dev/null
grep -F '"taskId":"stabilize-loop"' "$goal_manager_state_root_abs/mailbox.json" >/dev/null
grep -F '"taskId":"tighten-verify"' "$goal_manager_state_root_abs/mailbox.json" >/dev/null
grep -F '"source":"builder-report:control-plane-hardener"' "$goal_manager_state_root_abs/mailbox.json" >/dev/null
grep -F '"source":"task-report:verification-closer"' "$goal_manager_state_root_abs/mailbox.json" >/dev/null
grep -F 'Shared swarm mailbox context:' "$goal_manager_state_root_abs/task-stabilize-loop.md" >/dev/null
grep -F '"valid":true' "$goal_manager_state_root_abs/plan-validation.json" >/dev/null
grep -Fx "$goal_manager_state_root_abs/service" "$goal_manager_state_root_abs/service-root.txt" >/dev/null
grep -Fx 'goal-manager' "$goal_manager_state_root_abs/service-id.txt" >/dev/null
CLASP_MANAGER_COMMAND=status "$goal_manager_binary" "$goal_manager_state_root_abs" >"$goal_manager_status_output_abs"
grep -F '"phase":"completed"' "$goal_manager_status_output_abs" >/dev/null
grep -F '"verdict":"pass"' "$goal_manager_status_output_abs" >/dev/null
grep -F '"plannedTaskIds":["stabilize-loop","tighten-verify"]' "$goal_manager_status_output_abs" >/dev/null
goal_manager_objective_status_output="$("$claspc_bin" --json swarm objective status "$goal_manager_state_root_abs" improve-clasp)"
printf '%s\n' "$goal_manager_objective_status_output" | grep -F '"objectiveId":"improve-clasp"' >/dev/null
printf '%s\n' "$goal_manager_objective_status_output" | grep -F '"projectedStatus":"completed"' >/dev/null
printf '%s\n' "$goal_manager_objective_status_output" | grep -F '"taskCount":3' >/dev/null
printf '%s\n' "$goal_manager_objective_status_output" | grep -F '"taskId":"planner"' >/dev/null
printf '%s\n' "$goal_manager_objective_status_output" | grep -F '"taskId":"stabilize-loop"' >/dev/null
printf '%s\n' "$goal_manager_objective_status_output" | grep -F '"taskId":"tighten-verify"' >/dev/null
goal_manager_runs_output="$("$claspc_bin" --json swarm runs "$goal_manager_state_root_abs" stabilize-loop)"
printf '%s\n' "$goal_manager_runs_output" | grep -F '"role":"tool"' >/dev/null
printf '%s\n' "$goal_manager_runs_output" | grep -F '"status":"passed"' >/dev/null
goal_manager_artifacts_output="$("$claspc_bin" --json swarm artifacts "$goal_manager_state_root_abs" stabilize-loop)"
printf '%s\n' "$goal_manager_artifacts_output" | grep -F '"kind":"stdout"' >/dev/null
printf '%s\n' "$goal_manager_artifacts_output" | grep -F '"kind":"stderr"' >/dev/null

goal_manager_budget_fail_output="$(
  CLASP_LOOP_CODEX_BIN_JSON="\"$test_root_abs/codex\"" \
  CLASP_LOOP_WORKSPACE_JSON="\"$goal_manager_workspace_root_abs\"" \
  CLASP_MANAGER_CLASPC_BIN_JSON="\"$claspc_bin\"" \
  CLASP_MANAGER_GOAL_JSON='"Improve Clasp autonomously."' \
  CLASP_MANAGER_MAX_TASKS_JSON='0' \
  "$goal_manager_binary" "$goal_manager_budget_fail_state_root_abs"
)"
printf '%s\n' "$goal_manager_budget_fail_output" | grep -F '"phase":"failed"' >/dev/null
printf '%s\n' "$goal_manager_budget_fail_output" | grep -F '"verdict":"fail"' >/dev/null
grep -F '"summary":"planner validation failed"' "$goal_manager_budget_fail_state_root_abs/feedback.json" >/dev/null
grep -F '"code":"planned-task-budget"' "$goal_manager_budget_fail_state_root_abs/plan-validation.json" >/dev/null
grep -F '"valid":false' "$goal_manager_budget_fail_state_root_abs/plan-validation.json" >/dev/null

goal_manager_reserved_dep_fail_output="$(
  CLASP_TEST_FAKE_PLANNER_MODE='reserved-dependency' \
  CLASP_LOOP_CODEX_BIN_JSON="\"$test_root_abs/codex\"" \
  CLASP_LOOP_WORKSPACE_JSON="\"$goal_manager_workspace_root_abs\"" \
  CLASP_MANAGER_CLASPC_BIN_JSON="\"$claspc_bin\"" \
  CLASP_MANAGER_GOAL_JSON='"Improve Clasp autonomously."' \
  CLASP_MANAGER_MAX_TASKS_JSON='2' \
  "$goal_manager_binary" "$goal_manager_reserved_dep_fail_state_root_abs"
)"
printf '%s\n' "$goal_manager_reserved_dep_fail_output" | grep -F '"phase":"failed"' >/dev/null
printf '%s\n' "$goal_manager_reserved_dep_fail_output" | grep -F '"verdict":"fail"' >/dev/null
printf '%s\n' "$goal_manager_reserved_dep_fail_output" | grep -F '"allTaskIds":["planner"]' >/dev/null
grep -F '"summary":"planner validation failed"' "$goal_manager_reserved_dep_fail_state_root_abs/feedback.json" >/dev/null
grep -F '"code":"reserved-dependency"' "$goal_manager_reserved_dep_fail_state_root_abs/plan-validation.json" >/dev/null
grep -F '"valid":false' "$goal_manager_reserved_dep_fail_state_root_abs/plan-validation.json" >/dev/null
if grep -F 'no ready task matched' "$goal_manager_reserved_dep_fail_state_root_abs/feedback.json" >/dev/null; then
  echo "goal manager should fail with planner validation details before ready-task fallback" >&2
  exit 1
fi

trace_case "goal-manager-native"
goal_manager_native_output="$(
  CLASP_LOOP_CODEX_BIN_JSON="\"$test_root_abs/codex\"" \
  CLASP_LOOP_WORKSPACE_JSON="\"$goal_manager_native_workspace_root_abs\"" \
  CLASP_MANAGER_CLASPC_BIN_JSON="\"$claspc_bin\"" \
  CLASP_MANAGER_GOAL_JSON='"Improve Clasp autonomously."' \
  CLASP_MANAGER_MAX_TASKS_JSON='2' \
  "$goal_manager_binary" "$goal_manager_native_state_root_abs"
)"
printf '%s\n' "$goal_manager_native_output" | grep -F '"phase":"completed"' >/dev/null
printf '%s\n' "$goal_manager_native_output" | grep -F '"verdict":"pass"' >/dev/null
printf '%s\n' "$goal_manager_native_output" | grep -F '"plannedTaskIds":["stabilize-loop","tighten-verify"]' >/dev/null
goal_manager_native_workspace_stabilize_actual="$(readlink -f "$goal_manager_native_state_root_abs/workspace-stabilize-loop")"
goal_manager_native_workspace_tighten_actual="$(readlink -f "$goal_manager_native_state_root_abs/workspace-tighten-verify")"
[[ "$goal_manager_native_workspace_stabilize_actual" != "$goal_manager_native_state_root_abs/"* ]]
[[ "$goal_manager_native_workspace_tighten_actual" != "$goal_manager_native_state_root_abs/"* ]]
grep -Fx 'fixed-after-feedback' "$goal_manager_native_state_root_abs/workspace-stabilize-loop/workspace.txt" >/dev/null
grep -Fx 'fixed-after-feedback' "$goal_manager_native_state_root_abs/workspace-tighten-verify/workspace.txt" >/dev/null
grep -Fx 'fixed-after-feedback' "$goal_manager_native_workspace_root_abs/workspace.txt" >/dev/null
grep -Fx 'fixed-after-feedback' "$goal_manager_native_workspace_root_abs/notes/child-artifact.txt" >/dev/null
grep -F '"verdict":"pass"' "$goal_manager_native_state_root_abs/loop-stabilize-loop/feedback.json" >/dev/null
grep -F '"verdict":"pass"' "$goal_manager_native_state_root_abs/loop-tighten-verify/feedback.json" >/dev/null
grep -F '"valid":true' "$goal_manager_native_state_root_abs/plan-validation.json" >/dev/null
CLASP_MANAGER_COMMAND=status "$goal_manager_binary" "$goal_manager_native_state_root_abs" >"$goal_manager_status_output_abs.native"
grep -F '"phase":"completed"' "$goal_manager_status_output_abs.native" >/dev/null
grep -F '"verdict":"pass"' "$goal_manager_status_output_abs.native" >/dev/null

goal_manager_upgrade_state_root_abs="$test_root_abs/swarm-goal-manager-upgrade-state"
goal_manager_upgrade_workspace_root_abs="$test_root_abs/swarm-goal-manager-upgrade-workspace"
goal_manager_upgrade_ready_path_abs="$goal_manager_upgrade_state_root_abs/manager.ready"
goal_manager_upgrade_service_root_abs="$test_root_abs/swarm-goal-manager-upgrade-service"
goal_manager_upgrade_restored_path_abs="$goal_manager_upgrade_state_root_abs/restored-snapshot.json"
goal_manager_upgrade_service_status_output_abs="$test_root_abs/swarm-goal-manager-upgrade-service-status.json"
mkdir -p "$goal_manager_upgrade_workspace_root_abs"
trace_case "goal-manager-upgrade"
goal_manager_upgrade_command_json="$(
  node -e 'console.log(JSON.stringify(process.argv.slice(1)))' \
    env \
    CLASP_MANAGER_COMMAND=run \
    "CLASP_LOOP_CODEX_BIN_JSON=\"$test_root_abs/codex\"" \
    "CLASP_LOOP_WORKSPACE_JSON=\"$goal_manager_upgrade_workspace_root_abs\"" \
    "CLASP_MANAGER_CLASPC_BIN_JSON=\"$claspc_bin\"" \
    "CLASP_MANAGER_GOAL_JSON=\"Improve Clasp autonomously.\"" \
    CLASP_MANAGER_MAX_TASKS_JSON=2 \
    CLASP_LOOP_WATCH_POLL_MS_JSON=50 \
    "CLASP_MANAGER_READY_PATH_JSON=\"$goal_manager_upgrade_ready_path_abs\"" \
    "$goal_manager_binary" \
    "$goal_manager_upgrade_state_root_abs"
)"
goal_manager_upgrade_output="$(
  CLASP_MANAGER_COMMAND=upgrade \
  CLASP_LOOP_WORKSPACE_JSON="\"$goal_manager_upgrade_workspace_root_abs\"" \
  CLASP_LOOP_WATCH_POLL_MS_JSON='50' \
  CLASP_MANAGER_SERVICE_ROOT_JSON="\"$goal_manager_upgrade_service_root_abs\"" \
  CLASP_MANAGER_SERVICE_ID_JSON='"goal-manager-service"' \
  CLASP_MANAGER_UPGRADE_READY_PATH_JSON="\"$goal_manager_upgrade_ready_path_abs\"" \
  CLASP_MANAGER_UPGRADE_READY_CONTAINS_JSON='"ready"' \
  CLASP_MANAGER_UPGRADE_READY_TIMEOUT_MS_JSON='5000' \
  CLASP_MANAGER_UPGRADE_COMMIT_GRACE_MS_JSON='100' \
  CLASP_MANAGER_UPGRADE_COMMAND_JSON="$goal_manager_upgrade_command_json" \
  "$goal_manager_binary" "$goal_manager_upgrade_state_root_abs"
)"
printf '%s\n' "$goal_manager_upgrade_output" | grep -F '"phase":"committed"' >/dev/null
printf '%s\n' "$goal_manager_upgrade_output" | grep -F '"committed":true' >/dev/null
for _ in $(seq 1 2400); do
  if [[ -f "$goal_manager_upgrade_service_root_abs/service.json" ]] \
    && grep -F '"status":"completed"' "$goal_manager_upgrade_service_root_abs/service.json" >/dev/null 2>&1 \
    && [[ -f "$goal_manager_upgrade_state_root_abs/feedback.json" ]] \
    && grep -F '"verdict":"pass"' "$goal_manager_upgrade_state_root_abs/feedback.json" >/dev/null 2>&1 \
    && [[ -f "$goal_manager_upgrade_restored_path_abs" ]]; then
    break
  fi
  sleep 0.05
done
wait_for_path_contains "$goal_manager_upgrade_state_root_abs/feedback.json" '"verdict":"pass"'
wait_for_path_contains "$goal_manager_upgrade_service_root_abs/service.json" '"serviceId":"goal-manager-service"'
wait_for_path_contains "$goal_manager_upgrade_service_root_abs/service.json" '"status":"completed"'
wait_for_path_contains "$goal_manager_upgrade_service_root_abs/service.json" '"generation":1'
wait_for_path_contains "$goal_manager_upgrade_restored_path_abs" '"serviceRoot":"'"$goal_manager_upgrade_service_root_abs"'"'
wait_for_path_contains "$goal_manager_upgrade_restored_path_abs" '"serviceId":"goal-manager-service"'
wait_for_path_contains "$goal_manager_upgrade_restored_path_abs" '"generation":1'
grep -F '"serviceId":"goal-manager-service"' "$goal_manager_upgrade_service_root_abs/service.json" >/dev/null
grep -F '"status":"completed"' "$goal_manager_upgrade_service_root_abs/service.json" >/dev/null
grep -F '"generation":1' "$goal_manager_upgrade_service_root_abs/service.json" >/dev/null
grep -F '"verdict":"pass"' "$goal_manager_upgrade_state_root_abs/feedback.json" >/dev/null
grep -F '"serviceRoot":"'"$goal_manager_upgrade_service_root_abs"'"' "$goal_manager_upgrade_restored_path_abs" >/dev/null
grep -F '"serviceId":"goal-manager-service"' "$goal_manager_upgrade_restored_path_abs" >/dev/null
grep -F '"generation":1' "$goal_manager_upgrade_restored_path_abs" >/dev/null
CLASP_MANAGER_COMMAND=service-status "$goal_manager_binary" "$goal_manager_upgrade_state_root_abs" >"$goal_manager_upgrade_service_status_output_abs"
wait_for_path_contains "$goal_manager_upgrade_service_status_output_abs" '"serviceId":"goal-manager-service"'
wait_for_path_contains "$goal_manager_upgrade_service_status_output_abs" '"status":"completed"'
grep -F '"serviceId":"goal-manager-service"' "$goal_manager_upgrade_service_status_output_abs" >/dev/null
grep -F '"status":"completed"' "$goal_manager_upgrade_service_status_output_abs" >/dev/null

goal_manager_live_builder_heartbeat_abs="$goal_manager_live_state_root_abs/loop-stabilize-loop/builder-1.heartbeat.json"
goal_manager_live_child_state_abs="$goal_manager_live_state_root_abs/loop-stabilize-loop/state.json"
trace_case "goal-manager-live"
CLASP_TEST_FAKE_CODEX_SLEEP_SECS='1' \
CLASP_LOOP_CODEX_BIN_JSON="\"$test_root_abs/codex\"" \
CLASP_LOOP_WORKSPACE_JSON="\"$goal_manager_live_workspace_root_abs\"" \
CLASP_MANAGER_CLASPC_BIN_JSON="\"$claspc_bin\"" \
CLASP_MANAGER_GOAL_JSON='"Improve Clasp autonomously."' \
CLASP_MANAGER_MAX_TASKS_JSON='2' \
CLASP_LOOP_WATCH_POLL_MS_JSON='50' \
  "$goal_manager_binary" "$goal_manager_live_state_root_abs" >"$goal_manager_live_output_abs" 2>&1 &
goal_manager_live_pid=$!
for _ in $(seq 1 300); do
  if [[ -f "$goal_manager_live_builder_heartbeat_abs" && -f "$goal_manager_live_child_state_abs" ]]; then
    break
  fi
  if ! kill -0 "$goal_manager_live_pid" >/dev/null 2>&1; then
    break
  fi
  sleep 0.05
done
kill -0 "$goal_manager_live_pid" >/dev/null 2>&1
wait_for_path_contains "$goal_manager_live_builder_heartbeat_abs" '"running":true' "$goal_manager_live_pid" 2400
wait_for_path_contains "$goal_manager_live_child_state_abs" '"phase":"builder-running"' "$goal_manager_live_pid" 2400
for _ in $(seq 1 300); do
  if [[ -f "$goal_manager_live_state_status_abs" ]] \
    && grep -F '"phase":"task-running"' "$goal_manager_live_state_status_abs" >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "$goal_manager_live_pid" >/dev/null 2>&1; then
    break
  fi
  sleep 0.05
done
CLASP_MANAGER_COMMAND=status "$goal_manager_binary" "$goal_manager_live_state_root_abs" >"$goal_manager_live_status_output_abs"
grep -F '"phase":"task-running"' "$goal_manager_live_status_output_abs" >/dev/null
grep -F '"activeTaskId":"stabilize-loop"' "$goal_manager_live_status_output_abs" >/dev/null
wait "$goal_manager_live_pid"
goal_manager_live_pid=""
grep -F '"phase":"completed"' "$goal_manager_live_output_abs" >/dev/null
grep -F '"verdict":"pass"' "$goal_manager_live_output_abs" >/dev/null
grep -F '"verdict":"pass"' "$goal_manager_live_state_root_abs/feedback.json" >/dev/null

goal_manager_resume_builder_heartbeat_abs="$goal_manager_resume_state_root_abs/loop-stabilize-loop/builder-1.heartbeat.json"
goal_manager_resume_child_state_abs="$goal_manager_resume_state_root_abs/loop-stabilize-loop/state.json"
trace_case "goal-manager-resume"
CLASP_TEST_FAKE_CODEX_SLEEP_SECS='1' \
CLASP_LOOP_CODEX_BIN_JSON="\"$test_root_abs/codex\"" \
CLASP_LOOP_WORKSPACE_JSON="\"$goal_manager_resume_workspace_root_abs\"" \
CLASP_MANAGER_CLASPC_BIN_JSON="\"$claspc_bin\"" \
CLASP_MANAGER_GOAL_JSON='"Improve Clasp autonomously."' \
CLASP_MANAGER_MAX_TASKS_JSON='2' \
CLASP_LOOP_WATCH_POLL_MS_JSON='50' \
  "$goal_manager_binary" "$goal_manager_resume_state_root_abs" >"$goal_manager_resume_output_abs.first" 2>&1 &
goal_manager_live_pid=$!
for _ in $(seq 1 300); do
  if [[ -f "$goal_manager_resume_builder_heartbeat_abs" && -f "$goal_manager_resume_child_state_abs" ]]; then
    break
  fi
  if ! kill -0 "$goal_manager_live_pid" >/dev/null 2>&1; then
    break
  fi
  sleep 0.05
done
kill -0 "$goal_manager_live_pid" >/dev/null 2>&1
wait_for_path_contains "$goal_manager_resume_builder_heartbeat_abs" '"running":true' "$goal_manager_live_pid" 2400
wait_for_path_contains "$goal_manager_resume_child_state_abs" '"phase":"builder-running"' "$goal_manager_live_pid" 2400
CLASP_MANAGER_COMMAND=status "$goal_manager_binary" "$goal_manager_resume_state_root_abs" >"$goal_manager_resume_status_output_abs"
grep -F '"phase":"task-running"' "$goal_manager_resume_status_output_abs" >/dev/null
stop_goal_manager_service "$goal_manager_resume_state_root_abs"
wait_or_kill_pid "$goal_manager_live_pid" 100
goal_manager_live_pid=""
goal_manager_resume_output="$(
  CLASP_LOOP_CODEX_BIN_JSON="\"$test_root_abs/codex\"" \
  CLASP_LOOP_WORKSPACE_JSON="\"$goal_manager_resume_workspace_root_abs\"" \
  CLASP_MANAGER_CLASPC_BIN_JSON="\"$claspc_bin\"" \
  CLASP_MANAGER_GOAL_JSON='"Improve Clasp autonomously."' \
  CLASP_MANAGER_MAX_TASKS_JSON='2' \
  CLASP_LOOP_WATCH_POLL_MS_JSON='50' \
  "$goal_manager_binary" "$goal_manager_resume_state_root_abs"
)"
printf '%s\n' "$goal_manager_resume_output" | grep -F '"phase":"completed"' >/dev/null
printf '%s\n' "$goal_manager_resume_output" | grep -F '"verdict":"pass"' >/dev/null
grep -F '"verdict":"pass"' "$goal_manager_resume_state_root_abs/feedback.json" >/dev/null

goal_manager_service_restart_builder_heartbeat_abs="$goal_manager_service_restart_state_root_abs/loop-stabilize-loop/builder-1.heartbeat.json"
goal_manager_service_restart_child_state_abs="$goal_manager_service_restart_state_root_abs/loop-stabilize-loop/state.json"
goal_manager_service_restart_supervisor_config_abs="$goal_manager_service_restart_state_root_abs/service/supervisor.config.json"
trace_case "goal-manager-service-restart"
CLASP_TEST_FAKE_PLANNER_MODE='parallel-ready' \
CLASP_TEST_FAKE_CODEX_SLEEP_SECS='5' \
CLASP_LOOP_CODEX_BIN_JSON="\"$test_root_abs/codex\"" \
CLASP_LOOP_WORKSPACE_JSON="\"$goal_manager_service_restart_workspace_root_abs\"" \
CLASP_MANAGER_CLASPC_BIN_JSON="\"$claspc_bin\"" \
CLASP_MANAGER_GOAL_JSON='"Improve Clasp autonomously."' \
CLASP_MANAGER_MAX_TASKS_JSON='2' \
CLASP_MANAGER_MAX_CONCURRENT_CHILDREN_JSON='2' \
CLASP_LOOP_WATCH_POLL_MS_JSON='50' \
  "$goal_manager_binary" "$goal_manager_service_restart_state_root_abs" >"$goal_manager_service_restart_output_abs" 2>&1 &
goal_manager_live_pid=$!
for _ in $(seq 1 2400); do
  if [[ -f "$goal_manager_service_restart_builder_heartbeat_abs" && -f "$goal_manager_service_restart_child_state_abs" ]]; then
    break
  fi
  if ! kill -0 "$goal_manager_live_pid" >/dev/null 2>&1; then
    break
  fi
  sleep 0.05
done
kill -0 "$goal_manager_live_pid" >/dev/null 2>&1
wait_for_path_contains "$goal_manager_service_restart_builder_heartbeat_abs" '"running":true' "$goal_manager_live_pid" 2400
wait_for_path_contains "$goal_manager_service_restart_child_state_abs" '"phase":"builder-running"' "$goal_manager_live_pid" 2400
wait_for_path_contains "$goal_manager_service_restart_supervisor_config_abs" '"serviceId":"goal-manager"' "$goal_manager_live_pid"
if grep -F '"examples/swarm-native/GoalManager.clasp"' "$goal_manager_service_restart_supervisor_config_abs" >/dev/null 2>&1; then
  echo "expected goal manager supervisor to re-exec the backend binary instead of recursive source-run" >&2
  exit 1
fi
CLASP_MANAGER_COMMAND=service-status "$goal_manager_binary" "$goal_manager_service_restart_state_root_abs" >"$goal_manager_service_restart_service_output_abs"
grep -F '"status":"active"' "$goal_manager_service_restart_service_output_abs" >/dev/null
old_owner_pid="$(grep -o '"ownerPid":[0-9-]*' "$goal_manager_service_restart_service_output_abs" | head -n 1 | cut -d: -f2)"
[[ -n "$old_owner_pid" ]]
[[ "$old_owner_pid" -gt 0 ]]
kill "$old_owner_pid" >/dev/null 2>&1 || true
new_owner_pid=""
for _ in $(seq 1 400); do
  CLASP_MANAGER_COMMAND=service-status "$goal_manager_binary" "$goal_manager_service_restart_state_root_abs" >"$goal_manager_service_restart_service_output_abs"
  if grep -F '"status":"active"' "$goal_manager_service_restart_service_output_abs" >/dev/null 2>&1; then
    candidate_owner_pid="$(grep -o '"ownerPid":[0-9-]*' "$goal_manager_service_restart_service_output_abs" | head -n 1 | cut -d: -f2)"
    if [[ -n "$candidate_owner_pid" && "$candidate_owner_pid" -gt 0 && "$candidate_owner_pid" != "$old_owner_pid" ]]; then
      new_owner_pid="$candidate_owner_pid"
      break
    fi
  fi
  if ! kill -0 "$goal_manager_live_pid" >/dev/null 2>&1; then
    break
  fi
  sleep 0.05
done
[[ -n "$new_owner_pid" ]]
[[ "$new_owner_pid" -gt 0 ]]
wait "$goal_manager_live_pid"
goal_manager_live_pid=""
grep -F '"phase":"completed"' "$goal_manager_service_restart_output_abs" >/dev/null
grep -F '"verdict":"pass"' "$goal_manager_service_restart_output_abs" >/dev/null
grep -F '"verdict":"pass"' "$goal_manager_service_restart_state_root_abs/feedback.json" >/dev/null
CLASP_MANAGER_COMMAND=service-status "$goal_manager_binary" "$goal_manager_service_restart_state_root_abs" >"$goal_manager_service_restart_service_output_abs"
grep -F '"status":"completed"' "$goal_manager_service_restart_service_output_abs" >/dev/null

goal_manager_dirty_resume_builder_heartbeat_abs="$goal_manager_dirty_resume_state_root_abs/loop-stabilize-loop/builder-1.heartbeat.json"
goal_manager_dirty_resume_child_state_abs="$goal_manager_dirty_resume_state_root_abs/loop-stabilize-loop/state.json"
trace_case "goal-manager-dirty-service-resume"
CLASP_TEST_FAKE_PLANNER_MODE='parallel-ready' \
CLASP_TEST_FAKE_CODEX_SLEEP_SECS='5' \
CLASP_LOOP_CODEX_BIN_JSON="\"$test_root_abs/codex\"" \
CLASP_LOOP_WORKSPACE_JSON="\"$goal_manager_dirty_resume_workspace_root_abs\"" \
CLASP_MANAGER_CLASPC_BIN_JSON="\"$claspc_bin\"" \
CLASP_MANAGER_GOAL_JSON='"Improve Clasp autonomously."' \
CLASP_MANAGER_MAX_TASKS_JSON='2' \
CLASP_LOOP_WATCH_POLL_MS_JSON='50' \
  "$goal_manager_binary" "$goal_manager_dirty_resume_state_root_abs" >"$goal_manager_dirty_resume_output_abs.first" 2>&1 &
goal_manager_live_pid=$!
for _ in $(seq 1 300); do
  if [[ -f "$goal_manager_dirty_resume_builder_heartbeat_abs" && -f "$goal_manager_dirty_resume_child_state_abs" ]]; then
    break
  fi
  if ! kill -0 "$goal_manager_live_pid" >/dev/null 2>&1; then
    break
  fi
  sleep 0.05
done
kill -0 "$goal_manager_live_pid" >/dev/null 2>&1
wait_for_path_contains "$goal_manager_dirty_resume_builder_heartbeat_abs" '"running":true' "$goal_manager_live_pid" 2400
wait_for_path_contains "$goal_manager_dirty_resume_child_state_abs" '"phase":"builder-running"' "$goal_manager_live_pid" 2400
for _ in $(seq 1 300); do
  if [[ -f "$goal_manager_dirty_resume_state_status_abs" ]] \
    && grep -F '"phase":"task-running"' "$goal_manager_dirty_resume_state_status_abs" >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "$goal_manager_live_pid" >/dev/null 2>&1; then
    break
  fi
  sleep 0.05
done
CLASP_MANAGER_COMMAND=service-status "$goal_manager_binary" "$goal_manager_dirty_resume_state_root_abs" >"$goal_manager_dirty_resume_service_output_abs"
grep -F '"status":"active"' "$goal_manager_dirty_resume_service_output_abs" >/dev/null
old_dirty_owner_pid="$(grep -o '"ownerPid":[0-9-]*' "$goal_manager_dirty_resume_service_output_abs" | head -n 1 | cut -d: -f2)"
old_dirty_supervisor_pid="$(service_supervisor_pid_for "$goal_manager_dirty_resume_state_root_abs" | head -1)"
[[ -n "$old_dirty_owner_pid" ]]
[[ "$old_dirty_owner_pid" -gt 0 ]]
[[ -n "$old_dirty_supervisor_pid" ]]
[[ "$old_dirty_supervisor_pid" -gt 0 ]]
mapfile -t dirty_resume_descendant_pids < <(pgrep -f "$goal_manager_dirty_resume_state_root_abs" 2>/dev/null || true)
if [[ ${#dirty_resume_descendant_pids[@]} -gt 0 ]]; then
  kill "${dirty_resume_descendant_pids[@]}" >/dev/null 2>&1 || true
  sleep 0.1
  kill -9 "${dirty_resume_descendant_pids[@]}" >/dev/null 2>&1 || true
fi
wait_or_kill_pid "$goal_manager_live_pid" 100
goal_manager_live_pid=""
[[ -f "$goal_manager_dirty_resume_state_root_abs/service/service.json" ]]
[[ -f "$goal_manager_dirty_resume_state_root_abs/service/supervisor.lock" ]]
CLASP_MANAGER_COMMAND=service-status "$goal_manager_binary" "$goal_manager_dirty_resume_state_root_abs" >"$goal_manager_dirty_resume_service_output_abs"
grep -F '"status":"failed"' "$goal_manager_dirty_resume_service_output_abs" >/dev/null
goal_manager_dirty_resume_output="$(
  CLASP_TEST_FAKE_PLANNER_MODE='parallel-ready' \
  CLASP_TEST_FAKE_CODEX_SLEEP_SECS='5' \
  CLASP_LOOP_CODEX_BIN_JSON="\"$test_root_abs/codex\"" \
  CLASP_LOOP_WORKSPACE_JSON="\"$goal_manager_dirty_resume_workspace_root_abs\"" \
  CLASP_MANAGER_CLASPC_BIN_JSON="\"$claspc_bin\"" \
  CLASP_MANAGER_GOAL_JSON='"Improve Clasp autonomously."' \
  CLASP_MANAGER_MAX_TASKS_JSON='2' \
  CLASP_LOOP_WATCH_POLL_MS_JSON='50' \
  "$goal_manager_binary" "$goal_manager_dirty_resume_state_root_abs"
)"
printf '%s\n' "$goal_manager_dirty_resume_output" >"$goal_manager_dirty_resume_output_abs.second"
grep -F '"phase":"completed"' "$goal_manager_dirty_resume_output_abs.second" >/dev/null
grep -F '"verdict":"pass"' "$goal_manager_dirty_resume_output_abs.second" >/dev/null
grep -F '"verdict":"pass"' "$goal_manager_dirty_resume_state_root_abs/feedback.json" >/dev/null
grep -F 'service-resume:start' "$goal_manager_dirty_resume_state_root_abs/trace.log" >/dev/null
grep -F 'resume-manager:phase=task-running' "$goal_manager_dirty_resume_state_root_abs/trace.log" >/dev/null
CLASP_MANAGER_COMMAND=service-status "$goal_manager_binary" "$goal_manager_dirty_resume_state_root_abs" >"$goal_manager_dirty_resume_service_output_abs"
grep -F '"status":"completed"' "$goal_manager_dirty_resume_service_output_abs" >/dev/null

goal_manager_parallel_live_stabilize_heartbeat_abs="$goal_manager_parallel_live_state_root_abs/loop-stabilize-loop/builder-1.heartbeat.json"
goal_manager_parallel_live_tighten_heartbeat_abs="$goal_manager_parallel_live_state_root_abs/loop-tighten-verify/builder-1.heartbeat.json"
goal_manager_parallel_live_stabilize_state_abs="$goal_manager_parallel_live_state_root_abs/loop-stabilize-loop/state.json"
goal_manager_parallel_live_tighten_state_abs="$goal_manager_parallel_live_state_root_abs/loop-tighten-verify/state.json"
trace_case "goal-manager-parallel-live"
CLASP_TEST_FAKE_PLANNER_MODE='parallel-ready' \
CLASP_TEST_FAKE_CODEX_SLEEP_SECS='1' \
CLASP_LOOP_CODEX_BIN_JSON="\"$test_root_abs/codex\"" \
CLASP_LOOP_WORKSPACE_JSON="\"$goal_manager_parallel_live_workspace_root_abs\"" \
CLASP_MANAGER_CLASPC_BIN_JSON="\"$claspc_bin\"" \
CLASP_MANAGER_GOAL_JSON='"Improve Clasp with parallel bounded branches."' \
CLASP_MANAGER_MAX_TASKS_JSON='2' \
CLASP_MANAGER_MAX_CONCURRENT_CHILDREN_JSON='2' \
CLASP_LOOP_WATCH_POLL_MS_JSON='50' \
  "$goal_manager_binary" "$goal_manager_parallel_live_state_root_abs" >"$goal_manager_parallel_live_output_abs" 2>&1 &
goal_manager_parallel_live_pid=$!
for _ in $(seq 1 300); do
  if [[ -f "$goal_manager_parallel_live_stabilize_heartbeat_abs" && -f "$goal_manager_parallel_live_tighten_heartbeat_abs" && -f "$goal_manager_parallel_live_stabilize_state_abs" && -f "$goal_manager_parallel_live_tighten_state_abs" ]]; then
    break
  fi
  if ! kill -0 "$goal_manager_parallel_live_pid" >/dev/null 2>&1; then
    break
  fi
  sleep 0.05
done
kill -0 "$goal_manager_parallel_live_pid" >/dev/null 2>&1
wait_for_path_contains "$goal_manager_parallel_live_stabilize_heartbeat_abs" '"running":true' "$goal_manager_parallel_live_pid" 2400
wait_for_path_contains "$goal_manager_parallel_live_tighten_heartbeat_abs" '"running":true' "$goal_manager_parallel_live_pid" 2400
for _ in $(seq 1 300); do
  if [[ -f "$goal_manager_parallel_live_state_status_abs" ]] \
    && grep -F '"phase":"task-running"' "$goal_manager_parallel_live_state_status_abs" >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "$goal_manager_parallel_live_pid" >/dev/null 2>&1; then
    break
  fi
  sleep 0.05
done
CLASP_MANAGER_COMMAND=status "$goal_manager_binary" "$goal_manager_parallel_live_state_root_abs" >"$goal_manager_parallel_live_status_output_abs"
grep -F '"phase":"task-running"' "$goal_manager_parallel_live_status_output_abs" >/dev/null
grep -F '"activeTaskIds":["stabilize-loop","tighten-verify"]' "$goal_manager_parallel_live_status_output_abs" >/dev/null
wait "$goal_manager_parallel_live_pid"
goal_manager_parallel_live_pid=""
grep -F '"phase":"completed"' "$goal_manager_parallel_live_output_abs" >/dev/null
grep -F '"verdict":"pass"' "$goal_manager_parallel_live_output_abs" >/dev/null

goal_manager_promotion_conflict_output="$(
  trace_case "goal-manager-promotion-conflict"
  CLASP_TEST_FAKE_PLANNER_MODE='parallel-ready' \
  CLASP_TEST_FAKE_PROMOTION_CONFLICT='1' \
  CLASP_LOOP_CODEX_BIN_JSON="\"$test_root_abs/codex\"" \
  CLASP_LOOP_WORKSPACE_JSON="\"$goal_manager_promotion_conflict_workspace_root_abs\"" \
  CLASP_MANAGER_CLASPC_BIN_JSON="\"$claspc_bin\"" \
  CLASP_MANAGER_GOAL_JSON='"Improve Clasp with conflicting parallel branches."' \
  CLASP_MANAGER_MAX_TASKS_JSON='2' \
  CLASP_MANAGER_MAX_CONCURRENT_CHILDREN_JSON='2' \
  CLASP_LOOP_WATCH_POLL_MS_JSON='50' \
  "$goal_manager_binary" "$goal_manager_promotion_conflict_state_root_abs"
)"
printf '%s\n' "$goal_manager_promotion_conflict_output" | grep -F '"phase":"failed"' >/dev/null
printf '%s\n' "$goal_manager_promotion_conflict_output" | grep -F '"verdict":"fail"' >/dev/null
grep -F '"summary":"one or more planned tasks failed"' "$goal_manager_promotion_conflict_state_root_abs/feedback.json" >/dev/null
grep -R -F '"summary":"task promotion failed"' "$goal_manager_promotion_conflict_state_root_abs"/loop-*/feedback.json >/dev/null
grep -R -F 'promotion conflict: task workspace would overwrite files changed since snapshot' "$goal_manager_promotion_conflict_state_root_abs"/loop-*/feedback.json >/dev/null
grep -R -F 'recoverableDiffKind=promotion-workspace' "$goal_manager_promotion_conflict_state_root_abs"/loop-*/feedback.json >/dev/null
goal_manager_promotion_recoverable_diff="$(
  grep -Roh 'recoverableDiff=[^"]*' "$goal_manager_promotion_conflict_state_root_abs"/loop-*/feedback.json | head -1 | cut -d= -f2-
)"
test -f "$goal_manager_promotion_recoverable_diff"
grep -F 'fixed-after-feedback' "$goal_manager_promotion_recoverable_diff" >/dev/null
if grep -F '"summary":"planned task reconciliation failed"' "$goal_manager_promotion_conflict_state_root_abs/feedback.json" >/dev/null 2>&1; then
  echo "promotion conflicts should be task-level recoverable failures, not manager reconciliation failures" >&2
  exit 1
fi

goal_manager_cycle_fail_output="$(
  trace_case "goal-manager-cycle-fail"
  CLASP_TEST_FAKE_PLANNER_MODE='cycle' \
  CLASP_LOOP_CODEX_BIN_JSON="\"$test_root_abs/codex\"" \
  CLASP_LOOP_WORKSPACE_JSON="\"$goal_manager_native_workspace_root_abs\"" \
  CLASP_MANAGER_CLASPC_BIN_JSON="\"$claspc_bin\"" \
  CLASP_MANAGER_GOAL_JSON='"Improve Clasp autonomously."' \
  CLASP_MANAGER_MAX_TASKS_JSON='2' \
  "$goal_manager_binary" "$goal_manager_cycle_fail_state_root_abs"
)"
printf '%s\n' "$goal_manager_cycle_fail_output" | grep -F '"phase":"failed"' >/dev/null
printf '%s\n' "$goal_manager_cycle_fail_output" | grep -F '"verdict":"fail"' >/dev/null
grep -F '"summary":"planner validation failed"' "$goal_manager_cycle_fail_state_root_abs/feedback.json" >/dev/null
grep -F '"code":"dependency-cycle"' "$goal_manager_cycle_fail_state_root_abs/plan-validation.json" >/dev/null
grep -F '"valid":false' "$goal_manager_cycle_fail_state_root_abs/plan-validation.json" >/dev/null

mkdir -p "$goal_manager_replan_state_root_abs"
cat >"$goal_manager_replan_state_root_abs/planner-1.json" <<'JSON'
{"objectiveSummary":"Stale planner report should be ignored.","strategy":"This planner report is stale and should not be reused.","tasks":[{"taskId":"stale-task","detail":"Do not run this stale task.","dependencies":[],"taskPrompt":"This stale task should never be materialized."}],"testsRun":["stale-plan"],"residualRisks":[]}
JSON
cat >"$goal_manager_replan_state_root_abs/planner-input.json" <<'JSON'
{"fingerprint":"stale-fingerprint","goalText":"Old goal","plannerPolicy":"Old planner policy","schemaPath":"old.schema.json","workspaceRoot":"old-workspace"}
JSON

goal_manager_replan_output="$(
  trace_case "goal-manager-replan"
  CLASP_TEST_FAKE_PLANNER_MODE='replan' \
  CLASP_LOOP_CODEX_BIN_JSON="\"$test_root_abs/codex\"" \
  CLASP_LOOP_WORKSPACE_JSON="\"$goal_manager_replan_workspace_root_abs\"" \
  CLASP_MANAGER_CLASPC_BIN_JSON="\"$claspc_bin\"" \
  CLASP_MANAGER_GOAL_JSON='"Improve Clasp autonomously."' \
  CLASP_MANAGER_MAX_TASKS_JSON='2' \
  CLASP_MANAGER_PLANNER_POLICY_JSON='"Prefer replanning when planner inputs change."' \
  "$goal_manager_binary" "$goal_manager_replan_state_root_abs"
)"
printf '%s\n' "$goal_manager_replan_output" | grep -F '"phase":"completed"' >/dev/null
printf '%s\n' "$goal_manager_replan_output" | grep -F '"verdict":"pass"' >/dev/null
printf '%s\n' "$goal_manager_replan_output" | grep -F '"plannerSummary":"Improve Clasp with a replanned task DAG."' >/dev/null
printf '%s\n' "$goal_manager_replan_output" | grep -F '"plannedTaskIds":["refresh-plan","close-gap"]' >/dev/null
grep -Fx 'fixed-after-feedback' "$goal_manager_replan_state_root_abs/workspace-refresh-plan/workspace.txt" >/dev/null
grep -Fx 'fixed-after-feedback' "$goal_manager_replan_state_root_abs/workspace-close-gap/workspace.txt" >/dev/null
grep -F '"objectiveSummary":"Improve Clasp with a replanned task DAG."' "$goal_manager_replan_state_root_abs/planner-1.json" >/dev/null
grep -F '"taskId":"refresh-plan"' "$goal_manager_replan_state_root_abs/planner-1.json" >/dev/null
grep -F '"plannerPolicy":"Prefer replanning when planner inputs change."' "$goal_manager_replan_state_root_abs/planner-input.json" >/dev/null
grep -F '"mailboxSummary":"' "$goal_manager_replan_state_root_abs/planner-input.json" >/dev/null
if grep -F '"fingerprint":"stale-fingerprint"' "$goal_manager_replan_state_root_abs/planner-input.json" >/dev/null; then
  echo "goal manager should refresh planner input fingerprints after replanning" >&2
  exit 1
fi
grep -F '"valid":true' "$goal_manager_replan_state_root_abs/plan-validation.json" >/dev/null

goal_manager_benchmark_output="$(
  trace_case "goal-manager-benchmark"
  CLASP_TEST_FAKE_PLANNER_MODE='benchmark-replan' \
  CLASP_TEST_FAKE_BENCHMARK_MODE='replan-pass' \
  CLASP_LOOP_CODEX_BIN_JSON="\"$test_root_abs/codex\"" \
  CLASP_LOOP_WORKSPACE_JSON="\"$goal_manager_benchmark_workspace_root_abs\"" \
  CLASP_MANAGER_CLASPC_BIN_JSON="\"$claspc_bin\"" \
  CLASP_MANAGER_GOAL_JSON='"Beat the AppBench target for Clasp."' \
  CLASP_MANAGER_MAX_TASKS_JSON='1' \
  CLASP_MANAGER_MAX_WAVES_JSON='2' \
  CLASP_MANAGER_BENCHMARK_COMMAND_JSON="[\"$feedback_loop_benchmark_bin\"]" \
  "$goal_manager_binary" "$goal_manager_benchmark_state_root_abs"
)"
printf '%s\n' "$goal_manager_benchmark_output" | grep -F '"phase":"completed"' >/dev/null
printf '%s\n' "$goal_manager_benchmark_output" | grep -F '"verdict":"pass"' >/dev/null
printf '%s\n' "$goal_manager_benchmark_output" | grep -F '"plannedTaskIds":["wave-2-benchmark-finish"]' >/dev/null
printf '%s\n' "$goal_manager_benchmark_output" | grep -F '"benchmarkSummary":"AppBench target met after wave 2."' >/dev/null
printf '%s\n' "$goal_manager_benchmark_output" | grep -F '"benchmarkTargetMet":true' >/dev/null
grep -Fx 'fixed-after-feedback' "$goal_manager_benchmark_state_root_abs/workspace-benchmark-gap/workspace.txt" >/dev/null
grep -Fx 'fixed-after-feedback' "$goal_manager_benchmark_state_root_abs/workspace-wave-2-benchmark-finish/workspace.txt" >/dev/null
grep -F '"summary":"AppBench target still unmet after wave 1."' "$goal_manager_benchmark_state_root_abs/benchmark-1.json" >/dev/null
grep -F '"meetsTarget":false' "$goal_manager_benchmark_state_root_abs/benchmark-1.json" >/dev/null
grep -F '"summary":"AppBench target met after wave 2."' "$goal_manager_benchmark_state_root_abs/benchmark-2.json" >/dev/null
grep -F '"meetsTarget":true' "$goal_manager_benchmark_state_root_abs/benchmark-2.json" >/dev/null
grep -F '"source":"benchmark"' "$goal_manager_benchmark_state_root_abs/mailbox.json" >/dev/null
grep -F 'AppBench target still unmet after wave 1.' "$goal_manager_benchmark_state_root_abs/mailbox.json" >/dev/null
grep -F '"source":"builder-report:benchmark-operator"' "$goal_manager_benchmark_state_root_abs/mailbox.json" >/dev/null
grep -F '"source":"builder-report:benchmark-closer"' "$goal_manager_benchmark_state_root_abs/mailbox.json" >/dev/null
grep -F 'coordination=score-improvement, checkpoint-reuse' "$goal_manager_benchmark_state_root_abs/mailbox.json" >/dev/null
grep -F '"objectiveSummary":"Finish the remaining AppBench closure wave."' "$goal_manager_benchmark_state_root_abs/planner-2.json" >/dev/null
grep -F '"verdict":"pass"' "$goal_manager_benchmark_state_root_abs/loop-benchmark-gap/feedback.json" >/dev/null
grep -F '"verdict":"pass"' "$goal_manager_benchmark_state_root_abs/loop-wave-2-benchmark-finish/feedback.json" >/dev/null
goal_manager_benchmark_objective_status_output="$("$claspc_bin" --json swarm objective status "$goal_manager_benchmark_state_root_abs" improve-clasp)"
printf '%s\n' "$goal_manager_benchmark_objective_status_output" | grep -F '"projectedStatus":"completed"' >/dev/null
printf '%s\n' "$goal_manager_benchmark_objective_status_output" | grep -F '"taskId":"planner-2"' >/dev/null
printf '%s\n' "$goal_manager_benchmark_objective_status_output" | grep -F '"taskId":"wave-2-benchmark-finish"' >/dev/null

goal_manager_benchmark_resume_heartbeat_abs="$goal_manager_benchmark_resume_state_root_abs/benchmark-1.heartbeat.json"
trace_case "goal-manager-benchmark-resume"
CLASP_TEST_FAKE_PLANNER_MODE='benchmark-replan' \
CLASP_TEST_FAKE_BENCHMARK_SLEEP_SECS='5' \
CLASP_LOOP_CODEX_BIN_JSON="\"$test_root_abs/codex\"" \
CLASP_LOOP_WORKSPACE_JSON="\"$goal_manager_benchmark_resume_workspace_root_abs\"" \
CLASP_MANAGER_CLASPC_BIN_JSON="\"$claspc_bin\"" \
CLASP_MANAGER_GOAL_JSON='"Beat the AppBench target for Clasp."' \
CLASP_MANAGER_MAX_TASKS_JSON='1' \
CLASP_MANAGER_MAX_WAVES_JSON='2' \
CLASP_LOOP_WATCH_POLL_MS_JSON='50' \
  CLASP_MANAGER_BENCHMARK_COMMAND_JSON="[\"$feedback_loop_slow_benchmark_bin\"]" \
  "$goal_manager_binary" "$goal_manager_benchmark_resume_state_root_abs" >"$goal_manager_benchmark_resume_output_abs.first" 2>&1 &
goal_manager_live_pid=$!
for _ in $(seq 1 1200); do
  if [[ -f "$goal_manager_benchmark_resume_state_status_abs" ]] \
    && grep -F '"phase":"benchmark-running"' "$goal_manager_benchmark_resume_state_status_abs" >/dev/null 2>&1; then
    break
  fi
  sleep 0.05
done
CLASP_MANAGER_COMMAND=status "$goal_manager_binary" "$goal_manager_benchmark_resume_state_root_abs" >"$goal_manager_benchmark_resume_status_output_abs"
grep -F '"phase":"benchmark-running"' "$goal_manager_benchmark_resume_status_output_abs" >/dev/null
wait_for_path_contains "$goal_manager_benchmark_resume_heartbeat_abs" '"running":true' "" 600 0.05
stop_goal_manager_service "$goal_manager_benchmark_resume_state_root_abs"
wait_or_kill_pid "$goal_manager_live_pid" 100
goal_manager_live_pid=""
CLASP_TEST_FAKE_PLANNER_MODE='benchmark-replan' \
CLASP_TEST_FAKE_BENCHMARK_SLEEP_SECS='5' \
CLASP_LOOP_CODEX_BIN_JSON="\"$test_root_abs/codex\"" \
CLASP_LOOP_WORKSPACE_JSON="\"$goal_manager_benchmark_resume_workspace_root_abs\"" \
CLASP_MANAGER_CLASPC_BIN_JSON="\"$claspc_bin\"" \
CLASP_MANAGER_GOAL_JSON='"Beat the AppBench target for Clasp."' \
CLASP_MANAGER_MAX_TASKS_JSON='1' \
CLASP_MANAGER_MAX_WAVES_JSON='2' \
CLASP_LOOP_WATCH_POLL_MS_JSON='50' \
CLASP_MANAGER_BENCHMARK_COMMAND_JSON="[\"$feedback_loop_slow_benchmark_bin\"]" \
  "$goal_manager_binary" "$goal_manager_benchmark_resume_state_root_abs" >"$goal_manager_benchmark_resume_output_abs.second" 2>&1 &
goal_manager_live_pid=$!
wait_for_path_contains "$goal_manager_benchmark_resume_state_status_abs" '"phase":"completed"' "" 1200 0.05
wait_or_kill_pid "$goal_manager_live_pid" 100
goal_manager_live_pid=""
CLASP_MANAGER_COMMAND=status "$goal_manager_binary" "$goal_manager_benchmark_resume_state_root_abs" >"$goal_manager_benchmark_resume_status_output_abs"
goal_manager_benchmark_resume_output="$(cat "$goal_manager_benchmark_resume_status_output_abs")"
printf '%s\n' "$goal_manager_benchmark_resume_output" | grep -F '"phase":"completed"' >/dev/null
printf '%s\n' "$goal_manager_benchmark_resume_output" | grep -F '"verdict":"pass"' >/dev/null
printf '%s\n' "$goal_manager_benchmark_resume_output" | grep -F '"benchmarkTargetMet":true' >/dev/null
grep -F '"summary":"slow benchmark eventually finished."' "$goal_manager_benchmark_resume_state_root_abs/benchmark-1.json" >/dev/null

goal_manager_parallel_benchmark_output="$(
  trace_case "goal-manager-parallel-benchmark"
  CLASP_TEST_FAKE_PLANNER_MODE='parallel-branch-failure' \
  CLASP_TEST_FAKE_BENCHMARK_MODE='already-pass' \
  CLASP_LOOP_CODEX_BIN_JSON="\"$test_root_abs/codex\"" \
  CLASP_LOOP_WORKSPACE_JSON="\"$goal_manager_parallel_benchmark_workspace_root_abs\"" \
  CLASP_MANAGER_CLASPC_BIN_JSON="\"$claspc_bin\"" \
  CLASP_MANAGER_GOAL_JSON='"Beat the AppBench target with speculative parallel branches."' \
  CLASP_MANAGER_MAX_TASKS_JSON='2' \
  CLASP_MANAGER_MAX_CONCURRENT_CHILDREN_JSON='2' \
  CLASP_MANAGER_MAX_WAVES_JSON='2' \
  CLASP_MANAGER_BENCHMARK_COMMAND_JSON="[\"$feedback_loop_benchmark_bin\"]" \
  "$goal_manager_binary" "$goal_manager_parallel_benchmark_state_root_abs"
)"
printf '%s\n' "$goal_manager_parallel_benchmark_output" | grep -F '"phase":"completed"' >/dev/null
printf '%s\n' "$goal_manager_parallel_benchmark_output" | grep -F '"verdict":"pass"' >/dev/null
printf '%s\n' "$goal_manager_parallel_benchmark_output" | grep -F '"benchmarkTargetMet":true' >/dev/null
printf '%s\n' "$goal_manager_parallel_benchmark_output" | grep -F '"plannedTaskIds":["winning-branch","failing-branch"]' >/dev/null
grep -F '"summary":"AppBench target is already met."' "$goal_manager_parallel_benchmark_state_root_abs/benchmark-1.json" >/dev/null
grep -F '"verdict":"pass"' "$goal_manager_parallel_benchmark_state_root_abs/loop-winning-branch/feedback.json" >/dev/null
grep -F '"verdict":"fail"' "$goal_manager_parallel_benchmark_state_root_abs/loop-failing-branch/feedback.json" >/dev/null
grep -Fx 'fixed-after-feedback' "$goal_manager_parallel_benchmark_state_root_abs/workspace-winning-branch/workspace.txt" >/dev/null

goal_manager_benchmark_fail_output="$(
  trace_case "goal-manager-benchmark-fail"
  CLASP_TEST_FAKE_PLANNER_MODE='benchmark-replan' \
  CLASP_TEST_FAKE_BENCHMARK_MODE='always-fail' \
  CLASP_LOOP_CODEX_BIN_JSON="\"$test_root_abs/codex\"" \
  CLASP_LOOP_WORKSPACE_JSON="\"$goal_manager_benchmark_fail_workspace_root_abs\"" \
  CLASP_MANAGER_CLASPC_BIN_JSON="\"$claspc_bin\"" \
  CLASP_MANAGER_GOAL_JSON='"Beat the AppBench target for Clasp."' \
  CLASP_MANAGER_MAX_TASKS_JSON='1' \
  CLASP_MANAGER_MAX_WAVES_JSON='2' \
  CLASP_MANAGER_BENCHMARK_COMMAND_JSON="[\"$feedback_loop_benchmark_bin\"]" \
  "$goal_manager_binary" "$goal_manager_benchmark_fail_state_root_abs"
)"
printf '%s\n' "$goal_manager_benchmark_fail_output" | grep -F '"phase":"failed"' >/dev/null
printf '%s\n' "$goal_manager_benchmark_fail_output" | grep -F '"verdict":"fail"' >/dev/null
printf '%s\n' "$goal_manager_benchmark_fail_output" | grep -F '"benchmarkTargetMet":false' >/dev/null
grep -F '"summary":"benchmark target not met"' "$goal_manager_benchmark_fail_state_root_abs/feedback.json" >/dev/null
grep -F '"summary":"AppBench target is still unmet after the allowed waves."' "$goal_manager_benchmark_fail_state_root_abs/benchmark-2.json" >/dev/null
grep -F '"meetsTarget":false' "$goal_manager_benchmark_fail_state_root_abs/benchmark-latest.json" >/dev/null

goal_manager_benchmark_timeout_output="$(
  trace_case "goal-manager-benchmark-timeout"
  CLASP_TEST_FAKE_PLANNER_MODE='benchmark-replan' \
  CLASP_TEST_FAKE_BENCHMARK_SLEEP_SECS='5' \
  CLASP_LOOP_CODEX_BIN_JSON="\"$test_root_abs/codex\"" \
  CLASP_LOOP_WORKSPACE_JSON="\"$goal_manager_benchmark_timeout_workspace_root_abs\"" \
  CLASP_MANAGER_CLASPC_BIN_JSON="\"$claspc_bin\"" \
  CLASP_MANAGER_GOAL_JSON='"Beat the AppBench target for Clasp."' \
  CLASP_MANAGER_MAX_TASKS_JSON='1' \
  CLASP_MANAGER_MAX_WAVES_JSON='2' \
  CLASP_MANAGER_BENCHMARK_TIMEOUT_MS_JSON='100' \
  CLASP_MANAGER_BENCHMARK_COMMAND_JSON="[\"$feedback_loop_slow_benchmark_bin\"]" \
  "$goal_manager_binary" "$goal_manager_benchmark_timeout_state_root_abs"
)"
printf '%s\n' "$goal_manager_benchmark_timeout_output" | grep -F '"phase":"failed"' >/dev/null
printf '%s\n' "$goal_manager_benchmark_timeout_output" | grep -F '"verdict":"fail"' >/dev/null
printf '%s\n' "$goal_manager_benchmark_timeout_output" | grep -F '"benchmarkTargetMet":false' >/dev/null
grep -F '"summary":"benchmark command timed out"' "$goal_manager_benchmark_timeout_state_root_abs/feedback.json" >/dev/null
grep -F 'Benchmark command exceeded 100ms.' "$goal_manager_benchmark_timeout_state_root_abs/feedback.json" >/dev/null
grep -F '"phase":"failed"' "$goal_manager_benchmark_timeout_state_root_abs/status.json" >/dev/null
grep -F '"benchmarkRuns":0' "$goal_manager_benchmark_timeout_state_root_abs/status.json" >/dev/null
grep -F '"running":true' "$goal_manager_benchmark_timeout_state_root_abs/benchmark-1.heartbeat.json" >/dev/null

goal_manager_benchmark_timeout_signal_output="$(
  trace_case "goal-manager-benchmark-timeout-signal"
  CLASP_TEST_FAKE_PLANNER_MODE='benchmark-replan' \
  CLASP_TEST_FAKE_BENCHMARK_SLEEP_SECS='5' \
  CLASP_TEST_FAKE_BENCHMARK_SLOW_MODE='signal-before-sleep' \
  CLASP_LOOP_CODEX_BIN_JSON="\"$test_root_abs/codex\"" \
  CLASP_LOOP_WORKSPACE_JSON="\"$goal_manager_benchmark_timeout_signal_workspace_root_abs\"" \
  CLASP_MANAGER_CLASPC_BIN_JSON="\"$claspc_bin\"" \
  CLASP_MANAGER_GOAL_JSON='"Beat the AppBench target for Clasp."' \
  CLASP_MANAGER_MAX_TASKS_JSON='1' \
  CLASP_MANAGER_MAX_WAVES_JSON='2' \
  CLASP_MANAGER_BENCHMARK_TIMEOUT_MS_JSON='100' \
  CLASP_MANAGER_BENCHMARK_COMMAND_JSON="[\"$feedback_loop_slow_benchmark_bin\"]" \
  "$goal_manager_binary" "$goal_manager_benchmark_timeout_signal_state_root_abs"
)"
printf '%s\n' "$goal_manager_benchmark_timeout_signal_output" | grep -F '"phase":"completed"' >/dev/null
printf '%s\n' "$goal_manager_benchmark_timeout_signal_output" | grep -F '"verdict":"pass"' >/dev/null
printf '%s\n' "$goal_manager_benchmark_timeout_signal_output" | grep -F '"benchmarkTargetMet":true' >/dev/null
grep -F '"summary":"slow benchmark eventually finished."' "$goal_manager_benchmark_timeout_signal_state_root_abs/benchmark-1.json" >/dev/null
grep -F '"benchmarkRuns":1' "$goal_manager_benchmark_timeout_signal_state_root_abs/status.json" >/dev/null

env RUSTC=/definitely-missing-rustc "$claspc_bin" compile "$project_root/examples/support-console/Main.clasp" -o "$support_console_binary"
[[ -x "$support_console_binary" ]]
"$support_console_binary" route GET /support/customer '{}' | grep -F '"contactEmail":"ops@northwind.example"' >/dev/null
"$support_console_binary" route GET /support/customer/page '{}' | grep -F '"title":"Customer export"' >/dev/null

support_server_port="$(node -e 'const net=require("node:net"); const server=net.createServer(); server.listen(0, "127.0.0.1", () => { console.log(server.address().port); server.close(); });')"
support_server_addr="127.0.0.1:$support_server_port"
"$support_console_binary" serve "$support_server_addr" >"$support_server_log" 2>&1 &
server_pid=$!
for _ in $(seq 1 50); do
  if curl -sS -o /dev/null "http://$support_server_addr/support" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
curl -sS "http://$support_server_addr/support" | grep -F '"title":"Support console"' >/dev/null
curl -sS "http://$support_server_addr/support/customer/page" | grep -F '"title":"Customer export"' >/dev/null
curl -sS -X POST -H 'content-type: application/x-www-form-urlencoded' --data 'customerId=cust-42&summary=Renewal+is+blocked+on+legal+review.' "http://$support_server_addr/support/preview" | grep -F 'Thanks for the update. Renewal is blocked on legal review. We will send the next renewal step today.' >/dev/null
stop_server

env RUSTC=/definitely-missing-rustc "$claspc_bin" compile "$project_root/examples/release-gate/Main.clasp" -o "$release_gate_binary"
[[ -x "$release_gate_binary" ]]
"$release_gate_binary" route GET /release/audit '{}' | grep -F '"releaseId":"rel-204"' >/dev/null
"$release_gate_binary" route GET /release/audit '{}' | grep -F '"status":"pending"' >/dev/null

release_server_port="$(node -e 'const net=require("node:net"); const server=net.createServer(); server.listen(0, "127.0.0.1", () => { console.log(server.address().port); server.close(); });')"
release_server_addr="127.0.0.1:$release_server_port"
"$release_gate_binary" serve "$release_server_addr" >"$release_server_log" 2>&1 &
server_pid=$!
for _ in $(seq 1 50); do
  if curl -sS -o /dev/null "http://$release_server_addr/release-gate" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
curl -sS "http://$release_server_addr/release-gate" | grep -F '"title":"Release gate"' >/dev/null
curl -sS -X POST -H 'content-type: application/x-www-form-urlencoded' --data 'releaseId=rel-204&summary=Ship+the+support+automation+pipeline.' "http://$release_server_addr/release/review" | grep -F 'Approved after typed policy review.' >/dev/null
curl -sS -D "$server_headers" -o "$server_body" -X POST "http://$release_server_addr/release/accept" >/dev/null
grep -F 'HTTP/1.1 303 See Other' "$server_headers" >/dev/null
grep -Fi 'Location: /release/ack' "$server_headers" >/dev/null
stop_server

env RUSTC=/definitely-missing-rustc "$claspc_bin" compile "$project_root/examples/lead-app/Main.clasp" -o "$lead_app_binary"
[[ -x "$lead_app_binary" ]]
lead_create_json="$("$lead_app_binary" route POST /api/leads '{"company":"SynthSpeak API","contact":"Ava Stone","budget":25000,"segment":"Growth"}')"
printf '%s\n' "$lead_create_json" | grep -F '"leadId":"lead-3"' >/dev/null
printf '%s\n' "$lead_create_json" | grep -F '"priority":"medium"' >/dev/null
printf '%s\n' "$lead_create_json" | grep -F '"segment":"growth"' >/dev/null

lead_server_port="$(node -e 'const net=require("node:net"); const server=net.createServer(); server.listen(0, "127.0.0.1", () => { console.log(server.address().port); server.close(); });')"
lead_server_addr="127.0.0.1:$lead_server_port"
"$lead_app_binary" serve "$lead_server_addr" >"$lead_server_log" 2>&1 &
server_pid=$!
for _ in $(seq 1 50); do
  if curl -sS -o /dev/null "http://$lead_server_addr/api/inbox" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
curl -sS "http://$lead_server_addr/api/inbox" | grep -F '"headline":"Priority inbox"' >/dev/null
created_lead_json="$(curl -sS -X POST -H 'content-type: application/json' --data '{"company":"SynthSpeak API","contact":"Ava Stone","budget":25000,"segment":"Growth"}' "http://$lead_server_addr/api/leads")"
printf '%s\n' "$created_lead_json" | grep -F '"leadId":"lead-3"' >/dev/null
curl -sS "http://$lead_server_addr/api/lead/primary" | grep -F '"company":"SynthSpeak API"' >/dev/null
reviewed_lead_json="$(curl -sS -X POST -H 'content-type: application/json' --data '{"leadId":"lead-3","note":"Schedule technical discovery"}' "http://$lead_server_addr/api/review")"
printf '%s\n' "$reviewed_lead_json" | grep -F '"reviewNote":"Schedule technical discovery"' >/dev/null
curl -sS -o "$server_body" -w '%{http_code}' -X POST -H 'content-type: application/json' --data '{"company":"Bad Budget Co","contact":"Casey","budget":"oops","segment":"Growth"}' "http://$lead_server_addr/api/leads" | grep -F '400' >/dev/null
grep -F 'budget must be an integer' "$server_body" >/dev/null
curl -sS -o "$server_body" -w '%{http_code}' -X POST -H 'content-type: application/json' --data '{"leadId":"lead-404","note":"Missing"}' "http://$lead_server_addr/api/review" | grep -F '502' >/dev/null
grep -F 'Unknown lead: lead-404' "$server_body" >/dev/null
stop_server

if "$claspc_bin" --json --compiler=bootstrap check "$project_root/examples/hello.clasp" >"$bootstrap_rejection"; then
  :
else
  :
fi
grep -F '"status":"error"' "$bootstrap_rejection" >/dev/null
grep -F 'deprecated compiler selection is gone' "$bootstrap_rejection" >/dev/null
fi
