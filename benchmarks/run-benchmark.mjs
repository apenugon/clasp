#!/usr/bin/env node

import { cp, mkdir, readdir, readFile, writeFile, stat } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { spawn } from "node:child_process";

const benchmarkRoot = path.resolve("benchmarks");
const tasksRoot = path.join(benchmarkRoot, "tasks");
const resultsRoot = path.join(benchmarkRoot, "results");

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
}

async function summarizeCommand(args) {
  const options = parseOptions(args);
  const results = await loadResults();
  const filtered = results.filter((result) => matchesSummaryFilter(result, options));

  if (filtered.length === 0) {
    throw new Error("no results matched the supplied filters");
  }

  const grouped = groupBy(filtered, (result) =>
    [result.taskId, result.harness, result.model].join("\t")
  );

  for (const [groupKey, groupResults] of grouped.entries()) {
    const [taskId, harness, model] = groupKey.split("\t");
    const passed = groupResults.filter((result) => result.verification.passed).length;
    const durations = groupResults.map((result) => result.durationMs);
    const totals = groupResults.map((result) => result.tokenUsage.total);
    const uncached = groupResults.map((result) => result.harnessUsage?.uncachedTotal ?? result.tokenUsage.total);

    console.log(`${taskId}\t${harness}\t${model}`);
    console.log(`  runs: ${groupResults.length}`);
    console.log(`  passRate: ${(passed / groupResults.length * 100).toFixed(0)}%`);
    console.log(`  medianDurationMs: ${median(durations)}`);
    console.log(`  medianTokens: ${median(totals)}`);
    console.log(`  medianUncachedTokens: ${median(uncached)}`);
  }
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
    CLASP_BENCHMARK_WORKSPACE: workspace
  };
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
    : path.join(workspace, "codex-run.jsonl");

  if (options.harness === "codex" && (await fileExists(agentLogFile))) {
    return readCodexUsage(agentLogFile);
  }

  return null;
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
