#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
claspc_bin="$("$project_root/scripts/resolve-claspc.sh")"
test_root="$(mktemp -d)"
binary_path="$test_root/swarm-kernel"
state_root="$test_root/state/root"
event_log="$state_root/events.jsonl"
loop_state_root="$test_root/loop-state/root"
loop_event_log="$loop_state_root/events.jsonl"
sqlite_state_root="$test_root/sqlite-state"
sqlite_db="$sqlite_state_root/swarm.db"

cleanup() {
  rm -rf "$test_root"
}

trap cleanup EXIT

CLASP_SWARM_ACTOR=planner "$claspc_bin" compile "$project_root/examples/swarm-kernel/Main.clasp" -o "$binary_path"
[[ -x "$binary_path" ]]

output_path="$(CLASP_SWARM_ACTOR=planner "$binary_path" "$state_root")"
[[ "$output_path" == "$event_log" ]]
[[ -f "$event_log" ]]
grep -F '"kind":"task_created"' "$event_log" >/dev/null
grep -F '"taskId":"bootstrap"' "$event_log" >/dev/null
grep -F '"actor":"planner"' "$event_log" >/dev/null
grep -F '"detail":"Initialize swarm kernel state."' "$event_log" >/dev/null
grep -E '"atMs":[0-9]+' "$event_log" >/dev/null

lease_output_path="$(CLASP_SWARM_ACTOR=worker-1 CLASP_SWARM_COMMAND=lease CLASP_SWARM_TASK_ID=bootstrap "$binary_path" "$state_root")"
[[ "$lease_output_path" == "$event_log" ]]
grep -F '"kind":"lease_acquired"' "$event_log" >/dev/null
grep -F '"actor":"worker-1"' "$event_log" >/dev/null
grep -F '"detail":"Acquire lease for bootstrap."' "$event_log" >/dev/null

heartbeat_output_path="$(CLASP_SWARM_ACTOR=worker-1 CLASP_SWARM_COMMAND=heartbeat CLASP_SWARM_TASK_ID=bootstrap "$binary_path" "$state_root")"
[[ "$heartbeat_output_path" == "$event_log" ]]
grep -F '"kind":"worker_heartbeat"' "$event_log" >/dev/null
grep -F '"detail":"Heartbeat for bootstrap."' "$event_log" >/dev/null

complete_output_path="$(CLASP_SWARM_ACTOR=worker-1 CLASP_SWARM_COMMAND=complete CLASP_SWARM_TASK_ID=bootstrap "$binary_path" "$state_root")"
[[ "$complete_output_path" == "$event_log" ]]
grep -F '"kind":"task_completed"' "$event_log" >/dev/null
grep -F '"detail":"Complete task bootstrap."' "$event_log" >/dev/null

status_output="$(CLASP_SWARM_COMMAND=status CLASP_SWARM_TASK_ID=bootstrap "$binary_path" "$state_root")"
printf '%s\n' "$status_output" | grep -F '"taskId":"bootstrap"' >/dev/null
printf '%s\n' "$status_output" | grep -F '"status":"completed"' >/dev/null
printf '%s\n' "$status_output" | grep -F '"leaseActor":"worker-1"' >/dev/null
printf '%s\n' "$status_output" | grep -E '"lastHeartbeatAtMs":[0-9]+' >/dev/null
printf '%s\n' "$status_output" | grep -F '"heartbeatSeen":true' >/dev/null

repair_bootstrap_path="$(CLASP_SWARM_ACTOR=planner CLASP_SWARM_COMMAND=bootstrap CLASP_SWARM_TASK_ID=repair "$binary_path" "$state_root")"
[[ "$repair_bootstrap_path" == "$event_log" ]]
repair_lease_path="$(CLASP_SWARM_ACTOR=worker-2 CLASP_SWARM_COMMAND=lease CLASP_SWARM_TASK_ID=repair "$binary_path" "$state_root")"
[[ "$repair_lease_path" == "$event_log" ]]
repair_fail_path="$(CLASP_SWARM_ACTOR=worker-2 CLASP_SWARM_COMMAND=fail CLASP_SWARM_TASK_ID=repair "$binary_path" "$state_root")"
[[ "$repair_fail_path" == "$event_log" ]]
grep -F '"kind":"task_failed"' "$event_log" >/dev/null
grep -F '"detail":"Fail task repair."' "$event_log" >/dev/null

repair_status_output="$(CLASP_SWARM_COMMAND=status CLASP_SWARM_TASK_ID=repair "$binary_path" "$state_root")"
printf '%s\n' "$repair_status_output" | grep -F '"taskId":"repair"' >/dev/null
printf '%s\n' "$repair_status_output" | grep -F '"status":"failed"' >/dev/null
printf '%s\n' "$repair_status_output" | grep -F '"leaseActor":"worker-2"' >/dev/null
printf '%s\n' "$repair_status_output" | grep -F '"heartbeatSeen":false' >/dev/null

repair_retry_path="$(CLASP_SWARM_ACTOR=planner CLASP_SWARM_COMMAND=retry CLASP_SWARM_TASK_ID=repair "$binary_path" "$state_root")"
[[ "$repair_retry_path" == "$event_log" ]]
grep -F '"kind":"task_requeued"' "$event_log" >/dev/null
grep -F '"detail":"Requeue task repair."' "$event_log" >/dev/null

repair_retry_status_output="$(CLASP_SWARM_COMMAND=status CLASP_SWARM_TASK_ID=repair "$binary_path" "$state_root")"
printf '%s\n' "$repair_retry_status_output" | grep -F '"taskId":"repair"' >/dev/null
printf '%s\n' "$repair_retry_status_output" | grep -F '"status":"queued"' >/dev/null
printf '%s\n' "$repair_retry_status_output" | grep -F '"leaseActor":""' >/dev/null
printf '%s\n' "$repair_retry_status_output" | grep -F '"heartbeatSeen":false' >/dev/null

repair_history_output="$(CLASP_SWARM_COMMAND=history CLASP_SWARM_TASK_ID=repair "$binary_path" "$state_root")"
printf '%s\n' "$repair_history_output" | grep -F '"kind":"task_created"' >/dev/null
printf '%s\n' "$repair_history_output" | grep -F '"kind":"lease_acquired"' >/dev/null
printf '%s\n' "$repair_history_output" | grep -F '"kind":"task_failed"' >/dev/null
printf '%s\n' "$repair_history_output" | grep -F '"kind":"task_requeued"' >/dev/null
printf '%s\n' "$repair_history_output" | grep -F '"actor":"worker-2"' >/dev/null

draft_bootstrap_path="$(CLASP_SWARM_ACTOR=planner CLASP_SWARM_COMMAND=bootstrap CLASP_SWARM_TASK_ID=draft "$binary_path" "$state_root")"
[[ "$draft_bootstrap_path" == "$event_log" ]]
draft_lease_path="$(CLASP_SWARM_ACTOR=worker-3 CLASP_SWARM_COMMAND=lease CLASP_SWARM_TASK_ID=draft "$binary_path" "$state_root")"
[[ "$draft_lease_path" == "$event_log" ]]
draft_release_path="$(CLASP_SWARM_ACTOR=worker-3 CLASP_SWARM_COMMAND=release CLASP_SWARM_TASK_ID=draft "$binary_path" "$state_root")"
[[ "$draft_release_path" == "$event_log" ]]
grep -F '"kind":"lease_released"' "$event_log" >/dev/null
grep -F '"detail":"Release lease for draft."' "$event_log" >/dev/null

draft_status_output="$(CLASP_SWARM_COMMAND=status CLASP_SWARM_TASK_ID=draft "$binary_path" "$state_root")"
printf '%s\n' "$draft_status_output" | grep -F '"taskId":"draft"' >/dev/null
printf '%s\n' "$draft_status_output" | grep -F '"status":"queued"' >/dev/null
printf '%s\n' "$draft_status_output" | grep -F '"leaseActor":""' >/dev/null
printf '%s\n' "$draft_status_output" | grep -F '"heartbeatSeen":false' >/dev/null

tasks_output="$(CLASP_SWARM_COMMAND=tasks "$binary_path" "$state_root")"
printf '%s\n' "$tasks_output" | grep -F '"taskId":"bootstrap"' >/dev/null
printf '%s\n' "$tasks_output" | grep -F '"status":"completed"' >/dev/null
printf '%s\n' "$tasks_output" | grep -F '"taskId":"repair"' >/dev/null
printf '%s\n' "$tasks_output" | grep -F '"status":"queued"' >/dev/null
printf '%s\n' "$tasks_output" | grep -F '"taskId":"draft"' >/dev/null

summary_output="$(CLASP_SWARM_COMMAND=summary "$binary_path" "$state_root")"
printf '%s\n' "$summary_output" | grep -F '"allTaskIds":["bootstrap","repair","draft"]' >/dev/null
printf '%s\n' "$summary_output" | grep -F '"queuedTaskIds":["repair","draft"]' >/dev/null
printf '%s\n' "$summary_output" | grep -F '"completedTaskIds":["bootstrap"]' >/dev/null
printf '%s\n' "$summary_output" | grep -F '"failedTaskIds":[]' >/dev/null
printf '%s\n' "$summary_output" | grep -F '"heartbeatTaskIds":["bootstrap"]' >/dev/null
printf '%s\n' "$summary_output" | grep -F '"statusByTask":{"bootstrap":"completed","repair":"queued","draft":"queued"}' >/dev/null
printf '%s\n' "$summary_output" | grep -F '"leaseByTask":{"bootstrap":"worker-1","repair":"","draft":""}' >/dev/null
printf '%s\n' "$summary_output" | grep -F '"hasBootstrap":true' >/dev/null
printf '%s\n' "$summary_output" | grep -F '"bootstrapStatus":"completed"' >/dev/null
printf '%s\n' "$summary_output" | grep -F '"taskStatusKeys":["bootstrap","repair","draft"]' >/dev/null
printf '%s\n' "$summary_output" | grep -F '"leaseValuesWithoutDraft":["worker-1",""]' >/dev/null

loop_initial_output="$(CLASP_SWARM_COMMAND=monitor CLASP_SWARM_TASK_ID=language-loop "$binary_path" "$loop_state_root")"
printf '%s\n' "$loop_initial_output" | grep -F '"taskId":"language-loop"' >/dev/null
printf '%s\n' "$loop_initial_output" | grep -F '"attempt":1' >/dev/null
printf '%s\n' "$loop_initial_output" | grep -F '"phase":"needs-builder"' >/dev/null
printf '%s\n' "$loop_initial_output" | grep -F '"healthy":true' >/dev/null
printf '%s\n' "$loop_initial_output" | grep -F '"needsAttention":false' >/dev/null
printf '%s\n' "$loop_initial_output" | grep -F '"suggestedRole":"builder"' >/dev/null
printf '%s\n' "$loop_initial_output" | grep -F '"suggestedCommand":"CLASP_SWARM_COMMAND=builder-start CLASP_SWARM_TASK_ID=language-loop"' >/dev/null

loop_builder_start_path="$(CLASP_SWARM_ACTOR=builder CLASP_SWARM_COMMAND=builder-start CLASP_SWARM_TASK_ID=language-loop "$binary_path" "$loop_state_root")"
[[ "$loop_builder_start_path" == "$loop_event_log" ]]
grep -F '"kind":"builder_started"' "$loop_event_log" >/dev/null

loop_builder_running_output="$(CLASP_SWARM_COMMAND=loop-status CLASP_SWARM_TASK_ID=language-loop "$binary_path" "$loop_state_root")"
printf '%s\n' "$loop_builder_running_output" | grep -F '"phase":"builder-running"' >/dev/null
printf '%s\n' "$loop_builder_running_output" | grep -F '"builderRuns":1' >/dev/null
printf '%s\n' "$loop_builder_running_output" | grep -F '"suggestedRole":"builder"' >/dev/null

loop_builder_complete_path="$(CLASP_SWARM_ACTOR=builder CLASP_SWARM_COMMAND=builder-complete CLASP_SWARM_TASK_ID=language-loop "$binary_path" "$loop_state_root")"
[[ "$loop_builder_complete_path" == "$loop_event_log" ]]
grep -F '"kind":"builder_completed"' "$loop_event_log" >/dev/null

loop_needs_verifier_output="$(CLASP_SWARM_COMMAND=monitor CLASP_SWARM_TASK_ID=language-loop "$binary_path" "$loop_state_root")"
printf '%s\n' "$loop_needs_verifier_output" | grep -F '"phase":"needs-verifier"' >/dev/null
printf '%s\n' "$loop_needs_verifier_output" | grep -F '"suggestedRole":"verifier"' >/dev/null
printf '%s\n' "$loop_needs_verifier_output" | grep -F '"suggestedCommand":"CLASP_SWARM_COMMAND=verifier-start CLASP_SWARM_TASK_ID=language-loop"' >/dev/null

loop_verifier_start_path="$(CLASP_SWARM_ACTOR=verifier CLASP_SWARM_COMMAND=verifier-start CLASP_SWARM_TASK_ID=language-loop "$binary_path" "$loop_state_root")"
[[ "$loop_verifier_start_path" == "$loop_event_log" ]]
grep -F '"kind":"verifier_started"' "$loop_event_log" >/dev/null

loop_verifier_fail_path="$(CLASP_SWARM_ACTOR=verifier CLASP_SWARM_COMMAND=verifier-fail CLASP_SWARM_TASK_ID=language-loop CLASP_SWARM_DETAIL='native summary crashed' "$binary_path" "$loop_state_root")"
[[ "$loop_verifier_fail_path" == "$loop_event_log" ]]
grep -F '"kind":"verifier_failed"' "$loop_event_log" >/dev/null
grep -F '"detail":"native summary crashed"' "$loop_event_log" >/dev/null

loop_after_fail_output="$(CLASP_SWARM_COMMAND=monitor CLASP_SWARM_TASK_ID=language-loop "$binary_path" "$loop_state_root")"
printf '%s\n' "$loop_after_fail_output" | grep -F '"attempt":2' >/dev/null
printf '%s\n' "$loop_after_fail_output" | grep -F '"phase":"needs-builder"' >/dev/null
printf '%s\n' "$loop_after_fail_output" | grep -F '"healthy":false' >/dev/null
printf '%s\n' "$loop_after_fail_output" | grep -F '"needsAttention":true' >/dev/null
printf '%s\n' "$loop_after_fail_output" | grep -F '"attentionReason":"native summary crashed"' >/dev/null
printf '%s\n' "$loop_after_fail_output" | grep -F '"suggestedRole":"builder"' >/dev/null

loop_builder_retry_path="$(CLASP_SWARM_ACTOR=builder CLASP_SWARM_COMMAND=builder-start CLASP_SWARM_TASK_ID=language-loop "$binary_path" "$loop_state_root")"
[[ "$loop_builder_retry_path" == "$loop_event_log" ]]
loop_builder_retry_complete_path="$(CLASP_SWARM_ACTOR=builder CLASP_SWARM_COMMAND=builder-complete CLASP_SWARM_TASK_ID=language-loop "$binary_path" "$loop_state_root")"
[[ "$loop_builder_retry_complete_path" == "$loop_event_log" ]]
loop_verifier_retry_start_path="$(CLASP_SWARM_ACTOR=verifier CLASP_SWARM_COMMAND=verifier-start CLASP_SWARM_TASK_ID=language-loop "$binary_path" "$loop_state_root")"
[[ "$loop_verifier_retry_start_path" == "$loop_event_log" ]]
loop_verifier_pass_path="$(CLASP_SWARM_ACTOR=verifier CLASP_SWARM_COMMAND=verifier-pass CLASP_SWARM_TASK_ID=language-loop "$binary_path" "$loop_state_root")"
[[ "$loop_verifier_pass_path" == "$loop_event_log" ]]
grep -F '"kind":"verifier_passed"' "$loop_event_log" >/dev/null

loop_completed_output="$(CLASP_SWARM_COMMAND=monitor CLASP_SWARM_TASK_ID=language-loop "$binary_path" "$loop_state_root")"
printf '%s\n' "$loop_completed_output" | grep -F '"attempt":2' >/dev/null
printf '%s\n' "$loop_completed_output" | grep -F '"phase":"completed"' >/dev/null
printf '%s\n' "$loop_completed_output" | grep -F '"completed":true' >/dev/null
printf '%s\n' "$loop_completed_output" | grep -F '"builderRuns":2' >/dev/null
printf '%s\n' "$loop_completed_output" | grep -F '"verifierRuns":2' >/dev/null
printf '%s\n' "$loop_completed_output" | grep -F '"healthy":true' >/dev/null
printf '%s\n' "$loop_completed_output" | grep -F '"needsAttention":false' >/dev/null
printf '%s\n' "$loop_completed_output" | grep -F '"suggestedRole":""' >/dev/null

sqlite_bootstrap_output="$("$claspc_bin" --json swarm bootstrap "$sqlite_state_root" bootstrap)"
printf '%s\n' "$sqlite_bootstrap_output" | grep -F "\"database\":\"$sqlite_db\"" >/dev/null
printf '%s\n' "$sqlite_bootstrap_output" | grep -F '"kind":"task_created"' >/dev/null
printf '%s\n' "$sqlite_bootstrap_output" | grep -F '"taskId":"bootstrap"' >/dev/null

sqlite_lease_output="$(CLASP_SWARM_ACTOR=worker-1 "$claspc_bin" --json swarm lease "$sqlite_state_root" bootstrap)"
printf '%s\n' "$sqlite_lease_output" | grep -F '"kind":"lease_acquired"' >/dev/null
printf '%s\n' "$sqlite_lease_output" | grep -F '"actor":"worker-1"' >/dev/null

sqlite_heartbeat_output="$(CLASP_SWARM_ACTOR=worker-1 "$claspc_bin" --json swarm heartbeat "$sqlite_state_root" bootstrap)"
printf '%s\n' "$sqlite_heartbeat_output" | grep -F '"kind":"worker_heartbeat"' >/dev/null

sqlite_complete_output="$(CLASP_SWARM_ACTOR=worker-1 "$claspc_bin" --json swarm complete "$sqlite_state_root" bootstrap)"
printf '%s\n' "$sqlite_complete_output" | grep -F '"kind":"task_completed"' >/dev/null

sqlite_status_output="$("$claspc_bin" --json swarm status "$sqlite_state_root" bootstrap)"
printf '%s\n' "$sqlite_status_output" | grep -F '"taskId":"bootstrap"' >/dev/null
printf '%s\n' "$sqlite_status_output" | grep -F '"status":"completed"' >/dev/null
printf '%s\n' "$sqlite_status_output" | grep -F '"leaseActor":"worker-1"' >/dev/null
printf '%s\n' "$sqlite_status_output" | grep -F '"heartbeatSeen":true' >/dev/null
printf '%s\n' "$sqlite_status_output" | grep -F '"attempts":1' >/dev/null

sqlite_repair_bootstrap_output="$("$claspc_bin" --json swarm bootstrap "$sqlite_state_root" repair)"
printf '%s\n' "$sqlite_repair_bootstrap_output" | grep -F '"taskId":"repair"' >/dev/null
sqlite_repair_lease_output="$(CLASP_SWARM_ACTOR=worker-2 "$claspc_bin" --json swarm lease "$sqlite_state_root" repair)"
printf '%s\n' "$sqlite_repair_lease_output" | grep -F '"kind":"lease_acquired"' >/dev/null
sqlite_repair_fail_output="$(CLASP_SWARM_ACTOR=worker-2 "$claspc_bin" --json swarm fail "$sqlite_state_root" repair)"
printf '%s\n' "$sqlite_repair_fail_output" | grep -F '"kind":"task_failed"' >/dev/null
sqlite_repair_retry_output="$("$claspc_bin" --json swarm retry "$sqlite_state_root" repair)"
printf '%s\n' "$sqlite_repair_retry_output" | grep -F '"kind":"task_requeued"' >/dev/null
sqlite_summary_output="$("$claspc_bin" --json swarm summary "$sqlite_state_root")"
printf '%s\n' "$sqlite_summary_output" | grep -F '"allTaskIds":["bootstrap","repair"]' >/dev/null
printf '%s\n' "$sqlite_summary_output" | grep -F '"completedTaskIds":["bootstrap"]' >/dev/null
printf '%s\n' "$sqlite_summary_output" | grep -F '"queuedTaskIds":["repair"]' >/dev/null
printf '%s\n' "$sqlite_summary_output" | grep -F '"statusByTask":{"bootstrap":"completed","repair":"queued"}' >/dev/null
printf '%s\n' "$sqlite_summary_output" | grep -F '"bootstrapStatus":"completed"' >/dev/null

sqlite_repair_tool_lease_output="$(CLASP_SWARM_ACTOR=manager "$claspc_bin" --json swarm lease "$sqlite_state_root" repair)"
printf '%s\n' "$sqlite_repair_tool_lease_output" | grep -F '"kind":"lease_acquired"' >/dev/null
tool_output="$(CLASP_SWARM_ACTOR=manager "$claspc_bin" --json swarm tool "$sqlite_state_root" repair --cwd "$project_root" -- bash -lc 'printf tool-ok; >&2 printf tool-err')"
printf '%s\n' "$tool_output" | grep -F '"role":"tool"' >/dev/null
printf '%s\n' "$tool_output" | grep -F '"status":"passed"' >/dev/null
tool_stdout_path="$(printf '%s\n' "$tool_output" | sed -n 's/.*"stdoutArtifactPath":"\([^"]*\)".*/\1/p')"
tool_stderr_path="$(printf '%s\n' "$tool_output" | sed -n 's/.*"stderrArtifactPath":"\([^"]*\)".*/\1/p')"
[[ -f "$tool_stdout_path" ]]
[[ -f "$tool_stderr_path" ]]
grep -Fx 'tool-ok' "$tool_stdout_path" >/dev/null
grep -Fx 'tool-err' "$tool_stderr_path" >/dev/null

verifier_output="$(CLASP_SWARM_ACTOR=manager "$claspc_bin" --json swarm verifier run "$sqlite_state_root" repair native-smoke --cwd "$project_root" -- bash -lc 'printf verifier-ok')"
printf '%s\n' "$verifier_output" | grep -F '"role":"verifier"' >/dev/null
printf '%s\n' "$verifier_output" | grep -F '"name":"native-smoke"' >/dev/null
printf '%s\n' "$verifier_output" | grep -F '"status":"passed"' >/dev/null

mergegate_output="$("$claspc_bin" --json swarm mergegate decide "$sqlite_state_root" repair trunk native-smoke)"
printf '%s\n' "$mergegate_output" | grep -F '"mergegateName":"trunk"' >/dev/null
printf '%s\n' "$mergegate_output" | grep -F '"verdict":"pass"' >/dev/null
printf '%s\n' "$mergegate_output" | grep -F '"status":"passed"' >/dev/null

manager_start_output="$("$claspc_bin" --json swarm start "$sqlite_state_root" manager-task)"
printf '%s\n' "$manager_start_output" | grep -F '"kind":"task_created"' >/dev/null
printf '%s\n' "$manager_start_output" | grep -F '"taskId":"manager-task"' >/dev/null

manager_lease_output="$(CLASP_SWARM_ACTOR=manager "$claspc_bin" --json swarm lease "$sqlite_state_root" manager-task)"
printf '%s\n' "$manager_lease_output" | grep -F '"kind":"lease_acquired"' >/dev/null

manager_stop_output="$(CLASP_SWARM_ACTOR=manager "$claspc_bin" --json swarm stop "$sqlite_state_root" manager-task)"
printf '%s\n' "$manager_stop_output" | grep -F '"kind":"task_stopped"' >/dev/null

manager_stop_status_output="$("$claspc_bin" --json swarm status "$sqlite_state_root" manager-task)"
printf '%s\n' "$manager_stop_status_output" | grep -F '"status":"stopped"' >/dev/null
printf '%s\n' "$manager_stop_status_output" | grep -F '"leaseActor":""' >/dev/null
manager_stop_status_text="$("$claspc_bin" swarm status "$sqlite_state_root" manager-task)"
printf '%s\n' "$manager_stop_status_text" | grep -F 'task manager-task' >/dev/null
printf '%s\n' "$manager_stop_status_text" | grep -F 'status: stopped' >/dev/null

manager_resume_output="$(CLASP_SWARM_ACTOR=manager "$claspc_bin" --json swarm resume "$sqlite_state_root" manager-task)"
printf '%s\n' "$manager_resume_output" | grep -F '"kind":"task_resumed"' >/dev/null

manager_resume_status_output="$("$claspc_bin" --json swarm status "$sqlite_state_root" manager-task)"
printf '%s\n' "$manager_resume_status_output" | grep -F '"status":"queued"' >/dev/null

tail_output="$("$claspc_bin" --json swarm tail "$sqlite_state_root" manager-task --limit 4)"
printf '%s\n' "$tail_output" | grep -F '"kind":"task_created"' >/dev/null
printf '%s\n' "$tail_output" | grep -F '"kind":"task_stopped"' >/dev/null
printf '%s\n' "$tail_output" | grep -F '"kind":"task_resumed"' >/dev/null
tail_text="$("$claspc_bin" swarm tail "$sqlite_state_root" manager-task --limit 4)"
printf '%s\n' "$tail_text" | grep -F 'manager-task task_created by manager' >/dev/null
printf '%s\n' "$tail_text" | grep -F 'manager-task task_resumed by manager' >/dev/null

approval_output="$(CLASP_SWARM_ACTOR=manager "$claspc_bin" --json swarm approve "$sqlite_state_root" repair merge-ready)"
printf '%s\n' "$approval_output" | grep -F '"name":"merge-ready"' >/dev/null
printf '%s\n' "$approval_output" | grep -F '"taskId":"repair"' >/dev/null
approval_text="$(CLASP_SWARM_ACTOR=manager "$claspc_bin" swarm approve "$sqlite_state_root" repair review-ok)"
printf '%s\n' "$approval_text" | grep -F 'approval repair review-ok' >/dev/null
printf '%s\n' "$approval_text" | grep -F 'actor: manager' >/dev/null

approvals_output="$("$claspc_bin" --json swarm approvals "$sqlite_state_root" repair)"
printf '%s\n' "$approvals_output" | grep -F '"name":"merge-ready"' >/dev/null
printf '%s\n' "$approvals_output" | grep -F '"actor":"manager"' >/dev/null
printf '%s\n' "$approvals_output" | grep -F '"name":"review-ok"' >/dev/null

objective_create_output="$("$claspc_bin" --json swarm objective create "$sqlite_state_root" appbench --detail 'Beat appbench' --max-tasks 2 --max-runs 3)"
printf '%s\n' "$objective_create_output" | grep -F '"objectiveId":"appbench"' >/dev/null
printf '%s\n' "$objective_create_output" | grep -F '"maxTasks":2' >/dev/null

objective_plan_output="$("$claspc_bin" --json swarm task create "$sqlite_state_root" appbench plan --detail 'Plan work' --max-runs 1)"
printf '%s\n' "$objective_plan_output" | grep -F '"taskId":"plan"' >/dev/null
printf '%s\n' "$objective_plan_output" | grep -F '"objectiveId":"appbench"' >/dev/null
printf '%s\n' "$objective_plan_output" | grep -F '"ready":true' >/dev/null

objective_repair_output="$("$claspc_bin" --json swarm task create "$sqlite_state_root" appbench repair-2 --detail 'Repair runtime path' --depends-on plan --max-runs 1)"
printf '%s\n' "$objective_repair_output" | grep -F '"taskId":"repair-2"' >/dev/null
printf '%s\n' "$objective_repair_output" | grep -F '"ready":false' >/dev/null

policy_output="$("$claspc_bin" --json swarm policy set "$sqlite_state_root" repair-2 trunk --require-approval merge-ready --require-verifier native-smoke)"
printf '%s\n' "$policy_output" | grep -F '"taskId":"repair-2"' >/dev/null
printf '%s\n' "$policy_output" | grep -F '"mergegateName":"trunk"' >/dev/null
printf '%s\n' "$policy_output" | grep -F '"requiredApprovals":["merge-ready"]' >/dev/null
printf '%s\n' "$policy_output" | grep -F '"requiredVerifiers":["native-smoke"]' >/dev/null

manager_initial_output="$("$claspc_bin" --json swarm manager next "$sqlite_state_root" appbench)"
printf '%s\n' "$manager_initial_output" | grep -F '"action":"run-task"' >/dev/null
printf '%s\n' "$manager_initial_output" | grep -F '"taskId":"plan"' >/dev/null
printf '%s\n' "$manager_initial_output" | grep -F '"suggestedCommand":["claspc","swarm","lease","<state-root>","plan"]' >/dev/null

ready_before_output="$("$claspc_bin" --json swarm ready "$sqlite_state_root" appbench)"
printf '%s\n' "$ready_before_output" | grep -F '"taskId":"plan"' >/dev/null
if printf '%s\n' "$ready_before_output" | grep -F '"taskId":"repair-2"' >/dev/null; then
  echo "repair-2 should not be ready before plan completes" >&2
  exit 1
fi

plan_lease_output="$(CLASP_SWARM_ACTOR=manager "$claspc_bin" --json swarm lease "$sqlite_state_root" plan)"
printf '%s\n' "$plan_lease_output" | grep -F '"kind":"lease_acquired"' >/dev/null
plan_complete_output="$(CLASP_SWARM_ACTOR=manager "$claspc_bin" --json swarm complete "$sqlite_state_root" plan)"
printf '%s\n' "$plan_complete_output" | grep -F '"taskId":"plan"' >/dev/null
printf '%s\n' "$plan_complete_output" | grep -F '"status":"completed"' >/dev/null

ready_after_output="$("$claspc_bin" --json swarm ready "$sqlite_state_root" appbench)"
printf '%s\n' "$ready_after_output" | grep -F '"taskId":"repair-2"' >/dev/null

manager_after_plan_output="$("$claspc_bin" --json swarm manager next "$sqlite_state_root" appbench)"
printf '%s\n' "$manager_after_plan_output" | grep -F '"action":"run-task"' >/dev/null
printf '%s\n' "$manager_after_plan_output" | grep -F '"taskId":"repair-2"' >/dev/null

repair_lease_output="$(CLASP_SWARM_ACTOR=manager "$claspc_bin" --json swarm lease "$sqlite_state_root" repair-2)"
printf '%s\n' "$repair_lease_output" | grep -F '"kind":"lease_acquired"' >/dev/null
repair_complete_output="$(CLASP_SWARM_ACTOR=manager "$claspc_bin" --json swarm complete "$sqlite_state_root" repair-2)"
printf '%s\n' "$repair_complete_output" | grep -F '"taskId":"repair-2"' >/dev/null
printf '%s\n' "$repair_complete_output" | grep -F '"status":"completed"' >/dev/null
printf '%s\n' "$repair_complete_output" | grep -F '"mergePolicy"' >/dev/null

repair_status_output="$("$claspc_bin" --json swarm status "$sqlite_state_root" repair-2)"
printf '%s\n' "$repair_status_output" | grep -F '"missingVerifiers":["native-smoke"]' >/dev/null

manager_after_repair_output="$("$claspc_bin" --json swarm manager next "$sqlite_state_root" appbench)"
printf '%s\n' "$manager_after_repair_output" | grep -F '"action":"run-verifier"' >/dev/null
printf '%s\n' "$manager_after_repair_output" | grep -F '"verifier":"native-smoke"' >/dev/null

repair_verifier_output="$(CLASP_SWARM_ACTOR=manager "$claspc_bin" --json swarm verifier run "$sqlite_state_root" repair-2 native-smoke --cwd "$project_root" -- bash -lc 'printf verifier-ok')"
printf '%s\n' "$repair_verifier_output" | grep -F '"taskId":"repair-2"' >/dev/null
printf '%s\n' "$repair_verifier_output" | grep -F '"status":"passed"' >/dev/null

manager_after_verifier_output="$("$claspc_bin" --json swarm manager next "$sqlite_state_root" appbench)"
printf '%s\n' "$manager_after_verifier_output" | grep -F '"action":"request-approval"' >/dev/null
printf '%s\n' "$manager_after_verifier_output" | grep -F '"approval":"merge-ready"' >/dev/null
printf '%s\n' "$manager_after_verifier_output" | grep -F '"suggestedCommand":["claspc","swarm","approve","<state-root>","repair-2","merge-ready"]' >/dev/null
manager_after_verifier_text="$("$claspc_bin" swarm manager next "$sqlite_state_root" appbench)"
printf '%s\n' "$manager_after_verifier_text" | grep -F 'action: request-approval' >/dev/null
printf '%s\n' "$manager_after_verifier_text" | grep -F 'command: claspc swarm approve <state-root> repair-2 merge-ready' >/dev/null

repair_approval_output="$(CLASP_SWARM_ACTOR=manager "$claspc_bin" --json swarm approve "$sqlite_state_root" repair-2 merge-ready)"
printf '%s\n' "$repair_approval_output" | grep -F '"taskId":"repair-2"' >/dev/null
printf '%s\n' "$repair_approval_output" | grep -F '"name":"merge-ready"' >/dev/null

manager_after_approval_output="$("$claspc_bin" --json swarm manager next "$sqlite_state_root" appbench)"
printf '%s\n' "$manager_after_approval_output" | grep -F '"action":"decide-mergegate"' >/dev/null
printf '%s\n' "$manager_after_approval_output" | grep -F '"mergegateName":"trunk"' >/dev/null
printf '%s\n' "$manager_after_approval_output" | grep -F '"suggestedCommand":["claspc","swarm","mergegate","decide","<state-root>","repair-2","trunk","native-smoke"]' >/dev/null

repair_mergegate_output="$("$claspc_bin" --json swarm mergegate decide "$sqlite_state_root" repair-2 trunk native-smoke)"
printf '%s\n' "$repair_mergegate_output" | grep -F '"taskId":"repair-2"' >/dev/null
printf '%s\n' "$repair_mergegate_output" | grep -F '"verdict":"pass"' >/dev/null

manager_complete_output="$("$claspc_bin" --json swarm manager next "$sqlite_state_root" appbench)"
printf '%s\n' "$manager_complete_output" | grep -F '"action":"objective-complete"' >/dev/null

objective_status_output="$("$claspc_bin" --json swarm objective status "$sqlite_state_root" appbench)"
printf '%s\n' "$objective_status_output" | grep -F '"objectiveId":"appbench"' >/dev/null
printf '%s\n' "$objective_status_output" | grep -F '"taskCount":2' >/dev/null
printf '%s\n' "$objective_status_output" | grep -F '"taskId":"repair-2"' >/dev/null
printf '%s\n' "$objective_status_output" | grep -F '"satisfied":true' >/dev/null

objectives_output="$("$claspc_bin" --json swarm objectives "$sqlite_state_root")"
printf '%s\n' "$objectives_output" | grep -F '"objectiveId":"appbench"' >/dev/null

runs_output="$("$claspc_bin" --json swarm runs "$sqlite_state_root" repair)"
printf '%s\n' "$runs_output" | grep -F '"role":"tool"' >/dev/null
printf '%s\n' "$runs_output" | grep -F '"role":"verifier"' >/dev/null
printf '%s\n' "$runs_output" | grep -F '"name":"native-smoke"' >/dev/null

artifacts_output="$("$claspc_bin" --json swarm artifacts "$sqlite_state_root" repair)"
printf '%s\n' "$artifacts_output" | grep -F '"kind":"stdout"' >/dev/null
printf '%s\n' "$artifacts_output" | grep -F '"kind":"stderr"' >/dev/null
