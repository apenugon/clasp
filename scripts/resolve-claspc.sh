#!/usr/bin/env bash
set -euo pipefail

ulimit -c 0 >/dev/null 2>&1 || true

project_root="${CLASP_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
if [[ -f "$project_root/scripts/normalize-tmpdir.sh" ]]; then
  source "$project_root/scripts/normalize-tmpdir.sh"
fi
explicit_bin="${CLASP_CLASPC:-${CLASPC_BIN:-}}"
local_debug_bin="$project_root/runtime/target/debug/claspc"
nix_reentry="${CLASP_RESOLVE_CLASPC_NIX_REENTRY:-0}"
build_managed_mode="${CLASP_RESOLVE_CLASPC_BUILD_MANAGED:-auto}"
build_memory_mb="${CLASP_RESOLVE_CLASPC_BUILD_MEMORY_MB:-4096}"
build_min_available_memory_mb="${CLASP_RESOLVE_CLASPC_BUILD_MIN_AVAILABLE_MEMORY_MB:-45056}"
build_min_available_disk_mb="${CLASP_RESOLVE_CLASPC_BUILD_MIN_AVAILABLE_DISK_MB:-16384}"
build_min_disk_headroom_mb="${CLASP_RESOLVE_CLASPC_BUILD_MIN_DISK_HEADROOM_MB:-${CLASP_GENERATED_STATE_MIN_HEADROOM_MB:-1024}}"
cargo_build_jobs="${CLASP_CARGO_BUILD_JOBS:-1}"

validate_non_negative_integer() {
  local name="$1"
  local value="$2"

  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    printf 'resolve-claspc: %s must be a non-negative integer; got %s\n' "$name" "$value" >&2
    exit 2
  fi
}

validate_positive_integer() {
  local name="$1"
  local value="$2"

  if ! [[ "$value" =~ ^[0-9]+$ && "$value" -gt 0 ]]; then
    printf 'resolve-claspc: %s must be a positive integer; got %s\n' "$name" "$value" >&2
    exit 2
  fi
}

validate_non_negative_integer "CLASP_RESOLVE_CLASPC_BUILD_MEMORY_MB" "$build_memory_mb"
validate_non_negative_integer "CLASP_RESOLVE_CLASPC_BUILD_MIN_AVAILABLE_MEMORY_MB" "$build_min_available_memory_mb"
validate_non_negative_integer "CLASP_RESOLVE_CLASPC_BUILD_MIN_AVAILABLE_DISK_MB" "$build_min_available_disk_mb"
validate_non_negative_integer "CLASP_RESOLVE_CLASPC_BUILD_MIN_DISK_HEADROOM_MB" "$build_min_disk_headroom_mb"
validate_positive_integer "CLASP_CARGO_BUILD_JOBS" "$cargo_build_jobs"

binary_is_stale() {
  local binary_path="$1"

  if [[ ! -x "$binary_path" ]]; then
    return 0
  fi

  if [[ "$project_root/src/stage1.native.image.json" -nt "$binary_path" ]]; then
    return 0
  fi

  if [[ "$project_root/src/stage1.compiler.native.image.json" -nt "$binary_path" ]]; then
    return 0
  fi

  if [[ "$project_root/src/stage1.compiler.module-summary-cache-v2.json" -nt "$binary_path" ]]; then
    return 0
  fi

  if [[ "$project_root/src/stage1.compiler.source-export-cache-v1.json" -nt "$binary_path" ]]; then
    return 0
  fi

  if find "$project_root/runtime" -maxdepth 1 \( -name '*.rs' -o -name 'Cargo.toml' \) -newer "$binary_path" -print -quit | grep -q .; then
    return 0
  fi

  return 1
}

build_local_debug_bin() {
  if command -v cargo >/dev/null 2>&1; then
    (
      cd "$project_root"
      export CARGO_TARGET_DIR="$project_root/runtime/target"
      run_cargo_build cargo build --quiet --manifest-path runtime/Cargo.toml --bin claspc
    ) >&2
    return 0
  fi

  local store_cargo=""
  local store_rustc=""
  local store_cc=""
  for candidate in /nix/store/*-cargo-*/bin/cargo; do
    if [[ -x "$candidate" ]]; then
      store_cargo="$candidate"
      break
    fi
  done
  for candidate in /nix/store/*-rustc-*/bin/rustc; do
    if [[ -x "$candidate" ]]; then
      store_rustc="$candidate"
      break
    fi
  done
  for candidate in /nix/store/*-gcc-wrapper-*/bin/cc; do
    if [[ -x "$candidate" ]]; then
      store_cc="$candidate"
      break
    fi
  done
  if [[ -n "$store_cargo" && -n "$store_rustc" ]]; then
    (
      cd "$project_root"
      export CARGO_TARGET_DIR="$project_root/runtime/target"
      if [[ -n "$store_cc" ]]; then
        export PATH="$(dirname "$store_cargo"):$(dirname "$store_rustc"):$(dirname "$store_cc"):$PATH"
      else
        export PATH="$(dirname "$store_cargo"):$(dirname "$store_rustc"):$PATH"
      fi
      run_cargo_build cargo build --quiet --manifest-path runtime/Cargo.toml --bin claspc
    ) >&2
    return 0
  fi

  if [[ "$nix_reentry" == "1" ]]; then
    return 1
  fi

  if ! command -v nix >/dev/null 2>&1; then
    return 1
  fi

  run_cargo_build nix develop "path:$project_root" --command bash -lc "
    set -euo pipefail
    cd \"$project_root\"
    export CLASP_PROJECT_ROOT=\"$project_root\"
    export CLASP_RESOLVE_CLASPC_NIX_REENTRY=1
    export CARGO_TARGET_DIR=\"$project_root/runtime/target\"
    export CARGO_BUILD_JOBS=\"$cargo_build_jobs\"
    cargo build --quiet --manifest-path runtime/Cargo.toml --bin claspc
  " >&2
}

resolve_claspc_managed_build_enabled() {
  case "$build_managed_mode" in
    0|false|FALSE|False|no|NO|No|off|OFF|Off|never|NEVER|Never)
      return 1
      ;;
  esac

  [[ -z "${CLASP_MANAGED_JOB_ID:-}" ]] || return 1
  [[ -x "$project_root/scripts/run-managed-job.sh" ]] || return 1
  return 0
}

run_cargo_build_direct() {
  env CARGO_BUILD_JOBS="$cargo_build_jobs" "$@"
}

run_cargo_build_managed() {
  local job_dir=""
  local status=""
  local exit_status="1"
  local launch_status=0
  local -a managed_args=("$project_root/scripts/run-managed-job.sh" --jobs-root "$project_root/.clasp-verify/resolve-claspc-jobs")

  if (( build_memory_mb > 0 )); then
    managed_args+=(--memory-mb "$build_memory_mb")
  fi
  if (( build_min_available_memory_mb > 0 )); then
    managed_args+=(--min-available-memory-mb "$build_min_available_memory_mb")
  fi
  if (( build_min_available_disk_mb > 0 )); then
    managed_args+=(--min-available-disk-mb "$build_min_available_disk_mb" --disk-reserve-path "$project_root")
  fi
  if (( build_min_disk_headroom_mb > 0 )); then
    managed_args+=(--min-disk-headroom-mb "$build_min_disk_headroom_mb" --disk-reserve-path "$project_root")
  fi

  job_dir="$(
    "${managed_args[@]}" \
      -- env CARGO_BUILD_JOBS="$cargo_build_jobs" "$@"
  )" || launch_status=$?
  if (( launch_status != 0 )); then
    return "$launch_status"
  fi

  while true; do
    status="$(sed -n '1p' "$job_dir/status" 2>/dev/null || printf 'missing')"
    case "$status" in
      completed|failed|stopped|memory-exceeded|disk-exceeded)
        break
        ;;
    esac
    sleep 0.2
  done

  if [[ -f "$job_dir/stdout.log" ]]; then
    cat "$job_dir/stdout.log"
  fi
  if [[ -f "$job_dir/stderr.log" ]]; then
    cat "$job_dir/stderr.log" >&2
  fi
  if [[ -f "$job_dir/memory-exceeded" ]]; then
    printf 'resolve-claspc: cargo build memory guard tripped:\n' >&2
    sed 's/^/  /' "$job_dir/memory-exceeded" >&2 || true
  fi
  if [[ -f "$job_dir/disk-exceeded" ]]; then
    printf 'resolve-claspc: cargo build disk guard tripped:\n' >&2
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

run_cargo_build() {
  if resolve_claspc_managed_build_enabled; then
    run_cargo_build_managed "$@"
  else
    run_cargo_build_direct "$@"
  fi
}

if [[ -n "$explicit_bin" ]]; then
  if [[ ! -x "$explicit_bin" ]]; then
    printf 'resolve-claspc: explicit binary is not executable: %s\n' "$explicit_bin" >&2
    exit 1
  fi
  printf '%s\n' "$explicit_bin"
  exit 0
fi

if [[ -x "$local_debug_bin" ]] && ! binary_is_stale "$local_debug_bin"; then
  printf '%s\n' "$local_debug_bin"
  exit 0
fi

if build_local_debug_bin && [[ -x "$local_debug_bin" ]]; then
  printf '%s\n' "$local_debug_bin"
  exit 0
fi

for binary_path in /nix/store/*-claspc-*/bin/claspc; do
  if [[ "$binary_path" == '/nix/store/*-claspc-*/bin/claspc' ]]; then
    break
  fi
  if [[ -x "$binary_path" ]]; then
    # Last-resort fallback only when a current local debug compiler could not be built.
    # This keeps non-Nix ad hoc invocations usable, but callers should prefer the
    # local debug binary because older store outputs may lag the checked-in images.
    if [[ -x "$local_debug_bin" ]]; then
      printf '%s\n' "$local_debug_bin"
      exit 0
    fi
    if [[ "$nix_reentry" != "1" ]] || ! command -v cargo >/dev/null 2>&1; then
      printf '%s\n' "$binary_path"
      exit 0
    fi
  fi
done

if [[ -x "$local_debug_bin" ]]; then
  printf '%s\n' "$local_debug_bin"
  exit 0
fi

printf '%s\n' 'resolve-claspc: unable to find a current native claspc binary' >&2
exit 1
