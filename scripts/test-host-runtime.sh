#!/usr/bin/env bash
set -euo pipefail

ulimit -c 0 >/dev/null 2>&1 || true

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
mkdir -p "$tmp_root"
test_root="$(mktemp -d "$tmp_root/test-host-runtime.XXXXXX")"
host_resource_process_pid=""
managed_jobs_root="$test_root/managed-jobs"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$test_root/xdg-cache}"
export CLASP_NATIVE_RUN_BINARY_CACHE_DIR="${CLASP_NATIVE_RUN_BINARY_CACHE_DIR:-$test_root/run-binary-cache-v2}"
mkdir -p "$XDG_CACHE_HOME" "$CLASP_NATIVE_RUN_BINARY_CACHE_DIR"

test_export_host_pids() {
  local cache="$XDG_CACHE_HOME"
  ps -eo pid=,comm=,args= 2>/dev/null |
    awk -v cache="$cache" '
      $2 == "claspc" && index($0, "__serve-native-export-host") && index($0, cache) { print $1 }
    '
}

cleanup() {
  if [[ -n "${host_resource_process_pid:-}" ]]; then
    kill "$host_resource_process_pid" >/dev/null 2>&1 || true
    wait "$host_resource_process_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$test_root"
}

trap cleanup EXIT

run_managed_capture() {
  local output_path="$1"
  shift
  local job_dir=""
  local status=""
  local exit_status="1"
  local wait_secs="${CLASP_HOST_RUNTIME_TEST_MANAGED_WAIT_SECS:-180}"
  local waited=0
  local memory_mb="${CLASP_HOST_RUNTIME_TEST_MEMORY_MB:-4096}"
  local min_available_memory_mb="${CLASP_HOST_RUNTIME_TEST_MIN_AVAILABLE_MEMORY_MB:-8192}"
  local min_available_disk_mb="${CLASP_HOST_RUNTIME_TEST_MIN_AVAILABLE_DISK_MB:-4096}"
  local min_disk_headroom_mb="${CLASP_HOST_RUNTIME_TEST_MIN_DISK_HEADROOM_MB:-512}"
  local -a managed_args=("$project_root/scripts/run-managed-job.sh" --jobs-root "$managed_jobs_root")

  if (( memory_mb > 0 )); then
    managed_args+=(--memory-mb "$memory_mb")
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

  job_dir="$(
    CLASP_MANAGED_JOB_USE_SYSTEMD_SCOPE="${CLASP_HOST_RUNTIME_TEST_USE_SYSTEMD_SCOPE:-auto}" \
      "${managed_args[@]}" -- "$@"
  )"

  while true; do
    status="$(sed -n '1p' "$job_dir/status" 2>/dev/null || printf 'missing')"
    case "$status" in
      completed|failed|stopped|memory-exceeded|disk-exceeded)
        break
        ;;
    esac
    if (( waited >= wait_secs )); then
      "$project_root/scripts/stop-managed-job.sh" --jobs-root "$managed_jobs_root" "$job_dir" >/dev/null 2>&1 || true
      printf 'host-runtime managed job timed out after %s seconds: %s\n' "$wait_secs" "$job_dir" >&2
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done

  if [[ -f "$job_dir/stdout.log" ]]; then
    cp "$job_dir/stdout.log" "$output_path"
  else
    : >"$output_path"
  fi
  if [[ -f "$job_dir/stderr.log" && -s "$job_dir/stderr.log" ]]; then
    cat "$job_dir/stderr.log" >&2
  fi
  if [[ -f "$job_dir/memory-exceeded" ]]; then
    printf 'host-runtime managed job memory guard tripped:\n' >&2
    sed 's/^/  /' "$job_dir/memory-exceeded" >&2 || true
  fi
  if [[ -f "$job_dir/disk-exceeded" ]]; then
    printf 'host-runtime managed job disk guard tripped:\n' >&2
    sed 's/^/  /' "$job_dir/disk-exceeded" >&2 || true
  fi

  if [[ -f "$job_dir/exit-status" ]]; then
    exit_status="$(tr -d '[:space:]' <"$job_dir/exit-status")"
  elif [[ "$status" == "completed" ]]; then
    exit_status=0
  fi
  if ! [[ "$exit_status" =~ ^[0-9]+$ ]]; then
    exit_status=1
  fi
  return "$exit_status"
}

claspc_bin="$(
  CLASP_CLASPC= CLASPC_BIN= CLASP_PROJECT_ROOT="$project_root" \
    "$project_root/scripts/resolve-claspc.sh"
)"
state_root="$test_root/state"
output_path="$test_root/host-runtime-output.json"
host_resources_output_path="$test_root/host-resources-output.json"
host_resources_size_file="$test_root/host-resources-size.log"

CLASP_HOST_RUNTIME_SCENARIO_ENV=parent-env \
  run_managed_capture "$output_path" \
    timeout 120 "$claspc_bin" run "$project_root/examples/host-runtime/HostRuntimeHarness.clasp" -- "$state_root"

node - "$output_path" "$state_root" <<'EOF'
const fs = require("node:fs");
const path = require("node:path");

const [outputPath, stateRoot] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(outputPath, "utf8"));

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

assert(typeof report.cwd === "string" && report.cwd.length > 0, "expected current working directory");
assert(report.parentEnv === "parent-env", "parent env lookup did not round-trip");
assert(report.fileText === "file-text", "readFile did not read the written input file");
assert(report.writeBack === "child-env:missing:file-text", "writeFile did not persist process stdout");
assert(report.exitCode === 0, `unexpected process exit code ${report.exitCode}`);
assert(report.stdout === "child-env:missing:file-text", "process stdout did not include cwd file and isolated child env");
assert(report.stderr === "err-child-env", "process stderr did not include child env");
assert(report.parentChildEnv === "ERR:missing", "child env leaked into the parent runtime");
assert(report.timeoutExitCode === 124, `unexpected timeout exit code ${report.timeoutExitCode}`);
assert(report.timeoutTimedOut === true, "timed process did not report timedOut");
assert(report.timeoutError === "timeout", `unexpected timeout error ${report.timeoutError}`);
assert(report.timeoutMarkerExists === false, "timed process descendant survived past timeout");
assert(report.eventLogText === "event-one\nevent-two\n", "appendFile did not persist nested event log");
assert(
  fs.readFileSync(path.join(stateRoot, "output.txt"), "utf8") === "child-env:missing:file-text",
  "persisted output file mismatch",
);
assert(
  fs.readFileSync(path.join(stateRoot, "logs", "events.jsonl"), "utf8") === "event-one\nevent-two\n",
  "persisted event log mismatch",
);
EOF

sleep 30 &
host_resource_process_pid="$!"
dd if=/dev/zero of="$host_resources_size_file" bs=1M count=2 status=none

CLASP_HOST_RESOURCES_LIVE_PID="$$" \
CLASP_HOST_RESOURCES_PROCESS_NAME="sleep" \
CLASP_HOST_RESOURCES_FILE_SIZE_PATH="$host_resources_size_file" \
  run_managed_capture "$host_resources_output_path" \
    timeout 120 "$claspc_bin" run "$project_root/examples/swarm-native/HostResourcesHarness.clasp"

node - "$host_resources_output_path" "$host_resources_size_file" <<'EOF'
const fs = require("node:fs");

const [outputPath, sizeFilePath] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(outputPath, "utf8"));

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

assert(Number.isInteger(report.availableMb), "expected integer available disk");
assert(report.availableMb > 0, `expected positive available disk, got ${report.availableMb}`);
assert(report.availableError === "", `unexpected available disk error ${report.availableError}`);
assert(report.reserveZero === true, "zero disk reserve should always pass");
assert(report.reserveOne === true, "one MB disk reserve should pass on this test host");
assert(typeof report.invalidPathError === "string" && report.invalidPathError.length > 0, "invalid path should return an error");
assert(report.invalidPathError !== "unexpected-ok", "invalid path unexpectedly succeeded");
assert(report.fileSizeMb === 2, `expected 2 MB file size, got ${report.fileSizeMb}`);
assert(report.fileSizeError === "", `unexpected file size error ${report.fileSizeError}`);
assert(typeof report.missingFileSizeError === "string" && report.missingFileSizeError.length > 0, "missing file size should return an error");
assert(report.missingFileSizeError !== "unexpected-ok", "missing file size unexpectedly succeeded");
assert(report.capFileSizeMb === 1, `expected capped file size 1 MB, got ${report.capFileSizeMb}`);
assert(report.capFileError === "", `unexpected cap file error ${report.capFileError}`);
assert(fs.statSync(sizeFilePath).size === 1048576, "cap should keep exactly the final 1 MiB");
assert(Number.isInteger(report.availableMemoryMb), "expected integer available memory");
assert(report.availableMemoryMb > 0, `expected positive available memory, got ${report.availableMemoryMb}`);
assert(report.availableMemoryError === "", `unexpected available memory error ${report.availableMemoryError}`);
assert(report.memoryReserveZero === true, "zero memory reserve should always pass");
assert(report.memoryReserveOne === true, "one MB memory reserve should pass on this test host");
assert(report.livePidAlive === true, "live parent pid should be visible to hostProcessAlive");
assert(report.invalidPidAlive === false, "invalid pid should not be treated as alive");
assert(report.processName === "sleep", "process count fixture name did not round-trip");
assert(Number.isInteger(report.processNameCount), "expected integer process count");
assert(report.processNameCount >= 1, `expected to count the sleep fixture, got ${report.processNameCount}`);
assert(Number.isInteger(report.unmanagedProcessNameCount), "expected integer unmanaged process count");
assert(report.unmanagedProcessNameCount >= 1, `expected to count the unmanaged sleep fixture, got ${report.unmanagedProcessNameCount}`);
assert(Number.isInteger(report.unmanagedProcessNameRssMb), "expected integer unmanaged process RSS");
assert(report.unmanagedProcessNameRssMb >= 0, `expected non-negative unmanaged process RSS, got ${report.unmanagedProcessNameRssMb}`);
assert(report.missingProcessNameCount === 0, "missing process name should have zero matches");
EOF

kill "$host_resource_process_pid" >/dev/null 2>&1 || true
wait "$host_resource_process_pid" >/dev/null 2>&1 || true
host_resource_process_pid=""

for _ in 1 2 3 4 5; do
  if [[ -z "$(test_export_host_pids)" ]]; then
    break
  fi
  sleep 1
done

leftover_export_hosts="$(test_export_host_pids)"
if [[ -n "$leftover_export_hosts" ]]; then
  printf 'host runtime left test export host process(es): %s\n' "$leftover_export_hosts" >&2
  exit 1
fi

printf '%s\n' "host-runtime-ok"
