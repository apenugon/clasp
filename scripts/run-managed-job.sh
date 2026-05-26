#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
jobs_root="${CLASP_MANAGED_JOB_ROOT:-$project_root/.clasp-loops/jobs}"
job_id=""
memory_mb=""

usage() {
  cat <<'EOF' >&2
usage: scripts/run-managed-job.sh [--job-id <id>] [--jobs-root <dir>] [--memory-mb <mb>] -- <command> [args...]

Launches a command in an isolated session/process group and records metadata
that scripts/stop-managed-job.sh validates before stopping it. Completed jobs
record exit-status and update status to completed or failed.

When --memory-mb is set, the runner applies the limit with both a process
virtual-memory cap and, when available, a user systemd scope MemoryMax cgroup
around the workload. The detached runner stays outside the cgroup so it can
still record metadata if the workload is killed by the kernel memory limit.
Managed jobs also disable core dumps so memory-limit failures cannot spend
minutes writing multi-gigabyte crash artifacts.

By default, stop-managed-job requests cooperative stop by writing a stop-request
file. The detached runner owns any child signalling inside the managed session.
EOF
}

safe_job_id() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --job-id)
      job_id="${2:-}"
      shift 2
      ;;
    --jobs-root)
      jobs_root="${2:-}"
      shift 2
      ;;
    --memory-mb)
      memory_mb="${2:-}"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi
command=("$@")

if [[ -z "$job_id" ]]; then
  job_id="job-$(date +%Y%m%d%H%M%S%N)-$$-$RANDOM"
fi
if ! safe_job_id "$job_id"; then
  printf 'managed-job: invalid job id: %s\n' "$job_id" >&2
  exit 2
fi
if [[ -n "$memory_mb" ]] && ! [[ "$memory_mb" =~ ^[0-9]+$ && "$memory_mb" -gt 0 ]]; then
  printf 'managed-job: invalid memory limit: %s\n' "$memory_mb" >&2
  exit 2
fi

mkdir -p "$jobs_root"
jobs_root="$(cd "$jobs_root" && pwd -P)"
job_dir="$jobs_root/$job_id"
if [[ -e "$job_dir" ]]; then
  printf 'managed-job: job already exists: %s\n' "$job_id" >&2
  exit 1
fi
mkdir -p "$job_dir"

stdout_path="$job_dir/stdout.log"
stderr_path="$job_dir/stderr.log"
command_path="$job_dir/command.txt"
token_path="$job_dir/token"
stop_request_path="$job_dir/stop-request"
job_token="$(date +%s%N)-$$-$RANDOM"

printf '%q' "${command[0]}" >"$command_path"
for arg in "${command[@]:1}"; do
  printf ' %q' "$arg" >>"$command_path"
done
printf '\n' >>"$command_path"
printf '%s\n' "$job_token" >"$token_path"
printf '%s\n' "$stop_request_path" >"$job_dir/stop-request-path"
if [[ -n "$memory_mb" ]]; then
  printf '%s\n' "$memory_mb" >"$job_dir/memory-mb"
fi
printf 'started\n' >"$job_dir/status"

cd "$project_root"
setsid env \
  CLASP_MANAGED_JOB_ID="$job_id" \
  CLASP_MANAGED_JOB_ROOT="$jobs_root" \
  CLASP_MANAGED_JOB_TOKEN="$job_token" \
  CLASP_MANAGED_JOB_STOP_REQUEST="$stop_request_path" \
  CLASP_MANAGED_JOB_MEMORY_MB="$memory_mb" \
  bash -c '
    set +e
    watcher_pid=""
    memory_watcher_pid=""
    job_dir="$CLASP_MANAGED_JOB_ROOT/$CLASP_MANAGED_JOB_ID"

    trim_spaces() {
      tr -d "[:space:]"
    }

    current_sid() {
      ps -o sid= -p "$$" | trim_spaces
    }

    session_member_pids() {
      local sid="$1"
      ps -eo pid=,sid= |
        awk -v want="$sid" '"'"'
          {
            pid = $1
            sid = $2
            gsub(/[[:space:]]/, "", pid)
            gsub(/[[:space:]]/, "", sid)
            if (sid == want && pid != "") print pid
          }
        '"'"'
    }

    internal_watcher_pid() {
      local candidate_pid="$1"

      [[ -n "${watcher_pid:-}" && "$candidate_pid" == "$watcher_pid" ]] ||
        [[ -n "${memory_watcher_pid:-}" && "$candidate_pid" == "$memory_watcher_pid" ]]
    }

    session_has_stoppable_members() {
      local sid="$1"
      local candidate_pid
      while IFS= read -r candidate_pid; do
        if [[ -n "$candidate_pid" && "$candidate_pid" != "$$" && "$candidate_pid" != "$BASHPID" ]]; then
          if ! internal_watcher_pid "$candidate_pid"; then
            return 0
          fi
        fi
      done < <(session_member_pids "$sid")
      return 1
    }

    signal_session_members() {
      local signal="$1"
      local sid="$2"
      local candidate_pid
      while IFS= read -r candidate_pid; do
        if [[ -n "$candidate_pid" && "$candidate_pid" =~ ^[0-9]+$ && "$candidate_pid" != "$$" && "$candidate_pid" != "$BASHPID" ]]; then
          if ! internal_watcher_pid "$candidate_pid"; then
            kill "-$signal" "$candidate_pid" >/dev/null 2>&1 || true
          fi
        fi
      done < <(session_member_pids "$sid")
    }

    session_rss_kb() {
      local sid="$1"
      ps -eo pid=,sid=,rss= |
        awk -v want="$sid" -v parent_pid="$$" -v current_pid="$BASHPID" -v stop_watcher="${watcher_pid:-}" -v memory_watcher="${memory_watcher_pid:-}" '"'"'
          {
            pid = $1
            sid = $2
            rss = $3
            gsub(/[[:space:]]/, "", pid)
            gsub(/[[:space:]]/, "", sid)
            gsub(/[[:space:]]/, "", rss)
            if (sid != want || pid == "" || rss == "") next
            if (pid == parent_pid || pid == current_pid || pid == stop_watcher || pid == memory_watcher) next
            sum += rss
          }
          END { printf "%d\n", sum }
        '"'"'
    }

    watch_stop_request() {
      local sid="$1"
      local stop_file="$CLASP_MANAGED_JOB_STOP_REQUEST"
      while true; do
        if [[ -f "$stop_file" ]]; then
          printf "stopping\n" >"$job_dir/status"
          signal_session_members TERM "$sid"
          for _ in $(seq 1 50); do
            if ! session_has_stoppable_members "$sid"; then
              return 0
            fi
            sleep 0.1
          done
          signal_session_members KILL "$sid"
          return 0
        fi
        sleep 0.2
      done
    }

    watch_memory_limit() {
      local sid="$1"
      local memory_limit_kb="$((CLASP_MANAGED_JOB_MEMORY_MB * 1024))"
      local memory_exceeded_path="$job_dir/memory-exceeded"
      local rss_kb=""

      while true; do
        if ! session_has_stoppable_members "$sid"; then
          return 0
        fi

        rss_kb="$(session_rss_kb "$sid")"
        if [[ "$rss_kb" =~ ^[0-9]+$ ]] && (( rss_kb > memory_limit_kb )); then
          {
            printf "limit_mb=%s\n" "$CLASP_MANAGED_JOB_MEMORY_MB"
            printf "rss_kb=%s\n" "$rss_kb"
            date -u +"detected_at=%Y-%m-%dT%H:%M:%SZ"
          } >"$memory_exceeded_path"
          printf "memory-exceeded\n" >"$job_dir/status"
          signal_session_members TERM "$sid"
          for _ in $(seq 1 50); do
            if ! session_has_stoppable_members "$sid"; then
              return 0
            fi
            sleep 0.1
          done
          signal_session_members KILL "$sid"
          return 0
        fi

        sleep 0.5
      done
    }

    should_use_systemd_memory_scope() {
      local preference="${CLASP_MANAGED_JOB_USE_SYSTEMD_SCOPE:-auto}"

      [[ -n "${CLASP_MANAGED_JOB_MEMORY_MB:-}" ]] || return 1
      [[ "$preference" != "0" && "$preference" != "false" && "$preference" != "never" ]] || return 1
      command -v systemd-run >/dev/null 2>&1 || return 1
      systemctl --user is-active --quiet default.target >/dev/null 2>&1 || return 1
      return 0
    }

    start_workload() {
      if should_use_systemd_memory_scope; then
        printf "systemd-scope\n" >"$job_dir/memory-enforcer"
        systemd-run \
          --user \
          --scope \
          --quiet \
          --collect \
          -p MemoryAccounting=yes \
          -p "MemoryMax=${CLASP_MANAGED_JOB_MEMORY_MB}M" \
          "$@" &
      else
        if [[ -n "${CLASP_MANAGED_JOB_MEMORY_MB:-}" ]]; then
          printf "session-rss-watch\n" >"$job_dir/memory-enforcer"
        fi
        "$@" &
      fi
      child_pid="$!"
    }

    finish_managed_job() {
      local status="$1"

      if [[ -n "${watcher_pid:-}" ]]; then
        kill "$watcher_pid" >/dev/null 2>&1 || true
        wait "$watcher_pid" >/dev/null 2>&1 || true
      fi
      if [[ -n "${memory_watcher_pid:-}" ]]; then
        kill "$memory_watcher_pid" >/dev/null 2>&1 || true
        wait "$memory_watcher_pid" >/dev/null 2>&1 || true
      fi
      if [[ -n "${CLASP_MANAGED_JOB_MEMORY_MB:-}" && -f "$job_dir/memory-enforcer" && ! -f "$job_dir/memory-exceeded" && ! -f "$CLASP_MANAGED_JOB_STOP_REQUEST" ]] &&
         { [[ "$status" == "137" ]] || { [[ "$(cat "$job_dir/memory-enforcer" 2>/dev/null)" == "systemd-scope" && "$status" == "143" ]]; }; }; then
        {
          printf "limit_mb=%s\n" "$CLASP_MANAGED_JOB_MEMORY_MB"
          printf "rss_kb=unknown\n"
          printf "reason=workload-killed-by-memory-enforcer\n"
          date -u +"detected_at=%Y-%m-%dT%H:%M:%SZ"
        } >"$job_dir/memory-exceeded"
      fi
      if [[ -f "$job_dir/memory-exceeded" && "$status" != "0" ]]; then
        status="137"
      fi
      printf "%s\n" "$status" >"$job_dir/exit-status"
      if [[ -f "$CLASP_MANAGED_JOB_STOP_REQUEST" ]]; then
        printf "stopped\n" >"$job_dir/status"
      elif [[ "$status" == "0" ]]; then
        printf "completed\n" >"$job_dir/status"
      else
        printf "failed\n" >"$job_dir/status"
      fi
      exit "$status"
    }

    trap "finish_managed_job 130" INT
    trap "finish_managed_job 143" TERM

    ulimit -c 0 >/dev/null 2>&1 || true

    if [[ -n "${CLASP_MANAGED_JOB_MEMORY_MB:-}" ]]; then
      ulimit -v "$((CLASP_MANAGED_JOB_MEMORY_MB * 1024))" || finish_managed_job 125
    fi

    start_workload "$@"
    managed_sid="$(current_sid)"
    watch_stop_request "$managed_sid" &
    watcher_pid="$!"
    if [[ -n "${CLASP_MANAGED_JOB_MEMORY_MB:-}" ]]; then
      watch_memory_limit "$managed_sid" &
      memory_watcher_pid="$!"
    fi

    wait "$child_pid"
    finish_managed_job "$?"
  ' managed-job-runner "${command[@]}" \
  >"$stdout_path" 2>"$stderr_path" &
pid="$!"

sleep 0.05
if ! kill -0 "$pid" >/dev/null 2>&1; then
  printf 'managed-job: command exited before metadata could be recorded: %s\n' "$job_id" >&2
  exit 1
fi

pgid="$(ps -o pgid= -p "$pid" | tr -d '[:space:]')"
sid="$(ps -o sid= -p "$pid" | tr -d '[:space:]')"
if [[ -z "$pgid" || -z "$sid" ]]; then
  printf 'managed-job: failed to inspect launched job process: %s\n' "$job_id" >&2
  exit 1
fi

{
  printf '%s\n' "$pid"
} >"$job_dir/pid"
{
  printf '%s\n' "$pgid"
} >"$job_dir/pgid"
{
  printf '%s\n' "$sid"
} >"$job_dir/sid"
{
  printf '%s\n' "$project_root"
} >"$job_dir/cwd"
{
  date -u +%Y-%m-%dT%H:%M:%SZ
} >"$job_dir/started-at"

disown "$pid" >/dev/null 2>&1 || true
printf '%s\n' "$job_dir"
