#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
bash_bin="$(command -v bash)"
test_root=""

cleanup() {
  rm -rf "${test_root:-}"
}

trap cleanup EXIT

mkdir -p "$tmp_root"
test_root="$(mktemp -d "$tmp_root/test-verify-runtime-slice.XXXXXX")"
project_copy="$test_root/project"
mkdir -p "$project_copy/scripts" "$project_copy/examples/agent-loop-scenario/scripts"

cp "$project_root/scripts/verify-runtime-slice.sh" "$project_copy/scripts/verify-runtime-slice.sh"

make_fake_harness() {
  local script_path="$1"
  cat > "$project_copy/$script_path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s timeout=%s cwd=%s\n' "$0" "${CLASP_RUNTIME_SLICE_TIMEOUT_SECS:-}" "$PWD" >> "${CLASP_TEST_RUNTIME_SLICE_LOG:?}"
printf '%s-ok\n' "$(basename "$0")"
EOF
  chmod +x "$project_copy/$script_path"
}

make_fake_harness scripts/test-monitored-step.sh
make_fake_harness scripts/test-safe-subprocess.sh
make_fake_harness scripts/test-monitored-workflow.sh
make_fake_harness scripts/test-codex-loop-program.sh
make_fake_harness examples/agent-loop-scenario/scripts/verify.sh
make_fake_harness scripts/test-safe-workspace.sh
make_fake_harness scripts/test-swarm-native-managed-loop.sh

CLASP_PROJECT_ROOT="$project_copy" "$bash_bin" "$project_copy/scripts/verify-runtime-slice.sh" --help |
  grep -F 'usage: scripts/verify-runtime-slice.sh' >/dev/null
CLASP_PROJECT_ROOT="$project_copy" "$bash_bin" "$project_copy/scripts/verify-runtime-slice.sh" --list |
  grep -F 'managed-loop' >/dev/null
CLASP_PROJECT_ROOT="$project_copy" "$bash_bin" "$project_copy/scripts/verify-runtime-slice.sh" --list |
  grep -F 'agent-loop' >/dev/null
CLASP_PROJECT_ROOT="$project_copy" "$bash_bin" "$project_copy/scripts/verify-runtime-slice.sh" --list |
  grep -F 'workspace' >/dev/null

workflow_log="$test_root/workflow.log"
CLASP_PROJECT_ROOT="$project_copy" \
  CLASP_TEST_RUNTIME_SLICE_LOG="$workflow_log" \
  CLASP_RUNTIME_SLICE_TIMEOUT_SECS=7 \
  "$bash_bin" "$project_copy/scripts/verify-runtime-slice.sh" workflow |
  grep -F 'verify-runtime-slice: ok (workflow)' >/dev/null

grep -F 'scripts/test-monitored-workflow.sh timeout=7' "$workflow_log" >/dev/null
if grep -F 'test-codex-loop-program.sh' "$workflow_log" >/dev/null; then
  printf 'workflow-only runtime slice should not run the Codex loop fixture\n' >&2
  exit 1
fi

all_log="$test_root/all.log"
CLASP_PROJECT_ROOT="$project_copy" \
  CLASP_TEST_RUNTIME_SLICE_LOG="$all_log" \
  "$bash_bin" "$project_copy/scripts/verify-runtime-slice.sh" all |
  grep -F 'verify-runtime-slice: ok (process workflow codex-loop agent-loop workspace managed-loop)' >/dev/null

grep -F 'scripts/test-monitored-step.sh' "$all_log" >/dev/null
grep -F 'scripts/test-safe-subprocess.sh' "$all_log" >/dev/null
grep -F 'scripts/test-monitored-workflow.sh' "$all_log" >/dev/null
grep -F 'scripts/test-codex-loop-program.sh' "$all_log" >/dev/null
grep -F 'examples/agent-loop-scenario/scripts/verify.sh' "$all_log" >/dev/null
grep -F 'scripts/test-safe-workspace.sh' "$all_log" >/dev/null
grep -F 'scripts/test-swarm-native-managed-loop.sh' "$all_log" >/dev/null

default_log="$test_root/default.log"
CLASP_PROJECT_ROOT="$project_copy" \
  CLASP_TEST_RUNTIME_SLICE_LOG="$default_log" \
  "$bash_bin" "$project_copy/scripts/verify-runtime-slice.sh" |
  grep -F 'verify-runtime-slice: ok (process workflow codex-loop agent-loop workspace)' >/dev/null

grep -F 'scripts/test-monitored-step.sh' "$default_log" >/dev/null
grep -F 'scripts/test-safe-subprocess.sh' "$default_log" >/dev/null
grep -F 'scripts/test-monitored-workflow.sh' "$default_log" >/dev/null
grep -F 'scripts/test-codex-loop-program.sh' "$default_log" >/dev/null
grep -F 'examples/agent-loop-scenario/scripts/verify.sh' "$default_log" >/dev/null
grep -F 'scripts/test-safe-workspace.sh' "$default_log" >/dev/null
if grep -F 'test-swarm-native-managed-loop.sh' "$default_log" >/dev/null; then
  printf 'default runtime slice should stay below the managed-loop control-plane scenario\n' >&2
  exit 1
fi

if CLASP_PROJECT_ROOT="$project_copy" \
  CLASP_TEST_RUNTIME_SLICE_LOG="$test_root/bad.log" \
  CLASP_RUNTIME_SLICE_TIMEOUT_SECS=0 \
  "$bash_bin" "$project_copy/scripts/verify-runtime-slice.sh" process >/dev/null 2>"$test_root/bad.err"; then
  printf 'invalid runtime slice timeout should fail\n' >&2
  exit 1
fi
grep -F 'CLASP_RUNTIME_SLICE_TIMEOUT_SECS must be a positive integer' "$test_root/bad.err" >/dev/null
