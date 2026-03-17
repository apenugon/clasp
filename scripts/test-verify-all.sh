#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root=""
bash_bin="$(command -v bash)"

cleanup() {
  rm -rf "${test_root:-}"
}

trap cleanup EXIT

test_root="$(mktemp -d)"
mkdir -p "$test_root/bin" "$test_root/scripts"
cp "$project_root/scripts/verify-all.sh" "$test_root/scripts/verify-all.sh"

cat > "$test_root/bin/nix" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "${XDG_CACHE_HOME:-}" > "${CLASP_TEST_NIX_ENV_CAPTURE:?}"
printf '%s\n' "${CLASP_TEST_NIX_MESSAGE:-error: cannot connect to socket at /nix/var/nix/daemon-socket/socket: Operation not permitted}" >&2
exit 1
EOF
chmod +x "$test_root/bin/nix"

fallback_capture="$test_root/fallback.txt"
env_capture="$test_root/nix-env.txt"

PATH="$test_root/bin:$PATH" \
CLASP_TEST_NIX_ENV_CAPTURE="$env_capture" \
CLASP_VERIFY_FALLBACK_COMMANDS=$'printf fallback-ok > fallback.txt' \
"$bash_bin" "$test_root/scripts/verify-all.sh" >/dev/null

[[ "$(< "$fallback_capture")" == "fallback-ok" ]]
[[ "$(< "$env_capture")" == "/tmp/clasp-nix-cache" ]]

rm -f "$fallback_capture"
if PATH="$test_root/bin:$PATH" \
  CLASP_TEST_NIX_ENV_CAPTURE="$env_capture" \
  CLASP_TEST_NIX_MESSAGE='error: unexpected nix failure' \
  CLASP_VERIFY_FALLBACK_COMMANDS=$'printf should-not-run > fallback.txt' \
  "$bash_bin" "$test_root/scripts/verify-all.sh" >/dev/null 2>"$test_root/unexpected.log"; then
  printf 'verify-all unexpectedly succeeded on an unknown nix failure\n' >&2
  exit 1
fi

[[ ! -f "$fallback_capture" ]]
