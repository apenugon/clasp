#!/usr/bin/env node

import { cp, mkdir, readdir, readFile, writeFile } from "node:fs/promises";
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

  await prepareWorkspace(task, workspace);

  console.log(`Prepared ${task.id}`);
  console.log(`Workspace: ${workspace}`);
  console.log(`Prompt: ${path.join(task.dir, task.prompt)}`);
}

async function verifyCommand(taskId, args) {
  const task = await loadTask(taskId);
  const options = parseOptions(args);
  const workspace = resolveWorkspace(task.id, options.workspace);

  const startedAt = new Date();
  const verification = await runProcess(task.verify, workspace);
  const finishedAt = new Date();
  const result = buildResult(task, options, startedAt, finishedAt, verification);
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

  await prepareWorkspace(task, workspace);

  if (!options.agentCommand) {
    throw new Error("run requires --agent-command");
  }

  const promptPath = path.join(task.dir, task.prompt);
  const startedAt = new Date();
  await runShellCommand(options.agentCommand, workspace, {
    ...process.env,
    WEFT_BENCHMARK_TASK_ID: task.id,
    WEFT_BENCHMARK_PROMPT_FILE: promptPath,
    WEFT_BENCHMARK_WORKSPACE: workspace
  });
  const verification = await runProcess(task.verify, workspace);
  const finishedAt = new Date();
  const result = buildResult(task, options, startedAt, finishedAt, verification);
  const resultPath = await writeResult(result);

  console.log(`Completed run for ${task.id}`);
  console.log(`Result: ${resultPath}`);

  if (verification.exitCode !== 0) {
    process.exitCode = verification.exitCode;
  }
}

async function prepareWorkspace(task, workspace) {
  await mkdir(path.dirname(workspace), { recursive: true });
  await cp(path.join(task.dir, task.repo), workspace, {
    recursive: true,
    force: true
  });

  for (const command of task.prepare) {
    const result = await runProcess(command, workspace);
    if (result.exitCode !== 0) {
      throw new Error(`prepare command failed: ${command.join(" ")}`);
    }
  }
}

function buildResult(task, options, startedAt, finishedAt, verification) {
  const prompt = parseNumber(options.promptTokens);
  const completion = parseNumber(options.completionTokens);
  const retry = parseNumber(options.retryTokens);
  const debug = parseNumber(options.debugTokens);

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
    tokenUsage: {
      prompt,
      completion,
      retry,
      debug,
      total: prompt + completion + retry + debug
    },
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

async function runProcess(command, cwd) {
  return new Promise((resolve, reject) => {
    const child = spawn(command[0], command.slice(1), {
      cwd,
      stdio: "inherit",
      env: process.env
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
}

await main();

