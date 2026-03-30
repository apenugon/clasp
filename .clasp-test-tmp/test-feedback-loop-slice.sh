#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-.clasp-test-tmp}"
mkdir -p "$tmp_root"
export TMPDIR="$tmp_root"
test_root="$(mktemp -d "$TMPDIR/test-native-claspc.XXXXXX")"
test_root_abs="$(cd "$test_root" && pwd -P)"
export XDG_CACHE_HOME="$test_root/xdg-cache"
mkdir -p "$XDG_CACHE_HOME"
server_pid=""
feedback_loop_live_pid=""

cleanup() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" >/dev/null 2>&1 || true
    wait "$server_pid" >/dev/null 2>&1 || true
  fi
  if [[ -n "$feedback_loop_live_pid" ]]; then
    kill "$feedback_loop_live_pid" >/dev/null 2>&1 || true
    wait "$feedback_loop_live_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$test_root"
}

trap cleanup EXIT

stop_server() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" >/dev/null 2>&1 || true
    wait "$server_pid" >/dev/null 2>&1 || true
    server_pid=""
  fi
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
body_cache_project_dir="$test_root/body-cache-project"
body_cache_project_path="$body_cache_project_dir/Main.clasp"
body_cache_first_image="$test_root/body-cache-first.native.image.json"
body_cache_second_image="$test_root/body-cache-second.native.image.json"
body_cache_trace_first_log="$test_root/body-cache-first.log"
body_cache_trace_second_log="$test_root/body-cache-second.log"
body_cache_root="$test_root/body-cache-root"
check_cache_project_dir="$test_root/check-cache-project"
check_cache_project_path="$check_cache_project_dir/Main.clasp"
check_cache_first_output="$test_root/check-cache-first.json"
check_cache_second_output="$test_root/check-cache-second.json"
check_cache_first_log="$test_root/check-cache-first.log"
check_cache_second_log="$test_root/check-cache-second.log"
check_cache_root="$test_root/check-cache-root"
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

mkdir -p "$body_cache_project_dir/Shared"
cat >"$body_cache_project_path" <<'EOF'
module Main

import Shared.User
import Shared.Render

main : Str
main = renderUser defaultUser
EOF

cat >"$body_cache_project_dir/Shared/User.clasp" <<'EOF'
module Shared.User

record User = { name : Str }

defaultUser : User
defaultUser = User { name = "planner" }
EOF

cat >"$body_cache_project_dir/Shared/Render.clasp" <<'EOF'
module Shared.Render

import Shared.User

renderUser : User -> Str
renderUser user = user.name
EOF

mkdir -p "$check_cache_project_dir/Shared"
cat >"$check_cache_project_path" <<'EOF'
module Main

import Shared.User
import Shared.Render

main : Str
main = renderUser defaultUser
EOF

cat >"$check_cache_project_dir/Shared/User.clasp" <<'EOF'
module Shared.User

record User = { name : Str }

defaultUser : User
defaultUser = User { name = "planner" }
EOF

cat >"$check_cache_project_dir/Shared/Render.clasp" <<'EOF'
module Shared.Render

import Shared.User

renderUser : User -> Str
renderUser user = user.name
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

mkdir -p "$feedback_loop_workspace_root"
mkdir -p "$feedback_loop_noise_root"
mkdir -p "$feedback_loop_live_workspace_root"
mkdir -p "$feedback_loop_fail_workspace_root"
mkdir -p "$feedback_loop_recovery_workspace_root"
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
    --cd)
      workspace_root="$2"
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

workspace_path="$workspace_root/workspace.txt"
feedback_path="$(dirname "$report_path")/feedback.json"
builder_policy_path="$(dirname "$report_path")/builder-policy.md"

if [[ "$prompt" == *"builder subagent"* ]]; then
  printf '{"phase":"builder-start"}\n'
  printf 'builder-progress\n' >&2
  sleep 0.3
  content="first-attempt"
  if [[ -f "$feedback_path" && "$prompt" == *"Verifier feedback from the previous attempt:"* && "$prompt" == *"force-close-category"* ]]; then
    content="fixed-after-feedback"
  fi
  printf '%s\n' "$content" >"$workspace_path"
  cat >"$report_path" <<JSON
{"summary":"builder wrote $content","files_touched":["workspace.txt"],"tests_run":[],"residual_risks":[],"feedback":{"summary":"use verifier feedback","ergonomics":["ordinary loop works"],"follow_ups":["keep direct codex invocation"],"warnings":[]}}
JSON
elif [[ "$prompt" == *"verifier subagent"* ]]; then
  printf '{"phase":"verifier-start"}\n'
  printf 'verifier-progress\n' >&2
  sleep 0.3
  content=""
  if [[ -f "$workspace_path" ]]; then
    content="$(cat "$workspace_path")"
  fi
  if [[ "$content" == "fixed-after-feedback" ]]; then
    cat >"$report_path" <<'JSON'
{"verdict":"pass","summary":"feedback loop converged","findings":[],"tests_run":["workspace converged"],"follow_up":[],"capability_statuses":[{"name":"ordinary_program_execution","status":"pass","evidence":["workspace converged after verifier feedback"],"blocking_gaps":[],"required_closure":[]},{"name":"durable_native_substrate","status":"pass","evidence":["test fixture does not model substrate gaps"],"blocking_gaps":[],"required_closure":[]},{"name":"clasp_native_control_api","status":"pass","evidence":["feedback loop prompt included previous verifier feedback directly"],"blocking_gaps":[],"required_closure":[]},{"name":"orchestration_viability","status":"pass","evidence":["ordinary loop completed end to end"],"blocking_gaps":[],"required_closure":[]},{"name":"ergonomics","status":"pass","evidence":["test fixture did not expose ergonomic blockers"],"blocking_gaps":[],"required_closure":[]},{"name":"verification_gate","status":"pass","evidence":["workspace converged"],"blocking_gaps":[],"required_closure":[]}]}
JSON
  else
    printf '%s\n' 'force-close-category' >"$builder_policy_path"
    cat >"$report_path" <<'JSON'
{"verdict":"fail","summary":"workspace still needs feedback","findings":["workspace.txt still has the first-attempt content"],"tests_run":["workspace converged"],"follow_up":["Close the ordinary_program_execution category by using the verifier feedback to update workspace.txt."],"capability_statuses":[{"name":"ordinary_program_execution","status":"fail","evidence":["workspace.txt still has the first-attempt content"],"blocking_gaps":["builder did not consume the previous verifier feedback"],"required_closure":["Use the verifier feedback to update workspace.txt."]},{"name":"durable_native_substrate","status":"pass","evidence":["test fixture does not model substrate gaps"],"blocking_gaps":[],"required_closure":[]},{"name":"clasp_native_control_api","status":"pass","evidence":["direct Codex invocation path is present in the fixture"],"blocking_gaps":[],"required_closure":[]},{"name":"orchestration_viability","status":"fail","evidence":["loop has not converged yet"],"blocking_gaps":["builder/verifier cycle has not closed the blocking category"],"required_closure":["Make the next builder attempt consume the previous verifier feedback and converge."]},{"name":"ergonomics","status":"pass","evidence":["test fixture does not expose ergonomic blockers"],"blocking_gaps":[],"required_closure":[]},{"name":"verification_gate","status":"fail","evidence":["final convergence has not happened yet"],"blocking_gaps":["workspace still fails the acceptance check"],"required_closure":["Converge the workspace on the next attempt."]}]}
JSON
  fi
else
  printf 'unknown prompt\n' >&2
  exit 1
fi
EOF
chmod +x "$feedback_loop_codex_bin"

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

rm -rf "$body_cache_root"
mkdir -p "$body_cache_root"
XDG_CACHE_HOME="$body_cache_root" CLASP_NATIVE_TRACE_CACHE=1 "$claspc_bin" native-image "$body_cache_project_path" -o "$body_cache_first_image" >/dev/null 2>"$body_cache_trace_first_log"
sed -i 's/planner/operator/' "$body_cache_project_dir/Shared/User.clasp"
XDG_CACHE_HOME="$body_cache_root" CLASP_NATIVE_TRACE_CACHE=1 "$claspc_bin" native-image "$body_cache_project_path" -o "$body_cache_second_image" >/dev/null 2>"$body_cache_trace_second_log"
grep -F '[claspc-cache] build-plan hit path=' "$body_cache_trace_second_log" >/dev/null
grep -F '[claspc-cache] decl-module miss module=Shared.User path=' "$body_cache_trace_second_log" >/dev/null
grep -F '[claspc-cache] decl-module hit module=Shared.Render path=' "$body_cache_trace_second_log" >/dev/null
grep -F '[claspc-cache] decl-module hit module=Main path=' "$body_cache_trace_second_log" >/dev/null

rm -rf "$check_cache_root"
mkdir -p "$check_cache_root"
XDG_CACHE_HOME="$check_cache_root" CLASP_NATIVE_TRACE_CACHE=1 "$claspc_bin" --json check "$check_cache_project_path" >"$check_cache_first_output" 2>"$check_cache_first_log"
sed -i 's/planner/operator/' "$check_cache_project_dir/Shared/User.clasp"
XDG_CACHE_HOME="$check_cache_root" CLASP_NATIVE_TRACE_CACHE=1 "$claspc_bin" --json check "$check_cache_project_path" >"$check_cache_second_output" 2>"$check_cache_second_log"
grep -F '"status":"ok"' "$check_cache_first_output" >/dev/null
grep -F '"status":"ok"' "$check_cache_second_output" >/dev/null
cmp -s "$check_cache_first_output" "$check_cache_second_output"
grep -F '[claspc-cache] module-summary miss module=Shared.User path=' "$check_cache_second_log" >/dev/null
if grep -F '[claspc-cache] module-summary hit module=Shared.Render path=' "$check_cache_second_log" >/dev/null; then
  grep -F '[claspc-cache] module-summary hit module=Main path=' "$check_cache_second_log" >/dev/null
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
if grep -F '.clasp-test-tmp' "$feedback_loop_first_diff_path" >/dev/null; then
  printf 'feedback loop diff unexpectedly included transient directories\n' >&2
  exit 1
fi
if grep -F '.clasp-test-tmp' "$feedback_loop_second_diff_path" >/dev/null; then
  printf 'feedback loop diff unexpectedly included transient directories on retry\n' >&2
  exit 1
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
grep -F 'builder-start' "$feedback_loop_live_builder_stdout" >/dev/null
grep -F 'builder-progress' "$feedback_loop_live_builder_stderr" >/dev/null
grep -F '"pid":' "$feedback_loop_live_builder_heartbeat" >/dev/null
wait "$feedback_loop_live_pid"
feedback_loop_live_pid=""
grep -F '"completed":true' "$feedback_loop_live_builder_heartbeat" >/dev/null
grep -F '"exitCode":0' "$feedback_loop_live_builder_heartbeat" >/dev/null
grep -F 'pass:2' "$feedback_loop_live_output" >/dev/null

