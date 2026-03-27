#!/usr/bin/env bash
set -euo pipefail

project_root="${CLASP_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
explicit_bin="${CLASP_CLASPC:-${CLASPC_BIN:-}}"
local_debug_bin="$project_root/runtime/target/debug/claspc"
nix_reentry="${CLASP_RESOLVE_CLASPC_NIX_REENTRY:-0}"

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

  if find "$project_root/runtime" -maxdepth 1 \( -name '*.rs' -o -name 'Cargo.toml' \) -newer "$binary_path" -print -quit | grep -q .; then
    return 0
  fi

  return 1
}

build_local_debug_bin() {
  if command -v cargo >/dev/null 2>&1; then
    (
      cd "$project_root"
      cargo build --quiet --manifest-path runtime/Cargo.toml --bin claspc
    ) >&2
    return 0
  fi

  if [[ "$nix_reentry" == "1" ]]; then
    return 1
  fi

  if ! command -v nix >/dev/null 2>&1; then
    return 1
  fi

  nix develop "$project_root" --command bash -lc "
    set -euo pipefail
    cd \"$project_root\"
    export CLASP_PROJECT_ROOT=\"$project_root\"
    export CLASP_RESOLVE_CLASPC_NIX_REENTRY=1
    cargo build --quiet --manifest-path runtime/Cargo.toml --bin claspc
  " >&2
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
