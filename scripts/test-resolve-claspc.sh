#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
mkdir -p "$tmp_root"
test_root="$(mktemp -d "$tmp_root/test-resolve-claspc.XXXXXX")"

cleanup() {
  rm -rf "$test_root" >/dev/null 2>&1 || true
}

trap cleanup EXIT

repo_root="$test_root/repo"
mkdir -p "$repo_root/scripts" "$repo_root/bin" "$repo_root/runtime" "$repo_root/src"
cp "$project_root/scripts/resolve-claspc.sh" "$repo_root/scripts/resolve-claspc.sh"
chmod +x "$repo_root/scripts/resolve-claspc.sh"
printf '[package]\nname = "fake-runtime"\nversion = "0.0.0"\n' >"$repo_root/runtime/Cargo.toml"
printf '{}\n' >"$repo_root/src/stage1.compiler.module-summary-cache-v2.json"
printf '{}\n' >"$repo_root/src/stage1.compiler.source-export-cache-v1.json"

cat >"$repo_root/scripts/run-managed-job.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

jobs_root=""
job_id="fake-managed-build"
capture="${CLASP_TEST_RESOLVE_MANAGED_ARGS:?}"

printf '%s\n' "$@" >"$capture"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --jobs-root)
      jobs_root="$2"
      shift 2
      ;;
    --job-id)
      job_id="$2"
      shift 2
      ;;
    --memory-mb|--min-available-memory-mb|--min-available-disk-mb|--min-disk-headroom-mb|--disk-reserve-path)
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *)
      printf 'unexpected fake run-managed-job arg: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$jobs_root" || $# -lt 1 ]]; then
  printf 'fake run-managed-job missing jobs root or command\n' >&2
  exit 2
fi

job_dir="$jobs_root/$job_id"
mkdir -p "$job_dir"
printf '%s\n' "$$" >"$job_dir/pid"
printf '%s\n' "$$" >"$job_dir/pgid"
printf '%s\n' "$$" >"$job_dir/sid"
printf '%s\n' "$PWD" >"$job_dir/cwd"

set +e
"$@" >"$job_dir/stdout.log" 2>"$job_dir/stderr.log"
status=$?
set -e

printf '%s\n' "$status" >"$job_dir/exit-status"
if [[ "$status" == "0" ]]; then
  printf 'completed\n' >"$job_dir/status"
else
  printf 'failed\n' >"$job_dir/status"
fi
printf '%s\n' "$job_dir"
EOF
chmod +x "$repo_root/scripts/run-managed-job.sh"

cat >"$repo_root/bin/cargo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

repo_root="${CLASP_TEST_RESOLVE_PROJECT:?}"
printf 'CARGO_BUILD_JOBS=%s\n' "${CARGO_BUILD_JOBS:-}" >"${CLASP_TEST_RESOLVE_CARGO_ENV:?}"
printf '%s\n' "$@" >"${CLASP_TEST_RESOLVE_CARGO_ARGS:?}"
mkdir -p "$repo_root/runtime/target/debug"
cat >"$repo_root/runtime/target/debug/claspc" <<'BIN'
#!/usr/bin/env bash
printf 'fake-claspc\n'
BIN
chmod +x "$repo_root/runtime/target/debug/claspc"
EOF
chmod +x "$repo_root/bin/cargo"

managed_args_path="$test_root/managed-args.txt"
cargo_env_path="$test_root/cargo-env.txt"
cargo_args_path="$test_root/cargo-args.txt"

resolved="$(
  env \
  -u CLASP_MANAGED_JOB_ID \
  -u CLASP_MANAGED_JOB_ROOT \
  -u CLASP_MANAGED_JOB_TOKEN \
  -u CLASP_MANAGED_JOB_STOP_REQUEST \
  PATH="$repo_root/bin:$PATH" \
  CLASP_PROJECT_ROOT="$repo_root" \
  CLASP_TEST_RESOLVE_PROJECT="$repo_root" \
  CLASP_TEST_RESOLVE_MANAGED_ARGS="$managed_args_path" \
  CLASP_TEST_RESOLVE_CARGO_ENV="$cargo_env_path" \
  CLASP_TEST_RESOLVE_CARGO_ARGS="$cargo_args_path" \
  CLASP_RESOLVE_CLASPC_BUILD_MEMORY_MB=321 \
  CLASP_RESOLVE_CLASPC_BUILD_MIN_AVAILABLE_MEMORY_MB=654 \
  CLASP_RESOLVE_CLASPC_BUILD_MIN_AVAILABLE_DISK_MB=987 \
  CLASP_RESOLVE_CLASPC_BUILD_MIN_DISK_HEADROOM_MB=111 \
    "$repo_root/scripts/resolve-claspc.sh"
)"
[[ "$resolved" == "$repo_root/runtime/target/debug/claspc" ]]
grep -F 'CARGO_BUILD_JOBS=1' "$cargo_env_path" >/dev/null
grep -F 'build' "$cargo_args_path" >/dev/null
grep -Fx -- '--memory-mb' "$managed_args_path" >/dev/null
grep -Fx '321' "$managed_args_path" >/dev/null
grep -Fx -- '--min-available-memory-mb' "$managed_args_path" >/dev/null
grep -Fx '654' "$managed_args_path" >/dev/null
grep -Fx -- '--min-available-disk-mb' "$managed_args_path" >/dev/null
grep -Fx '987' "$managed_args_path" >/dev/null
grep -Fx -- '--min-disk-headroom-mb' "$managed_args_path" >/dev/null
grep -Fx '111' "$managed_args_path" >/dev/null

rm -f "$repo_root/runtime/target/debug/claspc" "$managed_args_path" "$cargo_env_path" "$cargo_args_path"
resolved_inside_managed="$(
  env \
  -u CLASP_MANAGED_JOB_ROOT \
  -u CLASP_MANAGED_JOB_TOKEN \
  -u CLASP_MANAGED_JOB_STOP_REQUEST \
  PATH="$repo_root/bin:$PATH" \
  CLASP_PROJECT_ROOT="$repo_root" \
  CLASP_MANAGED_JOB_ID=outer-managed-job \
  CLASP_TEST_RESOLVE_PROJECT="$repo_root" \
  CLASP_TEST_RESOLVE_MANAGED_ARGS="$managed_args_path" \
  CLASP_TEST_RESOLVE_CARGO_ENV="$cargo_env_path" \
  CLASP_TEST_RESOLVE_CARGO_ARGS="$cargo_args_path" \
  CLASP_CARGO_BUILD_JOBS=2 \
    "$repo_root/scripts/resolve-claspc.sh"
)"
[[ "$resolved_inside_managed" == "$repo_root/runtime/target/debug/claspc" ]]
[[ ! -e "$managed_args_path" ]]
grep -F 'CARGO_BUILD_JOBS=2' "$cargo_env_path" >/dev/null

if CLASP_PROJECT_ROOT="$repo_root" CLASP_CARGO_BUILD_JOBS=0 "$repo_root/scripts/resolve-claspc.sh" >"$test_root/invalid.out" 2>"$test_root/invalid.err"; then
  printf 'resolve-claspc unexpectedly accepted CLASP_CARGO_BUILD_JOBS=0\n' >&2
  exit 1
fi
grep -F 'CLASP_CARGO_BUILD_JOBS must be a positive integer' "$test_root/invalid.err" >/dev/null

printf 'resolve-claspc-ok\n'
