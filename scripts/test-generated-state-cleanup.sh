#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
mkdir -p "$tmp_root"
test_root="$(mktemp -d "$tmp_root/test-generated-state-cleanup.XXXXXX")"
active_pid=""

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

test_project="$test_root/project"
mkdir -p "$test_project/scripts"
cp "$project_root/scripts/clasp-clean-generated-state.sh" "$test_project/scripts/clasp-clean-generated-state.sh"
chmod +x "$test_project/scripts/clasp-clean-generated-state.sh"

mkdir -p \
  "$test_project/.clasp-swarm/full/01-lane/runs/run-1" \
  "$test_project/.clasp-swarm/full/01-lane/jobs/job-stale" \
  "$test_project/.clasp-swarm/full/01-lane/completed" \
  "$test_project/.clasp-verify/jobs/job-old" \
  "$test_project/.clasp-agents/task-1/jobs/job-old" \
  "$test_project/.clasp-loops/jobs/job-old" \
  "$test_project/benchmarks/workspaces/generated-workspace" \
  "$test_project/benchmarks/results/generated-result" \
  "$test_project/dist/backend-benchmarks" \
  "$test_project/runtime/target/debug" \
  "$test_project/dist-newstyle/build"

printf 'run artifact\n' >"$test_project/.clasp-swarm/full/01-lane/runs/run-1/artifact.txt"
printf 'started\n' >"$test_project/.clasp-swarm/full/01-lane/jobs/job-stale/status"
printf '999999\n' >"$test_project/.clasp-swarm/full/01-lane/jobs/job-stale/pid"
printf 'done\n' >"$test_project/.clasp-swarm/full/01-lane/completed/SW-001"
printf 'completed\n' >"$test_project/.clasp-verify/jobs/job-old/status"
printf '0\n' >"$test_project/.clasp-verify/jobs/job-old/exit-status"
printf 'completed\n' >"$test_project/.clasp-agents/task-1/jobs/job-old/status"
printf 'completed\n' >"$test_project/.clasp-loops/jobs/job-old/status"
printf 'keep\n' >"$test_project/benchmarks/workspaces/.gitkeep"
printf 'keep\n' >"$test_project/benchmarks/results/.gitkeep"
printf 'workspace cache\n' >"$test_project/benchmarks/workspaces/generated-workspace/cache.txt"
printf 'result cache\n' >"$test_project/benchmarks/results/generated-result/result.json"
printf 'dist cache\n' >"$test_project/dist/backend-benchmarks/result.txt"
printf 'runtime build cache\n' >"$test_project/runtime/target/debug/claspc"
printf 'dist-newstyle cache\n' >"$test_project/dist-newstyle/build/cache"

cache_dir="$test_root/xdg-cache/claspc-native/run-binary-cache-v2"
mkdir -p "$cache_dir"
printf 'cached binary\n' >"$cache_dir/stale-bin"

temp_cache_root="$test_root/tmp-cache"
global_cache_dir="$test_root/global-clasp-nix-cache"
codex_home="$test_root/codex-home"
codex_log="$codex_home/log/codex-tui.log"
mkdir -p \
  "$temp_cache_root/clasp-test-xdg-cache/claspc-native/run-binary-cache-v2" \
  "$temp_cache_root/clasp-verify-affected-jobs/job-old" \
  "$temp_cache_root/test-native-claspc.ABC123" \
  "$temp_cache_root/nix-shell.stale" \
  "$temp_cache_root/nix-develop-123-0" \
  "$temp_cache_root/native-runtime-trace.stale" \
  "$temp_cache_root/context-pack-js.stale" \
  "$global_cache_dir/claspc-native/run-binary-cache-v2" \
  "$codex_home/log"
printf 'temp binary\n' >"$temp_cache_root/clasp-test-xdg-cache/claspc-native/run-binary-cache-v2/stale-bin"
printf 'temp job\n' >"$temp_cache_root/clasp-verify-affected-jobs/job-old/status"
printf 'native test tmp\n' >"$temp_cache_root/test-native-claspc.ABC123/artifact"
printf 'nested nix\n' >"$temp_cache_root/nix-shell.stale/artifact"
printf 'nix develop\n' >"$temp_cache_root/nix-develop-123-0/artifact"
printf 'native trace\n' >"$temp_cache_root/native-runtime-trace.stale/artifact"
printf 'context pack\n' >"$temp_cache_root/context-pack-js.stale/artifact"
printf 'global cache\n' >"$global_cache_dir/claspc-native/run-binary-cache-v2/stale-bin"
printf '%*s' 1024 '' | tr ' ' A >"$codex_log"

dry_run_output="$test_root/dry-run.out"
CLASP_PROJECT_ROOT="$test_project" \
XDG_CACHE_HOME="$test_root/xdg-cache" \
  CODEX_HOME="$codex_home" \
  CLASP_GENERATED_STATE_TMPDIR="$temp_cache_root" \
  CLASP_GENERATED_STATE_GLOBAL_CACHE_DIR="$global_cache_dir" \
  CLASP_GENERATED_STATE_CODEX_LOG_MAX_BYTES=64 \
  "$test_project/scripts/clasp-clean-generated-state.sh" --dry-run --include-run-binary-cache --include-temp-caches --include-test-tmpdirs --include-build-caches --include-codex-logs >"$dry_run_output"

grep -F 'mode=dry-run' "$dry_run_output" >/dev/null
grep -F 'target=.clasp-swarm/full/01-lane/runs' "$dry_run_output" >/dev/null
grep -F 'target=.clasp-swarm/full/01-lane/jobs' "$dry_run_output" >/dev/null
grep -F 'target=benchmarks/workspaces/generated-workspace' "$dry_run_output" >/dev/null
grep -F 'target=benchmarks/results/generated-result' "$dry_run_output" >/dev/null
grep -F 'target=dist' "$dry_run_output" >/dev/null
grep -F "temp_target=$temp_cache_root/clasp-test-xdg-cache" "$dry_run_output" >/dev/null
grep -F "temp_target=$temp_cache_root/clasp-verify-affected-jobs" "$dry_run_output" >/dev/null
grep -F "temp_target=$temp_cache_root/test-native-claspc.ABC123" "$dry_run_output" >/dev/null
grep -F "temp_target=$temp_cache_root/nix-shell.stale" "$dry_run_output" >/dev/null
grep -F "temp_target=$temp_cache_root/nix-develop-123-0" "$dry_run_output" >/dev/null
grep -F "temp_target=$temp_cache_root/native-runtime-trace.stale" "$dry_run_output" >/dev/null
grep -F "temp_target=$temp_cache_root/context-pack-js.stale" "$dry_run_output" >/dev/null
grep -F "temp_target=$global_cache_dir" "$dry_run_output" >/dev/null
grep -F 'build_cache_target=runtime/target' "$dry_run_output" >/dev/null
grep -F 'build_cache_target=dist-newstyle' "$dry_run_output" >/dev/null
grep -F "run_binary_cache=$cache_dir" "$dry_run_output" >/dev/null
grep -F "codex_log=$codex_log" "$dry_run_output" >/dev/null
[[ -f "$test_project/.clasp-swarm/full/01-lane/runs/run-1/artifact.txt" ]]
[[ -f "$test_project/benchmarks/workspaces/generated-workspace/cache.txt" ]]
[[ -f "$test_project/benchmarks/results/generated-result/result.json" ]]
[[ -f "$test_project/dist/backend-benchmarks/result.txt" ]]
[[ -f "$test_project/runtime/target/debug/claspc" ]]
[[ -f "$test_project/dist-newstyle/build/cache" ]]
[[ -f "$cache_dir/stale-bin" ]]
[[ -f "$temp_cache_root/clasp-test-xdg-cache/claspc-native/run-binary-cache-v2/stale-bin" ]]
[[ -f "$temp_cache_root/clasp-verify-affected-jobs/job-old/status" ]]
[[ -f "$temp_cache_root/test-native-claspc.ABC123/artifact" ]]
[[ -f "$temp_cache_root/nix-shell.stale/artifact" ]]
[[ -f "$temp_cache_root/nix-develop-123-0/artifact" ]]
[[ -f "$global_cache_dir/claspc-native/run-binary-cache-v2/stale-bin" ]]
[[ -f "$codex_log" ]]

health_output="$test_root/health.out"
CLASP_PROJECT_ROOT="$test_project" \
XDG_CACHE_HOME="$test_root/xdg-cache" \
CODEX_HOME="$codex_home" \
CLASP_GENERATED_STATE_TMPDIR="$temp_cache_root" \
CLASP_GENERATED_STATE_GLOBAL_CACHE_DIR="$global_cache_dir" \
CLASP_GENERATED_STATE_CODEX_LOG_MAX_BYTES=64 \
  "$test_project/scripts/clasp-clean-generated-state.sh" \
    --health \
    --include-run-binary-cache \
    --include-temp-caches \
    --include-codex-logs \
    --include-build-caches \
    --min-available-disk-mb 999999999 \
    --disk-reserve-path "$test_project" >"$health_output"

grep -F 'mode=health' "$health_output" >/dev/null
grep -F 'safe_to_clean=true' "$health_output" >/dev/null
grep -F 'recommended_action=run-cleanup-then-free-disk-externally' "$health_output" >/dev/null
grep -F 'active_processes=0' "$health_output" >/dev/null
grep -F 'min_disk_headroom_mb=' "$health_output" >/dev/null
grep -F 'disk_headroom_mb=' "$health_output" >/dev/null
grep -F 'disk_shortfall_mb=' "$health_output" >/dev/null
grep -F 'disk_low_headroom=' "$health_output" >/dev/null
grep -F 'disk_reserve_met=false' "$health_output" >/dev/null
grep -F 'total_reclaimable_mb=' "$health_output" >/dev/null
grep -F 'projected_available_disk_mb=' "$health_output" >/dev/null
grep -F 'disk_guard_required_mb=' "$health_output" >/dev/null
grep -F 'reserve_shortfall_after_cleanup_mb=' "$health_output" >/dev/null
grep -F 'guard_shortfall_after_cleanup_mb=' "$health_output" >/dev/null
grep -F 'cleanup_can_satisfy_reserve=false' "$health_output" >/dev/null
grep -F 'cleanup_can_satisfy_guard=false' "$health_output" >/dev/null
grep -F 'repo_generated_targets=' "$health_output" >/dev/null
grep -F 'temp_generated_targets=' "$health_output" >/dev/null
grep -F 'build_cache_targets=' "$health_output" >/dev/null
grep -F 'codex_log_included=true' "$health_output" >/dev/null
grep -F "codex_log_path=$codex_log" "$health_output" >/dev/null
grep -F 'codex_log_reclaimable_mb=' "$health_output" >/dev/null

health_json="$test_root/health.json"
CLASP_PROJECT_ROOT="$test_project" \
XDG_CACHE_HOME="$test_root/xdg-cache" \
CODEX_HOME="$codex_home" \
CLASP_GENERATED_STATE_TMPDIR="$temp_cache_root" \
CLASP_GENERATED_STATE_GLOBAL_CACHE_DIR="$global_cache_dir" \
CLASP_GENERATED_STATE_CODEX_LOG_MAX_BYTES=64 \
  "$test_project/scripts/clasp-clean-generated-state.sh" \
    --health \
    --json \
    --include-run-binary-cache \
    --include-temp-caches \
    --include-test-tmpdirs \
    --include-codex-logs \
    --include-build-caches \
    --min-available-disk-mb 1 \
    --disk-reserve-path "$test_project" >"$health_json"

node - "$health_json" "$test_project" "$cache_dir" "$temp_cache_root" "$global_cache_dir" "$codex_log" <<'NODE'
const fs = require("node:fs");
const report = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const projectRoot = process.argv[3];
const cacheDir = process.argv[4];
const tempCacheRoot = process.argv[5];
const globalCacheDir = process.argv[6];
const codexLog = process.argv[7];

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

assert(report.schemaVersion === 1, "schema version should be present");
assert(report.mode === "health", "health mode should be encoded");
assert(report.projectRoot === projectRoot, "project root should be encoded");
assert(report.safeToClean === true, "safeToClean should be true before active pids");
assert(report.recommendedAction === "cleanup-stale-generated-state", "stale targets should recommend cleanup when reserve is met");
assert(report.activeProcessCount === 0, "active process count should be zero");
assert(report.disk.requiredMb === 1, "required disk reserve should follow the flag");
assert(report.disk.reservePath === projectRoot, "reserve path should follow the flag");
assert(report.disk.reserveMet === true, "small disk reserve should be met");
assert(report.disk.minHeadroomMb === 1024, "default disk headroom threshold should be encoded");
assert(Number.isInteger(report.disk.headroomMb), "disk headroom should be encoded");
assert(report.disk.headroomMb >= 0, "small disk reserve should have non-negative headroom");
assert(report.disk.shortfallMb === 0, "small disk reserve should have zero shortfall");
assert(report.disk.lowHeadroom === false, "small disk reserve should have sufficient headroom");
assert(report.cleanup.repoReclaimableMb > 0, "repo reclaimable size should be encoded");
assert(report.cleanup.tempReclaimableMb > 0, "temp reclaimable size should be encoded");
assert(report.cleanup.buildCacheReclaimableMb > 0, "build cache reclaimable size should be encoded");
assert(report.cleanup.runBinaryCacheReclaimableMb > 0, "run binary cache reclaimable size should be encoded");
assert(report.cleanup.codexLogReclaimableMb > 0, "codex log reclaimable size should be encoded");
assert(
  report.cleanup.totalReclaimableMb ===
    report.cleanup.repoReclaimableMb +
      report.cleanup.tempReclaimableMb +
      report.cleanup.buildCacheReclaimableMb +
      report.cleanup.runBinaryCacheReclaimableMb +
      report.cleanup.codexLogReclaimableMb,
  "total reclaimable size should sum cleanup classes",
);
assert(report.cleanup.projectedAvailableMb === report.disk.availableMb + report.cleanup.totalReclaimableMb, "projected disk should include reclaimable bytes");
assert(report.cleanup.reserveRequiredMb === report.disk.requiredMb, "cleanup reserve requirement should mirror disk requirement");
assert(report.cleanup.guardRequiredMb === report.disk.requiredMb + report.disk.minHeadroomMb, "cleanup guard requirement should include headroom");
assert(report.cleanup.reserveShortfallAfterCleanupMb === 0, "cleanup should cover small disk reserve");
assert(report.cleanup.guardShortfallAfterCleanupMb === 0, "cleanup should cover small disk guard");
assert(report.cleanup.cleanupCanSatisfyReserve === true, "cleanup should satisfy small reserve");
assert(report.cleanup.cleanupCanSatisfyGuard === true, "cleanup should satisfy small guard");
assert(report.tempCacheScanIncluded === true, "temp cache scan inclusion should be encoded");
assert(report.testTmpdirScanIncluded === true, "test tmpdir scan inclusion should be encoded");
assert(report.runBinaryCacheIncluded === true, "cache inclusion should be encoded");
assert(report.runBinaryCache === cacheDir, "cache path should be encoded");
assert(report.codexLogIncluded === true, "codex log inclusion should be encoded");
assert(report.codexLog.path === codexLog, "codex log path should be encoded");
assert(report.codexLog.exists === true, "codex log existence should be encoded");
assert(report.codexLog.sizeBytes === 1024, "codex log size should be encoded");
assert(report.codexLog.maxBytes === 64, "codex log cap should be encoded");
assert(report.codexLog.reclaimableMb === report.cleanup.codexLogReclaimableMb, "codex log reclaimable size should be mirrored");
assert(report.repoGeneratedTargets.includes(".clasp-swarm/full/01-lane/runs"), "runs target should be encoded");
assert(report.repoGeneratedTargets.includes(".clasp-swarm/full/01-lane/jobs"), "jobs target should be encoded");
assert(report.repoGeneratedTargets.includes("benchmarks/workspaces/generated-workspace"), "benchmark workspace target should be encoded");
assert(report.repoGeneratedTargets.includes("benchmarks/results/generated-result"), "benchmark result target should be encoded");
assert(report.repoGeneratedTargets.includes("dist"), "dist target should be encoded");
assert(report.tempGeneratedTargets.includes(`${tempCacheRoot}/clasp-test-xdg-cache`), "temp xdg cache should be encoded");
assert(report.tempGeneratedTargets.includes(`${tempCacheRoot}/clasp-verify-affected-jobs`), "verify temp jobs should be encoded");
assert(report.tempGeneratedTargets.includes(`${tempCacheRoot}/test-native-claspc.ABC123`), "test tmpdir should be encoded");
assert(report.tempGeneratedTargets.includes(`${tempCacheRoot}/nix-shell.stale`), "nested nix shell temp should be encoded");
assert(report.tempGeneratedTargets.includes(`${tempCacheRoot}/nix-develop-123-0`), "nix develop temp should be encoded");
assert(report.tempGeneratedTargets.includes(globalCacheDir), "global clasp cache should be encoded");
assert(report.buildCacheScanIncluded === true, "build cache scan inclusion should be encoded");
assert(report.buildCacheTargets.includes("runtime/target"), "runtime target cache should be encoded");
assert(report.buildCacheTargets.includes("dist-newstyle"), "dist-newstyle cache should be encoded");
NODE

apply_output="$test_root/apply.out"
CLASP_PROJECT_ROOT="$test_project" \
XDG_CACHE_HOME="$test_root/xdg-cache" \
  CODEX_HOME="$codex_home" \
  CLASP_GENERATED_STATE_TMPDIR="$temp_cache_root" \
  CLASP_GENERATED_STATE_GLOBAL_CACHE_DIR="$global_cache_dir" \
  CLASP_GENERATED_STATE_CODEX_LOG_MAX_BYTES=64 \
  "$test_project/scripts/clasp-clean-generated-state.sh" --apply --include-run-binary-cache --include-temp-caches --include-test-tmpdirs --include-build-caches --include-codex-logs >"$apply_output"

grep -F 'mode=apply' "$apply_output" >/dev/null
grep -F 'cleanup=ok' "$apply_output" >/dev/null
[[ ! -e "$test_project/.clasp-swarm/full/01-lane/runs" ]]
[[ ! -e "$test_project/.clasp-swarm/full/01-lane/jobs" ]]
[[ ! -e "$test_project/.clasp-verify/jobs" ]]
[[ ! -e "$test_project/.clasp-agents/task-1/jobs" ]]
[[ ! -e "$test_project/.clasp-loops/jobs" ]]
[[ ! -e "$test_project/benchmarks/workspaces/generated-workspace" ]]
[[ ! -e "$test_project/benchmarks/results/generated-result" ]]
[[ ! -e "$test_project/dist" ]]
[[ ! -e "$test_project/runtime/target" ]]
[[ ! -e "$test_project/dist-newstyle" ]]
[[ -f "$test_project/benchmarks/workspaces/.gitkeep" ]]
[[ -f "$test_project/benchmarks/results/.gitkeep" ]]
[[ -f "$test_project/.clasp-swarm/full/01-lane/completed/SW-001" ]]
[[ -d "$cache_dir" ]]
[[ ! -e "$cache_dir/stale-bin" ]]
[[ ! -e "$temp_cache_root/clasp-test-xdg-cache" ]]
[[ ! -e "$temp_cache_root/clasp-verify-affected-jobs" ]]
[[ ! -e "$temp_cache_root/test-native-claspc.ABC123" ]]
[[ ! -e "$temp_cache_root/nix-shell.stale" ]]
[[ ! -e "$temp_cache_root/nix-develop-123-0" ]]
[[ ! -e "$temp_cache_root/native-runtime-trace.stale" ]]
[[ ! -e "$temp_cache_root/context-pack-js.stale" ]]
[[ ! -e "$global_cache_dir" ]]
[[ -f "$codex_log" ]]
codex_log_size="$(wc -c <"$codex_log" | tr -d '[:space:]')"
[[ "$codex_log_size" == "64" ]]

low_headroom_json="$test_root/low-headroom.json"
CLASP_PROJECT_ROOT="$test_project" \
  "$test_project/scripts/clasp-clean-generated-state.sh" \
    --health \
    --json \
    --min-available-disk-mb 1 \
    --min-disk-headroom-mb 999999999 \
    --disk-reserve-path "$test_project" >"$low_headroom_json"

node - "$low_headroom_json" <<'NODE'
const fs = require("node:fs");
const report = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

assert(report.safeToClean === true, "cleaned project should be safe");
assert(report.recommendedAction === "free-disk-headroom", "low headroom without cleanup targets should ask for external disk headroom");
assert(report.repoGeneratedTargetCount === 0, "repo cleanup targets should be gone");
assert(report.tempGeneratedTargetCount === 0, "temp cleanup targets should not be included");
assert(report.buildCacheTargetCount === 0, "build cleanup targets should not be included");
assert(report.disk.requiredMb === 1, "low-headroom reserve should still be met");
assert(report.disk.reserveMet === true, "low-headroom scenario should keep reserve met");
assert(report.disk.minHeadroomMb === 999999999, "custom headroom threshold should be encoded");
assert(report.disk.lowHeadroom === true, "custom headroom threshold should trigger lowHeadroom");
assert(report.disk.shortfallMb === 0, "low-headroom warning is separate from reserve shortfall");
assert(report.cleanup.totalReclaimableMb === 0, "cleaned project should have no reclaimable generated state");
assert(report.cleanup.projectedAvailableMb === report.disk.availableMb, "projected disk should match available disk without cleanup targets");
assert(report.cleanup.reserveShortfallAfterCleanupMb === 0, "cleaned project should still satisfy hard reserve");
assert(report.cleanup.guardShortfallAfterCleanupMb > 0, "cleaned project should still miss exaggerated guard headroom");
assert(report.cleanup.cleanupCanSatisfyReserve === true, "cleaned project should satisfy hard reserve");
assert(report.cleanup.cleanupCanSatisfyGuard === false, "cleaned project should not satisfy exaggerated guard headroom");
NODE

mkdir -p "$test_project/.clasp-swarm/full/02-active/jobs/job-active"
sleep 60 &
active_pid="$!"
printf 'started\n' >"$test_project/.clasp-swarm/full/02-active/jobs/job-active/status"
printf '%s\n' "$active_pid" >"$test_project/.clasp-swarm/full/02-active/jobs/job-active/pid"
printf 'active artifact\n' >"$test_project/.clasp-swarm/full/02-active/jobs/job-active/stdout.log"

active_health_json="$test_root/active-health.json"
CLASP_PROJECT_ROOT="$test_project" \
  "$test_project/scripts/clasp-clean-generated-state.sh" --health --json >"$active_health_json"

node - "$active_health_json" "$active_pid" <<'NODE'
const fs = require("node:fs");
const report = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const activePid = process.argv[3];

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

assert(report.mode === "health", "active report should still be health mode");
assert(report.safeToClean === false, "active pid should make cleanup unsafe");
assert(report.recommendedAction === "wait-active-generated-work", "active pid should recommend waiting");
assert(report.cleanup.cleanupCanSatisfyReserve === false, "active pid should prevent cleanup from satisfying reserve");
assert(report.cleanup.cleanupCanSatisfyGuard === false, "active pid should prevent cleanup from satisfying guard");
assert(report.activeProcessCount === 1, "active process count should be one");
assert(report.activeProcesses[0].pid === activePid, "active pid should be reported");
assert(report.activeProcesses[0].status === "started", "active status should be reported");
NODE

active_stderr="$test_root/active.err"
if CLASP_PROJECT_ROOT="$test_project" \
  "$test_project/scripts/clasp-clean-generated-state.sh" --apply >"$test_root/active.out" 2>"$active_stderr"; then
  printf 'cleanup unexpectedly removed generated state while active pid was alive\n' >&2
  exit 1
fi

grep -F 'refusing cleanup because generated work is still running' "$active_stderr" >/dev/null
[[ -f "$test_project/.clasp-swarm/full/02-active/jobs/job-active/stdout.log" ]]

printf 'generated-state-cleanup-ok\n'
