import { join } from "node:path";
import { readFileSync, rmSync, writeFileSync } from "node:fs";
import {
  assistanceModes,
  average,
  benchmarkModes,
  buildSemanticBrief,
  changedFilesAgainstStart,
  cleanupArtifacts,
  commonStartRoot,
  createWorkspace,
  emitArtifacts,
  ensureResultsRoot,
  listTaskIds,
  loadCompiledModule,
  loadTask,
  median,
  parseCodexUsage,
  readJsonLines,
  renderPrompt,
  resultsRoot,
  runCodex,
  runCommand,
  stableString,
  suiteRoot,
  summarizeVerifyLog
} from "./lib.mjs";

function parseListEnv(name, fallback) {
  const value = process.env[name];
  if (!value || value.trim().length === 0) {
    return fallback;
  }
  return value
    .split(",")
    .map((entry) => entry.trim())
    .filter((entry) => entry.length > 0);
}

function parsePositiveIntEnv(name, fallback) {
  const value = process.env[name];
  if (!value) {
    return fallback;
  }
  const parsed = Number.parseInt(value, 10);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    throw new Error(`${name} must be a positive integer`);
  }
  return parsed;
}

function safeRatioDelta(left, right) {
  if (typeof left !== "number" || typeof right !== "number" || left === 0) {
    return null;
  }
  return Number((((left - right) / left) * 100).toFixed(1));
}

function safeDiff(left, right) {
  if (typeof left !== "number" || typeof right !== "number") {
    return null;
  }
  return right - left;
}

function numericValues(values) {
  return values.filter((value) => typeof value === "number" && Number.isFinite(value));
}

function buildAggregate(runs) {
  const durations = numericValues(runs.map((run) => run.durationMs));
  const totals = numericValues(runs.map((run) => run.tokenUsage.total));
  const uncached = numericValues(runs.map((run) => run.harnessUsage.uncachedTotal));
  const timeToGreen = runs.map((run) => run.timeToGreenMs).filter((value) => typeof value === "number");
  const verifyAttempts = runs.map((run) => run.verifyAttempts);
  const repairLoops = runs.map((run) => run.repairLoops);
  const passes = runs.filter((run) => run.verification.passed).length;

  return {
    runCount: runs.length,
    passCount: passes,
    passRate: Number((passes / runs.length).toFixed(3)),
    avgDurationMs: average(durations),
    medianDurationMs: median(durations),
    avgTotalTokens: average(totals),
    medianTotalTokens: median(totals),
    avgUncachedTokens: average(uncached),
    medianUncachedTokens: median(uncached),
    avgTimeToGreenMs: average(timeToGreen),
    medianTimeToGreenMs: median(timeToGreen),
    avgVerifyAttempts: Number((verifyAttempts.reduce((sum, value) => sum + value, 0) / runs.length).toFixed(2)),
    avgRepairLoops: Number((repairLoops.reduce((sum, value) => sum + value, 0) / runs.length).toFixed(2))
  };
}

const tasks = parseListEnv("CLASP_SUITE_TASKS", listTaskIds());
const modes = parseListEnv("CLASP_SUITE_MODES", benchmarkModes);
const assistances = parseListEnv("CLASP_SUITE_ASSISTANCES", assistanceModes);
const sampleCount = parsePositiveIntEnv("CLASP_SUITE_SAMPLES", 1);
const model = process.env.CLASP_LIVE_MODEL ?? "gpt-5.4";
const reasoningEffort = process.env.CLASP_LIVE_REASONING_EFFORT ?? "high";
const keepWorkspaces = process.env.CLASP_KEEP_WORKSPACES === "true";
const runId = new Date().toISOString().replaceAll(":", "-");

ensureResultsRoot();

const startArtifacts = emitArtifacts(join(commonStartRoot, "Main.clasp"));
const startCompiled = await loadCompiledModule(startArtifacts.compiledPath);
const startContext = JSON.parse(readFileSync(startArtifacts.contextPath, "utf8"));
const startAir = JSON.parse(readFileSync(startArtifacts.airPath, "utf8"));

const runs = [];

try {
  for (const taskId of tasks) {
    const task = loadTask(taskId);
    const semanticBrief = buildSemanticBrief(task, startCompiled, startContext, startAir);

    for (const mode of modes) {
      for (const assistance of assistances) {
        for (let sampleIndex = 1; sampleIndex <= sampleCount; sampleIndex += 1) {
          const workspace = createWorkspace(task, mode, assistance, semanticBrief);
          const promptText = renderPrompt(task, mode, assistance, semanticBrief);
          const baseName = `${runId}--${task.id}--${mode}--${assistance}--sample${String(sampleIndex).padStart(2, "0")}`;
          const promptPath = join(resultsRoot, `${baseName}.prompt.md`);
          const agentLogPath = join(resultsRoot, `${baseName}.codex-run.jsonl`);
          writeFileSync(promptPath, promptText, "utf8");

          const startedAt = new Date();
          const startedAtMs = startedAt.getTime();
          const codexRun = await runCodex(promptText, workspace, agentLogPath, model, reasoningEffort);
          const finishedAt = new Date();

          const finalVerification = await runCommand("bash", [join(suiteRoot, "validate.sh"), task.id, workspace], {
            cwd: suiteRoot
          });
          const verifyLog = summarizeVerifyLog(readJsonLines(join(workspace, "benchmark-verify.jsonl")), startedAtMs);
          const usage = parseCodexUsage(agentLogPath);
          const changedFiles = changedFilesAgainstStart(workspace);

          const result = {
            taskId: task.id,
            title: task.title,
            mode,
            assistance,
            sampleIndex,
            harness: "codex",
            model,
            reasoningEffort,
            startedAt: startedAt.toISOString(),
            finishedAt: finishedAt.toISOString(),
            durationMs: finishedAt.getTime() - startedAtMs,
            promptFile: promptPath,
            promptBytes: Buffer.byteLength(promptText, "utf8"),
            codexExitCode: codexRun.exitCode,
            codexTimedOut: codexRun.timedOut,
            tokenUsage: {
              prompt: usage.prompt,
              completion: usage.completion,
              retry: usage.retry,
              debug: usage.debug,
              total: usage.total
            },
            harnessUsage: usage.harnessUsage,
            verification: {
              passed: finalVerification.exitCode === 0,
              exitCode: finalVerification.exitCode,
              output: finalVerification.stdout.trim()
            },
            verifyAttempts: verifyLog.verifyAttempts,
            repairLoops: verifyLog.repairLoops,
            timeToGreenMs: verifyLog.timeToGreenMs,
            changedFiles,
            changedFileCount: changedFiles.length,
            workspace: keepWorkspaces || finalVerification.exitCode !== 0 ? workspace : null
          };

          writeFileSync(join(resultsRoot, `${baseName}.result.json`), stableString(result) + "\n", "utf8");
          runs.push(result);

          if (!keepWorkspaces && finalVerification.exitCode === 0) {
            rmSync(workspace, { recursive: true, force: true });
          }
        }
      }
    }
  }
} finally {
  cleanupArtifacts(startArtifacts);
}

const pairGroups = new Map();
for (const run of runs) {
  const key = `${run.taskId}::${run.mode}::${run.sampleIndex}`;
  const entry = pairGroups.get(key) ?? {};
  entry[run.assistance] = run;
  pairGroups.set(key, entry);
}

const pairComparisons = [];
for (const [key, pair] of pairGroups.entries()) {
  if (!pair["raw-text"] || !pair["compiler-owned-air"]) {
    continue;
  }

  const rawText = pair["raw-text"];
  const compilerOwnedAir = pair["compiler-owned-air"];
  pairComparisons.push({
    key,
    taskId: rawText.taskId,
    mode: rawText.mode,
    sampleIndex: rawText.sampleIndex,
    rawText,
    compilerOwnedAir,
    deltas: {
      durationMs: safeDiff(rawText.durationMs, compilerOwnedAir.durationMs),
      totalTokens: safeDiff(rawText.tokenUsage.total, compilerOwnedAir.tokenUsage.total),
      uncachedTokens: safeDiff(rawText.harnessUsage.uncachedTotal, compilerOwnedAir.harnessUsage.uncachedTotal),
      verifyAttempts: compilerOwnedAir.verifyAttempts - rawText.verifyAttempts,
      repairLoops: compilerOwnedAir.repairLoops - rawText.repairLoops,
      timeToGreenMs: safeDiff(rawText.timeToGreenMs, compilerOwnedAir.timeToGreenMs),
      durationPct: safeRatioDelta(rawText.durationMs, compilerOwnedAir.durationMs),
      totalTokensPct: safeRatioDelta(rawText.tokenUsage.total, compilerOwnedAir.tokenUsage.total),
      uncachedTokensPct: safeRatioDelta(rawText.harnessUsage.uncachedTotal, compilerOwnedAir.harnessUsage.uncachedTotal),
      timeToGreenPct: safeRatioDelta(rawText.timeToGreenMs, compilerOwnedAir.timeToGreenMs)
    }
  });
}

const byAssistance = Object.fromEntries(
  assistances.map((assistance) => [assistance, buildAggregate(runs.filter((run) => run.assistance === assistance))])
);

const byMode = Object.fromEntries(
  modes.map((mode) => [
    mode,
    Object.fromEntries(
      assistances.map((assistance) => [
        assistance,
        buildAggregate(runs.filter((run) => run.mode === mode && run.assistance === assistance))
      ])
    )
  ])
);

const byTask = Object.fromEntries(
  tasks.map((taskId) => [
    taskId,
    Object.fromEntries(
      assistances.map((assistance) => [
        assistance,
        buildAggregate(runs.filter((run) => run.taskId === taskId && run.assistance === assistance))
      ])
    )
  ])
);

const winCounters = {
  duration: 0,
  totalTokens: 0,
  uncachedTokens: 0,
  timeToGreen: 0
};
for (const comparison of pairComparisons) {
  if (comparison.deltas.durationMs < 0) {
    winCounters.duration += 1;
  }
  if (comparison.deltas.totalTokens < 0) {
    winCounters.totalTokens += 1;
  }
  if (comparison.deltas.uncachedTokens < 0) {
    winCounters.uncachedTokens += 1;
  }
  if (typeof comparison.deltas.timeToGreenMs === "number" && comparison.deltas.timeToGreenMs < 0) {
    winCounters.timeToGreen += 1;
  }
}

const summary = {
  suite: "contract-upgrade-suite",
  harness: "codex",
  model,
  reasoningEffort,
  runId,
  tasks,
  modes,
  assistances,
  sampleCount,
  runCount: runs.length,
  pairComparisons,
  aggregates: {
    byAssistance,
    byMode,
    byTask,
    compilerOwnedAirWins: {
      pairCount: pairComparisons.length,
      duration: winCounters.duration,
      totalTokens: winCounters.totalTokens,
      uncachedTokens: winCounters.uncachedTokens,
      timeToGreen: winCounters.timeToGreen
    }
  }
};

const summaryPath = join(resultsRoot, `${runId}--suite-summary.json`);
writeFileSync(summaryPath, stableString(summary) + "\n", "utf8");
console.log(stableString({ summaryPath, summary }));
