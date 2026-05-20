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
test_root="$(mktemp -d "$tmp_root/verify-affected.XXXXXX")"
project_copy="$test_root/project"
mkdir -p "$project_copy/scripts" "$project_copy/src/scripts" "$project_copy/src/Compiler" \
  "$project_copy/runtime" "$project_copy/examples/swarm-native" "$project_copy/examples/feedback-loop" \
  "$project_copy/examples/agent-task-scenario/scripts" \
  "$project_copy/examples/lead-app/Shared" "$project_copy/examples/lead-app/scripts" \
  "$project_copy/examples/lead-app/benchmark-prep" \
  "$project_copy/benchmarks/tasks/clasp-lead-segment/repo/Shared" \
  "$project_copy/benchmarks/tasks/clasp-lead-segment/repo/scripts" \
  "$test_root/bin"

cp "$project_root/scripts/verify-affected.sh" "$project_copy/scripts/verify-affected.sh"
cp "$project_root/scripts/verify-affected.mjs" "$project_copy/scripts/verify-affected.mjs"
cp "$project_root/scripts/verify-compiler-slice.sh" "$project_copy/scripts/verify-compiler-slice.sh"
cp "$project_root/scripts/test-verify-compiler-slice.sh" "$project_copy/scripts/test-verify-compiler-slice.sh"
cp "$project_root/scripts/verify-runtime-slice.sh" "$project_copy/scripts/verify-runtime-slice.sh"
cp "$project_root/scripts/test-verify-runtime-slice.sh" "$project_copy/scripts/test-verify-runtime-slice.sh"
touch "$project_copy/examples/lead-app/Shared/Lead.clasp"
touch "$project_copy/examples/lead-app/scripts/verify.sh"
touch "$project_copy/examples/agent-task-scenario/Main.clasp"
touch "$project_copy/examples/agent-task-scenario/scripts/verify.sh"
touch "$project_copy/benchmarks/tasks/clasp-lead-segment/repo/Shared/Lead.clasp"
touch "$project_copy/benchmarks/tasks/clasp-lead-segment/repo/scripts/verify.sh"
cat > "$project_copy/benchmarks/tasks/clasp-lead-segment/task.json" <<'JSON'
{"id":"clasp-lead-segment","language":"clasp","repo":"repo","verify":["bash","scripts/verify.sh"]}
JSON
cat > "$project_copy/examples/lead-app/benchmark-prep/Main.context.json" <<'JSON'
{
  "format": "clasp-context-v1",
  "module": "Main",
  "sourceModules": [
    {
      "sourceId": "source:Main",
      "moduleId": "module:Main",
      "moduleName": "Main",
      "role": "entry",
      "sourceFingerprint": "0123456789abcdef"
    },
    {
      "sourceId": "source:Shared.Lead",
      "moduleId": "module:Shared.Lead",
      "moduleName": "Shared.Lead",
      "role": "import",
      "sourceFingerprint": "fedcba9876543210"
    }
  ],
  "surfaceIndex": {
    "routes": [
      {
        "id": "route:createLeadRecordRoute",
        "name": "createLeadRecordRoute",
        "requestSchemaId": "schema:LeadIntake",
        "responseSchemaId": "schema:LeadRecord",
        "handlerId": "decl:createLead",
        "affectedSurfaces": [
          "route:createLeadRecordRoute",
          "schema:LeadIntake",
          "schema:LeadRecord",
          "decl:createLead",
          "decl:summarizeLead",
          "foreign:storeLead",
          "foreign:mockLeadSummaryModel"
        ],
        "affectedForeignBoundaries": ["foreign:storeLead", "foreign:mockLeadSummaryModel"],
        "verificationGuidance": {
          "scenarioCommands": ["bash examples/lead-app/scripts/verify.sh"]
        }
      }
    ],
    "foreignBoundaries": [
      {"id": "foreign:storeLead", "name": "storeLead"},
      {"id": "foreign:mockLeadSummaryModel", "name": "mockLeadSummaryModel"}
    ]
  },
  "verificationGuidance": {
    "scenarioCommands": ["bash examples/lead-app/scripts/verify.sh"]
  }
}
JSON

cat > "$test_root/bin/bash" <<EOF
#!$bash_bin
set -euo pipefail
printf '%s\n' "\$*" >> "\${CLASP_TEST_FAKE_COMMAND_LOG:?}"
printf 'fake-bash:%s\n' "\$*"
EOF
chmod +x "$test_root/bin/bash"

run_verify_affected() {
  (
    cd "$project_copy"
    PATH="$test_root/bin:$PATH" "$bash_bin" scripts/verify-affected.sh "$@"
  )
}

assert_report() {
  local report_path="$1"
  local log_path="$2"
  local scenario="$3"

  node - "$report_path" "$log_path" "$scenario" <<'NODE'
const fs = require("node:fs");
const report = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const logPath = process.argv[3];
const scenario = process.argv[4];
const log = fs.existsSync(logPath) ? fs.readFileSync(logPath, "utf8").trim().split(/\n/).filter(Boolean) : [];

function assert(condition, message) {
  if (!condition) {
    console.error(`${scenario}: ${message}`);
    process.exit(1);
  }
}

function hasCommand(fragment) {
  return report.selectedCommands.some((command) => command.command.includes(fragment));
}

function logHas(fragment) {
  return log.some((line) => line.includes(fragment));
}

const expectedVerdict = scenario.endsWith("-plan") ? "planned" : "passed";
assert(report.schemaVersion === 1, "schema version should be stable");
assert(report.finalVerdict === expectedVerdict, `expected ${expectedVerdict}, got ${report.finalVerdict}`);
assert(report.exitStatus === 0, "exit status should be zero");
assert(Array.isArray(report.commandRecords), "command records should be present");
assert(report.executedCommandCount === report.commandRecords.length, "executed command count should match records");
for (const record of report.commandRecords) {
  assert(Number.isInteger(record.elapsedMs) && record.elapsedMs >= 0, "command elapsedMs should be structural");
  assert(record.endedAtMs >= record.startedAtMs, "command timestamps should be ordered");
}

switch (scenario) {
  case "source-no-git":
    assert(report.usedGitFallback === false, "explicit source input should not use git fallback");
    assert(report.inputSources.some((source) => source.kind === "argv"), "argv source should be recorded");
    assert(report.changedFiles.includes("src/Compiler/Checker.clasp"), "source file should be normalized");
    assert(hasCommand("bash scripts/test-selfhost.sh"), "source route should run selfhost coverage");
    assert(hasCommand("bash src/scripts/verify.sh"), "source route should run hosted source verification");
    assert(!hasCommand("benchmarks/"), "source route should avoid broad benchmark commands");
    assert(report.usedVerifyFastFallback === false, "known source input should not use verify-fast fallback");
    assert(logHas("scripts/test-selfhost.sh"), "fake selfhost command should execute");
    assert(logHas("src/scripts/verify.sh"), "fake source verify command should execute");
    break;
  case "mixed-swarm-runtime":
    assert(report.inputSources.filter((source) => source.kind === "files-from").length === 2, "repeated files-from sources should be recorded");
    assert(report.inputSources.some((source) => source.kind === "env"), "env source should be recorded");
    assert(report.changedFiles.includes("runtime/swarm.rs"), "runtime file should be present");
    assert(report.changedFiles.includes("examples/swarm-native/GoalManager.clasp"), "swarm file should be present");
    assert(report.changedFiles.includes("examples/feedback-loop/Main.clasp"), "feedback-loop file should be present");
    assert(hasCommand("bash scripts/test-native-runtime.sh"), "runtime route should run native runtime coverage");
    assert(hasCommand("bash scripts/test-native-claspc.sh"), "runtime/swarm route should run native claspc coverage");
    assert(hasCommand("bash scripts/test-swarm-ready-gate.sh"), "swarm route should run ready-gate coverage");
    assert(hasCommand("bash scripts/verify-runtime-slice.sh process"), "feedback-loop route should run process runtime slice coverage");
    assert(hasCommand("bash scripts/verify-runtime-slice.sh workflow"), "feedback-loop route should run workflow runtime slice coverage");
    assert(hasCommand("bash scripts/verify-runtime-slice.sh codex-loop"), "feedback-loop route should run ordinary Codex runtime slice coverage");
    assert(hasCommand("bash scripts/verify-runtime-slice.sh managed-loop"), "swarm route should run managed-loop runtime slice coverage");
    assert(hasCommand("bash scripts/test-feedback-loop-resume.sh"), "feedback-loop route should run resume coverage");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-native-claspc.sh").length === 1, "native claspc command should be deduplicated");
    assert(report.usedVerifyFastFallback === false, "mixed known inputs should not fall back to verify-fast");
    break;
  case "unknown-fallback":
    assert(report.verificationFallbackMode === "unknown-path", "unknown path should mark fallback mode");
    assert(report.usedVerifyFastFallback === true, "unknown path should use verify-fast fallback");
    assert(report.selectedCommands.length === 1, "unknown-only input should select only verify-fast");
    assert(hasCommand("bash scripts/verify-fast.sh"), "unknown path should run verify-fast");
    assert(logHas("scripts/verify-fast.sh"), "fake verify-fast command should execute");
    break;
  case "verification-script":
    assert(report.changedFiles.includes("scripts/verify-affected.mjs"), "affected helper should be present");
    assert(hasCommand("node --check scripts/verify-affected.mjs"), "affected helper should run node syntax check");
    assert(hasCommand("bash scripts/test-verify-affected.sh"), "affected helper should run focused regression");
    assert(report.usedVerifyFastFallback === false, "known verification script should not use verify-fast fallback");
    assert(logHas("scripts/test-verify-affected.sh"), "fake affected regression command should execute");
    break;
  case "compiler-slice-script":
    assert(report.changedFiles.includes("scripts/verify-compiler-slice.sh"), "compiler slice verifier should be present");
    assert(report.changedFiles.includes("scripts/test-verify-compiler-slice.sh"), "compiler slice smoke test should be present");
    assert(hasCommand("bash -n 'scripts/verify-compiler-slice.sh'"), "compiler slice verifier should run shell syntax check");
    assert(hasCommand("bash -n 'scripts/test-verify-compiler-slice.sh'"), "compiler slice smoke should run shell syntax check");
    assert(hasCommand("bash scripts/test-verify-compiler-slice.sh"), "compiler slice script changes should run focused smoke");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-verify-compiler-slice.sh").length === 1, "compiler slice smoke should be deduplicated");
    assert(report.usedVerifyFastFallback === false, "known compiler slice scripts should not use verify-fast fallback");
    assert(logHas("scripts/test-verify-compiler-slice.sh"), "fake compiler slice smoke command should execute");
    break;
  case "runtime-slice-script":
    assert(report.changedFiles.includes("scripts/verify-runtime-slice.sh"), "runtime slice verifier should be present");
    assert(report.changedFiles.includes("scripts/test-verify-runtime-slice.sh"), "runtime slice smoke test should be present");
    assert(hasCommand("bash -n 'scripts/verify-runtime-slice.sh'"), "runtime slice verifier should run shell syntax check");
    assert(hasCommand("bash -n 'scripts/test-verify-runtime-slice.sh'"), "runtime slice smoke should run shell syntax check");
    assert(hasCommand("bash scripts/test-verify-runtime-slice.sh"), "runtime slice script changes should run focused smoke");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-verify-runtime-slice.sh").length === 1, "runtime slice smoke should be deduplicated");
    assert(report.usedVerifyFastFallback === false, "known runtime slice scripts should not use verify-fast fallback");
    assert(logHas("scripts/test-verify-runtime-slice.sh"), "fake runtime slice smoke command should execute");
    break;
  case "compiler-slice-fixture":
    assert(report.changedFiles.includes("examples/compiler-checker.clasp"), "compiler checker fixture should be present");
    assert(report.changedFiles.includes("examples/compiler-lower.clasp"), "compiler lower fixture should be present");
    assert(hasCommand("bash scripts/verify-compiler-slice.sh checker"), "checker fixture should run focused compiler slice verifier");
    assert(hasCommand("bash scripts/verify-compiler-slice.sh lower"), "lower fixture should run focused compiler slice verifier");
    assert(report.usedVerifyFastFallback === false, "known compiler fixture should not use verify-fast fallback");
    assert(logHas("scripts/verify-compiler-slice.sh checker"), "fake compiler slice verifier command should execute");
    assert(logHas("scripts/verify-compiler-slice.sh lower"), "fake lower slice verifier command should execute");
    break;
  case "agent-task-scenario":
    assert(report.changedFiles.includes("examples/agent-task-scenario/Main.clasp"), "agent task scenario source should be present");
    assert(report.changedFiles.includes("examples/agent-task-scenario/scripts/verify.sh"), "agent task scenario verifier should be present");
    assert(hasCommand("bash examples/agent-task-scenario/scripts/verify.sh"), "agent task scenario should run its scenario verifier");
    assert(hasCommand("bash -n 'examples/agent-task-scenario/scripts/verify.sh'"), "agent task scenario verifier should run shell syntax check");
    assert(report.selectedCommands.filter((command) => command.command === "bash examples/agent-task-scenario/scripts/verify.sh").length === 1, "agent task scenario verifier should be deduplicated");
    assert(report.usedVerifyFastFallback === false, "known agent task scenario inputs should not use verify-fast fallback");
    assert(logHas("examples/agent-task-scenario/scripts/verify.sh"), "fake agent task scenario verifier command should execute");
    break;
  case "monitored-workflow-script":
    assert(report.changedFiles.includes("scripts/test-monitored-workflow.sh"), "monitored workflow harness should be present");
    assert(hasCommand("bash -n 'scripts/test-monitored-workflow.sh'"), "monitored workflow harness should run shell syntax check");
    assert(hasCommand("bash scripts/verify-runtime-slice.sh workflow"), "monitored workflow harness should run focused runtime slice coverage");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/verify-runtime-slice.sh workflow").length === 1, "monitored workflow runtime slice should be deduplicated");
    assert(report.usedVerifyFastFallback === false, "known monitored workflow harness should not use verify-fast fallback");
    assert(logHas("scripts/verify-runtime-slice.sh workflow"), "fake monitored workflow slice command should execute");
    break;
  case "codex-loop-program-script":
    assert(report.changedFiles.includes("scripts/test-codex-loop-program.sh"), "ordinary Codex loop harness should be present");
    assert(hasCommand("bash -n 'scripts/test-codex-loop-program.sh'"), "ordinary Codex loop harness should run shell syntax check");
    assert(hasCommand("bash scripts/verify-runtime-slice.sh codex-loop"), "ordinary Codex loop harness should run focused runtime slice coverage");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/verify-runtime-slice.sh codex-loop").length === 1, "ordinary Codex runtime slice should be deduplicated");
    assert(report.usedVerifyFastFallback === false, "known ordinary Codex loop harness should not use verify-fast fallback");
    assert(logHas("scripts/verify-runtime-slice.sh codex-loop"), "fake ordinary Codex loop slice command should execute");
    break;
  case "host-runtime":
    assert(report.changedFiles.includes("examples/host-runtime/Main.clasp"), "host runtime source should be present");
    assert(report.changedFiles.includes("examples/host-runtime/Host.clasp"), "host runtime wrapper should be present");
    assert(report.changedFiles.includes("scripts/test-host-runtime.sh"), "host runtime harness should be present");
    assert(report.changedFiles.includes("docs/clasp-spec-v0.md"), "host runtime spec doc should be present");
    assert(report.changedFiles.includes("docs/autonomous-swarm-build-plan.md"), "host runtime build-plan doc should be present");
    assert(!report.changedFiles.includes(".workspace-ready"), "workspace sentinel should be ignored");
    assert(hasCommand("bash -n 'scripts/test-host-runtime.sh'"), "host runtime harness should run shell syntax check");
    assert(hasCommand("bash scripts/test-host-runtime.sh"), "host runtime route should run focused host API coverage");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-host-runtime.sh").length === 1, "host runtime command should be deduplicated");
    assert(report.usedVerifyFastFallback === false, "known host runtime inputs should not use verify-fast fallback");
    assert(logHas("scripts/test-host-runtime.sh"), "fake host runtime command should execute");
    break;
  case "source-benchmark-mixed":
    assert(report.changedFiles.includes("src/Compiler/SemanticArtifacts.clasp"), "source context artifact file should be present");
    assert(report.changedFiles.includes("benchmarks/tasks/clasp-lead-segment/repo/Shared/Lead.clasp"), "benchmark app source should be present");
    assert(hasCommand("bash scripts/test-selfhost.sh"), "mixed source+benchmark should keep selfhost/source coverage");
    assert(hasCommand("bash src/scripts/verify.sh"), "mixed source+benchmark should keep hosted source verification");
    assert(hasCommand("bash benchmarks/test-task-prep.sh"), "mixed source+benchmark should run benchmark prep coverage");
    assert(hasCommand("benchmarks/tasks/clasp-lead-segment/repo/scripts/verify.sh"), "mixed source+benchmark should run task app-flow verification");
    assert(report.selectedCommands.filter((command) => command.command === "bash benchmarks/test-task-prep.sh").length === 1, "benchmark prep command should be deduplicated");
    assert(report.usedVerifyFastFallback === false, "known source+benchmark inputs should not use verify-fast fallback");
    break;
  case "app-context-plan":
    assert(report.planOnly === true, "context scenario should be plan-only");
    assert(report.finalVerdict === "planned", `expected planned verdict, got ${report.finalVerdict}`);
    assert(report.executedCommandCount === 0, "plan-only should not execute commands");
    assert(report.changedFiles.includes("examples/lead-app/Shared/Lead.clasp"), "app source should be normalized");
    assert(hasCommand("bash examples/lead-app/scripts/verify.sh"), "context-aware app route should include app-flow verifier");
    assert(!hasCommand("bash scripts/test-selfhost.sh"), "app-only route should avoid source/compiler selfhost coverage");
    assert(report.semanticContextArtifacts.some((artifact) => artifact.path === "examples/lead-app/benchmark-prep/Main.context.json" && artifact.status === "ok"), "context artifact should be recorded");
    assert(report.semanticContextByChangedFile.some((entry) => entry.file === "examples/lead-app/Shared/Lead.clasp" && entry.artifactPaths.includes("examples/lead-app/benchmark-prep/Main.context.json")), "changed file should be linked to context artifact");
    assert(report.planExplanations.length > 0, "plan-only report should include semantic explanations");
    {
      const explanation = JSON.stringify(report.planExplanations);
      assert(explanation.includes("route:createLeadRecordRoute"), "plan explanation should name affected route surface");
      assert(explanation.includes("schema:LeadIntake"), "plan explanation should name request schema surface");
      assert(explanation.includes("decl:summarizeLead"), "plan explanation should name affected declaration surface");
      assert(explanation.includes("foreign:mockLeadSummaryModel"), "plan explanation should name foreign boundary surface");
    }
    break;
  case "goal-manager-fast-script":
    assert(report.changedFiles.includes("scripts/test-goal-manager-fast.sh"), "GoalManager harness should be present");
    assert(report.changedFiles.includes("scripts/test-swarm-ready-gate.sh"), "swarm-ready harness should be present");
    assert(hasCommand("bash -n 'scripts/test-goal-manager-fast.sh'"), "GoalManager harness should run shell syntax check");
    assert(hasCommand("bash scripts/test-goal-manager-fast.sh"), "GoalManager harness should run focused coverage");
    assert(hasCommand("bash -n 'scripts/test-swarm-ready-gate.sh'"), "swarm-ready harness should run shell syntax check");
    assert(hasCommand("bash scripts/test-swarm-ready-gate.sh"), "swarm-ready harness should run focused coverage");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-swarm-ready-gate.sh").length === 1, "swarm-ready command should be deduplicated");
    assert(report.usedVerifyFastFallback === false, "known focused harnesses should not use verify-fast fallback");
    assert(logHas("scripts/test-goal-manager-fast.sh"), "fake GoalManager fast command should execute");
    assert(logHas("scripts/test-swarm-ready-gate.sh"), "fake swarm-ready command should execute");
    break;
  case "planner-report-decode":
    assert(report.changedFiles.includes("examples/swarm-native/GoalManagerReportIO.clasp"), "planner report IO source should be present");
    assert(report.changedFiles.includes("scripts/test-goal-manager-planner-report-decode.sh"), "planner report decode harness should be present");
    assert(hasCommand("bash scripts/test-goal-manager-planner-report-decode.sh"), "planner report decode route should run focused coverage");
    assert(hasCommand("bash -n 'scripts/test-goal-manager-planner-report-decode.sh'"), "planner report decode harness should run shell syntax check");
    assert(hasCommand("bash scripts/test-native-claspc.sh"), "swarm-native source should retain native claspc coverage");
    assert(hasCommand("bash scripts/test-swarm-ready-gate.sh"), "swarm-native source should retain ready-gate coverage");
    assert(report.selectedCommands.filter((command) => command.command === "bash scripts/test-goal-manager-planner-report-decode.sh").length === 1, "planner report decode command should be deduplicated");
    assert(report.usedVerifyFastFallback === false, "known planner report decode paths should not use verify-fast fallback");
    assert(logHas("scripts/test-goal-manager-planner-report-decode.sh"), "fake planner report decode command should execute");
    break;
  case "empty-no-git":
    assert(report.usedGitFallback === true, "empty explicit input should try git fallback");
    assert(report.inputFallbackMode === "git-unavailable" || report.inputFallbackMode === "git-empty", `unexpected input fallback mode: ${report.inputFallbackMode}`);
    assert(report.verificationFallbackMode === "git-unavailable-empty-input" || report.verificationFallbackMode === "empty-input", `unexpected verification fallback mode: ${report.verificationFallbackMode}`);
    assert(report.changedFiles.length === 0, "empty no-git scenario should have no changed files");
    assert(hasCommand("bash scripts/verify-fast.sh"), "empty input should run verify-fast");
    break;
  case "empty-git":
    assert(report.usedGitFallback === true, "empty explicit input should try git fallback");
    assert(report.inputFallbackMode === "git-empty", `expected git-empty, got ${report.inputFallbackMode}`);
    assert(report.verificationFallbackMode === "empty-input", `expected empty-input, got ${report.verificationFallbackMode}`);
    assert(report.changedFiles.length === 0, "empty git scenario should have no changed files");
    assert(hasCommand("bash scripts/verify-fast.sh"), "empty git input should run verify-fast");
    break;
  default:
    assert(false, `unknown scenario ${scenario}`);
}
NODE
}

source_report="$test_root/source-report.json"
source_log="$test_root/source.log"
CLASP_TEST_FAKE_COMMAND_LOG="$source_log" \
  run_verify_affected --changed-file ./src/Compiler/Checker.clasp --changed-file src/Main.clasp > "$source_report"
assert_report "$source_report" "$source_log" source-no-git

mixed_report="$test_root/mixed-report.json"
mixed_log="$test_root/mixed.log"
mixed_files_one="$test_root/mixed-one.txt"
mixed_files_two="$test_root/mixed-two.txt"
printf 'runtime/swarm.rs\n' > "$mixed_files_one"
printf 'examples/feedback-loop/Main.clasp\n' > "$mixed_files_two"
CLASP_TEST_FAKE_COMMAND_LOG="$mixed_log" \
  CLASP_VERIFY_CHANGED_FILES='examples/swarm-native/GoalManager.clasp,runtime/claspc.rs' \
  run_verify_affected --files-from "$mixed_files_one" --files-from "$mixed_files_two" > "$mixed_report"
assert_report "$mixed_report" "$mixed_log" mixed-swarm-runtime

unknown_report="$test_root/unknown-report.json"
unknown_log="$test_root/unknown.log"
CLASP_TEST_FAKE_COMMAND_LOG="$unknown_log" \
  run_verify_affected --changed-file docs/notes.md > "$unknown_report"
assert_report "$unknown_report" "$unknown_log" unknown-fallback

script_report="$test_root/script-report.json"
script_log="$test_root/script.log"
CLASP_TEST_FAKE_COMMAND_LOG="$script_log" \
  run_verify_affected --changed-file scripts/verify-affected.mjs > "$script_report"
assert_report "$script_report" "$script_log" verification-script

compiler_slice_script_report="$test_root/compiler-slice-script-report.json"
compiler_slice_script_log="$test_root/compiler-slice-script.log"
CLASP_TEST_FAKE_COMMAND_LOG="$compiler_slice_script_log" \
  run_verify_affected \
    --changed-file scripts/verify-compiler-slice.sh \
    --changed-file scripts/test-verify-compiler-slice.sh > "$compiler_slice_script_report"
assert_report "$compiler_slice_script_report" "$compiler_slice_script_log" compiler-slice-script

compiler_slice_fixture_report="$test_root/compiler-slice-fixture-report.json"
compiler_slice_fixture_log="$test_root/compiler-slice-fixture.log"
CLASP_TEST_FAKE_COMMAND_LOG="$compiler_slice_fixture_log" \
  run_verify_affected \
    --changed-file examples/compiler-checker.clasp \
    --changed-file examples/compiler-lower.clasp > "$compiler_slice_fixture_report"
assert_report "$compiler_slice_fixture_report" "$compiler_slice_fixture_log" compiler-slice-fixture

runtime_slice_script_report="$test_root/runtime-slice-script-report.json"
runtime_slice_script_log="$test_root/runtime-slice-script.log"
CLASP_TEST_FAKE_COMMAND_LOG="$runtime_slice_script_log" \
  run_verify_affected \
    --changed-file scripts/verify-runtime-slice.sh \
    --changed-file scripts/test-verify-runtime-slice.sh > "$runtime_slice_script_report"
assert_report "$runtime_slice_script_report" "$runtime_slice_script_log" runtime-slice-script

agent_task_scenario_report="$test_root/agent-task-scenario-report.json"
agent_task_scenario_log="$test_root/agent-task-scenario.log"
CLASP_TEST_FAKE_COMMAND_LOG="$agent_task_scenario_log" \
  run_verify_affected \
    --changed-file examples/agent-task-scenario/Main.clasp \
    --changed-file examples/agent-task-scenario/scripts/verify.sh > "$agent_task_scenario_report"
assert_report "$agent_task_scenario_report" "$agent_task_scenario_log" agent-task-scenario

monitored_workflow_script_report="$test_root/monitored-workflow-script-report.json"
monitored_workflow_script_log="$test_root/monitored-workflow-script.log"
CLASP_TEST_FAKE_COMMAND_LOG="$monitored_workflow_script_log" \
  run_verify_affected --changed-file scripts/test-monitored-workflow.sh > "$monitored_workflow_script_report"
assert_report "$monitored_workflow_script_report" "$monitored_workflow_script_log" monitored-workflow-script

codex_loop_program_script_report="$test_root/codex-loop-program-script-report.json"
codex_loop_program_script_log="$test_root/codex-loop-program-script.log"
CLASP_TEST_FAKE_COMMAND_LOG="$codex_loop_program_script_log" \
  run_verify_affected --changed-file scripts/test-codex-loop-program.sh > "$codex_loop_program_script_report"
assert_report "$codex_loop_program_script_report" "$codex_loop_program_script_log" codex-loop-program-script

host_runtime_report="$test_root/host-runtime-report.json"
host_runtime_log="$test_root/host-runtime.log"
CLASP_TEST_FAKE_COMMAND_LOG="$host_runtime_log" \
  run_verify_affected \
    --changed-file examples/host-runtime/Main.clasp \
    --changed-file examples/host-runtime/Host.clasp \
    --changed-file scripts/test-host-runtime.sh \
    --changed-file docs/clasp-spec-v0.md \
    --changed-file docs/autonomous-swarm-build-plan.md \
    --changed-file .workspace-ready > "$host_runtime_report"
assert_report "$host_runtime_report" "$host_runtime_log" host-runtime

source_benchmark_report="$test_root/source-benchmark-report.json"
source_benchmark_log="$test_root/source-benchmark.log"
CLASP_TEST_FAKE_COMMAND_LOG="$source_benchmark_log" \
  run_verify_affected \
    --changed-file src/Compiler/SemanticArtifacts.clasp \
    --changed-file benchmarks/tasks/clasp-lead-segment/repo/Shared/Lead.clasp > "$source_benchmark_report"
assert_report "$source_benchmark_report" "$source_benchmark_log" source-benchmark-mixed

app_context_report="$test_root/app-context-report.json"
app_context_log="$test_root/app-context.log"
CLASP_TEST_FAKE_COMMAND_LOG="$app_context_log" \
  run_verify_affected --plan-only --changed-file examples/lead-app/Shared/Lead.clasp > "$app_context_report"
assert_report "$app_context_report" "$app_context_log" app-context-plan

goal_manager_report="$test_root/goal-manager-report.json"
goal_manager_log="$test_root/goal-manager.log"
CLASP_TEST_FAKE_COMMAND_LOG="$goal_manager_log" \
  run_verify_affected --changed-file scripts/test-goal-manager-fast.sh --changed-file scripts/test-swarm-ready-gate.sh > "$goal_manager_report"
assert_report "$goal_manager_report" "$goal_manager_log" goal-manager-fast-script

planner_report_decode_report="$test_root/planner-report-decode-report.json"
planner_report_decode_log="$test_root/planner-report-decode.log"
CLASP_TEST_FAKE_COMMAND_LOG="$planner_report_decode_log" \
  run_verify_affected \
    --changed-file examples/swarm-native/GoalManagerReportIO.clasp \
    --changed-file scripts/test-goal-manager-planner-report-decode.sh > "$planner_report_decode_report"
assert_report "$planner_report_decode_report" "$planner_report_decode_log" planner-report-decode

empty_report="$test_root/empty-report.json"
empty_log="$test_root/empty.log"
CLASP_TEST_FAKE_COMMAND_LOG="$empty_log" \
  run_verify_affected > "$empty_report"
assert_report "$empty_report" "$empty_log" empty-no-git

git -C "$project_copy" init -q >/dev/null
git -C "$project_copy" config user.email "verify-affected@example.test"
git -C "$project_copy" config user.name "verify affected"
git -C "$project_copy" add .
git -C "$project_copy" commit -m "fixture" >/dev/null

empty_git_report="$test_root/empty-git-report.json"
empty_git_log="$test_root/empty-git.log"
CLASP_TEST_FAKE_COMMAND_LOG="$empty_git_log" \
  run_verify_affected > "$empty_git_report"
assert_report "$empty_git_report" "$empty_git_log" empty-git
