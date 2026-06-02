#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
program_path="$project_root/examples/swarm-native/GeneratedStateCleanupPlan.clasp"

node - "$program_path" <<'NODE'
const fs = require("node:fs");

const [programPath] = process.argv.slice(2);
const source = fs.readFileSync(programPath, "utf8");

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

assert(source.includes("module GeneratedStateCleanupPlan"), "cleanup plan module should exist");
assert(source.includes("readEnvJsonText : Str -> Str -> Str"), "cleanup plan should decode manager JSON text fallbacks");
assert(source.includes("readEnvJsonInt : Str -> Int -> Int"), "cleanup plan should decode manager JSON int fallbacks");
assert(source.includes('foreign workspacePathSizeMbRaw : Str -> Str -> Result Int = "workspacePathSizeMb"'), "cleanup plan should use root-confined workspace size host boundary");
assert(source.includes('foreign hostFileSizeMbRaw : Str -> Result Int = "hostFileSizeMb"'), "cleanup plan should use read-only host file size host boundary");
assert(source.includes('foreign hostCapFileTailMbRaw : Str -> Int -> Result Int = "hostCapFileTailMb"'), "cleanup plan should cap configured external logs in apply mode");
assert(source.includes("record GeneratedCleanupProjection ="), "cleanup plan should expose cleanup sufficiency projection");
assert(source.includes("record GeneratedExternalLog ="), "cleanup plan should expose external log evidence");
assert(source.includes("record GeneratedExternalLogCap ="), "cleanup plan should expose external log cap results");
assert(source.includes("record GeneratedStateCleanupTestMatrix ="), "cleanup plan should expose one-shot runtime test coverage shape");
assert(source.includes("generatedCleanupProjectionFor : Str -> Bool -> [GeneratedCleanupTarget] -> [GeneratedExternalLog] -> GeneratedCleanupDisk -> GeneratedCleanupProjection"), "cleanup plan should compute projected disk state");
assert(source.includes("generatedStateCleanupTestMatrixFor : Str -> Str -> GeneratedStateCleanupTestMatrix"), "cleanup plan should exercise plan/apply/active coverage in one run");
assert(source.includes("CLASP_GENERATED_STATE_TEST_MATRIX_JSON"), "cleanup plan should expose one-shot runtime test mode");
assert(source.includes("CLASP_GENERATED_STATE_CODEX_LOG_MAX_MB"), "cleanup plan should expose external log cap sizing");
assert(source.includes("generatedCleanupTargetsSizeMb"), "cleanup plan should total reclaimable repo targets");
assert(source.includes("generatedExternalLogReclaimableMb"), "cleanup plan should total reclaimable external log state");
assert(source.includes("generatedExternalLogCapsFor"), "cleanup plan should cap external logs during apply");
assert(
  /readEnvText\s+"CLASP_GENERATED_STATE_DISK_RESERVE_PATH"\s+\(readEnvJsonText "CLASP_MANAGER_DISK_RESERVE_PATH_JSON" generatedCleanupProjectRoot\)/.test(source),
  "cleanup plan should inherit manager disk reserve path defaults",
);
assert(
  /readEnvInt\s+"CLASP_GENERATED_STATE_MIN_AVAILABLE_DISK_MB"\s+\(readEnvJsonInt\s+"CLASP_MANAGER_MIN_AVAILABLE_DISK_MB_JSON"/.test(source),
  "cleanup plan should inherit manager minimum disk reserve defaults",
);
assert(
  /readEnvInt\s+"CLASP_GENERATED_STATE_MIN_HEADROOM_MB"\s+\(readEnvJsonInt "CLASP_MANAGER_MIN_DISK_HEADROOM_MB_JSON" 1024\)/.test(source),
  "cleanup plan should inherit manager minimum disk headroom defaults",
);
assert(source.includes("workspaceRemovePathRaw"), "cleanup plan should keep workspace removal host boundary");
assert(source.includes("hostAvailableDiskMb reservePath"), "cleanup plan should inspect disk against the reserve path");
assert(source.includes('generatedExternalLogFor "codex-tui-log"'), "cleanup plan should inspect codex log growth");
assert(source.includes("cleanup-and-external-log-cap-applied"), "cleanup plan should distinguish applied log caps");
assert(source.includes("run-cleanup-then-free-disk-externally"), "cleanup plan should distinguish insufficient cleanup from sufficient cleanup");
assert(source.includes("cleanup-then-free-disk-headroom"), "cleanup plan should distinguish insufficient headroom cleanup");
assert(source.includes("cleanupCanSatisfyGuard"), "cleanup plan should project guard sufficiency");
assert(source.includes("GeneratedStateCleanupRun"), "cleanup plan should keep apply/report shape");

console.log("generated-state-cleanup-plan-static-ok");
NODE
