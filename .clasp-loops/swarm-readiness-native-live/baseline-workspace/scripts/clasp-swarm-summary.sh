#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$project_root/scripts/clasp-swarm-common.sh"

usage() {
  echo "usage: $0 [--json|--markdown] [wave-name]" >&2
}

json_mode=0
markdown_mode=0
wave_name="$(clasp_swarm_default_wave)"

if [[ $# -gt 2 ]]; then
  usage
  exit 1
fi

if [[ "${1:-}" == "--json" ]]; then
  json_mode=1
  wave_name="${2:-$(clasp_swarm_default_wave)}"
elif [[ "${1:-}" == "--markdown" ]]; then
  markdown_mode=1
  wave_name="${2:-$(clasp_swarm_default_wave)}"
elif [[ $# -ge 1 ]]; then
  wave_name="$1"
fi

node - <<'EOF' "$project_root/.clasp-swarm/$wave_name" "$wave_name" "$json_mode" "$markdown_mode"
const fs = require("fs");
const path = require("path");

const [runtimeRoot, waveName, jsonMode, markdownMode] = process.argv.slice(2);

function parseRunName(name) {
  const match = name.match(/^([0-9]{8}T[0-9]{6}Z)-(.+)-attempt([0-9]+)$/);
  if (!match) {
    return null;
  }

  const stamp = match[1];
  const taskId = match[2];
  const attempt = Number(match[3]);
  const startMillis = Date.parse(
    `${stamp.slice(0, 4)}-${stamp.slice(4, 6)}-${stamp.slice(6, 8)}T` +
      `${stamp.slice(9, 11)}:${stamp.slice(11, 13)}:${stamp.slice(13, 15)}Z`,
  );

  return {
    taskId,
    attempt,
    startMillis: Number.isFinite(startMillis) ? startMillis : null,
  };
}

function taskFamilyOf(taskId) {
  const match = String(taskId || "").match(/^([A-Z]{2,3})-[0-9]{3}(?:$|-)/);
  return match ? match[1] : "misc";
}

function readJson(filePath) {
  try {
    return JSON.parse(fs.readFileSync(filePath, "utf8"));
  } catch (_) {
    return null;
  }
}

function collectStrings(value, sink) {
  if (typeof value === "string") {
    sink.push(value);
    return;
  }

  if (Array.isArray(value)) {
    for (const item of value) {
      collectStrings(item, sink);
    }
    return;
  }

  if (value && typeof value === "object") {
    for (const item of Object.values(value)) {
      collectStrings(item, sink);
    }
  }
}

function reportTimedOut(report) {
  if (!report || typeof report !== "object") {
    return false;
  }

  const strings = [];
  collectStrings(report, strings);
  return strings.some((value) => /\bcode 124\b|timed out/i.test(value));
}

function rate(numerator, denominator) {
  if (denominator === 0) {
    return null;
  }
  return numerator / denominator;
}

function mean(total, count) {
  if (count === 0) {
    return null;
  }
  return total / count;
}

const runs = [];

if (fs.existsSync(runtimeRoot)) {
  for (const laneName of fs.readdirSync(runtimeRoot).sort()) {
    const laneRoot = path.join(runtimeRoot, laneName);
    const runsRoot = path.join(laneRoot, "runs");
    if (!fs.existsSync(runsRoot) || !fs.statSync(runsRoot).isDirectory()) {
      continue;
    }

    for (const runName of fs.readdirSync(runsRoot).sort()) {
      const runRoot = path.join(runsRoot, runName);
      if (!fs.statSync(runRoot).isDirectory()) {
        continue;
      }

      const parsed = parseRunName(runName);
      if (!parsed) {
        continue;
      }

      const verifierPath = path.join(runRoot, "verifier-report.json");
      const builderPath = path.join(runRoot, "builder-report.json");
      const hasVerifier = fs.existsSync(verifierPath);
      const hasBuilder = fs.existsSync(builderPath);
      const reportPath = hasVerifier ? verifierPath : hasBuilder ? builderPath : null;
      const report = reportPath ? readJson(reportPath) : null;
      const reportMillis = reportPath ? fs.statSync(reportPath).mtimeMs : null;
      const durationSeconds =
        parsed.startMillis !== null && reportMillis !== null
          ? Math.max(0, (reportMillis - parsed.startMillis) / 1000)
          : null;
      const verdict = hasVerifier && report && typeof report.verdict === "string" ? report.verdict : null;
      const outcome = hasVerifier ? (verdict === "pass" ? "pass" : "fail") : "incomplete";

      runs.push({
        lane: laneName,
        run: runName,
        taskId: parsed.taskId,
        taskFamily: taskFamilyOf(parsed.taskId),
        attempt: parsed.attempt,
        outcome,
        timedOut: hasVerifier && outcome === "fail" ? reportTimedOut(report) : false,
        durationSeconds,
      });
    }
  }
}

const families = new Map();
const overall = {
  totalRuns: 0,
  completedRuns: 0,
  passCount: 0,
  timeoutCount: 0,
  incompleteRuns: 0,
  durationSecondsTotal: 0,
  durationSampleCount: 0,
};

for (const run of runs) {
  overall.totalRuns += 1;
  if (run.outcome === "incomplete") {
    overall.incompleteRuns += 1;
  } else {
    overall.completedRuns += 1;
  }
  if (run.outcome === "pass") {
    overall.passCount += 1;
  }
  if (run.timedOut) {
    overall.timeoutCount += 1;
  }
  if (run.outcome !== "incomplete" && typeof run.durationSeconds === "number") {
    overall.durationSecondsTotal += run.durationSeconds;
    overall.durationSampleCount += 1;
  }

  const family = run.taskFamily;
  if (!families.has(family)) {
    families.set(family, {
      taskFamily: family,
      totalRuns: 0,
      completedRuns: 0,
      passCount: 0,
      timeoutCount: 0,
      incompleteRuns: 0,
      durationSecondsTotal: 0,
      durationSampleCount: 0,
    });
  }

  const bucket = families.get(family);
  bucket.totalRuns += 1;
  if (run.outcome === "incomplete") {
    bucket.incompleteRuns += 1;
  } else {
    bucket.completedRuns += 1;
  }
  if (run.outcome === "pass") {
    bucket.passCount += 1;
  }
  if (run.timedOut) {
    bucket.timeoutCount += 1;
  }
  if (run.outcome !== "incomplete" && typeof run.durationSeconds === "number") {
    bucket.durationSecondsTotal += run.durationSeconds;
    bucket.durationSampleCount += 1;
  }
}

function finalize(summary) {
  return {
    taskFamily: summary.taskFamily,
    totalRuns: summary.totalRuns,
    completedRuns: summary.completedRuns,
    incompleteRuns: summary.incompleteRuns,
    passCount: summary.passCount,
    timeoutCount: summary.timeoutCount,
    passRate: rate(summary.passCount, summary.completedRuns),
    timeoutRate: rate(summary.timeoutCount, summary.completedRuns),
    meanTimeSeconds: mean(summary.durationSecondsTotal, summary.durationSampleCount),
  };
}

const familySummaries = Array.from(families.values())
  .map(finalize)
  .sort((left, right) => left.taskFamily.localeCompare(right.taskFamily));

const payload = {
  wave: waveName,
  summary: finalize(overall),
  families: familySummaries,
};

if (jsonMode === "1") {
  process.stdout.write(`${JSON.stringify(payload, null, 2)}\n`);
  process.exit(0);
}

function formatRate(value) {
  return value === null ? "n/a" : `${(value * 100).toFixed(1)}%`;
}

function formatSeconds(value) {
  return value === null ? "n/a" : `${value.toFixed(1)}s`;
}

function formatRow(scope, summary) {
  return `| ${scope} | ${summary.totalRuns} | ${summary.completedRuns} | ${summary.incompleteRuns} | ${formatRate(summary.passRate)} | ${formatRate(summary.timeoutRate)} | ${formatSeconds(summary.meanTimeSeconds)} |`;
}

if (markdownMode === "1") {
  process.stdout.write(`# Swarm Summary: ${payload.wave}\n`);
  process.stdout.write(`| scope | runs | completed | incomplete | pass rate | timeout rate | mean time |\n`);
  process.stdout.write(`| --- | ---: | ---: | ---: | ---: | ---: | ---: |\n`);
  process.stdout.write(`${formatRow("overall", payload.summary)}\n`);
  for (const family of payload.families) {
    process.stdout.write(`${formatRow(family.taskFamily, family)}\n`);
  }
  process.exit(0);
}

process.stdout.write(`wave: ${payload.wave}\n`);
process.stdout.write(
  `summary: runs=${payload.summary.totalRuns} completed=${payload.summary.completedRuns} incomplete=${payload.summary.incompleteRuns} pass-rate=${formatRate(payload.summary.passRate)} timeout-rate=${formatRate(payload.summary.timeoutRate)} mean-time=${formatSeconds(payload.summary.meanTimeSeconds)}\n`,
);

for (const family of payload.families) {
  process.stdout.write(
    `family: ${family.taskFamily} runs=${family.totalRuns} completed=${family.completedRuns} incomplete=${family.incompleteRuns} pass-rate=${formatRate(family.passRate)} timeout-rate=${formatRate(family.timeoutRate)} mean-time=${formatSeconds(family.meanTimeSeconds)}\n`,
  );
}
EOF
