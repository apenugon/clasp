#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workspace_root="$project_root/benchmarks/workspaces/task-prep-check"
results_root="$project_root/benchmarks/results"

export CLASP_BENCHMARK_NPM_INSTALL_CACHE_ROOT="${CLASP_BENCHMARK_NPM_INSTALL_CACHE_ROOT:-$project_root/.clasp-verify/cache/benchmark-npm-install}"
export CLASP_BENCHMARK_NPM_INSTALL_CACHE_MODE="${CLASP_BENCHMARK_NPM_INSTALL_CACHE_MODE:-link}"
export CLASP_BENCHMARK_PREP_COMPILER_FINGERPRINT_CACHE="${CLASP_BENCHMARK_PREP_COMPILER_FINGERPRINT_CACHE:-$project_root/.clasp-verify/cache/benchmark-prep-compiler-fingerprint-v1.json}"
export CLASP_BENCHMARK_PREP_CACHE_MODE="${CLASP_BENCHMARK_PREP_CACHE_MODE:-link}"

mkdir -p "$workspace_root"

list_output="$(node "$project_root/benchmarks/run-benchmark.mjs" list)"
grep -q '^ts-lead-segment[[:space:]]' <<<"$list_output"
grep -q '^ts-lead-persistence[[:space:]]' <<<"$list_output"
grep -q '^clasp-lead-segment[[:space:]]' <<<"$list_output"
grep -q '^ts-lead-rejection[[:space:]]' <<<"$list_output"
grep -q '^clasp-lead-rejection[[:space:]]' <<<"$list_output"
grep -q '^ts-control-plane[[:space:]]' <<<"$list_output"
grep -q '^clasp-control-plane[[:space:]]' <<<"$list_output"
grep -q '^py-agent-escalation[[:space:]]' <<<"$list_output"
grep -q '^clasp-durable-workflow[[:space:]]' <<<"$list_output"
grep -q '^clasp-workflow-correctness[[:space:]]' <<<"$list_output"
grep -q '^clasp-external-adaptation[[:space:]]' <<<"$list_output"
grep -q '^clasp-legal-assistant-appbench[[:space:]]' <<<"$list_output"
grep -q '^ts-external-adaptation[[:space:]]' <<<"$list_output"
grep -q '^clasp-npm-interop[[:space:]]' <<<"$list_output"
grep -q '^ts-npm-interop[[:space:]]' <<<"$list_output"
grep -q '^clasp-python-interop[[:space:]]' <<<"$list_output"
grep -q '^ts-python-interop[[:space:]]' <<<"$list_output"
grep -q '^clasp-rust-interop[[:space:]]' <<<"$list_output"
grep -q '^ts-rust-interop[[:space:]]' <<<"$list_output"
grep -q '^clasp-interop-boundary[[:space:]]' <<<"$list_output"
grep -q '^ts-interop-boundary[[:space:]]' <<<"$list_output"
grep -q '^clasp-secret-handling[[:space:]]' <<<"$list_output"
grep -q '^ts-secret-handling[[:space:]]' <<<"$list_output"
grep -q '^clasp-authorization-data-access[[:space:]]' <<<"$list_output"
grep -q '^ts-authorization-data-access[[:space:]]' <<<"$list_output"
grep -q '^clasp-audit-log[[:space:]]' <<<"$list_output"
grep -q '^ts-audit-log[[:space:]]' <<<"$list_output"
grep -q '^clasp-compiler-maintenance[[:space:]]' <<<"$list_output"
grep -q '^clasp-syntax-compact[[:space:]]' <<<"$list_output"
grep -q '^clasp-syntax-verbose[[:space:]]' <<<"$list_output"

check_incomplete_task() {
  local task_id="$1"
  local workspace="$workspace_root/$task_id"
  local recovery_args=()

  if [[ "$task_id" == clasp-* ]]; then
    recovery_args=(--allow-bootstrap-recovery true)
  fi

  if [[ "${#recovery_args[@]}" -gt 0 ]]; then
    run_benchmark_prepare "$task_id" "$workspace" "${recovery_args[@]}" >/dev/null
  else
    run_benchmark_prepare "$task_id" "$workspace" >/dev/null
  fi

  if [[ "${#recovery_args[@]}" -gt 0 ]]; then
    return 0
  elif run_benchmark_verify "$task_id" "$workspace" --harness prep-check --model local >/dev/null 2>&1; then
    echo "expected $task_id to fail verification before the benchmark change is applied" >&2
    return 1
  fi
}

assert_contains() {
  local file="$1"
  local pattern="$2"

  if ! grep -Fq "$pattern" "$file"; then
    echo "expected $file to contain: $pattern" >&2
    return 1
  fi
}

assert_not_contains() {
  local file="$1"
  local pattern="$2"

  if grep -Fq "$pattern" "$file"; then
    echo "expected $file to omit: $pattern" >&2
    return 1
  fi
}

assert_contains "$project_root/benchmarks/run-benchmark.mjs" 'env.CLASP_CLASPC || env.CLASPC_BIN'
assert_not_contains "$project_root/benchmarks/run-benchmark.mjs" 'unset CLASP_CLASPC CLASPC_BIN'

assert_files_match() {
  local left="$1"
  local right="$2"

  if ! cmp -s "$left" "$right"; then
    echo "expected $left to match $right" >&2
    return 1
  fi
}

assert_file_exists() {
  local target="$1"

  if [[ ! -f "$target" ]]; then
    echo "expected file to exist: $target" >&2
    return 1
  fi
}

latest_result_for_harness() {
  local harness="$1"
  local latest_result=""
  local latest_mtime=0
  local stat_format=()

  if stat -c '%Y' "$results_root" >/dev/null 2>&1; then
    stat_format=(-c '%Y')
  else
    stat_format=(-f '%m')
  fi

  for candidate in "$results_root"/*--"$harness".json; do
    [[ -e "$candidate" ]] || continue
    local candidate_mtime
    candidate_mtime="$(stat "${stat_format[@]}" "$candidate")"
    if [[ -z "$latest_result" || "$candidate_mtime" -gt "$latest_mtime" ]]; then
      latest_result="$candidate"
      latest_mtime="$candidate_mtime"
    fi
  done

  if [[ -z "$latest_result" ]]; then
    echo "expected at least one benchmark result artifact for harness $harness" >&2
    return 1
  fi

  printf '%s\n' "$latest_result"
}

run_benchmark_prepare() {
  local task_id="$1"
  local workspace="$2"
  shift 2

  node "$project_root/benchmarks/run-benchmark.mjs" prepare "$task_id" --workspace "$workspace" "$@"
}

run_benchmark_verify() {
  local task_id="$1"
  local workspace="$2"
  shift 2

  node "$project_root/benchmarks/run-benchmark.mjs" verify "$task_id" --workspace "$workspace" "$@"
}

run_clasp_backend_static_verify() {
  local workspace="$1"
  shift || true

  bash "$project_root/benchmarks/verify-clasp-backend-check.sh" "$workspace" "$@"
}

check_pristine_task_fails_verification() {
  local task_id="$1"
  local workspace="$workspace_root/$task_id-pristine-fails"
  shift || true

  run_benchmark_prepare "$task_id" "$workspace" "$@" >/dev/null

  if run_benchmark_verify "$task_id" "$workspace" --harness prep-check --model local >/dev/null 2>&1; then
    echo "expected $task_id to fail verification before the benchmark change is applied" >&2
    return 1
  fi
}

check_default_clasp_benchmark_path_requires_recovery() {
  local task_id="clasp-secret-handling"
  local workspace="$workspace_root/$task_id-default-blocked"
  local output

  if output="$(run_benchmark_prepare "$task_id" "$workspace" 2>&1)"; then
    echo "expected $task_id default prepare to require explicit bootstrap recovery" >&2
    return 1
  fi

  grep -Fq 'rerun with --allow-bootstrap-recovery true' <<<"$output"
}

check_default_public_app_benchmark_path_supported() {
  local bundle_path="$workspace_root/public-app-default-path.bundle.json"

  rm -f "$bundle_path"
  node "$project_root/benchmarks/run-benchmark.mjs" freeze app \
    --count 1 \
    --notes default-path-check \
    --output "$bundle_path" >/dev/null

  assert_file_exists "$bundle_path"
  assert_contains "$bundle_path" '"taskSelection": "app"'
  assert_contains "$bundle_path" '"taskId": "clasp-lead-priority"'
  assert_contains "$bundle_path" '"taskId": "clasp-lead-rejection"'
  assert_contains "$bundle_path" '"taskId": "clasp-lead-segment"'
  assert_contains "$bundle_path" '"taskId": "clasp-external-adaptation"'
  assert_contains "$bundle_path" '"taskId": "clasp-legal-assistant-appbench"'
}

check_fixture_seed_override() {
  local task_id="fixture-seed-env-check"
  local task_dir="$project_root/benchmarks/tasks/$task_id"
  local override_workspace="$workspace_root/$task_id-override"
  local fallback_workspace="$workspace_root/$task_id-fallback"

  rm -rf "$task_dir" "$override_workspace" "$fallback_workspace"
  mkdir -p "$task_dir/repo"

  cat <<'JSON' >"$task_dir/task.json"
{
  "id": "fixture-seed-env-check",
  "title": "Fixture seed env check",
  "suite": "harness-regression",
  "language": "typescript",
  "repo": "repo",
  "prompt": "prompt.md",
  "prepare": [
    ["node", "-e", "const fs = require('node:fs'); fs.writeFileSync('prepare-seed.txt', `${process.env.CLASP_APP_FIXTURE_SEED}\\n`, 'utf8');"]
  ],
  "verify": ["node", "-e", "const fs = require('node:fs'); fs.writeFileSync('verify-seed.txt', `${process.env.CLASP_APP_FIXTURE_SEED}\\n`, 'utf8'); const expected = fs.readFileSync('expected-seed.txt', 'utf8').trim(); process.exit(process.env.CLASP_APP_FIXTURE_SEED === expected ? 0 : 1);"]
}
JSON

  cat <<'EOF' >"$task_dir/prompt.md"
Fixture seed env regression.
EOF

  cat <<'EOF' >"$task_dir/repo/expected-seed.txt"
override-seed
EOF

  CLASP_APP_FIXTURE_SEED="override-seed" \
  run_benchmark_prepare "$task_id" "$override_workspace" >/dev/null
  assert_contains "$override_workspace/prepare-seed.txt" "override-seed"

  CLASP_APP_FIXTURE_SEED="override-seed" \
    run_benchmark_verify "$task_id" "$override_workspace" --harness prep-check --model local >/dev/null
  assert_contains "$override_workspace/verify-seed.txt" "override-seed"

  printf '%s\n' "$task_id" >"$task_dir/repo/expected-seed.txt"
  CLASP_APP_FIXTURE_SEED="" \
    run_benchmark_prepare "$task_id" "$fallback_workspace" >/dev/null
  assert_contains "$fallback_workspace/prepare-seed.txt" "$task_id"

  CLASP_APP_FIXTURE_SEED="" \
    run_benchmark_verify "$task_id" "$fallback_workspace" --harness prep-check --model local >/dev/null
  assert_contains "$fallback_workspace/verify-seed.txt" "$task_id"

  rm -rf "$task_dir" "$override_workspace" "$fallback_workspace"
}

check_product_only_clasp_solution() {
  local task_id="clasp-lead-segment"
  local workspace="$workspace_root/$task_id-product-only"
  local task_root="$project_root/benchmarks/tasks/$task_id/repo"

  run_benchmark_prepare "$task_id" "$workspace" --allow-bootstrap-recovery true >/dev/null

  cp "$project_root/examples/lead-app/Shared/Lead.clasp" "$workspace/Shared/Lead.clasp"

  run_benchmark_verify "$task_id" "$workspace" --harness prep-check --model local >/dev/null

  if [[ -e "$workspace/server.mjs" ]]; then
    echo "expected $workspace/server.mjs to be omitted from native benchmark workspaces" >&2
    exit 1
  fi
  assert_files_match "$workspace/Main.clasp" "$task_root/Main.clasp"
  assert_files_match "$workspace/scripts/verify.sh" "$task_root/scripts/verify.sh"
  assert_files_match "$workspace/test/lead-app.test.mjs" "$task_root/test/lead-app.test.mjs"
  assert_files_match "$workspace/test/native-http-test.mjs" "$task_root/test/native-http-test.mjs"
}

check_product_only_typescript_solution() {
  local task_id="ts-lead-segment"
  local workspace="$workspace_root/$task_id-product-only"
  local task_root="$project_root/benchmarks/tasks/$task_id/repo"

  run_benchmark_prepare "$task_id" "$workspace" >/dev/null

  cp "$project_root/examples/lead-app-ts/src/shared/lead.ts" "$workspace/src/shared/lead.ts"

  run_benchmark_verify "$task_id" "$workspace" --harness prep-check --model local >/dev/null

  if [[ -e "$workspace/src/server/store.ts" ]]; then
    echo "expected $workspace/src/server/store.ts to be omitted from the lead-segment workspace" >&2
    exit 1
  fi
  assert_files_match "$workspace/src/server/main.ts" "$task_root/src/server/main.ts"
  assert_files_match "$workspace/src/server/runtime.ts" "$task_root/src/server/runtime.ts"
  assert_files_match "$workspace/src/server/dev.ts" "$task_root/src/server/dev.ts"
  assert_files_match "$workspace/scripts/verify.sh" "$task_root/scripts/verify.sh"
  assert_files_match "$workspace/test/lead-app.test.mjs" "$task_root/test/lead-app.test.mjs"
}

check_lead_segment_acceptance_surface() {
  local clasp_test="$project_root/benchmarks/tasks/clasp-lead-segment/repo/test/lead-app.test.mjs"
  local ts_test="$project_root/benchmarks/tasks/ts-lead-segment/repo/test/lead-app.test.mjs"

  for test_file in "$clasp_test" "$ts_test"; do
    assert_contains "$test_file" "Segment: enterprise"
    assert_contains "$test_file" "segment must be one of: startup, growth, enterprise"
    assert_contains "$test_file" "priority must be one of: low, medium, high"
    assert_contains "$test_file" "Ready for product demo next week."
  done

  assert_contains "$clasp_test" 'formFieldNames(landingPage.body), ["company", "contact", "budget", "segment"]'
  assert_contains "$clasp_test" "SynthSpeak (high, enterprise)"
  assert_contains "$clasp_test" "CLASP_MOCK_LEAD_SUMMARY_SEGMENT"
  assert_contains "$ts_test" 'assert.match(landingHtml, /name="segment"/);'
  assert_contains "$ts_test" 'SynthSpeak \(high, enterprise\)'
  assert_contains "$ts_test" 'segment: "global-5000"'
}

check_lead_host_binding_manifest() {
  local example_manifest="$project_root/examples/lead-app/host-bindings.manifest.json"
  local task_manifest="$project_root/benchmarks/tasks/clasp-lead-segment/host-bindings.manifest.json"
  local workspace="$workspace_root/clasp-lead-segment"
  local workspace_manifest="$workspace/benchmark-prep/host-bindings.manifest.json"
  local workspace_context="$workspace/benchmark-prep/Main.context.json"
  local workspace_air="$workspace/benchmark-prep/Main.air.json"
  local workspace_surfaces="$workspace/benchmark-prep/Main.surfaces.json"
  local workspace_agent_pack="$workspace/benchmark-prep/Main.agent-pack.json"
  local workspace_test="$workspace/test/lead-app.test.mjs"

  assert_file_exists "$example_manifest"
  assert_file_exists "$task_manifest"
  assert_file_exists "$workspace_manifest"
  assert_file_exists "$workspace_context"
  assert_file_exists "$workspace_air"
  assert_file_exists "$workspace_surfaces"
  assert_file_exists "$workspace_agent_pack"
  assert_files_match "$example_manifest" "$task_manifest"
  assert_files_match "$task_manifest" "$workspace_manifest"
  assert_contains "$workspace/LANGUAGE_GUIDE.md" '`benchmark-prep/host-bindings.manifest.json`'
  assert_contains "$workspace/LANGUAGE_GUIDE.md" '`benchmark-prep/Main.surfaces.json`'
  assert_contains "$workspace/LANGUAGE_GUIDE.md" '`benchmark-prep/Main.agent-pack.json`'
  assert_contains "$workspace/LANGUAGE_GUIDE.md" 'semanticIndex.entries'
  assert_contains "$workspace/LANGUAGE_GUIDE.md" 'App-owned edit surface'
  assert_contains "$workspace/LANGUAGE_GUIDE.md" '`Shared/Lead.clasp`'
  assert_contains "$workspace/LANGUAGE_GUIDE.md" 'route host inputs, host/runtime binding contracts, model JSON shapes, and runtime-owned failure behavior'
  assert_contains "$workspace/LANGUAGE_GUIDE.md" 'joins compiler context/AIR, surface index entries, app-owned edit files, host contracts, contract gaps, and verifier commands'

  node - "$workspace_manifest" "$workspace_test" "$workspace_surfaces" "$workspace_context" "$workspace_air" "$workspace_agent_pack" <<'EOF'
const assert = require("node:assert/strict");
const fs = require("node:fs");

const [manifestPath, testPath, surfacesPath, contextPath, airPath, agentPackPath] = process.argv.slice(2);
const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
const testSource = fs.readFileSync(testPath, "utf8");
const surfaces = JSON.parse(fs.readFileSync(surfacesPath, "utf8"));
const context = JSON.parse(fs.readFileSync(contextPath, "utf8"));
const air = JSON.parse(fs.readFileSync(airPath, "utf8"));
const agentPack = JSON.parse(fs.readFileSync(agentPackPath, "utf8"));

assert.equal(manifest.format, "clasp-lead-host-bindings-v1");
assert.equal(manifest.scope.benchmarkTask, "clasp-lead-segment");
assert.equal(context.format, "clasp-context-v1");
assert.equal(air.format, "clasp-air-v1");
assert.equal(surfaces.format, "clasp-benchmark-surfaces-v1");
assert.equal(agentPack.format, "clasp-benchmark-agent-pack-v1");
assert.deepEqual(surfaces.appOwnedEditSurface, ["Shared/Lead.clasp"]);
assert.ok(
  surfaces.sourceModules.some(
    (sourceModule) =>
      sourceModule.path === "Shared/Lead.clasp" &&
      sourceModule.role === "app-owned-edit-surface"
  ),
  "semantic surfaces should mark Shared/Lead.clasp as the app-owned edit surface"
);
assert.equal(surfaces.artifacts.hostBindingManifest, "benchmark-prep/host-bindings.manifest.json");
assert.equal(surfaces.artifacts.agentPack, "benchmark-prep/Main.agent-pack.json");
assert.equal(surfaces.artifacts.surfaces, "benchmark-prep/Main.surfaces.json");

assert.equal(agentPack.task.id, "clasp-lead-segment");
assert.equal(agentPack.task.entry, "Main.clasp");
assert.deepEqual(agentPack.task.verifierCommand, ["bash", "scripts/verify.sh"]);
assert.equal(agentPack.artifacts.context, "benchmark-prep/Main.context.json");
assert.equal(agentPack.artifacts.air, "benchmark-prep/Main.air.json");
assert.equal(agentPack.artifacts.surfaces, "benchmark-prep/Main.surfaces.json");
assert.equal(agentPack.artifacts.hostBindingManifest, "benchmark-prep/host-bindings.manifest.json");
assert.deepEqual(agentPack.editTargets.primary, ["Shared/Lead.clasp"]);
assert.ok(
  agentPack.editTargets.sourceModules.some(
    (sourceModule) =>
      sourceModule.path === "Shared/Lead.clasp" &&
      sourceModule.role === "app-owned-edit-surface" &&
      sourceModule.sourceId === "source:Shared.Lead"
  ),
  "agent pack should point agents at the app-owned Shared/Lead.clasp source module"
);
assert.ok(Array.isArray(agentPack.semanticIndex?.entries), "agent pack should expose semantic index entries");
const leadSchemaIndex = agentPack.semanticIndex.entries.find((entry) => entry.id === "schema:LeadIntake");
assert.ok(leadSchemaIndex, "semantic index should include LeadIntake schema");
assert.ok(
  leadSchemaIndex.editFiles?.includes("Shared/Lead.clasp"),
  "LeadIntake semantic index entry should point to the app-owned edit file"
);
assert.ok(
  leadSchemaIndex.queryText.includes("company:Str") &&
    leadSchemaIndex.artifactRefs?.includes("benchmark-prep/Main.context.json"),
  "LeadIntake semantic index entry should be searchable and artifact-backed"
);
const sharedLeadIndex = agentPack.semanticIndex.byEditFile.find((entry) => entry.path === "Shared/Lead.clasp");
assert.ok(sharedLeadIndex?.entryIds.includes("schema:LeadIntake"), "semantic index should map Shared/Lead.clasp to LeadIntake");
assert.ok(
  agentPack.compilerContext.surfaceIndex.routes.includes("route:createLeadRoute"),
  "agent pack should retain compiler-owned surfaceIndex route ids"
);
assert.ok(
  agentPack.compilerContext.airNodes.some(
    (node) => node.id === "record:LeadIntake" && node.kind === "record"
  ),
  "agent pack should include relevant AIR nodes, not just docs"
);

assert.ok(
  context.sourceModules.some(
    (sourceModule) =>
      sourceModule.sourceId === "source:Main" &&
      sourceModule.moduleId === "module:Main" &&
      sourceModule.moduleName === "Main" &&
      sourceModule.role === "entry" &&
      sourceModule.foreignBoundaries.includes("foreign:storeLead")
  ),
  "compiler-owned context should include the entry source module identity"
);
assert.ok(
  context.sourceModules.some(
    (sourceModule) =>
      sourceModule.sourceId === "source:Shared.Lead" &&
      sourceModule.moduleId === "module:Shared.Lead" &&
      sourceModule.moduleName === "Shared.Lead" &&
      sourceModule.role === "import" &&
      sourceModule.schemas.includes("schema:LeadIntake")
  ),
  "compiler-owned context should include imported source module identities"
);

const compilerRoute = context.surfaceIndex.routes.find(
  (route) => route.id === "route:createLeadRoute"
);
assert.ok(compilerRoute, "compiler-owned context missing createLeadRoute surface");
assert.equal(compilerRoute.method, "POST");
assert.equal(compilerRoute.path, "/leads");
assert.equal(compilerRoute.requestSchemaId, "schema:LeadIntake");
assert.ok(
  compilerRoute.affectedSurfaces.includes("route:createLeadRoute") &&
    compilerRoute.affectedSurfaces.includes("schema:LeadIntake") &&
    compilerRoute.affectedSurfaces.includes("foreign:storeLead"),
  "compiler-owned route surface should expose affected route, schema, and host binding surfaces"
);
assert.deepEqual(compilerRoute.affectedRoutes, ["route:createLeadRoute"]);
assert.ok(
  compilerRoute.affectedForeignBoundaries.includes("foreign:storeLead"),
  "compiler-owned route surface should reference host-binding boundaries"
);
assert.ok(
  context.surfaceIndex.foreignBoundaries.some(
    (boundary) =>
      boundary.id === "foreign:storeLead" &&
      boundary.runtimeName === "storeLead" &&
      boundary.type === "LeadIntake -> LeadSummary -> Str"
  ),
  "compiler-owned context should expose host-binding references"
);
assert.ok(
  air.nodes.some((node) => node.id === "route:createLeadRoute" && node.kind === "route"),
  "compiler-owned AIR should expose route nodes"
);
assert.ok(
  air.nodes.some((node) => node.id === "record:LeadIntake" && node.kind === "record"),
  "compiler-owned AIR should expose source record nodes"
);

const packCreateRoute = agentPack.surfaces.routes.find(
  (route) => route.name === "createLeadRoute"
);
assert.ok(packCreateRoute, "agent pack missing createLeadRoute action route");
assert.equal(packCreateRoute.method, "POST");
assert.equal(packCreateRoute.path, "/leads");
assert.equal(packCreateRoute.requestSchemaId, "schema:LeadIntake");
assert.ok(packCreateRoute.affectedSurfaces.includes("foreign:storeLead"));

const createRoute = manifest.routeHostInputs.find(
  (route) => route.method === "POST" && route.path === "/leads"
);
assert.ok(createRoute, "missing POST /leads route input contract");
assert.equal(createRoute.requestType, "LeadIntake");
assert.deepEqual(
  createRoute.hostInput.fields.map((field) => `${field.name}:${field.type}`),
  ["company:Str", "contact:Str", "budget:Int", "segment:LeadSegment"]
);
assert.deepEqual(
  createRoute.hostInput.fields.find((field) => field.name === "segment").wireValues,
  ["startup", "growth", "enterprise"]
);
assert.ok(
  createRoute.runtimeOwnedFailures.some(
    (failure) =>
      failure.status === 400 &&
      failure.phase === "request_boundary" &&
      failure.body === "segment must be one of: startup, growth, enterprise"
  ),
  "missing request-boundary segment failure contract"
);

const createSurfaceRoute = surfaces.routes.find(
  (route) => route.method === "POST" && route.path === "/leads"
);
assert.ok(createSurfaceRoute, "semantic surfaces missing POST /leads route");
assert.equal(createSurfaceRoute.requestType, "LeadIntake");
assert.equal(createSurfaceRoute.responseType, "Page");
assert.equal(createSurfaceRoute.handler, "createLeadPage");
assert.equal(createSurfaceRoute.requestDecoder, "$decode_LeadIntake");
assert.deepEqual(
  createSurfaceRoute.hostInput.fields.map((field) => `${field.name}:${field.type}`),
  ["company:Str", "contact:Str", "budget:Int", "segment:LeadSegment"]
);

const createForm = surfaces.forms.find(
  (form) => form.method === "POST" && form.action === "/leads"
);
assert.ok(createForm, "semantic surfaces missing POST /leads form");
assert.deepEqual(
  createForm.fields.map((field) => `${field.name}:${field.inputType}`),
  ["company:text", "contact:text", "budget:number"]
);
assert.deepEqual(
  createForm.expectedHostFields.map((field) => `${field.name}:${field.type}`),
  ["company:Str", "contact:Str", "budget:Int", "segment:LeadSegment"]
);
assert.ok(
  agentPack.surfaces.forms.some(
    (form) =>
      form.action === "/leads" &&
      form.expectedHostFields.some((field) => field.name === "segment" && field.type === "LeadSegment")
  ),
  "agent pack should expose the expected segment form/input contract"
);
assert.ok(
  surfaces.pages.some(
    (page) => page.routeName === "createLeadRoute" && page.path === "/leads"
  ),
  "semantic surfaces should expose page routes"
);
assert.ok(
  agentPack.surfaces.pages.some(
    (page) => page.routeName === "createLeadRoute" && page.path === "/leads"
  ),
  "agent pack should expose page routes"
);
assert.ok(
  surfaces.decodeBoundaries.some(
    (boundary) =>
      boundary.decl === "summarizeLead" &&
      boundary.targetType === "LeadSummary" &&
      boundary.sourceCallee === "mockLeadSummaryModel"
  ),
  "semantic surfaces should expose the model decode boundary"
);
assert.ok(
  surfaces.decodeBoundaries.some(
    (boundary) =>
      boundary.decl === "createLead" &&
      boundary.targetType === "LeadRecord" &&
      boundary.sourceCallee === "storeLead"
  ),
  "semantic surfaces should expose the host storage decode boundary"
);

const mockModel = manifest.mockModelCalls.find(
  (binding) => binding.name === "mockLeadSummaryModel"
);
assert.ok(mockModel, "missing mockLeadSummaryModel contract");
assert.equal(mockModel.signature, "LeadIntake -> Str");
assert.equal(mockModel.expectedJsonShape, "LeadSummary");
assert.ok(
  mockModel.runtimeOwnedFailures.some(
    (failure) =>
      failure.status === 502 &&
      failure.phase === "model_boundary" &&
      failure.body === "segment must be one of: startup, growth, enterprise"
  ),
  "missing model-boundary segment failure contract"
);
assert.ok(
  surfaces.hostBindings.some(
    (binding) =>
      binding.name === "mockLeadSummaryModel" &&
      binding.role === "mock-model" &&
      binding.expectedJsonShape === "LeadSummary"
  ),
  "semantic surfaces should expose mock model host binding"
);
assert.ok(
  surfaces.hostBindings.some(
    (binding) =>
      binding.name === "storeLead" &&
      binding.role === "host-binding" &&
      binding.decodedAs === "LeadRecord"
  ),
  "semantic surfaces should expose storage host binding"
);
assert.ok(
  agentPack.surfaces.boundaries.some(
    (boundary) =>
      boundary.name === "mockLeadSummaryModel" &&
      boundary.boundaryKind === "model" &&
      boundary.expectedJsonShape === "LeadSummary"
  ),
  "agent pack should classify model host boundaries"
);
assert.ok(
  agentPack.surfaces.boundaries.some(
    (boundary) =>
      boundary.name === "storeLead" &&
      boundary.boundaryKind === "storage" &&
      boundary.decodedAs === "LeadRecord"
  ),
  "agent pack should classify storage host boundaries"
);

assert.deepEqual(
  manifest.expectedJsonShapes.LeadIntake.fields.map((field) => `${field.name}:${field.type}`),
  ["company:Str", "contact:Str", "budget:Int", "segment:LeadSegment"]
);
assert.deepEqual(
  manifest.expectedJsonShapes.LeadSummary.fields.map((field) => `${field.name}:${field.type}`),
  ["summary:Str", "priority:LeadPriority", "segment:LeadSegment", "followUpRequired:Bool"]
);
assert.deepEqual(
  manifest.expectedJsonShapes.LeadRecord.fields.map((field) => `${field.name}:${field.type}`),
  [
    "leadId:Str",
    "company:Str",
    "contact:Str",
    "summary:Str",
    "priority:LeadPriority",
    "segment:LeadSegment",
    "followUpRequired:Bool",
    "reviewStatus:ReviewStatus",
    "reviewNote:Str"
  ]
);
assert.deepEqual(
  surfaces.records.find((record) => record.name === "LeadIntake").fields.map((field) => `${field.name}:${field.type}`),
  ["company:Str", "contact:Str", "budget:Int"]
);
assert.deepEqual(
  surfaces.expectedJsonShapes.LeadIntake.fields.map((field) => `${field.name}:${field.type}`),
  ["company:Str", "contact:Str", "budget:Int", "segment:LeadSegment"]
);
assert.ok(
  surfaces.contractGaps.some(
    (gap) =>
      gap.kind === "missing-field" &&
      gap.schema === "LeadIntake" &&
      gap.field === "segment" &&
      gap.expected === "LeadSegment"
  ),
  "semantic surfaces should identify the missing segment field"
);
assert.ok(
  agentPack.surfaces.schemas.some(
    (schema) =>
      schema.name === "LeadIntake" &&
      schema.present === true &&
      schema.missingFields.some((field) => field.name === "segment" && field.expected === "LeadSegment")
  ),
  "agent pack should attach missing segment fields to the LeadIntake schema"
);
assert.ok(
  surfaces.contractGaps.some(
    (gap) =>
      gap.kind === "missing-schema" &&
      gap.schema === "LeadSegment" &&
      gap.expected === "enum"
  ),
  "semantic surfaces should identify the missing LeadSegment enum"
);
assert.ok(
  agentPack.surfaces.types.some(
    (typeSurface) =>
      typeSurface.name === "LeadSegment" &&
      typeSurface.present === false &&
      typeSurface.expectedWireValues.includes("enterprise")
  ),
  "agent pack should expose the missing LeadSegment enum contract"
);
assert.ok(
  agentPack.actionItems.some(
    (item) =>
      item.kind === "close-contract-gap" &&
      item.schema === "LeadIntake" &&
      item.field === "segment" &&
      item.editFiles.includes("Shared/Lead.clasp") &&
      item.verifierCommand.join(" ") === "bash scripts/verify.sh"
  ),
  "agent pack should make contract gaps directly actionable"
);
assert.ok(
  agentPack.verifier.scenarioSignals.some(
    (signal) => signal.file === "test/lead-app.test.mjs" && signal.asserts.includes("segment")
  ),
  "agent pack should carry scenario-level acceptance signals"
);

assert.match(testSource, /formFieldNames\(landingPage\.body\), \["company", "contact", "budget", "segment"\]/);
assert.match(testSource, /Segment: enterprise/);
assert.match(testSource, /segment must be one of: startup, growth, enterprise/);
assert.match(testSource, /CLASP_MOCK_LEAD_SUMMARY_SEGMENT/);
EOF
}

check_product_only_typescript_persistence_solution() {
  local task_id="ts-lead-persistence"
  local workspace="$workspace_root/$task_id-product-only"
  local task_root="$project_root/benchmarks/tasks/$task_id/repo"

  run_benchmark_prepare "$task_id" "$workspace" >/dev/null

  cp "$project_root/examples/lead-app-ts/src/server/main.ts" "$workspace/src/server/main.ts"
  cp "$project_root/examples/lead-app-ts/src/server/store.ts" "$workspace/src/server/store.ts"
  cp "$project_root/examples/lead-app-ts/src/server/runtime-modules.d.ts" "$workspace/src/server/runtime-modules.d.ts"
  cp "$project_root/examples/lead-app-ts/src/server/dev.ts" "$workspace/src/server/dev.ts"

  run_benchmark_verify "$task_id" "$workspace" --harness prep-check --model local >/dev/null

  assert_files_match "$workspace/test/lead-app.test.mjs" "$task_root/test/lead-app.test.mjs"
}

check_product_only_clasp_workflow_correctness_solution() {
  local task_id="clasp-workflow-correctness"
  local workspace="$workspace_root/$task_id-product-only"
  local task_root="$project_root/benchmarks/tasks/$task_id/repo"
  local solution_root="$project_root/benchmarks/tasks/$task_id/solution"

  run_benchmark_prepare "$task_id" "$workspace" --allow-bootstrap-recovery true >/dev/null

  cp "$solution_root/Main.clasp" "$workspace/Main.clasp"

  run_clasp_backend_static_verify "$workspace"

  assert_files_match "$workspace/test/workflow-correctness.test.mjs" "$task_root/test/workflow-correctness.test.mjs"
}

check_oracle_prompt_mode() {
  local clasp_workspace="$workspace_root/clasp-lead-segment-oracle"
  local ts_workspace="$workspace_root/ts-lead-segment-oracle"
  local clasp_prepare_output
  local ts_prepare_output

  clasp_prepare_output="$(run_benchmark_prepare clasp-lead-segment "$clasp_workspace" --mode oracle --allow-bootstrap-recovery true)"
  grep -Fq 'Prompt: ' <<<"$clasp_prepare_output"
  grep -Fq 'benchmarks/tasks/clasp-lead-segment/prompt.oracle.md' <<<"$clasp_prepare_output"

  cp "$project_root/examples/lead-app/Shared/Lead.clasp" "$clasp_workspace/Shared/Lead.clasp"
  run_clasp_backend_static_verify "$clasp_workspace"

  ts_prepare_output="$(node "$project_root/benchmarks/run-benchmark.mjs" prepare ts-lead-segment --mode oracle --workspace "$ts_workspace")"
  grep -Fq 'Prompt: ' <<<"$ts_prepare_output"
  grep -Fq 'benchmarks/tasks/ts-lead-segment/prompt.oracle.md' <<<"$ts_prepare_output"
}

check_persistence_prompt_modes() {
  local raw_workspace="$workspace_root/ts-lead-persistence-raw"
  local hinted_workspace="$workspace_root/ts-lead-persistence-file-hinted"
  local oracle_workspace="$workspace_root/ts-lead-persistence-oracle"
  local raw_output
  local hinted_output
  local oracle_output
  local latest_result

  raw_output="$(run_benchmark_prepare ts-lead-persistence "$raw_workspace" --mode raw-repo)"
  grep -Fq 'Prompt: ' <<<"$raw_output"
  grep -Fq 'benchmarks/tasks/ts-lead-persistence/prompt.raw.md' <<<"$raw_output"

  hinted_output="$(run_benchmark_prepare ts-lead-persistence "$hinted_workspace" --mode file-hinted)"
  grep -Fq 'Prompt: ' <<<"$hinted_output"
  grep -Fq 'benchmarks/tasks/ts-lead-persistence/prompt.file-hinted.md' <<<"$hinted_output"

  oracle_output="$(run_benchmark_prepare ts-lead-persistence "$oracle_workspace" --mode oracle)"
  grep -Fq 'Prompt: ' <<<"$oracle_output"
  grep -Fq 'benchmarks/tasks/ts-lead-persistence/prompt.oracle.md' <<<"$oracle_output"

  cp "$project_root/examples/lead-app-ts/src/server/main.ts" "$oracle_workspace/src/server/main.ts"
  cp "$project_root/examples/lead-app-ts/src/server/store.ts" "$oracle_workspace/src/server/store.ts"
  cp "$project_root/examples/lead-app-ts/src/server/runtime-modules.d.ts" "$oracle_workspace/src/server/runtime-modules.d.ts"
  cp "$project_root/examples/lead-app-ts/src/server/dev.ts" "$oracle_workspace/src/server/dev.ts"

  run_benchmark_verify ts-lead-persistence "$oracle_workspace" \
    --harness oracle-check \
    --model local \
    --mode oracle >/dev/null

  latest_result="$(latest_result_for_harness oracle-check)"
  assert_contains "$latest_result" '"mode": "oracle"'
  assert_contains "$latest_result" '"promptFile": "benchmarks/tasks/ts-lead-persistence/prompt.oracle.md"'
  rm -f "$latest_result"
}

check_public_app_raw_prompt_fairness() {
  local priority_workspace="$workspace_root/clasp-lead-priority-raw"
  local priority_output
  local task_dir

  for task_id in \
    clasp-lead-priority \
    clasp-lead-rejection \
    clasp-external-adaptation \
    clasp-legal-assistant-appbench
  do
    task_dir="$project_root/benchmarks/tasks/$task_id"
    assert_file_exists "$task_dir/prompt.raw.md"
  done

  assert_not_contains "$project_root/benchmarks/tasks/clasp-lead-priority/prompt.raw.md" 'type Priority ='
  assert_not_contains "$project_root/benchmarks/tasks/clasp-lead-priority/prompt.raw.md" 'priorityHint : Priority'
  assert_not_contains "$project_root/benchmarks/tasks/clasp-lead-priority/prompt.raw.md" 'priority : Priority'
  assert_not_contains "$project_root/benchmarks/tasks/clasp-lead-rejection/prompt.raw.md" 'type Priority ='
  assert_not_contains "$project_root/benchmarks/tasks/clasp-lead-rejection/prompt.raw.md" 'priorityHint : Priority'
  assert_not_contains "$project_root/benchmarks/tasks/clasp-lead-rejection/prompt.raw.md" 'priority : Priority'

  priority_output="$(run_benchmark_prepare clasp-lead-priority "$priority_workspace" --mode raw-repo)"
  grep -Fq 'Prompt: ' <<<"$priority_output"
  grep -Fq 'benchmarks/tasks/clasp-lead-priority/prompt.raw.md' <<<"$priority_output"
}

check_nested_clasp_benchmark_prep() {
  local task_id="clasp-lead-priority"
  local workspace="$workspace_root/$task_id"

  run_benchmark_prepare "$task_id" "$workspace" >/dev/null

  assert_file_exists "$workspace/benchmark-prep/Main.context.json"
  assert_file_exists "$workspace/benchmark-prep/Main.air.json"
  assert_file_exists "$workspace/benchmark-prep/Main.ui.json"
  assert_file_exists "$workspace/benchmark-prep/Main.agent-pack.json"
  assert_file_exists "$workspace/LANGUAGE_GUIDE.md"

  assert_contains "$workspace/benchmark-prep/Main.context.json" '"format": "clasp-context-v1"'
  assert_contains "$workspace/benchmark-prep/Main.context.json" '"route:summarizeLeadRoute"'
  assert_contains "$workspace/benchmark-prep/Main.context.json" '"sourceId": "source:Shared.Lead"'
  assert_contains "$workspace/benchmark-prep/Main.context.json" '"affectedSurfaces"'
  assert_contains "$workspace/benchmark-prep/Main.air.json" '"format": "clasp-air-v1"'
  assert_contains "$workspace/benchmark-prep/Main.air.json" '"record:LeadRequest"'
  assert_contains "$workspace/benchmark-prep/Main.ui.json" '[]'
  assert_contains "$workspace/benchmark-prep/Main.agent-pack.json" '"format": "clasp-benchmark-agent-pack-v1"'
  assert_contains "$workspace/benchmark-prep/Main.surfaces.json" '"agentPack": "benchmark-prep/Main.agent-pack.json"'
  assert_contains "$workspace/LANGUAGE_GUIDE.md" '`app/Main.clasp`'
  assert_contains "$workspace/LANGUAGE_GUIDE.md" '`benchmark-prep/Main.context.json`'
  assert_contains "$workspace/LANGUAGE_GUIDE.md" '`benchmark-prep/Main.agent-pack.json`'
  assert_contains "$workspace/LANGUAGE_GUIDE.md" '`POST /lead/summary` request `LeadRequest` -> response `LeadSummary`'
}

check_public_app_semantic_pack_coverage() {
  local legal_workspace="$workspace_root/clasp-legal-assistant-appbench"

  run_benchmark_prepare clasp-legal-assistant-appbench "$legal_workspace" >/dev/null

  node - "$workspace_root" <<'EOF'
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const workspaceRoot = process.argv[2];
const publicAppTasks = [
  {
    id: "clasp-lead-priority",
    entry: "app/Main.clasp",
    appOwned: ["app/Shared/Lead.clasp"],
    doNotEdit: ["app/Main.clasp", "test/priority.test.mjs", "scripts/verify.sh"]
  },
  {
    id: "clasp-lead-rejection",
    entry: "app/Main.clasp",
    appOwned: ["app/Shared/Lead.clasp"],
    doNotEdit: ["app/Main.clasp", "test/priority.test.mjs", "test/rejection.test.mjs", "scripts/verify.sh"]
  },
  {
    id: "clasp-lead-segment",
    entry: "Main.clasp",
    appOwned: ["Shared/Lead.clasp"],
    doNotEdit: ["Main.clasp", "test/lead-app.test.mjs", "scripts/verify.sh"]
  },
  {
    id: "clasp-external-adaptation",
    entry: "Main.clasp",
    appOwned: ["demo.mjs"],
    doNotEdit: ["Main.clasp", "Shared/Lead.clasp", "bindings.mjs", "test/objective.test.mjs", "scripts/verify.sh"]
  },
  {
    id: "clasp-legal-assistant-appbench",
    entry: "Main.clasp",
    appOwned: ["Main.clasp", "Process.clasp"],
    doNotEdit: ["web-search-fixture.mjs", "scripts/verify.sh"]
  }
];

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function assertMetadata(metadata, task) {
  assert.equal(metadata.taskId, task.id);
  assert.equal(metadata.entry, task.entry);
  assert.deepEqual(metadata.verifierCommand, ["bash", "scripts/verify.sh"]);
  assert.deepEqual(metadata.appOwnedEditSurface, task.appOwned);
  assert.deepEqual(metadata.doNotEditSurface, task.doNotEdit);
  assert.equal(metadata.artifacts.context, "benchmark-prep/Main.context.json");
  assert.equal(metadata.artifacts.air, "benchmark-prep/Main.air.json");
  assert.equal(metadata.artifacts.surfaces, "benchmark-prep/Main.surfaces.json");
  assert.equal(metadata.artifacts.agentPack, "benchmark-prep/Main.agent-pack.json");
}

for (const task of publicAppTasks) {
  const workspace = path.join(workspaceRoot, task.id);
  const contextPath = path.join(workspace, "benchmark-prep", "Main.context.json");
  const airPath = path.join(workspace, "benchmark-prep", "Main.air.json");
  const surfacesPath = path.join(workspace, "benchmark-prep", "Main.surfaces.json");
  const agentPackPath = path.join(workspace, "benchmark-prep", "Main.agent-pack.json");
  const guidePath = path.join(workspace, "LANGUAGE_GUIDE.md");

  for (const artifactPath of [contextPath, airPath, surfacesPath, agentPackPath, guidePath]) {
    assert.ok(fs.existsSync(artifactPath), `missing semantic pack artifact for ${task.id}: ${artifactPath}`);
  }

  const context = readJson(contextPath);
  const air = readJson(airPath);
  const surfaces = readJson(surfacesPath);
  const agentPack = readJson(agentPackPath);
  const guide = fs.readFileSync(guidePath, "utf8");

  assertMetadata(context.benchmarkPrep, task);
  assertMetadata(air.benchmarkPrep, task);

  assert.equal(surfaces.taskId, task.id);
  assert.equal(surfaces.entry, task.entry);
  assert.deepEqual(surfaces.verifierCommand, ["bash", "scripts/verify.sh"]);
  assert.deepEqual(surfaces.appOwnedEditSurface, task.appOwned);
  assert.deepEqual(surfaces.doNotEditSurface, task.doNotEdit);
  assert.equal(surfaces.artifacts.context, "benchmark-prep/Main.context.json");
  assert.equal(surfaces.artifacts.air, "benchmark-prep/Main.air.json");
  assert.equal(surfaces.artifacts.surfaces, "benchmark-prep/Main.surfaces.json");
  assert.equal(surfaces.artifacts.agentPack, "benchmark-prep/Main.agent-pack.json");
  assert.ok(
    surfaces.summaries.routeBoundaryCount + surfaces.summaries.hostBoundaryCount > 0,
    `${task.id} should summarize at least one route or host boundary`
  );
  assert.ok(
    Array.isArray(surfaces.summaries.decodeBoundaries),
    `${task.id} should expose a decode-boundary summary array`
  );

  assert.equal(agentPack.task.id, task.id);
  assert.equal(agentPack.task.entry, task.entry);
  assert.deepEqual(agentPack.task.verifierCommand, ["bash", "scripts/verify.sh"]);
  assert.deepEqual(agentPack.editTargets.primary, task.appOwned);
  assert.deepEqual(agentPack.editTargets.doNotEdit, task.doNotEdit);
  assert.equal(agentPack.artifacts.context, "benchmark-prep/Main.context.json");
  assert.equal(agentPack.artifacts.air, "benchmark-prep/Main.air.json");
  assert.equal(agentPack.artifacts.surfaces, "benchmark-prep/Main.surfaces.json");
  assert.equal(agentPack.artifacts.agentPack, "benchmark-prep/Main.agent-pack.json");
  assert.deepEqual(agentPack.verifier.command, ["bash", "scripts/verify.sh"]);
  assert.deepEqual(agentPack.summaries, surfaces.summaries);
  assert.ok(
    agentPack.semanticIndex.entries.some((entry) => entry.kind === "source-module"),
    `${task.id} semantic index should include source-module entries`
  );
  assert.ok(
    agentPack.semanticIndex.artifactRefs.includes("benchmark-prep/Main.agent-pack.json"),
    `${task.id} semantic index should link back to the agent pack artifact`
  );

  assert.match(guide, /App-owned edit surface/);
  assert.match(guide, /Do-not-edit runtime\/test surfaces/);
  assert.match(guide, /semanticIndex\.entries/);
  for (const appPath of task.appOwned) {
    assert.ok(guide.includes(`\`${appPath}\``), `${task.id} guide missing app-owned surface ${appPath}`);
  }
  for (const guardedPath of task.doNotEdit) {
    assert.ok(guide.includes(`\`${guardedPath}\``), `${task.id} guide missing do-not-edit surface ${guardedPath}`);
  }
}
EOF
}

check_default_clasp_benchmark_path_requires_recovery
check_default_public_app_benchmark_path_supported
check_incomplete_task ts-lead-segment
check_incomplete_task ts-lead-persistence
check_incomplete_task clasp-lead-segment
check_incomplete_task ts-lead-rejection
check_incomplete_task clasp-lead-rejection
check_incomplete_task ts-control-plane
check_incomplete_task clasp-control-plane
check_incomplete_task py-agent-escalation
check_incomplete_task clasp-durable-workflow
check_incomplete_task clasp-workflow-correctness
check_incomplete_task clasp-external-adaptation
check_incomplete_task ts-external-adaptation
check_incomplete_task clasp-npm-interop
check_incomplete_task ts-npm-interop
check_incomplete_task clasp-python-interop
check_incomplete_task ts-python-interop
check_incomplete_task clasp-rust-interop
check_incomplete_task ts-rust-interop
check_incomplete_task clasp-interop-boundary
check_incomplete_task ts-interop-boundary
check_incomplete_task clasp-secret-handling
check_incomplete_task ts-secret-handling
check_incomplete_task clasp-authorization-data-access
check_incomplete_task ts-authorization-data-access
check_incomplete_task clasp-audit-log
check_incomplete_task ts-audit-log
check_incomplete_task clasp-compiler-maintenance
check_incomplete_task clasp-syntax-compact
check_incomplete_task clasp-syntax-verbose
check_pristine_task_fails_verification clasp-lead-segment --allow-bootstrap-recovery true
check_pristine_task_fails_verification ts-lead-segment
check_nested_clasp_benchmark_prep
check_fixture_seed_override
check_lead_segment_acceptance_surface
check_lead_host_binding_manifest
check_public_app_semantic_pack_coverage

clasp_workspace="$workspace_root/clasp-lead-segment"
assert_contains "$clasp_workspace/test/lead-app.test.mjs" 'const binaryPath = process.env.CLASP_BENCH_BINARY;'
assert_contains "$clasp_workspace/test/lead-app.test.mjs" 'from "./native-http-test.mjs";'
assert_not_contains "$clasp_workspace/test/lead-app.test.mjs" 'CLASP_PROJECT_ROOT'
assert_file_exists "$clasp_workspace/test/native-http-test.mjs"
if [[ -e "$clasp_workspace/server.mjs" ]]; then
  echo "expected clasp-lead-segment workspace to omit server.mjs" >&2
  exit 1
fi
if [[ -e "$clasp_workspace/runtime/server.mjs" ]]; then
  echo "expected clasp-lead-segment workspace to omit runtime/server.mjs" >&2
  exit 1
fi
assert_not_contains "$clasp_workspace/Shared/Lead.clasp" "LeadSegment"

ts_workspace="$workspace_root/ts-lead-segment"
assert_contains "$ts_workspace/test/lead-app.test.mjs" 'import { createServer } from "../dist/server/main.js";'
assert_not_contains "$ts_workspace/src/shared/lead.ts" "LeadSegment"
assert_contains "$ts_workspace/src/server/main.ts" "createStoredLeadRecord"
assert_contains "$ts_workspace/src/server/main.ts" "loadInboxSnapshot"
assert_not_contains "$ts_workspace/src/server/main.ts" 'leadId: `lead-${leads.length + 1}`'

ts_persistence_workspace="$workspace_root/ts-lead-persistence"
assert_contains "$ts_persistence_workspace/test/lead-app.test.mjs" 'lead app schema version 999 is incompatible with expected version 1'
assert_not_contains "$ts_persistence_workspace/src/server/main.ts" 'createLeadStore'
if [[ -f "$ts_persistence_workspace/src/server/store.ts" ]]; then
  echo "expected ts-lead-persistence workspace to omit src/server/store.ts" >&2
  exit 1
fi

clasp_rejection_workspace="$workspace_root/clasp-lead-rejection"
assert_contains "$clasp_rejection_workspace/test/rejection.test.mjs" 'const binaryPath = process.env.CLASP_BENCH_BINARY;'
assert_contains "$clasp_rejection_workspace/test/rejection.test.mjs" 'CLASP_MOCK_LEAD_SUMMARY_PRIORITY'
if [[ -e "$clasp_rejection_workspace/runtime/server.mjs" ]]; then
  echo "expected clasp-lead-rejection workspace to omit runtime/server.mjs" >&2
  exit 1
fi
assert_not_contains "$clasp_rejection_workspace/app/Shared/Lead.clasp" "type Priority"
assert_not_contains "$clasp_rejection_workspace/app/Shared/Lead.clasp" "priorityHint"
assert_not_contains "$clasp_rejection_workspace/app/Shared/Lead.clasp" "priority :"

ts_rejection_workspace="$workspace_root/ts-lead-rejection"
assert_contains "$ts_rejection_workspace/test/rejection.test.mjs" 'import { createServer } from "../dist/server/main.js";'
assert_not_contains "$ts_rejection_workspace/src/shared/lead.ts" "priorityHint"
assert_not_contains "$ts_rejection_workspace/src/shared/lead.ts" "priority:"

clasp_control_workspace="$workspace_root/clasp-control-plane"
assert_contains "$clasp_control_workspace/Main.clasp" 'approval: never'
assert_contains "$clasp_control_workspace/Main.clasp" 'sandbox: read_only'
assert_contains "$clasp_control_workspace/Main.clasp" 'process "rg"'
assert_not_contains "$clasp_control_workspace/Main.clasp" 'process "bash"'
assert_not_contains "$clasp_control_workspace/Main.clasp" 'secret "OPENAI_API_KEY"'
assert_not_contains "$clasp_control_workspace/Main.clasp" 'verification: "Run bash scripts/verify-all.sh before finishing."'

ts_control_workspace="$workspace_root/ts-control-plane"
assert_contains "$ts_control_workspace/src/controlPlane.ts" 'file: ["/workspace", "/tmp"]'
assert_contains "$ts_control_workspace/src/controlPlane.ts" 'network: ["api.openai.com", "example.com"]'
assert_contains "$ts_control_workspace/src/controlPlane.ts" 'process: ["rg", "git"]'
assert_contains "$ts_control_workspace/src/controlPlane.ts" 'secret: []'
assert_contains "$ts_control_workspace/src/controlPlane.ts" 'approvalPolicy: "never"'
assert_contains "$ts_control_workspace/src/controlPlane.ts" 'sandboxPolicy: "read_only"'

durable_workspace="$workspace_root/clasp-durable-workflow"
assert_file_exists "$durable_workspace/benchmark-prep/Main.context.json"
assert_file_exists "$durable_workspace/LANGUAGE_GUIDE.md"
assert_contains "$durable_workspace/benchmark-prep/Main.context.json" '"schema:Counter"'
assert_contains "$durable_workspace/LANGUAGE_GUIDE.md" '`Main.clasp`'
assert_contains "$durable_workspace/test/durable-workflow.test.mjs" 'import { runDurableWorkflowDemo } from "../demo.mjs";'
assert_contains "$durable_workspace/demo.mjs" "overlapStatus: null"
assert_contains "$durable_workspace/demo.mjs" "autoRollbackStatus: null"
assert_contains "$durable_workspace/demo.mjs" "manualRollbackStatus: null"

workflow_correctness_workspace="$workspace_root/clasp-workflow-correctness"
assert_file_exists "$workflow_correctness_workspace/benchmark-prep/Main.context.json"
assert_file_exists "$workflow_correctness_workspace/benchmark-prep/Main.air.json"
assert_file_exists "$workflow_correctness_workspace/LANGUAGE_GUIDE.md"
assert_contains "$workflow_correctness_workspace/benchmark-prep/Main.context.json" '"schema:Counter"'
assert_contains "$workflow_correctness_workspace/benchmark-prep/Main.air.json" '"decl:nonNegative"'
assert_contains "$workflow_correctness_workspace/LANGUAGE_GUIDE.md" '`Main.clasp`'
assert_contains "$workflow_correctness_workspace/test/workflow-correctness.test.mjs" 'runWorkflowCorrectnessDemo'
assert_not_contains "$workflow_correctness_workspace/Main.clasp" 'invariant : nonNegative'
assert_not_contains "$workflow_correctness_workspace/Main.clasp" 'precondition : belowLimit'
assert_not_contains "$workflow_correctness_workspace/Main.clasp" 'postcondition : withinLimit'

clasp_npm_workspace="$workspace_root/clasp-npm-interop"
assert_file_exists "$clasp_npm_workspace/benchmark-prep/Main.context.json"
assert_contains "$clasp_npm_workspace/LANGUAGE_GUIDE.md" '`Main.clasp`'
assert_contains "$clasp_npm_workspace/LANGUAGE_GUIDE.md" '`benchmark-prep/Main.context.json`'
assert_not_contains "$clasp_npm_workspace/Main.clasp" 'from npm "local-upper"'
assert_not_contains "$clasp_npm_workspace/Main.clasp" 'from typescript "./support/formatLead.mjs"'

ts_npm_workspace="$workspace_root/ts-npm-interop"
assert_not_contains "$ts_npm_workspace/src/main.mjs" 'local-upper'
assert_not_contains "$ts_npm_workspace/src/main.mjs" 'formatLead'

clasp_python_workspace="$workspace_root/clasp-python-interop"
assert_file_exists "$clasp_python_workspace/benchmark-prep/Main.context.json"
assert_contains "$clasp_python_workspace/LANGUAGE_GUIDE.md" '`Main.clasp`'
assert_not_contains "$clasp_python_workspace/Main.clasp" 'hook workerStart'
assert_not_contains "$clasp_python_workspace/Main.clasp" 'route summarizeRoute'

ts_python_workspace="$workspace_root/ts-python-interop"
assert_contains "$ts_python_workspace/test/python-interop.test.mjs" 'runPythonInteropDemo'
assert_not_contains "$ts_python_workspace/src/main.mjs" 'spawn('

clasp_rust_workspace="$workspace_root/clasp-rust-interop"
assert_file_exists "$clasp_rust_workspace/benchmark-prep/Main.context.json"
assert_contains "$clasp_rust_workspace/LANGUAGE_GUIDE.md" '`Main.clasp`'
assert_not_contains "$clasp_rust_workspace/Main.clasp" 'foreign mockLeadSummaryModel'

ts_rust_workspace="$workspace_root/ts-rust-interop"
assert_contains "$ts_rust_workspace/test/rust-interop.test.mjs" 'resolveLeadSummaryNativePlan'
assert_not_contains "$ts_rust_workspace/src/nativeInterop.mjs" 'lead_summary_bridge'

clasp_boundary_workspace="$workspace_root/clasp-interop-boundary"
assert_file_exists "$clasp_boundary_workspace/benchmark-prep/Main.context.json"
assert_contains "$clasp_boundary_workspace/LANGUAGE_GUIDE.md" '`Main.clasp`'
assert_not_contains "$clasp_boundary_workspace/Main.clasp" 'foreign unsafe inspectLead'
assert_not_contains "$clasp_boundary_workspace/Main.clasp" 'from typescript "./support/inspectLead.mjs"'

ts_boundary_workspace="$workspace_root/ts-interop-boundary"
assert_contains "$ts_boundary_workspace/test/interop-boundary.test.mjs" 'runInteropBoundaryDemo'
assert_not_contains "$ts_boundary_workspace/src/main.mjs" 'inspectLead('

clasp_secret_workspace="$workspace_root/clasp-secret-handling"
assert_not_contains "$clasp_secret_workspace/Main.clasp" 'secret "SEARCH_API_TOKEN"'

ts_secret_workspace="$workspace_root/ts-secret-handling"
assert_contains "$ts_secret_workspace/src/main.mjs" 'secretNames: Object.freeze([])'

clasp_authorization_workspace="$workspace_root/clasp-authorization-data-access"
assert_not_contains "$clasp_authorization_workspace/Main.clasp" 'policy SupportAccess = public, pii'
assert_not_contains "$clasp_authorization_workspace/Main.clasp" 'projection SupportCustomer = Customer with SupportAccess { id, company, contactEmail, plan }'
assert_contains "$clasp_authorization_workspace/Main.clasp" 'writeProofPolicy = "PublicAccess"'

ts_authorization_workspace="$workspace_root/ts-authorization-data-access"
assert_contains "$ts_authorization_workspace/src/main.mjs" 'writeProofPolicy: "PublicAccess"'
assert_contains "$ts_authorization_workspace/src/main.mjs" 'disclosedField: "plan"'

clasp_audit_workspace="$workspace_root/clasp-audit-log"
assert_contains "$clasp_audit_workspace/Main.clasp" 'retentionDays = 7'
assert_not_contains "$clasp_audit_workspace/Main.clasp" 'TypedRouteAudit'

ts_audit_workspace="$workspace_root/ts-audit-log"
assert_contains "$ts_audit_workspace/src/main.mjs" 'retentionDays: 7'
assert_contains "$ts_audit_workspace/src/main.mjs" 'typedEventKinds: Object.freeze(["route", "tool", "workflow"])'

compiler_maintenance_workspace="$workspace_root/clasp-compiler-maintenance"
assert_file_exists "$compiler_maintenance_workspace/benchmark-prep/Main.context.json"
assert_file_exists "$compiler_maintenance_workspace/LANGUAGE_GUIDE.md"
assert_contains "$compiler_maintenance_workspace/benchmark-prep/Main.context.json" '"schema:SelfHostSnapshot"'
assert_contains "$compiler_maintenance_workspace/LANGUAGE_GUIDE.md" 'Compiler/Checker.clasp'
assert_contains "$compiler_maintenance_workspace/LANGUAGE_GUIDE.md" 'Compiler/Lower.clasp'
assert_contains "$compiler_maintenance_workspace/LANGUAGE_GUIDE.md" 'Compiler/Emit/JavaScript.clasp'
assert_contains "$compiler_maintenance_workspace/test/compiler-maintenance.test.mjs" 'previewEnabled = true'
assert_not_contains "$compiler_maintenance_workspace/Main.clasp" "loweredPreviewFlag"
assert_not_contains "$compiler_maintenance_workspace/Compiler/Lower.clasp" "CoreBool"

syntax_compact_workspace="$workspace_root/clasp-syntax-compact"
assert_file_exists "$syntax_compact_workspace/benchmark-prep/Main.context.json"
assert_not_contains "$syntax_compact_workspace/LANGUAGE_GUIDE.md" '`benchmark-prep/Main.explain.txt`'
if [[ -f "$syntax_compact_workspace/benchmark-prep/Main.explain.txt" ]]; then
  echo "expected compact syntax workspace to omit explain artifact" >&2
  exit 1
fi

syntax_verbose_workspace="$workspace_root/clasp-syntax-verbose"
assert_file_exists "$syntax_verbose_workspace/benchmark-prep/Main.context.json"
assert_file_exists "$syntax_verbose_workspace/benchmark-prep/Main.explain.txt"
assert_contains "$syntax_verbose_workspace/benchmark-prep/Main.explain.txt" 'leadSummary : Lead -> Str'
assert_contains "$syntax_verbose_workspace/LANGUAGE_GUIDE.md" '`benchmark-prep/Main.explain.txt`'

check_product_only_clasp_solution
check_product_only_typescript_solution
check_product_only_typescript_persistence_solution
check_product_only_clasp_workflow_correctness_solution
check_oracle_prompt_mode
check_persistence_prompt_modes
check_public_app_raw_prompt_fairness
