#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
bash_bin="$(command -v bash)"

cleanup() {
  rm -rf "$test_root"
}

trap cleanup EXIT

mkdir -p "$test_root/bin" "$test_root/scripts"
cp "$project_root/scripts/test-native-runtime.sh" "$test_root/scripts/test-native-runtime.sh"
cp "$project_root/scripts/resolve-claspc.sh" "$test_root/scripts/resolve-claspc.sh"

cat > "$test_root/bin/fake-claspc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$0"
EOF
chmod +x "$test_root/bin/fake-claspc"

nix_log="$test_root/nix.log"
cat > "$test_root/bin/nix" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

log_path="${CLASP_TEST_NATIVE_RUNTIME_NIX_LOG:?}"
printf '%s\n' "$*" > "$log_path"

if [[ "$1" != "develop" ]]; then
  printf 'expected nix develop invocation, got: %s\n' "$*" >&2
  exit 1
fi

if [[ "$3" != "--command" || "$4" != "bash" || "$5" != "-lc" ]]; then
  printf 'expected nix develop --command bash -lc, got: %s\n' "$*" >&2
  exit 1
fi

command_text="$6"
[[ "$command_text" == *'export CLASP_NATIVE_RUNTIME_NIX_REENTRY=1'* ]]
[[ "$command_text" == *'bash scripts/test-native-runtime.sh'* ]]
EOF
chmod +x "$test_root/bin/nix"

PATH="$test_root/bin:$PATH" \
IN_NIX_SHELL= \
CLASPC_BIN="$test_root/bin/fake-claspc" \
CLASP_TEST_NATIVE_RUNTIME_NIX_LOG="$nix_log" \
"$bash_bin" "$test_root/scripts/test-native-runtime.sh" >/dev/null

grep -F "develop $test_root --command bash -lc" "$nix_log" >/dev/null
