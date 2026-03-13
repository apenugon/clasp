#!/usr/bin/env node

import { cp, mkdir, readdir, readFile, rm, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { spawn } from "node:child_process";
import { pathToFileURL } from "node:url";

const benchmarkRoot = path.resolve("benchmarks");
const tasksRoot = path.join(benchmarkRoot, "tasks");
const resultsRoot = path.join(benchmarkRoot, "results");
const comparisonTaskFamilies = [
  {
    comparisonLabel: "control-plane-comparison",
    leftTaskId: "clasp-control-plane",
    rightTaskId: "ts-control-plane",
    leftLabel: "clasp",
    rightLabel: "ts"
  },
  {
    comparisonLabel: "lead-priority-comparison",
    leftTaskId: "clasp-lead-priority",
    rightTaskId: "ts-lead-priority",
    leftLabel: "clasp",
    rightLabel: "ts"
  },
  {
    comparisonLabel: "lead-rejection-comparison",
    leftTaskId: "clasp-lead-rejection",
    rightTaskId: "ts-lead-rejection",
    leftLabel: "clasp",
    rightLabel: "ts"
  },
  {
    comparisonLabel: "lead-segment-comparison",
    leftTaskId: "clasp-lead-segment",
    rightTaskId: "ts-lead-segment",
    leftLabel: "clasp",
    rightLabel: "ts"
  },
  {
    comparisonLabel: "external-adaptation-comparison",
    leftTaskId: "clasp-external-adaptation",
    rightTaskId: "ts-external-adaptation",
    leftLabel: "clasp",
    rightLabel: "ts"
  },
  {
    comparisonLabel: "syntax-form-comparison",
    leftTaskId: "clasp-syntax-compact",
    rightTaskId: "clasp-syntax-verbose",
    leftLabel: "compact",
    rightLabel: "verbose"
  }
];
const publicAppBenchmark = {
  comparisonLabel: "main-public-app-comparison",
  taskPairs: [
    {
      leftTaskId: "clasp-lead-priority",
      rightTaskId: "ts-lead-priority"
    },
    {
      leftTaskId: "clasp-lead-rejection",
      rightTaskId: "ts-lead-rejection"
    },
    {
      leftTaskId: "clasp-lead-segment",
      rightTaskId: "ts-lead-segment"
    }
  ],
  leftLabel: "clasp",
  rightLabel: "ts"
};

async function main() {
  const [command, maybeTaskId, ...rest] = process.argv.slice(2);

  switch (command) {
    case "list":
      await listTasks();
      break;
    case "prepare":
      await prepareCommand(maybeTaskId, rest);
      break;
    case "verify":
      await verifyCommand(maybeTaskId, rest);
      break;
    case "run":
      await runCommand(maybeTaskId, rest);
      break;
    case "summarize":
      await summarizeCommand(
        [maybeTaskId, ...rest].filter((value) => value !== undefined)
      );
      break;
    default:
      usage();
      process.exitCode = 1;
  }
}

async function listTasks() {
  const tasks = await loadTasks();
  for (const task of tasks) {
    console.log(`${task.id}\t${task.language}\t${task.suite}\t${task.title}`);
  }
}

async function prepareCommand(taskId, args) {
  const task = await loadTask(taskId);
  const options = parseOptions(args);
  const workspace = resolveWorkspace(task.id, options.workspace);

  await prepareWorkspace(task, workspace, benchmarkEnv(task, workspace));

  console.log(`Prepared ${task.id}`);
  console.log(`Workspace: ${workspace}`);
  console.log(`Prompt: ${path.join(task.dir, task.prompt)}`);
}

async function verifyCommand(taskId, args) {
  const task = await loadTask(taskId);
  const options = parseOptions(args);
  const workspace = resolveWorkspace(task.id, options.workspace);
  const env = benchmarkEnv(task, workspace);

  const startedAt = new Date();
  const verification = await runProcess(task.verify, workspace, env);
  const finishedAt = new Date();
  const usage = await resolveTokenUsage(options, workspace);
  const result = buildResult(task, options, startedAt, finishedAt, verification, usage);
  const resultPath = await writeResult(result);

  console.log(`Verification ${verification.exitCode === 0 ? "passed" : "failed"} for ${task.id}`);
  console.log(`Result: ${resultPath}`);

  if (verification.exitCode !== 0) {
    process.exitCode = verification.exitCode;
  }
}

async function runCommand(taskId, args) {
  const task = await loadTask(taskId);
  const options = parseOptions(args);
  const workspace = resolveWorkspace(task.id, options.workspace);
  const env = benchmarkEnv(task, workspace);

  await prepareWorkspace(task, workspace, env);

  if (!options.agentCommand) {
    throw new Error("run requires --agent-command");
  }

  const promptPath = path.join(task.dir, task.prompt);
  const startedAt = new Date();
  await runShellCommand(options.agentCommand, workspace, {
    ...env,
    CLASP_BENCHMARK_PROMPT_FILE: promptPath
  });
  const verification = await runProcess(task.verify, workspace, env);
  const finishedAt = new Date();
  const usage = await resolveTokenUsage(options, workspace);
  const result = buildResult(task, options, startedAt, finishedAt, verification, usage);
  const resultPath = await writeResult(result);

  console.log(`Completed run for ${task.id}`);
  console.log(`Result: ${resultPath}`);

  if (verification.exitCode !== 0) {
    process.exitCode = verification.exitCode;
  }
}

async function prepareWorkspace(task, workspace, env) {
  await mkdir(path.dirname(workspace), { recursive: true });
  await cp(path.join(task.dir, task.repo), workspace, {
    recursive: true,
    force: true
  });

  for (const command of task.prepare) {
    const result = await runProcess(command, workspace, env);
    if (result.exitCode !== 0) {
      throw new Error(`prepare command failed: ${command.join(" ")}`);
    }
  }

  if (task.language === "clasp") {
    await generateClaspBenchmarkPrep(task, workspace, env);
  }
}

async function generateClaspBenchmarkPrep(task, workspace, env) {
  const entryPath = await resolveClaspEntrypoint(task, workspace);
  const prepRoot = path.join(workspace, "benchmark-prep");
  const moduleName = path.basename(entryPath, ".clasp");
  const contextPath = path.join(prepRoot, `${moduleName}.context.json`);
  const airPath = path.join(prepRoot, `${moduleName}.air.json`);
  const uiPath = path.join(prepRoot, `${moduleName}.ui.json`);
  const explainPath = task.surfaceForm === "verbose"
    ? path.join(prepRoot, `${moduleName}.explain.txt`)
    : null;

  await mkdir(prepRoot, { recursive: true });
  await runClaspCompilerCommand("context", entryPath, contextPath, env);
  await runClaspCompilerCommand("air", entryPath, airPath, env);

  const uiGraph = await renderClaspUiGraph(entryPath, prepRoot, env);
  await writeFile(uiPath, JSON.stringify(uiGraph, null, 2) + "\n", "utf8");

  if (explainPath) {
    const explanation = await renderClaspExplain(entryPath, env);
    await writeFile(explainPath, explanation, "utf8");
  }

  const context = JSON.parse(await readFile(contextPath, "utf8"));
  const air = JSON.parse(await readFile(airPath, "utf8"));
  const guidePath = path.join(workspace, "LANGUAGE_GUIDE.md");
  const guide = renderClaspLanguageGuide({
    workspace,
    entryPath,
    prepRoot,
    moduleName,
    explainPath,
    context,
    air,
    uiGraph
  });

  await writeFile(guidePath, guide, "utf8");
}

async function resolveClaspEntrypoint(task, workspace) {
  const candidates = [];

  if (typeof task.entry === "string" && task.entry.length > 0) {
    candidates.push(task.entry);
  }

  candidates.push("Main.clasp", path.join("app", "Main.clasp"));

  for (const candidate of candidates) {
    const resolved = path.join(workspace, candidate);
    if (await fileExists(resolved)) {
      return resolved;
    }
  }

  throw new Error(
    `unable to locate Clasp entrypoint for ${task.id}; tried: ${candidates.join(", ")}`
  );
}

async function runClaspCompilerCommand(command, inputPath, outputPath, env) {
  const script = [
    "set -euo pipefail",
    `cd ${shellQuote(env.CLASP_PROJECT_ROOT)}`,
    `cabal run claspc -- ${command} ${shellQuote(inputPath)} -o ${shellQuote(outputPath)} >/dev/null 2>/dev/null`
  ].join(" && ");
  const result = await runProcess(
    ["nix", "develop", env.CLASP_PROJECT_ROOT, "--command", "bash", "-lc", script],
    env.CLASP_PROJECT_ROOT,
    env
  );

  if (result.exitCode !== 0) {
    throw new Error(`failed to generate Clasp ${command} artifact for ${inputPath}`);
  }
}

async function renderClaspUiGraph(entryPath, prepRoot, env) {
  const tempModulePath = path.join(prepRoot, ".benchmark-prep-ui.mjs");

  try {
    await runClaspCompilerCommand("compile", entryPath, tempModulePath, env);
    const compiledModule = await import(`${pathToFileURL(tempModulePath).href}?t=${Date.now()}`);
    return compiledModule.__claspUiGraph ?? [];
  } finally {
    await rm(tempModulePath, { force: true });
  }
}

async function renderClaspExplain(entryPath, env) {
  const result = await runClaspStdoutCommand("explain", entryPath, env);

  if (result.exitCode !== 0) {
    throw new Error(`failed to generate Clasp explain artifact for ${entryPath}`);
  }

  return result.stdout;
}

async function runClaspStdoutCommand(command, inputPath, env) {
  const script = [
    "set -euo pipefail",
    `cd ${shellQuote(env.CLASP_PROJECT_ROOT)}`,
    `cabal run claspc -- ${command} ${shellQuote(inputPath)}`
  ].join(" && ");
  return runProcessCapture(
    ["nix", "develop", env.CLASP_PROJECT_ROOT, "--command", "bash", "-lc", script],
    env.CLASP_PROJECT_ROOT,
    env
  );
}

function renderClaspLanguageGuide({
  workspace,
  entryPath,
  prepRoot,
  moduleName,
  explainPath,
  context,
  air,
  uiGraph
}) {
  const sourceFiles = collectArtifactSourceFiles(workspace, context, air);
  const routes = collectContextRoutes(context);
  const foreignDecls = collectContextForeignDecls(context);
  const artifactPaths = [
    path.join(prepRoot, `${moduleName}.context.json`),
    path.join(prepRoot, `${moduleName}.air.json`),
    path.join(prepRoot, `${moduleName}.ui.json`)
  ];

  if (explainPath) {
    artifactPaths.push(explainPath);
  }

  const relativeArtifactPaths = artifactPaths.map((targetPath) => path.relative(workspace, targetPath));

  const lines = [
    "# Clasp Workspace Guide",
    "",
    "This workspace includes compiler-generated benchmark prep artifacts under `benchmark-prep/`.",
    "",
    "## Where to start",
    "",
    `- Entry module: \`${path.relative(workspace, entryPath)}\``
  ];

  if (sourceFiles.length > 0) {
    lines.push("- Clasp source files in the semantic pack:");
    for (const sourceFile of sourceFiles) {
      lines.push(`  - \`${sourceFile}\``);
    }
  }

  lines.push("", "## Semantic pack");
  lines.push("");
  for (const artifactPath of relativeArtifactPaths) {
    lines.push(`- \`${artifactPath}\``);
  }

  if (explainPath) {
    lines.push(
      "",
      "## Expanded surface",
      "",
      `- \`${path.relative(workspace, explainPath)}\` is the compiler-generated human-readable rendering of the entry module.`
    );
  }

  lines.push("", "## Routes and boundaries", "");

  if (routes.length === 0) {
    lines.push("- No typed routes were found in the generated context graph.");
  } else {
    for (const route of routes) {
      lines.push(
        `- \`${route.method} ${route.path}\` request \`${route.requestType}\` -> response \`${route.responseType}\``
      );
    }
  }

  if (foreignDecls.length === 0) {
    lines.push("- No foreign runtime boundaries were found in the generated context graph.");
  } else {
    lines.push("- Foreign runtime boundaries:");
    for (const foreignDecl of foreignDecls) {
      lines.push(`  - \`${foreignDecl.name} : ${foreignDecl.type}\``);
    }
  }

  lines.push("", "## UI graph", "");

  if (uiGraph.length === 0) {
    lines.push("- No page routes were exported in the compiled UI graph for this task.");
  } else {
    for (const page of uiGraph) {
      lines.push(
        `- \`${page.routeName}\` at \`${page.path}\`${page.title ? ` titled "${page.title}"` : ""}`
      );
    }
  }

  lines.push(
    "",
    "## Acceptance loop",
    "",
    "- Use `bash scripts/verify.sh` for the final check.",
    "- Let `verify.sh` regenerate `build/Main.js`.",
    "- Prefer the Clasp schema and route files before touching runtime glue."
  );

  return lines.join("\n") + "\n";
}

function collectArtifactSourceFiles(workspace, ...artifacts) {
  const sourceFiles = new Set();

  for (const artifact of artifacts) {
    for (const filePath of collectArtifactFilePaths(artifact)) {
      if (!filePath.endsWith(".clasp")) {
        continue;
      }
      if (filePath.startsWith("<")) {
        continue;
      }

      sourceFiles.add(path.relative(workspace, filePath));
    }
  }

  return [...sourceFiles].sort((left, right) => left.localeCompare(right));
}

function collectArtifactFilePaths(value) {
  if (Array.isArray(value)) {
    return value.flatMap((entry) => collectArtifactFilePaths(entry));
  }

  if (value && typeof value === "object") {
    const current = typeof value.file === "string" ? [value.file] : [];
    return current.concat(
      Object.values(value).flatMap((entry) => collectArtifactFilePaths(entry))
    );
  }

  return [];
}

function collectContextRoutes(context) {
  return (context.nodes ?? [])
    .filter((node) => node.kind === "route")
    .map((node) => {
      const attrs = attrsToRecord(node.attrs);
      return {
        method: String(attrs.method ?? "UNKNOWN"),
        path: String(attrs.path ?? "/"),
        requestType: String(attrs.requestType ?? "Unknown"),
        responseType: String(attrs.responseType ?? "Unknown")
      };
    });
}

function collectContextForeignDecls(context) {
  return (context.nodes ?? [])
    .filter((node) => node.kind === "foreign")
    .map((node) => {
      const attrs = attrsToRecord(node.attrs);
      return {
        name: String(attrs.name ?? "unknown"),
        type: String(attrs.type ?? "Unknown")
      };
    });
}

function attrsToRecord(attrs) {
  const record = {};

  for (const attr of attrs ?? []) {
    record[attr.name] = attr.value;
  }

  return record;
}

function shellQuote(value) {
  return `'${String(value).replaceAll("'", "'\"'\"'")}'`;
}

async function summarizeCommand(args) {
  const options = parseOptions(args);
  const results = await loadResults();
  const filtered = results.filter((result) => matchesSummaryFilter(result, options));

  if (filtered.length === 0) {
    throw new Error("no results matched the supplied filters");
  }

  const grouped = groupBy(filtered, (result) => {
    const series = parseSeriesRun(result.notes).series ?? "";
    return [result.taskId, result.harness, result.model, series].join("\t");
  });

  for (const [groupKey, groupResults] of grouped.entries()) {
    const [taskId, harness, model, series] = groupKey.split("\t");
    const summary = summarizeGroup(groupResults);

    console.log(`${taskId}\t${harness}\t${model}`);
    if (series) {
      console.log(`  series: ${series}`);
    }
    console.log(`  runs: ${summary.runs}`);
    console.log(`  passRate: ${summary.passRate}`);
    console.log(`  timeToGreenMs: ${summary.timeToGreenMs}`);
    console.log(`  medianDurationMs: ${summary.medianDurationMs}`);
    console.log(`  medianTokens: ${summary.medianTokens}`);
    console.log(`  medianUncachedTokens: ${summary.medianUncachedTokens}`);
  }

  const comparisonSections = buildTaskFamilyComparisons(filtered);
  for (const section of comparisonSections) {
    console.log(section.comparisonLabel);

    for (const comparison of section.comparisons) {
      console.log(
        `  ${comparison.harness}\t${comparison.model}\t${comparison.series}`
      );
      console.log(
        `    ${buildComparisonMetricKey(comparison.leftLabel, "PassRate")}: ${comparison.left.passRate}`
      );
      console.log(
        `    ${buildComparisonMetricKey(comparison.rightLabel, "PassRate")}: ${comparison.right.passRate}`
      );
      console.log(`    passRateDeltaPct: ${comparison.passRateDeltaPct}`);
      console.log(
        `    ${buildComparisonMetricKey(comparison.leftLabel, "TimeToGreenMs")}: ${comparison.left.timeToGreenMs}`
      );
      console.log(
        `    ${buildComparisonMetricKey(comparison.rightLabel, "TimeToGreenMs")}: ${comparison.right.timeToGreenMs}`
      );
      console.log(`    timeToGreenDeltaMs: ${comparison.timeToGreenDeltaMs}`);
      console.log(
        `    ${buildComparisonMetricKey(comparison.leftLabel, "MedianTokens")}: ${comparison.left.medianTokens}`
      );
      console.log(
        `    ${buildComparisonMetricKey(comparison.rightLabel, "MedianTokens")}: ${comparison.right.medianTokens}`
      );
      console.log(`    tokenDelta: ${comparison.tokenDelta}`);
      console.log(
        `    uncachedTokenDelta: ${comparison.uncachedTokenDelta}`
      );
    }
  }

  const publicAppComparisons = buildPublicAppComparisons(filtered);
  if (publicAppComparisons.length > 0) {
    console.log(publicAppBenchmark.comparisonLabel);

    for (const comparison of publicAppComparisons) {
      console.log(
        `  ${comparison.harness}\t${comparison.model}\t${comparison.series}`
      );
      console.log(`    taskPairs: ${comparison.taskPairs}`);
      console.log(
        `    ${buildComparisonMetricKey(comparison.leftLabel, "CompletedTasks")}: ${comparison.left.completedTasks}/${comparison.taskPairs}`
      );
      console.log(
        `    ${buildComparisonMetricKey(comparison.rightLabel, "CompletedTasks")}: ${comparison.right.completedTasks}/${comparison.taskPairs}`
      );
      console.log(
        `    ${buildComparisonMetricKey(comparison.leftLabel, "RunPassRate")}: ${comparison.left.runPassRate}`
      );
      console.log(
        `    ${buildComparisonMetricKey(comparison.rightLabel, "RunPassRate")}: ${comparison.right.runPassRate}`
      );
      console.log(`    passRateDeltaPct: ${comparison.passRateDeltaPct}`);
      console.log(
        `    ${buildComparisonMetricKey(comparison.leftLabel, "SuiteTimeToGreenMs")}: ${comparison.left.suiteTimeToGreenMs}`
      );
      console.log(
        `    ${buildComparisonMetricKey(comparison.rightLabel, "SuiteTimeToGreenMs")}: ${comparison.right.suiteTimeToGreenMs}`
      );
      console.log(`    timeToGreenDeltaMs: ${comparison.timeToGreenDeltaMs}`);
      console.log(
        `    ${buildComparisonMetricKey(comparison.leftLabel, "SuiteMedianTokens")}: ${comparison.left.suiteMedianTokens}`
      );
      console.log(
        `    ${buildComparisonMetricKey(comparison.rightLabel, "SuiteMedianTokens")}: ${comparison.right.suiteMedianTokens}`
      );
      console.log(`    tokenDelta: ${comparison.tokenDelta}`);
      console.log(
        `    uncachedTokenDelta: ${comparison.uncachedTokenDelta}`
      );
    }
  }
}

function summarizeGroup(groupResults) {
  const ordered = [...groupResults].sort(compareRunOrder);
  const passed = ordered.filter((result) => result.verification.passed).length;
  const durations = ordered.map((result) => result.durationMs);
  const totals = ordered.map((result) => result.tokenUsage.total);
  const uncached = ordered.map(
    (result) => result.harnessUsage?.uncachedTotal ?? result.tokenUsage.total
  );
  const firstGreenIndex = ordered.findIndex((result) => result.verification.passed);
  const timeToGreenMs = firstGreenIndex === -1
    ? "n/a"
    : ordered
      .slice(0, firstGreenIndex + 1)
      .reduce((total, result) => total + result.durationMs, 0);

  return {
    runs: ordered.length,
    passedRuns: passed,
    passRate: `${(passed / ordered.length * 100).toFixed(0)}%`,
    passRatePct: passed / ordered.length * 100,
    timeToGreenMs,
    medianDurationMs: median(durations),
    medianTokens: median(totals),
    medianUncachedTokens: median(uncached)
  };
}

function buildTaskFamilyComparisons(results) {
  return comparisonTaskFamilies
    .map((family) => ({
      comparisonLabel: family.comparisonLabel,
      comparisons: buildTaskComparisons(results, family)
    }))
    .filter((section) => section.comparisons.length > 0);
}

function buildPublicAppComparisons(results) {
  const relevantTaskIds = new Set(
    publicAppBenchmark.taskPairs.flatMap((pair) => [pair.leftTaskId, pair.rightTaskId])
  );
  const relevant = results.filter((result) => relevantTaskIds.has(result.taskId));
  const grouped = groupBy(relevant, (result) => {
    const series = parseSeriesRun(result.notes).series ?? "";
    return [result.harness, result.model, series].join("\t");
  });
  const comparisons = [];

  for (const [groupKey, groupResults] of grouped.entries()) {
    const [harness, model, series] = groupKey.split("\t");
    const byTask = groupBy(groupResults, (result) => result.taskId);
    const leftTaskSummaries = [];
    const rightTaskSummaries = [];

    for (const pair of publicAppBenchmark.taskPairs) {
      const leftResults = byTask.get(pair.leftTaskId);
      const rightResults = byTask.get(pair.rightTaskId);

      if (!leftResults || !rightResults) {
        leftTaskSummaries.length = 0;
        rightTaskSummaries.length = 0;
        break;
      }

      leftTaskSummaries.push(summarizeGroup(leftResults));
      rightTaskSummaries.push(summarizeGroup(rightResults));
    }

    if (leftTaskSummaries.length !== publicAppBenchmark.taskPairs.length) {
      continue;
    }

    const left = summarizeBenchmarkSuite(leftTaskSummaries);
    const right = summarizeBenchmarkSuite(rightTaskSummaries);
    comparisons.push({
      harness,
      model,
      series: series || "(all-runs)",
      taskPairs: publicAppBenchmark.taskPairs.length,
      leftLabel: publicAppBenchmark.leftLabel,
      rightLabel: publicAppBenchmark.rightLabel,
      left,
      right,
      passRateDeltaPct: Math.round(left.runPassRatePct - right.runPassRatePct),
      timeToGreenDeltaMs:
        typeof left.suiteTimeToGreenMs === "number" && typeof right.suiteTimeToGreenMs === "number"
          ? left.suiteTimeToGreenMs - right.suiteTimeToGreenMs
          : "n/a",
      tokenDelta: left.suiteMedianTokens - right.suiteMedianTokens,
      uncachedTokenDelta:
        left.suiteMedianUncachedTokens - right.suiteMedianUncachedTokens
    });
  }

  return comparisons.sort((left, right) =>
    [left.harness, left.model, left.series].join("\t").localeCompare(
      [right.harness, right.model, right.series].join("\t")
    )
  );
}

function summarizeBenchmarkSuite(taskSummaries) {
  const totalRuns = taskSummaries.reduce((sum, summary) => sum + summary.runs, 0);
  const totalPassedRuns = taskSummaries.reduce((sum, summary) => sum + summary.passedRuns, 0);
  const completedTasks = taskSummaries.filter(
    (summary) => typeof summary.timeToGreenMs === "number"
  ).length;
  const suiteTimeToGreenMs = completedTasks === taskSummaries.length
    ? taskSummaries.reduce((sum, summary) => sum + summary.timeToGreenMs, 0)
    : "n/a";

  return {
    completedTasks,
    runPassRate: `${(totalPassedRuns / totalRuns * 100).toFixed(0)}%`,
    runPassRatePct: totalPassedRuns / totalRuns * 100,
    suiteTimeToGreenMs,
    suiteMedianTokens: taskSummaries.reduce((sum, summary) => sum + summary.medianTokens, 0),
    suiteMedianUncachedTokens: taskSummaries.reduce(
      (sum, summary) => sum + summary.medianUncachedTokens,
      0
    )
  };
}

function buildTaskComparisons(results, family) {
  const relevantTaskIds = new Set([family.leftTaskId, family.rightTaskId]);
  const relevant = results.filter((result) => relevantTaskIds.has(result.taskId));
  const grouped = groupBy(relevant, (result) => {
    const series = parseSeriesRun(result.notes).series ?? "";
    return [result.harness, result.model, series].join("\t");
  });
  const comparisons = [];

  for (const [groupKey, groupResults] of grouped.entries()) {
    const [harness, model, series] = groupKey.split("\t");
    const byTask = groupBy(groupResults, (result) => result.taskId);
    const leftResults = byTask.get(family.leftTaskId);
    const rightResults = byTask.get(family.rightTaskId);

    if (!leftResults || !rightResults) {
      continue;
    }

    const left = summarizeGroup(leftResults);
    const right = summarizeGroup(rightResults);
    comparisons.push({
      harness,
      model,
      series: series || "(all-runs)",
      leftLabel: family.leftLabel,
      rightLabel: family.rightLabel,
      left,
      right,
      passRateDeltaPct: Math.round(left.passRatePct - right.passRatePct),
      timeToGreenDeltaMs:
        typeof left.timeToGreenMs === "number" && typeof right.timeToGreenMs === "number"
          ? left.timeToGreenMs - right.timeToGreenMs
          : "n/a",
      tokenDelta: left.medianTokens - right.medianTokens,
      uncachedTokenDelta:
        left.medianUncachedTokens - right.medianUncachedTokens
    });
  }

  return comparisons.sort((left, right) =>
    [left.harness, left.model, left.series].join("\t").localeCompare(
      [right.harness, right.model, right.series].join("\t")
    )
  );
}

function buildComparisonMetricKey(label, suffix) {
  return `${label}${suffix}`;
}

function buildResult(task, options, startedAt, finishedAt, verification, usage) {
  const prompt = usage?.prompt ?? parseNumber(options.promptTokens);
  const completion = usage?.completion ?? parseNumber(options.completionTokens);
  const retry = usage?.retry ?? parseNumber(options.retryTokens);
  const debug = usage?.debug ?? parseNumber(options.debugTokens);
  const tokenUsage = {
    prompt,
    completion,
    retry,
    debug,
    total: prompt + completion + retry + debug
  };

  return {
    taskId: task.id,
    suite: task.suite,
    language: task.language,
    harness: options.harness ?? "unspecified",
    model: options.model ?? "unspecified",
    startedAt: startedAt.toISOString(),
    finishedAt: finishedAt.toISOString(),
    durationMs: finishedAt.getTime() - startedAt.getTime(),
    humanInterventions: parseNumber(options.interventions),
    notes: options.notes ?? "",
    tokenUsage,
    harnessUsage: usage?.harnessUsage,
    verification: {
      passed: verification.exitCode === 0,
      command: task.verify,
      exitCode: verification.exitCode
    }
  };
}

async function writeResult(result) {
  await mkdir(resultsRoot, { recursive: true });
  const stamp = result.finishedAt.replaceAll(":", "-");
  const filename = `${stamp}--${result.taskId}--${result.harness}.json`;
  const resultPath = path.join(resultsRoot, filename);
  await writeFile(resultPath, JSON.stringify(result, null, 2) + "\n", "utf8");
  return resultPath;
}

async function loadTasks() {
  const entries = await readdir(tasksRoot, { withFileTypes: true });
  const tasks = [];

  for (const entry of entries) {
    if (!entry.isDirectory()) {
      continue;
    }

    tasks.push(await loadTask(entry.name));
  }

  return tasks.sort((left, right) => left.id.localeCompare(right.id));
}

async function loadResults() {
  const entries = await readdir(resultsRoot, { withFileTypes: true });
  const results = [];

  for (const entry of entries) {
    if (!entry.isFile() || !entry.name.endsWith(".json")) {
      continue;
    }

    const resultPath = path.join(resultsRoot, entry.name);
    const result = JSON.parse(await readFile(resultPath, "utf8"));
    results.push(result);
  }

  return results.sort((left, right) => left.finishedAt.localeCompare(right.finishedAt));
}

async function loadTask(taskId) {
  if (!taskId) {
    throw new Error("task id is required");
  }

  const taskDir = path.join(tasksRoot, taskId);
  const manifestPath = path.join(taskDir, "task.json");
  const manifest = JSON.parse(await readFile(manifestPath, "utf8"));

  return {
    ...manifest,
    dir: taskDir
  };
}

function benchmarkEnv(task, workspace) {
  return {
    ...process.env,
    CLASP_PROJECT_ROOT: path.resolve("."),
    CLASP_BENCHMARK_ROOT: benchmarkRoot,
    CLASP_BENCHMARK_TASK_ID: task.id,
    CLASP_BENCHMARK_WORKSPACE: workspace,
    CLASP_APP_FIXTURE_SEED: resolveFixtureSeed(task.id)
  };
}

function resolveFixtureSeed(taskId) {
  const suppliedSeed = process.env.CLASP_APP_FIXTURE_SEED;
  return suppliedSeed && suppliedSeed.length > 0 ? suppliedSeed : taskId;
}

function resolveWorkspace(taskId, suppliedWorkspace) {
  return path.resolve(suppliedWorkspace ?? path.join(benchmarkRoot, "workspaces", taskId));
}

function parseOptions(args) {
  const options = {};

  for (let index = 0; index < args.length; index += 1) {
    const current = args[index];
    if (!current.startsWith("--")) {
      throw new Error(`unexpected argument: ${current}`);
    }

    const key = current.slice(2).replace(/-([a-z])/g, (_, letter) => letter.toUpperCase());
    const value = args[index + 1];

    if (!value || value.startsWith("--")) {
      throw new Error(`missing value for ${current}`);
    }

    options[key] = value;
    index += 1;
  }

  return options;
}

async function resolveTokenUsage(options, workspace) {
  if (hasAnyTokenOption(options)) {
    return {
      prompt: parseNumber(options.promptTokens),
      completion: parseNumber(options.completionTokens),
      retry: parseNumber(options.retryTokens),
      debug: parseNumber(options.debugTokens)
    };
  }

  const agentLogFile = options.agentLogFile
    ? path.resolve(options.agentLogFile)
    : defaultAgentLogFile(options.harness, workspace);

  if (!(await fileExists(agentLogFile))) {
    return null;
  }

  if (options.harness === "codex") {
    return readCodexUsage(agentLogFile);
  }

  if (options.harness === "claude-code") {
    return readClaudeCodeUsage(agentLogFile);
  }

  return null;
}

function defaultAgentLogFile(harness, workspace) {
  if (harness === "claude-code") {
    return path.join(workspace, "claude-run.jsonl");
  }

  return path.join(workspace, "codex-run.jsonl");
}

function parseNumber(value) {
  if (!value) {
    return 0;
  }

  const parsed = Number.parseInt(value, 10);
  if (Number.isNaN(parsed) || parsed < 0) {
    throw new Error(`invalid numeric value: ${value}`);
  }

  return parsed;
}

function hasAnyTokenOption(options) {
  return (
    options.promptTokens ||
    options.completionTokens ||
    options.retryTokens ||
    options.debugTokens
  );
}

async function readCodexUsage(agentLogFile) {
  const content = await readFile(agentLogFile, "utf8");
  const lines = content
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.length > 0)
    .map((line) => JSON.parse(line));
  const completion = [...lines].reverse().find((line) => line.type === "turn.completed");

  if (!completion?.usage) {
    throw new Error(`no completed Codex usage found in ${agentLogFile}`);
  }

  const input = parseNumber(String(completion.usage.input_tokens ?? 0));
  const cachedInput = parseNumber(String(completion.usage.cached_input_tokens ?? 0));
  const output = parseNumber(String(completion.usage.output_tokens ?? 0));

  return {
    prompt: input,
    completion: output,
    retry: 0,
    debug: 0,
    harnessUsage: {
      provider: "codex",
      agentLogFile,
      inputTokens: input,
      cachedInputTokens: cachedInput,
      outputTokens: output,
      uncachedInputTokens: Math.max(0, input - cachedInput),
      uncachedTotal: Math.max(0, input - cachedInput) + output
    }
  };
}

async function readClaudeCodeUsage(agentLogFile) {
  const content = await readFile(agentLogFile, "utf8");
  const lines = content
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.length > 0)
    .map((line) => JSON.parse(line));
  const usageRecords = lines
    .filter((line) => line.type === "assistant" && line.message?.usage)
    .map((line) => line.message.usage);

  if (usageRecords.length === 0) {
    throw new Error(`no Claude Code assistant usage found in ${agentLogFile}`);
  }

  const totals = usageRecords.reduce(
    (aggregate, usage) => ({
      input: aggregate.input + parseNumber(String(usage.input_tokens ?? 0)),
      cacheCreation:
        aggregate.cacheCreation +
        parseNumber(String(usage.cache_creation_input_tokens ?? 0)),
      cacheRead:
        aggregate.cacheRead + parseNumber(String(usage.cache_read_input_tokens ?? 0)),
      output: aggregate.output + parseNumber(String(usage.output_tokens ?? 0))
    }),
    { input: 0, cacheCreation: 0, cacheRead: 0, output: 0 }
  );
  const prompt = totals.input + totals.cacheCreation + totals.cacheRead;

  return {
    prompt,
    completion: totals.output,
    retry: 0,
    debug: 0,
    harnessUsage: {
      provider: "claude-code",
      agentLogFile,
      inputTokens: prompt,
      cachedInputTokens: totals.cacheRead,
      outputTokens: totals.output,
      uncachedInputTokens: totals.input + totals.cacheCreation,
      uncachedTotal: totals.input + totals.cacheCreation + totals.output
    }
  };
}

async function fileExists(targetPath) {
  try {
    await stat(targetPath);
    return true;
  } catch {
    return false;
  }
}

function matchesSummaryFilter(result, options) {
  if (options.taskId && result.taskId !== options.taskId) {
    return false;
  }

  if (options.harness && result.harness !== options.harness) {
    return false;
  }

  if (options.model && result.model !== options.model) {
    return false;
  }

  if (options.language && result.language !== options.language) {
    return false;
  }

  if (options.notes && !String(result.notes ?? "").includes(options.notes)) {
    return false;
  }

  return true;
}

function groupBy(values, keyFor) {
  const groups = new Map();

  for (const value of values) {
    const key = keyFor(value);
    const existing = groups.get(key) ?? [];
    existing.push(value);
    groups.set(key, existing);
  }

  return groups;
}

function parseSeriesRun(notes) {
  const note = String(notes ?? "").trim();
  const match = /^(.*)-(\d+)$/.exec(note);

  if (!match || match[1].length === 0) {
    return {
      series: null,
      runNumber: null
    };
  }

  return {
    series: match[1],
    runNumber: Number.parseInt(match[2], 10)
  };
}

function compareRunOrder(left, right) {
  const leftSeries = parseSeriesRun(left.notes);
  const rightSeries = parseSeriesRun(right.notes);

  if (leftSeries.runNumber !== null && rightSeries.runNumber !== null) {
    return leftSeries.runNumber - rightSeries.runNumber;
  }

  return left.finishedAt.localeCompare(right.finishedAt);
}

function median(values) {
  const sorted = [...values].sort((left, right) => left - right);
  const middle = Math.floor(sorted.length / 2);

  if (sorted.length % 2 === 1) {
    return sorted[middle];
  }

  return Math.round((sorted[middle - 1] + sorted[middle]) / 2);
}

async function runProcess(command, cwd, env = process.env) {
  return new Promise((resolve, reject) => {
    const child = spawn(command[0], command.slice(1), {
      cwd,
      stdio: "inherit",
      env
    });

    child.on("error", reject);
    child.on("exit", (exitCode) => {
      resolve({
        exitCode: exitCode ?? 1
      });
    });
  });
}

async function runProcessCapture(command, cwd, env = process.env) {
  return new Promise((resolve, reject) => {
    const child = spawn(command[0], command.slice(1), {
      cwd,
      env,
      stdio: ["ignore", "pipe", "inherit"]
    });
    let stdout = "";

    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });

    child.on("error", reject);
    child.on("exit", (exitCode) => {
      resolve({
        exitCode: exitCode ?? 1,
        stdout
      });
    });
  });
}

async function runShellCommand(command, cwd, env) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, {
      cwd,
      env,
      shell: true,
      stdio: "inherit"
    });

    child.on("error", reject);
    child.on("exit", (exitCode) => {
      if (exitCode === 0) {
        resolve();
      } else {
        reject(new Error(`agent command failed with exit code ${exitCode ?? 1}`));
      }
    });
  });
}

function usage() {
  console.error("usage:");
  console.error("  node benchmarks/run-benchmark.mjs list");
  console.error("  node benchmarks/run-benchmark.mjs prepare <task-id> [--workspace path]");
  console.error("  node benchmarks/run-benchmark.mjs verify <task-id> --workspace path [--harness name --model name --interventions n --prompt-tokens n --completion-tokens n --retry-tokens n --debug-tokens n --notes text]");
  console.error("  node benchmarks/run-benchmark.mjs run <task-id> --workspace path --agent-command command [--harness name --model name --interventions n --prompt-tokens n --completion-tokens n --retry-tokens n --debug-tokens n --notes text]");
  console.error("  node benchmarks/run-benchmark.mjs summarize [--task-id id --harness name --model name --language name --notes text]");
}

await main();
