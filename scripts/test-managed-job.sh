#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
mkdir -p "$tmp_root"
test_root="$(mktemp -d "$tmp_root/test-managed-job.XXXXXX")"
jobs_root="$test_root/jobs"
unrelated_session_pid=""

cleanup() {
  if [[ -n "${unrelated_session_pid:-}" ]]; then
    kill "$unrelated_session_pid" >/dev/null 2>&1 || true
    wait "$unrelated_session_pid" >/dev/null 2>&1 || true
  fi
  if [[ "${CLASP_TEST_KEEP_TMP:-}" == "1" ]]; then
    printf 'kept test root: %s\n' "$test_root" >&2
  else
    rm -rf "$test_root" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

chmod +x "$project_root/scripts/run-managed-job.sh" "$project_root/scripts/stop-managed-job.sh"

wait_for_file() {
  local path="$1"
  for _ in $(seq 1 50); do
    if [[ -f "$path" ]]; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

session_has_members() {
  local sid="$1"
  ps -eo sid= | awk -v want="$sid" '{ gsub(/[[:space:]]/, "", $1); if ($1 == want) found = 1 } END { exit found ? 0 : 1 }'
}

session_has_nonroot_group() {
  local sid="$1"
  local root_pgid="$2"
  ps -eo pgid=,sid= |
    awk -v want_sid="$sid" -v root_pgid="$root_pgid" '
      {
        pgid = $1
        sid = $2
        gsub(/[[:space:]]/, "", pgid)
        gsub(/[[:space:]]/, "", sid)
        if (sid == want_sid && pgid != root_pgid) found = 1
      }
      END { exit found ? 0 : 1 }
    '
}

complete_job_dir="$(
  "$project_root/scripts/run-managed-job.sh" \
    --jobs-root "$jobs_root" \
    --job-id complete-smoke \
    -- bash -c 'printf complete-output; printf complete-error >&2; sleep 0.2; exit 0'
)"
[[ "$complete_job_dir" == "$jobs_root/complete-smoke" ]]
complete_pid="$(tr -d '[:space:]' <"$complete_job_dir/pid")"
wait_for_file "$complete_job_dir/exit-status"
[[ "$(cat "$complete_job_dir/exit-status")" == "0" ]]
[[ "$(cat "$complete_job_dir/status")" == "completed" ]]
[[ "$(cat "$complete_job_dir/stdout.log")" == "complete-output" ]]
[[ "$(cat "$complete_job_dir/stderr.log")" == "complete-error" ]]
"$project_root/scripts/stop-managed-job.sh" --jobs-root "$jobs_root" complete-smoke >"$test_root/completed-stop.out"
grep -F 'managed-job-stop: completed complete-smoke' "$test_root/completed-stop.out" >/dev/null
[[ "$(cat "$complete_job_dir/status")" == "completed" ]]
if kill -0 "$complete_pid" >/dev/null 2>&1; then
  printf 'completed managed job root process still alive: %s\n' "$complete_pid" >&2
  exit 1
fi

failed_job_dir="$(
  "$project_root/scripts/run-managed-job.sh" \
    --jobs-root "$jobs_root" \
    --job-id failed-smoke \
    -- bash -c 'sleep 0.2; exit 7'
)"
[[ "$failed_job_dir" == "$jobs_root/failed-smoke" ]]
wait_for_file "$failed_job_dir/exit-status"
[[ "$(cat "$failed_job_dir/exit-status")" == "7" ]]
[[ "$(cat "$failed_job_dir/status")" == "failed" ]]

job_dir="$(
  "$project_root/scripts/run-managed-job.sh" \
    --jobs-root "$jobs_root" \
    --job-id stop-smoke \
    -- bash -c 'trap "printf terminated >\"$CLASP_MANAGED_JOB_ROOT/terminated.txt\"; exit 0" TERM; while true; do sleep 1; done'
)"

[[ "$job_dir" == "$jobs_root/stop-smoke" ]]
[[ -f "$job_dir/pid" ]]
[[ -f "$job_dir/pgid" ]]
[[ -f "$job_dir/sid" ]]
[[ -f "$job_dir/token" ]]
[[ -f "$job_dir/stop-request-path" ]]
[[ -f "$job_dir/command.txt" ]]

pid="$(tr -d '[:space:]' <"$job_dir/pid")"
pgid="$(tr -d '[:space:]' <"$job_dir/pgid")"
sid="$(tr -d '[:space:]' <"$job_dir/sid")"
self_pgid="$(ps -o pgid= -p "$$" | tr -d '[:space:]')"
self_sid="$(ps -o sid= -p "$$" | tr -d '[:space:]')"

[[ -n "$pid" && -n "$pgid" && -n "$sid" ]]
[[ "$pgid" != "$self_pgid" ]]
[[ "$sid" != "$self_sid" ]]
kill -0 "$pid" >/dev/null

"$project_root/scripts/stop-managed-job.sh" --jobs-root "$jobs_root" stop-smoke >/dev/null
for _ in $(seq 1 50); do
  if ! kill -0 "$pid" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
if kill -0 "$pid" >/dev/null 2>&1; then
  printf 'managed job process still alive after stop: %s\n' "$pid" >&2
  exit 1
fi
[[ "$(cat "$job_dir/status")" == "stopped" ]]
[[ "$(cat "$jobs_root/terminated.txt")" == "terminated" ]]

nested_job_dir="$(
  "$project_root/scripts/run-managed-job.sh" \
    --jobs-root "$jobs_root" \
    --job-id stop-timeout-child-group \
    -- bash -c 'timeout 120s bash -c '"'"'while true; do sleep 1; done'"'"'; status=$?; exit "$status"'
)"

[[ "$nested_job_dir" == "$jobs_root/stop-timeout-child-group" ]]
nested_pid="$(tr -d '[:space:]' <"$nested_job_dir/pid")"
nested_pgid="$(tr -d '[:space:]' <"$nested_job_dir/pgid")"
nested_sid="$(tr -d '[:space:]' <"$nested_job_dir/sid")"

for _ in $(seq 1 50); do
  if session_has_nonroot_group "$nested_sid" "$nested_pgid"; then
    break
  fi
  sleep 0.1
done
if ! session_has_nonroot_group "$nested_sid" "$nested_pgid"; then
  printf 'managed job did not create nested process group under timeout\n' >&2
  ps -eo pid,ppid,pgid,sid,comm,args | awk -v sid="$nested_sid" '$4 == sid { print }' >&2
  "$project_root/scripts/stop-managed-job.sh" --jobs-root "$jobs_root" stop-timeout-child-group >/dev/null || true
  exit 1
fi

"$project_root/scripts/stop-managed-job.sh" --jobs-root "$jobs_root" stop-timeout-child-group >/dev/null
if session_has_members "$nested_sid"; then
  printf 'managed job timeout child group still has session members after stop\n' >&2
  ps -eo pid,ppid,pgid,sid,comm,args | awk -v sid="$nested_sid" '$4 == sid { print }' >&2
  exit 1
fi
if kill -0 "$nested_pid" >/dev/null 2>&1; then
  printf 'managed job root process still alive after nested stop: %s\n' "$nested_pid" >&2
  exit 1
fi
[[ "$(cat "$nested_job_dir/status")" == "stopped" ]]

orphan_job_dir="$(
  "$project_root/scripts/run-managed-job.sh" \
    --jobs-root "$jobs_root" \
    --job-id stop-root-exited-session \
    -- bash -c 'bash -c '"'"'while true; do sleep 1; done'"'"' & sleep 0.3; exit 0'
)"

[[ "$orphan_job_dir" == "$jobs_root/stop-root-exited-session" ]]
orphan_pid="$(tr -d '[:space:]' <"$orphan_job_dir/pid")"
orphan_sid="$(tr -d '[:space:]' <"$orphan_job_dir/sid")"

for _ in $(seq 1 50); do
  if ! kill -0 "$orphan_pid" >/dev/null 2>&1 && session_has_members "$orphan_sid"; then
    break
  fi
  sleep 0.1
done
if kill -0 "$orphan_pid" >/dev/null 2>&1 || ! session_has_members "$orphan_sid"; then
  printf 'managed job did not leave a root-exited session member for stop coverage\n' >&2
  ps -eo pid,ppid,pgid,sid,comm,args | awk -v sid="$orphan_sid" '$4 == sid { print }' >&2
  "$project_root/scripts/stop-managed-job.sh" --jobs-root "$jobs_root" stop-root-exited-session >/dev/null || true
  exit 1
fi

"$project_root/scripts/stop-managed-job.sh" --force-signal --jobs-root "$jobs_root" stop-root-exited-session >"$test_root/orphan-stop.out" 2>"$test_root/orphan-stop.err"
grep -F 'root exited; stopping remaining isolated session members' "$test_root/orphan-stop.err" >/dev/null
if session_has_members "$orphan_sid"; then
  printf 'managed job root-exited session still has members after stop\n' >&2
  ps -eo pid,ppid,pgid,sid,comm,args | awk -v sid="$orphan_sid" '$4 == sid { print }' >&2
  exit 1
fi
[[ "$(cat "$orphan_job_dir/status")" == "stopped" ]]

forged_dir="$jobs_root/forged-current-group"
mkdir -p "$forged_dir"
printf '%s\n' "$$" >"$forged_dir/pid"
printf '%s\n' "$self_pgid" >"$forged_dir/pgid"
printf '%s\n' "$self_sid" >"$forged_dir/sid"
printf '%s\n' "$project_root" >"$forged_dir/cwd"
if "$project_root/scripts/stop-managed-job.sh" --force-signal --jobs-root "$jobs_root" forged-current-group >"$test_root/forged.out" 2>"$test_root/forged.err"; then
  printf 'stop-managed-job unexpectedly accepted current process group metadata\n' >&2
  exit 1
fi
grep -F 'refusing to stop current shell process group/session' "$test_root/forged.err" >/dev/null

forged_outside_dir="$jobs_root/forged-outside-root"
mkdir -p "$forged_outside_dir"
printf '999999\n' >"$forged_outside_dir/pid"
printf '999999\n' >"$forged_outside_dir/pgid"
printf '999999\n' >"$forged_outside_dir/sid"
printf '/tmp\n' >"$forged_outside_dir/cwd"
if "$project_root/scripts/stop-managed-job.sh" --force-signal --jobs-root "$jobs_root" forged-outside-root >"$test_root/outside.out" 2>"$test_root/outside.err"; then
  printf 'stop-managed-job unexpectedly accepted outside-root metadata\n' >&2
  exit 1
fi
grep -F 'refusing job cwd outside project root' "$test_root/outside.err" >/dev/null

setsid bash -c 'while true; do sleep 1; done' &
unrelated_session_pid="$!"
sleep 0.1
unrelated_sid="$(ps -o sid= -p "$unrelated_session_pid" | tr -d '[:space:]')"
unrelated_pgid="$(ps -o pgid= -p "$unrelated_session_pid" | tr -d '[:space:]')"
[[ -n "$unrelated_sid" && -n "$unrelated_pgid" ]]

forged_unmarked_dir="$jobs_root/forged-unmarked-session"
mkdir -p "$forged_unmarked_dir"
printf '999999\n' >"$forged_unmarked_dir/pid"
printf '%s\n' "$unrelated_pgid" >"$forged_unmarked_dir/pgid"
printf '%s\n' "$unrelated_sid" >"$forged_unmarked_dir/sid"
printf '%s\n' "$project_root" >"$forged_unmarked_dir/cwd"
printf 'not-the-session-token\n' >"$forged_unmarked_dir/token"
if "$project_root/scripts/stop-managed-job.sh" --force-signal --jobs-root "$jobs_root" forged-unmarked-session >"$test_root/unmarked.out" 2>"$test_root/unmarked.err"; then
  printf 'stop-managed-job unexpectedly accepted an unmarked foreign session\n' >&2
  exit 1
fi
grep -F 'refusing to stop unmarked session members' "$test_root/unmarked.err" >/dev/null
kill -0 "$unrelated_session_pid" >/dev/null
kill "$unrelated_session_pid" >/dev/null 2>&1 || true
wait "$unrelated_session_pid" >/dev/null 2>&1 || true
unrelated_session_pid=""

printf 'managed-job-ok\n'
