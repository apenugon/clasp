#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
jobs_root="${CLASP_MANAGED_JOB_ROOT:-$project_root/.clasp-loops/jobs}"
job_id=""
preflight_only=0
memory_mb=""
min_available_memory_mb=""
min_available_disk_mb=""
min_disk_headroom_mb="${CLASP_MANAGED_JOB_MIN_DISK_HEADROOM_MB:-0}"
disk_reserve_path="${CLASP_MANAGED_JOB_DISK_RESERVE_PATH:-$project_root}"
max_memory_mb="${CLASP_MANAGED_JOB_MAX_MEMORY_MB:-8192}"
default_min_available_memory_mb="${CLASP_MANAGED_JOB_DEFAULT_MIN_AVAILABLE_MEMORY_MB:-8192}"
external_agent_reserve_mb="${CLASP_MANAGED_JOB_EXTERNAL_AGENT_RESERVE_MB:-1024}"
external_agent_process_names="${CLASP_MANAGED_JOB_EXTERNAL_AGENT_PROCESS_NAMES:-codex}"
memory_budget_scope="${CLASP_MANAGED_JOB_MEMORY_BUDGET_SCOPE:-global}"
require_memory_limit="${CLASP_MANAGED_JOB_REQUIRE_MEMORY_LIMIT:-1}"
admission_lock_file="${CLASP_MANAGED_JOB_ADMISSION_LOCK_FILE:-$project_root/.clasp-managed-job-admission.lock}"
require_admission_lock="${CLASP_MANAGED_JOB_REQUIRE_ADMISSION_LOCK:-1}"

usage() {
  cat <<'EOF' >&2
usage: scripts/run-managed-job.sh [--job-id <id>] [--jobs-root <dir>] [--preflight-only] [--memory-mb <mb>] [--min-available-memory-mb <mb>] [--min-available-disk-mb <mb>] [--min-disk-headroom-mb <mb>] [--disk-reserve-path <path>] -- <command> [args...]

Launches a command in an isolated session/process group and records metadata
that scripts/stop-managed-job.sh validates before stopping it. Completed jobs
record exit-status and update status to completed or failed.

When --memory-mb is set, the runner applies the limit with a user systemd
scope MemoryMax cgroup by default. This is intentionally fail-closed for
heavyweight jobs: if the hard cgroup guard is unavailable, the job exits before
starting unless CLASP_MANAGED_JOB_USE_SYSTEMD_SCOPE is set to auto or never.
With auto/never, the runner falls back to a process virtual-memory cap and RSS
watcher. The detached runner stays outside the cgroup so it can still record
metadata if the workload is killed by the kernel memory limit.
Managed jobs also disable core dumps so memory-limit failures cannot spend
minutes writing multi-gigabyte crash artifacts.

When --min-available-memory-mb is set, the runner also watches host
MemAvailable and stops the managed session before the whole VM enters kernel
OOM territory. The runtime watcher preserves the declared memory budget of
other live managed jobs, matching the preflight admission model.

When --min-available-disk-mb is set, the runner checks and watches free space
on --disk-reserve-path, defaulting to the project root. If the reserve is not
met, the job fails before starting or is stopped before the filesystem fills.
When --min-disk-headroom-mb is also set, the runner fails closed if the hard
reserve is met but the remaining margin above that reserve is too small.

Memory admission is serialized through CLASP_MANAGED_JOB_ADMISSION_LOCK_FILE
and includes the declared --memory-mb budget of other live managed jobs. This
prevents independently launched jobs from each passing the host-memory reserve
check and collectively overcommitting the machine.
Use --preflight-only to run the same admission checks and record job metadata
without starting the command. This is useful before launching agent loops on a
machine that may already have resident Codex processes.

By default, managed jobs must set --memory-mb and cannot request more than
CLASP_MANAGED_JOB_MAX_MEMORY_MB, which defaults to 8192. Set
CLASP_MANAGED_JOB_REQUIRE_MEMORY_LIMIT=0 to allow an intentionally unbounded
managed job, or CLASP_MANAGED_JOB_MAX_MEMORY_MB=0 to disable the ceiling.
Memory-capped jobs that do not pass --min-available-memory-mb also reserve
CLASP_MANAGED_JOB_DEFAULT_MIN_AVAILABLE_MEMORY_MB, defaulting to 8192, so
independently launched capped jobs cannot collectively spend all host memory.
Set CLASP_MANAGED_JOB_DEFAULT_MIN_AVAILABLE_MEMORY_MB=0 only for tiny fixtures.
Host-memory admission also reserves the current RSS of live unmanaged processes
whose command name appears in CLASP_MANAGED_JOB_EXTERNAL_AGENT_PROCESS_NAMES,
plus CLASP_MANAGED_JOB_EXTERNAL_AGENT_RESERVE_MB of growth headroom per process,
defaulting to 1024 MB per live codex process. Set the reserve to 0 only for tiny
fixtures. This protects managed compiler and verifier work from starting next
to unrelated agent sessions that are already resident and may grow while the job
is running.
Set CLASP_MANAGED_JOB_USE_SYSTEMD_SCOPE=auto to allow the weaker fallback when
user systemd is not available; set it to never only for tests or tiny fixtures.
Set CLASP_MANAGED_JOB_REQUIRE_ADMISSION_LOCK=0 only for tiny fixtures that do
not need cross-job memory admission. Nested managed jobs exclude their direct
parent job's declared budget by default, so an outer bounded verifier can launch
bounded inner work without double-reserving the same envelope. Set
CLASP_MANAGED_JOB_EXCLUDE_PARENT_BUDGET=0 only when a child must reserve memory
as fully independent from its parent job. Production admission counts all live
managed jobs globally; tests may set CLASP_MANAGED_JOB_MEMORY_BUDGET_SCOPE to
current-root to account only for jobs in the same --jobs-root.

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
    --preflight-only)
      preflight_only=1
      shift
      ;;
    --memory-mb)
      memory_mb="${2:-}"
      shift 2
      ;;
    --min-available-memory-mb)
      min_available_memory_mb="${2:-}"
      shift 2
      ;;
    --min-available-disk-mb)
      min_available_disk_mb="${2:-}"
      shift 2
      ;;
    --min-disk-headroom-mb)
      min_disk_headroom_mb="${2:-}"
      shift 2
      ;;
    --disk-reserve-path)
      disk_reserve_path="${2:-}"
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
if ! [[ "$max_memory_mb" =~ ^[0-9]+$ ]]; then
  printf 'managed-job: invalid CLASP_MANAGED_JOB_MAX_MEMORY_MB: %s\n' "$max_memory_mb" >&2
  exit 2
fi
if ! [[ "$default_min_available_memory_mb" =~ ^[0-9]+$ ]]; then
  printf 'managed-job: invalid CLASP_MANAGED_JOB_DEFAULT_MIN_AVAILABLE_MEMORY_MB: %s\n' "$default_min_available_memory_mb" >&2
  exit 2
fi
if ! [[ "$external_agent_reserve_mb" =~ ^[0-9]+$ ]]; then
  printf 'managed-job: invalid CLASP_MANAGED_JOB_EXTERNAL_AGENT_RESERVE_MB: %s\n' "$external_agent_reserve_mb" >&2
  exit 2
fi
case "$memory_budget_scope" in
  global|current-root)
    ;;
  *)
    printf 'managed-job: invalid CLASP_MANAGED_JOB_MEMORY_BUDGET_SCOPE: %s\n' "$memory_budget_scope" >&2
    exit 2
    ;;
esac
if [[ -n "$min_available_memory_mb" ]] && ! [[ "$min_available_memory_mb" =~ ^[0-9]+$ && "$min_available_memory_mb" -gt 0 ]]; then
  printf 'managed-job: invalid minimum available memory: %s\n' "$min_available_memory_mb" >&2
  exit 2
fi
if [[ -n "$min_available_disk_mb" ]] && ! [[ "$min_available_disk_mb" =~ ^[0-9]+$ && "$min_available_disk_mb" -gt 0 ]]; then
  printf 'managed-job: invalid minimum available disk: %s\n' "$min_available_disk_mb" >&2
  exit 2
fi
if ! [[ "$min_disk_headroom_mb" =~ ^[0-9]+$ ]]; then
  printf 'managed-job: invalid minimum disk headroom: %s\n' "$min_disk_headroom_mb" >&2
  exit 2
fi
if [[ -z "$disk_reserve_path" ]]; then
  printf 'managed-job: invalid empty disk reserve path\n' >&2
  exit 2
fi
case "$require_memory_limit" in
  0|false|FALSE|False|no|NO|No|off|OFF|Off|never|NEVER|Never)
    ;;
  *)
    if [[ -z "$memory_mb" ]]; then
      printf 'managed-job: refusing unbounded job; pass --memory-mb or set CLASP_MANAGED_JOB_REQUIRE_MEMORY_LIMIT=0\n' >&2
      exit 2
    fi
    ;;
esac
if [[ -n "$memory_mb" && "$max_memory_mb" -gt 0 && "$memory_mb" -gt "$max_memory_mb" ]]; then
  printf 'managed-job: memory limit %s MB exceeds CLASP_MANAGED_JOB_MAX_MEMORY_MB=%s\n' "$memory_mb" "$max_memory_mb" >&2
  exit 2
fi
if [[ -n "$memory_mb" && -z "$min_available_memory_mb" && "$default_min_available_memory_mb" -gt 0 ]]; then
  min_available_memory_mb="$default_min_available_memory_mb"
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
if [[ -n "$min_available_memory_mb" ]]; then
  printf '%s\n' "$min_available_memory_mb" >"$job_dir/min-available-memory-mb"
fi
if [[ "$external_agent_reserve_mb" -gt 0 ]]; then
  printf '%s\n' "$external_agent_reserve_mb" >"$job_dir/external-agent-reserve-mb"
  printf '%s\n' "$external_agent_process_names" >"$job_dir/external-agent-process-names"
fi
if [[ -n "$min_available_disk_mb" ]]; then
  printf '%s\n' "$min_available_disk_mb" >"$job_dir/min-available-disk-mb"
  printf '%s\n' "$disk_reserve_path" >"$job_dir/disk-reserve-path"
fi
if (( min_disk_headroom_mb > 0 )); then
  printf '%s\n' "$min_disk_headroom_mb" >"$job_dir/min-disk-headroom-mb"
  printf '%s\n' "$disk_reserve_path" >"$job_dir/disk-reserve-path"
fi
printf 'started\n' >"$job_dir/status"

parent_job_id="${CLASP_MANAGED_JOB_ID:-}"
parent_job_root="${CLASP_MANAGED_JOB_ROOT:-}"
parent_job_token="${CLASP_MANAGED_JOB_TOKEN:-}"
min_disk_headroom_env=""
if (( min_disk_headroom_mb > 0 )); then
  min_disk_headroom_env="$min_disk_headroom_mb"
fi

cd "$project_root"
setsid env \
  CLASP_MANAGED_JOB_ID="$job_id" \
  CLASP_MANAGED_JOB_ROOT="$jobs_root" \
  CLASP_MANAGED_JOB_TOKEN="$job_token" \
  CLASP_MANAGED_JOB_STOP_REQUEST="$stop_request_path" \
  CLASP_MANAGED_JOB_MEMORY_MB="$memory_mb" \
  CLASP_MANAGED_JOB_MIN_AVAILABLE_MEMORY_MB="$min_available_memory_mb" \
  CLASP_MANAGED_JOB_MIN_AVAILABLE_DISK_MB="$min_available_disk_mb" \
  CLASP_MANAGED_JOB_MIN_DISK_HEADROOM_MB="$min_disk_headroom_env" \
  CLASP_MANAGED_JOB_DISK_RESERVE_PATH="$disk_reserve_path" \
  CLASP_MANAGED_JOB_EXTERNAL_AGENT_RESERVE_MB="$external_agent_reserve_mb" \
  CLASP_MANAGED_JOB_EXTERNAL_AGENT_PROCESS_NAMES="$external_agent_process_names" \
  CLASP_MANAGED_JOB_MEMORY_BUDGET_SCOPE="$memory_budget_scope" \
  CLASP_MANAGED_JOB_ADMISSION_LOCK_FILE="$admission_lock_file" \
  CLASP_MANAGED_JOB_REQUIRE_ADMISSION_LOCK="$require_admission_lock" \
  CLASP_MANAGED_JOB_PREFLIGHT_ONLY="$preflight_only" \
  CLASP_MANAGED_JOB_PARENT_ID="$parent_job_id" \
  CLASP_MANAGED_JOB_PARENT_ROOT="$parent_job_root" \
  CLASP_MANAGED_JOB_PARENT_TOKEN="$parent_job_token" \
  CLASP_MANAGED_JOB_EXCLUDE_PARENT_BUDGET="${CLASP_MANAGED_JOB_EXCLUDE_PARENT_BUDGET:-1}" \
  bash -c '
    set +e
    watcher_pid=""
    memory_watcher_pid=""
    admission_lock_held=0
    workload_started=0
    job_dir="$CLASP_MANAGED_JOB_ROOT/$CLASP_MANAGED_JOB_ID"
    expected_job_id="$CLASP_MANAGED_JOB_ID"
    expected_job_root="$CLASP_MANAGED_JOB_ROOT"
    expected_job_token="$CLASP_MANAGED_JOB_TOKEN"
    parent_job_id="${CLASP_MANAGED_JOB_PARENT_ID:-}"
    parent_job_root="${CLASP_MANAGED_JOB_PARENT_ROOT:-}"
    parent_job_token="${CLASP_MANAGED_JOB_PARENT_TOKEN:-}"
    exclude_parent_budget="${CLASP_MANAGED_JOB_EXCLUDE_PARENT_BUDGET:-0}"

    trim_spaces() {
      tr -d "[:space:]"
    }

    current_sid() {
      ps -o sid= -p "$$" | trim_spaces
    }

    session_member_pids() {
      local sid="$1"
      if command -v setsid >/dev/null 2>&1; then
        setsid env \
          -u CLASP_MANAGED_JOB_ID \
          -u CLASP_MANAGED_JOB_ROOT \
          -u CLASP_MANAGED_JOB_TOKEN \
          -u CLASP_MANAGED_JOB_STOP_REQUEST \
          -u CLASP_MANAGED_JOB_MEMORY_MB \
          -u CLASP_MANAGED_JOB_MIN_AVAILABLE_MEMORY_MB \
          -u CLASP_MANAGED_JOB_MIN_AVAILABLE_DISK_MB \
          -u CLASP_MANAGED_JOB_MIN_DISK_HEADROOM_MB \
          -u CLASP_MANAGED_JOB_DISK_RESERVE_PATH \
          -u CLASP_MANAGED_JOB_EXTERNAL_AGENT_RESERVE_MB \
          -u CLASP_MANAGED_JOB_EXTERNAL_AGENT_PROCESS_NAMES \
          -u CLASP_MANAGED_JOB_MEMORY_BUDGET_SCOPE \
          -u CLASP_MANAGED_JOB_ADMISSION_LOCK_FILE \
          -u CLASP_MANAGED_JOB_REQUIRE_ADMISSION_LOCK \
          -u CLASP_MANAGED_JOB_PREFLIGHT_ONLY \
          -u CLASP_MANAGED_JOB_PARENT_ID \
          -u CLASP_MANAGED_JOB_PARENT_ROOT \
          -u CLASP_MANAGED_JOB_PARENT_TOKEN \
          -u CLASP_MANAGED_JOB_EXCLUDE_PARENT_BUDGET \
          -u CLASP_MANAGED_JOB_WORKLOAD \
          sh -c '"'"'
          ps -eo pid=,sid= |
            awk -v want="$1" '"'"'"'"'"'"'"'"'
              {
                pid = $1
                sid = $2
                gsub(/[[:space:]]/, "", pid)
                gsub(/[[:space:]]/, "", sid)
                if (sid == want && pid != "") print pid
              }
            '"'"'"'"'"'"'"'"'
        '"'"' managed-session-scan "$sid"
      else
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
      fi
    }

    internal_watcher_pid() {
      local candidate_pid="$1"
      local candidate_ppid=""

      if [[ -n "${watcher_pid:-}" && "$candidate_pid" == "$watcher_pid" ]] ||
        [[ -n "${memory_watcher_pid:-}" && "$candidate_pid" == "$memory_watcher_pid" ]]; then
        return 0
      fi
      candidate_ppid="$(ps -o ppid= -p "$candidate_pid" 2>/dev/null | trim_spaces)" || return 1
      [[ -n "${watcher_pid:-}" && "$candidate_ppid" == "$watcher_pid" ]] ||
        [[ -n "${memory_watcher_pid:-}" && "$candidate_ppid" == "$memory_watcher_pid" ]]
    }

    internal_runner_helper_pid() {
      local candidate_pid="$1"
      local candidate_ppid=""

      candidate_ppid="$(ps -o ppid= -p "$candidate_pid" 2>/dev/null | trim_spaces)" || return 1
      process_has_marker "$candidate_pid" && return 1
      process_has_job_marker "$candidate_pid" && return 0
      if [[ -n "$candidate_ppid" ]] &&
         process_has_job_marker "$candidate_ppid" &&
         ! process_has_marker "$candidate_ppid"; then
        return 0
      fi
      if [[ "$candidate_ppid" != "$$" && "$candidate_ppid" != "$BASHPID" ]]; then
        return 1
      fi
      return 0
    }

    process_has_job_marker() {
      local candidate_pid="$1"
      local environ

      environ="$(read_proc_environ "/proc/$candidate_pid/environ")" || return 1
      grep -Fx "CLASP_MANAGED_JOB_ID=$expected_job_id" <<<"$environ" >/dev/null &&
      grep -Fx "CLASP_MANAGED_JOB_ROOT=$expected_job_root" <<<"$environ" >/dev/null &&
        grep -Fx "CLASP_MANAGED_JOB_TOKEN=$expected_job_token" <<<"$environ" >/dev/null
    }

    process_has_any_managed_job_marker() {
      local candidate_pid="$1"
      local environ

      environ="$(read_proc_environ "/proc/$candidate_pid/environ")" || return 1
      grep -E "^CLASP_MANAGED_JOB_ID=.+" <<<"$environ" >/dev/null &&
        grep -E "^CLASP_MANAGED_JOB_ROOT=.+" <<<"$environ" >/dev/null &&
        grep -E "^CLASP_MANAGED_JOB_TOKEN=.+" <<<"$environ" >/dev/null
    }

    external_agent_name_matches() {
      local process_name="$1"
      local configured_names="${CLASP_MANAGED_JOB_EXTERNAL_AGENT_PROCESS_NAMES:-codex}"
      local normalized_names
      local wanted_name

      normalized_names="${configured_names//,/ }"
      for wanted_name in $normalized_names; do
        if [[ -n "$wanted_name" && "$process_name" == "$wanted_name" ]]; then
          return 0
        fi
      done
      return 1
    }

    live_external_agent_process_count() {
      local reserve_mb="${CLASP_MANAGED_JOB_EXTERNAL_AGENT_RESERVE_MB:-0}"
      local candidate_pid=""
      local process_name=""
      local count=0

      [[ "$reserve_mb" =~ ^[0-9]+$ && "$reserve_mb" -gt 0 ]] || {
        printf "0\n"
        return 0
      }

      while read -r candidate_pid process_name; do
        [[ -n "$candidate_pid" && "$candidate_pid" =~ ^[0-9]+$ && -n "$process_name" ]] || continue
        external_agent_name_matches "$process_name" || continue
        process_has_any_managed_job_marker "$candidate_pid" && continue
        count=$((count + 1))
      done < <(ps -eo pid=,comm= 2>/dev/null || true)

      printf "%d\n" "$count"
    }

    live_external_agent_rss_mb() {
      local candidate_pid=""
      local process_name=""
      local rss_kb=""
      local total_kb=0

      while read -r candidate_pid process_name rss_kb; do
        [[ -n "$candidate_pid" && "$candidate_pid" =~ ^[0-9]+$ && -n "$process_name" ]] || continue
        [[ "$rss_kb" =~ ^[0-9]+$ ]] || rss_kb=0
        external_agent_name_matches "$process_name" || continue
        process_has_any_managed_job_marker "$candidate_pid" && continue
        total_kb=$((total_kb + rss_kb))
      done < <(ps -eo pid=,comm=,rss= 2>/dev/null || true)

      printf "%d\n" "$(((total_kb + 1023) / 1024))"
    }

    read_proc_environ() {
      local environ_path="$1"

      [[ -r "$environ_path" ]] || return 1
      { tr "\0" "\n" <"$environ_path"; } 2>/dev/null
    }

    process_has_marker() {
      local candidate_pid="$1"
      local environ

      process_has_job_marker "$candidate_pid" || return 1
      environ="$(read_proc_environ "/proc/$candidate_pid/environ")" || return 1
      grep -Fx "CLASP_MANAGED_JOB_WORKLOAD=1" <<<"$environ" >/dev/null
    }

    marked_job_pids() {
      local environ
      local environ_path
      local candidate_pid

      while IFS= read -r -d "" environ_path; do
        candidate_pid="${environ_path#/proc/}"
        candidate_pid="${candidate_pid%/environ}"
        [[ -n "$candidate_pid" && "$candidate_pid" =~ ^[0-9]+$ ]] || continue
        environ="$(read_proc_environ "$environ_path")" || continue
        environ=$'"'"'\n'"'"'"$environ"$'"'"'\n'"'"'
        if [[ "$environ" == *$'"'"'\n'"'"'"CLASP_MANAGED_JOB_ID=$expected_job_id"$'"'"'\n'"'"'* &&
              "$environ" == *$'"'"'\n'"'"'"CLASP_MANAGED_JOB_ROOT=$expected_job_root"$'"'"'\n'"'"'* &&
              "$environ" == *$'"'"'\n'"'"'"CLASP_MANAGED_JOB_TOKEN=$expected_job_token"$'"'"'\n'"'"'* &&
              "$environ" == *$'"'"'\nCLASP_MANAGED_JOB_WORKLOAD=1\n'"'"'* ]]; then
          printf "%s\n" "$candidate_pid"
        fi
      done < <(grep -Zal -- "CLASP_MANAGED_JOB_ID=$expected_job_id" /proc/[0-9]*/environ 2>/dev/null || true)
    }

    session_has_stoppable_members() {
      local sid="$1"
      local candidate_pid
      while IFS= read -r candidate_pid; do
        if [[ -n "$candidate_pid" && "$candidate_pid" != "$$" && "$candidate_pid" != "$BASHPID" ]]; then
          if ! internal_watcher_pid "$candidate_pid"; then
            if internal_runner_helper_pid "$candidate_pid"; then
              continue
            fi
            return 0
          fi
        fi
      done < <(session_member_pids "$sid")
      return 1
    }

    job_member_pids() {
      local sid="$1"

      {
        session_member_pids "$sid"
        marked_job_pids
      } | env \
        -u CLASP_MANAGED_JOB_ID \
        -u CLASP_MANAGED_JOB_ROOT \
        -u CLASP_MANAGED_JOB_TOKEN \
        -u CLASP_MANAGED_JOB_STOP_REQUEST \
        -u CLASP_MANAGED_JOB_MEMORY_MB \
        -u CLASP_MANAGED_JOB_MIN_AVAILABLE_MEMORY_MB \
        -u CLASP_MANAGED_JOB_MIN_AVAILABLE_DISK_MB \
        -u CLASP_MANAGED_JOB_MIN_DISK_HEADROOM_MB \
        -u CLASP_MANAGED_JOB_DISK_RESERVE_PATH \
        -u CLASP_MANAGED_JOB_EXTERNAL_AGENT_RESERVE_MB \
        -u CLASP_MANAGED_JOB_EXTERNAL_AGENT_PROCESS_NAMES \
        -u CLASP_MANAGED_JOB_MEMORY_BUDGET_SCOPE \
        -u CLASP_MANAGED_JOB_ADMISSION_LOCK_FILE \
        -u CLASP_MANAGED_JOB_REQUIRE_ADMISSION_LOCK \
        -u CLASP_MANAGED_JOB_PREFLIGHT_ONLY \
        -u CLASP_MANAGED_JOB_PARENT_ID \
        -u CLASP_MANAGED_JOB_PARENT_ROOT \
        -u CLASP_MANAGED_JOB_PARENT_TOKEN \
        -u CLASP_MANAGED_JOB_EXCLUDE_PARENT_BUDGET \
        -u CLASP_MANAGED_JOB_WORKLOAD \
        awk '"'"'NF && !seen[$0]++ { print }'"'"'
    }

    job_has_stoppable_members() {
      local sid="$1"
      local candidate_pid
      while IFS= read -r candidate_pid; do
        if [[ -n "$candidate_pid" && "$candidate_pid" != "$$" && "$candidate_pid" != "$BASHPID" ]]; then
          if ! internal_watcher_pid "$candidate_pid"; then
            if internal_runner_helper_pid "$candidate_pid"; then
              continue
            fi
            return 0
          fi
        fi
      done < <(job_member_pids "$sid")
      return 1
    }

    signal_session_members() {
      local signal="$1"
      local sid="$2"
      local candidate_pid
      while IFS= read -r candidate_pid; do
        if [[ -n "$candidate_pid" && "$candidate_pid" =~ ^[0-9]+$ && "$candidate_pid" != "$$" && "$candidate_pid" != "$BASHPID" ]]; then
          if ! internal_watcher_pid "$candidate_pid"; then
            if internal_runner_helper_pid "$candidate_pid"; then
              continue
            fi
            kill "-$signal" "$candidate_pid" >/dev/null 2>&1 || true
          fi
        fi
      done < <(session_member_pids "$sid")
    }

    signal_job_members() {
      local signal="$1"
      local sid="$2"
      local candidate_pid
      while IFS= read -r candidate_pid; do
        if [[ -n "$candidate_pid" && "$candidate_pid" =~ ^[0-9]+$ && "$candidate_pid" != "$$" && "$candidate_pid" != "$BASHPID" ]]; then
          if ! internal_watcher_pid "$candidate_pid"; then
            if internal_runner_helper_pid "$candidate_pid"; then
              continue
            fi
            kill "-$signal" "$candidate_pid" >/dev/null 2>&1 || true
          fi
        fi
      done < <(job_member_pids "$sid")
    }

    stop_job_members() {
      local sid="$1"

      signal_job_members TERM "$sid"
      for _ in $(seq 1 "$cleanup_poll_iterations"); do
        if ! job_has_stoppable_members "$sid"; then
          return 0
        fi
        sleep "$cleanup_poll_sleep_secs"
      done
      signal_job_members KILL "$sid"
      for _ in $(seq 1 "$cleanup_poll_iterations"); do
        if ! job_has_stoppable_members "$sid"; then
          return 0
        fi
        sleep "$cleanup_poll_sleep_secs"
      done
      return 0
    }

    stop_session_members() {
      local sid="$1"

      signal_session_members TERM "$sid"
      for _ in $(seq 1 "$cleanup_poll_iterations"); do
        if ! session_has_stoppable_members "$sid"; then
          return 0
        fi
        sleep "$cleanup_poll_sleep_secs"
      done
      signal_session_members KILL "$sid"
      for _ in $(seq 1 "$cleanup_poll_iterations"); do
        if ! session_has_stoppable_members "$sid"; then
          return 0
        fi
        sleep "$cleanup_poll_sleep_secs"
      done
      return 0
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

    job_rss_kb() {
      local sid="$1"
      local candidate_pid
      local rss_kb
      local sum=0

      while IFS= read -r candidate_pid; do
        if [[ -z "$candidate_pid" || "$candidate_pid" == "$$" || "$candidate_pid" == "$BASHPID" ]]; then
          continue
        fi
        if internal_watcher_pid "$candidate_pid"; then
          continue
        fi
        if internal_runner_helper_pid "$candidate_pid"; then
          continue
        fi
        rss_kb="$(ps -o rss= -p "$candidate_pid" 2>/dev/null | tr -d "[:space:]")"
        if [[ "$rss_kb" =~ ^[0-9]+$ ]]; then
          sum=$((sum + rss_kb))
        fi
      done < <(job_member_pids "$sid")

      printf "%d\n" "$sum"
    }

    host_available_memory_mb() {
      awk '"'"'/MemAvailable:/ { printf "%d\n", int($2 / 1024); found = 1 } END { if (!found) print 0 }'"'"' /proc/meminfo 2>/dev/null || printf "0\n"
    }

    host_available_disk_mb() {
      local reserve_path="${1:-$PWD}"

      df -Pm "$reserve_path" 2>/dev/null |
        awk '"'"'NR == 2 { printf "%d\n", $4; found = 1 } END { if (!found) print 0 }'"'"' ||
        printf "0\n"
    }

    record_disk_recovery_hint() {
      printf "recovery_command=bash scripts/clasp-clean-generated-state.sh --health --json --include-run-binary-cache --include-temp-caches --include-build-caches --include-codex-logs\n"
      printf "recovery_apply_command=bash scripts/clasp-clean-generated-state.sh --apply --include-run-binary-cache --include-temp-caches --include-build-caches --include-codex-logs\n"
      printf "recovery_note=inspect the health report and run apply only when safeToClean is true; if cleanup cannot cover the shortfall, free disk outside the repo before retrying heavyweight work\n"
    }

    live_managed_memory_budget_mb() {
      local environ
      local environ_path
      local candidate_pid
      local line
      local job_id=""
      local job_root=""
      local job_token=""
      local job_memory=""
      local job_parent_id=""
      local job_parent_root=""
      local job_parent_token=""
      local job_status=""
      local key=""
      local current_key="$expected_job_root"$'"'"'\t'"'"'"$expected_job_id"$'"'"'\t'"'"'"$expected_job_token"
      local parent_key="$parent_job_root"$'"'"'\t'"'"'"$parent_job_id"$'"'"'\t'"'"'"$parent_job_token"
      local job_parent_key=""
      local ancestor_key=""
      local skip_job=0
      local total=0
      declare -A seen_jobs=()
      declare -A seen_ancestors=()
      declare -A job_memory_by_key=()
      declare -A job_parent_by_key=()

      for environ_path in /proc/[0-9]*/environ; do
        [[ -r "$environ_path" ]] || continue
        candidate_pid="${environ_path#/proc/}"
        candidate_pid="${candidate_pid%/environ}"
        [[ -n "$candidate_pid" && "$candidate_pid" =~ ^[0-9]+$ ]] || continue
        environ="$(read_proc_environ "$environ_path")" || continue

        job_id=""
        job_root=""
        job_token=""
        job_memory=""
        job_parent_id=""
        job_parent_root=""
        job_parent_token=""
        while IFS= read -r line; do
          case "$line" in
            CLASP_MANAGED_JOB_ID=*) job_id="${line#CLASP_MANAGED_JOB_ID=}" ;;
            CLASP_MANAGED_JOB_ROOT=*) job_root="${line#CLASP_MANAGED_JOB_ROOT=}" ;;
            CLASP_MANAGED_JOB_TOKEN=*) job_token="${line#CLASP_MANAGED_JOB_TOKEN=}" ;;
            CLASP_MANAGED_JOB_MEMORY_MB=*) job_memory="${line#CLASP_MANAGED_JOB_MEMORY_MB=}" ;;
            CLASP_MANAGED_JOB_PARENT_ID=*) job_parent_id="${line#CLASP_MANAGED_JOB_PARENT_ID=}" ;;
            CLASP_MANAGED_JOB_PARENT_ROOT=*) job_parent_root="${line#CLASP_MANAGED_JOB_PARENT_ROOT=}" ;;
            CLASP_MANAGED_JOB_PARENT_TOKEN=*) job_parent_token="${line#CLASP_MANAGED_JOB_PARENT_TOKEN=}" ;;
          esac
        done <<<"$environ"

        [[ -n "$job_id" && -n "$job_root" && -n "$job_token" ]] || continue
        [[ "$job_memory" =~ ^[0-9]+$ && "$job_memory" -gt 0 ]] || continue
        if [[ "${CLASP_MANAGED_JOB_MEMORY_BUDGET_SCOPE:-global}" == "current-root" &&
              "$job_root" != "$expected_job_root" ]]; then
          continue
        fi
        job_status="$(sed -n "1p" "$job_root/$job_id/status" 2>/dev/null || true)"
        case "$job_status" in
          completed|failed|stopped|memory-exceeded|disk-exceeded|memory-enforcer-unavailable|admission-lock-unavailable)
            continue
            ;;
        esac
        key="$job_root"$'"'"'\t'"'"'"$job_id"$'"'"'\t'"'"'"$job_token"
        job_parent_key="$job_parent_root"$'"'"'\t'"'"'"$job_parent_id"$'"'"'\t'"'"'"$job_parent_token"
        [[ -z "${seen_jobs[$key]:-}" ]] || continue
        seen_jobs[$key]=1
        job_memory_by_key[$key]="$job_memory"
        job_parent_by_key[$key]="$job_parent_key"
      done

      for key in "${!job_memory_by_key[@]}"; do
        [[ "$key" != "$current_key" ]] || continue
        [[ "${job_parent_by_key[$key]:-}" != "$current_key" ]] || continue

        skip_job=0
        if [[ "$exclude_parent_budget" =~ ^(1|true|TRUE|True|yes|YES|Yes|on|ON|On)$ ]]; then
          seen_ancestors=()
          ancestor_key="$parent_key"
          while [[ -n "$ancestor_key" ]]; do
            if [[ "$key" == "$ancestor_key" ]]; then
              skip_job=1
              break
            fi
            [[ -z "${seen_ancestors[$ancestor_key]:-}" ]] || break
            seen_ancestors[$ancestor_key]=1
            ancestor_key="${job_parent_by_key[$ancestor_key]:-}"
          done
        fi
        [[ "$skip_job" == "0" ]] || continue

        total=$((total + job_memory_by_key[$key]))
      done

      printf "%d\n" "$total"
    }

    admission_lock_required() {
      local preference="${CLASP_MANAGED_JOB_REQUIRE_ADMISSION_LOCK:-1}"

      case "$preference" in
        0|false|FALSE|False|no|NO|No|off|OFF|Off|never|NEVER|Never)
          return 1
          ;;
      esac

      [[ -n "${CLASP_MANAGED_JOB_MEMORY_MB:-}" ||
         -n "${CLASP_MANAGED_JOB_MIN_AVAILABLE_MEMORY_MB:-}" ||
         -n "${CLASP_MANAGED_JOB_MIN_AVAILABLE_DISK_MB:-}" ||
         -n "${CLASP_MANAGED_JOB_MIN_DISK_HEADROOM_MB:-}" ]]
    }

    acquire_admission_lock() {
      local lock_file="${CLASP_MANAGED_JOB_ADMISSION_LOCK_FILE:-}"
      local lock_dir=""

      admission_lock_required || return 0
      if [[ -z "$lock_file" ]]; then
        {
          printf "reason=missing-admission-lock-file\n"
          date -u +"detected_at=%Y-%m-%dT%H:%M:%SZ"
        } >"$job_dir/admission-error"
        printf "admission-lock-unavailable\n" >"$job_dir/status"
        finish_managed_job 125
      fi
      if ! command -v flock >/dev/null 2>&1; then
        {
          printf "reason=flock-unavailable\n"
          printf "lock_file=%s\n" "$lock_file"
          date -u +"detected_at=%Y-%m-%dT%H:%M:%SZ"
        } >"$job_dir/admission-error"
        printf "admission-lock-unavailable\n" >"$job_dir/status"
        finish_managed_job 125
      fi

      lock_dir="$(dirname "$lock_file")"
      if ! mkdir -p "$lock_dir"; then
        {
          printf "reason=admission-lock-directory-unavailable\n"
          printf "lock_file=%s\n" "$lock_file"
          date -u +"detected_at=%Y-%m-%dT%H:%M:%SZ"
        } >"$job_dir/admission-error"
        printf "admission-lock-unavailable\n" >"$job_dir/status"
        finish_managed_job 125
      fi
      if ! exec 8>"$lock_file"; then
        {
          printf "reason=admission-lock-open-failed\n"
          printf "lock_file=%s\n" "$lock_file"
          date -u +"detected_at=%Y-%m-%dT%H:%M:%SZ"
        } >"$job_dir/admission-error"
        printf "admission-lock-unavailable\n" >"$job_dir/status"
        finish_managed_job 125
      fi
      if ! flock -x 8; then
        {
          printf "reason=admission-lock-flock-failed\n"
          printf "lock_file=%s\n" "$lock_file"
          date -u +"detected_at=%Y-%m-%dT%H:%M:%SZ"
        } >"$job_dir/admission-error"
        printf "admission-lock-unavailable\n" >"$job_dir/status"
        finish_managed_job 125
      fi
      admission_lock_held=1
      printf "%s\n" "$lock_file" >"$job_dir/admission-lock"
    }

    release_admission_lock() {
      if [[ "${admission_lock_held:-0}" == "1" ]]; then
        flock -u 8 >/dev/null 2>&1 || true
        exec 8>&- || true
        admission_lock_held=0
      fi
    }

    preflight_host_memory_reserve() {
      local min_available_memory_mb="${CLASP_MANAGED_JOB_MIN_AVAILABLE_MEMORY_MB:-}"
      local memory_exceeded_path="$job_dir/memory-exceeded"
      local required_available_memory_mb=""
      local available_memory_mb=""
      local existing_budget_mb="0"
      local external_agent_count="0"
      local external_agent_rss_mb="0"
      local external_agent_reserved_memory_mb="0"
      local external_agent_reserve_per_process_mb="${CLASP_MANAGED_JOB_EXTERNAL_AGENT_RESERVE_MB:-0}"

      if [[ "$min_available_memory_mb" =~ ^[0-9]+$ && "$min_available_memory_mb" -gt 0 ]]; then
        required_available_memory_mb="$min_available_memory_mb"
        if [[ "${CLASP_MANAGED_JOB_MEMORY_MB:-}" =~ ^[0-9]+$ && "$CLASP_MANAGED_JOB_MEMORY_MB" -gt 0 ]]; then
          required_available_memory_mb="$((required_available_memory_mb + CLASP_MANAGED_JOB_MEMORY_MB))"
        fi
        external_agent_count="$(live_external_agent_process_count)"
        if [[ "$external_agent_count" =~ ^[0-9]+$ && "$external_agent_count" -gt 0 ]]; then
          external_agent_rss_mb="$(live_external_agent_rss_mb)"
          [[ "$external_agent_rss_mb" =~ ^[0-9]+$ ]] || external_agent_rss_mb="0"
          if [[ "$external_agent_reserve_per_process_mb" =~ ^[0-9]+$ ]]; then
            external_agent_reserved_memory_mb="$((external_agent_rss_mb + external_agent_count * external_agent_reserve_per_process_mb))"
          else
            external_agent_reserved_memory_mb="$external_agent_rss_mb"
          fi
          required_available_memory_mb="$((required_available_memory_mb + external_agent_reserved_memory_mb))"
        else
          external_agent_count="0"
          external_agent_rss_mb="0"
          external_agent_reserved_memory_mb="0"
        fi
        existing_budget_mb="$(live_managed_memory_budget_mb)"
        if [[ "$existing_budget_mb" =~ ^[0-9]+$ && "$existing_budget_mb" -gt 0 ]]; then
          required_available_memory_mb="$((required_available_memory_mb + existing_budget_mb))"
        else
          existing_budget_mb="0"
        fi
        available_memory_mb="$(host_available_memory_mb)"
        if [[ "$available_memory_mb" =~ ^[0-9]+$ ]] && (( available_memory_mb < required_available_memory_mb )); then
          {
            printf "min_available_memory_mb=%s\n" "$min_available_memory_mb"
            if [[ "${CLASP_MANAGED_JOB_MEMORY_MB:-}" =~ ^[0-9]+$ && "$CLASP_MANAGED_JOB_MEMORY_MB" -gt 0 ]]; then
              printf "memory_mb=%s\n" "$CLASP_MANAGED_JOB_MEMORY_MB"
            fi
            printf "external_agent_process_names=%s\n" "${CLASP_MANAGED_JOB_EXTERNAL_AGENT_PROCESS_NAMES:-codex}"
            printf "external_agent_process_count=%s\n" "$external_agent_count"
            printf "external_agent_rss_mb=%s\n" "$external_agent_rss_mb"
            printf "external_agent_reserve_per_process_mb=%s\n" "$external_agent_reserve_per_process_mb"
            printf "external_agent_reserved_memory_mb=%s\n" "$external_agent_reserved_memory_mb"
            printf "running_managed_memory_budget_mb=%s\n" "$existing_budget_mb"
            printf "required_available_memory_mb=%s\n" "$required_available_memory_mb"
            printf "available_memory_mb=%s\n" "$available_memory_mb"
            printf "reason=host-available-memory-reserve\n"
            printf "phase=preflight\n"
            date -u +"detected_at=%Y-%m-%dT%H:%M:%SZ"
          } >"$memory_exceeded_path"
          printf "memory-exceeded\n" >"$job_dir/status"
          finish_managed_job 137
        fi
      fi
    }

    preflight_host_disk_reserve() {
      local min_available_disk_mb="${CLASP_MANAGED_JOB_MIN_AVAILABLE_DISK_MB:-0}"
      local min_disk_headroom_mb="${CLASP_MANAGED_JOB_MIN_DISK_HEADROOM_MB:-0}"
      local disk_reserve_path="${CLASP_MANAGED_JOB_DISK_RESERVE_PATH:-$PWD}"
      local disk_exceeded_path="$job_dir/disk-exceeded"
      local available_disk_mb=""
      local disk_headroom_mb=""

      if [[ "$min_available_disk_mb" =~ ^[0-9]+$ && "$min_disk_headroom_mb" =~ ^[0-9]+$ ]] &&
         (( min_available_disk_mb > 0 || min_disk_headroom_mb > 0 )); then
        available_disk_mb="$(host_available_disk_mb "$disk_reserve_path")"
        if [[ "$available_disk_mb" =~ ^[0-9]+$ ]] && (( available_disk_mb < min_available_disk_mb )); then
          {
            printf "min_available_disk_mb=%s\n" "$min_available_disk_mb"
            printf "min_disk_headroom_mb=%s\n" "$min_disk_headroom_mb"
            printf "available_disk_mb=%s\n" "$available_disk_mb"
            printf "disk_reserve_path=%s\n" "$disk_reserve_path"
            printf "reason=host-available-disk-reserve\n"
            printf "phase=preflight\n"
            record_disk_recovery_hint
            date -u +"detected_at=%Y-%m-%dT%H:%M:%SZ"
          } >"$disk_exceeded_path"
          printf "disk-exceeded\n" >"$job_dir/status"
          finish_managed_job 123
        fi
        if [[ "$available_disk_mb" =~ ^[0-9]+$ ]] && (( min_disk_headroom_mb > 0 )); then
          disk_headroom_mb="$((available_disk_mb - min_available_disk_mb))"
          if (( disk_headroom_mb < min_disk_headroom_mb )); then
            {
              printf "min_available_disk_mb=%s\n" "$min_available_disk_mb"
              printf "min_disk_headroom_mb=%s\n" "$min_disk_headroom_mb"
              printf "available_disk_mb=%s\n" "$available_disk_mb"
              printf "disk_headroom_mb=%s\n" "$disk_headroom_mb"
              printf "disk_reserve_path=%s\n" "$disk_reserve_path"
              printf "reason=host-available-disk-headroom\n"
              printf "phase=preflight\n"
              record_disk_recovery_hint
              date -u +"detected_at=%Y-%m-%dT%H:%M:%SZ"
            } >"$disk_exceeded_path"
            printf "disk-exceeded\n" >"$job_dir/status"
            finish_managed_job 123
          fi
        fi
      fi
    }

    watch_stop_request() {
      local sid="$1"
      local stop_file="$CLASP_MANAGED_JOB_STOP_REQUEST"
      while true; do
        if [[ -f "$stop_file" ]]; then
          printf "stopping\n" >"$job_dir/status"
          if [[ -n "${CLASP_MANAGED_JOB_MEMORY_MB:-}" ||
                -n "${CLASP_MANAGED_JOB_MIN_AVAILABLE_MEMORY_MB:-}" ||
                -n "${CLASP_MANAGED_JOB_MIN_AVAILABLE_DISK_MB:-}" ||
                -n "${CLASP_MANAGED_JOB_MIN_DISK_HEADROOM_MB:-}" ]]; then
            stop_job_members "$sid"
          else
            stop_session_members "$sid"
          fi
          return 0
        fi
        sleep 0.2
      done
    }

    watch_memory_limit() {
      local sid="$1"
      local memory_limit_kb=""
      if [[ -n "${CLASP_MANAGED_JOB_MEMORY_MB:-}" ]]; then
        memory_limit_kb="$((CLASP_MANAGED_JOB_MEMORY_MB * 1024))"
      fi
      local min_available_memory_mb="${CLASP_MANAGED_JOB_MIN_AVAILABLE_MEMORY_MB:-}"
      local min_available_disk_mb="${CLASP_MANAGED_JOB_MIN_AVAILABLE_DISK_MB:-0}"
      local min_disk_headroom_mb="${CLASP_MANAGED_JOB_MIN_DISK_HEADROOM_MB:-0}"
      local disk_reserve_path="${CLASP_MANAGED_JOB_DISK_RESERVE_PATH:-$PWD}"
      local memory_exceeded_path="$job_dir/memory-exceeded"
      local disk_exceeded_path="$job_dir/disk-exceeded"
      local rss_kb=""
      local available_memory_mb=""
      local existing_budget_mb="0"
      local external_agent_count="0"
      local external_agent_rss_mb="0"
      local external_agent_reserved_memory_mb="0"
      local external_agent_reserve_per_process_mb="${CLASP_MANAGED_JOB_EXTERNAL_AGENT_RESERVE_MB:-0}"
      local required_available_memory_mb=""
      local available_disk_mb=""
      local disk_headroom_mb=""

      # Let the parent launcher record pid/pgid/sid before an immediate guard trip.
      sleep 0.1

      while true; do
        if [[ -n "$memory_limit_kb" ]]; then
          rss_kb="$(session_rss_kb "$sid")"
        fi
        if [[ -n "$memory_limit_kb" && "$rss_kb" =~ ^[0-9]+$ ]] && (( rss_kb > memory_limit_kb )); then
          {
            printf "limit_mb=%s\n" "$CLASP_MANAGED_JOB_MEMORY_MB"
            printf "rss_kb=%s\n" "$rss_kb"
            printf "reason=session-rss-limit\n"
            date -u +"detected_at=%Y-%m-%dT%H:%M:%SZ"
          } >"$memory_exceeded_path"
          printf "memory-exceeded\n" >"$job_dir/status"
          stop_job_members "$sid"
          return 0
        fi
        if [[ -n "$memory_limit_kb" ]]; then
          rss_kb="$(job_rss_kb "$sid")"
        fi
        if [[ -n "$memory_limit_kb" && "$rss_kb" =~ ^[0-9]+$ ]] && (( rss_kb > memory_limit_kb )); then
          {
            printf "limit_mb=%s\n" "$CLASP_MANAGED_JOB_MEMORY_MB"
            printf "rss_kb=%s\n" "$rss_kb"
            printf "reason=job-rss-limit\n"
            date -u +"detected_at=%Y-%m-%dT%H:%M:%SZ"
          } >"$memory_exceeded_path"
          printf "memory-exceeded\n" >"$job_dir/status"
          stop_job_members "$sid"
          return 0
        fi

        if [[ "$min_available_memory_mb" =~ ^[0-9]+$ && "$min_available_memory_mb" -gt 0 ]]; then
          required_available_memory_mb="$min_available_memory_mb"
          external_agent_count="0"
          external_agent_rss_mb="0"
          external_agent_reserved_memory_mb="0"
          external_agent_count="$(live_external_agent_process_count)"
          if [[ "$external_agent_count" =~ ^[0-9]+$ && "$external_agent_count" -gt 0 ]]; then
            external_agent_rss_mb="$(live_external_agent_rss_mb)"
            [[ "$external_agent_rss_mb" =~ ^[0-9]+$ ]] || external_agent_rss_mb="0"
            if [[ "$external_agent_reserve_per_process_mb" =~ ^[0-9]+$ ]]; then
              external_agent_reserved_memory_mb="$((external_agent_rss_mb + external_agent_count * external_agent_reserve_per_process_mb))"
            else
              external_agent_reserved_memory_mb="$external_agent_rss_mb"
            fi
            required_available_memory_mb="$((required_available_memory_mb + external_agent_reserved_memory_mb))"
          else
            external_agent_count="0"
            external_agent_rss_mb="0"
            external_agent_reserved_memory_mb="0"
          fi
          existing_budget_mb="$(live_managed_memory_budget_mb)"
          if [[ "$existing_budget_mb" =~ ^[0-9]+$ && "$existing_budget_mb" -gt 0 ]]; then
            required_available_memory_mb="$((required_available_memory_mb + existing_budget_mb))"
          else
            existing_budget_mb="0"
          fi
          available_memory_mb="$(host_available_memory_mb)"
          if [[ "$available_memory_mb" =~ ^[0-9]+$ ]] && (( available_memory_mb < required_available_memory_mb )); then
            {
              printf "min_available_memory_mb=%s\n" "$min_available_memory_mb"
              printf "external_agent_process_names=%s\n" "${CLASP_MANAGED_JOB_EXTERNAL_AGENT_PROCESS_NAMES:-codex}"
              printf "external_agent_process_count=%s\n" "$external_agent_count"
              printf "external_agent_rss_mb=%s\n" "$external_agent_rss_mb"
              printf "external_agent_reserve_per_process_mb=%s\n" "$external_agent_reserve_per_process_mb"
              printf "external_agent_reserved_memory_mb=%s\n" "$external_agent_reserved_memory_mb"
              printf "running_managed_memory_budget_mb=%s\n" "$existing_budget_mb"
              printf "required_available_memory_mb=%s\n" "$required_available_memory_mb"
              printf "available_memory_mb=%s\n" "$available_memory_mb"
              printf "reason=host-available-memory-reserve\n"
              printf "phase=watch\n"
              date -u +"detected_at=%Y-%m-%dT%H:%M:%SZ"
            } >"$memory_exceeded_path"
            printf "memory-exceeded\n" >"$job_dir/status"
            stop_job_members "$sid"
            return 0
          fi
        fi

        if [[ "$min_available_disk_mb" =~ ^[0-9]+$ && "$min_disk_headroom_mb" =~ ^[0-9]+$ ]] &&
           (( min_available_disk_mb > 0 || min_disk_headroom_mb > 0 )); then
          available_disk_mb="$(host_available_disk_mb "$disk_reserve_path")"
          if [[ "$available_disk_mb" =~ ^[0-9]+$ ]] && (( available_disk_mb < min_available_disk_mb )); then
            {
              printf "min_available_disk_mb=%s\n" "$min_available_disk_mb"
              printf "min_disk_headroom_mb=%s\n" "$min_disk_headroom_mb"
              printf "available_disk_mb=%s\n" "$available_disk_mb"
              printf "disk_reserve_path=%s\n" "$disk_reserve_path"
              printf "reason=host-available-disk-reserve\n"
              printf "phase=watch\n"
              record_disk_recovery_hint
              date -u +"detected_at=%Y-%m-%dT%H:%M:%SZ"
            } >"$disk_exceeded_path"
            printf "disk-exceeded\n" >"$job_dir/status"
            stop_job_members "$sid"
            return 0
          fi
          if [[ "$available_disk_mb" =~ ^[0-9]+$ ]] && (( min_disk_headroom_mb > 0 )); then
            disk_headroom_mb="$((available_disk_mb - min_available_disk_mb))"
            if (( disk_headroom_mb < min_disk_headroom_mb )); then
              {
                printf "min_available_disk_mb=%s\n" "$min_available_disk_mb"
                printf "min_disk_headroom_mb=%s\n" "$min_disk_headroom_mb"
                printf "available_disk_mb=%s\n" "$available_disk_mb"
                printf "disk_headroom_mb=%s\n" "$disk_headroom_mb"
                printf "disk_reserve_path=%s\n" "$disk_reserve_path"
                printf "reason=host-available-disk-headroom\n"
                printf "phase=watch\n"
                record_disk_recovery_hint
                date -u +"detected_at=%Y-%m-%dT%H:%M:%SZ"
              } >"$disk_exceeded_path"
              printf "disk-exceeded\n" >"$job_dir/status"
              stop_job_members "$sid"
              return 0
            fi
          fi
        fi

        sleep 0.5
      done
    }

    should_use_systemd_memory_scope() {
      local preference="${CLASP_MANAGED_JOB_USE_SYSTEMD_SCOPE:-required}"

      [[ -n "${CLASP_MANAGED_JOB_MEMORY_MB:-}" ]] || return 1
      [[ "$preference" != "0" && "$preference" != "false" && "$preference" != "never" ]] || return 1
      command -v systemd-run >/dev/null 2>&1 || return 1
      systemctl --user is-active --quiet default.target >/dev/null 2>&1 || return 1
      return 0
    }

    systemd_memory_scope_required() {
      local preference="${CLASP_MANAGED_JOB_USE_SYSTEMD_SCOPE:-required}"

      case "$preference" in
        required|require|1|true|always)
          return 0
          ;;
        *)
          return 1
          ;;
      esac
    }

    start_workload() {
      if should_use_systemd_memory_scope; then
        local memory_high_mb="$((CLASP_MANAGED_JOB_MEMORY_MB * 98 / 100))"
        if (( memory_high_mb < 1 )); then
          memory_high_mb=1
        fi
        printf "systemd-scope\n" >"$job_dir/memory-enforcer"
        env CLASP_MANAGED_JOB_WORKLOAD=1 \
          systemd-run \
          --user \
          --scope \
          --quiet \
          --collect \
          --setenv="CLASP_MANAGED_JOB_ID=$expected_job_id" \
          --setenv="CLASP_MANAGED_JOB_ROOT=$expected_job_root" \
          --setenv="CLASP_MANAGED_JOB_TOKEN=$expected_job_token" \
          --setenv="CLASP_MANAGED_JOB_STOP_REQUEST=$CLASP_MANAGED_JOB_STOP_REQUEST" \
          --setenv="CLASP_MANAGED_JOB_MEMORY_MB=$CLASP_MANAGED_JOB_MEMORY_MB" \
          --setenv="CLASP_MANAGED_JOB_MIN_AVAILABLE_MEMORY_MB=$CLASP_MANAGED_JOB_MIN_AVAILABLE_MEMORY_MB" \
          --setenv="CLASP_MANAGED_JOB_MIN_AVAILABLE_DISK_MB=$CLASP_MANAGED_JOB_MIN_AVAILABLE_DISK_MB" \
          --setenv="CLASP_MANAGED_JOB_MIN_DISK_HEADROOM_MB=$CLASP_MANAGED_JOB_MIN_DISK_HEADROOM_MB" \
          --setenv="CLASP_MANAGED_JOB_DISK_RESERVE_PATH=$CLASP_MANAGED_JOB_DISK_RESERVE_PATH" \
          --setenv="CLASP_MANAGED_JOB_EXTERNAL_AGENT_RESERVE_MB=$CLASP_MANAGED_JOB_EXTERNAL_AGENT_RESERVE_MB" \
          --setenv="CLASP_MANAGED_JOB_EXTERNAL_AGENT_PROCESS_NAMES=$CLASP_MANAGED_JOB_EXTERNAL_AGENT_PROCESS_NAMES" \
          --setenv="CLASP_MANAGED_JOB_MEMORY_BUDGET_SCOPE=$CLASP_MANAGED_JOB_MEMORY_BUDGET_SCOPE" \
          --setenv="CLASP_MANAGED_JOB_EXCLUDE_PARENT_BUDGET=$exclude_parent_budget" \
          --setenv="CLASP_MANAGED_JOB_WORKLOAD=1" \
          -p MemoryAccounting=yes \
          -p "MemoryHigh=${memory_high_mb}M" \
          -p "MemoryMax=${CLASP_MANAGED_JOB_MEMORY_MB}M" \
          bash -c '"'"'ulimit -c 0 >/dev/null 2>&1 || true; exec "$@"'"'"' managed-core-wrapper "$@" &
      else
        if [[ -n "${CLASP_MANAGED_JOB_MEMORY_MB:-}" ]]; then
          printf "session-rss-watch\n" >"$job_dir/memory-enforcer"
        fi
        env CLASP_MANAGED_JOB_WORKLOAD=1 "$@" &
      fi
      child_pid="$!"
    }

    record_runner_metadata() {
      {
        printf "%s\n" "$$"
      } >"$job_dir/pid"
      {
        ps -o pgid= -p "$$" | trim_spaces
      } >"$job_dir/pgid"
      {
        current_sid
      } >"$job_dir/sid"
      {
        printf "%s\n" "$PWD"
      } >"$job_dir/cwd"
      {
        date -u +%Y-%m-%dT%H:%M:%SZ
      } >"$job_dir/started-at"
    }

    apply_virtual_memory_limit() {
      local requested_kb="$((CLASP_MANAGED_JOB_MEMORY_MB * 1024))"
      local current_limit

      current_limit="$(ulimit -v 2>/dev/null || printf "unknown")"
      if [[ "$current_limit" =~ ^[0-9]+$ ]] && (( requested_kb > current_limit )); then
        {
          printf "%s\n" "$((current_limit / 1024))"
        } >"$job_dir/effective-memory-mb"
        {
          printf "requested_mb=%s\n" "$CLASP_MANAGED_JOB_MEMORY_MB"
          printf "inherited_limit_mb=%s\n" "$((current_limit / 1024))"
        } >"$job_dir/inherited-memory-limit"
        return 0
      fi

      ulimit -v "$requested_kb" || finish_managed_job 125
      {
        printf "%s\n" "$CLASP_MANAGED_JOB_MEMORY_MB"
      } >"$job_dir/effective-memory-mb"
    }

    apply_memory_limit() {
      local requested_kb="$((CLASP_MANAGED_JOB_MEMORY_MB * 1024))"
      local current_limit

      if ! should_use_systemd_memory_scope; then
        if systemd_memory_scope_required; then
          {
            printf "requested_mb=%s\n" "$CLASP_MANAGED_JOB_MEMORY_MB"
            printf "preference=%s\n" "${CLASP_MANAGED_JOB_USE_SYSTEMD_SCOPE:-required}"
            printf "reason=systemd-scope-required-unavailable\n"
            date -u +"detected_at=%Y-%m-%dT%H:%M:%SZ"
          } >"$job_dir/memory-enforcer-error"
          printf "memory-enforcer-unavailable\n" >"$job_dir/status"
          finish_managed_job 125
        fi
        apply_virtual_memory_limit
        return 0
      fi

      current_limit="$(ulimit -v 2>/dev/null || printf "unknown")"
      if [[ "$current_limit" =~ ^[0-9]+$ ]] && (( requested_kb > current_limit )); then
        {
          printf "%s\n" "$((current_limit / 1024))"
        } >"$job_dir/effective-memory-mb"
        {
          printf "requested_mb=%s\n" "$CLASP_MANAGED_JOB_MEMORY_MB"
          printf "inherited_limit_mb=%s\n" "$((current_limit / 1024))"
        } >"$job_dir/inherited-memory-limit"
        return 0
      fi

      {
        printf "%s\n" "$CLASP_MANAGED_JOB_MEMORY_MB"
      } >"$job_dir/effective-memory-mb"
      {
        printf "systemd-scope\n"
      } >"$job_dir/effective-memory-enforcer"
    }

    signal_direct_children() {
      local parent_pid="$1"
      local signal="$2"
      local child_pid

      while IFS= read -r child_pid; do
        if [[ -n "$child_pid" && "$child_pid" =~ ^[0-9]+$ ]]; then
          kill "-$signal" "$child_pid" >/dev/null 2>&1 || true
        fi
      done < <(ps -o pid= --ppid "$parent_pid" 2>/dev/null || true)
    }

    stop_internal_watcher() {
      local pid="$1"

      if [[ -n "$pid" ]]; then
        signal_direct_children "$pid" TERM
        kill "$pid" >/dev/null 2>&1 || true
        wait "$pid" >/dev/null 2>&1 || true
        signal_direct_children "$pid" KILL
      fi
    }

    stop_internal_watchers() {
      stop_internal_watcher "${watcher_pid:-}"
      watcher_pid=""
      stop_internal_watcher "${memory_watcher_pid:-}"
      memory_watcher_pid=""
    }

    finish_managed_job() {
      local status="$1"
      local cleanup_sid=""
      local cleanup_scope="session"
      local recorded_job_status=""
      local final_job_status=""

      release_admission_lock
      stop_internal_watchers
      if [[ "${workload_started:-0}" == "1" ]]; then
        cleanup_sid="${managed_sid:-$(current_sid)}"
        if [[ -n "$cleanup_sid" ]]; then
          if [[ -n "${CLASP_MANAGED_JOB_MEMORY_MB:-}" ||
                -n "${CLASP_MANAGED_JOB_MIN_AVAILABLE_MEMORY_MB:-}" ||
                -n "${CLASP_MANAGED_JOB_MIN_AVAILABLE_DISK_MB:-}" ||
                -n "${CLASP_MANAGED_JOB_MIN_DISK_HEADROOM_MB:-}" ]]; then
            cleanup_scope="job"
          fi
          if [[ -f "$CLASP_MANAGED_JOB_STOP_REQUEST" &&
                -z "${CLASP_MANAGED_JOB_MEMORY_MB:-}" &&
                -z "${CLASP_MANAGED_JOB_MIN_AVAILABLE_MEMORY_MB:-}" &&
                -z "${CLASP_MANAGED_JOB_MIN_AVAILABLE_DISK_MB:-}" &&
                -z "${CLASP_MANAGED_JOB_MIN_DISK_HEADROOM_MB:-}" ]]; then
            cleanup_scope="session"
          fi
          if [[ "$cleanup_scope" == "job" ]]; then
            stop_job_members "$cleanup_sid"
          else
            stop_session_members "$cleanup_sid"
          fi
        fi
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
      recorded_job_status="$(sed -n '1p' "$job_dir/status" 2>/dev/null || true)"
      if [[ -f "$job_dir/memory-exceeded" && "$status" != "0" ]]; then
        status="137"
        final_job_status="memory-exceeded"
      fi
      if [[ -f "$job_dir/disk-exceeded" ]]; then
        status="123"
        final_job_status="disk-exceeded"
      fi
      if [[ -z "$final_job_status" ]]; then
        case "$recorded_job_status" in
          admission-lock-unavailable|memory-enforcer-unavailable)
            final_job_status="$recorded_job_status"
            ;;
        esac
      fi
      printf "%s\n" "$status" >"$job_dir/exit-status"
      if [[ -n "$final_job_status" ]]; then
        printf "%s\n" "$final_job_status" >"$job_dir/status"
      elif [[ -f "$CLASP_MANAGED_JOB_STOP_REQUEST" ]]; then
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
    cleanup_poll_iterations="${CLASP_MANAGED_JOB_CLEANUP_POLL_ITERATIONS:-10}"
    cleanup_poll_sleep_secs="${CLASP_MANAGED_JOB_CLEANUP_POLL_SLEEP_SECS:-0.05}"
    if ! [[ "$cleanup_poll_iterations" =~ ^[0-9]+$ ]] || (( cleanup_poll_iterations < 1 )); then
      cleanup_poll_iterations=10
    fi
    if ! [[ "$cleanup_poll_sleep_secs" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      cleanup_poll_sleep_secs=0.05
    fi

    record_runner_metadata
    acquire_admission_lock
    preflight_host_memory_reserve
    preflight_host_disk_reserve
    if [[ "${CLASP_MANAGED_JOB_PREFLIGHT_ONLY:-0}" == "1" ]]; then
      printf "preflight-passed\n" >"$job_dir/preflight-passed"
      finish_managed_job 0
    fi
    if [[ -n "${CLASP_MANAGED_JOB_MEMORY_MB:-}" ]]; then
      apply_memory_limit
    fi
    printf "ok\n" >"$job_dir/preflight-complete"

    start_workload "$@"
    workload_started=1
    release_admission_lock
    managed_sid="$(current_sid)"
    watch_stop_request "$managed_sid" >/dev/null 2>&1 &
    watcher_pid="$!"
    if [[ -n "${CLASP_MANAGED_JOB_MEMORY_MB:-}" ||
          -n "${CLASP_MANAGED_JOB_MIN_AVAILABLE_MEMORY_MB:-}" ||
          -n "${CLASP_MANAGED_JOB_MIN_AVAILABLE_DISK_MB:-}" ||
          -n "${CLASP_MANAGED_JOB_MIN_DISK_HEADROOM_MB:-}" ]]; then
      watch_memory_limit "$managed_sid" >/dev/null 2>&1 &
      memory_watcher_pid="$!"
    fi

    wait "$child_pid"
    finish_managed_job "$?"
  ' managed-job-runner "${command[@]}" \
  >"$stdout_path" 2>"$stderr_path" &
pid="$!"

for _ in $(seq 1 50); do
  if [[ -f "$job_dir/pid" && -f "$job_dir/pgid" && -f "$job_dir/sid" && -f "$job_dir/cwd" ]]; then
    break
  fi
  if ! kill -0 "$pid" >/dev/null 2>&1; then
    if [[ -f "$job_dir/pid" && -f "$job_dir/pgid" && -f "$job_dir/sid" && -f "$job_dir/cwd" && -f "$job_dir/exit-status" ]]; then
      printf '%s\n' "$job_dir"
      exit 0
    fi
  fi
  sleep 0.02
done
if ! kill -0 "$pid" >/dev/null 2>&1; then
  if [[ -f "$job_dir/pid" && -f "$job_dir/pgid" && -f "$job_dir/sid" && -f "$job_dir/cwd" && -f "$job_dir/exit-status" ]]; then
    printf '%s\n' "$job_dir"
    exit 0
  fi
  printf 'managed-job: command exited before metadata could be recorded: %s\n' "$job_id" >&2
  exit 1
fi

pgid="$(tr -d '[:space:]' <"$job_dir/pgid" 2>/dev/null || ps -o pgid= -p "$pid" | tr -d '[:space:]')"
sid="$(tr -d '[:space:]' <"$job_dir/sid" 2>/dev/null || ps -o sid= -p "$pid" | tr -d '[:space:]')"
if [[ -z "$pgid" || -z "$sid" ]]; then
  for _ in $(seq 1 50); do
    if [[ -f "$job_dir/pgid" && -f "$job_dir/sid" ]]; then
      pgid="$(tr -d '[:space:]' <"$job_dir/pgid" 2>/dev/null)"
      sid="$(tr -d '[:space:]' <"$job_dir/sid" 2>/dev/null)"
      if [[ -n "$pgid" && -n "$sid" ]]; then
        break
      fi
    fi
    sleep 0.02
  done
fi
if [[ -z "$pgid" || -z "$sid" ]]; then
  if [[ -f "$job_dir/pid" && -f "$job_dir/pgid" && -f "$job_dir/sid" && -f "$job_dir/cwd" && -f "$job_dir/exit-status" ]]; then
    printf '%s\n' "$job_dir"
    exit 0
  fi
  printf 'managed-job: failed to inspect launched job process: %s\n' "$job_id" >&2
  exit 1
fi

{
  printf '%s\n' "$pgid"
} >"$job_dir/pgid"
{
  printf '%s\n' "$sid"
} >"$job_dir/sid"
if [[ ! -f "$job_dir/pid" ]]; then
  {
    printf '%s\n' "$pid"
  } >"$job_dir/pid"
fi
{
  printf '%s\n' "$project_root"
} >"$job_dir/cwd"
{
  date -u +%Y-%m-%dT%H:%M:%SZ
} >"$job_dir/started-at"

disown "$pid" >/dev/null 2>&1 || true
printf '%s\n' "$job_dir"
