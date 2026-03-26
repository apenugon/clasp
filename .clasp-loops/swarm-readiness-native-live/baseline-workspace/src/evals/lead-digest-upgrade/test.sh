#!/usr/bin/env bash
set -euo pipefail

eval_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if bash "$eval_root/validate.sh" "$eval_root/start" >/tmp/clasp-lead-digest-start.out 2>/tmp/clasp-lead-digest-start.err; then
  echo "expected start fixture to fail target validation" >&2
  exit 1
fi

bash "$eval_root/validate.sh" "$eval_root/solution"

metrics_json="$(bash "$eval_root/compare.sh")"
printf '%s\n' "$metrics_json" | node -e '
const fs = require("fs");
const metrics = JSON.parse(fs.readFileSync(0, "utf8"));
if (metrics.oracle.changedFileCount !== 2) {
  throw new Error(`expected 2 changed files, got ${metrics.oracle.changedFileCount}`);
}
if (metrics.baselineValidator.startFailureIssueCount !== 1) {
  throw new Error(`expected baseline validator to report 1 issue, got ${metrics.baselineValidator.startFailureIssueCount}`);
}
if (metrics.claspAware.startFailureIssueCount <= metrics.baselineValidator.startFailureIssueCount) {
  throw new Error("expected semantic validator to expose more failure signals than the baseline validator");
}
if (metrics.claspAware.observableSurfaceCount <= metrics.rawRepo.observableSurfaceCount) {
  throw new Error("expected clasp-aware observable surfaces to exceed raw-repo observable surfaces");
}
'
