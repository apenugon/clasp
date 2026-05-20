#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
mkdir -p "$tmp_root"
export TMPDIR="$tmp_root"
test_root="$(mktemp -d "$TMPDIR/test-selfhost.XXXXXX")"
if claspc_bin="$(env -u CLASP_CLASPC -u CLASPC_BIN "$project_root/scripts/resolve-claspc.sh")"; then
  :
else
  claspc_bin="$("$project_root/scripts/resolve-claspc.sh")"
fi
time_bin="$(which time 2>/dev/null || true)"
selfhost_entry_cache_root="$test_root/selfhost-entry-cache-root"
selfhost_entry_check_output="$test_root/selfhost.entry.check.json"
selfhost_entry_check_log="$test_root/selfhost.entry.check.log"
semantic_probe_cache_root="$test_root/semantic-probe-cache"
diagnostic_probe_cache_root="$test_root/diagnostic-probe-cache"
semantic_source_path="$test_root/semantic-context.clasp"
diagnostic_unbound_source_path="$test_root/diagnostic-unbound.clasp"
semantic_check_output="$test_root/semantic.check.txt"
diagnostic_unbound_output="$test_root/diagnostic-unbound.check.txt"
semantic_air_output="$test_root/semantic.air.json"
semantic_context_output="$test_root/semantic.context.json"
lead_app_context_output="$test_root/lead-app.context.json"
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
  company : Str classified pii,
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
mkdir -p "$diagnostic_probe_cache_root"

node "$project_root/scripts/generate-promoted-module-summary-cache.mjs" --check >/dev/null
node "$project_root/scripts/check-promoted-native-image-exports.mjs" >/dev/null

cat >"$diagnostic_unbound_source_path" <<'EOF'
module Main

main : Bool
main = True
EOF

XDG_CACHE_HOME="$diagnostic_probe_cache_root" CLASPC_BIN="$claspc_bin" \
  bash "$project_root/src/scripts/run-native-tool.sh" \
  "$project_root/src/embedded.compiler.native.image.json" \
  checkSourceText \
  "$diagnostic_unbound_source_path" \
  "$diagnostic_unbound_output"
grep -F 'In `main`: Unknown constructor `True`. Clasp boolean literals are lowercase; use `true` instead' "$diagnostic_unbound_output" >/dev/null

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
if (graph.sourceIdentity?.sourceId !== "source:Main" || graph.moduleIdentity?.moduleId !== "module:Main") {
  throw new Error("missing stable source/module identity for Main context");
}
if (!Array.isArray(graph.sourceModules) || graph.sourceModules[0]?.sourceFingerprint?.length !== 16) {
  throw new Error("missing sourceModules source fingerprint");
}
if (route.requestSchemaId !== "schema:LeadRequest" || route.responseSchemaId !== "schema:LeadSummary") {
  throw new Error("missing route request/response schema identities");
}
if (route.handlerId !== "decl:summarizeLead") {
  throw new Error(`unexpected route handler identity: ${route.handlerId}`);
}
const leadRequestSchema = graph.surfaceIndex?.schemas?.find((entry) => entry.id === "schema:LeadRequest");
if (!leadRequestSchema) {
  throw new Error("missing LeadRequest in context surfaceIndex.schemas");
}
if (leadRequestSchema.kind !== "record" || leadRequestSchema.name !== "LeadRequest") {
  throw new Error("LeadRequest schema entry missing stable record identity");
}
const leadRequestCompany = leadRequestSchema.fields?.find((field) => field.id === "schema-field:LeadRequest:company");
if (leadRequestCompany?.name !== "company" || leadRequestCompany?.type !== "Str" || leadRequestCompany?.classification !== "pii") {
  throw new Error("LeadRequest company field missing stable id/name/type/classification");
}
const priorityHint = graph.surfaceIndex?.schemaFields?.find((field) => field.id === "schema-field:LeadRequest:priorityHint");
if (!priorityHint?.referencedTypes?.includes("type:LeadPriority")) {
  throw new Error("LeadRequest priorityHint field missing enum type reference");
}
const leadSummarySchema = graph.surfaceIndex?.schemas?.find((entry) => entry.id === "schema:LeadSummary");
if (!leadSummarySchema?.fieldIds?.includes("schema-field:LeadSummary:followUpRequired")) {
  throw new Error("LeadSummary schema missing stable field ids");
}
if (!leadSummarySchema?.affectedRoutes?.includes("route:summarizeLeadRoute")) {
  throw new Error("LeadSummary schema missing affected route link");
}
const leadPriorityType = graph.surfaceIndex?.types?.find((entry) => entry.id === "type:LeadPriority");
if (!leadPriorityType) {
  throw new Error("missing LeadPriority in context surfaceIndex.types");
}
for (const constructorName of ["Low", "Medium", "High"]) {
  if (!leadPriorityType.wireConstructorNames?.includes(constructorName)) {
    throw new Error(`LeadPriority missing wire constructor ${constructorName}`);
  }
}
const highConstructor = leadPriorityType.constructors?.find((entry) => entry.id === "constructor:LeadPriority:High");
if (highConstructor?.wireName !== "High") {
  throw new Error("LeadPriority High constructor missing stable constructor entry");
}
if (!leadPriorityType.affectedSchemas?.includes("schema:LeadRequest") || !leadPriorityType.affectedRoutes?.includes("route:summarizeLeadRoute")) {
  throw new Error("LeadPriority type missing schema/route impact links");
}
for (const expectedSurface of ["schema:LeadRequest", "schema:LeadSummary", "decl:summarizeLead", "foreign:mockLeadSummaryModel"]) {
  if (!route.affectedSurfaces?.includes(expectedSurface)) {
    throw new Error(`route affected surfaces missing ${expectedSurface}`);
  }
}
if (!route.affectedForeignBoundaries?.includes("foreign:mockLeadSummaryModel")) {
  throw new Error("missing route affected foreign boundary");
}
if (!route.verificationGuidance?.focusedCommands?.includes("bash scripts/verify-affected.sh --changed-file <source.clasp>")) {
  throw new Error("missing route affected verifier guidance");
}
if (!graph.verificationGuidance?.scenarioCommands?.includes("bash examples/lead-app/scripts/verify.sh")) {
  throw new Error("missing lead-app scenario verification guidance");
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

XDG_CACHE_HOME="$semantic_probe_cache_root" CLASPC_BIN="$claspc_bin" \
  bash "$project_root/src/scripts/run-native-tool.sh" \
  "$project_root/src/embedded.compiler.native.image.json" \
  contextProjectText \
  "--project-entry=$project_root/examples/lead-app/Main.clasp" \
  "$lead_app_context_output"
node - "$lead_app_context_output" <<'EOF'
const fs = require("node:fs");

const graph = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const entryModule = graph.sourceModules?.find((entry) => entry.moduleName === "Main");
const sharedModule = graph.sourceModules?.find((entry) => entry.moduleName === "Shared.Lead");
if (entryModule?.role !== "entry" || sharedModule?.role !== "import") {
  throw new Error("lead-app context missing stable entry/import source module identities");
}
const dependencyGraph = graph.dependencyGraph;
if (dependencyGraph?.format !== "clasp-dependency-graph-v1") {
  throw new Error(`lead-app context missing dependencyGraph: ${dependencyGraph?.format}`);
}
const entryDependencyNode = dependencyGraph.nodes?.find((entry) => entry.id === "source:Main");
const sharedDependencyNode = dependencyGraph.nodes?.find((entry) => entry.id === "source:Shared.Lead");
if (entryDependencyNode?.moduleId !== "module:Main" || entryDependencyNode?.role !== "entry") {
  throw new Error("dependencyGraph missing stable Main source-module node");
}
if (sharedDependencyNode?.moduleId !== "module:Shared.Lead" || sharedDependencyNode?.role !== "import") {
  throw new Error("dependencyGraph missing stable imported Shared.Lead source-module node");
}
if (!entryDependencyNode.imports?.includes("Shared.Lead")) {
  throw new Error("dependencyGraph Main source-module node missing Shared.Lead import");
}
const hasSharedImportEdge = dependencyGraph.edges?.some(
  (edge) => edge.kind === "imports" && edge.from === "source:Main" && edge.to === "source:Shared.Lead",
);
if (!hasSharedImportEdge) {
  throw new Error("dependencyGraph missing Main -> Shared.Lead import edge");
}
for (const expectedSchema of ["schema:LeadIntake", "schema:LeadRecord"]) {
  if (!sharedDependencyNode.affectedSchemas?.includes(expectedSchema)) {
    throw new Error(`dependencyGraph imported module affectedSchemas missing ${expectedSchema}`);
  }
}
for (const expectedRoute of ["route:createLeadRecordRoute", "route:createLeadRoute"]) {
  if (!sharedDependencyNode.affectedRoutes?.includes(expectedRoute)) {
    throw new Error(`dependencyGraph imported module affectedRoutes missing ${expectedRoute}`);
  }
  const hasAffectsEdge = dependencyGraph.edges?.some(
    (edge) => edge.kind === "affects" && edge.from === "source:Shared.Lead" && edge.to === expectedRoute,
  );
  if (!hasAffectsEdge) {
    throw new Error(`dependencyGraph missing Shared.Lead affects edge to ${expectedRoute}`);
  }
}
for (const expectedForeign of ["foreign:storeLead", "foreign:mockLeadSummaryModel"]) {
  if (!sharedDependencyNode.affectedForeignBoundaries?.includes(expectedForeign)) {
    throw new Error(`dependencyGraph imported module affectedForeignBoundaries missing ${expectedForeign}`);
  }
}
const route = graph.surfaceIndex?.routes?.find((entry) => entry.name === "createLeadRecordRoute");
if (!route) {
  throw new Error("missing createLeadRecordRoute in lead-app context");
}
const leadIntakeSchema = graph.surfaceIndex?.schemas?.find((entry) => entry.id === "schema:LeadIntake");
if (!leadIntakeSchema) {
  throw new Error("missing imported LeadIntake in lead-app surfaceIndex.schemas");
}
for (const [fieldId, expectedType] of [
  ["schema-field:LeadIntake:company", "Str"],
  ["schema-field:LeadIntake:contact", "Str"],
  ["schema-field:LeadIntake:budget", "Int"],
  ["schema-field:LeadIntake:segment", "LeadSegment"],
]) {
  const field = leadIntakeSchema.fields?.find((entry) => entry.id === fieldId);
  if (field?.type !== expectedType) {
    throw new Error(`LeadIntake field ${fieldId} expected ${expectedType}, got ${field?.type}`);
  }
}
const leadIntakeSegment = graph.surfaceIndex?.schemaFields?.find((entry) => entry.id === "schema-field:LeadIntake:segment");
if (!leadIntakeSegment?.referencedTypes?.includes("type:LeadSegment")) {
  throw new Error("LeadIntake segment field missing LeadSegment type reference");
}
const leadRecordSchema = graph.surfaceIndex?.schemas?.find((entry) => entry.id === "schema:LeadRecord");
if (!leadRecordSchema?.fieldIds?.includes("schema-field:LeadRecord:reviewStatus")) {
  throw new Error("missing imported LeadRecord fields in surfaceIndex.schemas");
}
for (const [schema, expectedRoute] of [
  [leadIntakeSchema, "route:createLeadRecordRoute"],
  [leadRecordSchema, "route:createLeadRecordRoute"],
]) {
  if (!schema?.affectedRoutes?.includes(expectedRoute)) {
    throw new Error(`${schema?.id} missing affected route ${expectedRoute}`);
  }
}
for (const expectedForeign of ["foreign:storeLead", "foreign:mockLeadSummaryModel"]) {
  if (!leadIntakeSchema.affectedForeignBoundaries?.includes(expectedForeign)) {
    throw new Error(`LeadIntake missing affected foreign boundary ${expectedForeign}`);
  }
}
const leadSegmentType = graph.surfaceIndex?.types?.find((entry) => entry.id === "type:LeadSegment");
if (!leadSegmentType) {
  throw new Error("missing imported LeadSegment in lead-app surfaceIndex.types");
}
for (const constructorName of ["Startup", "Growth", "Enterprise"]) {
  if (!leadSegmentType.wireConstructorNames?.includes(constructorName)) {
    throw new Error(`LeadSegment missing wire constructor ${constructorName}`);
  }
}
if (!leadSegmentType.affectedSchemas?.includes("schema:LeadIntake") || !leadSegmentType.affectedRoutes?.includes("route:createLeadRecordRoute")) {
  throw new Error("LeadSegment type missing schema/route impact links");
}
for (const [field, expected] of [
  ["requestSchemaId", "schema:LeadIntake"],
  ["responseSchemaId", "schema:LeadRecord"],
  ["handlerId", "decl:createLead"],
]) {
  if (route[field] !== expected) {
    throw new Error(`lead-app route ${field} expected ${expected}, got ${route[field]}`);
  }
}
for (const expectedSurface of [
  "route:createLeadRecordRoute",
  "schema:LeadIntake",
  "schema:LeadRecord",
  "decl:createLead",
  "decl:summarizeLead",
  "foreign:storeLead",
  "foreign:mockLeadSummaryModel",
]) {
  if (!route.affectedSurfaces?.includes(expectedSurface)) {
    throw new Error(`lead-app route affected surfaces missing ${expectedSurface}`);
  }
}
for (const expectedForeign of ["foreign:storeLead", "foreign:mockLeadSummaryModel"]) {
  if (!route.affectedForeignBoundaries?.includes(expectedForeign)) {
    throw new Error(`lead-app route affected foreign boundaries missing ${expectedForeign}`);
  }
}
if (!route.verificationGuidance?.scenarioCommands?.includes("bash examples/lead-app/scripts/verify.sh")) {
  throw new Error("lead-app route missing scenario test guidance");
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
