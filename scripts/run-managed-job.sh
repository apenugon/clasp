#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
jobs_root="${CLASP_MANAGED_JOB_ROOT:-$project_root/.clasp-loops/jobs}"
job_id=""

usage() {
  cat <<'EOF' >&2
usage: scripts/run-managed-job.sh [--job-id <id>] [--jobs-root <dir>] -- <command> [args...]

Launches a command in an isolated session/process group and records metadata
that scripts/stop-managed-job.sh validates before stopping it.
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
  job_id="job-$(date +%Y%m%d%H%M%S)-$$"
fi
if ! safe_job_id "$job_id"; then
  printf 'managed-job: invalid job id: %s\n' "$job_id" >&2
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

printf '%q' "${command[0]}" >"$command_path"
for arg in "${command[@]:1}"; do
  printf ' %q' "$arg" >>"$command_path"
done
printf '\n' >>"$command_path"

cd "$project_root"
setsid env \
  CLASP_MANAGED_JOB_ID="$job_id" \
  CLASP_MANAGED_JOB_ROOT="$jobs_root" \
  "${command[@]}" \
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
{
  printf 'started\n'
} >"$job_dir/status"

disown "$pid" >/dev/null 2>&1 || true
printf '%s\n' "$job_dir"
