#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
report_path="$test_root/checkpoint.json"
no_native_report_path="$test_root/checkpoint-no-native.json"

cleanup() {
  rm -rf "$test_root"
}

trap cleanup EXIT

node --check "$project_root/scripts/benchmark-checkpoint.mjs" >/dev/null

node "$project_root/scripts/benchmark-checkpoint.mjs" \
  --fixture \
  --generated-at 2026-05-20T00:00:00.000Z \
  --tmp-root "$test_root" \
  --output "$report_path" >/dev/null

node - "$report_path" <<'EOF'
const fs = require("node:fs");

const report = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

assert(report.schemaVersion === 1, "schema version should be stable");
assert(report.kind === "clasp-baseline-bottleneck-checkpoint", "unexpected checkpoint kind");
assert(report.mode === "fixture", "fixture run should report fixture mode");
assert(report.generatedAt === "2026-05-20T00:00:00.000Z", "generatedAt should be controllable");
assert(report.finalStatus === "ok", "fixture checkpoint should pass");
assert(report.tmpDir === null, "temporary directory should be omitted unless kept");
assert(Array.isArray(report.commands) && report.commands.length === 4, "expected four fixture commands");
assert(report.commands.every((command) => command.command.startsWith("timeout ")), "commands should be explicitly timeout-wrapped");
assert(report.commands.every((command) => command.exitStatus === 0), "fixture commands should pass");
assert(report.commands.every((command) => Number.isInteger(command.durationMs) && command.durationMs >= 0), "durationMs should be structural");
assert(report.commandSummary["source-run-cold"].category === "ordinary-source-run-startup", "missing source run summary");
assert(report.commandSummary["compiler-slice-checker"].category === "verifier-heavy-check", "missing checker summary");
assert(report.nativeIncrementalReport?.matchesExpectations === true, "native incremental report should be embedded");
assert(
  report.nativeIncrementalReport?.advisoryTimings?.nativeImageCold?.realSeconds === 0.08,
  "native incremental timing should be preserved",
);
assert(Array.isArray(report.bottlenecks), "bottlenecks should be present");
assert(report.bottlenecks.length >= 1 && report.bottlenecks.length <= 2, "checkpoint should report one or two bottlenecks");
assert(report.bottlenecks[0].rank === 1, "bottlenecks should be ranked");
assert(report.bottlenecks.every((entry) => Array.isArray(entry.relatedCommands)), "bottlenecks should cite commands");
EOF

node "$project_root/scripts/benchmark-checkpoint.mjs" \
  --fixture \
  --no-native-incremental \
  --generated-at 2026-05-20T00:00:00.000Z \
  --tmp-root "$test_root" \
  --output "$no_native_report_path" >/dev/null

node - "$no_native_report_path" <<'EOF'
const fs = require("node:fs");
const report = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));

if (report.commands.length !== 3) {
  throw new Error(`expected no-native fixture to run three commands, got ${report.commands.length}`);
}
if (report.nativeIncrementalReport !== null) {
  throw new Error("no-native fixture should not embed a native incremental report");
}
if (report.commandSummary["native-incremental-body-change"]) {
  throw new Error("native incremental command should be absent when disabled");
}
EOF
