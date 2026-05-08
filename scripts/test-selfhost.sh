#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
mkdir -p "$tmp_root"
export TMPDIR="$tmp_root"
test_root="$(mktemp -d "$TMPDIR/test-selfhost.XXXXXX")"
claspc_bin="$("$project_root/scripts/resolve-claspc.sh")"
time_bin="$(which time 2>/dev/null || true)"
selfhost_entry_cache_root="$test_root/selfhost-entry-cache-root"
selfhost_entry_check_output="$test_root/selfhost.entry.check.json"
selfhost_entry_check_log="$test_root/selfhost.entry.check.log"
semantic_probe_cache_root="$test_root/semantic-probe-cache"
semantic_source_path="$test_root/semantic-context.clasp"
semantic_check_output="$test_root/semantic.check.txt"
semantic_air_output="$test_root/semantic.air.json"
semantic_context_output="$test_root/semantic.context.json"
large_selfhost_project_root="$test_root/large-selfhost-project"
large_selfhost_cache_root="$test_root/large-selfhost-cache"
large_selfhost_check_output="$test_root/large-selfhost.check.json"
large_selfhost_check_log="$test_root/large-selfhost.check.log"
large_selfhost_check_time="$test_root/large-selfhost.check.time"
large_selfhost_invalid_output="$test_root/large-selfhost.invalid.json"
large_selfhost_invalid_log="$test_root/large-selfhost.invalid.log"

selfhost_incremental_report="$test_root/selfhost.incremental.report.json"

cleanup() {
  rm -rf "$test_root"
}

trap cleanup EXIT

cat >"$semantic_source_path" <<'EOF'
module Main

type LeadPriority = Low | Medium | High

record LeadRequest = {
  company : Str,
  budget : Int,
  priorityHint : LeadPriority
}

record LeadSummary = {
  summary : Str,
  priority : LeadPriority,
  followUpRequired : Bool
}

foreign mockLeadSummaryModel : LeadRequest -> Str = "mockLeadSummaryModel"

summarizeLead : LeadRequest -> LeadSummary
summarizeLead lead = decode LeadSummary (mockLeadSummaryModel lead)

route summarizeLeadRoute = POST "/lead/summary" LeadRequest -> LeadSummary summarizeLead
EOF

mkdir -p "$selfhost_entry_cache_root"
mkdir -p "$semantic_probe_cache_root"

node "$project_root/scripts/generate-promoted-module-summary-cache.mjs" --check >/dev/null
node "$project_root/scripts/check-promoted-native-image-exports.mjs" >/dev/null

XDG_CACHE_HOME="$semantic_probe_cache_root" CLASPC_BIN="$claspc_bin" \
  bash "$project_root/src/scripts/run-native-tool.sh" \
  "$project_root/src/embedded.compiler.native.image.json" \
  checkSourceText \
  "$semantic_source_path" \
  "$semantic_check_output"
grep -F 'summarizeLead : LeadRequest -> LeadSummary' "$semantic_check_output" >/dev/null

XDG_CACHE_HOME="$semantic_probe_cache_root" CLASPC_BIN="$claspc_bin" \
  bash "$project_root/src/scripts/run-native-tool.sh" \
  "$project_root/src/embedded.compiler.native.image.json" \
  airSourceText \
  "$semantic_source_path" \
  "$semantic_air_output"
node - "$semantic_air_output" <<'EOF'
const fs = require("node:fs");

const artifact = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (artifact.format !== "clasp-air-v1") {
  throw new Error(`unexpected AIR format: ${artifact.format}`);
}
const route = artifact.nodes?.find((entry) => entry.kind === "route" && entry.name === "summarizeLeadRoute");
if (!route) {
  throw new Error("missing summarizeLeadRoute in AIR nodes");
}
if (route.responseKind !== "json") {
  throw new Error(`unexpected AIR route responseKind: ${route.responseKind}`);
}
EOF

XDG_CACHE_HOME="$semantic_probe_cache_root" CLASPC_BIN="$claspc_bin" \
  bash "$project_root/src/scripts/run-native-tool.sh" \
  "$project_root/src/embedded.compiler.native.image.json" \
  contextSourceText \
  "$semantic_source_path" \
  "$semantic_context_output"
node - "$semantic_context_output" <<'EOF'
const fs = require("node:fs");

const graph = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (graph.format !== "clasp-context-v1") {
  throw new Error(`unexpected context format: ${graph.format}`);
}
const route = graph.surfaceIndex?.routes?.find((entry) => entry.name === "summarizeLeadRoute");
if (!route) {
  throw new Error("missing summarizeLeadRoute in context surfaceIndex.routes");
}
if (route.responseKind !== "json") {
  throw new Error(`unexpected route responseKind: ${route.responseKind}`);
}
const hasForeignUse = graph.edges?.some(
  (edge) => edge.kind === "uses" && edge.from === "decl:summarizeLead" && edge.to === "foreign:mockLeadSummaryModel",
);
if (!hasForeignUse) {
  throw new Error("missing declaration uses edge to mockLeadSummaryModel");
}
const hasSchemaUse = graph.edges?.some(
  (edge) => edge.kind === "uses" && edge.from === "decl:summarizeLead" && edge.to === "schema:LeadSummary",
);
if (!hasSchemaUse) {
  throw new Error("missing declaration uses edge to LeadSummary schema");
}
EOF

XDG_CACHE_HOME="$selfhost_entry_cache_root" CLASP_NATIVE_TRACE_CACHE=1 "$claspc_bin" --json check "$project_root/src/Main.clasp" >"$selfhost_entry_check_output" 2>"$selfhost_entry_check_log"
grep -F '"status":"ok"' "$selfhost_entry_check_output" >/dev/null
grep -F '[claspc-cache] module-summary promoted hit module=Compiler.Ast ' "$selfhost_entry_check_log" >/dev/null
grep -F '[claspc-cache] module-summary promoted hit module=Compiler.Emit.JavaScript ' "$selfhost_entry_check_log" >/dev/null
grep -F '[claspc-cache] module-summary promoted hit module=Main ' "$selfhost_entry_check_log" >/dev/null

if [[ -z "$time_bin" || ! -x "$time_bin" ]]; then
  printf 'missing time binary\n' >&2
  exit 1
fi

mkdir -p "$large_selfhost_project_root"
(
  cd "$project_root/src"
  find . -name '*.clasp' -print | while IFS= read -r source_path; do
    mkdir -p "$large_selfhost_project_root/$(dirname "$source_path")"
    cp "$source_path" "$large_selfhost_project_root/$source_path"
  done
)
sed -i 's/keepNoRenderedText value = false/keepNoRenderedText value = true/' "$large_selfhost_project_root/Compiler/Ast.clasp"

"$time_bin" -p -o "$large_selfhost_check_time" \
  env XDG_CACHE_HOME="$large_selfhost_cache_root" CLASP_NATIVE_TRACE_CACHE=1 \
  "$claspc_bin" --json check "$large_selfhost_project_root/Main.clasp" \
  >"$large_selfhost_check_output" 2>"$large_selfhost_check_log"
grep -F '"status":"ok"' "$large_selfhost_check_output" >/dev/null
grep -F '[claspc-cache] module-summary promoted unvalidated-hit module=Compiler.Ast ' "$large_selfhost_check_log" >/dev/null
grep -F '[claspc-cache] module-summary decl-validation module=Compiler.Ast changed=keepNoRenderedText' "$large_selfhost_check_log" >/dev/null
grep -F '[claspc-cache] module-summary validated-hit module=Compiler.Ast path=' "$large_selfhost_check_log" >/dev/null
node - "$large_selfhost_check_time" <<'EOF'
const fs = require("node:fs");

const timePath = process.argv[2];
const maxSeconds = Number(process.env.CLASP_EDITED_MODULE_SPEED_MAX_SECONDS || "60");
const text = fs.readFileSync(timePath, "utf8");
const match = /^real\s+([0-9.]+)$/m.exec(text);
if (!match) {
  throw new Error(`missing real timing in ${timePath}`);
}
const realSeconds = Number(match[1]);
if (!(realSeconds < maxSeconds)) {
  throw new Error(`edited Compiler.Ast check took ${realSeconds}s, expected < ${maxSeconds}s`);
}
EOF
sed -i 's/keepNoRenderedText value = true/keepNoRenderedText value = "not-bool"/' "$large_selfhost_project_root/Compiler/Ast.clasp"
if env XDG_CACHE_HOME="$large_selfhost_cache_root" CLASP_NATIVE_TRACE_CACHE=1 \
  "$claspc_bin" --json check "$large_selfhost_project_root/Main.clasp" \
  >"$large_selfhost_invalid_output" 2>"$large_selfhost_invalid_log"; then
  printf 'large edited Compiler.Ast semantic error unexpectedly passed\n' >&2
  exit 1
fi
grep -F '"status":"error"' "$large_selfhost_invalid_output" >/dev/null
grep -F 'keepNoRenderedText' "$large_selfhost_invalid_output" >/dev/null
grep -F '[claspc-cache] module-summary decl-validation module=Compiler.Ast changed=keepNoRenderedText' "$large_selfhost_invalid_log" >/dev/null

CLASPC_BIN="$claspc_bin" bash "$project_root/scripts/measure-native-incremental.sh" \
  --scenario selfhost-body-change \
  --report "$selfhost_incremental_report" \
  --assert >/dev/null
node - "$selfhost_incremental_report" <<'EOF'
const fs = require("node:fs");

const report = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (report.scenario !== "selfhost-body-change") {
  throw new Error(`unexpected selfhost incremental scenario: ${report.scenario}`);
}
if (!report.matchesExpectations) {
  throw new Error(`selfhost incremental mismatches: ${report.mismatches.join("; ")}`);
}
if (JSON.stringify(report.changedModules) !== JSON.stringify(["Helper"])) {
  throw new Error(`unexpected selfhost changed modules: ${JSON.stringify(report.changedModules)}`);
}
if (report.observedCacheBehavior.image?.sourceExport?.nativeImageProjectText !== "miss") {
  throw new Error("expected nativeImageProjectText source-export miss");
}
if (report.expectedCacheBehavior.image?.buildPlan !== "hit") {
  throw new Error("expected selfhost report to include build-plan cache expectation");
}
if (typeof report.advisoryTimings.checkBodyChange?.realSeconds !== "number") {
  throw new Error("expected selfhost check body-change timing");
}
if (typeof report.advisoryTimings.imageBodyChange?.realSeconds !== "number") {
  throw new Error("expected selfhost image body-change timing");
}
EOF
