#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
jobs_root="${CLASP_MANAGED_JOB_ROOT:-$project_root/.clasp-loops/jobs}"
job_id=""
memory_mb="${CLASP_MANAGED_JOB_MEMORY_MB:-}"

usage() {
  cat <<'EOF' >&2
usage: scripts/run-managed-job.sh [--job-id <id>] [--jobs-root <dir>] [--memory-mb <mb>] -- <command> [args...]

Launches a command in an isolated session/process group and records metadata
that scripts/stop-managed-job.sh validates before stopping it. Completed jobs
record exit-status and update status to completed or failed.

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

    session_has_stoppable_members() {
      local sid="$1"
      local candidate_pid
      while IFS= read -r candidate_pid; do
        if [[ -n "$candidate_pid" && "$candidate_pid" != "$$" && "$candidate_pid" != "$BASHPID" ]]; then
          if [[ -z "${watcher_pid:-}" || "$candidate_pid" != "$watcher_pid" ]]; then
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
          if [[ -z "${watcher_pid:-}" || "$candidate_pid" != "$watcher_pid" ]]; then
            kill "-$signal" "$candidate_pid" >/dev/null 2>&1 || true
          fi
        fi
      done < <(session_member_pids "$sid")
    }

    watch_stop_request() {
      local sid="$1"
      local stop_file="$CLASP_MANAGED_JOB_STOP_REQUEST"
      while true; do
        if [[ -f "$stop_file" ]]; then
          local job_dir="$CLASP_MANAGED_JOB_ROOT/$CLASP_MANAGED_JOB_ID"
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

    finish_managed_job() {
      local status="$1"
      local job_dir="$CLASP_MANAGED_JOB_ROOT/$CLASP_MANAGED_JOB_ID"

      if [[ -n "${watcher_pid:-}" ]]; then
        kill "$watcher_pid" >/dev/null 2>&1 || true
        wait "$watcher_pid" >/dev/null 2>&1 || true
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

    if [[ -n "${CLASP_MANAGED_JOB_MEMORY_MB:-}" ]]; then
      ulimit -v "$((CLASP_MANAGED_JOB_MEMORY_MB * 1024))" || finish_managed_job 125
    fi

    "$@" &
    child_pid="$!"
    managed_sid="$(current_sid)"
    watch_stop_request "$managed_sid" &
    watcher_pid="$!"

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
