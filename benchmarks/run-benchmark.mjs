#!/usr/bin/env node

import { cp, mkdir, mkdtemp, readdir, readFile, rm, stat, writeFile } from "node:fs/promises";
import { readdirSync } from "node:fs";
import { createHash } from "node:crypto";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { spawn } from "node:child_process";
import { pathToFileURL } from "node:url";

const benchmarkRoot = path.resolve("benchmarks");
const tasksRoot = path.join(benchmarkRoot, "tasks");
const resultsRoot = path.join(benchmarkRoot, "results");
const benchmarkModes = new Set(["raw-repo", "file-hinted", "oracle"]);
const taskSetAliases = {
  app: [
    "clasp-lead-priority",
    "ts-lead-priority",
    "clasp-lead-rejection",
    "ts-lead-rejection",
    "clasp-lead-segment",
    "ts-lead-segment",
    "clasp-external-adaptation",
    "ts-external-adaptation",
    "clasp-legal-assistant-appbench"
  ],
  "control-plane": [
    "clasp-control-plane",
    "ts-control-plane"
  ],
  "lead-priority": [
    "clasp-lead-priority",
    "ts-lead-priority"
  ],
  "lead-rejection": [
    "clasp-lead-rejection",
    "ts-lead-rejection"
  ],
  "lead-segment": [
    "clasp-lead-segment",
    "ts-lead-segment"
  ],
  "lead-persistence": [
    "ts-lead-persistence"
  ],
  correctness: [
    "clasp-workflow-correctness",
    "ts-lead-persistence"
  ],
  "external-adaptation": [
    "clasp-external-adaptation",
    "ts-external-adaptation"
  ],
  "foreign-interop": [
    "clasp-npm-interop",
    "ts-npm-interop",
    "clasp-python-interop",
    "ts-python-interop",
    "clasp-rust-interop",
    "ts-rust-interop"
  ],
  "mixed-stack-semantic-layer": [
    "clasp-npm-interop",
    "ts-npm-interop",
    "clasp-python-interop",
    "ts-python-interop",
    "clasp-rust-interop",
    "ts-rust-interop",
    "clasp-interop-boundary",
    "ts-interop-boundary"
  ],
  "interop-boundary": [
    "clasp-interop-boundary",
    "ts-interop-boundary"
  ],
  "secret-handling": [
    "clasp-secret-handling",
    "ts-secret-handling"
  ],
  "authorization-data-access": [
    "clasp-authorization-data-access",
    "ts-authorization-data-access"
  ],
  "agent-planning": [
    "clasp-authorization-data-access",
    "ts-authorization-data-access",
    "clasp-lead-segment",
    "clasp-control-plane",
    "ts-control-plane",
    "clasp-durable-workflow",
    "clasp-compiler-maintenance"
  ],
  "audit-log": [
    "clasp-audit-log",
    "ts-audit-log"
  ],
  "npm-interop": [
    "clasp-npm-interop",
    "ts-npm-interop"
  ],
  "python-interop": [
    "clasp-python-interop",
    "ts-python-interop"
  ],
  "rust-interop": [
    "clasp-rust-interop",
    "ts-rust-interop"
  ],
  "compiler-maintenance": [
    "clasp-compiler-maintenance"
  ],
  "syntax-form": [
    "clasp-syntax-compact",
    "clasp-syntax-verbose"
  ]
};
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
    comparisonLabel: "npm-interop-comparison",
    leftTaskId: "clasp-npm-interop",
    rightTaskId: "ts-npm-interop",
    leftLabel: "clasp",
    rightLabel: "ts"
  },
  {
    comparisonLabel: "python-interop-comparison",
    leftTaskId: "clasp-python-interop",
    rightTaskId: "ts-python-interop",
    leftLabel: "clasp",
    rightLabel: "ts"
  },
  {
    comparisonLabel: "rust-interop-comparison",
    leftTaskId: "clasp-rust-interop",
    rightTaskId: "ts-rust-interop",
    leftLabel: "clasp",
    rightLabel: "ts"
  },
  {
    comparisonLabel: "interop-boundary-comparison",
    leftTaskId: "clasp-interop-boundary",
    rightTaskId: "ts-interop-boundary",
    leftLabel: "clasp",
    rightLabel: "ts"
  },
  {
    comparisonLabel: "secret-handling-comparison",
    leftTaskId: "clasp-secret-handling",
    rightTaskId: "ts-secret-handling",
    leftLabel: "clasp",
    rightLabel: "ts"
  },
  {
    comparisonLabel: "authorization-data-access-comparison",
    leftTaskId: "clasp-authorization-data-access",
    rightTaskId: "ts-authorization-data-access",
    leftLabel: "clasp",
    rightLabel: "ts"
  },
  {
    comparisonLabel: "audit-log-comparison",
    leftTaskId: "clasp-audit-log",
    rightTaskId: "ts-audit-log",
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
    },
    {
      leftTaskId: "clasp-external-adaptation",
      rightTaskId: "ts-external-adaptation"
    }
  ],
  checkpointTaskIds: [
    "clasp-legal-assistant-appbench"
  ],
  leftLabel: "clasp",
  rightLabel: "ts"
};
const mixedStackSemanticLayerBenchmark = {
  comparisonLabel: "mixed-stack-semantic-layer-comparison",
  taskPairs: [
    {
      leftTaskId: "clasp-npm-interop",
      rightTaskId: "ts-npm-interop"
    },
    {
      leftTaskId: "clasp-python-interop",
      rightTaskId: "ts-python-interop"
    },
    {
      leftTaskId: "clasp-rust-interop",
      rightTaskId: "ts-rust-interop"
    },
    {
      leftTaskId: "clasp-interop-boundary",
      rightTaskId: "ts-interop-boundary"
    }
  ],
  leftLabel: "clasp",
  rightLabel: "ts"
};
const airPlanningWorkflowComparison = {
  comparisonLabel: "air-planning-comparison",
  baselineWorkflowAssistance: "raw-text",
  candidateWorkflowAssistance: "compiler-owned-air",
  baselineLabel: "rawText",
  candidateLabel: "compilerOwnedAir"
};
const agentPlanningBenchmark = {
  comparisonLabel: "agent-planning-scorecard",
  slices: [
    {
      sliceLabel: "obligation-discharge-guidance",
      type: "task-family",
      comparisonLabel: "authorization-data-access-comparison",
      leftTaskId: "clasp-authorization-data-access",
      rightTaskId: "ts-authorization-data-access",
      leftLabel: "clasp",
      rightLabel: "ts"
    },
    {
      sliceLabel: "semantic-memory-freshness",
      type: "workflow-assistance",
      taskId: "clasp-lead-segment",
      sourceComparison: airPlanningWorkflowComparison.comparisonLabel
    },
    {
      sliceLabel: "parallel-agent-lease-coordination",
      type: "task-family",
      comparisonLabel: "control-plane-comparison",
      leftTaskId: "clasp-control-plane",
      rightTaskId: "ts-control-plane",
      leftLabel: "clasp",
      rightLabel: "ts"
    },
    {
      sliceLabel: "transactional-edit-rollback",
      type: "task-summary",
      taskId: "clasp-durable-workflow"
    },
    {
      sliceLabel: "cheapest-valid-path-planning",
      type: "task-summary",
      taskId: "clasp-compiler-maintenance"
    }
  ]
};
const cachingAndTrustBenchmark = {
  comparisonLabel: "caching-and-trust-scorecard",
  slices: [
    {
      sliceLabel: "semantic-proof-or-result-cache-reuse",
      type: "task-family",
      comparisonLabel: "authorization-data-access-comparison",
      leftTaskId: "clasp-authorization-data-access",
      rightTaskId: "ts-authorization-data-access",
      leftLabel: "clasp",
      rightLabel: "ts",
      includeCacheMetrics: true
    },
    {
      sliceLabel: "world-snapshot-fidelity",
      type: "task-family",
      comparisonLabel: "external-adaptation-comparison",
      leftTaskId: "clasp-external-adaptation",
      rightTaskId: "ts-external-adaptation",
      leftLabel: "clasp",
      rightLabel: "ts"
    },
    {
      sliceLabel: "interference-analysis-quality",
      type: "task-family",
      comparisonLabel: "control-plane-comparison",
      leftTaskId: "clasp-control-plane",
      rightTaskId: "ts-control-plane",
      leftLabel: "clasp",
      rightLabel: "ts"
    },
    {
      sliceLabel: "trusted-computing-base-reporting-clarity",
      type: "task-family",
      comparisonLabel: "interop-boundary-comparison",
      leftTaskId: "clasp-interop-boundary",
      rightTaskId: "ts-interop-boundary",
      leftLabel: "clasp",
      rightLabel: "ts"
    }
  ]
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
    case "freeze":
      await freezeCommand(maybeTaskId, rest);
      break;
    case "verify":
      await verifyCommand(maybeTaskId, rest);
      break;
    case "run":
      await runCommand(maybeTaskId, rest);
      break;
    case "package":
      await packageCommand(
        [maybeTaskId, ...rest].filter((value) => value !== undefined)
      );
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
  assertDefaultBenchmarkPathSupported(task, options);
  const workspace = resolveWorkspace(task.id, options.workspace);
  const promptPath = await resolvePromptPath(task, options.mode);

  await prepareWorkspace(task, workspace, benchmarkEnv(task, workspace));

  console.log(`Prepared ${task.id}`);
  console.log(`Workspace: ${workspace}`);
  console.log(`Prompt: ${promptPath}`);
  console.log(`Mode: ${normalizeBenchmarkMode(options.mode)}`);
}

async function freezeCommand(taskSelection, args) {
  const options = parseOptions(args);
  if (!options.output) {
    throw new Error("freeze requires --output");
  }

  const taskIds = resolveTaskSelection(taskSelection);
  const tasks = [];
  for (const taskId of taskIds) {
    const task = await loadTask(taskId);
    assertDefaultBenchmarkPathSupported(task, options);
    tasks.push(task);
  }

  const sampleCount = parsePositiveNumber(options.count ?? options.sampleCount ?? "1", "sample count");
  const mode = normalizeBenchmarkMode(options.mode);
  const harness = options.harness ?? "unspecified";
  const model = options.model ?? "unspecified";
  const workflowAssistance = normalizeWorkflowAssistance(
    options.workflowAssistance ?? process.env.CLASP_BENCHMARK_WORKFLOW_ASSISTANCE
  );
  const seriesLabel = options.notes ?? options.notePrefix ?? taskSelection ?? taskIds.join("-");
  const seed = options.seed ?? `${seriesLabel}:${harness}:${model}:${mode}:${taskIds.join(",")}`;
  const samples = taskIds.length === 0
    ? []
    : Array.from({ length: sampleCount }, (_, index) => buildFrozenSample(taskIds, index + 1, seed));
  const files = await collectFrozenBundleFiles(tasks, mode);
  const manifest = {
    schemaVersion: 1,
    bundleType: "clasp-benchmark-fairness-bundle",
    bundleId: createStableId(`${seriesLabel}:${harness}:${model}:${mode}`),
    taskSelection: taskSelection ?? taskIds[0] ?? "",
    taskIds,
    harness,
    model,
    mode,
    workflowAssistance,
    sampleCount,
    seriesLabel,
    seed,
    samples,
    files
  };
  const outputPath = path.resolve(options.output);

  await mkdir(path.dirname(outputPath), { recursive: true });
  await writeFile(outputPath, JSON.stringify(manifest, null, 2) + "\n", "utf8");

  console.log(`Frozen ${taskIds.length} tasks`);
  console.log(`Samples: ${sampleCount}`);
  console.log(`Bundle: ${outputPath}`);
}

async function verifyCommand(taskId, args) {
  const task = await loadTask(taskId);
  const options = parseOptions(args);
  assertDefaultBenchmarkPathSupported(task, options);
  const workspace = resolveWorkspace(task.id, options.workspace);
  const env = benchmarkEnv(task, workspace);

  const startedAt = new Date();
  const verification = await runProcess(task.verify, workspace, env);
  const finishedAt = new Date();
  const usage = await resolveTokenUsage(options, workspace);
  const phases = await resolvePhaseSummary(options, workspace, startedAt, finishedAt, verification);
  const result = await buildResult(task, options, startedAt, finishedAt, verification, usage, phases);
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
  assertDefaultBenchmarkPathSupported(task, options);
  const workspace = resolveWorkspace(task.id, options.workspace);
  const env = benchmarkEnv(task, workspace);

  await prepareWorkspace(task, workspace, env);

  if (!options.agentCommand) {
    throw new Error("run requires --agent-command");
  }

  const promptPath = await resolvePromptPath(task, options.mode);
  const startedAt = new Date();
  await runShellCommand(options.agentCommand, workspace, {
    ...env,
    CLASP_BENCHMARK_PROMPT_FILE: promptPath
  });
  const verification = await runProcess(task.verify, workspace, env);
  const finishedAt = new Date();
  const usage = await resolveTokenUsage(options, workspace);
  const phases = await resolvePhaseSummary(options, workspace, startedAt, finishedAt, verification);
  const result = await buildResult(task, options, startedAt, finishedAt, verification, usage, phases);
  const resultPath = await writeResult(result);

  console.log(`Completed run for ${task.id}`);
  console.log(`Result: ${resultPath}`);

  if (verification.exitCode !== 0) {
    process.exitCode = verification.exitCode;
  }
}

async function prepareWorkspace(task, workspace, env) {
  await mkdir(path.dirname(workspace), { recursive: true });
  await rm(workspace, { recursive: true, force: true });
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
  const surfacesPath = path.join(prepRoot, `${moduleName}.surfaces.json`);
  const agentPackPath = path.join(prepRoot, `${moduleName}.agent-pack.json`);
  const explainPath = task.surfaceForm === "verbose"
    ? path.join(prepRoot, `${moduleName}.explain.txt`)
    : null;

  await mkdir(prepRoot, { recursive: true });
  const context = await renderClaspJsonArtifact("context", entryPath, contextPath, env);
  const air = await renderClaspJsonArtifact("air", entryPath, airPath, env);
  const nativeImage = await renderClaspNativeImage(entryPath, prepRoot, env);

  const uiGraph = await renderClaspUiGraph(entryPath, prepRoot, env);
  await writeFile(uiPath, JSON.stringify(uiGraph, null, 2) + "\n", "utf8");

  if (explainPath) {
    const explanation = await renderClaspExplain(entryPath, env);
    await writeFile(explainPath, explanation, "utf8");
  }

  const hostBindingManifestPath = await copyClaspHostBindingManifest(task, prepRoot);
  const hostBindingManifest = hostBindingManifestPath
    ? JSON.parse(await readFile(hostBindingManifestPath, "utf8"))
    : null;
  const surfaces = synthesizeClaspBenchmarkSurfaces({
    task,
    workspace,
    entryPath,
    prepRoot,
    moduleName,
    nativeImage,
    uiGraph,
    hostBindingManifestPath,
    hostBindingManifest
  });
  surfaces.artifacts.agentPack = path.relative(workspace, agentPackPath);
  await writeFile(surfacesPath, JSON.stringify(surfaces, null, 2) + "\n", "utf8");
  const agentPack = synthesizeClaspAgentActionPack({
    task,
    workspace,
    entryPath,
    moduleName,
    context,
    air,
    surfaces,
    hostBindingManifestPath,
    hostBindingManifest
  });
  await writeFile(agentPackPath, JSON.stringify(agentPack, null, 2) + "\n", "utf8");

  const guidePath = path.join(workspace, "LANGUAGE_GUIDE.md");
  const guide = renderClaspLanguageGuide({
    workspace,
    entryPath,
    prepRoot,
    moduleName,
    surfacesPath,
    agentPackPath,
    explainPath,
    hostBindingManifestPath,
    hostBindingManifest,
    appOwnedEditSurface: surfaces.appOwnedEditSurface,
    context,
    air,
    uiGraph
  });

  await writeFile(guidePath, guide, "utf8");
}

async function copyClaspHostBindingManifest(task, prepRoot) {
  if (typeof task.hostBindingManifest !== "string" || task.hostBindingManifest.length === 0) {
    return null;
  }

  const sourcePath = path.join(task.dir, task.hostBindingManifest);
  const targetPath = path.join(prepRoot, "host-bindings.manifest.json");

  await cp(sourcePath, targetPath, { force: true });
  return targetPath;
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
  const result = await runClaspCompilerCommandCapture(command, inputPath, outputPath, env);

  if (result.exitCode !== 0) {
    throw new Error(`failed to generate Clasp ${command} artifact for ${inputPath}`);
  }
}

async function renderClaspJsonArtifact(command, inputPath, outputPath, env) {
  await runClaspCompilerCommand(command, inputPath, outputPath, env);
  return JSON.parse(await readFile(outputPath, "utf8"));
}

async function runClaspCompilerCommandCapture(command, inputPath, outputPath, env) {
  const script = [
    "set -euo pipefail",
    `cd ${shellQuote(env.CLASP_PROJECT_ROOT)}`,
    "unset CLASP_CLASPC CLASPC_BIN",
    `claspc_bin="$(${shellQuote(path.join(env.CLASP_PROJECT_ROOT, "scripts", "resolve-claspc.sh"))})"`,
    `"${"$"}claspc_bin" --json ${command} ${shellQuote(inputPath)} -o ${shellQuote(outputPath)} >/dev/null`
  ].join(" && ");
  return runProcessCapture(
    ["bash", "-lc", script],
    env.CLASP_PROJECT_ROOT,
    env
  );
}

async function renderClaspUiGraph(entryPath, prepRoot, env) {
  const tempModulePath = path.join(prepRoot, ".benchmark-prep-ui.mjs");

  try {
    const compileResult = await runClaspCompilerCommandCapture("compile", entryPath, tempModulePath, env);

    if (compileResult.exitCode !== 0) {
      if (compileResult.stderr.includes("E_BACKEND_TARGET_REQUIRES_NATIVE")) {
        return [];
      }

      throw new Error(`failed to generate Clasp compile artifact for ${entryPath}`);
    }

    const compiledBytes = await readFile(tempModulePath);
    if (looksLikeNativeBinary(compiledBytes)) {
      return [];
    }

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
    "unset CLASP_CLASPC CLASPC_BIN",
    `claspc_bin="$(${shellQuote(path.join(env.CLASP_PROJECT_ROOT, "scripts", "resolve-claspc.sh"))})"`,
    `"${"$"}claspc_bin" ${command} ${shellQuote(inputPath)}`
  ].join(" && ");
  return runProcessCapture(
    ["bash", "-lc", script],
    env.CLASP_PROJECT_ROOT,
    env
  );
}

async function renderClaspNativeImage(entryPath, prepRoot, env) {
  const imagePath = path.join(prepRoot, ".benchmark-prep.native.image.json");
  const result = await runClaspCompilerCommandCapture("native-image", entryPath, imagePath, env);

  if (result.exitCode !== 0) {
    throw new Error(`failed to generate Clasp native-image artifact for ${entryPath}`);
  }

  return JSON.parse(await readFile(imagePath, "utf8"));
}

function synthesizeClaspBenchmarkSurfaces({
  task,
  workspace,
  entryPath,
  prepRoot,
  moduleName,
  nativeImage,
  uiGraph,
  hostBindingManifestPath,
  hostBindingManifest
}) {
  const appOwnedEditSurface = normalizeTaskStringList(
    task.appOwnedEditSurface ?? task.appOwnedEditSurfaces
  );
  const entry = path.relative(workspace, entryPath);
  const sourceFiles = collectWorkspaceClaspSourceFiles(workspace);
  const surfaceTypeNames = collectSurfaceTypeNames(nativeImage, hostBindingManifest);
  const records = collectBenchmarkRecords(nativeImage, surfaceTypeNames);
  const enums = collectBenchmarkEnums(nativeImage, surfaceTypeNames);
  const routes = collectBenchmarkRoutes(nativeImage, hostBindingManifest);
  const forms = collectBenchmarkForms(nativeImage, hostBindingManifest);
  const pages = collectBenchmarkPages(routes, uiGraph);
  const hostBindings = collectBenchmarkHostBindings(nativeImage, hostBindingManifest);
  const expectedJsonShapes = hostBindingManifest?.expectedJsonShapes ?? {};

  return {
    format: "clasp-benchmark-surfaces-v1",
    taskId: task.id,
    entry,
    appOwnedEditSurface,
    artifacts: {
      context: path.join("benchmark-prep", `${moduleName}.context.json`),
      air: path.join("benchmark-prep", `${moduleName}.air.json`),
      ui: path.join("benchmark-prep", `${moduleName}.ui.json`),
      surfaces: path.join("benchmark-prep", `${moduleName}.surfaces.json`),
      hostBindingManifest: hostBindingManifestPath
        ? path.relative(workspace, hostBindingManifestPath)
        : null
    },
    sourceModules: sourceFiles.map((sourceFile) => ({
      path: sourceFile,
      role: sourceModuleRole(sourceFile, entry, appOwnedEditSurface)
    })),
    records,
    enums,
    routes,
    pages,
    forms,
    decodeBoundaries: collectBenchmarkDecodeBoundaries(nativeImage),
    hostBindings,
    expectedJsonShapes,
    contractGaps: collectHostContractGaps(records, enums, expectedJsonShapes, appOwnedEditSurface)
  };
}

function synthesizeClaspAgentActionPack({
  task,
  workspace,
  entryPath,
  moduleName,
  context,
  air,
  surfaces,
  hostBindingManifestPath,
  hostBindingManifest
}) {
  const entry = path.relative(workspace, entryPath);
  const artifacts = {
    context: path.join("benchmark-prep", `${moduleName}.context.json`),
    air: path.join("benchmark-prep", `${moduleName}.air.json`),
    ui: path.join("benchmark-prep", `${moduleName}.ui.json`),
    surfaces: path.join("benchmark-prep", `${moduleName}.surfaces.json`),
    agentPack: path.join("benchmark-prep", `${moduleName}.agent-pack.json`),
    hostBindingManifest: hostBindingManifestPath
      ? path.relative(workspace, hostBindingManifestPath)
      : null
  };
  const packRoutes = collectAgentPackRoutes(surfaces, context);
  const packSchemas = collectAgentPackSchemas(surfaces, context);
  const packTypes = collectAgentPackTypes(surfaces, context);
  const packBoundaries = collectAgentPackBoundaries(surfaces, context, hostBindingManifest);
  const referencedSurfaceIds = collectAgentPackSurfaceIds(packRoutes, packSchemas, packTypes, packBoundaries);

  return {
    format: "clasp-benchmark-agent-pack-v1",
    task: {
      id: task.id,
      title: task.title ?? "",
      suite: task.suite ?? "",
      language: task.language ?? "",
      entry,
      prompt: task.prompt ?? null,
      verifierCommand: normalizeTaskCommand(task.verify)
    },
    artifacts,
    editTargets: {
      primary: surfaces.appOwnedEditSurface ?? [],
      sourceModules: collectAgentPackSourceModules(surfaces, context, entry)
    },
    compilerContext: {
      contextFormat: context.format ?? null,
      airFormat: air.format ?? null,
      surfaceIndex: summarizeAgentPackSurfaceIndex(context),
      airNodes: collectAgentPackAirNodes(air, referencedSurfaceIds)
    },
    surfaces: {
      routes: packRoutes,
      schemas: packSchemas,
      types: packTypes,
      forms: surfaces.forms ?? [],
      pages: surfaces.pages ?? [],
      boundaries: packBoundaries,
      decodeBoundaries: surfaces.decodeBoundaries ?? []
    },
    contractGaps: surfaces.contractGaps ?? [],
    actionItems: collectAgentPackActionItems(surfaces, context, task),
    verifier: {
      command: normalizeTaskCommand(task.verify),
      scenarioSignals: hostBindingManifest?.acceptanceSignals ?? []
    }
  };
}

function normalizeTaskStringList(value) {
  if (Array.isArray(value)) {
    return value.filter((item) => typeof item === "string" && item.length > 0);
  }

  if (typeof value === "string" && value.length > 0) {
    return [value];
  }

  return [];
}

function sourceModuleRole(sourceFile, entry, appOwnedEditSurface) {
  if (appOwnedEditSurface.includes(sourceFile)) {
    return "app-owned-edit-surface";
  }

  if (sourceFile === entry) {
    return "entry";
  }

  return "support";
}

function collectSurfaceTypeNames(nativeImage, hostBindingManifest) {
  const typeNames = new Set();

  for (const codec of nativeImage.runtime?.jsonCodecs ?? []) {
    addSurfaceTypeName(typeNames, codec.type);
  }

  for (const boundary of nativeImage.runtime?.boundaries ?? []) {
    if (boundary.kind === "route") {
      addSurfaceTypeName(typeNames, boundary.request);
      addSurfaceTypeName(typeNames, boundary.response);
    }
  }

  for (const route of hostBindingManifest?.routeHostInputs ?? []) {
    addSurfaceTypeName(typeNames, route.requestType);
    addSurfaceTypeName(typeNames, route.responseType);
    for (const field of route.hostInput?.fields ?? []) {
      addSurfaceTypeName(typeNames, field.type);
    }
  }

  for (const binding of hostBindingManifest?.mockModelCalls ?? []) {
    addSurfaceTypeName(typeNames, binding.inputType);
    addSurfaceTypeName(typeNames, binding.decodedAs);
    addSurfaceTypeName(typeNames, binding.expectedInputShape);
    addSurfaceTypeName(typeNames, binding.expectedJsonShape);
    addFunctionTypeNames(typeNames, binding.signature);
  }

  for (const binding of hostBindingManifest?.hostBindings ?? []) {
    addSurfaceTypeName(typeNames, binding.decodedAs);
    addFunctionTypeNames(typeNames, binding.signature);
  }

  for (const [shapeName, shape] of Object.entries(hostBindingManifest?.expectedJsonShapes ?? {})) {
    addSurfaceTypeName(typeNames, shapeName);
    for (const field of shape.fields ?? []) {
      addSurfaceTypeName(typeNames, field.type);
    }
  }

  return typeNames;
}

function addFunctionTypeNames(typeNames, signature) {
  if (typeof signature !== "string") {
    return;
  }

  for (const candidate of signature.match(/[A-Z][A-Za-z0-9_]*/g) ?? []) {
    addSurfaceTypeName(typeNames, candidate);
  }
}

function addSurfaceTypeName(typeNames, typeName) {
  if (typeof typeName !== "string" || typeName.length === 0) {
    return;
  }

  const normalized = typeName.replace(/^\[/, "").replace(/\]$/, "");
  if (isPrimitiveSurfaceType(normalized)) {
    return;
  }

  typeNames.add(normalized);
}

function isPrimitiveSurfaceType(typeName) {
  return ["Str", "Int", "Bool", "Page", "View", "Prompt", "Redirect", "Result"].includes(typeName);
}

function collectBenchmarkRecords(nativeImage, surfaceTypeNames) {
  return (nativeImage.abi?.recordLayouts ?? [])
    .filter((layout) => surfaceTypeNames.size === 0 || surfaceTypeNames.has(layout.name))
    .map((layout) => ({
      name: layout.name,
      fields: (layout.fields ?? []).map((field) => ({
        name: field.name,
        type: field.type,
        storage: field.storage
      }))
    }))
    .sort(compareByName);
}

function collectBenchmarkEnums(nativeImage, surfaceTypeNames) {
  return (nativeImage.abi?.variantLayouts ?? [])
    .filter((layout) => surfaceTypeNames.size === 0 || surfaceTypeNames.has(layout.name))
    .map((layout) => ({
      name: layout.name,
      constructors: (layout.constructors ?? []).map((constructor) => constructor.name),
      wireValues: (layout.constructors ?? []).map((constructor) => constructorWireValue(constructor.name))
    }))
    .sort(compareByName);
}

function constructorWireValue(name) {
  if (typeof name !== "string" || name.length === 0) {
    return "";
  }

  return `${name.slice(0, 1).toLowerCase()}${name.slice(1)}`;
}

function collectBenchmarkRoutes(nativeImage, hostBindingManifest) {
  const manifestRoutes = hostBindingManifest?.routeHostInputs ?? [];

  return (nativeImage.runtime?.boundaries ?? [])
    .filter((boundary) => boundary.kind === "route")
    .map((boundary) => {
      const manifestRoute = findManifestRoute(manifestRoutes, boundary.method, boundary.path, boundary.name);

      return {
        name: boundary.name,
        method: boundary.method,
        path: boundary.path,
        requestType: boundary.request,
        responseType: boundary.response,
        responseKind: boundary.responseKind ?? routeResponseKind(boundary.response),
        handler: boundary.handler,
        requestDecoder: boundary.decode,
        responseEncoder: boundary.encode,
        hostInput: manifestRoute?.hostInput ?? null,
        runtimeOwnedFailures: manifestRoute?.runtimeOwnedFailures ?? []
      };
    })
    .sort((left, right) => `${left.method} ${left.path}`.localeCompare(`${right.method} ${right.path}`));
}

function findManifestRoute(manifestRoutes, method, routePath, name) {
  return manifestRoutes.find((route) => route.name === name) ??
    manifestRoutes.find((route) => route.method === method && route.path === routePath) ??
    null;
}

function routeResponseKind(responseType) {
  if (responseType === "Page") {
    return "page";
  }

  if (responseType === "Redirect") {
    return "redirect";
  }

  return "json";
}

function collectBenchmarkPages(routes, uiGraph) {
  const uiByRoute = new Map((uiGraph ?? []).map((page) => [page.routeName, page]));

  return routes
    .filter((route) => route.responseKind === "page" || route.responseType === "Page")
    .map((route) => {
      const uiPage = uiByRoute.get(route.name);
      return {
        routeName: route.name,
        method: route.method,
        path: route.path,
        handler: route.handler,
        title: uiPage?.title ?? null
      };
    });
}

function collectBenchmarkForms(nativeImage, hostBindingManifest) {
  const manifestRoutes = hostBindingManifest?.routeHostInputs ?? [];
  const forms = [];

  for (const decl of nativeImage.decls ?? []) {
    const body = decl.body;
    walkBenchmarkExpr(body, (expr) => {
      if (!isLocalCall(expr, "form")) {
        return;
      }

      const method = stringLiteralValue(expr.args?.[0]);
      const action = stringLiteralValue(expr.args?.[1]);
      const manifestRoute = findManifestRoute(manifestRoutes, method, action, null);
      forms.push({
        decl: decl.name,
        method,
        action,
        fields: collectInputFields(expr),
        expectedHostFields: manifestRoute?.hostInput?.fields ?? []
      });
    });
  }

  return forms.sort((left, right) => `${left.method} ${left.action}`.localeCompare(`${right.method} ${right.action}`));
}

function collectInputFields(expr) {
  const fields = [];

  walkBenchmarkExpr(expr, (candidate) => {
    if (!isLocalCall(candidate, "input")) {
      return;
    }

    fields.push({
      name: stringLiteralValue(candidate.args?.[0]),
      inputType: stringLiteralValue(candidate.args?.[1]),
      defaultValue: stringLiteralValue(candidate.args?.[2])
    });
  });

  return fields;
}

function collectBenchmarkDecodeBoundaries(nativeImage) {
  const boundaries = [];

  for (const decl of nativeImage.decls ?? []) {
    walkBenchmarkExpr(decl.body, (expr) => {
      if (expr.kind !== "intrinsic" || expr.name !== "decode") {
        return;
      }

      boundaries.push({
        decl: decl.name,
        targetType: expr.type,
        source: summarizeBenchmarkExpr(expr.value),
        sourceCallee: localCallName(expr.value)
      });
    });
  }

  return boundaries.sort((left, right) => left.decl.localeCompare(right.decl));
}

function collectBenchmarkHostBindings(nativeImage, hostBindingManifest) {
  const runtimeBindings = new Map(
    (nativeImage.runtime?.bindings ?? []).map((binding) => [binding.name, binding])
  );
  const bindings = [];

  for (const binding of hostBindingManifest?.mockModelCalls ?? []) {
    const runtimeBinding = runtimeBindings.get(binding.name);
    bindings.push({
      name: binding.name,
      role: "mock-model",
      type: runtimeBinding?.type ?? binding.signature ?? "",
      runtimeName: binding.runtimeName ?? runtimeBinding?.runtime ?? binding.name,
      inputType: binding.inputType ?? null,
      decodedAs: binding.decodedAs ?? null,
      expectedJsonShape: binding.expectedJsonShape ?? null,
      runtimeOwnedFailures: binding.runtimeOwnedFailures ?? []
    });
  }

  for (const binding of hostBindingManifest?.hostBindings ?? []) {
    const runtimeBinding = runtimeBindings.get(binding.name);
    bindings.push({
      name: binding.name,
      role: "host-binding",
      type: runtimeBinding?.type ?? binding.signature ?? "",
      runtimeName: binding.runtimeName ?? runtimeBinding?.runtime ?? binding.name,
      decodedAs: binding.decodedAs ?? null,
      runtimeOwnedFailures: binding.runtimeOwnedFailures ?? []
    });
  }

  if (bindings.length > 0) {
    return bindings.sort(compareByName);
  }

  return (nativeImage.runtime?.bindings ?? [])
    .filter((binding) => isHostBindingName(binding.name))
    .map((binding) => ({
      name: binding.name,
      role: "foreign",
      type: binding.type,
      runtimeName: binding.runtime ?? binding.name,
      decodedAs: null,
      runtimeOwnedFailures: []
    }))
    .sort(compareByName);
}

function collectHostContractGaps(records, enums, expectedJsonShapes, appOwnedEditSurface) {
  const gaps = [];
  const recordsByName = new Map(records.map((record) => [record.name, record]));
  const enumsByName = new Map(enums.map((enumShape) => [enumShape.name, enumShape]));

  for (const [shapeName, shape] of Object.entries(expectedJsonShapes ?? {})) {
    if (shape.kind === "record") {
      const record = recordsByName.get(shapeName);
      if (!record) {
        gaps.push(hostContractGap("missing-schema", shapeName, null, shape.kind, appOwnedEditSurface));
        continue;
      }

      const fieldsByName = new Map(record.fields.map((field) => [field.name, field]));
      for (const expectedField of shape.fields ?? []) {
        const field = fieldsByName.get(expectedField.name);
        if (!field) {
          gaps.push(hostContractGap("missing-field", shapeName, expectedField.name, expectedField.type, appOwnedEditSurface));
        } else if (field.type !== expectedField.type) {
          gaps.push(hostContractGap("field-type-mismatch", shapeName, expectedField.name, expectedField.type, appOwnedEditSurface));
        }
      }
    } else if (shape.kind === "enum") {
      const enumShape = enumsByName.get(shapeName);
      if (!enumShape) {
        gaps.push(hostContractGap("missing-schema", shapeName, null, shape.kind, appOwnedEditSurface));
        continue;
      }

      const actualWireValues = new Set(enumShape.wireValues);
      for (const wireValue of shape.wireValues ?? []) {
        if (!actualWireValues.has(wireValue)) {
          gaps.push(hostContractGap("missing-wire-value", shapeName, wireValue, "enum-wire-value", appOwnedEditSurface));
        }
      }
    }
  }

  return gaps;
}

function hostContractGap(kind, schema, field, expected, appOwnedEditSurface) {
  return {
    kind,
    schema,
    field,
    expected,
    appOwnedEditSurface
  };
}

function collectAgentPackRoutes(surfaces, context) {
  const contextRoutesByName = new Map(
    (context.surfaceIndex?.routes ?? []).map((route) => [route.name, route])
  );

  return (surfaces.routes ?? []).map((route) => {
    const contextRoute = contextRoutesByName.get(route.name) ?? null;
    return compactObject({
      id: contextRoute?.id ?? `route:${route.name}`,
      airNodeId: `route:${route.name}`,
      name: route.name,
      method: route.method,
      path: route.path,
      requestType: route.requestType,
      responseType: route.responseType,
      responseKind: route.responseKind,
      handler: route.handler,
      requestSchemaId: contextRoute?.requestSchemaId ?? schemaIdForType(route.requestType),
      responseSchemaId: contextRoute?.responseSchemaId ?? schemaIdForType(route.responseType),
      affectedSurfaces: contextRoute?.affectedSurfaces ?? [],
      affectedRoutes: contextRoute?.affectedRoutes ?? [],
      affectedSchemas: contextRoute?.affectedSchemas ?? [],
      affectedForeignBoundaries: contextRoute?.affectedForeignBoundaries ?? [],
      hostInput: route.hostInput,
      runtimeOwnedFailures: route.runtimeOwnedFailures ?? []
    });
  });
}

function collectAgentPackSchemas(surfaces, context) {
  const contextSchemasByName = new Map(
    (context.surfaceIndex?.schemas ?? []).map((schema) => [schema.name, schema])
  );
  const expectedJsonShapes = surfaces.expectedJsonShapes ?? {};
  const actualRecordsByName = new Map((surfaces.records ?? []).map((record) => [record.name, record]));
  const schemaNames = new Set([
    ...actualRecordsByName.keys(),
    ...Object.entries(expectedJsonShapes)
      .filter(([, shape]) => shape?.kind === "record")
      .map(([name]) => name)
  ]);

  return [...schemaNames].sort((left, right) => left.localeCompare(right)).map((schemaName) => {
    const record = actualRecordsByName.get(schemaName) ?? null;
    const contextSchema = contextSchemasByName.get(schemaName) ?? null;
    const expectedShape = expectedJsonShapes[schemaName] ?? null;
    const gaps = (surfaces.contractGaps ?? []).filter((gap) => gap.schema === schemaName);

    return compactObject({
      id: contextSchema?.id ?? `schema:${schemaName}`,
      airNodeId: record ? `record:${schemaName}` : null,
      name: schemaName,
      kind: expectedShape?.kind ?? contextSchema?.kind ?? "record",
      present: Boolean(record),
      fields: record?.fields ?? [],
      expectedFields: expectedShape?.fields ?? null,
      missingFields: gaps
        .filter((gap) => gap.kind === "missing-field")
        .map((gap) => compactObject({
          name: gap.field,
          expected: gap.expected,
          editFiles: gap.appOwnedEditSurface ?? []
        })),
      affectedRoutes: contextSchema?.affectedRoutes ?? [],
      affectedForeignBoundaries: contextSchema?.affectedForeignBoundaries ?? [],
      affectedSurfaces: contextSchema?.affectedSurfaces ?? []
    });
  });
}

function collectAgentPackTypes(surfaces, context) {
  const contextTypesByName = new Map(
    (context.surfaceIndex?.types ?? []).map((typeSurface) => [typeSurface.name, typeSurface])
  );
  const expectedJsonShapes = surfaces.expectedJsonShapes ?? {};
  const actualEnumsByName = new Map((surfaces.enums ?? []).map((enumShape) => [enumShape.name, enumShape]));
  const typeNames = new Set([
    ...actualEnumsByName.keys(),
    ...Object.entries(expectedJsonShapes)
      .filter(([, shape]) => shape?.kind === "enum")
      .map(([name]) => name)
  ]);

  return [...typeNames].sort((left, right) => left.localeCompare(right)).map((typeName) => {
    const enumShape = actualEnumsByName.get(typeName) ?? null;
    const contextType = contextTypesByName.get(typeName) ?? null;
    const expectedShape = expectedJsonShapes[typeName] ?? null;
    const gaps = (surfaces.contractGaps ?? []).filter((gap) => gap.schema === typeName);

    return compactObject({
      id: contextType?.id ?? `type:${typeName}`,
      airNodeId: enumShape ? `type:${typeName}` : null,
      name: typeName,
      kind: "enum",
      present: Boolean(enumShape),
      constructors: enumShape?.constructors ?? [],
      wireValues: enumShape?.wireValues ?? [],
      expectedWireValues: expectedShape?.wireValues ?? null,
      missingWireValues: gaps
        .filter((gap) => gap.kind === "missing-wire-value")
        .map((gap) => gap.field),
      missingSchema: gaps.some((gap) => gap.kind === "missing-schema"),
      affectedSchemas: contextType?.affectedSchemas ?? [],
      affectedRoutes: contextType?.affectedRoutes ?? [],
      affectedForeignBoundaries: contextType?.affectedForeignBoundaries ?? [],
      affectedSurfaces: contextType?.affectedSurfaces ?? []
    });
  });
}

function collectAgentPackBoundaries(surfaces, context, hostBindingManifest) {
  const contextBoundariesByName = new Map(
    (context.surfaceIndex?.foreignBoundaries ?? []).map((boundary) => [boundary.name, boundary])
  );
  const hostBindingsByName = new Map((surfaces.hostBindings ?? []).map((binding) => [binding.name, binding]));
  const names = new Set([
    ...hostBindingsByName.keys(),
    ...contextBoundariesByName.keys(),
    ...((hostBindingManifest?.mockModelCalls ?? []).map((binding) => binding.name)),
    ...((hostBindingManifest?.hostBindings ?? []).map((binding) => binding.name))
  ]);

  return [...names].sort((left, right) => left.localeCompare(right)).map((name) => {
    const hostBinding = hostBindingsByName.get(name) ?? null;
    const contextBoundary = contextBoundariesByName.get(name) ?? null;
    const manifestBinding = findManifestHostBinding(hostBindingManifest, name);

    return compactObject({
      id: contextBoundary?.id ?? `foreign:${name}`,
      airNodeId: `foreign:${name}`,
      name,
      boundaryKind: agentPackBoundaryKind(hostBinding ?? manifestBinding),
      role: hostBinding?.role ?? manifestBinding?.role ?? "foreign",
      type: contextBoundary?.type ?? hostBinding?.type ?? manifestBinding?.signature ?? "",
      runtimeName: contextBoundary?.runtimeName ?? hostBinding?.runtimeName ?? manifestBinding?.runtimeName ?? name,
      inputType: hostBinding?.inputType ?? manifestBinding?.inputType ?? null,
      decodedAs: hostBinding?.decodedAs ?? manifestBinding?.decodedAs ?? null,
      expectedJsonShape: hostBinding?.expectedJsonShape ?? manifestBinding?.expectedJsonShape ?? null,
      runtimeOwnedFailures: hostBinding?.runtimeOwnedFailures ?? manifestBinding?.runtimeOwnedFailures ?? []
    });
  });
}

function collectAgentPackSourceModules(surfaces, context, entry) {
  const contextModulesByPath = new Map(
    (context.sourceModules ?? []).map((sourceModule) => [
      sourceModulePath(sourceModule, entry),
      sourceModule
    ])
  );
  const modulePaths = new Set([
    ...((surfaces.sourceModules ?? []).map((sourceModule) => sourceModule.path)),
    ...contextModulesByPath.keys()
  ]);

  return [...modulePaths].sort((left, right) => left.localeCompare(right)).map((modulePath) => {
    const surfaceModule = (surfaces.sourceModules ?? []).find((sourceModule) => sourceModule.path === modulePath) ?? null;
    const contextModule = contextModulesByPath.get(modulePath) ?? null;

    return compactObject({
      path: modulePath,
      role: surfaceModule?.role ?? contextModule?.role ?? "support",
      sourceId: contextModule?.sourceId ?? null,
      moduleId: contextModule?.moduleId ?? null,
      moduleName: contextModule?.moduleName ?? null,
      schemas: contextModule?.schemas ?? [],
      routes: contextModule?.routes ?? [],
      foreignBoundaries: contextModule?.foreignBoundaries ?? []
    });
  });
}

function collectAgentPackActionItems(surfaces, context, task) {
  const schemasByName = new Map(
    collectAgentPackSchemas(surfaces, context).map((schema) => [schema.name, schema])
  );
  const typesByName = new Map(
    collectAgentPackTypes(surfaces, context).map((typeSurface) => [typeSurface.name, typeSurface])
  );
  const verifierCommand = normalizeTaskCommand(task.verify);

  return (surfaces.contractGaps ?? []).map((gap) => {
    const relatedSurface = schemasByName.get(gap.schema) ?? typesByName.get(gap.schema) ?? null;
    return compactObject({
      kind: "close-contract-gap",
      gapKind: gap.kind,
      schema: gap.schema,
      field: gap.field,
      expected: gap.expected,
      editFiles: gap.appOwnedEditSurface ?? surfaces.appOwnedEditSurface ?? [],
      affectedRoutes: relatedSurface?.affectedRoutes ?? [],
      affectedForeignBoundaries: relatedSurface?.affectedForeignBoundaries ?? [],
      affectedSurfaces: relatedSurface?.affectedSurfaces ?? [],
      verifierCommand
    });
  });
}

function collectAgentPackSurfaceIds(routes, schemas, types, boundaries) {
  const ids = new Set();

  for (const item of [...routes, ...schemas, ...types, ...boundaries]) {
    addString(ids, item.id);
    addString(ids, item.airNodeId);
    for (const surfaceId of item.affectedSurfaces ?? []) {
      addString(ids, surfaceId);
    }
  }

  for (const schema of schemas) {
    addString(ids, schema.id?.replace(/^schema:/, "record:"));
    for (const field of schema.fields ?? []) {
      addString(ids, `record-field:${schema.name}:${field.name}`);
    }
  }

  for (const typeSurface of types) {
    if (typeSurface.present) {
      addString(ids, `type:${typeSurface.name}`);
      for (const constructorName of typeSurface.constructors ?? []) {
        addString(ids, `constructor:${typeSurface.name}:${constructorName}`);
      }
    }
  }

  return ids;
}

function collectAgentPackAirNodes(air, referencedSurfaceIds) {
  const airNodeIds = new Set();

  for (const surfaceId of referencedSurfaceIds) {
    addString(airNodeIds, surfaceToAirNodeId(surfaceId));
  }

  return (air.nodes ?? [])
    .filter((node) => airNodeIds.has(node.id))
    .map((node) => compactObject({
      id: node.id,
      kind: node.kind,
      name: node.name ?? null
    }));
}

function summarizeAgentPackSurfaceIndex(context) {
  return {
    routes: (context.surfaceIndex?.routes ?? []).map((route) => route.id),
    schemas: (context.surfaceIndex?.schemas ?? []).map((schema) => schema.id),
    schemaFields: (context.surfaceIndex?.schemaFields ?? []).map((field) => field.id),
    types: (context.surfaceIndex?.types ?? []).map((typeSurface) => typeSurface.id),
    foreignBoundaries: (context.surfaceIndex?.foreignBoundaries ?? []).map((boundary) => boundary.id)
  };
}

function findManifestHostBinding(hostBindingManifest, name) {
  const mockModel = (hostBindingManifest?.mockModelCalls ?? []).find((binding) => binding.name === name);
  if (mockModel) {
    return {
      ...mockModel,
      role: "mock-model"
    };
  }

  const hostBinding = (hostBindingManifest?.hostBindings ?? []).find((binding) => binding.name === name);
  if (hostBinding) {
    return {
      ...hostBinding,
      role: "host-binding"
    };
  }

  return null;
}

function agentPackBoundaryKind(binding) {
  if (!binding) {
    return "foreign";
  }

  if (binding.role === "mock-model") {
    return "model";
  }

  if (typeof binding.name === "string" && /^(store|load|review)/.test(binding.name)) {
    return "storage";
  }

  return binding.role === "host-binding" ? "host" : "foreign";
}

function sourceModulePath(sourceModule, entry) {
  if (sourceModule.role === "entry") {
    return entry;
  }

  if (typeof sourceModule.moduleName === "string" && sourceModule.moduleName.length > 0) {
    return `${sourceModule.moduleName.split(".").join("/")}.clasp`;
  }

  return entry;
}

function schemaIdForType(typeName) {
  return typeof typeName === "string" && typeName.length > 0
    ? `schema:${typeName}`
    : null;
}

function surfaceToAirNodeId(surfaceId) {
  if (typeof surfaceId !== "string") {
    return "";
  }

  if (surfaceId.startsWith("schema-field:")) {
    return surfaceId.replace(/^schema-field:/, "record-field:");
  }

  if (surfaceId.startsWith("schema:")) {
    return surfaceId.replace(/^schema:/, "record:");
  }

  return surfaceId;
}

function addString(target, value) {
  if (typeof value === "string" && value.length > 0) {
    target.add(value);
  }
}

function normalizeTaskCommand(command) {
  return Array.isArray(command)
    ? command.filter((part) => typeof part === "string")
    : [];
}

function compactObject(record) {
  return Object.fromEntries(
    Object.entries(record).filter(([, value]) => value !== undefined && value !== null)
  );
}

function walkBenchmarkExpr(expr, visit) {
  if (!expr || typeof expr !== "object") {
    return;
  }

  visit(expr);

  for (const value of Object.values(expr)) {
    if (Array.isArray(value)) {
      for (const item of value) {
        walkBenchmarkExpr(item, visit);
      }
    } else if (value && typeof value === "object") {
      walkBenchmarkExpr(value, visit);
    }
  }
}

function isLocalCall(expr, name) {
  return expr?.kind === "call" &&
    expr.callee?.kind === "local" &&
    expr.callee.name === name;
}

function stringLiteralValue(expr) {
  return expr?.kind === "string" ? expr.value : null;
}

function localCallName(expr) {
  return expr?.kind === "call" && expr.callee?.kind === "local"
    ? expr.callee.name
    : null;
}

function summarizeBenchmarkExpr(expr) {
  if (!expr || typeof expr !== "object") {
    return "";
  }

  if (expr.kind === "call") {
    return `${expr.callee?.name ?? expr.callee?.kind ?? "call"}(...)`;
  }

  if (expr.kind === "local") {
    return expr.name;
  }

  if (expr.kind === "intrinsic") {
    return expr.name;
  }

  return expr.kind ?? "expr";
}

function compareByName(left, right) {
  return String(left.name ?? "").localeCompare(String(right.name ?? ""));
}

function renderClaspLanguageGuide({
  workspace,
  entryPath,
  prepRoot,
  moduleName,
  surfacesPath,
  agentPackPath,
  explainPath,
  hostBindingManifestPath,
  hostBindingManifest,
  appOwnedEditSurface,
  context,
  air,
  uiGraph
}) {
  const sourceFiles = collectWorkspaceClaspSourceFiles(workspace);
  const routes = collectContextRoutes(context);
  const foreignDecls = collectContextForeignDecls(context, hostBindingManifest);
  const artifactPaths = [
    path.join(prepRoot, `${moduleName}.context.json`),
    path.join(prepRoot, `${moduleName}.air.json`),
    path.join(prepRoot, `${moduleName}.ui.json`),
    surfacesPath,
    agentPackPath
  ];

  if (explainPath) {
    artifactPaths.push(explainPath);
  }
  if (hostBindingManifestPath) {
    artifactPaths.push(hostBindingManifestPath);
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

  if ((appOwnedEditSurface ?? []).length > 0) {
    lines.push("", "## App-owned edit surface", "");
    for (const sourceFile of appOwnedEditSurface) {
      lines.push(`- \`${sourceFile}\``);
    }
    lines.push("- Prefer these files for product behavior changes before changing test or harness files.");
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

  if (hostBindingManifestPath) {
    lines.push(
      "",
      "## Host binding manifest",
      "",
      `- \`${path.relative(workspace, hostBindingManifestPath)}\` lists route host inputs, host/runtime binding contracts, model JSON shapes, and runtime-owned failure behavior for this task.`
    );
  }

  lines.push(
    "",
    "## Benchmark surfaces",
    "",
    `- \`${path.relative(workspace, surfacesPath)}\` summarizes source modules, records/enums, typed routes, pages/forms, decode boundaries, host bindings, and expected host JSON shapes.`
  );

  lines.push(
    "",
    "## Agent action pack",
    "",
    `- \`${path.relative(workspace, agentPackPath)}\` joins compiler context/AIR, surface index entries, app-owned edit files, host contracts, contract gaps, and verifier commands for benchmark agents.`
  );

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
    "- Let `verify.sh` regenerate the packaged native binary.",
    "- Prefer the Clasp schema and route files before touching benchmark harness glue."
  );

  return lines.join("\n") + "\n";
}

function collectWorkspaceClaspSourceFiles(workspace) {
  const sourceFiles = [];

  function walk(currentPath) {
    const entries = readdirSync(currentPath, { withFileTypes: true });
    for (const entry of entries) {
      if (entry.name === "benchmark-prep" || entry.name === "build" || entry.name === "dist") {
        continue;
      }

      const entryPath = path.join(currentPath, entry.name);
      if (entry.isDirectory()) {
        walk(entryPath);
        continue;
      }

      if (entry.isFile() && entry.name.endsWith(".clasp")) {
        sourceFiles.push(path.relative(workspace, entryPath));
      }
    }
  }

  walk(workspace);
  return sourceFiles.sort((left, right) => left.localeCompare(right));
}

function collectContextRoutes(context) {
  const surfaceRoutes = (context.surfaceIndex?.routes ?? [])
    .map((route) => ({
      method: String(route.method ?? "UNKNOWN"),
      path: String(route.path ?? "/"),
      requestType: String(route.requestType ?? "Unknown"),
      responseType: String(route.responseType ?? "Unknown")
    }));

  if (surfaceRoutes.length > 0) {
    return surfaceRoutes;
  }

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

function collectContextForeignDecls(context, hostBindingManifest = null) {
  const manifestNames = new Set([
    ...((hostBindingManifest?.mockModelCalls ?? []).map((binding) => binding.name)),
    ...((hostBindingManifest?.hostBindings ?? []).map((binding) => binding.name))
  ]);
  const keepManifestBoundary = (name) => manifestNames.size === 0 || manifestNames.has(String(name ?? ""));
  const surfaceForeignDecls = (context.surfaceIndex?.foreignBoundaries ?? [])
    .filter((boundary) => keepManifestBoundary(boundary.name))
    .map((boundary) => ({
      name: String(boundary.name ?? "unknown"),
      type: String(boundary.type ?? "Unknown")
    }));

  if (surfaceForeignDecls.length > 0) {
    return surfaceForeignDecls;
  }

  return (context.nodes ?? [])
    .filter((node) => node.kind === "foreign")
    .filter((node) => {
      const attrs = attrsToRecord(node.attrs);
      return keepManifestBoundary(attrs.name);
    })
    .map((node) => {
      const attrs = attrsToRecord(node.attrs);
      return {
        name: String(attrs.name ?? "unknown"),
        type: String(attrs.type ?? "Unknown")
      };
    });
}

function isHostBindingName(name) {
  return typeof name === "string" &&
    !["text", "element", "styled", "link", "form", "input", "submit", "page", "redirect"].includes(name);
}

function looksLikeNativeBinary(contents) {
  if (!contents || contents.length < 4) {
    return false;
  }

  const prefix = contents.subarray(0, 4);
  if (
    (prefix[0] === 0x7f && prefix[1] === 0x45 && prefix[2] === 0x4c && prefix[3] === 0x46) ||
    (prefix[0] === 0xcf && prefix[1] === 0xfa && prefix[2] === 0xed && prefix[3] === 0xfe) ||
    (prefix[0] === 0xfe && prefix[1] === 0xed && prefix[2] === 0xfa && prefix[3] === 0xcf)
  ) {
    return true;
  }

  for (const byte of contents.subarray(0, 32)) {
    if (byte === 0) {
      return true;
    }
  }

  return false;
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

function resolveTaskSelection(taskSelection) {
  if (!taskSelection) {
    throw new Error("task id or task-set alias is required");
  }

  return taskSetAliases[taskSelection] ?? [taskSelection];
}

function normalizeBenchmarkMode(mode) {
  if (!mode) {
    return "raw-repo";
  }

  if (!benchmarkModes.has(mode)) {
    throw new Error(`unsupported benchmark mode: ${mode}`);
  }

  return mode;
}

async function resolvePromptPath(task, requestedMode) {
  const mode = normalizeBenchmarkMode(requestedMode);
  const taskPromptPath = path.join(task.dir, task.prompt);
  const promptDir = path.dirname(taskPromptPath);
  const promptBase = path.basename(taskPromptPath, path.extname(taskPromptPath));
  const promptExt = path.extname(taskPromptPath);
  const candidates = [];

  if (mode === "raw-repo") {
    candidates.push(path.join(promptDir, `${promptBase}.raw${promptExt}`));
  }
  if (mode === "file-hinted") {
    candidates.push(path.join(promptDir, `${promptBase}.file-hinted${promptExt}`));
  }
  if (mode === "oracle") {
    candidates.push(path.join(promptDir, `${promptBase}.oracle${promptExt}`));
  }

  candidates.push(taskPromptPath);

  for (const candidate of candidates) {
    if (candidate === taskPromptPath || await fileExists(candidate)) {
      return candidate;
    }
  }

  return taskPromptPath;
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
    const mode = result.protocol?.mode ?? "";
    const workflowAssistance = result.protocol?.workflowAssistance ?? "";
    return [result.taskId, result.harness, result.model, mode, workflowAssistance, series].join("\t");
  });

  for (const [groupKey, groupResults] of grouped.entries()) {
    const [taskId, harness, model, mode, workflowAssistance, series] = groupKey.split("\t");
    const summary = summarizeGroup(groupResults);

    console.log(`${taskId}\t${harness}\t${model}`);
    if (mode) {
      console.log(`  mode: ${mode}`);
    }
    if (workflowAssistance) {
      console.log(`  workflowAssistance: ${workflowAssistance}`);
    }
    if (series) {
      console.log(`  series: ${series}`);
    }
    console.log(`  runs: ${summary.runs}`);
    console.log(`  passRate: ${summary.passRate}`);
    console.log(`  timeToGreenMs: ${summary.timeToGreenMs}`);
    console.log(`  medianDurationMs: ${summary.medianDurationMs}`);
    console.log(`  medianTokens: ${summary.medianTokens}`);
    console.log(`  medianUncachedTokens: ${summary.medianUncachedTokens}`);
    if (summary.medianDiscoveryMs !== "n/a") {
      console.log(`  medianDiscoveryMs: ${summary.medianDiscoveryMs}`);
    }
    if (summary.medianFirstEditMs !== "n/a") {
      console.log(`  medianFirstEditMs: ${summary.medianFirstEditMs}`);
    }
    if (summary.medianFirstVerifyMs !== "n/a") {
      console.log(`  medianFirstVerifyMs: ${summary.medianFirstVerifyMs}`);
    }
    if (summary.medianPhaseTimeToGreenMs !== "n/a") {
      console.log(`  medianPhaseTimeToGreenMs: ${summary.medianPhaseTimeToGreenMs}`);
    }
  }

  const comparisonSections = buildTaskFamilyComparisons(filtered);
  for (const section of comparisonSections) {
    console.log(section.comparisonLabel);

    for (const comparison of section.comparisons) {
      console.log(
        `  ${comparison.harness}\t${comparison.model}\t${comparison.series}`
      );
      console.log(`    mode: ${comparison.mode}`);
      console.log(`    workflowAssistance: ${comparison.workflowAssistance}`);
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

  const workflowAssistanceComparisons = buildWorkflowAssistanceComparisons(filtered);
  if (workflowAssistanceComparisons.length > 0) {
    console.log(airPlanningWorkflowComparison.comparisonLabel);

    for (const comparison of workflowAssistanceComparisons) {
      console.log(
        `  ${comparison.taskId}\t${comparison.harness}\t${comparison.model}\t${comparison.series}`
      );
      console.log(`    mode: ${comparison.mode}`);
      console.log(
        `    ${buildComparisonMetricKey(comparison.baselineLabel, "WorkflowAssistance")}: ${comparison.baselineWorkflowAssistance}`
      );
      console.log(
        `    ${buildComparisonMetricKey(comparison.candidateLabel, "WorkflowAssistance")}: ${comparison.candidateWorkflowAssistance}`
      );
      console.log(
        `    ${buildComparisonMetricKey(comparison.baselineLabel, "PassRate")}: ${comparison.baseline.passRate}`
      );
      console.log(
        `    ${buildComparisonMetricKey(comparison.candidateLabel, "PassRate")}: ${comparison.candidate.passRate}`
      );
      console.log(`    passRateDeltaPct: ${comparison.passRateDeltaPct}`);
      console.log(
        `    ${buildComparisonMetricKey(comparison.baselineLabel, "TimeToGreenMs")}: ${comparison.baseline.timeToGreenMs}`
      );
      console.log(
        `    ${buildComparisonMetricKey(comparison.candidateLabel, "TimeToGreenMs")}: ${comparison.candidate.timeToGreenMs}`
      );
      console.log(`    timeToGreenDeltaMs: ${comparison.timeToGreenDeltaMs}`);
      console.log(
        `    ${buildComparisonMetricKey(comparison.baselineLabel, "MedianTokens")}: ${comparison.baseline.medianTokens}`
      );
      console.log(
        `    ${buildComparisonMetricKey(comparison.candidateLabel, "MedianTokens")}: ${comparison.candidate.medianTokens}`
      );
      console.log(`    tokenDelta: ${comparison.tokenDelta}`);
      console.log(`    uncachedTokenDelta: ${comparison.uncachedTokenDelta}`);
    }
  }

  printBenchmarkSuiteComparisons(buildBenchmarkSuiteComparisons(filtered, publicAppBenchmark));
  printBenchmarkSuiteComparisons(
    buildBenchmarkSuiteComparisons(filtered, mixedStackSemanticLayerBenchmark)
  );
  printAgentPlanningScorecard(buildAgentPlanningScorecard(filtered));
  printCachingAndTrustScorecard(buildCachingAndTrustScorecard(filtered));
}

async function packageCommand(args) {
  const options = parseOptions(args);
  if (!options.output) {
    throw new Error("package requires --output");
  }

  const results = (await loadResults())
    .filter((result) => matchesSummaryFilter(result, options))
    .sort((left, right) => left.fileName.localeCompare(right.fileName));

  if (results.length === 0) {
    throw new Error("no results matched the supplied filters");
  }

  const taskIds = [...new Set(results.map((result) => result.taskId))]
    .sort((left, right) => left.localeCompare(right));
  const tasks = [];

  for (const taskId of taskIds) {
    tasks.push(await loadTask(taskId));
  }

  const stagingRoot = await mkdtemp(path.join(os.tmpdir(), "clasp-benchmark-package-"));
  const bundleRoot = path.join(stagingRoot, "bundle");
  const outputPath = path.resolve(options.output);

  try {
    await mkdir(path.join(bundleRoot, "benchmarks"), { recursive: true });
    await copyPackageFiles(bundleRoot, results, tasks);

    const manifestPath = path.join(bundleRoot, "benchmarks", "package-manifest.json");
    const manifest = await buildPackageManifest(bundleRoot, results, tasks, options);
    await writeFile(manifestPath, JSON.stringify(manifest, null, 2) + "\n", "utf8");
    await createDeterministicTarball(bundleRoot, outputPath);
  } finally {
    await rm(stagingRoot, { recursive: true, force: true });
  }

  console.log(`Packaged ${results.length} results`);
  console.log(`Tasks: ${taskIds.join(", ")}`);
  console.log(`Archive: ${outputPath}`);
}

function summarizeGroup(groupResults) {
  const ordered = [...groupResults].sort(compareRunOrder);
  const passed = ordered.filter((result) => result.verification.passed).length;
  const durations = ordered.map((result) => result.durationMs);
  const totals = ordered.map((result) => result.tokenUsage.total);
  const uncached = ordered.map(
    (result) => result.harnessUsage?.uncachedTotal ?? result.tokenUsage.total
  );
  const cachedInput = ordered.map((result) => result.harnessUsage?.cachedInputTokens ?? 0);
  const cacheReuseRates = ordered
    .map((result) => computeCacheReuseRate(result))
    .filter((value) => value !== null);
  const discovery = numericPhaseValues(ordered, "discoveryMs");
  const firstEdit = numericPhaseValues(ordered, "firstEditMs");
  const firstVerify = numericPhaseValues(ordered, "firstVerifyMs");
  const phaseTimeToGreen = numericPhaseValues(ordered, "timeToGreenMs");
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
    medianUncachedTokens: median(uncached),
    medianCachedInputTokens: median(cachedInput),
    medianCacheReuseRatePct: cacheReuseRates.length > 0 ? median(cacheReuseRates) : "n/a",
    medianDiscoveryMs: discovery.length > 0 ? median(discovery) : "n/a",
    medianFirstEditMs: firstEdit.length > 0 ? median(firstEdit) : "n/a",
    medianFirstVerifyMs: firstVerify.length > 0 ? median(firstVerify) : "n/a",
    medianPhaseTimeToGreenMs: phaseTimeToGreen.length > 0 ? median(phaseTimeToGreen) : "n/a"
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

function printBenchmarkSuiteComparisons(comparisons) {
  if (comparisons.length === 0) {
    return;
  }

  console.log(comparisons[0].comparisonLabel);

  for (const comparison of comparisons) {
    console.log(
      `  ${comparison.harness}\t${comparison.model}\t${comparison.series}`
    );
    console.log(`    mode: ${comparison.mode}`);
    console.log(`    workflowAssistance: ${comparison.workflowAssistance}`);
    console.log(`    taskPairs: ${comparison.taskPairs}`);
    if (comparison.checkpointTasks > 0) {
      console.log(`    checkpointTasks: ${comparison.checkpointTasks}`);
      console.log(`    checkpointCompletedTasks: ${comparison.checkpointCompletedTasks}/${comparison.checkpointTasks}`);
    }
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
    console.log(
      `    ${buildComparisonMetricKey(comparison.leftLabel, "FeatureThroughputPerHour")}: ${comparison.left.featureThroughputPerHour}`
    );
    console.log(
      `    ${buildComparisonMetricKey(comparison.rightLabel, "FeatureThroughputPerHour")}: ${comparison.right.featureThroughputPerHour}`
    );
    console.log(`    throughputDeltaPct: ${comparison.throughputDeltaPct}`);
    console.log(`    tokenDelta: ${comparison.tokenDelta}`);
    console.log(
      `    uncachedTokenDelta: ${comparison.uncachedTokenDelta}`
    );
  }
}

function buildBenchmarkSuiteComparisons(results, benchmark) {
  const checkpointTaskIds = benchmark.checkpointTaskIds ?? [];
  const relevantTaskIds = new Set(
    [
      ...benchmark.taskPairs.flatMap((pair) => [pair.leftTaskId, pair.rightTaskId]),
      ...checkpointTaskIds
    ]
  );
  const relevant = results.filter((result) => relevantTaskIds.has(result.taskId));
  const grouped = groupBy(relevant, (result) => {
    const series = parseSeriesRun(result.notes).series ?? "";
    const mode = result.protocol?.mode ?? "";
    const workflowAssistance = result.protocol?.workflowAssistance ?? "";
    return [result.harness, result.model, mode, workflowAssistance, series].join("\t");
  });
  const comparisons = [];

  for (const [groupKey, groupResults] of grouped.entries()) {
    const [harness, model, mode, workflowAssistance, series] = groupKey.split("\t");
    const byTask = groupBy(groupResults, (result) => result.taskId);
    const leftTaskSummaries = [];
    const rightTaskSummaries = [];
    const checkpointSummaries = [];

    for (const pair of benchmark.taskPairs) {
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

    for (const checkpointTaskId of checkpointTaskIds) {
      const checkpointResults = byTask.get(checkpointTaskId);

      if (!checkpointResults) {
        checkpointSummaries.length = 0;
        break;
      }

      checkpointSummaries.push(summarizeGroup(checkpointResults));
    }

    if (leftTaskSummaries.length !== benchmark.taskPairs.length) {
      continue;
    }
    if (checkpointSummaries.length !== checkpointTaskIds.length) {
      continue;
    }

    const left = summarizeBenchmarkSuite(leftTaskSummaries);
    const right = summarizeBenchmarkSuite(rightTaskSummaries);
    comparisons.push({
      comparisonLabel: benchmark.comparisonLabel,
      harness,
      model,
      mode: mode || "(unspecified)",
      workflowAssistance: workflowAssistance || "unspecified",
      series: series || "(all-runs)",
      taskPairs: benchmark.taskPairs.length,
      checkpointTasks: checkpointTaskIds.length,
      checkpointCompletedTasks: checkpointSummaries.filter((summary) => summary.timeToGreenMs !== "n/a").length,
      leftLabel: benchmark.leftLabel,
      rightLabel: benchmark.rightLabel,
      left,
      right,
      passRateDeltaPct: Math.round(left.runPassRatePct - right.runPassRatePct),
      timeToGreenDeltaMs:
        typeof left.suiteTimeToGreenMs === "number" && typeof right.suiteTimeToGreenMs === "number"
          ? left.suiteTimeToGreenMs - right.suiteTimeToGreenMs
          : "n/a",
      throughputDeltaPct:
        typeof left.featureThroughputPerHour === "number" &&
          typeof right.featureThroughputPerHour === "number" &&
          right.featureThroughputPerHour !== 0
          ? Math.round(
            (left.featureThroughputPerHour - right.featureThroughputPerHour)
              / right.featureThroughputPerHour
              * 100
          )
          : "n/a",
      tokenDelta: left.suiteMedianTokens - right.suiteMedianTokens,
      uncachedTokenDelta:
        left.suiteMedianUncachedTokens - right.suiteMedianUncachedTokens
    });
  }

  return comparisons.sort((left, right) =>
    [left.harness, left.model, left.mode, left.workflowAssistance, left.series].join("\t").localeCompare(
      [right.harness, right.model, right.mode, right.workflowAssistance, right.series].join("\t")
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
  const featureThroughputPerHour = typeof suiteTimeToGreenMs === "number" && suiteTimeToGreenMs > 0
    ? Number((completedTasks * 3600000 / suiteTimeToGreenMs).toFixed(2))
    : "n/a";

  return {
    completedTasks,
    runPassRate: `${(totalPassedRuns / totalRuns * 100).toFixed(0)}%`,
    runPassRatePct: totalPassedRuns / totalRuns * 100,
    suiteTimeToGreenMs,
    featureThroughputPerHour,
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
    const mode = result.protocol?.mode ?? "";
    const workflowAssistance = result.protocol?.workflowAssistance ?? "";
    return [result.harness, result.model, mode, workflowAssistance, series].join("\t");
  });
  const comparisons = [];

  for (const [groupKey, groupResults] of grouped.entries()) {
    const [harness, model, mode, workflowAssistance, series] = groupKey.split("\t");
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
      mode: mode || "(unspecified)",
      workflowAssistance: workflowAssistance || "unspecified",
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
      cachedInputTokenDelta:
        left.medianCachedInputTokens - right.medianCachedInputTokens,
      cacheReuseRateDeltaPct:
        typeof left.medianCacheReuseRatePct === "number" &&
          typeof right.medianCacheReuseRatePct === "number"
          ? left.medianCacheReuseRatePct - right.medianCacheReuseRatePct
          : "n/a",
      uncachedTokenDelta:
        left.medianUncachedTokens - right.medianUncachedTokens
    });
  }

  return comparisons.sort((left, right) =>
    [left.harness, left.model, left.mode, left.workflowAssistance, left.series].join("\t").localeCompare(
      [right.harness, right.model, right.mode, right.workflowAssistance, right.series].join("\t")
    )
  );
}

function buildCachingAndTrustScorecard(results) {
  const entries = [];

  for (const slice of cachingAndTrustBenchmark.slices) {
    for (const comparison of buildTaskComparisons(results, slice)) {
      entries.push({
        sliceLabel: slice.sliceLabel,
        sliceType: slice.type,
        source: slice.comparisonLabel,
        includeCacheMetrics: slice.includeCacheMetrics === true,
        ...comparison
      });
    }
  }

  return entries.sort((left, right) =>
    [
      left.sliceLabel,
      left.harness,
      left.model,
      left.mode,
      left.workflowAssistance ?? "",
      left.series
    ].join("\t").localeCompare(
      [
        right.sliceLabel,
        right.harness,
        right.model,
        right.mode,
        right.workflowAssistance ?? "",
        right.series
      ].join("\t")
    )
  );
}

function printCachingAndTrustScorecard(entries) {
  if (entries.length === 0) {
    return;
  }

  console.log(cachingAndTrustBenchmark.comparisonLabel);

  for (const entry of entries) {
    console.log(`  ${entry.sliceLabel}\t${entry.harness}\t${entry.model}\t${entry.series}`);
    console.log(`    mode: ${entry.mode}`);
    console.log(`    sourceBenchmark: ${entry.source}`);
    console.log(`    workflowAssistance: ${entry.workflowAssistance}`);
    console.log(
      `    ${buildComparisonMetricKey(entry.leftLabel, "PassRate")}: ${entry.left.passRate}`
    );
    console.log(
      `    ${buildComparisonMetricKey(entry.rightLabel, "PassRate")}: ${entry.right.passRate}`
    );
    console.log(`    passRateDeltaPct: ${entry.passRateDeltaPct}`);
    console.log(
      `    ${buildComparisonMetricKey(entry.leftLabel, "TimeToGreenMs")}: ${entry.left.timeToGreenMs}`
    );
    console.log(
      `    ${buildComparisonMetricKey(entry.rightLabel, "TimeToGreenMs")}: ${entry.right.timeToGreenMs}`
    );
    console.log(`    timeToGreenDeltaMs: ${entry.timeToGreenDeltaMs}`);
    console.log(`    tokenDelta: ${entry.tokenDelta}`);
    console.log(`    uncachedTokenDelta: ${entry.uncachedTokenDelta}`);

    if (entry.includeCacheMetrics) {
      console.log(
        `    ${buildComparisonMetricKey(entry.leftLabel, "MedianCachedInputTokens")}: ${entry.left.medianCachedInputTokens}`
      );
      console.log(
        `    ${buildComparisonMetricKey(entry.rightLabel, "MedianCachedInputTokens")}: ${entry.right.medianCachedInputTokens}`
      );
      console.log(`    cachedInputTokenDelta: ${entry.cachedInputTokenDelta}`);
      console.log(
        `    ${buildComparisonMetricKey(entry.leftLabel, "MedianCacheReuseRatePct")}: ${entry.left.medianCacheReuseRatePct}`
      );
      console.log(
        `    ${buildComparisonMetricKey(entry.rightLabel, "MedianCacheReuseRatePct")}: ${entry.right.medianCacheReuseRatePct}`
      );
      console.log(`    cacheReuseRateDeltaPct: ${entry.cacheReuseRateDeltaPct}`);
    }
  }
}

function buildWorkflowAssistanceComparisons(results) {
  const relevant = results.filter((result) => result.language === "clasp");
  const grouped = groupBy(relevant, (result) => {
    const series = parseSeriesRun(result.notes).series ?? "";
    const mode = result.protocol?.mode ?? "";
    return [result.taskId, result.harness, result.model, mode, series].join("\t");
  });
  const comparisons = [];

  for (const [groupKey, groupResults] of grouped.entries()) {
    const [taskId, harness, model, mode, series] = groupKey.split("\t");
    const byWorkflowAssistance = groupBy(
      groupResults,
      (result) => result.protocol?.workflowAssistance ?? "unspecified"
    );
    const baselineResults = byWorkflowAssistance.get(
      airPlanningWorkflowComparison.baselineWorkflowAssistance
    );
    const candidateResults = byWorkflowAssistance.get(
      airPlanningWorkflowComparison.candidateWorkflowAssistance
    );

    if (!baselineResults || !candidateResults) {
      continue;
    }

    const baseline = summarizeGroup(baselineResults);
    const candidate = summarizeGroup(candidateResults);
    comparisons.push({
      taskId,
      harness,
      model,
      mode: mode || "(unspecified)",
      series: series || "(all-runs)",
      baselineLabel: airPlanningWorkflowComparison.baselineLabel,
      candidateLabel: airPlanningWorkflowComparison.candidateLabel,
      baselineWorkflowAssistance: airPlanningWorkflowComparison.baselineWorkflowAssistance,
      candidateWorkflowAssistance: airPlanningWorkflowComparison.candidateWorkflowAssistance,
      baseline,
      candidate,
      passRateDeltaPct: Math.round(candidate.passRatePct - baseline.passRatePct),
      timeToGreenDeltaMs:
        typeof candidate.timeToGreenMs === "number" && typeof baseline.timeToGreenMs === "number"
          ? candidate.timeToGreenMs - baseline.timeToGreenMs
          : "n/a",
      tokenDelta: candidate.medianTokens - baseline.medianTokens,
      uncachedTokenDelta:
        candidate.medianUncachedTokens - baseline.medianUncachedTokens
    });
  }

  return comparisons.sort((left, right) =>
    [left.taskId, left.harness, left.model, left.mode, left.series].join("\t").localeCompare(
      [right.taskId, right.harness, right.model, right.mode, right.series].join("\t")
    )
  );
}

function buildAgentPlanningScorecard(results) {
  const entries = [];
  const workflowComparisons = buildWorkflowAssistanceComparisons(results);

  for (const slice of agentPlanningBenchmark.slices) {
    if (slice.type === "task-family") {
      for (const comparison of buildTaskComparisons(results, slice)) {
        entries.push({
          sliceLabel: slice.sliceLabel,
          sliceType: slice.type,
          source: slice.comparisonLabel,
          ...comparison
        });
      }
      continue;
    }

    if (slice.type === "workflow-assistance") {
      for (const comparison of workflowComparisons.filter((entry) => entry.taskId === slice.taskId)) {
        entries.push({
          sliceLabel: slice.sliceLabel,
          sliceType: slice.type,
          source: slice.sourceComparison,
          ...comparison
        });
      }
      continue;
    }

    if (slice.type === "task-summary") {
      const relevant = results.filter((result) => result.taskId === slice.taskId);
      const grouped = groupBy(relevant, (result) => {
        const series = parseSeriesRun(result.notes).series ?? "";
        const mode = result.protocol?.mode ?? "";
        const workflowAssistance = result.protocol?.workflowAssistance ?? "";
        return [result.harness, result.model, mode, workflowAssistance, series].join("\t");
      });

      for (const [groupKey, groupResults] of grouped.entries()) {
        const [harness, model, mode, workflowAssistance, series] = groupKey.split("\t");
        entries.push({
          sliceLabel: slice.sliceLabel,
          sliceType: slice.type,
          sourceTaskId: slice.taskId,
          harness,
          model,
          mode: mode || "(unspecified)",
          workflowAssistance: workflowAssistance || "unspecified",
          series: series || "(all-runs)",
          summary: summarizeGroup(groupResults)
        });
      }
    }
  }

  return entries.sort((left, right) =>
    [
      left.sliceLabel,
      left.harness,
      left.model,
      left.mode,
      left.workflowAssistance ?? "",
      left.series
    ].join("\t").localeCompare(
      [
        right.sliceLabel,
        right.harness,
        right.model,
        right.mode,
        right.workflowAssistance ?? "",
        right.series
      ].join("\t")
    )
  );
}

function printAgentPlanningScorecard(entries) {
  if (entries.length === 0) {
    return;
  }

  console.log(agentPlanningBenchmark.comparisonLabel);

  for (const entry of entries) {
    console.log(`  ${entry.sliceLabel}\t${entry.harness}\t${entry.model}\t${entry.series}`);
    console.log(`    mode: ${entry.mode}`);

    if (entry.sliceType === "task-family") {
      console.log(`    sourceBenchmark: ${entry.source}`);
      console.log(`    workflowAssistance: ${entry.workflowAssistance}`);
      console.log(
        `    ${buildComparisonMetricKey(entry.leftLabel, "PassRate")}: ${entry.left.passRate}`
      );
      console.log(
        `    ${buildComparisonMetricKey(entry.rightLabel, "PassRate")}: ${entry.right.passRate}`
      );
      console.log(`    passRateDeltaPct: ${entry.passRateDeltaPct}`);
      console.log(
        `    ${buildComparisonMetricKey(entry.leftLabel, "TimeToGreenMs")}: ${entry.left.timeToGreenMs}`
      );
      console.log(
        `    ${buildComparisonMetricKey(entry.rightLabel, "TimeToGreenMs")}: ${entry.right.timeToGreenMs}`
      );
      console.log(`    timeToGreenDeltaMs: ${entry.timeToGreenDeltaMs}`);
      console.log(`    tokenDelta: ${entry.tokenDelta}`);
      console.log(`    uncachedTokenDelta: ${entry.uncachedTokenDelta}`);
      continue;
    }

    if (entry.sliceType === "workflow-assistance") {
      console.log(`    sourceBenchmark: ${entry.source}`);
      console.log(
        `    ${buildComparisonMetricKey(entry.baselineLabel, "WorkflowAssistance")}: ${entry.baselineWorkflowAssistance}`
      );
      console.log(
        `    ${buildComparisonMetricKey(entry.candidateLabel, "WorkflowAssistance")}: ${entry.candidateWorkflowAssistance}`
      );
      console.log(
        `    ${buildComparisonMetricKey(entry.baselineLabel, "PassRate")}: ${entry.baseline.passRate}`
      );
      console.log(
        `    ${buildComparisonMetricKey(entry.candidateLabel, "PassRate")}: ${entry.candidate.passRate}`
      );
      console.log(`    passRateDeltaPct: ${entry.passRateDeltaPct}`);
      console.log(
        `    ${buildComparisonMetricKey(entry.baselineLabel, "TimeToGreenMs")}: ${entry.baseline.timeToGreenMs}`
      );
      console.log(
        `    ${buildComparisonMetricKey(entry.candidateLabel, "TimeToGreenMs")}: ${entry.candidate.timeToGreenMs}`
      );
      console.log(`    timeToGreenDeltaMs: ${entry.timeToGreenDeltaMs}`);
      console.log(`    tokenDelta: ${entry.tokenDelta}`);
      console.log(`    uncachedTokenDelta: ${entry.uncachedTokenDelta}`);
      continue;
    }

    console.log(`    sourceTask: ${entry.sourceTaskId}`);
    console.log(`    workflowAssistance: ${entry.workflowAssistance}`);
    console.log(`    runs: ${entry.summary.runs}`);
    console.log(`    passRate: ${entry.summary.passRate}`);
    console.log(`    timeToGreenMs: ${entry.summary.timeToGreenMs}`);
    console.log(`    medianDurationMs: ${entry.summary.medianDurationMs}`);
    console.log(`    medianTokens: ${entry.summary.medianTokens}`);
    console.log(`    medianUncachedTokens: ${entry.summary.medianUncachedTokens}`);
  }
}

function buildComparisonMetricKey(label, suffix) {
  return `${label}${suffix}`;
}

function computeCacheReuseRate(result) {
  const cached = result.harnessUsage?.cachedInputTokens;
  const uncachedInput = result.harnessUsage?.uncachedInputTokens;

  if (typeof cached !== "number" || typeof uncachedInput !== "number") {
    return null;
  }

  const totalInput = cached + uncachedInput;
  if (totalInput <= 0) {
    return 0;
  }

  return Number((cached / totalInput * 100).toFixed(2));
}

async function buildResult(task, options, startedAt, finishedAt, verification, usage, phases) {
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
  const protocol = await buildProtocolMetadata(task, options, startedAt, finishedAt);

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
    protocol,
    phases,
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
    results.push({
      ...result,
      fileName: entry.name
    });
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

function assertDefaultBenchmarkPathSupported(task, options) {
  if (!requiresBootstrapRecovery(task) || allowsBootstrapRecovery(options)) {
    return;
  }

  throw new Error(
    `${task.id} is not available on the default benchmark path because it still depends on the Haskell bootstrap compiler; rerun with --allow-bootstrap-recovery true for the explicit recovery-only path`
  );
}

function requiresBootstrapRecovery(task) {
  return task.language === "clasp" && task.defaultBenchmarkPath !== true;
}

function allowsBootstrapRecovery(options) {
  return parseBooleanOption(options.allowBootstrapRecovery) === true;
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

function parseBooleanOption(value) {
  if (value === undefined) {
    return false;
  }

  if (typeof value !== "string") {
    throw new Error("boolean option value must be a string");
  }

  const normalized = value.trim().toLowerCase();
  if (normalized === "true") {
    return true;
  }

  if (normalized === "false") {
    return false;
  }

  throw new Error(`expected boolean option value but received: ${value}`);
}

async function buildProtocolMetadata(task, options, startedAt, finishedAt) {
  const mode = normalizeBenchmarkMode(options.mode);
  const promptPath = await resolvePromptPath(task, mode);
  const promptRelativePath = path.relative(path.resolve("."), promptPath);
  const bundleManifestPath = options.bundleManifest ? path.resolve(options.bundleManifest) : null;
  const bundleManifest = bundleManifestPath && await fileExists(bundleManifestPath)
    ? JSON.parse(await readFile(bundleManifestPath, "utf8"))
    : null;
  const workflowAssistance = normalizeWorkflowAssistance(
    options.workflowAssistance ??
      bundleManifest?.workflowAssistance ??
      process.env.CLASP_BENCHMARK_WORKFLOW_ASSISTANCE
  );
  const seriesRun = parseSeriesRun(options.notes);
  const sampleIndex = parseOptionalPositiveNumber(options.sampleIndex ?? seriesRun.runNumber);
  const sampleCount = parseOptionalPositiveNumber(options.sampleCount ?? bundleManifest?.sampleCount);
  const sample = bundleManifest && sampleIndex !== null
    ? bundleManifest.samples?.find((entry) => entry.sampleIndex === sampleIndex) ?? null
    : null;
  const orderIndex = sample
    ? sample.runOrder.findIndex((entry) => entry.taskId === task.id)
    : -1;
  const bundleDigest = bundleManifestPath && await fileExists(bundleManifestPath)
    ? await sha256File(bundleManifestPath)
    : null;

  return {
    schemaVersion: 1,
    mode,
    workflowAssistance,
    promptFile: promptRelativePath,
    repeatedSamples: sampleCount,
    sampleIndex,
    runOrderPosition: orderIndex >= 0 ? orderIndex + 1 : null,
    randomizedOrderSeed: sample?.seed ?? bundleManifest?.seed ?? null,
    bundle: bundleManifest
      ? {
        id: bundleManifest.bundleId,
        manifestFile: path.relative(path.resolve("."), bundleManifestPath),
        sha256: bundleDigest
      }
      : null,
    timingWindow: {
      startedAt: startedAt.toISOString(),
      finishedAt: finishedAt.toISOString()
    }
  };
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

function parsePositiveNumber(value, label) {
  const parsed = parseNumber(value);
  if (parsed <= 0) {
    throw new Error(`${label} must be greater than zero`);
  }

  return parsed;
}

function parseOptionalPositiveNumber(value) {
  if (value === undefined || value === null || value === "") {
    return null;
  }

  const parsed = parseNumber(String(value));
  return parsed > 0 ? parsed : null;
}

function hasAnyTokenOption(options) {
  return (
    options.promptTokens ||
    options.completionTokens ||
    options.retryTokens ||
    options.debugTokens
  );
}

async function resolvePhaseSummary(options, workspace, startedAt, finishedAt, verification) {
  const phaseFile = options.phaseFile
    ? path.resolve(options.phaseFile)
    : path.join(workspace, "benchmark-phases.json");

  if (!(await fileExists(phaseFile))) {
    return verification.exitCode === 0
      ? { timeToGreenMs: finishedAt.getTime() - startedAt.getTime() }
      : null;
  }

  const raw = JSON.parse(await readFile(phaseFile, "utf8"));
  const phases = raw.phases ?? raw;
  const summary = {};

  for (const key of ["discoveryMs", "firstEditMs", "firstVerifyMs", "timeToGreenMs"]) {
    const value = phases[key];
    if (typeof value === "number" && Number.isFinite(value) && value >= 0) {
      summary[key] = Math.round(value);
    }
  }

  if (summary.timeToGreenMs === undefined && verification.exitCode === 0) {
    summary.timeToGreenMs = finishedAt.getTime() - startedAt.getTime();
  }

  return Object.keys(summary).length > 0 ? summary : null;
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

  if (options.mode && result.protocol?.mode !== options.mode) {
    return false;
  }

  if (
    options.workflowAssistance &&
    result.protocol?.workflowAssistance !== normalizeWorkflowAssistance(options.workflowAssistance)
  ) {
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

function normalizeWorkflowAssistance(value) {
  const normalized = String(value ?? "unspecified")
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9._-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .replace(/-+/g, "-");

  return normalized.length > 0 ? normalized : "unspecified";
}

function numericPhaseValues(results, key) {
  return results
    .map((result) => result.phases?.[key])
    .filter((value) => typeof value === "number" && Number.isFinite(value));
}

function compareRunOrder(left, right) {
  const leftSeries = parseSeriesRun(left.notes);
  const rightSeries = parseSeriesRun(right.notes);

  if (leftSeries.runNumber !== null && rightSeries.runNumber !== null) {
    return leftSeries.runNumber - rightSeries.runNumber;
  }

  return left.finishedAt.localeCompare(right.finishedAt);
}

function createStableId(value) {
  return createHash("sha256").update(String(value)).digest("hex").slice(0, 16);
}

function seededOrder(taskIds, seed) {
  const tagged = taskIds.map((taskId) => ({
    taskId,
    orderKey: createStableId(`${seed}:${taskId}`)
  }));

  tagged.sort((left, right) =>
    left.orderKey.localeCompare(right.orderKey) || left.taskId.localeCompare(right.taskId)
  );

  return tagged.map((entry) => entry.taskId);
}

function buildFrozenSample(taskIds, sampleIndex, seriesSeed) {
  const seed = `${seriesSeed}:sample:${sampleIndex}`;
  const orderedTaskIds = seededOrder(taskIds, seed);

  return {
    sampleIndex,
    seed,
    runOrder: orderedTaskIds.map((taskId, index) => ({
      position: index + 1,
      taskId
    }))
  };
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
      stdio: ["ignore", "pipe", "pipe"]
    });
    let stdout = "";
    let stderr = "";

    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });

    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });

    child.on("error", reject);
    child.on("exit", (exitCode) => {
      resolve({
        exitCode: exitCode ?? 1,
        stdout,
        stderr
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
  console.error("  node benchmarks/run-benchmark.mjs prepare <task-id> [--workspace path --mode raw-repo|file-hinted|oracle]");
  console.error("  node benchmarks/run-benchmark.mjs freeze <task-id|alias> --count n --output path [--harness name --model name --mode raw-repo|file-hinted|oracle --workflow-assistance raw-text|compiler-owned-air|... --notes text --seed text]");
  console.error("  node benchmarks/run-benchmark.mjs verify <task-id> --workspace path [--harness name --model name --mode raw-repo|file-hinted|oracle --workflow-assistance raw-text|compiler-owned-air|... --interventions n --prompt-tokens n --completion-tokens n --retry-tokens n --debug-tokens n --notes text --bundle-manifest path --sample-count n --sample-index n --phase-file path]");
  console.error("  node benchmarks/run-benchmark.mjs run <task-id> --workspace path --agent-command command [--harness name --model name --mode raw-repo|file-hinted|oracle --workflow-assistance raw-text|compiler-owned-air|... --interventions n --prompt-tokens n --completion-tokens n --retry-tokens n --debug-tokens n --notes text --bundle-manifest path --sample-count n --sample-index n --phase-file path]");
  console.error("  node benchmarks/run-benchmark.mjs package --output path [--task-id id --harness name --model name --language name --mode raw-repo|file-hinted|oracle --workflow-assistance raw-text|compiler-owned-air|... --notes text]");
  console.error("  node benchmarks/run-benchmark.mjs summarize [--task-id id --harness name --model name --language name --mode raw-repo|file-hinted|oracle --workflow-assistance raw-text|compiler-owned-air|... --notes text]");
  console.error("  task-set aliases: app, control-plane, lead-priority, lead-rejection, lead-segment, lead-persistence, correctness, external-adaptation, foreign-interop, mixed-stack-semantic-layer, interop-boundary, secret-handling, authorization-data-access, audit-log, npm-interop, python-interop, rust-interop, compiler-maintenance, syntax-form");
}

async function copyPackageFiles(bundleRoot, results, tasks) {
  const benchmarkDir = path.join(bundleRoot, "benchmarks");
  const bundlesDir = path.join(benchmarkDir, "bundles");
  const resultsDir = path.join(benchmarkDir, "results");
  const tasksDir = path.join(benchmarkDir, "tasks");

  await mkdir(bundlesDir, { recursive: true });
  await mkdir(resultsDir, { recursive: true });
  await mkdir(tasksDir, { recursive: true });

  const repoFiles = [
    { source: path.resolve("AGENTS.md"), target: path.join(bundleRoot, "AGENTS.md") },
    { source: path.join(benchmarkRoot, "README.md"), target: path.join(benchmarkDir, "README.md") },
    {
      source: path.join(benchmarkRoot, "result-schema.json"),
      target: path.join(benchmarkDir, "result-schema.json")
    },
    {
      source: path.join(benchmarkRoot, "run-benchmark.mjs"),
      target: path.join(benchmarkDir, "run-benchmark.mjs")
    },
    {
      source: path.join(benchmarkRoot, "run-codex-harness.sh"),
      target: path.join(benchmarkDir, "run-codex-harness.sh")
    },
    {
      source: path.join(benchmarkRoot, "run-claude-harness.sh"),
      target: path.join(benchmarkDir, "run-claude-harness.sh")
    },
    {
      source: path.join(benchmarkRoot, "run-codex-series.sh"),
      target: path.join(benchmarkDir, "run-codex-series.sh")
    },
    {
      source: path.join(benchmarkRoot, "run-claude-series.sh"),
      target: path.join(benchmarkDir, "run-claude-series.sh")
    }
  ];

  for (const file of repoFiles) {
    if (await fileExists(file.source)) {
      await mkdir(path.dirname(file.target), { recursive: true });
      await cp(file.source, file.target);
    }
  }

  for (const result of results) {
    await cp(
      path.join(resultsRoot, result.fileName),
      path.join(resultsDir, result.fileName)
    );
  }

  const bundleManifests = [...new Set(
    results
      .map((result) => result.protocol?.bundle?.manifestFile)
      .filter((value) => typeof value === "string" && value.length > 0)
  )];

  for (const relativeBundlePath of bundleManifests) {
    const sourcePath = path.resolve(relativeBundlePath);
    if (!(await fileExists(sourcePath))) {
      continue;
    }
    await cp(sourcePath, path.join(bundleRoot, relativeBundlePath));
  }

  for (const task of tasks) {
    await cp(task.dir, path.join(tasksDir, task.id), {
      recursive: true,
      force: true
    });
  }
}

async function buildPackageManifest(bundleRoot, results, tasks, options) {
  const files = await collectPackageFileRecords(bundleRoot);
  const publicationProtocol = buildPublicationProtocolSummary(results);

  return {
    schemaVersion: 1,
    bundleType: "clasp-benchmark-results",
    filters: packageFilters(options),
    resultCount: results.length,
    taskIds: tasks.map((task) => task.id),
    tasks: tasks.map((task) => ({
      id: task.id,
      suite: task.suite,
      language: task.language,
      title: task.title,
      prompt: task.prompt,
      repo: task.repo,
      prepare: task.prepare,
      verify: task.verify
    })),
    results: results.map((result) => ({
      file: posixJoin("benchmarks", "results", result.fileName),
      taskId: result.taskId,
      harness: result.harness,
      model: result.model,
      language: result.language,
      notes: result.notes ?? "",
      finishedAt: result.finishedAt,
      verificationPassed: result.verification.passed
    })),
    reproducibility: {
      archiveFormat: "tar.gz",
      tarOptions: ["--sort=name", "--owner=0", "--group=0", "--numeric-owner", "--mtime=@0"],
      gzipOptions: ["-n"]
    },
    publicationProtocol,
    files
  };
}

function buildPublicationProtocolSummary(results) {
  const modes = [...new Set(results.map((result) => result.protocol?.mode).filter(Boolean))]
    .sort((left, right) => left.localeCompare(right));
  const repeatedSamples = results.reduce((max, result) =>
    Math.max(max, result.protocol?.repeatedSamples ?? 0), 0);
  const bundleManifests = [...new Set(
    results
      .map((result) => result.protocol?.bundle?.manifestFile)
      .filter((value) => typeof value === "string" && value.length > 0)
  )].sort((left, right) => left.localeCompare(right));
  const workflowAssistances = [...new Set(
    results
      .map((result) => result.protocol?.workflowAssistance)
      .filter((value) => typeof value === "string" && value.length > 0)
  )].sort((left, right) => left.localeCompare(right));
  const hasPhases = results.some((result) => result.phases && Object.keys(result.phases).length > 0);

  return {
    frozenBundles: bundleManifests,
    randomizedRunOrder: bundleManifests.length > 0,
    repeatedSamples,
    modes,
    workflowAssistances,
    phaseDecomposition: hasPhases
  };
}

function packageFilters(options) {
  const filters = {};
  const keys = ["taskId", "harness", "model", "language", "mode", "workflowAssistance", "notes"];

  for (const key of keys) {
    if (options[key]) {
      filters[key] = options[key];
    }
  }

  return filters;
}

async function collectPackageFileRecords(rootDir) {
  const entries = await collectFiles(rootDir);
  const records = [];

  for (const relativePath of entries) {
    const absolutePath = path.join(rootDir, relativePath);
    const content = await readFile(absolutePath);
    records.push({
      path: posixJoin(...relativePath.split(path.sep)),
      size: content.length,
      sha256: createHash("sha256").update(content).digest("hex")
    });
  }

  return records;
}

async function collectFrozenBundleFiles(tasks, mode) {
  const rootDir = path.resolve(".");
  const records = [];
  const staticFiles = [
    path.resolve("AGENTS.md"),
    path.join(benchmarkRoot, "README.md"),
    path.join(benchmarkRoot, "result-schema.json"),
    path.join(benchmarkRoot, "run-benchmark.mjs"),
    path.join(benchmarkRoot, "run-codex-harness.sh"),
    path.join(benchmarkRoot, "run-claude-harness.sh"),
    path.join(benchmarkRoot, "run-codex-series.sh"),
    path.join(benchmarkRoot, "run-claude-series.sh")
  ];

  for (const filePath of staticFiles) {
    if (await fileExists(filePath)) {
      records.push(await buildFileRecord(rootDir, filePath));
    }
  }

  for (const task of tasks) {
    const taskFiles = await collectFiles(task.dir);
    for (const relativePath of taskFiles) {
      const absolutePath = path.join(task.dir, relativePath);
      records.push(await buildFileRecord(rootDir, absolutePath));
    }

    const promptPath = await resolvePromptPath(task, mode);
    const promptRecordPath = path.relative(rootDir, promptPath);
    if (!records.some((record) => record.path === posixJoin(...promptRecordPath.split(path.sep)))) {
      records.push(await buildFileRecord(rootDir, promptPath));
    }
  }

  records.sort((left, right) => left.path.localeCompare(right.path));
  return records;
}

async function collectFiles(rootDir, relativeDir = "") {
  const directory = path.join(rootDir, relativeDir);
  const entries = await readdir(directory, { withFileTypes: true });
  const files = [];

  for (const entry of entries.sort((left, right) => left.name.localeCompare(right.name))) {
    const relativePath = path.join(relativeDir, entry.name);
    if (entry.isDirectory()) {
      files.push(...await collectFiles(rootDir, relativePath));
      continue;
    }

    if (entry.isFile()) {
      files.push(relativePath);
    }
  }

  return files;
}

async function buildFileRecord(rootDir, absolutePath) {
  const content = await readFile(absolutePath);
  return {
    path: posixJoin(...path.relative(rootDir, absolutePath).split(path.sep)),
    size: content.length,
    sha256: createHash("sha256").update(content).digest("hex")
  };
}

async function sha256File(filePath) {
  const content = await readFile(filePath);
  return createHash("sha256").update(content).digest("hex");
}

async function createDeterministicTarball(sourceDir, outputPath) {
  await mkdir(path.dirname(outputPath), { recursive: true });
  const gnuTarCommand = [
    "tar",
    "--sort=name",
    "--owner=0",
    "--group=0",
    "--numeric-owner",
    "--mtime=@0",
    "-cf",
    "-",
    "."
  ].join(" ");
  const portableTarCommand = [
    "LC_ALL=C",
    `find . -print | sort | tar --uid 0 --gid 0 --uname root --gname root --format pax --options gzip:!timestamp -czf ${shellQuote(outputPath)} -T -`
  ].join(" ");
  const command = [
    "set -euo pipefail",
    "find . -exec touch -h -t 197001010000 {} +",
    `if ${gnuTarCommand} >/dev/null 2>&1; then`,
    `  ${gnuTarCommand} | gzip -n > ${shellQuote(outputPath)}`,
    "else",
    `  ${portableTarCommand}`,
    "fi"
  ].join("\n");
  const result = await runProcess(["bash", "-lc", command], sourceDir);

  if (result.exitCode !== 0) {
    throw new Error(`failed to create benchmark package: ${outputPath}`);
  }
}

function posixJoin(...segments) {
  return segments.join("/");
}

const invokedAsScript =
  process.argv[1] !== undefined &&
  import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href;

if (invokedAsScript) {
  await main();
}

export {
  buildBenchmarkSuiteComparisons,
  loadResults,
  matchesSummaryFilter,
  publicAppBenchmark
};
