#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
mkdir -p "$tmp_root"
export TMPDIR="$tmp_root"
test_root="$(mktemp -d "$TMPDIR/test-swarm-semantic-summary-index.XXXXXX")"

cleanup() {
  rm -rf "$test_root"
}

trap cleanup EXIT

claspc_bin="$(env -u CLASP_CLASPC -u CLASPC_BIN -u RUSTC "$project_root/scripts/resolve-claspc.sh")"
summary_path="$test_root/lead-app.semantic.json"
program_state_root="$test_root/program-state"
output_path="$test_root/semantic-summary-index-harness.json"

env RUSTC=/definitely-missing-rustc \
  timeout 120 \
  "$claspc_bin" --json semantic "$project_root/examples/lead-app/Main.clasp" -o "$summary_path" \
  >/dev/null

env RUSTC=/definitely-missing-rustc CLASP_SEMANTIC_SUMMARY_PATH="$summary_path" \
  timeout 120 \
  "$claspc_bin" run "$project_root/examples/swarm-native/SemanticSummaryIndexHarness.clasp" -- "$program_state_root" \
  >"$output_path"

if grep -F 'error:' "$output_path" >/dev/null; then
  cat "$output_path" >&2
  exit 1
fi

node - "$output_path" "$summary_path" <<'EOF'
const fs = require("node:fs");

const report = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const summaryPath = process.argv[3];

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function includes(list, value, label) {
  assert(Array.isArray(list), `${label} is not an array`);
  assert(list.includes(value), `${label} missing ${value}: ${JSON.stringify(list)}`);
}

function includesEnding(list, suffix, label) {
  assert(Array.isArray(list), `${label} is not an array`);
  assert(
    list.some((value) => typeof value === "string" && value.endsWith(suffix)),
    `${label} missing suffix ${suffix}: ${JSON.stringify(list)}`,
  );
}

function includesText(list, fragment, label) {
  assert(Array.isArray(list), `${label} is not an array`);
  assert(
    list.some((value) => typeof value === "string" && value.includes(fragment)),
    `${label} missing fragment ${fragment}: ${JSON.stringify(list)}`,
  );
}

assert(report.summaryFormat === "clasp-semantic-summary-v1", `summary format ${report.summaryFormat}`);
assert(report.summaryStatus === "ok", `summary status ${report.summaryStatus}`);
assert(report.summaryInput.endsWith("examples/lead-app/Main.clasp"), `summary input ${report.summaryInput}`);
assert(report.generatedEntryCount > 0, `generated entry count ${report.generatedEntryCount}`);
includes(report.generatedEntryIds, "source:Main", "generated entry ids");
includes(report.generatedEntryIds, "source:Shared.Lead", "generated entry ids");
includes(report.generatedEntryIds, "schema:LeadIntake", "generated entry ids");
includes(report.generatedEntryIds, "route:createLeadRoute", "generated entry ids");
includes(report.generatedEntryIds, "route:createLeadRecordRoute", "generated entry ids");
includes(report.generatedEntryIds, "foreign:mockLeadSummaryModel", "generated entry ids");
includesEnding(report.generatedEditFiles, "examples/lead-app/Main.clasp", "generated edit files");
includesEnding(report.generatedEditFiles, "examples/lead-app/Shared/Lead.clasp", "generated edit files");
includes(report.generatedArtifactRefs, summaryPath, "generated artifact refs");
includes(report.generatedSurfaceIds, "route:createLeadRoute", "generated surface ids");
includes(report.generatedSurfaceIds, "route:createLeadRecordRoute", "generated surface ids");
includes(report.generatedSurfaceIds, "schema:LeadIntake", "generated surface ids");
includes(report.generatedSurfaceIds, "foreign:mockLeadSummaryModel", "generated surface ids");
includesText(report.generatedQueryTexts, "POST /leads LeadIntake -> Page", "generated query texts");
includesText(report.generatedQueryTexts, "POST /api/leads LeadIntake -> LeadRecord", "generated query texts");
includesText(report.generatedQueryTexts, "mockLeadSummaryModel", "generated query texts");

assert(report.contextSemanticArtifactCount >= 1, `context semantic artifact count ${report.contextSemanticArtifactCount}`);
includes(report.contextSemanticIndexEntryIds, "source:Main", "context semantic entry ids");
includes(report.contextSemanticIndexEntryIds, "source:Shared.Lead", "context semantic entry ids");
includes(report.contextSemanticIndexEntryIds, "schema:LeadIntake", "context semantic entry ids");
includes(report.contextSemanticIndexEntryIds, "route:createLeadRoute", "context semantic entry ids");
includes(report.contextSemanticIndexEntryIds, "route:createLeadRecordRoute", "context semantic entry ids");
includes(report.contextSemanticIndexEntryIds, "foreign:mockLeadSummaryModel", "context semantic entry ids");
includesEnding(report.contextSemanticIndexEditFiles, "examples/lead-app/Main.clasp", "context semantic edit files");
includesEnding(report.contextSemanticIndexEditFiles, "examples/lead-app/Shared/Lead.clasp", "context semantic edit files");
includes(report.contextSemanticIndexArtifactRefs, summaryPath, "context semantic artifact refs");
includes(report.contextSemanticIndexSurfaceIds, "route:createLeadRoute", "context semantic surface ids");
includes(report.contextSemanticIndexSurfaceIds, "route:createLeadRecordRoute", "context semantic surface ids");
includes(report.contextSemanticIndexSurfaceIds, "schema:LeadIntake", "context semantic surface ids");
includes(report.contextSemanticIndexSurfaceIds, "foreign:mockLeadSummaryModel", "context semantic surface ids");
includesText(report.contextSemanticIndexQueryTexts, "POST /leads LeadIntake -> Page", "context semantic query texts");
includesText(report.contextSemanticIndexQueryTexts, "POST /api/leads LeadIntake -> LeadRecord", "context semantic query texts");
includesText(report.contextSemanticIndexQueryTexts, "mockLeadSummaryModel", "context semantic query texts");
EOF

printf 'swarm-semantic-summary-index-ok\n'
