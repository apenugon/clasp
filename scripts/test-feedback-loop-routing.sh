#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
timeout_secs="${CLASP_FEEDBACK_LOOP_ROUTING_TIMEOUT_SECS:-90}"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
test_root=""

usage() {
  cat <<'EOF'
usage: scripts/test-feedback-loop-routing.sh [case-or-group ...]

Runs the lightweight focused verifier routing probe. This covers the
diff-derived selector without launching the full feedback-loop manager. Set
CLASP_TEST_FEEDBACK_LOOP_ROUTING_CLASP_PROBE=1 to run the ordinary-Clasp probe
instead of the default fast fixture.

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

snapshot_path="$test_root/focused-selection.json"

grep -F 'CLASP_LOOP_AFFECTED_VERIFICATION_PLAN_JSON' "$project_root/examples/feedback-loop/Main.clasp" >/dev/null
grep -F 'CLASP_LOOP_AFFECTED_VERIFICATION_PLAN_PATH_JSON' "$project_root/examples/feedback-loop/Main.clasp" >/dev/null
grep -F 'CLASP_LOOP_AFFECTED_VERIFICATION_LAUNCH_POLICY_JSON' "$project_root/examples/feedback-loop/Main.clasp" >/dev/null
grep -F 'CLASP_LOOP_AFFECTED_VERIFICATION_LAUNCH_POLICY_PATH_JSON' "$project_root/examples/feedback-loop/Main.clasp" >/dev/null
grep -F 'Affected verification launch policy JSON:' "$project_root/examples/feedback-loop/Main.clasp" >/dev/null
grep -F 'affectedVerificationVerifierPromptSection' "$project_root/examples/feedback-loop/Main.clasp" >/dev/null
grep -F 'affectedVerificationVerifierPromptSection' "$project_root/examples/swarm-native/FeedbackLoop.clasp" >/dev/null
grep -F 'plannerAffectedVerificationContextSection' "$project_root/examples/swarm-native/GoalManagerBootstrapPlanner.clasp" >/dev/null
grep -F 'CLASP_LOOP_AFFECTED_VERIFICATION_LAUNCH_POLICY_PATH_JSON' "$project_root/examples/swarm-native/GoalManagerBootstrapTasks.clasp" >/dev/null
grep -F 'CLASP_LOOP_AFFECTED_VERIFICATION_LAUNCH_POLICY_JSON' "$project_root/examples/swarm-native/GoalManagerBootstrapTasks.clasp" >/dev/null
grep -F 'CLASP_LOOP_AFFECTED_VERIFICATION_LAUNCH_POLICY_JSON' "$project_root/examples/swarm-native/GoalManagerServiceMain.clasp" >/dev/null

if [[ "${CLASP_TEST_FEEDBACK_LOOP_ROUTING_CLASP_PROBE:-0}" == "1" ]]; then
  parse_positive_timeout
  claspc_bin="$("$project_root/scripts/resolve-claspc.sh")"
  (
    cd "$project_root"
    timeout "$timeout_secs" "$claspc_bin" run examples/feedback-loop/FocusedSelectionProbe.clasp
  ) > "$snapshot_path"
else
  node - "$snapshot_path" <<'NODE'
const fs = require("node:fs");
const snapshotPath = process.argv[2];

const verifyFastCommands = ["bash scripts/verify-fast.sh"];
const noDiffCommands = ["$(scripts/resolve-claspc.sh) --json check examples/feedback-loop/Main.clasp"];
const feedbackLoopCommands = [
  "$(scripts/resolve-claspc.sh) --json check examples/feedback-loop/Main.clasp",
  "$(scripts/resolve-claspc.sh) --json check examples/feedback-loop/ProcessDemo.clasp",
  "bash scripts/test-feedback-loop-routing.sh loop-routing",
  "bash scripts/test-swarm-ready-gate.sh"
];
const nativeScenarioCommands = [
  "$(scripts/resolve-claspc.sh) --json check examples/swarm-native/Main.clasp",
  "bash scripts/test-native-claspc.sh",
  "bash scripts/test-swarm-ready-gate.sh"
];
const controlPlaneCommands = [
  "$(scripts/resolve-claspc.sh) --json check examples/swarm-native/GoalManager.wrapper.clasp",
  "bash scripts/test-goal-manager-fast.sh",
  "bash scripts/test-swarm-ready-gate.sh"
];
const compilerSpeedCommands = [
  "bash -n scripts/measure-native-incremental.sh scripts/test-native-incremental-guard.sh scripts/test-selfhost.sh",
  "node --check scripts/native-incremental-guard.mjs",
  "bash scripts/test-native-incremental-guard.sh"
];
const verifyHarnessCommands = [
  "bash scripts/test-verify-all.sh",
  "bash scripts/test-swarm-ready-gate.sh"
];

function diffForPath(path) {
  return [`--- a/${path}`, `+++ b/${path}`, "@@ -1 +1 @@", "-old", "+new"].join("\n");
}

function diffForPaths(paths) {
  return paths.map(diffForPath).join("\n");
}

function emptyState() {
  return { changed: false, broad: false, unknown: false, loop: false, nativeScenario: false, compilerSpeed: false, controlPlane: false, verifyHarness: false };
}

function classifyPath(pathText, state) {
  if (!pathText || pathText.includes("/dev/null") || pathText.includes("/runtime/target/")) return state;
  state.changed = true;
  if (pathText.includes("/scripts/verify-fast.sh") ||
      pathText.includes("/scripts/verify-all.sh") ||
      pathText.includes("/scripts/verify-affected.mjs") ||
      pathText.includes("/scripts/test-verify-affected.sh") ||
      pathText.includes("/scripts/test-selfhost-verify-mode-split.sh") ||
      pathText.includes("/src/scripts/verify.sh") ||
      pathText.includes("/scripts/test-verify-all.sh")) {
    state.verifyHarness = true;
  } else if ((pathText.includes("/src/") && !pathText.includes("/src/scripts/verify.sh")) ||
      pathText.includes("/runtime/")) {
    state.broad = true;
  } else if (pathText.includes("/examples/feedback-loop/") ||
      pathText.includes("/scripts/test-feedback-loop-resume.sh") ||
      pathText.includes("/scripts/test-feedback-loop-routing.sh") ||
      pathText.includes("/scripts/test-swarm-ready-gate.sh")) {
    state.loop = true;
  } else if (pathText.includes("/examples/swarm-native/Swarm.clasp") ||
      pathText.includes("/examples/swarm-native/Main.clasp") ||
      pathText.includes("/scripts/test-native-claspc.sh")) {
    state.nativeScenario = true;
  } else if (pathText.includes("/scripts/measure-native-incremental.sh") ||
      pathText.includes("/scripts/native-incremental-guard.mjs") ||
      pathText.includes("/scripts/test-native-incremental-guard.sh") ||
      pathText.includes("/scripts/test-selfhost.sh")) {
    state.compilerSpeed = true;
  } else if (pathText.includes("/examples/swarm-native/GoalManager") ||
      pathText.includes("/scripts/ensure-goal-manager-binary.sh") ||
      pathText.includes("/examples/swarm-native/Service.clasp") ||
      pathText.includes("/examples/swarm-native/FeedbackLoop.clasp") ||
      pathText.includes("/scripts/test-goal-manager-fast.sh")) {
    state.controlPlane = true;
  } else {
    state.unknown = true;
  }
  return state;
}

function classifyDiff(raw) {
  const state = emptyState();
  for (const line of raw.split(/\n/)) {
    if (line.startsWith("+++ ") || line.startsWith("--- ")) {
      classifyPath(line.slice(4), state);
    }
  }
  return state;
}

function categories(state) {
  const values = [];
  if (state.broad) values.push("compiler_runtime_broad");
  if (state.loop) values.push("feedback_loop");
  if (state.nativeScenario) values.push("native_scenario");
  if (state.compilerSpeed) values.push("compiler_speed");
  if (state.controlPlane) values.push("control_plane");
  if (state.verifyHarness) values.push("verification_harness");
  if (state.unknown) values.push("unknown_path");
  if (!state.changed) values.push("no_diff");
  return values.length ? values : ["unknown_path"];
}

function commandsForState(state) {
  if (!state.changed) return noDiffCommands;
  if (state.broad || state.unknown) return verifyFastCommands;
  const commands = [];
  if (state.loop) commands.push(...feedbackLoopCommands);
  if (state.nativeScenario) commands.push(...nativeScenarioCommands);
  if (state.compilerSpeed) commands.push(...compilerSpeedCommands);
  if (state.controlPlane) commands.push(...controlPlaneCommands);
  if (state.verifyHarness) commands.push(...verifyHarnessCommands);
  return commands.length ? commands : noDiffCommands;
}

function reasonForState(state) {
  if (!state.changed) return "baseline diff was empty; selected a lightweight feedback-loop check";
  if (state.broad) return "diff touched compiler/runtime substrate; selected conservative verify-fast";
  if (state.unknown) return "diff included unknown paths; selected conservative verify-fast";
  return "diff touched only known feedback-loop/native-scenario/compiler-speed/control-plane/verification harness paths; selected narrow focused checks";
}

function fallbackForState(state) {
  if (state.broad) return "compiler/runtime changes can invalidate the compiler, native runtime, cache, or promoted self-hosting gates; focused selection falls back to verify-fast";
  if (state.unknown) return "one or more changed paths did not match a known narrow surface; focused selection falls back to verify-fast";
  return "";
}

function buildFromDiffText(diffPath, raw) {
  const state = classifyDiff(raw);
  return {
    source: "diff-derived",
    diffPath,
    changedSurfaceCategories: categories(state),
    commands: commandsForState(state),
    reason: reasonForState(state),
    fallbackReason: fallbackForState(state),
    cacheEvidence: ["native-cache-report:none-found"],
    checkEvidence: [`baseline-diff:${diffPath}`, `diff-changed:${state.changed}`, `diff-broad:${state.broad}`, `diff-unknown:${state.unknown}`, ...categories(state)]
  };
}

function buildFromManager(diffPath, commands, raw) {
  const state = classifyDiff(raw);
  return {
    source: "manager-env",
    diffPath,
    changedSurfaceCategories: ["manager_env_override", ...categories(state)],
    commands,
    reason: "CLASP_LOOP_FOCUSED_VERIFY_COMMANDS_JSON supplied non-empty focused commands",
    fallbackReason: state.broad ? "manager supplied focused commands, so the compiler/runtime diff fallback was recorded but not applied" : state.unknown ? "manager supplied focused commands, so the unknown-path diff fallback was recorded but not applied" : "",
    cacheEvidence: ["native-cache-report:none-found"],
    checkEvidence: [`baseline-diff:${diffPath}`, `diff-changed:${state.changed}`, `diff-broad:${state.broad}`, `diff-unknown:${state.unknown}`, ...categories(state)]
  };
}

const diffPath = "changes-1.diff";
const snapshot = {
  loop: buildFromDiffText(diffPath, diffForPath("examples/feedback-loop/Main.clasp")),
  generatedLoop: buildFromDiffText(diffPath, diffForPaths(["examples/feedback-loop/Main.clasp", "runtime/target/debug/generated.txt"])),
  nativeScenario: buildFromDiffText(diffPath, diffForPath("examples/swarm-native/Swarm.clasp")),
  controlPlane: buildFromDiffText(diffPath, diffForPath("scripts/ensure-goal-manager-binary.sh")),
  compilerSpeed: buildFromDiffText(diffPath, diffForPath("scripts/measure-native-incremental.sh")),
  verifyHarness: buildFromDiffText(diffPath, diffForPath("src/scripts/verify.sh")),
  broad: buildFromDiffText(diffPath, diffForPath("runtime/claspc.rs")),
  unknown: buildFromDiffText(diffPath, diffForPath("README.md")),
  noDiff: buildFromDiffText(diffPath, ""),
  managerOverride: buildFromManager(diffPath, ["bash scripts/test-swarm-ready-gate.sh"], diffForPath("README.md")),
  readError: {
    source: "diff-derived",
    diffPath,
    changedSurfaceCategories: ["unknown_path"],
    commands: verifyFastCommands,
    reason: "diff artifact could not be read; selected conservative verify-fast: fixture missing",
    fallbackReason: "diff artifact could not be read; focused selection falls back to verify-fast",
    cacheEvidence: ["native-cache-report:none-found"],
    checkEvidence: [`baseline-diff:${diffPath}`, "diff-read-error:fixture missing", "unknown_path"]
  }
};

fs.writeFileSync(snapshotPath, JSON.stringify(snapshot));
NODE
fi

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
