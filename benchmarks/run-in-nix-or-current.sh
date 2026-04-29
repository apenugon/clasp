#!/usr/bin/env bash
set -euo pipefail

project_root="${1:?project root is required}"
shift

if [[ $# -eq 0 ]]; then
  echo "run-in-nix-or-current.sh requires a command" >&2
  exit 2
fi

nix_failure_log="$(mktemp)"
shim_root=""

cleanup() {
  rm -f "$nix_failure_log"
  rm -rf "${shim_root:-}"
}

trap cleanup EXIT

run_current_shell() {
  shim_root="$(mktemp -d)"
  cat >"$shim_root/bun" <<EOF
#!/usr/bin/env bash
exec node "$project_root/benchmarks/node-bun-shim.mjs" "\$@"
EOF
  chmod +x "$shim_root/bun"

  CLASP_PROJECT_ROOT="$project_root" PATH="$shim_root:$PATH" "$@"
}

if [[ -n "${IN_NIX_SHELL:-}" || "${CLASP_BENCHMARK_USE_CURRENT_SHELL:-0}" == "1" ]]; then
  run_current_shell "$@"
  exit 0
fi

if nix develop "$project_root" --command "$@" 2>"$nix_failure_log"; then
  exit 0
fi

if grep -Eq 'readonly database|daemon-socket/socket|not tracked by Git' "$nix_failure_log"; then
  printf 'benchmark-verify: falling back to current shell because Nix cannot evaluate this workspace\n' >&2
  run_current_shell "$@"
  exit 0
fi

cat "$nix_failure_log" >&2
exit 1
