#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
timeout_secs="${CLASP_GENERATED_STATE_CLEANUP_PLAN_TIMEOUT_SECS:-420}"
active_pid=""

if ! [[ "$timeout_secs" =~ ^[0-9]+$ ]] || (( timeout_secs < 1 )); then
  printf 'CLASP_GENERATED_STATE_CLEANUP_PLAN_TIMEOUT_SECS must be a positive integer\n' >&2
  exit 1
fi

mkdir -p "$tmp_root"
test_root="$(mktemp -d "$tmp_root/test-generated-state-cleanup-plan.XXXXXX")"
test_xdg_cache_home="${CLASP_TEST_SHARED_XDG_CACHE_HOME:-$test_root/xdg-cache}"
export XDG_CACHE_HOME="$test_xdg_cache_home"
mkdir -p "$XDG_CACHE_HOME"

cleanup() {
  if [[ -n "${active_pid:-}" ]]; then
    kill "$active_pid" >/dev/null 2>&1 || true
    wait "$active_pid" >/dev/null 2>&1 || true
  fi
  if [[ "${CLASP_TEST_KEEP_TMP:-}" == "1" ]]; then
    printf 'kept test root: %s\n' "$test_root" >&2
  else
    rm -rf "$test_root" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

test_export_host_pids() {
  ps -eo pid=,comm=,args= |
    awk -v cache="$test_xdg_cache_home" '
      $2 == "claspc" && index($0, "__serve-native-export-host") && index($0, cache) { print $1 }
    '
}

claspc_bin="$(
  CLASP_CLASPC= CLASPC_BIN= CLASP_PROJECT_ROOT="$project_root" \
    "$project_root/scripts/resolve-claspc.sh"
)"
program_path="$project_root/examples/swarm-native/GeneratedStateCleanupPlan.clasp"

node - "$program_path" <<'NODE'
const fs = require("node:fs");

const [programPath] = process.argv.slice(2);
const source = fs.readFileSync(programPath, "utf8");

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

assert(source.includes('readEnvJsonText : Str -> Str -> Str'), "cleanup plan should decode manager JSON text fallbacks");
assert(source.includes('readEnvJsonInt : Str -> Int -> Int'), "cleanup plan should decode manager JSON int fallbacks");
assert(source.includes('workspacePathSizeMbRaw : Str -> Str -> Result Int = "workspacePathSizeMb"'), "cleanup plan should use root-confined workspace size measurement");
assert(source.includes('foreign hostFileSizeMbRaw : Str -> Result Int = "hostFileSizeMb"'), "cleanup plan should use read-only host file size measurement for external logs");
assert(source.includes('foreign hostCapFileTailMbRaw : Str -> Int -> Result Int = "hostCapFileTailMb"'), "cleanup plan should cap configured external logs in apply mode");
assert(source.includes('record GeneratedCleanupProjection ='), "cleanup plan should expose cleanup sufficiency projection");
assert(source.includes('record GeneratedExternalLog ='), "cleanup plan should expose external log evidence");
assert(source.includes('record GeneratedExternalLogCap ='), "cleanup plan should expose external log cap results");
assert(source.includes('record GeneratedStateCleanupTestMatrix ='), "cleanup plan should expose a one-shot runtime test matrix");
assert(source.includes('generatedCleanupProjectionFor : Str -> Bool -> [GeneratedCleanupTarget] -> [GeneratedExternalLog] -> GeneratedCleanupDisk -> GeneratedCleanupProjection'), "cleanup plan should compute projected disk sufficiency");
assert(source.includes('CLASP_GENERATED_STATE_TEST_MATRIX_JSON'), "cleanup plan should support a one-shot runtime test matrix");
assert(source.includes('CLASP_GENERATED_STATE_CODEX_LOG_MAX_MB'), "cleanup plan should expose codex log cap sizing");
assert(
  /readEnvText\s+"CLASP_GENERATED_STATE_DISK_RESERVE_PATH"\s+\(readEnvJsonText "CLASP_MANAGER_DISK_RESERVE_PATH_JSON" generatedCleanupProjectRoot\)/.test(source),
  "cleanup plan should inherit manager disk reserve path defaults"
);
assert(
  /readEnvInt\s+"CLASP_GENERATED_STATE_MIN_AVAILABLE_DISK_MB"\s+\(readEnvJsonInt\s+"CLASP_MANAGER_MIN_AVAILABLE_DISK_MB_JSON"/.test(source),
  "cleanup plan should inherit manager minimum disk reserve defaults"
);
assert(
  /readEnvInt\s+"CLASP_GENERATED_STATE_MIN_HEADROOM_MB"\s+\(readEnvJsonInt "CLASP_MANAGER_MIN_DISK_HEADROOM_MB_JSON" 1024\)/.test(source),
  "cleanup plan should inherit manager minimum disk headroom defaults"
);
NODE

test_project="$test_root/project"
mkdir -p \
  "$test_project/.clasp-swarm/full/01-lane/runs/run-1" \
  "$test_project/.clasp-swarm/full/01-lane/jobs/job-stale" \
  "$test_project/.clasp-verify/jobs/job-terminal" \
  "$test_project/.clasp-generated-state" \
  "$test_project/generated/manual-cache"

printf 'run artifact\n' >"$test_project/.clasp-swarm/full/01-lane/runs/run-1/artifact.txt"
printf 'started\n' >"$test_project/.clasp-swarm/full/01-lane/jobs/job-stale/status"
printf '999999\n' >"$test_project/.clasp-swarm/full/01-lane/jobs/job-stale/pid"
printf 'completed\n' >"$test_project/.clasp-verify/jobs/job-terminal/status"
printf '0\n' >"$test_project/.clasp-verify/jobs/job-terminal/pid"
printf 'manual cache\n' >"$test_project/generated/manual-cache/artifact.txt"
cat >"$test_project/.clasp-generated-state/cleanup-targets.json" <<'JSON'
[
  {"relativePath":"generated/manual-cache","reason":"manual configured output"},
  {"relativePath":"missing-cache","reason":"missing configured output"},
  {"relativePath":".","reason":"forbidden root"}
]
JSON

active_project="$test_root/active-project"
mkdir -p "$active_project/.clasp-swarm/full/02-active/jobs/job-active"
sleep "$((timeout_secs + 60))" &
active_pid="$!"
printf 'started\n' >"$active_project/.clasp-swarm/full/02-active/jobs/job-active/status"
printf '%s\n' "$active_pid" >"$active_project/.clasp-swarm/full/02-active/jobs/job-active/pid"
printf 'active artifact\n' >"$active_project/.clasp-swarm/full/02-active/jobs/job-active/stdout.log"

codex_home="$test_root/codex-home"
mkdir -p "$codex_home/log"
dd if=/dev/zero of="$codex_home/log/codex-tui.log" bs=1M count=2 status=none

matrix_output="$test_root/matrix.json"
CLASP_GENERATED_STATE_MIN_AVAILABLE_DISK_MB=1 \
CLASP_GENERATED_STATE_MIN_HEADROOM_MB=1 \
CLASP_GENERATED_STATE_CODEX_LOG_MAX_MB=1 \
CODEX_HOME="$codex_home" \
CLASP_GENERATED_STATE_TEST_MATRIX_JSON=true \
CLASP_GENERATED_STATE_ACTIVE_PROJECT_ROOT="$active_project" \
CLASP_NATIVE_JOBS_MAX="${CLASP_NATIVE_JOBS_MAX:-2}" \
CLASP_NATIVE_BUNDLE_JOBS="${CLASP_NATIVE_BUNDLE_JOBS:-2}" \
CLASP_NATIVE_IMAGE_SECTION_JOBS="${CLASP_NATIVE_IMAGE_SECTION_JOBS:-1}" \
CLASP_NATIVE_IMAGE_SECTION_JOBS_MAX="${CLASP_NATIVE_IMAGE_SECTION_JOBS_MAX:-2}" \
CLASP_NATIVE_IMAGE_MODULE_DECL_CHUNK_SIZE="${CLASP_NATIVE_IMAGE_MODULE_DECL_CHUNK_SIZE:-8}" \
CLASP_NATIVE_EXPORT_HOST_IDLE_TIMEOUT_SECS="${CLASP_NATIVE_EXPORT_HOST_IDLE_TIMEOUT_SECS:-1}" \
  timeout "$timeout_secs" "$claspc_bin" run "$program_path" -- "$test_project" >"$matrix_output"

node - "$matrix_output" "$test_project" "$active_project" "$active_pid" "$codex_home/log/codex-tui.log" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");

const [outputPath, testProject, activeProject, activePid, codexLogPath] = process.argv.slice(2);
const matrix = JSON.parse(fs.readFileSync(outputPath, "utf8"));
const report = matrix.plan;
const applyReport = matrix.applyRun;
const activeReport = matrix.activeApplyRun;

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function targetPaths(report) {
  return report.repoGeneratedTargets.map((target) => target.relativePath);
}

assert(report.projectRoot === testProject, "projectRoot should match the workspace argument");
assert(report.safeToClean === true, "stale and terminal pid metadata should be safe to clean");
assert(report.recommendedAction === "cleanup-stale-generated-state-and-cap-external-logs", `unexpected action ${report.recommendedAction}`);
assert(report.configuredTargetCount === 3, `configured target count ${report.configuredTargetCount}`);
assert(report.invalidConfiguredTargetCount === 2, `invalid configured target count ${report.invalidConfiguredTargetCount}`);
assert(report.invalidConfiguredTargets.some((target) => target.reason === "missing-path"), "missing configured target should be reported");
assert(report.invalidConfiguredTargets.some((target) => target.message.includes("workspace root")), "workspace-root target should be rejected");
assert(report.activeProcessCount === 0, `active process count ${report.activeProcessCount}`);
assert(report.inactiveProcessCount >= 2, `inactive process count ${report.inactiveProcessCount}`);
assert(report.inactiveProcesses.some((process) => process.reason === "stale-pid"), "stale pid should be reported inactive");
assert(report.inactiveProcesses.some((process) => process.reason === "terminal-status"), "terminal status should be reported inactive");
assert(report.externalLogCount === 1, `external log count ${report.externalLogCount}`);
assert(report.externalLogs[0].name === "codex-tui-log", "external log name should identify codex tui log");
assert(report.externalLogs[0].exists === true, "fake codex log should exist");
assert(report.externalLogs[0].sizeMb === 2, `fake codex log size ${report.externalLogs[0].sizeMb}`);
assert(report.externalLogs[0].maxMb === 1, `fake codex log max ${report.externalLogs[0].maxMb}`);
assert(report.externalLogs[0].reclaimableMb === 1, `fake codex log reclaimable ${report.externalLogs[0].reclaimableMb}`);
assert(report.externalLogs[0].recommendedAction === "cap-log-tail", `fake codex log action ${report.externalLogs[0].recommendedAction}`);
assert(report.disk.reserveMet === true, "small disk reserve should be met");
assert(report.disk.shortfallMb === 0, "small disk reserve should not have a shortfall");
assert(report.disk.headroomMb === report.disk.availableMb - report.disk.requiredMb, "disk headroom should subtract the reserve from available space");
assert(report.cleanup.repoReclaimableMb >= 1, "cleanup plan should estimate reclaimable repo MB");
assert(report.cleanup.externalLogReclaimableMb === 1, `external log reclaimable ${report.cleanup.externalLogReclaimableMb}`);
assert(report.cleanup.totalReclaimableMb === report.cleanup.repoReclaimableMb + report.cleanup.externalLogReclaimableMb, "cleanup plan should add repo and external log reclaimable MB");
assert(report.cleanup.projectedAvailableMb === report.disk.availableMb + report.cleanup.totalReclaimableMb, "cleanup plan should project disk after cleanup");
assert(report.cleanup.reserveRequiredMb === report.disk.requiredMb, "cleanup projection should mirror disk reserve");
assert(report.cleanup.guardRequiredMb === report.disk.requiredMb + report.disk.minHeadroomMb, "cleanup projection should include guard headroom");
assert(report.cleanup.reserveShortfallAfterCleanupMb === 0, "small reserve should have no cleanup reserve shortfall");
assert(report.cleanup.guardShortfallAfterCleanupMb === 0, "small guard should have no cleanup guard shortfall");
assert(report.cleanup.cleanupCanSatisfyReserve === true, "safe cleanup should satisfy small reserve");
assert(report.cleanup.cleanupCanSatisfyGuard === true, "safe cleanup should satisfy small guard");
const paths = targetPaths(report);
assert(paths.includes(".clasp-swarm/full/01-lane/runs"), "runs target should be planned");
assert(paths.includes(".clasp-swarm/full/01-lane/jobs"), "jobs target should be planned");
assert(paths.includes(".clasp-verify/jobs"), "verify jobs target should be planned");
assert(paths.includes("generated/manual-cache"), "configured target should be planned");
assert(report.summary.includes("inactiveProcessCount="), "summary should include inactive pid evidence");

assert(applyReport.mode === "apply", "apply report should identify apply mode");
assert(applyReport.finalAction === "cleanup-and-external-log-cap-applied", `unexpected final action ${applyReport.finalAction}`);
assert(applyReport.plan.safeToClean === true, "apply should only run from a safe plan");
assert(applyReport.removals.length >= 4, "apply should remove planned generated targets");
assert(applyReport.removals.every((removal) => removal.ok === true), "all planned removals should succeed");
assert(applyReport.externalLogCaps.length === 1, `external log cap count ${applyReport.externalLogCaps.length}`);
assert(applyReport.externalLogCaps[0].name === "codex-tui-log", "external log cap should identify codex log");
assert(applyReport.externalLogCaps[0].ok === true, "external log cap should succeed");
assert(applyReport.externalLogCaps[0].beforeSizeMb === 2, `external log cap before size ${applyReport.externalLogCaps[0].beforeSizeMb}`);
assert(applyReport.externalLogCaps[0].afterSizeMb === 1, `external log cap after size ${applyReport.externalLogCaps[0].afterSizeMb}`);
assert(fs.statSync(codexLogPath).size === 1048576, "external log cap should keep exactly the final 1 MiB");
assert(!fs.existsSync(path.join(testProject, ".clasp-swarm", "full", "01-lane", "runs")), "runs target should be removed");
assert(!fs.existsSync(path.join(testProject, ".clasp-swarm", "full", "01-lane", "jobs")), "jobs target should be removed");
assert(!fs.existsSync(path.join(testProject, ".clasp-verify", "jobs")), "verify jobs target should be removed");
assert(!fs.existsSync(path.join(testProject, "generated", "manual-cache")), "configured target should be removed");
assert(fs.existsSync(path.join(testProject, ".clasp-generated-state", "cleanup-targets.json")), "cleanup catalog should not be removed");

assert(activeReport.mode === "apply", "active report should still identify apply mode");
assert(activeReport.finalAction === "refused-active-generated-work", `unexpected final action ${activeReport.finalAction}`);
assert(activeReport.removals.length === 0, "active generated work should prevent removals");
assert(activeReport.plan.safeToClean === false, "active generated work should mark cleanup unsafe");
assert(activeReport.plan.recommendedAction === "wait-active-generated-work", `unexpected action ${activeReport.plan.recommendedAction}`);
assert(activeReport.plan.cleanup.cleanupCanSatisfyReserve === false, "active generated work should prevent reserve sufficiency");
assert(activeReport.plan.cleanup.cleanupCanSatisfyGuard === false, "active generated work should prevent guard sufficiency");
assert(activeReport.externalLogCaps.length === 0, "already capped external log should not be capped again");
assert(activeReport.plan.activeProcessCount === 1, `active process count ${activeReport.plan.activeProcessCount}`);
assert(activeReport.plan.activeProcesses[0].pid === activePid, "active pid should be reported");
assert(fs.existsSync(path.join(activeProject, ".clasp-swarm", "full", "02-active", "jobs", "job-active", "stdout.log")), "active artifact should remain");
NODE

export_hosts_cleared=0
for _ in $(seq 1 50); do
  if [[ -z "$(test_export_host_pids)" ]]; then
    export_hosts_cleared=1
    break
  fi
  sleep 0.1
done
if [[ "$export_hosts_cleared" != "1" ]]; then
  printf 'generated-state cleanup plan left test export host process(es):\n' >&2
  test_export_host_pids >&2 || true
  exit 1
fi

printf '%s\n' "generated-state-cleanup-plan-ok"
