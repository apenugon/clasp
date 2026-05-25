#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$project_root/scripts/clasp-swarm-common.sh"

usage() {
  cat <<'EOF' >&2
usage: scripts/clasp-swarm-stop.sh [--force-signal] [wave]

By default this requests cooperative managed-job stops. --force-signal passes
through to stop-managed-job.sh, which only signals marked managed-job session
members after validating the job metadata.
EOF
}

wave_name=""
force_signal_args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force-signal)
      force_signal_args=(--force-signal)
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    -*)
      usage
      exit 2
      ;;
    *)
      if [[ -n "$wave_name" ]]; then
        usage
        exit 2
      fi
      wave_name="$1"
      shift
      ;;
  esac
done

if [[ -z "$wave_name" ]]; then
  wave_name="$(clasp_swarm_default_wave)"
fi

while IFS= read -r lane_dir; do
  lane_name="$(clasp_swarm_lane_name "$lane_dir")"
  runtime_root="$project_root/.clasp-swarm/$wave_name/$lane_name"
  pid_file="$runtime_root/pid"
  job_file="$runtime_root/job"

  if [[ -f "$job_file" ]]; then
    job_dir="$(sed -n '1p' "$job_file")"
    pid=""
    if [[ -f "$job_dir/pid" ]]; then
      pid="$(tr -d '[:space:]' <"$job_dir/pid")"
    fi
    if "$project_root/scripts/stop-managed-job.sh" "${force_signal_args[@]}" --jobs-root "$runtime_root/jobs" "$job_dir"; then
      if [[ -n "$pid" ]]; then
        echo "stopped lane=$lane_name pid=$pid"
      else
        echo "stopped lane=$lane_name"
      fi
      rm -f "$pid_file" "$job_file"
    else
      echo "failed to stop lane=$lane_name via managed job metadata" >&2
      exit 1
    fi
    continue
  fi

  if [[ ! -f "$pid_file" ]]; then
    echo "lane $lane_name is not running"
    continue
  fi

  pid="$(cat "$pid_file")"

  if kill -0 "$pid" >/dev/null 2>&1; then
    echo "lane $lane_name has unmanaged pid $pid; refusing to signal without managed-job metadata" >&2
    exit 1
  else
    echo "lane $lane_name had stale pid $pid"
  fi

  rm -f "$pid_file"
done < <(clasp_swarm_lane_dirs "$wave_name" "$project_root")
