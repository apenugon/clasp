#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

node --check "$project_root/scripts/generate-promoted-module-summary-cache.mjs" >/dev/null
node "$project_root/scripts/generate-promoted-module-summary-cache.mjs" --check >/dev/null
node - "$project_root/src/stage1.compiler.module-summary-cache-v2.json" <<'EOF'
const fs = require("node:fs");

const [cachePath] = process.argv.slice(2);
const cache = JSON.parse(fs.readFileSync(cachePath, "utf8"));

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

assert(cache.sources.includes("src/Main.clasp"), "promoted cache should include the selfhost entry");
assert(
  cache.sources.includes("examples/swarm-native/GoalManagerGeneratedCleanupHealthHarness.clasp"),
  "promoted cache should include the cleanup-health harness entry",
);
for (const moduleName of [
  "GoalManagerResourceContext",
  "HostResources",
  "GeneratedStateCleanupPlan",
  "GoalManagerGeneratedCleanupHealth",
  "GoalManagerGeneratedCleanupHealthHarness",
]) {
  const entry = cache.summaries.find((candidate) => candidate.moduleName === moduleName);
  assert(entry, `promoted cache missing ${moduleName}`);
  assert(entry.cacheKey && entry.cacheKey.endsWith(".cache"), `${moduleName} should include a cache key`);
  assert(entry.sourceFingerprint, `${moduleName} should include a source fingerprint`);
  assert(typeof entry.summary === "string", `${moduleName} should include a summary`);
}

console.log("promoted-module-summary-cache-static-ok");
EOF
