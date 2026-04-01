#!/usr/bin/env node

import { readFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { spawn } from "node:child_process";

import {
  buildBenchmarkSuiteComparisons,
  loadResults,
  matchesSummaryFilter,
  publicAppBenchmark
} from "./run-benchmark.mjs";

const projectRoot = path.resolve(".");
const benchmarkRoot = path.join(projectRoot, "benchmarks");
const defaultTaskSet = "app";
const defaultHarness = "codex";
const defaultModel = "gpt-5.4";
const defaultMode = "raw-repo";
const defaultWorkflowAssistance = "unspecified";

function parseArgs(argv) {
  const options = {
    taskSet: defaultTaskSet,
    count: 1,
    notes: "",
    harness: defaultHarness,
    model: defaultModel,
    mode: defaultMode,
    workflowAssistance: defaultWorkflowAssistance,
    skipRun: false
  };

  for (let index = 0; index < argv.length; index += 1) {
    const current = argv[index];
    if (!current.startsWith("--")) {
      throw new Error(`unexpected argument: ${current}`);
    }

    const key = current.slice(2);
    if (key === "skip-run") {
      const value = argv[index + 1];
      if (value !== "true" && value !== "false") {
        throw new Error(`expected true/false for ${current}`);
      }
      options.skipRun = value === "true";
      index += 1;
      continue;
    }

    const value = argv[index + 1];
    if (value === undefined || value.startsWith("--")) {
      throw new Error(`missing value for ${current}`);
    }

    if (key === "task-set") {
      options.taskSet = value;
    } else if (key === "count") {
      const parsed = Number.parseInt(value, 10);
      if (!Number.isInteger(parsed) || parsed < 1) {
        throw new Error(`invalid count: ${value}`);
      }
      options.count = parsed;
    } else if (key === "notes") {
      options.notes = value;
    } else if (key === "harness") {
      options.harness = value;
    } else if (key === "model") {
      options.model = value;
    } else if (key === "mode") {
      options.mode = value;
    } else if (key === "workflow-assistance") {
      options.workflowAssistance = value;
    } else {
      throw new Error(`unknown option: ${current}`);
    }

    index += 1;
  }

  return options;
}

function benchmarkSignal({
  summary,
  passed,
  meetsTarget,
  scoreValue,
  targetValue
}) {
  return {
    suite: "main-public-app-comparison",
    summary,
    passed,
    meetsTarget,
    scoreName: "throughputDeltaPct",
    scoreValue,
    targetName: "minThroughputDeltaPct",
    targetValue
  };
}

function utcSlugNow() {
  return new Date().toISOString().replace(/[:.]/g, "-");
}

function shellQuote(value) {
  return `'${String(value).replace(/'/g, `'\"'\"'`)}'`;
}

function buildAgentCommand(model) {
  const harnessPath = path.join(projectRoot, "benchmarks", "run-codex-harness.sh");
  return `CODEX_MODEL=${shellQuote(model)} CODEX_REASONING_EFFORT=high bash ${shellQuote(harnessPath)} "$CLASP_BENCHMARK_PROMPT_FILE" "$CLASP_BENCHMARK_WORKSPACE"`;
}

async function runProcess(command, cwd, env, { allowFailure = false } = {}) {
  return await new Promise((resolve, reject) => {
    const child = spawn(command[0], command.slice(1), {
      cwd,
      env,
      stdio: ["ignore", "pipe", "pipe"]
    });
    let stdout = "";
    let stderr = "";

    child.stdout.on("data", (chunk) => {
      const text = chunk.toString();
      stdout += text;
      process.stdout.write(text);
    });

    child.stderr.on("data", (chunk) => {
      const text = chunk.toString();
      stderr += text;
      process.stderr.write(text);
    });

    child.on("error", reject);
    child.on("exit", (exitCode) => {
      const result = {
        exitCode: exitCode ?? 1,
        stdout,
        stderr
      };

      if (!allowFailure && result.exitCode !== 0) {
        reject(new Error(stderr.trim() || stdout.trim() || `command failed: ${command.join(" ")}`));
        return;
      }

      resolve(result);
    });
  });
}

async function loadBundle(bundleManifestPath) {
  return JSON.parse(await readFile(bundleManifestPath, "utf8"));
}

async function runPublicAppSeries(options, notePrefix) {
  const workflowSlug = options.workflowAssistance
    .toLowerCase()
    .replace(/[^a-z0-9._-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    || "unspecified";
  const bundleManifestPath = path.join(
    benchmarkRoot,
    "bundles",
    `${notePrefix}--codex--${options.model.replaceAll("/", "-")}--${options.mode}--workflow-assistance-${workflowSlug}.json`
  );
  const env = {
    ...process.env,
    CLASP_BENCHMARK_WORKFLOW_ASSISTANCE: options.workflowAssistance
  };

  await runProcess(
    [
      "node",
      path.join(benchmarkRoot, "run-benchmark.mjs"),
      "freeze",
      options.taskSet,
      "--count",
      String(options.count),
      "--harness",
      options.harness,
      "--model",
      options.model,
      "--mode",
      options.mode,
      "--notes",
      notePrefix,
      "--output",
      bundleManifestPath,
      "--allow-bootstrap-recovery",
      process.env.CLASP_ALLOW_BOOTSTRAP_RECOVERY === "true" ? "true" : "false"
    ],
    projectRoot,
    env
  );

  const bundle = await loadBundle(bundleManifestPath);
  for (const sample of bundle.samples ?? []) {
    const note = `${notePrefix}-${sample.sampleIndex}`;
    for (const entry of sample.runOrder ?? []) {
      const workspace = path.join(benchmarkRoot, "workspaces", `${entry.taskId}-${note}`);
      await runProcess(
        [
          "node",
          path.join(benchmarkRoot, "run-benchmark.mjs"),
          "run",
          entry.taskId,
          "--workspace",
          workspace,
          "--harness",
          options.harness,
          "--model",
          options.model,
          "--mode",
          options.mode,
          "--notes",
          note,
          "--bundle-manifest",
          bundleManifestPath,
          "--sample-count",
          String(options.count),
          "--sample-index",
          String(sample.sampleIndex),
          "--agent-command",
          buildAgentCommand(options.model),
          "--allow-bootstrap-recovery",
          process.env.CLASP_ALLOW_BOOTSTRAP_RECOVERY === "true" ? "true" : "false"
        ],
        projectRoot,
        env,
        { allowFailure: true }
      );
    }
  }
}

function selectPublicAppComparison(results, options, notePrefix) {
  const filtered = results.filter((result) =>
    matchesSummaryFilter(result, {
      harness: options.harness,
      model: options.model,
      mode: options.mode,
      workflowAssistance: options.workflowAssistance,
      notes: notePrefix
    })
  );
  const comparisons = buildBenchmarkSuiteComparisons(filtered, publicAppBenchmark);

  return comparisons.find((comparison) =>
    comparison.harness === options.harness &&
    comparison.model === options.model &&
    comparison.mode === options.mode &&
    comparison.workflowAssistance === options.workflowAssistance &&
    comparison.series === notePrefix
  ) ?? null;
}

function computeSignalFromComparison(comparison) {
  if (comparison === null) {
    return benchmarkSignal({
      summary: "Public app benchmark did not produce a full Clasp vs TypeScript comparison.",
      passed: false,
      meetsTarget: false,
      scoreValue: -100,
      targetValue: 0
    });
  }

  const completedOk = comparison.left.completedTasks === comparison.taskPairs &&
    comparison.left.completedTasks >= comparison.right.completedTasks;
  const passRateOk = comparison.left.runPassRatePct >= comparison.right.runPassRatePct;
  const timeOk = typeof comparison.left.suiteTimeToGreenMs === "number" &&
    typeof comparison.right.suiteTimeToGreenMs === "number" &&
    comparison.left.suiteTimeToGreenMs <= comparison.right.suiteTimeToGreenMs;
  const uncachedOk = typeof comparison.left.suiteMedianUncachedTokens === "number" &&
    typeof comparison.right.suiteMedianUncachedTokens === "number" &&
    comparison.left.suiteMedianUncachedTokens <= comparison.right.suiteMedianUncachedTokens;
  const throughputDelta = typeof comparison.throughputDeltaPct === "number"
    ? comparison.throughputDeltaPct
    : -100;
  const meetsTarget = completedOk && passRateOk && timeOk && uncachedOk && throughputDelta >= 0;
  const summary =
    `${meetsTarget ? "Clasp meets the public app benchmark target." : "Clasp is still behind the public app benchmark target."} ` +
    `completed=${comparison.left.completedTasks}/${comparison.taskPairs} vs ts=${comparison.right.completedTasks}/${comparison.taskPairs}; ` +
    `timeToGreenDeltaMs=${comparison.timeToGreenDeltaMs}; ` +
    `uncachedTokenDelta=${comparison.uncachedTokenDelta}; ` +
    `throughputDeltaPct=${comparison.throughputDeltaPct}.`;

  return benchmarkSignal({
    summary,
    passed: true,
    meetsTarget,
    scoreValue: throughputDelta,
    targetValue: 0
  });
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const notePrefix = options.notes || `public-app-live-${utcSlugNow()}`;

  try {
    if (!options.skipRun) {
      await runPublicAppSeries(options, notePrefix);
    }

    const results = await loadResults();
    const comparison = selectPublicAppComparison(results, options, notePrefix);
    console.log(JSON.stringify(computeSignalFromComparison(comparison)));
  } catch (error) {
    const summary = error instanceof Error ? error.message : String(error);
    console.log(JSON.stringify(benchmarkSignal({
      summary: `Public app benchmark run failed: ${summary}`,
      passed: false,
      meetsTarget: false,
      scoreValue: -100,
      targetValue: 0
    })));
  }
}

await main();
