#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
mkdir -p "$tmp_root"
test_root="$(mktemp -d "$tmp_root/test-managed-job.XXXXXX")"
jobs_root="$test_root/jobs"
unrelated_session_pid=""
marked_orphan_pid=""
external_reserve_pid=""
budget_holder_job_dir=""
unmarked_child_sid=""

export CLASP_MANAGED_JOB_REQUIRE_MEMORY_LIMIT=0
export CLASP_MANAGED_JOB_USE_SYSTEMD_SCOPE="${CLASP_MANAGED_JOB_USE_SYSTEMD_SCOPE:-auto}"
export CLASP_MANAGED_JOB_MEMORY_BUDGET_SCOPE=current-root
export CLASP_MANAGED_JOB_KILL_AFTER_SECS="${CLASP_MANAGED_JOB_KILL_AFTER_SECS:-1}"
export CLASP_MANAGED_JOB_CLEANUP_POLL_ITERATIONS="${CLASP_MANAGED_JOB_CLEANUP_POLL_ITERATIONS:-2}"
export CLASP_MANAGED_JOB_CLEANUP_POLL_SLEEP_SECS="${CLASP_MANAGED_JOB_CLEANUP_POLL_SLEEP_SECS:-0.01}"
poll_sleep="${CLASP_TEST_MANAGED_JOB_POLL_SECS:-0.02}"
poll_iterations="${CLASP_TEST_MANAGED_JOB_POLL_ITERATIONS:-250}"
wait_for_file_iterations="${CLASP_TEST_MANAGED_JOB_WAIT_FILE_ITERATIONS:-750}"

cleanup() {
  if [[ -n "${budget_holder_job_dir:-}" && -d "$budget_holder_job_dir" ]]; then
    "$project_root/scripts/stop-managed-job.sh" --jobs-root "$jobs_root" admission-budget-holder >/dev/null 2>&1 || true
  fi
  if [[ -n "${unmarked_child_sid:-}" ]]; then
    current_sid="$(ps -o sid= -p "$$" | tr -d '[:space:]')"
    if [[ "$unmarked_child_sid" != "$current_sid" ]]; then
      while IFS= read -r cleanup_pid; do
        if [[ -n "$cleanup_pid" && "$cleanup_pid" != "$$" ]]; then
          kill "$cleanup_pid" >/dev/null 2>&1 || true
        fi
      done < <(
        ps -eo pid=,sid= |
          awk -v want="$unmarked_child_sid" '
            {
              pid = $1
              sid = $2
              gsub(/[[:space:]]/, "", pid)
              gsub(/[[:space:]]/, "", sid)
              if (sid == want && pid != "") print pid
            }
          '
      )
    fi
  fi
  if [[ -n "${marked_orphan_pid:-}" ]]; then
    kill "$marked_orphan_pid" >/dev/null 2>&1 || true
    wait "$marked_orphan_pid" >/dev/null 2>&1 || true
  fi
  if [[ -n "${external_reserve_pid:-}" ]]; then
    kill "$external_reserve_pid" >/dev/null 2>&1 || true
    wait "$external_reserve_pid" >/dev/null 2>&1 || true
  fi
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

if env -u CLASP_MANAGED_JOB_REQUIRE_MEMORY_LIMIT -u CLASP_MANAGED_JOB_MAX_MEMORY_MB \
  "$project_root/scripts/run-managed-job.sh" \
    --jobs-root "$jobs_root" \
    --job-id unbounded-policy-smoke \
    -- bash -c 'exit 0' >"$test_root/unbounded-policy.out" 2>"$test_root/unbounded-policy.err"; then
  printf 'run-managed-job unexpectedly accepted an unbounded job by default\n' >&2
  exit 1
fi
grep -F 'refusing unbounded job' "$test_root/unbounded-policy.err" >/dev/null
grep -F 'CLASP_MANAGED_JOB_USE_SYSTEMD_SCOPE=auto' "$project_root/scripts/run-managed-job.sh" >/dev/null
grep -F 'systemd-scope-required-unavailable' "$project_root/scripts/run-managed-job.sh" >/dev/null
grep -F 'CLASP_MANAGED_JOB_ADMISSION_LOCK_FILE' "$project_root/scripts/run-managed-job.sh" >/dev/null
grep -F -- '--preflight-only' "$project_root/scripts/run-managed-job.sh" >/dev/null
grep -F 'preflight-passed' "$project_root/scripts/run-managed-job.sh" >/dev/null
grep -F 'preflight-complete' "$project_root/scripts/run-managed-job.sh" >/dev/null
grep -F 'CLASP_MANAGED_JOB_DEFAULT_MIN_AVAILABLE_MEMORY_MB' "$project_root/scripts/run-managed-job.sh" >/dev/null
grep -F 'CLASP_MANAGED_JOB_EXTERNAL_AGENT_RESERVE_MB' "$project_root/scripts/run-managed-job.sh" >/dev/null
grep -F 'CLASP_MANAGED_JOB_EXTERNAL_AGENT_PROCESS_NAMES' "$project_root/scripts/run-managed-job.sh" >/dev/null
grep -F 'CLASP_MANAGED_JOB_MEMORY_BUDGET_SCOPE' "$project_root/scripts/run-managed-job.sh" >/dev/null
grep -F 'live_external_agent_process_count' "$project_root/scripts/run-managed-job.sh" >/dev/null
grep -F 'live_external_agent_rss_mb' "$project_root/scripts/run-managed-job.sh" >/dev/null
grep -F 'external_agent_reserved_memory_mb' "$project_root/scripts/run-managed-job.sh" >/dev/null
grep -F 'collectively spend all host memory' "$project_root/scripts/run-managed-job.sh" >/dev/null
grep -F 'live_managed_memory_budget_mb' "$project_root/scripts/run-managed-job.sh" >/dev/null
grep -F 'runtime watcher preserves the declared memory budget' "$project_root/scripts/run-managed-job.sh" >/dev/null
grep -F 'phase=watch' "$project_root/scripts/run-managed-job.sh" >/dev/null
grep -F 'CLASP_MANAGED_JOB_MIN_AVAILABLE_DISK_MB' "$project_root/scripts/run-managed-job.sh" >/dev/null
grep -F 'CLASP_MANAGED_JOB_MIN_DISK_HEADROOM_MB' "$project_root/scripts/run-managed-job.sh" >/dev/null
grep -F 'preflight_host_disk_reserve' "$project_root/scripts/run-managed-job.sh" >/dev/null
grep -F 'disk-exceeded' "$project_root/scripts/run-managed-job.sh" >/dev/null
grep -F 'refusing force-signal with unmarked session members' "$project_root/scripts/stop-managed-job.sh" >/dev/null
grep -F 'force-signal is exact-marker-only' "$project_root/scripts/stop-managed-job.sh" >/dev/null
grep -F 'memory-exceeded|disk-exceeded|memory-enforcer-unavailable|admission-lock-unavailable' "$project_root/scripts/stop-managed-job.sh" >/dev/null
! grep -F 'signal_validated_session_pids' "$project_root/scripts/stop-managed-job.sh" >/dev/null

if CLASP_MANAGED_JOB_MAX_MEMORY_MB=128 \
  "$project_root/scripts/run-managed-job.sh" \
    --jobs-root "$jobs_root" \
    --job-id max-memory-policy-smoke \
    --memory-mb 256 \
    -- bash -c 'exit 0' >"$test_root/max-memory-policy.out" 2>"$test_root/max-memory-policy.err"; then
  printf 'run-managed-job unexpectedly accepted a job above the configured memory ceiling\n' >&2
  exit 1
fi
grep -F 'exceeds CLASP_MANAGED_JOB_MAX_MEMORY_MB=128' "$test_root/max-memory-policy.err" >/dev/null

if CLASP_MANAGED_JOB_DEFAULT_MIN_AVAILABLE_MEMORY_MB=invalid \
  "$project_root/scripts/run-managed-job.sh" \
    --jobs-root "$jobs_root" \
    --job-id invalid-default-memory-reserve \
    --memory-mb 128 \
    -- bash -c 'exit 0' >"$test_root/invalid-default-memory-reserve.out" 2>"$test_root/invalid-default-memory-reserve.err"; then
  printf 'run-managed-job unexpectedly accepted an invalid default host-memory reserve\n' >&2
  exit 1
fi
grep -F 'invalid CLASP_MANAGED_JOB_DEFAULT_MIN_AVAILABLE_MEMORY_MB' "$test_root/invalid-default-memory-reserve.err" >/dev/null

if CLASP_MANAGED_JOB_EXTERNAL_AGENT_RESERVE_MB=invalid \
  "$project_root/scripts/run-managed-job.sh" \
    --jobs-root "$jobs_root" \
    --job-id invalid-external-agent-reserve \
    --memory-mb 128 \
    -- bash -c 'exit 0' >"$test_root/invalid-external-agent-reserve.out" 2>"$test_root/invalid-external-agent-reserve.err"; then
  printf 'run-managed-job unexpectedly accepted an invalid external-agent reserve\n' >&2
  exit 1
fi
grep -F 'invalid CLASP_MANAGED_JOB_EXTERNAL_AGENT_RESERVE_MB' "$test_root/invalid-external-agent-reserve.err" >/dev/null

if CLASP_MANAGED_JOB_MEMORY_BUDGET_SCOPE=invalid \
  "$project_root/scripts/run-managed-job.sh" \
    --jobs-root "$jobs_root" \
    --job-id invalid-memory-budget-scope \
    --memory-mb 128 \
    -- bash -c 'exit 0' >"$test_root/invalid-memory-budget-scope.out" 2>"$test_root/invalid-memory-budget-scope.err"; then
  printf 'run-managed-job unexpectedly accepted an invalid memory-budget scope\n' >&2
  exit 1
fi
grep -F 'invalid CLASP_MANAGED_JOB_MEMORY_BUDGET_SCOPE' "$test_root/invalid-memory-budget-scope.err" >/dev/null

wait_for_file() {
  local path="$1"
  for _ in $(seq 1 "$wait_for_file_iterations"); do
    if [[ -f "$path" ]]; then
      return 0
    fi
    sleep "$poll_sleep"
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

session_has_unmarked_member() {
  local sid="$1"
  local candidate_pid

  while IFS= read -r candidate_pid; do
    if [[ -n "$candidate_pid" && "$candidate_pid" != "$$" && -r "/proc/$candidate_pid/environ" ]]; then
      if ! tr '\0' '\n' <"/proc/$candidate_pid/environ" | grep -F 'CLASP_MANAGED_JOB_ID=' >/dev/null; then
        return 0
      fi
    fi
  done < <(
    ps -eo pid=,sid= |
      awk -v want="$sid" '
        {
          pid = $1
          sid = $2
          gsub(/[[:space:]]/, "", pid)
          gsub(/[[:space:]]/, "", sid)
          if (sid == want && pid != "") print pid
        }
      '
  )

  return 1
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
if CLASP_MANAGED_JOB_KILL_AFTER_SECS=not-a-number \
  "$project_root/scripts/stop-managed-job.sh" --jobs-root "$jobs_root" complete-smoke >"$test_root/invalid-kill-after.out" 2>"$test_root/invalid-kill-after.err"; then
  printf 'stop-managed-job unexpectedly accepted invalid CLASP_MANAGED_JOB_KILL_AFTER_SECS\n' >&2
  exit 1
fi
grep -F 'invalid CLASP_MANAGED_JOB_KILL_AFTER_SECS' "$test_root/invalid-kill-after.err" >/dev/null
if kill -0 "$complete_pid" >/dev/null 2>&1; then
  printf 'completed managed job root process still alive: %s\n' "$complete_pid" >&2
  exit 1
fi

instant_job_dir="$(
  "$project_root/scripts/run-managed-job.sh" \
    --jobs-root "$jobs_root" \
    --job-id instant-complete-smoke \
    -- bash -c 'printf instant-output; exit 0'
)"
[[ "$instant_job_dir" == "$jobs_root/instant-complete-smoke" ]]
wait_for_file "$instant_job_dir/exit-status"
[[ "$(cat "$instant_job_dir/exit-status")" == "0" ]]
[[ "$(cat "$instant_job_dir/status")" == "completed" ]]
[[ "$(cat "$instant_job_dir/stdout.log")" == "instant-output" ]]
for required in pid pgid sid cwd started-at; do
  [[ -f "$instant_job_dir/$required" ]]
done
"$project_root/scripts/stop-managed-job.sh" --jobs-root "$jobs_root" instant-complete-smoke >"$test_root/instant-completed-stop.out"
grep -F 'managed-job-stop: completed instant-complete-smoke' "$test_root/instant-completed-stop.out" >/dev/null

guard_terminal_dir="$jobs_root/guard-terminal-memory"
mkdir -p "$guard_terminal_dir"
printf '999999\n' >"$guard_terminal_dir/pid"
printf '999999\n' >"$guard_terminal_dir/pgid"
printf '999999\n' >"$guard_terminal_dir/sid"
printf '%s\n' "$project_root" >"$guard_terminal_dir/cwd"
printf '137\n' >"$guard_terminal_dir/exit-status"
printf 'memory-exceeded\n' >"$guard_terminal_dir/status"
"$project_root/scripts/stop-managed-job.sh" --jobs-root "$jobs_root" guard-terminal-memory >"$test_root/guard-terminal-memory-stop.out"
grep -F 'managed-job-stop: memory-exceeded guard-terminal-memory' "$test_root/guard-terminal-memory-stop.out" >/dev/null
[[ "$(cat "$guard_terminal_dir/status")" == "memory-exceeded" ]]
[[ ! -f "$guard_terminal_dir/stop-request" ]]

if (ulimit -v 262144) >/dev/null 2>&1; then
  inherited_limit_job_dir="$(
    (
      ulimit -v 262144
      CLASP_MANAGED_JOB_USE_SYSTEMD_SCOPE=never \
        "$project_root/scripts/run-managed-job.sh" \
          --jobs-root "$jobs_root" \
          --job-id inherited-memory-limit-smoke \
          --memory-mb 512 \
          -- bash -c 'printf inherited-limit-output'
    )
  )"
  [[ "$inherited_limit_job_dir" == "$jobs_root/inherited-memory-limit-smoke" ]]
  wait_for_file "$inherited_limit_job_dir/exit-status"
  [[ "$(cat "$inherited_limit_job_dir/exit-status")" == "0" ]]
  [[ "$(cat "$inherited_limit_job_dir/status")" == "completed" ]]
  [[ "$(cat "$inherited_limit_job_dir/stdout.log")" == "inherited-limit-output" ]]
  [[ "$(cat "$inherited_limit_job_dir/effective-memory-mb")" == "256" ]]
  grep -F 'requested_mb=512' "$inherited_limit_job_dir/inherited-memory-limit" >/dev/null
fi

default_reserve_job_dir="$(
  CLASP_MANAGED_JOB_DEFAULT_MIN_AVAILABLE_MEMORY_MB=1 \
  CLASP_MANAGED_JOB_USE_SYSTEMD_SCOPE=never \
    "$project_root/scripts/run-managed-job.sh" \
      --jobs-root "$jobs_root" \
      --job-id default-host-memory-reserve \
      --memory-mb 128 \
      -- bash -c 'printf default-reserve'
)"
[[ "$default_reserve_job_dir" == "$jobs_root/default-host-memory-reserve" ]]
wait_for_file "$default_reserve_job_dir/exit-status"
[[ "$(cat "$default_reserve_job_dir/exit-status")" == "0" ]]
[[ "$(cat "$default_reserve_job_dir/status")" == "completed" ]]
[[ "$(cat "$default_reserve_job_dir/min-available-memory-mb")" == "1" ]]
[[ "$(cat "$default_reserve_job_dir/stdout.log")" == "default-reserve" ]]

disabled_default_reserve_job_dir="$(
  CLASP_MANAGED_JOB_DEFAULT_MIN_AVAILABLE_MEMORY_MB=0 \
  CLASP_MANAGED_JOB_USE_SYSTEMD_SCOPE=never \
    "$project_root/scripts/run-managed-job.sh" \
      --jobs-root "$jobs_root" \
      --job-id disabled-default-host-memory-reserve \
      --memory-mb 128 \
      -- bash -c 'printf disabled-default-reserve'
)"
[[ "$disabled_default_reserve_job_dir" == "$jobs_root/disabled-default-host-memory-reserve" ]]
wait_for_file "$disabled_default_reserve_job_dir/exit-status"
[[ "$(cat "$disabled_default_reserve_job_dir/exit-status")" == "0" ]]
[[ "$(cat "$disabled_default_reserve_job_dir/status")" == "completed" ]]
[[ ! -f "$disabled_default_reserve_job_dir/min-available-memory-mb" ]]
[[ "$(cat "$disabled_default_reserve_job_dir/stdout.log")" == "disabled-default-reserve" ]]

preflight_only_job_dir="$(
  CLASP_MANAGED_JOB_DEFAULT_MIN_AVAILABLE_MEMORY_MB=1 \
  CLASP_MANAGED_JOB_EXTERNAL_AGENT_RESERVE_MB=0 \
  CLASP_MANAGED_JOB_USE_SYSTEMD_SCOPE=never \
    "$project_root/scripts/run-managed-job.sh" \
      --jobs-root "$jobs_root" \
      --job-id preflight-only-smoke \
      --preflight-only \
      --memory-mb 128 \
      -- bash -c 'printf should-not-run'
)"
[[ "$preflight_only_job_dir" == "$jobs_root/preflight-only-smoke" ]]
wait_for_file "$preflight_only_job_dir/exit-status"
[[ "$(cat "$preflight_only_job_dir/exit-status")" == "0" ]]
[[ "$(cat "$preflight_only_job_dir/status")" == "completed" ]]
[[ "$(cat "$preflight_only_job_dir/min-available-memory-mb")" == "1" ]]
[[ -f "$preflight_only_job_dir/preflight-passed" ]]
[[ "$(cat "$preflight_only_job_dir/stdout.log")" == "" ]]
[[ "$(cat "$preflight_only_job_dir/stderr.log")" == "" ]]

marked_orphan_pid_file="$test_root/marked-orphan.pid"
marked_orphan_job_dir="$(
  CLASP_MANAGED_JOB_USE_SYSTEMD_SCOPE=never \
    "$project_root/scripts/run-managed-job.sh" \
      --jobs-root "$jobs_root" \
      --job-id marked-orphan-cleanup \
      --memory-mb 128 \
      -- bash -c 'setsid bash -c '"'"'printf "%s\n" "$BASHPID" >"$1"; while true; do sleep 1; done'"'"' _ "$1" & sleep 0.3; exit 0' _ "$marked_orphan_pid_file"
)"
[[ "$marked_orphan_job_dir" == "$jobs_root/marked-orphan-cleanup" ]]
wait_for_file "$marked_orphan_job_dir/exit-status"
wait_for_file "$marked_orphan_pid_file"
[[ "$(cat "$marked_orphan_job_dir/exit-status")" == "0" ]]
[[ "$(cat "$marked_orphan_job_dir/status")" == "completed" ]]
marked_orphan_pid="$(tr -d '[:space:]' <"$marked_orphan_pid_file")"
for _ in $(seq 1 "$poll_iterations"); do
  if ! kill -0 "$marked_orphan_pid" >/dev/null 2>&1; then
    break
  fi
  sleep "$poll_sleep"
done
if kill -0 "$marked_orphan_pid" >/dev/null 2>&1; then
  printf 'marked managed orphan survived normal job completion cleanup: %s\n' "$marked_orphan_pid" >&2
  exit 1
fi
"$project_root/scripts/stop-managed-job.sh" --jobs-root "$jobs_root" marked-orphan-cleanup >"$test_root/marked-orphan-stop.out"
grep -F 'managed-job-stop: completed marked-orphan-cleanup' "$test_root/marked-orphan-stop.out" >/dev/null
marked_orphan_pid=""

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

core_limit_job_dir="$(
  "$project_root/scripts/run-managed-job.sh" \
    --jobs-root "$jobs_root" \
    --job-id core-limit-smoke \
    -- bash -c 'ulimit -c; sleep 0.2'
)"
[[ "$core_limit_job_dir" == "$jobs_root/core-limit-smoke" ]]
wait_for_file "$core_limit_job_dir/exit-status"
[[ "$(cat "$core_limit_job_dir/exit-status")" == "0" ]]
[[ "$(cat "$core_limit_job_dir/status")" == "completed" ]]
[[ "$(tr -d '[:space:]' <"$core_limit_job_dir/stdout.log")" == "0" ]]

no_inherit_job_dir="$(
  CLASP_MANAGED_JOB_MEMORY_MB=64 \
  CLASP_MANAGED_JOB_MIN_AVAILABLE_MEMORY_MB=64 \
    "$project_root/scripts/run-managed-job.sh" \
      --jobs-root "$jobs_root" \
      --job-id memory-env-no-inherit \
      -- bash -c 'sleep 0.2; exit 0'
)"
[[ "$no_inherit_job_dir" == "$jobs_root/memory-env-no-inherit" ]]
wait_for_file "$no_inherit_job_dir/exit-status"
[[ "$(cat "$no_inherit_job_dir/exit-status")" == "0" ]]
[[ ! -f "$no_inherit_job_dir/memory-mb" ]]
[[ ! -f "$no_inherit_job_dir/min-available-memory-mb" ]]

admission_lock_directory="$test_root/admission-lock-as-directory"
mkdir -p "$admission_lock_directory"
admission_lock_unavailable_job_dir="$(
  CLASP_MANAGED_JOB_ADMISSION_LOCK_FILE="$admission_lock_directory" \
    "$project_root/scripts/run-managed-job.sh" \
      --jobs-root "$jobs_root" \
      --job-id admission-lock-unavailable-smoke \
      --min-available-memory-mb 1 \
      -- bash -c 'printf should-not-run'
)"
[[ "$admission_lock_unavailable_job_dir" == "$jobs_root/admission-lock-unavailable-smoke" ]]
wait_for_file "$admission_lock_unavailable_job_dir/exit-status"
[[ "$(cat "$admission_lock_unavailable_job_dir/exit-status")" == "125" ]]
[[ "$(cat "$admission_lock_unavailable_job_dir/status")" == "admission-lock-unavailable" ]]
grep -F 'reason=admission-lock-open-failed' "$admission_lock_unavailable_job_dir/admission-error" >/dev/null
grep -F "lock_file=$admission_lock_directory" "$admission_lock_unavailable_job_dir/admission-error" >/dev/null
[[ "$(cat "$admission_lock_unavailable_job_dir/stdout.log")" == "" ]]

host_reserve_started="$test_root/host-reserve-started"
host_reserve_job_dir="$(
  "$project_root/scripts/run-managed-job.sh" \
    --jobs-root "$jobs_root" \
    --job-id host-reserve-smoke \
    --min-available-memory-mb 999999999 \
    -- bash -c 'printf started >"$1"; while true; do sleep 1; done' _ "$host_reserve_started"
)"
[[ "$host_reserve_job_dir" == "$jobs_root/host-reserve-smoke" ]]
host_reserve_sid="$(tr -d '[:space:]' <"$host_reserve_job_dir/sid")"
wait_for_file "$host_reserve_job_dir/exit-status"
[[ "$(cat "$host_reserve_job_dir/exit-status")" == "137" ]]
[[ "$(cat "$host_reserve_job_dir/status")" == "memory-exceeded" ]]
[[ "$(cat "$host_reserve_job_dir/min-available-memory-mb")" == "999999999" ]]
[[ ! -e "$host_reserve_started" ]]
grep -F 'min_available_memory_mb=999999999' "$host_reserve_job_dir/memory-exceeded" >/dev/null
grep -F 'available_memory_mb=' "$host_reserve_job_dir/memory-exceeded" >/dev/null
grep -F 'reason=host-available-memory-reserve' "$host_reserve_job_dir/memory-exceeded" >/dev/null
grep -F 'phase=preflight' "$host_reserve_job_dir/memory-exceeded" >/dev/null
for _ in $(seq 1 "$poll_iterations"); do
  if ! session_has_members "$host_reserve_sid"; then
    break
  fi
  sleep "$poll_sleep"
done
if session_has_members "$host_reserve_sid"; then
  printf 'host-reserve managed job still has session members\n' >&2
  ps -eo pid,ppid,pgid,sid,rss,comm,args | awk -v sid="$host_reserve_sid" '$4 == sid { print }' >&2
  exit 1
fi

sleep 30 &
external_reserve_pid="$!"
external_agent_reserve_started="$test_root/external-agent-reserve-started"
external_agent_reserve_job_dir="$(
  CLASP_MANAGED_JOB_EXTERNAL_AGENT_PROCESS_NAMES=sleep \
  CLASP_MANAGED_JOB_EXTERNAL_AGENT_RESERVE_MB=999999999 \
    "$project_root/scripts/run-managed-job.sh" \
      --jobs-root "$jobs_root" \
      --job-id external-agent-reserve-smoke \
      --min-available-memory-mb 1 \
      -- bash -c 'printf started >"$1"; while true; do sleep 1; done' _ "$external_agent_reserve_started"
)"
[[ "$external_agent_reserve_job_dir" == "$jobs_root/external-agent-reserve-smoke" ]]
external_agent_reserve_sid="$(tr -d '[:space:]' <"$external_agent_reserve_job_dir/sid")"
wait_for_file "$external_agent_reserve_job_dir/exit-status"
[[ "$(cat "$external_agent_reserve_job_dir/exit-status")" == "137" ]]
[[ "$(cat "$external_agent_reserve_job_dir/status")" == "memory-exceeded" ]]
[[ "$(cat "$external_agent_reserve_job_dir/min-available-memory-mb")" == "1" ]]
[[ "$(cat "$external_agent_reserve_job_dir/external-agent-reserve-mb")" == "999999999" ]]
[[ "$(cat "$external_agent_reserve_job_dir/external-agent-process-names")" == "sleep" ]]
[[ ! -e "$external_agent_reserve_started" ]]
grep -F 'external_agent_process_names=sleep' "$external_agent_reserve_job_dir/memory-exceeded" >/dev/null
external_agent_count="$(awk -F= '$1 == "external_agent_process_count" { print $2; exit }' "$external_agent_reserve_job_dir/memory-exceeded")"
external_agent_rss="$(awk -F= '$1 == "external_agent_rss_mb" { print $2; exit }' "$external_agent_reserve_job_dir/memory-exceeded")"
external_agent_reserved="$(awk -F= '$1 == "external_agent_reserved_memory_mb" { print $2; exit }' "$external_agent_reserve_job_dir/memory-exceeded")"
[[ "$external_agent_count" =~ ^[0-9]+$ && "$external_agent_count" -ge 1 ]]
[[ "$external_agent_rss" =~ ^[0-9]+$ && "$external_agent_rss" -ge 0 ]]
[[ "$external_agent_reserved" =~ ^[0-9]+$ && "$external_agent_reserved" -ge 999999999 ]]
grep -F 'reason=host-available-memory-reserve' "$external_agent_reserve_job_dir/memory-exceeded" >/dev/null
grep -F 'phase=preflight' "$external_agent_reserve_job_dir/memory-exceeded" >/dev/null
for _ in $(seq 1 "$poll_iterations"); do
  if ! session_has_members "$external_agent_reserve_sid"; then
    break
  fi
  sleep "$poll_sleep"
done
if session_has_members "$external_agent_reserve_sid"; then
  printf 'external-agent-reserve managed job still has session members\n' >&2
  ps -eo pid,ppid,pgid,sid,rss,comm,args | awk -v sid="$external_agent_reserve_sid" '$4 == sid { print }' >&2
  exit 1
fi
kill "$external_reserve_pid" >/dev/null 2>&1 || true
wait "$external_reserve_pid" >/dev/null 2>&1 || true
external_reserve_pid=""

disk_reserve_started="$test_root/disk-reserve-started"
disk_reserve_job_dir="$(
  "$project_root/scripts/run-managed-job.sh" \
    --jobs-root "$jobs_root" \
    --job-id host-disk-reserve-smoke \
    --min-available-disk-mb 999999999 \
    --disk-reserve-path "$project_root" \
    -- bash -c 'printf started >"$1"; while true; do sleep 1; done' _ "$disk_reserve_started"
)"
[[ "$disk_reserve_job_dir" == "$jobs_root/host-disk-reserve-smoke" ]]
disk_reserve_sid="$(tr -d '[:space:]' <"$disk_reserve_job_dir/sid")"
wait_for_file "$disk_reserve_job_dir/exit-status"
[[ "$(cat "$disk_reserve_job_dir/exit-status")" == "123" ]]
[[ "$(cat "$disk_reserve_job_dir/status")" == "disk-exceeded" ]]
[[ "$(cat "$disk_reserve_job_dir/min-available-disk-mb")" == "999999999" ]]
[[ "$(cat "$disk_reserve_job_dir/disk-reserve-path")" == "$project_root" ]]
[[ ! -e "$disk_reserve_started" ]]
grep -F 'min_available_disk_mb=999999999' "$disk_reserve_job_dir/disk-exceeded" >/dev/null
grep -F 'available_disk_mb=' "$disk_reserve_job_dir/disk-exceeded" >/dev/null
grep -F 'disk_reserve_path='"$project_root" "$disk_reserve_job_dir/disk-exceeded" >/dev/null
grep -F 'reason=host-available-disk-reserve' "$disk_reserve_job_dir/disk-exceeded" >/dev/null
grep -F 'phase=preflight' "$disk_reserve_job_dir/disk-exceeded" >/dev/null
grep -F 'recovery_command=bash scripts/clasp-clean-generated-state.sh --health --json --include-run-binary-cache --include-temp-caches --include-build-caches' "$disk_reserve_job_dir/disk-exceeded" >/dev/null
grep -F 'recovery_apply_command=bash scripts/clasp-clean-generated-state.sh --apply --include-run-binary-cache --include-temp-caches --include-build-caches' "$disk_reserve_job_dir/disk-exceeded" >/dev/null
grep -F 'recovery_note=inspect the health report' "$disk_reserve_job_dir/disk-exceeded" >/dev/null
for _ in $(seq 1 "$poll_iterations"); do
  if ! session_has_members "$disk_reserve_sid"; then
    break
  fi
  sleep "$poll_sleep"
done
if session_has_members "$disk_reserve_sid"; then
  printf 'disk-reserve managed job still has session members\n' >&2
  ps -eo pid,ppid,pgid,sid,rss,comm,args | awk -v sid="$disk_reserve_sid" '$4 == sid { print }' >&2
  exit 1
fi

disk_reserve_ok_job_dir="$(
  "$project_root/scripts/run-managed-job.sh" \
    --jobs-root "$jobs_root" \
    --job-id host-disk-reserve-ok-smoke \
    --min-available-disk-mb 1 \
    --disk-reserve-path "$project_root" \
    -- bash -c 'printf disk-ok'
)"
[[ "$disk_reserve_ok_job_dir" == "$jobs_root/host-disk-reserve-ok-smoke" ]]
wait_for_file "$disk_reserve_ok_job_dir/exit-status"
[[ "$(cat "$disk_reserve_ok_job_dir/exit-status")" == "0" ]]
[[ "$(cat "$disk_reserve_ok_job_dir/status")" == "completed" ]]
[[ "$(cat "$disk_reserve_ok_job_dir/stdout.log")" == "disk-ok" ]]

disk_headroom_started="$test_root/disk-headroom-started"
disk_headroom_job_dir="$(
  "$project_root/scripts/run-managed-job.sh" \
    --jobs-root "$jobs_root" \
    --job-id host-disk-headroom-smoke \
    --min-available-disk-mb 1 \
    --min-disk-headroom-mb 999999999 \
    --disk-reserve-path "$project_root" \
    -- bash -c 'printf started >"$1"; while true; do sleep 1; done' _ "$disk_headroom_started"
)"
[[ "$disk_headroom_job_dir" == "$jobs_root/host-disk-headroom-smoke" ]]
disk_headroom_sid="$(tr -d '[:space:]' <"$disk_headroom_job_dir/sid")"
wait_for_file "$disk_headroom_job_dir/exit-status"
[[ "$(cat "$disk_headroom_job_dir/exit-status")" == "123" ]]
[[ "$(cat "$disk_headroom_job_dir/status")" == "disk-exceeded" ]]
[[ "$(cat "$disk_headroom_job_dir/min-available-disk-mb")" == "1" ]]
[[ "$(cat "$disk_headroom_job_dir/min-disk-headroom-mb")" == "999999999" ]]
[[ "$(cat "$disk_headroom_job_dir/disk-reserve-path")" == "$project_root" ]]
[[ ! -e "$disk_headroom_started" ]]
grep -F 'min_available_disk_mb=1' "$disk_headroom_job_dir/disk-exceeded" >/dev/null
grep -F 'min_disk_headroom_mb=999999999' "$disk_headroom_job_dir/disk-exceeded" >/dev/null
grep -F 'available_disk_mb=' "$disk_headroom_job_dir/disk-exceeded" >/dev/null
grep -F 'disk_headroom_mb=' "$disk_headroom_job_dir/disk-exceeded" >/dev/null
grep -F 'reason=host-available-disk-headroom' "$disk_headroom_job_dir/disk-exceeded" >/dev/null
grep -F 'phase=preflight' "$disk_headroom_job_dir/disk-exceeded" >/dev/null
grep -F 'recovery_command=bash scripts/clasp-clean-generated-state.sh --health --json --include-run-binary-cache --include-temp-caches --include-build-caches' "$disk_headroom_job_dir/disk-exceeded" >/dev/null
grep -F 'recovery_apply_command=bash scripts/clasp-clean-generated-state.sh --apply --include-run-binary-cache --include-temp-caches --include-build-caches' "$disk_headroom_job_dir/disk-exceeded" >/dev/null
grep -F 'recovery_note=inspect the health report' "$disk_headroom_job_dir/disk-exceeded" >/dev/null
for _ in $(seq 1 "$poll_iterations"); do
  if ! session_has_members "$disk_headroom_sid"; then
    break
  fi
  sleep "$poll_sleep"
done
if session_has_members "$disk_headroom_sid"; then
  printf 'disk-headroom managed job still has session members\n' >&2
  ps -eo pid,ppid,pgid,sid,rss,comm,args | awk -v sid="$disk_headroom_sid" '$4 == sid { print }' >&2
  exit 1
fi

budget_holder_job_dir="$(
  CLASP_MANAGED_JOB_DEFAULT_MIN_AVAILABLE_MEMORY_MB=0 \
  CLASP_MANAGED_JOB_USE_SYSTEMD_SCOPE=never \
    "$project_root/scripts/run-managed-job.sh" \
      --jobs-root "$jobs_root" \
      --job-id admission-budget-holder \
      --memory-mb 128 \
      -- bash -c 'trap "exit 0" TERM; while true; do sleep 1; done'
)"
[[ "$budget_holder_job_dir" == "$jobs_root/admission-budget-holder" ]]
wait_for_file "$budget_holder_job_dir/pid"
budget_holder_pid="$(tr -d '[:space:]' <"$budget_holder_job_dir/pid")"
for _ in $(seq 1 "$poll_iterations"); do
  if kill -0 "$budget_holder_pid" >/dev/null 2>&1 &&
     [[ -f "$budget_holder_job_dir/admission-lock" ]] &&
     [[ "$(sed -n '1p' "$budget_holder_job_dir/status")" == "started" ]]; then
    break
  fi
  sleep "$poll_sleep"
done
kill -0 "$budget_holder_pid" >/dev/null
[[ -f "$budget_holder_job_dir/admission-lock" ]]

headroom_started="$test_root/headroom-started"
headroom_job_dir="$(
  CLASP_MANAGED_JOB_MAX_MEMORY_MB=0 \
    "$project_root/scripts/run-managed-job.sh" \
    --jobs-root "$jobs_root" \
    --job-id host-reserve-headroom-smoke \
    --memory-mb 999999999 \
    --min-available-memory-mb 1 \
    -- bash -c 'printf started >"$1"; while true; do sleep 1; done' _ "$headroom_started"
)"
[[ "$headroom_job_dir" == "$jobs_root/host-reserve-headroom-smoke" ]]
headroom_sid="$(tr -d '[:space:]' <"$headroom_job_dir/sid")"
wait_for_file "$headroom_job_dir/exit-status"
[[ "$(cat "$headroom_job_dir/exit-status")" == "137" ]]
[[ "$(cat "$headroom_job_dir/status")" == "memory-exceeded" ]]
[[ "$(cat "$headroom_job_dir/memory-mb")" == "999999999" ]]
[[ "$(cat "$headroom_job_dir/min-available-memory-mb")" == "1" ]]
[[ ! -e "$headroom_started" ]]
grep -F 'min_available_memory_mb=1' "$headroom_job_dir/memory-exceeded" >/dev/null
grep -F 'memory_mb=999999999' "$headroom_job_dir/memory-exceeded" >/dev/null
headroom_running_budget="$(awk -F= '$1 == "running_managed_memory_budget_mb" { print $2; exit }' "$headroom_job_dir/memory-exceeded")"
headroom_required_available="$(awk -F= '$1 == "required_available_memory_mb" { print $2; exit }' "$headroom_job_dir/memory-exceeded")"
[[ "$headroom_running_budget" =~ ^[0-9]+$ && "$headroom_running_budget" -ge 128 ]]
[[ "$headroom_required_available" =~ ^[0-9]+$ && "$headroom_required_available" -ge 1000000128 ]]
grep -F 'reason=host-available-memory-reserve' "$headroom_job_dir/memory-exceeded" >/dev/null
grep -F 'phase=preflight' "$headroom_job_dir/memory-exceeded" >/dev/null
for _ in $(seq 1 "$poll_iterations"); do
  if ! session_has_members "$headroom_sid"; then
    break
  fi
  sleep "$poll_sleep"
done
if session_has_members "$headroom_sid"; then
  printf 'host-reserve headroom managed job still has session members\n' >&2
  ps -eo pid,ppid,pgid,sid,rss,comm,args | awk -v sid="$headroom_sid" '$4 == sid { print }' >&2
  exit 1
fi
"$project_root/scripts/stop-managed-job.sh" --jobs-root "$jobs_root" admission-budget-holder >/dev/null
budget_holder_job_dir=""
if kill -0 "$budget_holder_pid" >/dev/null 2>&1; then
  printf 'admission budget holder survived stop: %s\n' "$budget_holder_pid" >&2
  exit 1
fi

nested_parent_child_job_file="$test_root/nested-parent-child-job"
nested_parent_job_dir="$(
  CLASP_MANAGED_JOB_EXTERNAL_AGENT_RESERVE_MB=0 \
  CLASP_MANAGED_JOB_USE_SYSTEMD_SCOPE=never \
    "$project_root/scripts/run-managed-job.sh" \
      --jobs-root "$jobs_root" \
      --job-id nested-parent-budget-parent \
      --memory-mb 1024 \
      --min-available-memory-mb 1 \
      -- bash -c 'set -euo pipefail
        child_job_file="$1"
        jobs_root="$2"
        project_root="$3"
        available_mb="$(awk '"'"'/MemAvailable:/ { printf "%d\n", int($2 / 1024); found = 1 } END { if (!found) print 0 }'"'"' /proc/meminfo)"
        if (( available_mb > 1024 )); then
          child_min_available_mb="$((available_mb - 512))"
        else
          child_min_available_mb=1
        fi
        child_job_dir="$(
          CLASP_MANAGED_JOB_USE_SYSTEMD_SCOPE=never \
            "$project_root/scripts/run-managed-job.sh" \
              --jobs-root "$jobs_root" \
              --job-id nested-parent-budget-child \
              --memory-mb 128 \
              --min-available-memory-mb "$child_min_available_mb" \
              -- bash -c '"'"'printf nested-child-ok'"'"'
        )"
        printf "%s\n" "$child_job_dir" >"$child_job_file"
        for _ in $(seq 1 250); do
          [[ -f "$child_job_dir/exit-status" ]] && break
          sleep 0.02
        done
        [[ "$(cat "$child_job_dir/exit-status")" == "0" ]]
        [[ "$(cat "$child_job_dir/status")" == "completed" ]]
        [[ "$(cat "$child_job_dir/stdout.log")" == "nested-child-ok" ]]
      ' _ "$nested_parent_child_job_file" "$jobs_root" "$project_root"
)"
[[ "$nested_parent_job_dir" == "$jobs_root/nested-parent-budget-parent" ]]
wait_for_file "$nested_parent_job_dir/exit-status"
[[ "$(cat "$nested_parent_job_dir/exit-status")" == "0" ]]
[[ "$(cat "$nested_parent_job_dir/status")" == "completed" ]]
wait_for_file "$nested_parent_child_job_file"
nested_child_job_dir="$(sed -n '1p' "$nested_parent_child_job_file")"
[[ "$nested_child_job_dir" == "$jobs_root/nested-parent-budget-child" ]]
[[ "$(cat "$nested_child_job_dir/exit-status")" == "0" ]]
[[ "$(cat "$nested_child_job_dir/stdout.log")" == "nested-child-ok" ]]

if command -v cc >/dev/null 2>&1; then
  cat >"$test_root/hold-memory.c" <<'EOF'
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv) {
  size_t mb = argc > 1 ? strtoull(argv[1], 0, 10) : 64;
  size_t bytes = mb * 1024 * 1024;
  char *data = (char *)malloc(bytes);
  if (data == NULL) return 2;
  for (size_t i = 0; i < bytes; i += 4096) data[i] = (char)(i & 255);
  sleep(30);
  return data[0];
}
EOF
  cc -O1 -o "$test_root/hold-memory" "$test_root/hold-memory.c"

  memory_job_dir="$(
    CLASP_MANAGED_JOB_USE_SYSTEMD_SCOPE=never \
      "$project_root/scripts/run-managed-job.sh" \
      --jobs-root "$jobs_root" \
      --job-id memory-watch-smoke \
      --memory-mb 128 \
      -- bash -c '"$1" 96 & "$1" 96 & wait' _ "$test_root/hold-memory"
  )"
  [[ "$memory_job_dir" == "$jobs_root/memory-watch-smoke" ]]
  memory_sid="$(tr -d '[:space:]' <"$memory_job_dir/sid")"
  wait_for_file "$memory_job_dir/exit-status"
  [[ "$(cat "$memory_job_dir/exit-status")" == "137" ]]
  [[ "$(cat "$memory_job_dir/status")" == "memory-exceeded" ]]
  grep -E '^(systemd-scope|session-rss-watch)$' "$memory_job_dir/memory-enforcer" >/dev/null
  grep -F 'limit_mb=128' "$memory_job_dir/memory-exceeded" >/dev/null
  grep -F 'rss_kb=' "$memory_job_dir/memory-exceeded" >/dev/null
  for _ in $(seq 1 "$poll_iterations"); do
    if ! session_has_members "$memory_sid"; then
      break
    fi
    sleep "$poll_sleep"
  done
  if session_has_members "$memory_sid"; then
    printf 'memory-limited managed job still has session members\n' >&2
    ps -eo pid,ppid,pgid,sid,rss,comm,args | awk -v sid="$memory_sid" '$4 == sid { print }' >&2
    exit 1
  fi

  detached_memory_pid_file="$test_root/detached-memory.pids"
  detached_memory_job_dir="$(
    CLASP_MANAGED_JOB_USE_SYSTEMD_SCOPE=never \
      "$project_root/scripts/run-managed-job.sh" \
      --jobs-root "$jobs_root" \
      --job-id memory-watch-detached-marked-smoke \
      --memory-mb 128 \
      -- bash -c 'setsid bash -c '"'"'printf "%s\n" "$BASHPID" >>"$2"; exec "$1" 96'"'"' _ "$1" "$2" & setsid bash -c '"'"'printf "%s\n" "$BASHPID" >>"$2"; exec "$1" 96'"'"' _ "$1" "$2" & wait' _ "$test_root/hold-memory" "$detached_memory_pid_file"
  )"
  [[ "$detached_memory_job_dir" == "$jobs_root/memory-watch-detached-marked-smoke" ]]
  detached_memory_sid="$(tr -d '[:space:]' <"$detached_memory_job_dir/sid")"
  wait_for_file "$detached_memory_pid_file"
  wait_for_file "$detached_memory_job_dir/exit-status"
  [[ "$(cat "$detached_memory_job_dir/exit-status")" == "137" ]]
  [[ "$(cat "$detached_memory_job_dir/status")" == "memory-exceeded" ]]
  grep -E '^(systemd-scope|session-rss-watch)$' "$detached_memory_job_dir/memory-enforcer" >/dev/null
  grep -F 'limit_mb=128' "$detached_memory_job_dir/memory-exceeded" >/dev/null
  grep -F 'rss_kb=' "$detached_memory_job_dir/memory-exceeded" >/dev/null
  for _ in $(seq 1 "$poll_iterations"); do
    if ! session_has_members "$detached_memory_sid"; then
      break
    fi
    sleep "$poll_sleep"
  done
  if session_has_members "$detached_memory_sid"; then
    printf 'detached marked memory-limited managed job still has root session members\n' >&2
    ps -eo pid,ppid,pgid,sid,rss,comm,args | awk -v sid="$detached_memory_sid" '$4 == sid { print }' >&2
    exit 1
  fi
  while IFS= read -r detached_memory_pid; do
    if [[ -n "$detached_memory_pid" ]] && kill -0 "$detached_memory_pid" >/dev/null 2>&1; then
      printf 'detached marked memory child survived memory cleanup: %s\n' "$detached_memory_pid" >&2
      exit 1
    fi
  done <"$detached_memory_pid_file"
fi

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
for _ in $(seq 1 "$poll_iterations"); do
  if ! kill -0 "$pid" >/dev/null 2>&1; then
    break
  fi
  sleep "$poll_sleep"
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

for _ in $(seq 1 "$poll_iterations"); do
  if session_has_nonroot_group "$nested_sid" "$nested_pgid"; then
    break
  fi
  sleep "$poll_sleep"
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

unmarked_child_job_dir="$(
  "$project_root/scripts/run-managed-job.sh" \
    --jobs-root "$jobs_root" \
    --job-id stop-unmarked-session-child \
    -- bash -c 'env -i PATH="$PATH" bash -c '"'"'while true; do sleep 1; done'"'"' & wait'
)"

[[ "$unmarked_child_job_dir" == "$jobs_root/stop-unmarked-session-child" ]]
unmarked_child_sid="$(tr -d '[:space:]' <"$unmarked_child_job_dir/sid")"

for _ in $(seq 1 "$poll_iterations"); do
  if session_has_unmarked_member "$unmarked_child_sid"; then
    break
  fi
  sleep "$poll_sleep"
done
if ! session_has_unmarked_member "$unmarked_child_sid"; then
  printf 'managed job did not create an unmarked same-session child for stop coverage\n' >&2
  ps -eo pid,ppid,pgid,sid,comm,args | awk -v sid="$unmarked_child_sid" '$4 == sid { print }' >&2
  "$project_root/scripts/stop-managed-job.sh" --jobs-root "$jobs_root" stop-unmarked-session-child >/dev/null || true
  exit 1
fi

if "$project_root/scripts/stop-managed-job.sh" --force-signal --jobs-root "$jobs_root" stop-unmarked-session-child >"$test_root/unmarked-session-child-default.out" 2>"$test_root/unmarked-session-child-default.err"; then
  printf 'stop-managed-job unexpectedly force-stopped an unmarked same-session child by default\n' >&2
  exit 1
fi
grep -F 'refusing force-signal with unmarked session members' "$test_root/unmarked-session-child-default.err" >/dev/null
if ! session_has_members "$unmarked_child_sid"; then
  printf 'managed job unmarked same-session child died during default force-stop refusal\n' >&2
  exit 1
fi

"$project_root/scripts/stop-managed-job.sh" --jobs-root "$jobs_root" stop-unmarked-session-child >/dev/null
if session_has_members "$unmarked_child_sid"; then
  printf 'managed job unmarked same-session child survived cooperative managed stop\n' >&2
  ps -eo pid,ppid,pgid,sid,comm,args | awk -v sid="$unmarked_child_sid" '$4 == sid { print }' >&2
  exit 1
fi
[[ "$(cat "$unmarked_child_job_dir/status")" == "stopped" ]]

orphan_job_dir="$(
  "$project_root/scripts/run-managed-job.sh" \
    --jobs-root "$jobs_root" \
    --job-id stop-root-exited-session \
    -- bash -c 'bash -c '"'"'while true; do sleep 1; done'"'"' & sleep 0.3; exit 0'
)"

[[ "$orphan_job_dir" == "$jobs_root/stop-root-exited-session" ]]
orphan_pid="$(tr -d '[:space:]' <"$orphan_job_dir/pid")"
orphan_sid="$(tr -d '[:space:]' <"$orphan_job_dir/sid")"

wait_for_file "$orphan_job_dir/exit-status"
[[ "$(cat "$orphan_job_dir/exit-status")" == "0" ]]
for _ in $(seq 1 "$poll_iterations"); do
  if ! kill -0 "$orphan_pid" >/dev/null 2>&1 && ! session_has_members "$orphan_sid"; then
    break
  fi
  sleep "$poll_sleep"
done
if kill -0 "$orphan_pid" >/dev/null 2>&1 || session_has_members "$orphan_sid"; then
  printf 'managed job left root-exited session members after normal cleanup\n' >&2
  ps -eo pid,ppid,pgid,sid,comm,args | awk -v sid="$orphan_sid" '$4 == sid { print }' >&2
  "$project_root/scripts/stop-managed-job.sh" --jobs-root "$jobs_root" stop-root-exited-session >/dev/null || true
  exit 1
fi

"$project_root/scripts/stop-managed-job.sh" --force-signal --jobs-root "$jobs_root" stop-root-exited-session >"$test_root/orphan-stop.out" 2>"$test_root/orphan-stop.err"
grep -F 'job already exited: stop-root-exited-session' "$test_root/orphan-stop.err" >/dev/null
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
