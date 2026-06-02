#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$project_root/scripts/clasp-swarm-common.sh"

wave_name="$(clasp_swarm_default_wave)"
batch_filter=""
json_output=0
include_repository_gate="${CLASP_SWARM_PREFLIGHT_INCLUDE_REPOSITORY_GATE:-0}"
launch_profile="${CLASP_SWARM_PROFILE:-}"
max_running_lanes="${CLASP_SWARM_MAX_RUNNING_LANES:-1}"
main_branch="${CLASP_SWARM_MAIN_BRANCH:-main}"
allow_dirty="${CLASP_SWARM_ALLOW_DIRTY:-0}"
lane_memory_mb="${CLASP_SWARM_LANE_MEMORY_MB:-8192}"
min_available_memory_mb="${CLASP_SWARM_MIN_AVAILABLE_MEMORY_MB:-45056}"
min_available_disk_mb="${CLASP_SWARM_MIN_AVAILABLE_DISK_MB:-16384}"
min_disk_headroom_mb="${CLASP_SWARM_MIN_DISK_HEADROOM_MB:-${CLASP_GENERATED_STATE_MIN_HEADROOM_MB:-1024}}"
candidate_lane_memory_mb="${CLASP_SWARM_PREFLIGHT_CANDIDATE_LANE_MEMORY_MB:-4096}"
candidate_min_available_memory_mb="${CLASP_SWARM_PREFLIGHT_CANDIDATE_MIN_AVAILABLE_MEMORY_MB:-32768}"
external_agent_process_names="${CLASP_MANAGED_JOB_EXTERNAL_AGENT_PROCESS_NAMES:-codex}"
external_agent_reserve_per_process_mb="${CLASP_MANAGED_JOB_EXTERNAL_AGENT_RESERVE_MB:-1024}"

usage() {
  cat <<'EOF' >&2
usage: scripts/clasp-swarm-preflight.sh [--json] [--profile <name>] [--batch <batch-label>] [wave-name]

Runs the swarm launch admission checks without starting a worker lane. The
preflight reuses scripts/run-managed-job.sh --preflight-only, so it accounts for
the lane memory cap, host memory reserve, disk reserve/headroom, live managed
job budgets, and unmanaged external-agent RSS before a swarm launcher mutates
runtime state or creates child agent processes. Blocked memory reports also
include a bounded candidate profile, controlled by
CLASP_SWARM_PREFLIGHT_CANDIDATE_LANE_MEMORY_MB and
CLASP_SWARM_PREFLIGHT_CANDIDATE_MIN_AVAILABLE_MEMORY_MB, so managers can tell
whether a smaller explicitly configured launch would pass admission.
When --include-repository-gate is set, the report also checks the same clean
repository and required-branch gates that scripts/clasp-swarm-start.sh enforces
before launching a lane.

Profiles:
  bounded-low-memory  Use CLASP_SWARM_LANE_MEMORY_MB=4096 and
                      CLASP_SWARM_MIN_AVAILABLE_MEMORY_MB=32768.
  bounded-memory-pressure
                      Use CLASP_SWARM_LANE_MEMORY_MB=4096 and
                      CLASP_SWARM_MIN_AVAILABLE_MEMORY_MB=28672.
EOF
}

validate_non_negative_integer() {
  local name="$1"
  local value="$2"

  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s must be a non-negative integer; got %s\n' "$name" "$value" >&2
    exit 2
  fi
}

apply_launch_profile() {
  case "$launch_profile" in
    ""|default)
      ;;
    bounded-low-memory)
      lane_memory_mb=4096
      min_available_memory_mb=32768
      ;;
    bounded-memory-pressure)
      lane_memory_mb=4096
      min_available_memory_mb=28672
      ;;
    *)
      printf 'clasp-swarm-preflight: unknown launch profile: %s\n' "$launch_profile" >&2
      exit 2
      ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --json)
      json_output=1
      shift
      ;;
    --include-repository-gate|--repository-gate)
      include_repository_gate=1
      shift
      ;;
    --profile|--launch-profile)
      if [[ $# -lt 2 ]]; then
        printf 'clasp-swarm-preflight: %s requires a value\n' "$1" >&2
        exit 2
      fi
      launch_profile="$2"
      shift 2
      ;;
    --profile=*|--launch-profile=*)
      launch_profile="${1#*=}"
      shift
      ;;
    --batch)
      if [[ $# -lt 2 ]]; then
        printf 'clasp-swarm-preflight: --batch requires a value\n' >&2
        exit 2
      fi
      batch_filter="$2"
      shift 2
      ;;
    --batch=*)
      batch_filter="${1#--batch=}"
      shift
      ;;
    -*)
      printf 'clasp-swarm-preflight: unknown option: %s\n' "$1" >&2
      usage
      exit 2
      ;;
    *)
      wave_name="$1"
      shift
      if [[ $# -gt 0 ]]; then
        printf 'clasp-swarm-preflight: unexpected extra argument: %s\n' "$1" >&2
        usage
        exit 2
      fi
      ;;
  esac
done

apply_launch_profile

validate_non_negative_integer "CLASP_SWARM_MAX_RUNNING_LANES" "$max_running_lanes"
validate_non_negative_integer "CLASP_SWARM_LANE_MEMORY_MB" "$lane_memory_mb"
validate_non_negative_integer "CLASP_SWARM_MIN_AVAILABLE_MEMORY_MB" "$min_available_memory_mb"
validate_non_negative_integer "CLASP_SWARM_MIN_AVAILABLE_DISK_MB" "$min_available_disk_mb"
validate_non_negative_integer "CLASP_SWARM_MIN_DISK_HEADROOM_MB" "$min_disk_headroom_mb"
validate_non_negative_integer "CLASP_SWARM_PREFLIGHT_CANDIDATE_LANE_MEMORY_MB" "$candidate_lane_memory_mb"
validate_non_negative_integer "CLASP_SWARM_PREFLIGHT_CANDIDATE_MIN_AVAILABLE_MEMORY_MB" "$candidate_min_available_memory_mb"
validate_non_negative_integer "CLASP_MANAGED_JOB_EXTERNAL_AGENT_RESERVE_MB" "$external_agent_reserve_per_process_mb"

repository_gate_status="not-checked"
repository_gate_reason="not-requested"
repository_gate_current_branch=""
repository_gate_required_branch="$main_branch"
repository_gate_dirty_entries="0"
repository_gate_recommended_action="none"

repository_dirty_entry_count() {
  git -C "$project_root" status --short --untracked-files=all --ignore-submodules=all 2>/dev/null |
    awk 'END { print NR + 0 }'
}

repository_gate_top_reason() {
  case "$repository_gate_reason" in
    dirty-repo)
      printf 'repository-dirty\n'
      ;;
    wrong-branch)
      printf 'repository-wrong-branch\n'
      ;;
    git-unavailable)
      printf 'repository-unavailable\n'
      ;;
    *)
      printf 'repository-blocked\n'
      ;;
  esac
}

evaluate_repository_gate() {
  repository_gate_status="not-checked"
  repository_gate_reason="not-requested"
  repository_gate_current_branch=""
  repository_gate_required_branch="$main_branch"
  repository_gate_dirty_entries="0"
  repository_gate_recommended_action="none"

  if (( include_repository_gate != 1 )); then
    return 0
  fi

  if ! git -C "$project_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    repository_gate_status="blocked"
    repository_gate_reason="git-unavailable"
    repository_gate_recommended_action="run-from-a-git-checkout-before-launch"
    return 0
  fi

  repository_gate_current_branch="$(clasp_swarm_current_branch "$project_root" 2>/dev/null || true)"
  repository_gate_dirty_entries="$(repository_dirty_entry_count)"

  if [[ "$allow_dirty" != "1" ]] && (( repository_gate_dirty_entries > 0 )); then
    repository_gate_status="blocked"
    repository_gate_reason="dirty-repo"
    repository_gate_recommended_action="commit-or-stash-before-launch"
    return 0
  fi

  if [[ "$repository_gate_current_branch" != "$main_branch" ]]; then
    repository_gate_status="blocked"
    repository_gate_reason="wrong-branch"
    repository_gate_recommended_action="checkout-required-branch-before-launch"
    return 0
  fi

  repository_gate_status="admitted"
  if (( repository_gate_dirty_entries > 0 )); then
    repository_gate_reason="dirty-allowed"
  else
    repository_gate_reason="clean"
  fi
}

managed_job_status() {
  local job_dir="$1"
  sed -n '1p' "$job_dir/status" 2>/dev/null || true
}

managed_job_exit_status() {
  local job_dir="$1"
  sed -n '1p' "$job_dir/exit-status" 2>/dev/null || true
}

guard_field() {
  local guard_details="$1"
  local key="$2"

  awk -F= -v want="$key" '$1 == want { print $2; found = 1; exit } END { exit(found ? 0 : 1) }' <<< "$guard_details" 2>/dev/null || true
}

guard_int_field() {
  local guard_details="$1"
  local key="$2"
  local value=""

  value="$(guard_field "$guard_details" "$key")"
  if [[ "$value" =~ ^-?[0-9]+$ ]]; then
    printf '%s\n' "$value"
  else
    printf '0\n'
  fi
}

guard_pressure_kind() {
  local guard_details="$1"
  local reason=""

  reason="$(guard_field "$guard_details" "reason")"
  case "$reason" in
    host-available-memory-reserve|session-rss-limit|job-rss-limit)
      printf 'memory\n'
      ;;
    host-available-disk-reserve|host-available-disk-headroom)
      printf 'disk\n'
      ;;
    admission-lock-*|missing-admission-lock-file|flock-unavailable)
      printf 'admission-lock\n'
      ;;
    systemd-scope-required-unavailable|systemd-scope-failed|systemd-run-unavailable)
      printf 'memory-enforcer\n'
      ;;
    *)
      if [[ -n "$guard_details" ]]; then
        printf 'unknown\n'
      else
        printf 'none\n'
      fi
      ;;
  esac
}

guard_shortfall_mb() {
  local guard_details="$1"
  local kind=""
  local reason=""
  local required=0
  local available=0
  local min_headroom=0
  local actual_headroom=0
  local shortfall=0

  kind="$(guard_pressure_kind "$guard_details")"
  reason="$(guard_field "$guard_details" "reason")"
  case "$kind:$reason" in
    memory:*)
      required="$(guard_int_field "$guard_details" "required_available_memory_mb")"
      available="$(guard_int_field "$guard_details" "available_memory_mb")"
      shortfall=$((required - available))
      ;;
    disk:host-available-disk-headroom)
      min_headroom="$(guard_int_field "$guard_details" "min_disk_headroom_mb")"
      actual_headroom="$(guard_int_field "$guard_details" "disk_headroom_mb")"
      shortfall=$((min_headroom - actual_headroom))
      ;;
    disk:*)
      required="$(guard_int_field "$guard_details" "min_available_disk_mb")"
      available="$(guard_int_field "$guard_details" "available_disk_mb")"
      shortfall=$((required - available))
      ;;
    *)
      shortfall=0
      ;;
  esac

  if (( shortfall > 0 )); then
    printf '%s\n' "$shortfall"
  else
    printf '0\n'
  fi
}

guard_recommended_action() {
  local guard_details="$1"
  local kind=""
  local external_reserved=0

  kind="$(guard_pressure_kind "$guard_details")"
  external_reserved="$(guard_int_field "$guard_details" "external_agent_reserved_memory_mb")"
  case "$kind" in
    memory)
      if (( external_reserved > 0 )); then
        printf 'wait-for-external-agent-pressure-or-lower-concurrency-and-lane-memory-budget\n'
      else
        printf 'lower-concurrency-or-lane-memory-budget-before-launch\n'
      fi
      ;;
    disk)
      printf 'run-safe-generated-state-cleanup-or-free-disk-before-launch\n'
      ;;
    admission-lock)
      printf 'repair-managed-job-admission-lock-before-launch\n'
      ;;
    memory-enforcer)
      printf 'repair-memory-enforcer-before-launch\n'
      ;;
    unknown)
      printf 'inspect-managed-preflight-guard-before-launch\n'
      ;;
    *)
      printf 'none\n'
      ;;
  esac
}

read_proc_environ() {
  local environ_path="$1"

  [[ -r "$environ_path" ]] || return 1
  { tr "\0" "\n" <"$environ_path"; } 2>/dev/null
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
  local normalized_names
  local wanted_name

  normalized_names="${external_agent_process_names//,/ }"
  for wanted_name in $normalized_names; do
    if [[ -n "$wanted_name" && "$process_name" == "$wanted_name" ]]; then
      return 0
    fi
  done
  return 1
}

live_external_agent_process_count() {
  local candidate_pid=""
  local process_name=""
  local count=0

  if (( external_agent_reserve_per_process_mb < 1 )); then
    printf '0\n'
    return 0
  fi

  while read -r candidate_pid process_name; do
    [[ -n "$candidate_pid" && "$candidate_pid" =~ ^[0-9]+$ && -n "$process_name" ]] || continue
    external_agent_name_matches "$process_name" || continue
    process_has_any_managed_job_marker "$candidate_pid" && continue
    count=$((count + 1))
  done < <(ps -eo pid=,comm= 2>/dev/null || true)

  printf '%d\n' "$count"
}

live_external_agent_rss_mb() {
  local candidate_pid=""
  local process_name=""
  local rss_kb=""
  local total_kb=0

  if (( external_agent_reserve_per_process_mb < 1 )); then
    printf '0\n'
    return 0
  fi

  while read -r candidate_pid process_name rss_kb; do
    [[ -n "$candidate_pid" && "$candidate_pid" =~ ^[0-9]+$ && -n "$process_name" ]] || continue
    [[ "$rss_kb" =~ ^[0-9]+$ ]] || rss_kb=0
    external_agent_name_matches "$process_name" || continue
    process_has_any_managed_job_marker "$candidate_pid" && continue
    total_kb=$((total_kb + rss_kb))
  done < <(ps -eo pid=,comm=,rss= 2>/dev/null || true)

  printf '%d\n' "$(((total_kb + 1023) / 1024))"
}

guard_or_default_int_field() {
  local guard_details="$1"
  local key="$2"
  local fallback="$3"
  local value=""

  value="$(guard_field "$guard_details" "$key")"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$fallback"
  fi
}

nonnegative_mb() {
  local value="$1"
  if (( value > 0 )); then
    printf '%s\n' "$value"
  else
    printf '0\n'
  fi
}

guard_same_reserve_max_lane_memory_mb() {
  local guard_details="$1"
  local available=0
  local external_reserved=0
  local running_budget=0
  local max_lane=0

  available="$(guard_int_field "$guard_details" "available_memory_mb")"
  external_reserved="$(guard_int_field "$guard_details" "external_agent_reserved_memory_mb")"
  running_budget="$(guard_int_field "$guard_details" "running_managed_memory_budget_mb")"
  max_lane=$((available - min_available_memory_mb - external_reserved - running_budget))
  nonnegative_mb "$max_lane"
}

guard_same_lane_max_min_available_memory_mb() {
  local guard_details="$1"
  local available=0
  local external_reserved=0
  local running_budget=0
  local max_min_available=0

  available="$(guard_int_field "$guard_details" "available_memory_mb")"
  external_reserved="$(guard_int_field "$guard_details" "external_agent_reserved_memory_mb")"
  running_budget="$(guard_int_field "$guard_details" "running_managed_memory_budget_mb")"
  max_min_available=$((available - lane_memory_mb - external_reserved - running_budget))
  nonnegative_mb "$max_min_available"
}

guard_candidate_required_available_memory_mb() {
  local guard_details="$1"
  local external_reserved=0
  local running_budget=0

  external_reserved="$(guard_int_field "$guard_details" "external_agent_reserved_memory_mb")"
  running_budget="$(guard_int_field "$guard_details" "running_managed_memory_budget_mb")"
  printf '%s\n' "$((candidate_min_available_memory_mb + candidate_lane_memory_mb + external_reserved + running_budget))"
}

guard_candidate_shortfall_mb() {
  local guard_details="$1"
  local available=0
  local required=0
  local shortfall=0

  available="$(guard_int_field "$guard_details" "available_memory_mb")"
  required="$(guard_candidate_required_available_memory_mb "$guard_details")"
  shortfall=$((required - available))
  nonnegative_mb "$shortfall"
}

guard_candidate_admissible_text() {
  local guard_details="$1"
  local shortfall=0

  shortfall="$(guard_candidate_shortfall_mb "$guard_details")"
  if (( shortfall == 0 )); then
    printf 'true\n'
  else
    printf 'false\n'
  fi
}

guard_candidate_env_text() {
  printf 'CLASP_SWARM_LANE_MEMORY_MB=%s CLASP_SWARM_MIN_AVAILABLE_MEMORY_MB=%s\n' \
    "$candidate_lane_memory_mb" "$candidate_min_available_memory_mb"
}

refresh_resource_report_fields() {
  external_agent_process_count="$(live_external_agent_process_count)"
  external_agent_rss_mb="0"
  external_agent_reserved_memory_mb="0"

  if [[ "$external_agent_process_count" =~ ^[0-9]+$ && "$external_agent_process_count" -gt 0 ]]; then
    external_agent_rss_mb="$(live_external_agent_rss_mb)"
    [[ "$external_agent_rss_mb" =~ ^[0-9]+$ ]] || external_agent_rss_mb="0"
    external_agent_reserved_memory_mb="$((external_agent_rss_mb + external_agent_process_count * external_agent_reserve_per_process_mb))"
  else
    external_agent_process_count="0"
  fi

  resource_pressure_kind="none"
  resource_shortfall_mb="0"
  recommended_action="none"
  same_reserve_max_lane_memory_mb="0"
  same_lane_max_min_available_memory_mb="0"
  candidate_required_available_memory_mb="0"
  candidate_shortfall_mb="0"
  candidate_admissible="false"
  candidate_env=""

  if [[ -n "$guard_details" ]]; then
    resource_pressure_kind="$(guard_pressure_kind "$guard_details")"
    resource_shortfall_mb="$(guard_shortfall_mb "$guard_details")"
    recommended_action="$(guard_recommended_action "$guard_details")"
    external_agent_process_count="$(guard_or_default_int_field "$guard_details" "external_agent_process_count" "$external_agent_process_count")"
    external_agent_rss_mb="$(guard_or_default_int_field "$guard_details" "external_agent_rss_mb" "$external_agent_rss_mb")"
    external_agent_reserve_per_process_mb="$(guard_or_default_int_field "$guard_details" "external_agent_reserve_per_process_mb" "$external_agent_reserve_per_process_mb")"
    external_agent_reserved_memory_mb="$(guard_or_default_int_field "$guard_details" "external_agent_reserved_memory_mb" "$external_agent_reserved_memory_mb")"
    if [[ "$resource_pressure_kind" == "memory" ]]; then
      same_reserve_max_lane_memory_mb="$(guard_same_reserve_max_lane_memory_mb "$guard_details")"
      same_lane_max_min_available_memory_mb="$(guard_same_lane_max_min_available_memory_mb "$guard_details")"
      candidate_required_available_memory_mb="$(guard_candidate_required_available_memory_mb "$guard_details")"
      candidate_shortfall_mb="$(guard_candidate_shortfall_mb "$guard_details")"
      candidate_admissible="$(guard_candidate_admissible_text "$guard_details")"
      candidate_env="$(guard_candidate_env_text)"
    fi
  fi
}

lane_runtime_is_running() {
  local runtime_root="$1"
  local job_file="$runtime_root/job"
  local pid_file="$runtime_root/pid"
  local job_dir=""
  local pid=""
  local status=""

  if [[ -f "$job_file" ]]; then
    job_dir="$(sed -n '1p' "$job_file")"
    if [[ -f "$job_dir/pid" && -f "$job_dir/status" ]]; then
      pid="$(tr -d '[:space:]' <"$job_dir/pid")"
      status="$(sed -n '1p' "$job_dir/status")"
      if [[ -f "$pid_file" && "$status" != "completed" && "$status" != "failed" && "$status" != "stopped" ]] &&
         kill -0 "$pid" >/dev/null 2>&1; then
        return 0
      fi
    fi
  elif [[ -f "$pid_file" ]]; then
    pid="$(cat "$pid_file")"
    if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
      return 0
    fi
  fi

  return 1
}

running_lane_count_for_wave() {
  local count=0
  local lane_dir=""
  local lane_name=""
  local runtime_root=""

  while IFS= read -r lane_dir; do
    [[ -n "$lane_dir" ]] || continue
    lane_name="$(clasp_swarm_lane_name "$lane_dir")"
    runtime_root="$project_root/.clasp-swarm/$wave_name/$lane_name"
    if lane_runtime_is_running "$runtime_root"; then
      count=$((count + 1))
    fi
  done < <(clasp_swarm_lane_dirs "$wave_name" "$project_root")

  printf '%s\n' "$count"
}

find_next_ready_lane() {
  local lane_dir=""
  local lane_name=""
  local runtime_root=""
  local selected_task=""
  local completed_root=""
  local blocked_root=""
  local global_completed_root="$project_root/.clasp-swarm/completed"
  local first_waiting_task=""
  local first_blocked_task=""

  while IFS= read -r lane_dir; do
    [[ -n "$lane_dir" ]] || continue
    lane_name="$(clasp_swarm_lane_name "$lane_dir")"
    runtime_root="$project_root/.clasp-swarm/$wave_name/$lane_name"
    completed_root="$runtime_root/completed"
    blocked_root="$runtime_root/blocked"

    selected_task="$(
      clasp_swarm_select_next_ready_task \
        "$lane_dir" \
        "$completed_root" \
        "$global_completed_root" \
        "$blocked_root" \
        "$batch_filter" || true
    )"
    if [[ -z "$selected_task" ]]; then
      continue
    fi
    if [[ "$selected_task" == __WAIT__:* ]]; then
      if [[ -z "$first_waiting_task" ]]; then
        first_waiting_task="${selected_task#__WAIT__:}"
      fi
      continue
    fi
    if [[ "$selected_task" == __BLOCKED__:* ]]; then
      if [[ -z "$first_blocked_task" ]]; then
        first_blocked_task="${selected_task#__BLOCKED__:}"
      fi
      continue
    fi

    printf '%s\t%s\n' "$lane_name" "$selected_task"
    return 0
  done < <(clasp_swarm_lane_dirs "$wave_name" "$project_root")

  if [[ -n "$first_blocked_task" ]]; then
    printf '__BLOCKED__\t%s\n' "$first_blocked_task"
    return 0
  fi
  if [[ -n "$first_waiting_task" ]]; then
    printf '__WAIT__\t%s\n' "$first_waiting_task"
    return 0
  fi

  return 1
}

print_json_report() {
  node - "$@" <<'NODE'
const [
  status,
  reason,
  waveName,
  batchFilter,
  runningLanes,
  maxRunningLanes,
  laneMemoryMb,
  minAvailableMemoryMb,
  minAvailableDiskMb,
  minDiskHeadroomMb,
  selectedLane,
  selectedTask,
  jobDir,
  jobStatus,
  jobExitStatus,
  guardDetails,
  resourcePressureKind,
  resourceShortfallMb,
  recommendedAction,
  externalAgentProcessCount,
  externalAgentRssMb,
  externalAgentReservePerProcessMb,
  externalAgentReservedMemoryMb,
  externalAgentProcessNames,
  sameReserveMaxLaneMemoryMb,
  sameLaneMaxMinAvailableMemoryMb,
  candidateLaneMemoryMb,
  candidateMinAvailableMemoryMb,
  candidateRequiredAvailableMemoryMb,
  candidateShortfallMb,
  candidateAdmissible,
  candidateEnv,
  repositoryGateChecked,
  repositoryGateStatus,
  repositoryGateReason,
  repositoryGateAllowDirty,
  repositoryGateCurrentBranch,
  repositoryGateRequiredBranch,
  repositoryGateDirtyEntries,
  repositoryGateRecommendedAction,
] = process.argv.slice(2);

process.stdout.write(`${JSON.stringify({
  schemaVersion: 1,
  status,
  reason,
  waveName,
  batchFilter,
  runningLanes: Number(runningLanes),
  maxRunningLanes: Number(maxRunningLanes),
  laneMemoryMb: Number(laneMemoryMb),
  minAvailableMemoryMb: Number(minAvailableMemoryMb),
  minAvailableDiskMb: Number(minAvailableDiskMb),
  minDiskHeadroomMb: Number(minDiskHeadroomMb),
  selectedLane: selectedLane || null,
  selectedTask: selectedTask || null,
  selectedLaneText: selectedLane || "",
  selectedTaskText: selectedTask || "",
  managedPreflight: {
    jobDir: jobDir || null,
    status: jobStatus || null,
    exitStatus: jobExitStatus || null,
    guardDetails: guardDetails || "",
  },
  resourcePressure: {
    kind: resourcePressureKind || "none",
    shortfallMb: Number(resourceShortfallMb || 0),
    recommendedAction: recommendedAction || "none",
    safeStopPolicy: "stop-only-managed-jobs-by-metadata; do-not-kill-unmanaged-agent-processes",
    externalAgentProcessCount: Number(externalAgentProcessCount || 0),
    externalAgentRssMb: Number(externalAgentRssMb || 0),
    externalAgentReservePerProcessMb: Number(externalAgentReservePerProcessMb || 0),
    externalAgentReservedMemoryMb: Number(externalAgentReservedMemoryMb || 0),
    externalAgentProcessNames: externalAgentProcessNames || "",
  },
  launchAdjustment: {
    sameReserveMaxLaneMemoryMb: Number(sameReserveMaxLaneMemoryMb || 0),
    sameLaneMaxMinAvailableMemoryMb: Number(sameLaneMaxMinAvailableMemoryMb || 0),
    candidateProfile: "bounded-low-memory",
    candidateLaneMemoryMb: Number(candidateLaneMemoryMb || 0),
    candidateMinAvailableMemoryMb: Number(candidateMinAvailableMemoryMb || 0),
    candidateRequiredAvailableMemoryMb: Number(candidateRequiredAvailableMemoryMb || 0),
    candidateShortfallMb: Number(candidateShortfallMb || 0),
    candidateAdmissible: candidateAdmissible === "true",
    candidateEnv: candidateEnv || "",
    note: "candidate settings are advisory; launch only through managed preflight/start with explicit policy",
  },
  repositoryGate: {
    checked: repositoryGateChecked === "1",
    status: repositoryGateStatus || "not-checked",
    reason: repositoryGateReason || "not-requested",
    allowDirty: repositoryGateAllowDirty === "1",
    currentBranch: repositoryGateCurrentBranch || null,
    requiredBranch: repositoryGateRequiredBranch || null,
    dirtyEntries: Number(repositoryGateDirtyEntries || 0),
    recommendedAction: repositoryGateRecommendedAction || "none",
  },
}, null, 2)}\n`);
NODE
}

print_text_report() {
  local status="$1"
  local reason="$2"
  local selected_lane="$3"
  local selected_task="$4"
  local job_dir="$5"
  local job_status="$6"
  local job_exit_status="$7"
  local guard_details="$8"

  printf 'swarm-preflight=%s reason=%s wave=%s batch=%s running_lanes=%s max_running_lanes=%s lane_memory_mb=%s min_available_memory_mb=%s min_available_disk_mb=%s min_disk_headroom_mb=%s\n' \
    "$status" "$reason" "$wave_name" "${batch_filter:-}" "$running_lanes" "$max_running_lanes" "$lane_memory_mb" "$min_available_memory_mb" "$min_available_disk_mb" "$min_disk_headroom_mb"
  if [[ -n "$selected_lane" ]]; then
    printf 'selected_lane=%s\n' "$selected_lane"
  fi
  if [[ -n "$selected_task" ]]; then
    printf 'selected_task=%s\n' "$selected_task"
  fi
  if [[ -n "$job_dir" ]]; then
    printf 'managed_preflight_job=%s status=%s exit_status=%s\n' "$job_dir" "${job_status:-unknown}" "${job_exit_status:-unknown}"
  fi
  if (( include_repository_gate == 1 )); then
    printf 'repository_gate:\n'
    printf 'status=%s\n' "$repository_gate_status"
    printf 'reason=%s\n' "$repository_gate_reason"
    printf 'allow_dirty=%s\n' "$allow_dirty"
    printf 'current_branch=%s\n' "${repository_gate_current_branch:-}"
    printf 'required_branch=%s\n' "$repository_gate_required_branch"
    printf 'dirty_entries=%s\n' "$repository_gate_dirty_entries"
    printf 'recommended_action=%s\n' "$repository_gate_recommended_action"
  fi
  printf 'resource_pressure:\n'
  printf 'resource_pressure_kind=%s\n' "$resource_pressure_kind"
  printf 'resource_shortfall_mb=%s\n' "$resource_shortfall_mb"
  printf 'recommended_action=%s\n' "$recommended_action"
  printf 'safe_stop_policy=stop-only-managed-jobs-by-metadata; do-not-kill-unmanaged-agent-processes\n'
  printf 'external_agent_process_names=%s\n' "$external_agent_process_names"
  printf 'external_agent_process_count=%s\n' "$external_agent_process_count"
  printf 'external_agent_rss_mb=%s\n' "$external_agent_rss_mb"
  printf 'external_agent_reserve_per_process_mb=%s\n' "$external_agent_reserve_per_process_mb"
  printf 'external_agent_reserved_memory_mb=%s\n' "$external_agent_reserved_memory_mb"
  if [[ -n "$guard_details" ]]; then
    printf 'managed_preflight_guard:\n%s\n' "$guard_details"
    printf 'managed_preflight_recovery:\n'
    printf 'resource_pressure_kind=%s\n' "$resource_pressure_kind"
    printf 'resource_shortfall_mb=%s\n' "$resource_shortfall_mb"
    printf 'recommended_action=%s\n' "$recommended_action"
    printf 'safe_stop_policy=stop-only-managed-jobs-by-metadata; do-not-kill-unmanaged-agent-processes\n'
    printf 'external_agent_process_names=%s\n' "$external_agent_process_names"
    printf 'external_agent_process_count=%s\n' "$external_agent_process_count"
    printf 'external_agent_rss_mb=%s\n' "$external_agent_rss_mb"
    printf 'external_agent_reserve_per_process_mb=%s\n' "$external_agent_reserve_per_process_mb"
    printf 'external_agent_reserved_memory_mb=%s\n' "$external_agent_reserved_memory_mb"
    if [[ "$resource_pressure_kind" == "memory" ]]; then
      printf 'launch_adjustment:\n'
      printf 'same_reserve_max_lane_memory_mb=%s\n' "$same_reserve_max_lane_memory_mb"
      printf 'same_lane_max_min_available_memory_mb=%s\n' "$same_lane_max_min_available_memory_mb"
      printf 'candidate_profile=bounded-low-memory\n'
      printf 'candidate_lane_memory_mb=%s\n' "$candidate_lane_memory_mb"
      printf 'candidate_min_available_memory_mb=%s\n' "$candidate_min_available_memory_mb"
      printf 'candidate_required_available_memory_mb=%s\n' "$candidate_required_available_memory_mb"
      printf 'candidate_shortfall_mb=%s\n' "$candidate_shortfall_mb"
      printf 'candidate_admissible=%s\n' "$candidate_admissible"
      printf 'candidate_env=%s\n' "$candidate_env"
      printf 'candidate_note=candidate settings are advisory; launch only through managed preflight/start with explicit policy\n'
    fi
  fi
}

running_lanes="$(running_lane_count_for_wave)"
selected_lane=""
selected_task=""
ready_row=""
job_dir=""
job_status=""
job_exit_status=""
guard_details=""
exit_code=0
err_path="$(mktemp "${TMPDIR:-/tmp}/clasp-swarm-preflight.err.XXXXXX")"

cleanup() {
  rm -f "$err_path"
}

trap cleanup EXIT

if (( max_running_lanes > 0 && running_lanes >= max_running_lanes )); then
  status="blocked"
  reason="max-running-lanes"
  exit_code=75
else
  if ready_row="$(find_next_ready_lane)"; then
    selected_lane="${ready_row%%$'\t'*}"
    selected_task="${ready_row#*$'\t'}"
    if [[ "$selected_lane" == "__WAIT__" ]]; then
      status="waiting"
      reason="dependencies-not-ready"
    elif [[ "$selected_lane" == "__BLOCKED__" ]]; then
      status="blocked"
      reason="lane-task-blocked"
      exit_code=75
    else
      managed_args=(
        "$project_root/scripts/run-managed-job.sh"
        --jobs-root "$project_root/.clasp-swarm/preflight-jobs"
        --preflight-only
      )
      if (( lane_memory_mb > 0 )); then
        managed_args+=(--memory-mb "$lane_memory_mb")
      fi
      if (( min_available_memory_mb > 0 )); then
        managed_args+=(--min-available-memory-mb "$min_available_memory_mb")
      fi
      if (( min_available_disk_mb > 0 )); then
        managed_args+=(--min-available-disk-mb "$min_available_disk_mb" --disk-reserve-path "$project_root")
      fi
      if (( min_disk_headroom_mb > 0 )); then
        managed_args+=(--min-disk-headroom-mb "$min_disk_headroom_mb" --disk-reserve-path "$project_root")
      fi

      set +e
      job_dir="$("${managed_args[@]}" -- bash -c 'exit 0' 2>"$err_path")"
      preflight_status="$?"
      set -e
      if [[ -z "$job_dir" || ! -d "$job_dir" ]]; then
        status="blocked"
        reason="managed-preflight-launch-failed"
        guard_details="$(cat "$err_path" 2>/dev/null || true)"
        exit_code="$preflight_status"
      else
        for _ in $(seq 1 100); do
          job_status="$(managed_job_status "$job_dir")"
          if clasp_swarm_managed_job_status_is_terminal "$job_status" ||
             [[ -f "$job_dir/preflight-passed" || -f "$job_dir/memory-exceeded" || -f "$job_dir/disk-exceeded" || -f "$job_dir/admission-error" || -f "$job_dir/memory-enforcer-error" ]]; then
            break
          fi
          sleep 0.02
        done
        job_status="$(managed_job_status "$job_dir")"
        job_exit_status="$(managed_job_exit_status "$job_dir")"
        if [[ -f "$job_dir/memory-exceeded" ]]; then
          guard_details="$(cat "$job_dir/memory-exceeded")"
          if [[ -z "$job_status" ]]; then
            job_status="memory-exceeded"
          fi
        elif [[ -f "$job_dir/disk-exceeded" ]]; then
          guard_details="$(cat "$job_dir/disk-exceeded")"
          if [[ -z "$job_status" ]]; then
            job_status="disk-exceeded"
          fi
        elif [[ -f "$job_dir/admission-error" ]]; then
          guard_details="$(cat "$job_dir/admission-error")"
          if [[ -z "$job_status" ]]; then
            job_status="admission-lock-unavailable"
          fi
        elif [[ -f "$job_dir/memory-enforcer-error" ]]; then
          guard_details="$(cat "$job_dir/memory-enforcer-error")"
          if [[ -z "$job_status" ]]; then
            job_status="memory-enforcer-unavailable"
          fi
        fi
        if ! clasp_swarm_managed_job_status_is_terminal "$job_status" &&
           [[ "$job_exit_status" == "0" && -f "$job_dir/preflight-passed" ]]; then
          job_status="completed"
        fi
        if [[ "$job_status" == "completed" && "${job_exit_status:-0}" == "0" && -f "$job_dir/preflight-passed" ]]; then
          status="admitted"
          reason="managed-preflight-passed"
        else
          status="blocked"
          reason="managed-preflight-${job_status:-unknown}"
          exit_code=75
        fi
      fi
    fi
  else
    status="idle"
    reason="no-ready-lane"
  fi
fi

evaluate_repository_gate
if [[ "$repository_gate_status" == "blocked" ]]; then
  status="blocked"
  reason="$(repository_gate_top_reason)"
  exit_code=75
fi

resource_pressure_kind="none"
resource_shortfall_mb="0"
recommended_action="none"
external_agent_process_count="0"
external_agent_rss_mb="0"
external_agent_reserved_memory_mb="0"
same_reserve_max_lane_memory_mb="0"
same_lane_max_min_available_memory_mb="0"
candidate_required_available_memory_mb="0"
candidate_shortfall_mb="0"
candidate_admissible="false"
candidate_env=""
refresh_resource_report_fields

if (( json_output )); then
  print_json_report \
    "$status" "$reason" "$wave_name" "$batch_filter" "$running_lanes" "$max_running_lanes" \
    "$lane_memory_mb" "$min_available_memory_mb" "$min_available_disk_mb" "$min_disk_headroom_mb" \
    "$selected_lane" "$selected_task" "$job_dir" "$job_status" "$job_exit_status" "$guard_details" \
    "$resource_pressure_kind" "$resource_shortfall_mb" "$recommended_action" \
    "$external_agent_process_count" "$external_agent_rss_mb" "$external_agent_reserve_per_process_mb" \
    "$external_agent_reserved_memory_mb" "$external_agent_process_names" \
    "$same_reserve_max_lane_memory_mb" "$same_lane_max_min_available_memory_mb" \
    "$candidate_lane_memory_mb" "$candidate_min_available_memory_mb" \
    "$candidate_required_available_memory_mb" "$candidate_shortfall_mb" \
    "$candidate_admissible" "$candidate_env" \
    "$include_repository_gate" "$repository_gate_status" "$repository_gate_reason" "$allow_dirty" \
    "$repository_gate_current_branch" "$repository_gate_required_branch" "$repository_gate_dirty_entries" \
    "$repository_gate_recommended_action"
else
  print_text_report "$status" "$reason" "$selected_lane" "$selected_task" "$job_dir" "$job_status" "$job_exit_status" "$guard_details"
fi

exit "$exit_code"
