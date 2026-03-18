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
lock_capture="$test_root/lock-path.txt"
writable_nested_capture="$test_root/nested.txt"
writable_cache_root="$test_root/writable-cache"
mkdir -p "$writable_cache_root"
fallback_commands=$'printf fallback-ok > '"$fallback_capture"$'\nprintf %s "$CLASP_VERIFY_EFFECTIVE_LOCK_FILE" > '"$lock_capture"

PATH="$test_root/bin:$PATH" \
CLASP_TEST_NIX_ENV_CAPTURE="$env_capture" \
CLASP_VERIFY_FALLBACK_COMMANDS="$fallback_commands" \
"$bash_bin" "$test_root/scripts/verify-all.sh" >/dev/null

[[ "$(< "$fallback_capture")" == "fallback-ok" ]]
[[ "$(< "$env_capture")" == "/tmp/clasp-nix-cache" ]]
[[ "$(< "$lock_capture")" == "$test_root/.clasp-verify.lock" ]]

rm -f "$fallback_capture" "$env_capture" "$lock_capture"
PATH="$test_root/bin:$PATH" \
XDG_CACHE_HOME="$writable_cache_root" \
CLASP_TEST_NIX_ENV_CAPTURE="$env_capture" \
CLASP_VERIFY_FALLBACK_COMMANDS="$fallback_commands" \
"$bash_bin" "$test_root/scripts/verify-all.sh" >/dev/null

[[ "$(< "$fallback_capture")" == "fallback-ok" ]]
[[ "$(< "$env_capture")" == "$writable_cache_root" ]]
[[ "$(< "$lock_capture")" == "$test_root/.clasp-verify.lock" ]]

git_test_root="$test_root/git-repo"
mkdir -p "$git_test_root/scripts"
cp "$project_root/scripts/verify-all.sh" "$git_test_root/scripts/verify-all.sh"
(
  cd "$git_test_root"
  git init -b main >/dev/null
  git config user.name 'Verify All Test'
  git config user.email 'verify-all-test@example.com'
  git add scripts/verify-all.sh
  git commit -m 'init' >/dev/null
)
chmod a-w "$git_test_root/.git"
chmod_restore_needed=1
trap 'if [[ "${chmod_restore_needed:-0}" == "1" && -d "$git_test_root/.git" ]]; then chmod u+w "$git_test_root/.git" >/dev/null 2>&1 || true; fi; rm -rf "${test_root:-}"' EXIT
rm -f "$fallback_capture" "$env_capture" "$lock_capture"
PATH="$test_root/bin:$PATH" \
XDG_CACHE_HOME="$writable_cache_root" \
CLASP_TEST_NIX_ENV_CAPTURE="$env_capture" \
CLASP_VERIFY_FALLBACK_COMMANDS="$fallback_commands" \
"$bash_bin" "$git_test_root/scripts/verify-all.sh" >/dev/null

[[ "$(< "$fallback_capture")" == "fallback-ok" ]]
[[ "$(< "$env_capture")" == "$writable_cache_root" ]]
[[ "$(< "$lock_capture")" == /tmp/clasp-verify-*".lock" ]]
[[ ! -e "$git_test_root/.git/clasp-verify.lock.d" ]]
chmod u+w "$git_test_root/.git"
chmod_restore_needed=0

rm -f "$writable_nested_capture"
PATH="$test_root/bin:$PATH" \
CLASP_VERIFY_IN_PROGRESS=1 \
CLASP_VERIFY_ACTIVE_ROOT="$test_root" \
CLASP_VERIFY_NESTED_COMMANDS=$'printf nested-ok > '"$writable_nested_capture" \
"$bash_bin" "$test_root/scripts/verify-all.sh" >/dev/null

[[ "$(< "$writable_nested_capture")" == "nested-ok" ]]

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
