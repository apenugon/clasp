#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
jobs_root="${CLASP_MANAGED_JOB_ROOT:-$project_root/.clasp-loops/jobs}"
job_id=""
kill_after_secs="${CLASP_MANAGED_JOB_KILL_AFTER_SECS:-5}"

usage() {
  cat <<'EOF' >&2
usage: scripts/stop-managed-job.sh [--jobs-root <dir>] <job-id-or-dir>

Stops only jobs launched by scripts/run-managed-job.sh. The recorded process
group/session must be isolated from the current shell before any signal is sent.
EOF
}

trim_file() {
  tr -d '[:space:]' <"$1"
}

safe_job_id() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]
}

current_pgid() {
  ps -o pgid= -p "$$" | tr -d '[:space:]'
}

current_sid() {
  ps -o sid= -p "$$" | tr -d '[:space:]'
}

process_has_marker() {
  local pid="$1"
  local expected_job_id="$2"
  local expected_root="$3"

  if [[ ! -r "/proc/$pid/environ" ]]; then
    return 1
  fi
  tr '\0' '\n' <"/proc/$pid/environ" | grep -Fx "CLASP_MANAGED_JOB_ID=$expected_job_id" >/dev/null &&
    tr '\0' '\n' <"/proc/$pid/environ" | grep -Fx "CLASP_MANAGED_JOB_ROOT=$expected_root" >/dev/null
}

session_has_members() {
  local sid="$1"
  ps -eo sid= | awk -v want="$sid" '{ gsub(/[[:space:]]/, "", $1); if ($1 == want) found = 1 } END { exit found ? 0 : 1 }'
}

session_pgids() {
  local sid="$1"
  ps -eo pgid=,sid= |
    awk -v want="$sid" '
      {
        pgid = $1
        sid = $2
        gsub(/[[:space:]]/, "", pgid)
        gsub(/[[:space:]]/, "", sid)
        if (sid == want && pgid != "") seen[pgid] = 1
      }
      END {
        for (pgid in seen) print pgid
      }
    '
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --jobs-root)
      jobs_root="${2:-}"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -*)
      usage
      exit 2
      ;;
    *)
      job_id="$1"
      shift
      break
      ;;
  esac
done

if [[ -z "$job_id" || $# -gt 0 ]]; then
  usage
  exit 2
fi

jobs_root="$(cd "$jobs_root" && pwd -P)"
if [[ -d "$job_id" ]]; then
  job_dir="$(cd "$job_id" && pwd -P)"
  job_id="$(basename "$job_dir")"
else
  if ! safe_job_id "$job_id"; then
    printf 'managed-job-stop: invalid job id: %s\n' "$job_id" >&2
    exit 2
  fi
  job_dir="$jobs_root/$job_id"
fi

case "$job_dir" in
  "$jobs_root"/*)
    ;;
  *)
    printf 'managed-job-stop: refusing job outside jobs root: %s\n' "$job_dir" >&2
    exit 2
    ;;
esac

for required in pid pgid sid cwd; do
  if [[ ! -f "$job_dir/$required" ]]; then
    printf 'managed-job-stop: missing metadata %s for %s\n' "$required" "$job_id" >&2
    exit 1
  fi
done

pid="$(trim_file "$job_dir/pid")"
pgid="$(trim_file "$job_dir/pgid")"
sid="$(trim_file "$job_dir/sid")"
cwd="$(sed -n '1p' "$job_dir/cwd")"

if ! [[ "$pid" =~ ^[0-9]+$ && "$pgid" =~ ^[0-9]+$ && "$sid" =~ ^[0-9]+$ ]]; then
  printf 'managed-job-stop: invalid numeric metadata for %s\n' "$job_id" >&2
  exit 1
fi

if [[ "$pgid" == "$(current_pgid)" || "$sid" == "$(current_sid)" ]]; then
  printf 'managed-job-stop: refusing to stop current shell process group/session for %s\n' "$job_id" >&2
  exit 1
fi

case "$cwd" in
  "$project_root"|"$project_root"/*)
    ;;
  *)
    printf 'managed-job-stop: refusing job cwd outside project root: %s\n' "$cwd" >&2
    exit 1
    ;;
esac

root_is_live=0
if kill -0 "$pid" >/dev/null 2>&1; then
  root_is_live=1
fi

if [[ "$root_is_live" == "1" ]]; then
  actual_pgid="$(ps -o pgid= -p "$pid" | tr -d '[:space:]')"
  actual_sid="$(ps -o sid= -p "$pid" | tr -d '[:space:]')"
  if [[ "$actual_pgid" != "$pgid" || "$actual_sid" != "$sid" ]]; then
    printf 'managed-job-stop: live process metadata mismatch for %s\n' "$job_id" >&2
    exit 1
  fi

  if ! process_has_marker "$pid" "$job_id" "$jobs_root"; then
    printf 'managed-job-stop: live process is missing managed-job marker env for %s\n' "$job_id" >&2
    exit 1
  fi
elif ! session_has_members "$sid"; then
  printf 'stopped\n' >"$job_dir/status"
  printf 'managed-job-stop: job already exited: %s\n' "$job_id" >&2
  exit 0
else
  printf 'managed-job-stop: root exited; stopping remaining isolated session members for %s\n' "$job_id" >&2
fi

printf 'stopping\n' >"$job_dir/status"
while IFS= read -r session_pgid; do
  if [[ -n "$session_pgid" && "$session_pgid" != "$(current_pgid)" ]]; then
    kill -TERM -- "-$session_pgid" >/dev/null 2>&1 || true
  fi
done < <(session_pgids "$sid")

for _ in $(seq 1 50); do
  if ! session_has_members "$sid"; then
    printf 'stopped\n' >"$job_dir/status"
    printf 'managed-job-stop: stopped %s\n' "$job_id"
    exit 0
  fi
  sleep 0.1
done

if [[ "$kill_after_secs" =~ ^[0-9]+$ && "$kill_after_secs" != "0" ]]; then
  while IFS= read -r session_pgid; do
    if [[ -n "$session_pgid" && "$session_pgid" != "$(current_pgid)" ]]; then
      kill -KILL -- "-$session_pgid" >/dev/null 2>&1 || true
    fi
  done < <(session_pgids "$sid")
fi

for _ in $(seq 1 20); do
  if ! session_has_members "$sid"; then
    printf 'stopped\n' >"$job_dir/status"
    printf 'managed-job-stop: stopped %s\n' "$job_id"
    exit 0
  fi
  sleep 0.1
done

printf 'managed-job-stop: session still has members after stop: %s\n' "$job_id" >&2
exit 1
