#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
timeout_secs="${CLASP_CODEX_LOOP_PROGRAM_TIMEOUT_SECS:-120}"

if ! [[ "$timeout_secs" =~ ^[0-9]+$ ]] || (( timeout_secs < 1 )); then
  printf 'CLASP_CODEX_LOOP_PROGRAM_TIMEOUT_SECS must be a positive integer\n' >&2
  exit 1
fi

mkdir -p "$tmp_root"
test_root="$(mktemp -d "$tmp_root/test-codex-loop-program.XXXXXX")"
output_path="$test_root/output.json"
state_root="$test_root/state"
fake_codex="$test_root/codex"
fake_codex_log="$test_root/codex-invocations.jsonl"
test_xdg_cache_home="${CLASP_TEST_SHARED_XDG_CACHE_HOME:-$tmp_root/clasp-test-xdg-cache}"
if [[ "${CLASP_TEST_ISOLATED_XDG_CACHE:-0}" == "1" ]]; then
  test_xdg_cache_home="$test_root/xdg-cache"
fi
mkdir -p "$test_xdg_cache_home"
export XDG_CACHE_HOME="$test_xdg_cache_home"

cleanup() {
  if [[ "${CLASP_TEST_KEEP_TMP:-}" == "1" ]]; then
    printf 'kept test root: %s\n' "$test_root" >&2
  else
    rm -rf "$test_root" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

cat > "$fake_codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" != "exec" ]]; then
  printf 'expected codex exec, got: %s\n' "$*" >&2
  exit 64
fi

output_path=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-last-message)
      output_path="${2:-}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [[ -z "$output_path" ]]; then
  printf 'missing --output-last-message\n' >&2
  exit 65
fi

role="$(basename "$output_path" .final.txt)"
mkdir -p "$(dirname "$output_path")"
printf '{"type":"agent_message","role":"%s","text":"%s stdout event"}\n' "$role" "$role"
printf '%s stderr event' "$role" >&2
printf '%s final from fake codex\n' "$role" > "$output_path"
printf '{"role":"%s","argv":%s,"outputPath":%s}\n' \
  "$role" \
  "$(node -e 'process.stdout.write(JSON.stringify(process.argv.slice(1)))' "$@")" \
  "$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$output_path")" \
  >> "${CLASP_FAKE_CODEX_LOG:?}"
EOF
chmod +x "$fake_codex"

claspc_bin="$("$project_root/scripts/resolve-claspc.sh")"
demo_path="$project_root/examples/feedback-loop/CodexLoopDemo.clasp"
codex_json="$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$fake_codex")"

if grep -F '"bash"' "$demo_path" >/dev/null; then
  printf 'CodexLoopDemo should invoke Codex directly, not a shell wrapper\n' >&2
  exit 1
fi

grep -F 'codexExecCommand' "$demo_path" >/dev/null
grep -F '"exec"' "$demo_path" >/dev/null
grep -F '"--output-last-message"' "$demo_path" >/dev/null
grep -F 'codex-loop-status.json' "$demo_path" >/dev/null

CLASP_CODEX_LOOP_CODEX_BIN_JSON="$codex_json" \
  timeout "$timeout_secs" "$claspc_bin" --json check "$demo_path" | grep -F '"status":"ok"' >/dev/null
CLASP_CODEX_LOOP_CODEX_BIN_JSON="$codex_json" \
  CLASP_FAKE_CODEX_LOG="$fake_codex_log" \
  timeout "$timeout_secs" "$claspc_bin" run "$demo_path" -- "$state_root" >"$output_path"

node - "$output_path" "$state_root" "$fake_codex_log" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");

const outputPath = process.argv[2];
const stateRoot = process.argv[3];
const fakeCodexLog = process.argv[4];
const report = JSON.parse(fs.readFileSync(outputPath, "utf8"));
const persisted = JSON.parse(fs.readFileSync(path.join(stateRoot, "codex-loop-status.json"), "utf8"));
const events = fs
  .readFileSync(path.join(stateRoot, "codex-loop-events.jsonl"), "utf8")
  .trim()
  .split(/\n/)
  .filter(Boolean)
  .map((line) => JSON.parse(line));
const invocations = fs
  .readFileSync(fakeCodexLog, "utf8")
  .trim()
  .split(/\n/)
  .filter(Boolean)
  .map((line) => JSON.parse(line));

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

function readText(name) {
  return fs.readFileSync(path.join(stateRoot, name), "utf8");
}

assert(report.loopId === "ordinary-clasp-codex-loop", "loop id should identify ordinary Codex path");
assert(report.finalStatus === "completed-pass", `unexpected final status ${report.finalStatus}`);
assert(report.completed === true, "loop should complete");
assert(JSON.stringify(report) === JSON.stringify(persisted), "final state should be durably persisted");
assert(report.builder.ok === true && report.builder.status === "completed-pass", "builder step should pass");
assert(report.verifier.ok === true && report.verifier.status === "completed-pass", "verifier step should pass");
assert(report.builder.finalText === "builder final from fake codex\n", "builder final text should be captured");
assert(report.verifier.finalText === "verifier final from fake codex\n", "verifier final text should be captured");
assert(report.builder.stdout.includes('"role":"builder"'), "builder stdout should be captured");
assert(report.verifier.stdout.includes('"role":"verifier"'), "verifier stdout should be captured");
assert(report.builder.stderr === "builder stderr event", "builder stderr should be captured");
assert(report.verifier.stderr === "verifier stderr event", "verifier stderr should be captured");

assert(readText("builder.final.txt") === report.builder.finalText, "builder final artifact should persist");
assert(readText("verifier.final.txt") === report.verifier.finalText, "verifier final artifact should persist");
assert(readText("builder.prompt.md").includes("builder subagent"), "builder prompt artifact should persist");
assert(readText("verifier.prompt.md").includes("verifier subagent"), "verifier prompt artifact should persist");
assert(JSON.parse(readText("builder.status.json")).role === "builder", "builder status artifact should be readable");
assert(JSON.parse(readText("verifier.status.json")).role === "verifier", "verifier status artifact should be readable");
assert(JSON.parse(readText("builder.heartbeat.json")).completed === true, "builder heartbeat should persist");
assert(JSON.parse(readText("verifier.heartbeat.json")).completed === true, "verifier heartbeat should persist");

assert(invocations.length === 2, "fake Codex should be invoked exactly twice");
assert(invocations.map((entry) => entry.role).join(",") === "builder,verifier", "builder and verifier Codex roles should run");
for (const invocation of invocations) {
  assert(invocation.outputPath.endsWith(`${invocation.role}.final.txt`), "Codex output path should be role-specific");
}

assert(events.some((event) => event.kind === "loop-started" && event.detail.length > 0), "loop start should be logged");
assert(events.filter((event) => event.kind === "step-started").length === 2, "each Codex step should log start");
assert(events.filter((event) => event.kind === "step-completed").length === 2, "each Codex step should log completion");
assert(events.some((event) => event.kind === "loop-completed" && event.status === "completed-pass"), "final event should be logged");
NODE

printf 'codex-loop-program-ok\n'
