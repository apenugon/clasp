#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
timeout_secs="${CLASP_FEEDBACK_LOOP_ROUTING_TIMEOUT_SECS:-90}"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
test_root=""

usage() {
  cat <<'EOF'
usage: scripts/test-feedback-loop-routing.sh [case-or-group ...]

Runs the lightweight ordinary-Clasp focused verifier routing probe. This covers
the diff-derived selector without launching the full feedback-loop manager.

Cases:
  all
  routing
  loop-routing
  native-routing
  goal-helper-routing
  speed-routing
  verify-routing
  unknown-routing
EOF
}

cleanup() {
  rm -rf "${test_root:-}" >/dev/null 2>&1 || true
}

requested_cases=("$@")
if (( ${#requested_cases[@]} == 0 )); then
  requested_cases=(all)
fi

for requested_case in "${requested_cases[@]}"; do
  case "$requested_case" in
    --help|-h)
      usage
      exit 0
      ;;
    all|routing|loop-routing|native-routing|goal-helper-routing|speed-routing|verify-routing|unknown-routing)
      ;;
    *)
      printf 'test-feedback-loop-routing: unknown case or group: %s\n' "$requested_case" >&2
      usage >&2
      exit 2
      ;;
  esac
done

parse_positive_timeout() {
  if ! [[ "$timeout_secs" =~ ^[0-9]+$ ]] || (( timeout_secs < 1 )); then
    printf 'test-feedback-loop-routing: CLASP_FEEDBACK_LOOP_ROUTING_TIMEOUT_SECS must be a positive integer\n' >&2
    exit 2
  fi
}

mkdir -p "$tmp_root"
test_root="$(mktemp -d "$tmp_root/test-feedback-loop-routing.XXXXXX")"
trap cleanup EXIT

parse_positive_timeout
claspc_bin="$("$project_root/scripts/resolve-claspc.sh")"
snapshot_path="$test_root/focused-selection.json"

(
  cd "$project_root"
  timeout "$timeout_secs" "$claspc_bin" run examples/feedback-loop/FocusedSelectionProbe.clasp
) > "$snapshot_path"

node - "$snapshot_path" "${requested_cases[@]}" <<'NODE'
const fs = require("node:fs");

const snapshot = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const requested = process.argv.slice(3);

function assert(condition, message) {
  if (!condition) {
    console.error(`test-feedback-loop-routing: ${message}`);
    process.exit(1);
  }
}

function wants(name) {
  return requested.length === 0 || requested.includes("all") || requested.includes("routing") || requested.includes(name);
}

function hasCommand(selection, fragment) {
  return selection.commands.some((command) => command.includes(fragment));
}

function hasCategory(selection, category) {
  return selection.changedSurfaceCategories.includes(category);
}

function assertNarrow(selection, name) {
  assert(selection.source === "diff-derived", `${name} should be diff-derived`);
  assert(selection.fallbackReason === "", `${name} should not have a fallback reason`);
  assert(!hasCommand(selection, "bash scripts/verify-fast.sh"), `${name} should not select verify-fast`);
}

if (wants("loop-routing")) {
  assertNarrow(snapshot.loop, "loop-routing");
  assert(hasCategory(snapshot.loop, "feedback_loop"), "loop-routing should classify feedback_loop");
  assert(hasCommand(snapshot.loop, "bash scripts/test-feedback-loop-routing.sh loop-routing"), "loop-routing should keep the focused routing command");
  assert(hasCommand(snapshot.loop, "bash scripts/test-swarm-ready-gate.sh"), "loop-routing should keep ready-gate coverage");
  assertNarrow(snapshot.generatedLoop, "loop-routing generated-noise");
  assert(hasCategory(snapshot.generatedLoop, "feedback_loop"), "generated runtime target noise should not hide feedback_loop");
  assert(!hasCategory(snapshot.generatedLoop, "compiler_runtime_broad"), "generated runtime target noise should not force broad routing");
}

if (wants("native-routing")) {
  assertNarrow(snapshot.nativeScenario, "native-routing");
  assert(hasCategory(snapshot.nativeScenario, "native_scenario"), "native-routing should classify native_scenario");
  assert(hasCommand(snapshot.nativeScenario, "bash scripts/test-native-claspc.sh"), "native-routing should select native claspc coverage");
}

if (wants("goal-helper-routing")) {
  assertNarrow(snapshot.controlPlane, "goal-helper-routing");
  assert(hasCategory(snapshot.controlPlane, "control_plane"), "goal-helper-routing should classify control_plane");
  assert(hasCommand(snapshot.controlPlane, "bash scripts/test-goal-manager-fast.sh"), "goal-helper-routing should select GoalManager fast coverage");
}

if (wants("speed-routing")) {
  assertNarrow(snapshot.compilerSpeed, "speed-routing");
  assert(hasCategory(snapshot.compilerSpeed, "compiler_speed"), "speed-routing should classify compiler_speed");
  assert(hasCommand(snapshot.compilerSpeed, "bash scripts/test-native-incremental-guard.sh"), "speed-routing should select native incremental guard");
}

if (wants("verify-routing")) {
  assertNarrow(snapshot.verifyHarness, "verify-routing");
  assert(hasCategory(snapshot.verifyHarness, "verification_harness"), "verify-routing should classify verification_harness");
  assert(hasCommand(snapshot.verifyHarness, "bash scripts/test-verify-all.sh"), "verify-routing should select verify-all regression");
}

if (wants("unknown-routing")) {
  assert(snapshot.unknown.source === "diff-derived", "unknown-routing should be diff-derived");
  assert(hasCategory(snapshot.unknown, "unknown_path"), "unknown-routing should classify unknown_path");
  assert(hasCommand(snapshot.unknown, "bash scripts/verify-fast.sh"), "unknown-routing should select verify-fast");
  assert(snapshot.unknown.fallbackReason.includes("did not match"), "unknown-routing should explain fallback");
}

assert(hasCategory(snapshot.broad, "compiler_runtime_broad"), "broad substrate diff should be classified");
assert(hasCommand(snapshot.broad, "bash scripts/verify-fast.sh"), "broad substrate diff should select verify-fast");
assert(hasCategory(snapshot.noDiff, "no_diff"), "empty diff should classify no_diff");
assert(!hasCommand(snapshot.noDiff, "bash scripts/verify-fast.sh"), "empty diff should use lightweight feedback-loop check");
assert(snapshot.managerOverride.source === "manager-env", "manager override should be marked manager-env");
assert(hasCategory(snapshot.managerOverride, "manager_env_override"), "manager override should include manager_env_override");
assert(hasCategory(snapshot.managerOverride, "unknown_path"), "manager override should still record unknown diff category");
assert(!hasCommand(snapshot.managerOverride, "bash scripts/verify-fast.sh"), "manager override should preserve supplied commands");
assert(snapshot.readError.fallbackReason.includes("could not be read"), "read errors should fail closed to verify-fast");
assert(hasCommand(snapshot.readError, "bash scripts/verify-fast.sh"), "read errors should select verify-fast");
NODE

printf 'feedback-loop-routing: ok (%s)\n' "${requested_cases[*]}"
