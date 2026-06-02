#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
mkdir -p "$tmp_root"
test_root="$(mktemp -d "$tmp_root/test-promote-selfhost-managed.XXXXXX")"

cleanup() {
  if [[ "${CLASP_TEST_KEEP_TMP:-}" == "1" ]]; then
    printf 'kept test root: %s\n' "$test_root" >&2
  else
    rm -rf "$test_root" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

mkdir -p "$test_root/scripts"
cp "$project_root/scripts/promote-selfhost-images.sh" "$test_root/scripts/promote-selfhost-images.sh"

cat >"$test_root/scripts/run-managed-job.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

jobs_root=""
memory_mb=""
min_available_memory_mb=""
min_available_disk_mb=""
min_disk_headroom_mb=""
disk_reserve_path=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --jobs-root)
      jobs_root="$2"
      shift 2
      ;;
    --memory-mb)
      memory_mb="$2"
      shift 2
      ;;
    --min-available-memory-mb)
      min_available_memory_mb="$2"
      shift 2
      ;;
    --min-available-disk-mb)
      min_available_disk_mb="$2"
      shift 2
      ;;
    --min-disk-headroom-mb)
      min_disk_headroom_mb="$2"
      shift 2
      ;;
    --disk-reserve-path)
      disk_reserve_path="$2"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *)
      printf 'unexpected fake run-managed arg: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

job_dir="$jobs_root/${CLASP_TEST_FAKE_MANAGED_JOB_ID:-promote-fixture}"
mkdir -p "$job_dir"
printf '%s\n' "$memory_mb" >"$job_dir/memory.arg"
printf '%s\n' "$min_available_memory_mb" >"$job_dir/min-available.arg"
printf '%s\n' "$min_available_disk_mb" >"$job_dir/min-available-disk.arg"
printf '%s\n' "$min_disk_headroom_mb" >"$job_dir/min-disk-headroom.arg"
printf '%s\n' "$disk_reserve_path" >"$job_dir/disk-reserve-path.arg"
for arg in "$@"; do
  printf '<%s>\n' "$arg"
done >"$job_dir/command.args"
printf 'wrapped stdout\n' >"$job_dir/stdout.log"
printf 'wrapped stderr\n' >"$job_dir/stderr.log"
if [[ "${CLASP_TEST_FAKE_MANAGED_STATUS:-completed}" == "started" ]]; then
  printf 'started\n' >"$job_dir/status"
else
  printf '0\n' >"$job_dir/exit-status"
  printf 'completed\n' >"$job_dir/status"
fi
printf '%s\n' "$job_dir"
EOF
chmod +x "$test_root/scripts/run-managed-job.sh"

cat >"$test_root/scripts/stop-managed-job.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

jobs_root=""
target=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --jobs-root)
      jobs_root="$2"
      shift 2
      ;;
    *)
      target="$1"
      shift
      ;;
  esac
done

if [[ -z "$target" ]]; then
  printf 'missing target\n' >&2
  exit 2
fi

job_dir="$target"
if [[ "$target" != /* ]]; then
  job_dir="$jobs_root/$target"
fi
mkdir -p "$job_dir"
printf 'stopped\n' >"$job_dir/status"
printf '%s\n' "$*" >"$(dirname "$jobs_root")/stop-managed.args"
printf '%s\n' "$job_dir" >"$(dirname "$jobs_root")/stop-managed.target"
EOF
chmod +x "$test_root/scripts/stop-managed-job.sh"

(
  cd "$test_root"
  env \
    -u CLASP_PROJECT_ROOT \
    -u CLASP_MANAGED_JOB_ID \
    -u CLASP_MANAGED_JOB_ROOT \
    -u CLASP_MANAGED_JOB_TOKEN \
    -u CLASP_MANAGED_JOB_WORKLOAD \
    -u CLASP_MANAGED_JOB_STOP_REQUEST \
    -u CLASP_PROMOTE_MANAGED_REENTRY \
    CLASP_PROMOTE_MANAGED_MEMORY_MB=256 \
    CLASP_PROMOTE_MANAGED_MIN_AVAILABLE_MEMORY_MB=1024 \
    CLASP_PROMOTE_MANAGED_MIN_AVAILABLE_DISK_MB=2048 \
    CLASP_PROMOTE_MANAGED_MIN_DISK_HEADROOM_MB=512 \
    CLASP_PROMOTE_MANAGED_POLL_SECS=1 \
    bash scripts/promote-selfhost-images.sh >"$test_root/stdout.log" 2>"$test_root/stderr.log"
)

job_dir="$test_root/.clasp-verify/jobs/promote-fixture"
[[ "$(cat "$job_dir/memory.arg")" == "256" ]]
[[ "$(cat "$job_dir/min-available.arg")" == "1024" ]]
[[ "$(cat "$job_dir/min-available-disk.arg")" == "2048" ]]
[[ "$(cat "$job_dir/min-disk-headroom.arg")" == "512" ]]
[[ "$(cat "$job_dir/disk-reserve-path.arg")" == "$test_root" ]]
grep -F '<env>' "$job_dir/command.args" >/dev/null
grep -F '<CLASP_PROMOTE_MANAGED_REENTRY=1>' "$job_dir/command.args" >/dev/null
grep -F '<bash>' "$job_dir/command.args" >/dev/null
grep -F "<$test_root/scripts/promote-selfhost-images.sh>" "$job_dir/command.args" >/dev/null
grep -F 'wrapped stdout' "$test_root/stdout.log" >/dev/null
grep -F 'managed promotion job:' "$test_root/stderr.log" >/dev/null
grep -F 'wrapped stderr' "$test_root/stderr.log" >/dev/null

set +e
(
  cd "$test_root"
  env \
    -u CLASP_PROJECT_ROOT \
    -u CLASP_MANAGED_JOB_ID \
    -u CLASP_MANAGED_JOB_ROOT \
    -u CLASP_MANAGED_JOB_TOKEN \
    -u CLASP_MANAGED_JOB_WORKLOAD \
    -u CLASP_MANAGED_JOB_STOP_REQUEST \
    -u CLASP_PROMOTE_MANAGED_REENTRY \
    CLASP_TEST_FAKE_MANAGED_JOB_ID=promote-fixture-timeout \
    CLASP_TEST_FAKE_MANAGED_STATUS=started \
    CLASP_PROMOTE_MANAGED_MEMORY_MB=256 \
    CLASP_PROMOTE_MANAGED_MIN_AVAILABLE_MEMORY_MB=1024 \
    CLASP_PROMOTE_MANAGED_MIN_AVAILABLE_DISK_MB=2048 \
    CLASP_PROMOTE_MANAGED_MIN_DISK_HEADROOM_MB=512 \
    CLASP_PROMOTE_MANAGED_POLL_SECS=30 \
    timeout 2 bash scripts/promote-selfhost-images.sh >"$test_root/timeout.stdout.log" 2>"$test_root/timeout.stderr.log"
)
timeout_status=$?
set -e

if [[ "$timeout_status" == "0" ]]; then
  printf 'managed promotion timeout fixture should not complete\n' >&2
  exit 1
fi
[[ "$(cat "$test_root/.clasp-verify/jobs/promote-fixture-timeout/status")" == "stopped" ]]
grep -F 'promote-fixture-timeout' "$test_root/.clasp-verify/stop-managed.target" >/dev/null

printf 'promote-selfhost-managed-ok\n'
