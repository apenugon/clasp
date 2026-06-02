#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$project_root/scripts/clasp-swarm-common.sh"

usage() {
  echo "usage: $0 [--json] [wave-name]" >&2
}

count_files() {
  local target_dir="$1"

  if [[ -d "$target_dir" ]]; then
    find "$target_dir" -type f | wc -l | tr -d '[:space:]'
  else
    printf '0\n'
  fi
}

count_task_files() {
  local lane_dir="$1"

  if [[ -d "$lane_dir" ]]; then
    find "$lane_dir" -maxdepth 1 -type f -name '*.md' | wc -l | tr -d '[:space:]'
  else
    printf '0\n'
  fi
}

marker_value() {
  local marker_file="$1"
  local marker_key="$2"

  if [[ ! -f "$marker_file" ]]; then
    return 0
  fi

  awk -F= -v marker_key="$marker_key" '
    $1 == marker_key {
      sub(/^[^=]*=/, "", $0)
      print
      exit
    }
  ' "$marker_file"
}

latest_child_job_dir() {
  local child_jobs_root="$1"

  if [[ ! -d "$child_jobs_root" ]]; then
    return 0
  fi

  while IFS= read -r child_dir; do
    local started_at=""
    local started_epoch="0"
    local modified_at="0"

    if [[ -f "$child_dir/started-at" ]]; then
      started_at="$(sed -n '1p' "$child_dir/started-at")"
      started_epoch="$(date -u -d "$started_at" +%s 2>/dev/null || printf '0')"
    fi

    modified_at="$(find "$child_dir" -maxdepth 0 -printf '%T@\n' 2>/dev/null || printf '0')"
    printf '%s\t%s\t%s\n' "$started_epoch" "$modified_at" "$child_dir"
  done < <(find "$child_jobs_root" -mindepth 1 -maxdepth 1 -type d)
}

collect_latest_run_state() {
  local runs_root="$1"
  local lane_name="$2"
  local lane_status="$3"
  local job_status="$4"
  local job_memory_exceeded="$5"
  local job_disk_exceeded="$6"
  local job_admission_error="$7"
  local job_memory_enforcer_error="$8"
  local child_job_status="$9"
  local child_job_memory_exceeded="${10}"
  local child_job_disk_exceeded="${11}"
  local child_job_admission_error="${12}"
  local child_job_memory_enforcer_error="${13}"

  latest_run_path=""
  latest_run_attempt=""
  latest_run_status=""
  latest_run_summary=""

  if [[ ! -d "$runs_root" ]]; then
    return 0
  fi

  latest_run_path="$(find "$runs_root" -maxdepth 1 -mindepth 1 -type d | sort | tail -n 1 || true)"

  if [[ -z "$latest_run_path" ]]; then
    return 0
  fi

  latest_run_attempt="$(clasp_swarm_task_run_attempt "$latest_run_path" 2>/dev/null || true)"

  read -r latest_run_status latest_run_summary < <(
    node - <<'EOF' "$latest_run_path/builder-report.json" "$latest_run_path/verifier-report.json" "$lane_name" "$lane_status" "$job_status" "$job_memory_exceeded" "$job_disk_exceeded" "$job_admission_error" "$job_memory_enforcer_error" "$child_job_status" "$child_job_memory_exceeded" "$child_job_disk_exceeded" "$child_job_admission_error" "$child_job_memory_enforcer_error"
const fs = require("fs");
const [
  builderPath,
  verifierPath,
  laneName,
  laneStatus,
  jobStatus,
  jobMemoryExceeded,
  jobDiskExceeded,
  jobAdmissionError,
  jobMemoryEnforcerError,
  childJobStatus,
  childJobMemoryExceeded,
  childJobDiskExceeded,
  childJobAdmissionError,
  childJobMemoryEnforcerError,
] = process.argv.slice(2);

function sanitize(value) {
  return String(value || "").replace(/\s+/g, " ").trim();
}

let status = "started";
let summary = `Lane ${laneName} has an active run without a structured report yet.`;

if (fs.existsSync(verifierPath)) {
  try {
    const report = JSON.parse(fs.readFileSync(verifierPath, "utf8"));
    status = report.verdict === "pass" ? "pass" : "fail";
    summary = sanitize(report.summary) || summary;
  } catch (_) {
    status = "invalid-report";
    summary = `Lane ${laneName} produced an unreadable verifier report.`;
  }
} else if (fs.existsSync(builderPath)) {
  try {
    const report = JSON.parse(fs.readFileSync(builderPath, "utf8"));
    status = "builder-complete";
    summary = sanitize(report.summary) || `Lane ${laneName} completed the builder step.`;
  } catch (_) {
    status = "invalid-report";
    summary = `Lane ${laneName} produced an unreadable builder report.`;
  }
} else if (laneStatus !== "running") {
  const memoryExceeded =
    jobStatus === "memory-exceeded" ||
    jobMemoryExceeded === "1" ||
    childJobMemoryExceeded === "1";
  const diskExceeded =
    jobStatus === "disk-exceeded" ||
    jobDiskExceeded === "1" ||
    childJobDiskExceeded === "1";
  const admissionUnavailable =
    jobStatus === "admission-lock-unavailable" ||
    childJobStatus === "admission-lock-unavailable" ||
    jobAdmissionError === "1" ||
    childJobAdmissionError === "1";
  const memoryEnforcerUnavailable =
    jobStatus === "memory-enforcer-unavailable" ||
    childJobStatus === "memory-enforcer-unavailable" ||
    jobMemoryEnforcerError === "1" ||
    childJobMemoryEnforcerError === "1";

  if (memoryExceeded) {
    status = "memory-exceeded";
    summary = `Lane ${laneName} stopped before writing a structured report because the managed job exceeded its memory guard.`;
  } else if (diskExceeded) {
    status = "disk-exceeded";
    summary = `Lane ${laneName} stopped before writing a structured report because the managed job exceeded its disk guard.`;
  } else if (admissionUnavailable) {
    status = "admission-lock-unavailable";
    summary = `Lane ${laneName} stopped before writing a structured report because the managed-job admission lock was unavailable.`;
  } else if (memoryEnforcerUnavailable) {
    status = "memory-enforcer-unavailable";
    summary = `Lane ${laneName} stopped before writing a structured report because the managed-job memory enforcer was unavailable.`;
  } else if (jobStatus === "failed") {
    status = "failed-before-report";
    summary = `Lane ${laneName} failed before writing a structured report.`;
  } else if (jobStatus === "stopped") {
    status = "stopped-before-report";
    summary = `Lane ${laneName} was stopped before writing a structured report.`;
  } else {
    status = "interrupted-before-report";
    summary = `Lane ${laneName} is not running and has no structured report for the latest run.`;
  }
}

process.stdout.write(`${status}\t${summary}\n`);
EOF
  )
}

json_mode=0
wave_name="$(clasp_swarm_default_wave)"

if [[ $# -gt 2 ]]; then
  usage
  exit 1
fi

if [[ "${1:-}" == "--json" ]]; then
  json_mode=1
  wave_name="${2:-$(clasp_swarm_default_wave)}"
elif [[ $# -ge 1 ]]; then
  wave_name="$1"
fi

lane_text_file="$(mktemp)"
lane_jsonl_file="$(mktemp)"
run_state_file="$(mktemp)"

cleanup() {
  rm -f "$lane_text_file" "$lane_jsonl_file" "$run_state_file"
}

trap cleanup EXIT

lane_count=0
running_count=0
stopped_count=0
completed_total=0
blocked_total=0

while IFS= read -r lane_dir; do
  lane_name="$(clasp_swarm_lane_name "$lane_dir")"
  runtime_root="$project_root/.clasp-swarm/$wave_name/$lane_name"
  runs_root="$runtime_root/runs"
  pid_file="$runtime_root/pid"
  current_task_file="$runtime_root/current-task.txt"
  completed_root="$runtime_root/completed"
  blocked_root="$runtime_root/blocked"
  log_file="$runtime_root/lane.log"
  job_file="$runtime_root/job"
  child_jobs_root="$runtime_root/child-jobs"
  pid=""
  stale_pid=""
  status="stopped"
  job_status=""
  job_exit_status=""
  job_memory_mb=""
  job_min_available_memory_mb=""
  job_memory_enforcer=""
  job_memory_exceeded="0"
  job_disk_exceeded="0"
  job_admission_error="0"
  job_memory_enforcer_error="0"
  job_failure_reason=""
  job_failure_phase=""
  job_recovery_command=""
  job_recovery_apply_command=""
  job_recovery_note=""
  child_job_dir=""
  child_job_name=""
  child_job_status=""
  child_job_exit_status=""
  child_job_memory_mb=""
  child_job_min_available_memory_mb=""
  child_job_memory_enforcer=""
  child_job_memory_exceeded="0"
  child_job_disk_exceeded="0"
  child_job_admission_error="0"
  child_job_memory_enforcer_error="0"
  child_job_failure_reason=""
  child_job_failure_phase=""
  child_job_recovery_command=""
  child_job_recovery_apply_command=""
  child_job_recovery_note=""
  current_task=""

  lane_count=$((lane_count + 1))

  if [[ -f "$job_file" ]]; then
    job_dir="$(sed -n '1p' "$job_file")"
    if [[ -n "$job_dir" && -f "$job_dir/status" ]]; then
      job_status="$(sed -n '1p' "$job_dir/status")"
    fi
    if [[ -n "$job_dir" && -f "$job_dir/exit-status" ]]; then
      job_exit_status="$(sed -n '1p' "$job_dir/exit-status")"
    fi
    if [[ -n "$job_dir" && -f "$job_dir/memory-mb" ]]; then
      job_memory_mb="$(sed -n '1p' "$job_dir/memory-mb")"
    fi
    if [[ -n "$job_dir" && -f "$job_dir/min-available-memory-mb" ]]; then
      job_min_available_memory_mb="$(sed -n '1p' "$job_dir/min-available-memory-mb")"
    fi
    if [[ -n "$job_dir" && -f "$job_dir/memory-enforcer" ]]; then
      job_memory_enforcer="$(sed -n '1p' "$job_dir/memory-enforcer")"
    fi
    if [[ -n "$job_dir" && -f "$job_dir/memory-exceeded" ]]; then
      job_memory_exceeded="1"
      job_failure_reason="$(marker_value "$job_dir/memory-exceeded" reason)"
      job_failure_phase="$(marker_value "$job_dir/memory-exceeded" phase)"
    fi
    if [[ -n "$job_dir" && -f "$job_dir/disk-exceeded" ]]; then
      job_disk_exceeded="1"
      if [[ -z "$job_failure_reason" ]]; then
        job_failure_reason="$(marker_value "$job_dir/disk-exceeded" reason)"
      fi
      if [[ -z "$job_failure_phase" ]]; then
        job_failure_phase="$(marker_value "$job_dir/disk-exceeded" phase)"
      fi
      job_recovery_command="$(marker_value "$job_dir/disk-exceeded" recovery_command)"
      job_recovery_apply_command="$(marker_value "$job_dir/disk-exceeded" recovery_apply_command)"
      job_recovery_note="$(marker_value "$job_dir/disk-exceeded" recovery_note)"
    fi
    if [[ -n "$job_dir" && -f "$job_dir/admission-error" ]]; then
      job_admission_error="1"
      if [[ -z "$job_failure_reason" ]]; then
        job_failure_reason="$(marker_value "$job_dir/admission-error" reason)"
      fi
    fi
    if [[ -n "$job_dir" && -f "$job_dir/memory-enforcer-error" ]]; then
      job_memory_enforcer_error="1"
      if [[ -z "$job_failure_reason" ]]; then
        job_failure_reason="$(marker_value "$job_dir/memory-enforcer-error" reason)"
      fi
    fi
  fi

  if [[ -d "$child_jobs_root" ]]; then
    child_job_dir="$(latest_child_job_dir "$child_jobs_root" | sort -n -k1,1 -k2,2 | tail -n 1 | cut -f3- || true)"
    if [[ -n "$child_job_dir" ]]; then
      child_job_name="$(basename "$child_job_dir")"
      if [[ -f "$child_job_dir/status" ]]; then
        child_job_status="$(sed -n '1p' "$child_job_dir/status")"
      fi
      if [[ -f "$child_job_dir/exit-status" ]]; then
        child_job_exit_status="$(sed -n '1p' "$child_job_dir/exit-status")"
      fi
      if [[ -f "$child_job_dir/memory-mb" ]]; then
        child_job_memory_mb="$(sed -n '1p' "$child_job_dir/memory-mb")"
      fi
      if [[ -f "$child_job_dir/min-available-memory-mb" ]]; then
        child_job_min_available_memory_mb="$(sed -n '1p' "$child_job_dir/min-available-memory-mb")"
      fi
      if [[ -f "$child_job_dir/memory-enforcer" ]]; then
        child_job_memory_enforcer="$(sed -n '1p' "$child_job_dir/memory-enforcer")"
      fi
      if [[ -f "$child_job_dir/memory-exceeded" ]]; then
        child_job_memory_exceeded="1"
        child_job_failure_reason="$(marker_value "$child_job_dir/memory-exceeded" reason)"
        child_job_failure_phase="$(marker_value "$child_job_dir/memory-exceeded" phase)"
      fi
      if [[ -f "$child_job_dir/disk-exceeded" ]]; then
        child_job_disk_exceeded="1"
        if [[ -z "$child_job_failure_reason" ]]; then
          child_job_failure_reason="$(marker_value "$child_job_dir/disk-exceeded" reason)"
        fi
        if [[ -z "$child_job_failure_phase" ]]; then
          child_job_failure_phase="$(marker_value "$child_job_dir/disk-exceeded" phase)"
        fi
        child_job_recovery_command="$(marker_value "$child_job_dir/disk-exceeded" recovery_command)"
        child_job_recovery_apply_command="$(marker_value "$child_job_dir/disk-exceeded" recovery_apply_command)"
        child_job_recovery_note="$(marker_value "$child_job_dir/disk-exceeded" recovery_note)"
      fi
      if [[ -f "$child_job_dir/admission-error" ]]; then
        child_job_admission_error="1"
        if [[ -z "$child_job_failure_reason" ]]; then
          child_job_failure_reason="$(marker_value "$child_job_dir/admission-error" reason)"
        fi
      fi
      if [[ -f "$child_job_dir/memory-enforcer-error" ]]; then
        child_job_memory_enforcer_error="1"
        if [[ -z "$child_job_failure_reason" ]]; then
          child_job_failure_reason="$(marker_value "$child_job_dir/memory-enforcer-error" reason)"
        fi
      fi
    fi
  fi

  if [[ -f "$pid_file" ]]; then
    pid="$(cat "$pid_file")"
    if kill -0 "$pid" >/dev/null 2>&1; then
      status="running"
      running_count=$((running_count + 1))
    else
      stale_pid="$pid"
      pid=""
      stopped_count=$((stopped_count + 1))
    fi
  else
    stopped_count=$((stopped_count + 1))
  fi

  if [[ -f "$current_task_file" ]]; then
    current_task="$(cat "$current_task_file")"
  fi

  completed_count="$(count_files "$completed_root")"
  blocked_count="$(count_files "$blocked_root")"
  lane_task_count="$(count_task_files "$lane_dir")"
  completed_total=$((completed_total + completed_count))
  blocked_total=$((blocked_total + blocked_count))

  collect_latest_run_state \
    "$runs_root" \
    "$lane_name" \
    "$status" \
    "$job_status" \
    "$job_memory_exceeded" \
    "$job_disk_exceeded" \
    "$job_admission_error" \
    "$job_memory_enforcer_error" \
    "$child_job_status" \
    "$child_job_memory_exceeded" \
    "$child_job_disk_exceeded" \
    "$child_job_admission_error" \
    "$child_job_memory_enforcer_error"

  if [[ "$status" == "stopped" && "$blocked_count" == "0" && "$completed_count" == "$lane_task_count" ]]; then
    latest_run_path=""
    latest_run_attempt=""
    latest_run_status="complete"
    latest_run_summary="Lane $lane_name has no remaining tasks."
  fi

  printf '%s\n' "${latest_run_status:-no-run}" >> "$run_state_file"

  {
    echo "lane: $lane_name"
    echo "  status: $status"
    if [[ -n "$pid" ]]; then
      echo "  pid: $pid"
    fi
    if [[ -n "$stale_pid" ]]; then
      echo "  stale pid: $stale_pid"
    fi
    if [[ -n "$job_status" ]]; then
      echo "  managed job status: $job_status"
    fi
    if [[ -n "$job_exit_status" ]]; then
      echo "  managed job exit: $job_exit_status"
    fi
    if [[ -n "$job_memory_mb" ]]; then
      echo "  managed job memory mb: $job_memory_mb"
    fi
    if [[ -n "$job_min_available_memory_mb" ]]; then
      echo "  managed job min available memory mb: $job_min_available_memory_mb"
    fi
    if [[ -n "$job_memory_enforcer" ]]; then
      echo "  managed job memory enforcer: $job_memory_enforcer"
    fi
    if [[ "$job_memory_exceeded" == "1" ]]; then
      echo "  managed job memory exceeded: true"
    fi
    if [[ "$job_disk_exceeded" == "1" ]]; then
      echo "  managed job disk exceeded: true"
    fi
    if [[ "$job_admission_error" == "1" ]]; then
      echo "  managed job admission error: true"
    fi
    if [[ "$job_memory_enforcer_error" == "1" ]]; then
      echo "  managed job memory enforcer error: true"
    fi
    if [[ -n "$job_failure_reason" ]]; then
      echo "  managed job failure reason: $job_failure_reason"
    fi
    if [[ -n "$job_failure_phase" ]]; then
      echo "  managed job failure phase: $job_failure_phase"
    fi
    if [[ -n "$job_recovery_command" ]]; then
      echo "  managed job recovery command: $job_recovery_command"
    fi
    if [[ -n "$job_recovery_apply_command" ]]; then
      echo "  managed job recovery apply command: $job_recovery_apply_command"
    fi
    if [[ -n "$job_recovery_note" ]]; then
      echo "  managed job recovery note: $job_recovery_note"
    fi
    if [[ -n "$child_job_dir" ]]; then
      echo "  latest child job: $child_job_name"
      if [[ -n "$child_job_status" ]]; then
        echo "  child job status: $child_job_status"
      fi
      if [[ -n "$child_job_exit_status" ]]; then
        echo "  child job exit: $child_job_exit_status"
      fi
      if [[ -n "$child_job_memory_mb" ]]; then
        echo "  child job memory mb: $child_job_memory_mb"
      fi
      if [[ -n "$child_job_min_available_memory_mb" ]]; then
        echo "  child job min available memory mb: $child_job_min_available_memory_mb"
      fi
      if [[ -n "$child_job_memory_enforcer" ]]; then
        echo "  child job memory enforcer: $child_job_memory_enforcer"
      fi
      if [[ "$child_job_memory_exceeded" == "1" ]]; then
        echo "  child job memory exceeded: true"
      fi
      if [[ "$child_job_disk_exceeded" == "1" ]]; then
        echo "  child job disk exceeded: true"
      fi
      if [[ "$child_job_admission_error" == "1" ]]; then
        echo "  child job admission error: true"
      fi
      if [[ "$child_job_memory_enforcer_error" == "1" ]]; then
        echo "  child job memory enforcer error: true"
      fi
      if [[ -n "$child_job_failure_reason" ]]; then
        echo "  child job failure reason: $child_job_failure_reason"
      fi
      if [[ -n "$child_job_failure_phase" ]]; then
        echo "  child job failure phase: $child_job_failure_phase"
      fi
      if [[ -n "$child_job_recovery_command" ]]; then
        echo "  child job recovery command: $child_job_recovery_command"
      fi
      if [[ -n "$child_job_recovery_apply_command" ]]; then
        echo "  child job recovery apply command: $child_job_recovery_apply_command"
      fi
      if [[ -n "$child_job_recovery_note" ]]; then
        echo "  child job recovery note: $child_job_recovery_note"
      fi
    fi
    if [[ -n "$current_task" ]]; then
      echo "  current task: $current_task"
    fi
    echo "  completed: $completed_count"
    echo "  blocked: $blocked_count"
    if [[ -n "$latest_run_path" ]]; then
      echo "  latest run: $(basename "$latest_run_path")"
      if [[ -n "$latest_run_attempt" ]]; then
        echo "  latest attempt: $latest_run_attempt"
      fi
      echo "  run status: $latest_run_status"
      echo "  run summary: $latest_run_summary"
    fi
    if [[ -f "$log_file" ]]; then
      echo "  log: $log_file"
      tail -n 5 "$log_file" | sed 's/^/    /'
    fi
  } >> "$lane_text_file"

  node - <<'EOF' \
    "$lane_name" \
    "$status" \
    "$pid" \
    "$stale_pid" \
    "$job_status" \
    "$job_exit_status" \
    "$job_memory_mb" \
    "$job_min_available_memory_mb" \
    "$job_memory_enforcer" \
    "$job_memory_exceeded" \
    "$job_disk_exceeded" \
    "$job_admission_error" \
    "$job_memory_enforcer_error" \
    "$job_failure_reason" \
    "$job_failure_phase" \
    "$job_recovery_command" \
    "$job_recovery_apply_command" \
    "$job_recovery_note" \
    "$child_job_dir" \
    "$child_job_name" \
    "$child_job_status" \
    "$child_job_exit_status" \
    "$child_job_memory_mb" \
    "$child_job_min_available_memory_mb" \
    "$child_job_memory_enforcer" \
    "$child_job_memory_exceeded" \
    "$child_job_disk_exceeded" \
    "$child_job_admission_error" \
    "$child_job_memory_enforcer_error" \
    "$child_job_failure_reason" \
    "$child_job_failure_phase" \
    "$child_job_recovery_command" \
    "$child_job_recovery_apply_command" \
    "$child_job_recovery_note" \
    "$current_task" \
    "$completed_count" \
    "$blocked_count" \
    "$log_file" \
    "$latest_run_path" \
    "$latest_run_attempt" \
    "$latest_run_status" \
    "$latest_run_summary" >> "$lane_jsonl_file"
const fs = require("fs");
const [
  lane,
  status,
  pid,
  stalePid,
  managedJobStatus,
  managedJobExitStatus,
  managedJobMemoryMb,
  managedJobMinAvailableMemoryMb,
  managedJobMemoryEnforcer,
  managedJobMemoryExceeded,
  managedJobDiskExceeded,
  managedJobAdmissionError,
  managedJobMemoryEnforcerError,
  managedJobFailureReason,
  managedJobFailurePhase,
  managedJobRecoveryCommand,
  managedJobRecoveryApplyCommand,
  managedJobRecoveryNote,
  childJobPath,
  childJobName,
  childJobStatus,
  childJobExitStatus,
  childJobMemoryMb,
  childJobMinAvailableMemoryMb,
  childJobMemoryEnforcer,
  childJobMemoryExceeded,
  childJobDiskExceeded,
  childJobAdmissionError,
  childJobMemoryEnforcerError,
  childJobFailureReason,
  childJobFailurePhase,
  childJobRecoveryCommand,
  childJobRecoveryApplyCommand,
  childJobRecoveryNote,
  currentTask,
  completedCount,
  blockedCount,
  logPath,
  latestRunPath,
  latestRunAttempt,
  latestRunStatus,
  latestRunSummary,
] = process.argv.slice(2);

function tailLines(filePath, count) {
  if (!filePath || !fs.existsSync(filePath)) {
    return [];
  }
  return fs
    .readFileSync(filePath, "utf8")
    .split(/\r?\n/)
    .filter((line) => line.length > 0)
    .slice(-count);
}

function firstNonEmpty(...values) {
  return values.find((value) => value && String(value).length > 0) || null;
}

function recommendedActionFor(laneStatus) {
  const runStatus = laneStatus.latestRun?.status || (laneStatus.status === "running" ? "running" : "no-run");
  const child = laneStatus.latestChildJob || {};
  const reason = firstNonEmpty(laneStatus.managedJobFailureReason, child.failureReason);
  const phase = firstNonEmpty(laneStatus.managedJobFailurePhase, child.failurePhase);

  if (runStatus === "disk-exceeded") {
    return {
      type: "recover-disk",
      reason,
      phase,
      command: firstNonEmpty(laneStatus.managedJobRecoveryCommand, child.recoveryCommand),
      applyCommand: firstNonEmpty(laneStatus.managedJobRecoveryApplyCommand, child.recoveryApplyCommand),
      note: firstNonEmpty(laneStatus.managedJobRecoveryNote, child.recoveryNote),
    };
  }
  if (runStatus === "memory-exceeded") {
    return {
      type: "reduce-memory-pressure",
      reason,
      phase,
      command: null,
      applyCommand: null,
      note: "Wait for memory headroom or lower swarm concurrency before retrying this lane.",
    };
  }
  if (runStatus === "admission-lock-unavailable") {
    return {
      type: "repair-admission-lock",
      reason,
      phase,
      command: null,
      applyCommand: null,
      note: "Repair managed-job admission lock configuration before launching more agent work.",
    };
  }
  if (runStatus === "memory-enforcer-unavailable") {
    return {
      type: "repair-memory-enforcer",
      reason,
      phase,
      command: null,
      applyCommand: null,
      note: "Enable the configured memory enforcer or explicitly allow the weaker managed fallback before retrying.",
    };
  }
  if (runStatus === "failed-before-report") {
    return {
      type: "inspect-lane-log",
      reason,
      phase,
      command: null,
      applyCommand: null,
      note: "Inspect lane logs and the managed job stderr before retrying.",
    };
  }
  if (runStatus === "stopped-before-report") {
    return {
      type: "inspect-stop-state",
      reason,
      phase,
      command: null,
      applyCommand: null,
      note: "Inspect the stop request and lane log before restarting the lane.",
    };
  }
  if (runStatus === "invalid-report") {
    return {
      type: "repair-report",
      reason,
      phase,
      command: null,
      applyCommand: null,
      note: "Repair or remove the unreadable structured report before consuming this lane result.",
    };
  }

  return null;
}

const laneStatus = {
  lane,
  status,
  pid: pid || null,
  stalePid: stalePid || null,
  managedJobStatus: managedJobStatus || null,
  managedJobExitStatus: managedJobExitStatus || null,
  managedJobMemoryMb: managedJobMemoryMb ? Number(managedJobMemoryMb) : null,
  managedJobMinAvailableMemoryMb: managedJobMinAvailableMemoryMb ? Number(managedJobMinAvailableMemoryMb) : null,
  managedJobMemoryEnforcer: managedJobMemoryEnforcer || null,
  managedJobMemoryExceeded: managedJobMemoryExceeded === "1",
  managedJobDiskExceeded: managedJobDiskExceeded === "1",
  managedJobAdmissionError: managedJobAdmissionError === "1",
  managedJobMemoryEnforcerError: managedJobMemoryEnforcerError === "1",
  managedJobFailureReason: managedJobFailureReason || null,
  managedJobFailurePhase: managedJobFailurePhase || null,
  managedJobRecoveryCommand: managedJobRecoveryCommand || null,
  managedJobRecoveryApplyCommand: managedJobRecoveryApplyCommand || null,
  managedJobRecoveryNote: managedJobRecoveryNote || null,
  latestChildJob: childJobPath
    ? {
        path: childJobPath,
        name: childJobName || null,
        status: childJobStatus || null,
        exitStatus: childJobExitStatus || null,
        memoryMb: childJobMemoryMb ? Number(childJobMemoryMb) : null,
        minAvailableMemoryMb: childJobMinAvailableMemoryMb ? Number(childJobMinAvailableMemoryMb) : null,
        memoryEnforcer: childJobMemoryEnforcer || null,
        memoryExceeded: childJobMemoryExceeded === "1",
        diskExceeded: childJobDiskExceeded === "1",
        admissionError: childJobAdmissionError === "1",
        memoryEnforcerError: childJobMemoryEnforcerError === "1",
        failureReason: childJobFailureReason || null,
        failurePhase: childJobFailurePhase || null,
        recoveryCommand: childJobRecoveryCommand || null,
        recoveryApplyCommand: childJobRecoveryApplyCommand || null,
        recoveryNote: childJobRecoveryNote || null,
      }
    : null,
  currentTask: currentTask || null,
  completedCount: Number(completedCount),
  blockedCount: Number(blockedCount),
  logPath: logPath && fs.existsSync(logPath) ? logPath : null,
  recentLogLines: tailLines(logPath, 5),
  latestRun: latestRunPath
    ? {
        path: latestRunPath,
        attempt: latestRunAttempt ? Number(latestRunAttempt) : null,
        status: latestRunStatus || "started",
        summary: latestRunSummary || null,
      }
    : null,
};

laneStatus.recommendedAction = recommendedActionFor(laneStatus);

process.stdout.write(`${JSON.stringify(laneStatus)}\n`);
EOF
done < <(clasp_swarm_lane_dirs "$wave_name" "$project_root")

if [[ "$json_mode" == "1" ]]; then
  node - <<'EOF' "$wave_name" "$lane_count" "$running_count" "$stopped_count" "$completed_total" "$blocked_total" "$lane_jsonl_file"
const fs = require("fs");
const [wave, laneCount, runningCount, stoppedCount, completedCount, blockedCount, laneJsonl] = process.argv.slice(2);
const lanes = fs.existsSync(laneJsonl)
  ? fs
      .readFileSync(laneJsonl, "utf8")
      .split(/\r?\n/)
      .filter(Boolean)
      .map((line) => JSON.parse(line))
  : [];
const runStateCounts = Object.fromEntries(
  lanes
    .reduce((counts, lane) => {
      const key = lane.latestRun?.status || "no-run";
      counts.set(key, (counts.get(key) || 0) + 1);
      return counts;
    }, new Map())
    .entries(),
);
const payload = {
  wave,
  summary: {
    laneCount: Number(laneCount),
    runningCount: Number(runningCount),
    stoppedCount: Number(stoppedCount),
    completedCount: Number(completedCount),
    blockedCount: Number(blockedCount),
    runStateCounts,
  },
  lanes,
};
process.stdout.write(`${JSON.stringify(payload, null, 2)}\n`);
EOF
  exit 0
fi

run_state_summary="$(
  node - <<'EOF' "$run_state_file"
const fs = require("fs");
const [runStateFile] = process.argv.slice(2);
const counts = new Map();
for (const state of fs.readFileSync(runStateFile, "utf8").split(/\r?\n/).filter(Boolean).sort()) {
  counts.set(state, (counts.get(state) || 0) + 1);
}
process.stdout.write(
  Array.from(counts.entries())
    .map(([state, count]) => `${state}=${count}`)
    .join(" "),
);
EOF
)"

echo "wave: $wave_name"
echo "summary: lanes=$lane_count running=$running_count stopped=$stopped_count completed=$completed_total blocked=$blocked_total"
echo "run-states: ${run_state_summary:-none}"

if [[ -s "$lane_text_file" ]]; then
  cat "$lane_text_file"
fi
