#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const projectRoot = path.resolve(path.join(path.dirname(fileURLToPath(import.meta.url)), ".."));
const captureBytes = parsePositiveInt(process.env.CLASP_VERIFY_AFFECTED_CAPTURE_BYTES, 8192);

function parsePositiveInt(value, fallback) {
  if (!value || !/^[0-9]+$/.test(value)) {
    return fallback;
  }
  const parsed = Number.parseInt(value, 10);
  return parsed > 0 ? parsed : fallback;
}

function usage() {
  return [
    "usage: scripts/verify-affected.sh [--changed-file PATH ...] [--files-from PATH ...] [--report-json PATH] [--plan-only]",
    "",
    "Inputs are accepted from repeated --changed-file, repeated --files-from,",
    "CLASP_VERIFY_CHANGED_FILES, or best-effort git diff fallback when explicit",
    "inputs are absent.",
  ].join("\n");
}

function splitEnvFiles(value) {
  if (!value) {
    return [];
  }
  const pieces = [];
  for (const chunk of String(value).split(/[\n\r,]+/)) {
    const trimmed = chunk.trim();
    if (!trimmed) {
      continue;
    }
    if (/\s/.test(trimmed)) {
      for (const part of trimmed.split(/\s+/)) {
        if (part.trim()) {
          pieces.push(part.trim());
        }
      }
    } else {
      pieces.push(trimmed);
    }
  }
  return pieces;
}

function splitFileList(value) {
  if (!value) {
    return [];
  }
  const separator = value.includes("\0") ? /\0/g : /\r?\n/g;
  return String(value)
    .split(separator)
    .map((entry) => entry.trim())
    .filter((entry) => entry.length > 0);
}

function normalizeChangedFile(rawValue) {
  if (rawValue === undefined || rawValue === null) {
    return null;
  }
  let value = String(rawValue).replace(/\0/g, "").trim();
  if (!value) {
    return null;
  }
  value = value.replace(/\\/g, "/");
  if (path.isAbsolute(value)) {
    const relative = path.relative(projectRoot, value).replace(/\\/g, "/");
    if (relative && relative !== "." && !relative.startsWith("../") && relative !== "..") {
      value = relative;
    }
  }
  value = value.replace(/^\.\//, "");
  const normalized = path.posix.normalize(value);
  if (!normalized || normalized === ".") {
    return null;
  }
  return normalized.replace(/^\.\//, "");
}

function uniqueNormalized(files) {
  const seen = new Set();
  const result = [];
  for (const file of files) {
    const normalized = normalizeChangedFile(file);
    if (!normalized || seen.has(normalized)) {
      continue;
    }
    seen.add(normalized);
    result.push(normalized);
  }
  return result;
}

function nowMs() {
  return Date.now();
}

function tailText(value) {
  if (!value) {
    return "";
  }
  if (value.length <= captureBytes) {
    return value;
  }
  return value.slice(value.length - captureBytes);
}

function shellQuote(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

function parseArgs(argv) {
  const changedFiles = [];
  const filesFrom = [];
  let reportJson = "";
  let planOnly = false;

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--help" || arg === "-h") {
      process.stdout.write(`${usage()}\n`);
      process.exit(0);
    }
    if (arg === "--plan-only") {
      planOnly = true;
      continue;
    }
    if (arg === "--changed-file") {
      index += 1;
      if (index >= argv.length) {
        throw new Error("--changed-file requires a path");
      }
      changedFiles.push(argv[index]);
      continue;
    }
    if (arg.startsWith("--changed-file=")) {
      changedFiles.push(arg.slice("--changed-file=".length));
      continue;
    }
    if (arg === "--files-from") {
      index += 1;
      if (index >= argv.length) {
        throw new Error("--files-from requires a path");
      }
      filesFrom.push(argv[index]);
      continue;
    }
    if (arg.startsWith("--files-from=")) {
      filesFrom.push(arg.slice("--files-from=".length));
      continue;
    }
    if (arg === "--report-json") {
      index += 1;
      if (index >= argv.length) {
        throw new Error("--report-json requires a path");
      }
      reportJson = argv[index];
      continue;
    }
    if (arg.startsWith("--report-json=")) {
      reportJson = arg.slice("--report-json=".length);
      continue;
    }
    throw new Error(`unknown argument: ${arg}`);
  }

  return { changedFiles, filesFrom, reportJson, planOnly };
}

function readFilesFrom(paths) {
  const sources = [];
  const files = [];
  for (const sourcePath of paths) {
    const resolvedPath = sourcePath === "-" ? "-" : path.resolve(projectRoot, sourcePath);
    const source = {
      kind: "files-from",
      path: sourcePath,
      status: "ok",
      count: 0,
    };
    try {
      const content =
        sourcePath === "-"
          ? fs.readFileSync(0, "utf8")
          : fs.readFileSync(resolvedPath, "utf8");
      const sourceFiles = splitFileList(content);
      source.count = sourceFiles.length;
      files.push(...sourceFiles);
    } catch (error) {
      source.status = "error";
      source.error = error instanceof Error ? error.message : String(error);
      sources.push(source);
      throw new Error(`failed to read --files-from ${sourcePath}: ${source.error}`);
    }
    sources.push(source);
  }
  return { sources, files };
}

function collectGitFallback() {
  const commands = [
    ["diff", "--name-only", "--relative"],
    ["diff", "--name-only", "--relative", "--cached"],
    ["ls-files", "--others", "--exclude-standard"],
  ];
  const files = [];
  const attempts = [];
  let anySucceeded = false;

  for (const args of commands) {
    const startedAtMs = nowMs();
    const result = spawnSync("git", ["-C", projectRoot, ...args], {
      encoding: "utf8",
      maxBuffer: 10 * 1024 * 1024,
    });
    const endedAtMs = nowMs();
    const exitStatus = result.status === null ? 127 : result.status;
    attempts.push({
      command: `git -C ${shellQuote(projectRoot)} ${args.map(shellQuote).join(" ")}`,
      exitStatus,
      elapsedMs: Math.max(0, endedAtMs - startedAtMs),
      stderrTail: tailText(result.stderr || ""),
    });
    if (exitStatus === 0) {
      anySucceeded = true;
      files.push(...splitFileList(result.stdout || ""));
    }
  }

  return {
    source: {
      kind: "git-diff",
      status: anySucceeded ? "ok" : "unavailable",
      count: files.length,
      attempts,
    },
    files,
    inputFallbackMode: anySucceeded ? (files.length > 0 ? "git-diff" : "git-empty") : "git-unavailable",
  };
}

const nativeIncrementalLimitedParallelEnv = [
  "CLASP_NATIVE_JOBS_MAX=2",
  "CLASP_NATIVE_BUNDLE_JOBS=2",
  "CLASP_NATIVE_IMAGE_SECTION_JOBS=2",
  "CLASP_NATIVE_IMAGE_SECTION_JOBS_MAX=2",
  "CLASP_NATIVE_IMAGE_MODULE_DECL_FRESH_PROCESS=1",
  "CLASP_NATIVE_IMAGE_MODULE_DECL_CHUNK_SIZE=8",
  "CLASP_NATIVE_EXPORT_HOST_IDLE_TIMEOUT_SECS=5",
].join(" ");

const COMMANDS = {
  verifyFast: "bash scripts/verify-fast.sh",
  selfhost: "bash scripts/test-selfhost.sh",
  sourceVerify: "bash src/scripts/verify.sh",
  nativeDiagnostics: "bash scripts/test-native-claspc-diagnostics.sh",
  nativeIncrementalGuard: "bash scripts/test-native-incremental-guard.sh",
  nativeIncrementalCli: "bash scripts/measure-native-incremental.sh --scenario native-cli-body-change --assert",
  nativeIncrementalSelfhost:
    `${nativeIncrementalLimitedParallelEnv} bash scripts/measure-native-incremental.sh --scenario selfhost-body-change --assert`,
  nativeIncrementalCompilerModule:
    `${nativeIncrementalLimitedParallelEnv} CLASP_NATIVE_INCREMENTAL_COMPILER_MODULE_IMAGE_PROBE=0 bash scripts/measure-native-incremental.sh --scenario selfhost-compiler-module-body-change --assert --max-duration compilerCheckBodyChange=10`,
  intBuiltins: "bash scripts/test-int-builtins.sh",
  dictBuiltins: "bash scripts/test-dict-builtins.sh",
  tryDecode: "bash scripts/test-try-decode.sh",
  modelBoundary: "bash scripts/test-model-boundary.sh",
  serviceDecode: "bash scripts/test-service-decode.sh",
  nativeClaspc: "bash scripts/test-native-claspc.sh",
  nativeRuntime: "bash scripts/test-native-runtime.sh",
  swarmReady: "bash scripts/test-swarm-ready-gate.sh",
  standaloneSwarmSurfaces: "bash scripts/test-standalone-swarm-surfaces.sh",
  swarmReadyBenchmark: "CLASP_SWARM_READY_BENCHMARK_TIMEOUT_SECS=700 bash scripts/test-swarm-ready-benchmark.sh",
  swarmCapabilityAudit: "bash scripts/test-swarm-capability-audit.sh",
  swarmPolicyHelpers: "bash scripts/test-swarm-policy-helpers.sh",
  swarmDestructivePolicy: "bash scripts/test-swarm-destructive-policy.sh",
  swarmFilesystemKernelPolicy: "bash scripts/test-swarm-filesystem-kernel-policy.sh",
  swarmMemory: "bash scripts/test-swarm-memory.sh",
  swarmPriority: "bash scripts/test-swarm-priority.sh",
  swarmSpawnPolicy: "bash scripts/test-swarm-spawn-policy.sh",
  swarmContextPack: "bash scripts/test-swarm-context-pack.sh",
  swarmSemanticSummaryIndex: "bash scripts/test-swarm-semantic-summary-index.sh",
  swarmPreflight: "bash scripts/test-swarm-preflight.sh",
  swarmNativeSupervisor: "bash scripts/test-swarm-native-supervisor.sh",
  taskManifest: "bash scripts/test-task-manifest.sh",
  swarmControl: "bash scripts/test-swarm-control.sh",
  localSourceEditWorkspace: "bash scripts/test-local-source-edit-workspace.sh",
  localAgentCapabilityClosure: "bash scripts/test-local-agent-capability-closure.sh static",
  agentCommandTemplate: "bash scripts/test-agent-command-template.sh",
  agentBackendStatic: "bash scripts/test-agent-backend-static.sh",
  agentErgonomics: "bash scripts/test-agent-ergonomics-helpers.sh static",
  monitoredLoop: "bash scripts/test-monitored-loop.sh",
  monitoredStep: "bash scripts/test-monitored-step.sh",
  monitoredRunLog: "bash scripts/test-monitored-run-log.sh",
  monitoredWorkflow: "bash scripts/test-monitored-workflow.sh",
  codexLoopProgram: "bash scripts/test-codex-loop-program.sh",
  hostRuntime: "bash scripts/test-host-runtime.sh",
  resourceGuardPolicy: "bash scripts/test-resource-guard-policy.sh",
  resourceRecoveryPolicy: "bash scripts/test-resource-recovery-policy.sh static",
  goalManagerResourceHealth: "bash scripts/test-goal-manager-resource-health.sh static",
  goalManagerGeneratedCleanupHealth: "bash scripts/test-goal-manager-generated-cleanup-health.sh static",
  agentLoopScenario: "bash examples/agent-loop-scenario/scripts/verify.sh",
  safeWorkspace: "bash scripts/test-safe-workspace.sh",
  safeWorkspaceStatic: "bash scripts/test-safe-workspace-static.sh",
  safeSubprocess: "bash scripts/test-safe-subprocess.sh",
  managedJob: "bash scripts/test-managed-job.sh",
  resolveClaspc: "bash scripts/test-resolve-claspc.sh",
  generatedStateCleanup: "bash scripts/test-generated-state-cleanup.sh",
  generatedStateCleanupPlanStatic: "bash scripts/test-generated-state-cleanup-plan-static.sh",
  generatedStateCleanupPlan: "bash scripts/test-generated-state-cleanup-plan.sh",
  runtimeSliceProcess: "bash scripts/verify-runtime-slice.sh process",
  runtimeSliceWorkflow: "bash scripts/verify-runtime-slice.sh workflow",
  runtimeSliceCodexLoop: "bash scripts/verify-runtime-slice.sh codex-loop",
  runtimeSliceWorkspace: "bash scripts/verify-runtime-slice.sh workspace",
  runtimeSliceManagedLoop: "bash scripts/verify-runtime-slice.sh managed-loop",
  runtimeSliceSwarmFeedbackLoop:
    "CLASP_RUNTIME_SLICE_TIMEOUT_SECS=700 CLASP_SWARM_FEEDBACK_LOOP_TIMEOUT_SECS=700 bash scripts/verify-runtime-slice.sh swarm-feedback-loop",
  goalManagerFast: "CLASP_GOAL_MANAGER_FAST_CACHE_PROBE_ONLY=1 bash scripts/test-goal-manager-fast.sh",
  goalManagerAgentCommandTemplate: "bash scripts/test-goal-manager-agent-command-template.sh",
  goalManagerDefaultPlannerCommand: "bash scripts/test-goal-manager-default-planner-command.sh",
  goalManagerPlannerReportDecode: "bash scripts/test-goal-manager-planner-report-decode.sh",
  goalManagerMailboxCapabilityDetails: "bash scripts/test-goal-manager-mailbox-capability-details.sh",
  feedbackLoopRouting: "bash scripts/test-feedback-loop-routing.sh",
  feedbackLoopRoutingLoop: "bash scripts/test-feedback-loop-routing.sh loop-routing",
  feedbackResumeSmoke: "bash scripts/test-feedback-loop-resume.sh smoke",
  verifyAllSmoke: "bash scripts/test-verify-all-smoke.sh",
  verifyAllRegression: "bash scripts/test-verify-all.sh",
  verifyAffectedRegression: "bash scripts/test-verify-affected.sh",
  compilerSliceRegression: "bash scripts/test-verify-compiler-slice.sh",
  selfhostVerifyModeSplit: "bash scripts/test-selfhost-verify-mode-split.sh",
  jsEmitterDeterminism: "bash scripts/test-js-emitter-determinism.sh",
  recordUpdateParity: "bash scripts/test-record-update-parity.sh",
  runtimeSliceRegression: "bash scripts/test-verify-runtime-slice.sh",
  promotedSourceExportCacheRegression: "bash scripts/test-promoted-source-export-cache.sh",
  promotedSourceExportCacheNodeCheck: "node --check scripts/generate-promoted-source-export-cache.mjs",
  promotedModuleSummaryCacheRegression: "bash scripts/test-promoted-module-summary-cache.sh",
  promotedModuleSummaryCacheNodeCheck: "node --check scripts/generate-promoted-module-summary-cache.mjs",
  benchmarkCheckpointNodeCheck: "node --check scripts/benchmark-checkpoint.mjs",
  benchmarkCheckpointRegression: "bash scripts/test-benchmark-checkpoint.sh",
  runBenchmarkNodeCheck: "node --check benchmarks/run-benchmark.mjs",
  benchmarkPrepCacheRegression: "bash benchmarks/test-benchmark-prep-cache.sh",
  benchmarkTaskPrep: "bash benchmarks/test-task-prep.sh",
  affectedNodeCheck: "node --check scripts/verify-affected.mjs",
};

const contextArtifactLimitPerFile = parsePositiveInt(process.env.CLASP_VERIFY_AFFECTED_CONTEXT_ARTIFACT_LIMIT, 4);
const planSurfaceLimit = parsePositiveInt(process.env.CLASP_VERIFY_AFFECTED_PLAN_SURFACE_LIMIT, 12);
const plannerReportDecodeFiles = new Set([
  "examples/swarm-native/GoalManager.clasp",
  "examples/swarm-native/GoalManager.scratch.clasp",
  "examples/swarm-native/GoalManagerBenchmarkCheckpoint.clasp",
  "examples/swarm-native/GoalManagerBenchmarkCommand.clasp",
  "examples/swarm-native/GoalManagerBenchmarkRuntime.clasp",
  "examples/swarm-native/GoalManagerMailboxIO.clasp",
  "examples/swarm-native/GoalManagerPlannerIO.clasp",
  "examples/swarm-native/GoalManagerPreludeDecode.clasp",
  "examples/swarm-native/GoalManagerReportIO.clasp",
  "examples/swarm-native/GoalManagerRuntime.clasp",
  "examples/swarm-native/GoalManagerWatch.clasp",
  "examples/swarm-native/PlannerReportDecodeHarness.clasp",
  "scripts/test-goal-manager-planner-report-decode.sh",
]);
const retiredGoalManagerProgramFiles = new Set([
  "examples/swarm-native/GoalManagerProgram.clasp",
  "examples/swarm-native/GoalManagerProgram2.clasp",
]);
const focusedPlannerReportDecodeFiles = new Set(
  [...plannerReportDecodeFiles].filter(
    (file) => file.startsWith("examples/swarm-native/") && file !== "examples/swarm-native/GoalManager.clasp",
  ),
);
const ignoredChangedFiles = new Set([
  ".workspace-ready",
  ".clasp-agents",
  ".clasp-loops",
  ".clasp-manager-workspace-ready",
  ".clasp-manager-workspace-manifest.json",
  ".clasp-managed-job-admission.lock",
  ".clasp-swarm",
  ".clasp-task-baselines",
  ".clasp-task-workspaces",
  ".clasp-test-tmp",
  ".clasp-verify",
  ".clasp-verify-tmp",
  "runtime/.clasp-test-tmp",
  "runtime/target",
  "src/native-verify-cache",
]);
const ignoredChangedFilePrefixes = [
  ".clasp-agents/",
  ".clasp-loops/",
  ".clasp-swarm/",
  ".clasp-task-baselines/",
  ".clasp-task-workspaces/",
  ".clasp-test-tmp/",
  ".clasp-verify/",
  ".clasp-verify-tmp/",
  "benchmarks/results/",
  "benchmarks/workspaces/",
  "runtime/.clasp-test-tmp/",
  "runtime/target/",
  "src/native-verify-cache/",
];
const hostRuntimeDocFiles = new Set([
  "docs/autonomous-swarm-build-plan.md",
  "docs/clasp-spec-v0.md",
]);
const swarmTaskManifestFiles = new Set([
  "agents/swarm/task.schema.json",
  "agents/swarm/task-template.md",
  "scripts/clasp-swarm-validate-task.mjs",
  "scripts/test-task-manifest.sh",
]);
const swarmControlScriptFiles = new Set([
  "scripts/clasp-builder.sh",
  "scripts/clasp-swarm-common.sh",
  "scripts/clasp-swarm-lane.sh",
  "scripts/clasp-swarm-start.sh",
  "scripts/clasp-swarm-status.sh",
  "scripts/clasp-swarm-supervise.sh",
  "scripts/clasp-verifier.sh",
  "scripts/test-swarm-control.sh",
]);
const swarmNativeSupervisorScriptFiles = new Set([
  "scripts/clasp-swarm-supervise.sh",
  "scripts/test-swarm-native-supervisor.sh",
]);
const swarmPreflightScriptFiles = new Set([
  "scripts/clasp-swarm-preflight.sh",
  "scripts/test-swarm-preflight.sh",
]);

function isIgnoredChangedFile(file) {
  return ignoredChangedFiles.has(file) || ignoredChangedFilePrefixes.some((prefix) => file.startsWith(prefix));
}

function fileExists(relativePath) {
  try {
    return fs.existsSync(path.resolve(projectRoot, relativePath));
  } catch (_error) {
    return false;
  }
}

function readDirIfExists(absolutePath) {
  try {
    return fs.readdirSync(absolutePath, { withFileTypes: true });
  } catch (_error) {
    return [];
  }
}

function withinProjectRoot(absolutePath) {
  const relative = path.relative(projectRoot, absolutePath);
  return relative === "" || (!relative.startsWith("..") && !path.isAbsolute(relative));
}

function addUnique(values, value) {
  if (typeof value !== "string" || value.length === 0 || values.includes(value)) {
    return;
  }
  values.push(value);
}

function addManyUnique(values, additions) {
  if (!Array.isArray(additions)) {
    return;
  }
  for (const addition of additions) {
    addUnique(values, addition);
  }
}

function truncateList(values, limit = planSurfaceLimit) {
  const safeValues = Array.isArray(values) ? values : [];
  if (safeValues.length <= limit) {
    return safeValues;
  }
  return [...safeValues.slice(0, limit), `...${safeValues.length - limit} more`];
}

function isClaspSourceFile(file) {
  return file.endsWith(".clasp");
}

function exampleVerifyCommandForFile(file) {
  const match = /^examples\/([^/]+)\//.exec(file);
  if (!match) {
    return null;
  }
  const scriptPath = `examples/${match[1]}/scripts/verify.sh`;
  return fileExists(scriptPath) ? `bash ${scriptPath}` : null;
}

function exampleVerifyScriptCommandForFile(file) {
  const match = /^examples\/([^/]+)\/scripts\/verify\.sh$/.exec(file);
  if (!match) {
    return null;
  }
  return `bash examples/${match[1]}/scripts/verify.sh`;
}

function benchmarkTaskRepoMatch(file) {
  const match = /^benchmarks\/tasks\/([^/]+)\/repo\/(.+)/.exec(file);
  if (!match) {
    return null;
  }
  return {
    taskId: match[1],
    repoPath: match[2],
  };
}

function benchmarkTaskMetadata(taskId) {
  const taskPath = path.resolve(projectRoot, "benchmarks", "tasks", taskId, "task.json");
  try {
    return JSON.parse(fs.readFileSync(taskPath, "utf8"));
  } catch (_error) {
    return null;
  }
}

function benchmarkTaskVerifyCommand(taskId) {
  const scriptPath = `benchmarks/tasks/${taskId}/repo/scripts/verify.sh`;
  return fileExists(scriptPath) ? `CLASP_PROJECT_ROOT=$PWD bash ${scriptPath}` : null;
}

function isBenchmarkCheckpointFile(file) {
  return (
    file === "scripts/benchmark-checkpoint.mjs" ||
    file === "scripts/test-benchmark-checkpoint.sh" ||
    /^benchmarks\/checkpoints\/[^/]+\.json$/.test(file)
  );
}

function isBenchmarkPrepCacheFile(file) {
  return file === "benchmarks/run-benchmark.mjs" || file === "benchmarks/test-benchmark-prep-cache.sh";
}

function isPromotedSourceExportCacheFile(file) {
  return (
    file === "scripts/generate-promoted-source-export-cache.mjs" ||
    file === "scripts/test-promoted-source-export-cache.sh" ||
    file === "src/stage1.compiler.source-export-cache-v1.json" ||
    file === "src/stage1.promoted-project.native.image.json"
  );
}

function isPromotedModuleSummaryCacheFile(file) {
  return (
    file === "scripts/generate-promoted-module-summary-cache.mjs" ||
    file === "scripts/test-promoted-module-summary-cache.sh" ||
    file === "src/stage1.compiler.module-summary-cache-v2.json" ||
    file === "src/stage1.compiler.native.image.json"
  );
}

function isAgentFeedbackJsonFile(file) {
  return /^agents\/feedback\/[^/]+\.json$/.test(file);
}

function contextArtifactCandidatesForFile(file) {
  const candidates = [];
  if (file.endsWith(".context.json")) {
    addUnique(candidates, file);
  }

  const absoluteFile = path.resolve(projectRoot, file);
  let currentDir = path.dirname(absoluteFile);
  const visited = new Set();

  while (withinProjectRoot(currentDir) && !visited.has(currentDir)) {
    visited.add(currentDir);
    for (const candidateDir of [currentDir, path.join(currentDir, "benchmark-prep")]) {
      for (const entry of readDirIfExists(candidateDir)) {
        if (!entry.isFile() || !entry.name.endsWith(".context.json")) {
          continue;
        }
        const relative = path.relative(projectRoot, path.join(candidateDir, entry.name)).replace(/\\/g, "/");
        addUnique(candidates, relative);
      }
    }
    if (currentDir === projectRoot) {
      break;
    }
    currentDir = path.dirname(currentDir);
  }

  return candidates.slice(0, contextArtifactLimitPerFile);
}

function textAttr(attrs, name) {
  const attr = Array.isArray(attrs) ? attrs.find((entry) => entry?.name === name) : null;
  return typeof attr?.value === "string" ? attr.value : "";
}

function collectContextSurfaces(graph) {
  const routes = [];
  const schemas = [];
  const declarations = [];
  const foreignBoundaries = [];
  const workflows = [];
  const tools = [];

  for (const route of graph?.surfaceIndex?.routes ?? []) {
    addUnique(routes, route.id || (route.name ? `route:${route.name}` : ""));
    addUnique(schemas, route.requestSchemaId || "");
    addUnique(schemas, route.responseSchemaId || "");
    addUnique(declarations, route.handlerId || "");
    addManyUnique(routes, route.affectedRoutes);
    addManyUnique(schemas, route.affectedSchemas);
    addManyUnique(declarations, route.affectedDeclarations);
    addManyUnique(foreignBoundaries, route.affectedForeignBoundaries);
    addManyUnique(routes, (route.affectedSurfaces || []).filter((surface) => surface.startsWith("route:")));
    addManyUnique(schemas, (route.affectedSurfaces || []).filter((surface) => surface.startsWith("schema:")));
    addManyUnique(declarations, (route.affectedSurfaces || []).filter((surface) => surface.startsWith("decl:")));
    addManyUnique(foreignBoundaries, (route.affectedSurfaces || []).filter((surface) => surface.startsWith("foreign:")));
  }

  for (const workflow of graph?.surfaceIndex?.workflows ?? []) {
    addUnique(workflows, workflow.id || (workflow.name ? `workflow:${workflow.name}` : ""));
  }
  for (const tool of graph?.surfaceIndex?.tools ?? []) {
    addUnique(tools, tool.id || (tool.name ? `tool:${tool.name}` : ""));
  }
  for (const foreign of graph?.surfaceIndex?.foreignBoundaries ?? []) {
    addUnique(foreignBoundaries, foreign.id || (foreign.name ? `foreign:${foreign.name}` : ""));
  }

  for (const node of graph?.nodes ?? []) {
    if (typeof node?.id !== "string") {
      continue;
    }
    switch (node.kind) {
      case "route":
        addUnique(routes, node.id);
        break;
      case "schema":
      case "record":
        addUnique(schemas, node.id.startsWith("schema:") ? node.id : `schema:${textAttr(node.attrs, "name") || node.id}`);
        break;
      case "decl":
        addUnique(declarations, node.id);
        break;
      case "foreign":
        addUnique(foreignBoundaries, node.id);
        break;
      case "workflow":
        addUnique(workflows, node.id);
        break;
      case "tool":
        addUnique(tools, node.id);
        break;
      default:
        break;
    }
  }

  return {
    routes,
    schemas,
    declarations,
    foreignBoundaries,
    workflows,
    tools,
  };
}

function collectContextScenarioCommands(graph) {
  const commands = [];
  addManyUnique(commands, graph?.verificationGuidance?.scenarioCommands);
  for (const route of graph?.surfaceIndex?.routes ?? []) {
    addManyUnique(commands, route?.verificationGuidance?.scenarioCommands);
  }
  return commands.filter((command) => typeof command === "string" && !command.includes("<") && !command.includes("verify-all.sh"));
}

function summarizeContextArtifact(relativePath) {
  const absolutePath = path.resolve(projectRoot, relativePath);
  try {
    const graph = JSON.parse(fs.readFileSync(absolutePath, "utf8"));
    return {
      path: relativePath,
      status: "ok",
      format: typeof graph.format === "string" ? graph.format : "unknown",
      module: typeof graph.module === "string" ? graph.module : "",
      entry: typeof graph.entry === "string" ? path.relative(projectRoot, graph.entry).replace(/\\/g, "/") : "",
      sourceModules: Array.isArray(graph.sourceModules)
        ? graph.sourceModules
            .map((entry) => ({
              moduleName: entry.moduleName || "",
              role: entry.role || "",
              sourceId: entry.sourceId || "",
              moduleId: entry.moduleId || "",
              sourceFingerprint: entry.sourceFingerprint || "",
            }))
            .filter((entry) => entry.moduleName || entry.sourceId || entry.moduleId)
        : [],
      surfaces: collectContextSurfaces(graph),
      scenarioCommands: collectContextScenarioCommands(graph),
    };
  } catch (error) {
    return {
      path: relativePath,
      status: "error",
      error: error instanceof Error ? error.message : String(error),
      format: "unknown",
      sourceModules: [],
      surfaces: {
        routes: [],
        schemas: [],
        declarations: [],
        foreignBoundaries: [],
        workflows: [],
        tools: [],
      },
      scenarioCommands: [],
    };
  }
}

function collectSemanticContexts(changedFiles) {
  const artifactByPath = new Map();
  const byChangedFile = [];

  for (const file of changedFiles) {
    const artifactPaths = contextArtifactCandidatesForFile(file);
    for (const artifactPath of artifactPaths) {
      if (!artifactByPath.has(artifactPath)) {
        artifactByPath.set(artifactPath, summarizeContextArtifact(artifactPath));
      }
    }
    byChangedFile.push({
      file,
      artifactPaths,
    });
  }

  return {
    artifacts: Array.from(artifactByPath.values()),
    byChangedFile,
  };
}

function surfacesFromArtifacts(semanticContexts, artifactPaths) {
  const result = {
    routes: [],
    schemas: [],
    declarations: [],
    foreignBoundaries: [],
    workflows: [],
    tools: [],
  };
  const artifactsByPath = new Map(semanticContexts.artifacts.map((artifact) => [artifact.path, artifact]));
  for (const artifactPath of artifactPaths) {
    const artifact = artifactsByPath.get(artifactPath);
    if (!artifact || artifact.status !== "ok") {
      continue;
    }
    addManyUnique(result.routes, artifact.surfaces.routes);
    addManyUnique(result.schemas, artifact.surfaces.schemas);
    addManyUnique(result.declarations, artifact.surfaces.declarations);
    addManyUnique(result.foreignBoundaries, artifact.surfaces.foreignBoundaries);
    addManyUnique(result.workflows, artifact.surfaces.workflows);
    addManyUnique(result.tools, artifact.surfaces.tools);
  }
  return result;
}

function surfaceText(surfaces) {
  const parts = [];
  for (const [label, values] of [
    ["routes", surfaces.routes],
    ["schemas", surfaces.schemas],
    ["declarations", surfaces.declarations],
    ["foreign boundaries", surfaces.foreignBoundaries],
    ["workflows", surfaces.workflows],
    ["tools", surfaces.tools],
  ]) {
    if (values.length > 0) {
      parts.push(`${label}: ${truncateList(values).join(", ")}`);
    }
  }
  return parts.length > 0 ? parts.join("; ") : "no named surfaces found";
}

function buildPlanExplanations(changedFiles, routePlan, semanticContexts) {
  const commandByFile = new Map();
  for (const selectedCommand of routePlan.selectedCommands) {
    for (const file of selectedCommand.matchedFiles) {
      if (!commandByFile.has(file)) {
        commandByFile.set(file, []);
      }
      addUnique(commandByFile.get(file), selectedCommand.command);
    }
  }

  return semanticContexts.byChangedFile
    .filter((entry) => entry.artifactPaths.length > 0)
    .map((entry) => {
      const surfaces = surfacesFromArtifacts(semanticContexts, entry.artifactPaths);
      const artifactText = entry.artifactPaths.join(", ");
      return {
        kind: "semantic-context",
        file: entry.file,
        artifacts: entry.artifactPaths,
        surfaces,
        selectedCommands: commandByFile.get(entry.file) || [],
        explanation: `Context artifact ${artifactText} identifies semantic surfaces for ${entry.file}: ${surfaceText(surfaces)}.`,
      };
    });
}

function commandUsesExplicitStaticMode(command) {
  return /(^|\s)bash\s+[^;&|]+\.sh\s+static($|\s)/.test(command);
}

function commandUsesStaticHarnessName(command) {
  return /(^|\s)bash\s+['"]?[^;&|'" ]*-static\.sh['"]?($|\s)/.test(command);
}

function commandUsesCacheProbeOnlyMode(command) {
  return /(^|\s)CLASP_[A-Z0-9_]*CACHE_PROBE_ONLY=1\s+bash\s+[^;&|]+\.sh($|\s)/.test(command);
}

function commandUsesVerifierSmokeHarness(command) {
  return /(^|\s)bash\s+scripts\/test-verify-all-smoke\.sh($|\s)/.test(command);
}

function commandStaticProfile(compilerStateAccess = "none") {
  return {
    resourceClass: "static",
    oomRisk: "low",
    requiresManagedGuard: false,
    executionAdvice: "safe-direct",
    compilerStateAccess,
  };
}

function commandResourceProfile(id, command) {
  if (commandUsesCacheProbeOnlyMode(command)) {
    return commandStaticProfile("temporary-cache-probe");
  }

  if (
    command.startsWith("bash -n ") ||
    command.startsWith("node --check ") ||
    command.startsWith("cc -fsyntax-only ") ||
    commandUsesExplicitStaticMode(command) ||
    commandUsesStaticHarnessName(command) ||
    commandUsesVerifierSmokeHarness(command) ||
    command === COMMANDS.swarmReady ||
    command === COMMANDS.swarmCapabilityAudit ||
    command === COMMANDS.swarmPreflight ||
    command === COMMANDS.resourceGuardPolicy
  ) {
    return commandStaticProfile("none");
  }

  if (
    command.includes("verify-all.sh") ||
    command.includes("test-selfhost.sh") ||
    command.includes("src/scripts/verify.sh") ||
    command.includes("test-native-claspc.sh") ||
    command.includes("measure-native-incremental.sh") ||
    command.includes("test-swarm-ready-benchmark.sh") ||
    command.includes("promote-selfhost") ||
    id.includes("native-claspc") ||
    id.includes("selfhost")
  ) {
    return {
      resourceClass: "heavy",
      oomRisk: "guarded",
      requiresManagedGuard: true,
      executionAdvice: "run-under-managed-job-with-memory-and-disk-admission",
      compilerStateAccess: "compiler-build-or-cache",
    };
  }

  if (
    command.includes("verify-runtime-slice.sh") ||
    command.includes("test-swarm-memory.sh") ||
    command.includes("test-swarm-context-pack.sh") ||
    command.includes("test-swarm-policy-helpers.sh") ||
    command.includes("test-swarm-destructive-policy.sh") ||
    command.includes("test-swarm-filesystem-kernel-policy.sh") ||
    command.includes("test-swarm-priority.sh") ||
    command.includes("test-swarm-spawn-policy.sh") ||
    command.includes("test-goal-manager") ||
    command.includes("test-verify-affected.sh") ||
    command.includes("test-verify-all.sh")
  ) {
    return {
      resourceClass: "focused",
      oomRisk: "guarded",
      requiresManagedGuard: true,
      executionAdvice: "prefer-managed-job-for-agent-runs",
      compilerStateAccess: "possible-compiler-or-runtime-state",
    };
  }

  return {
    resourceClass: "focused",
    oomRisk: "moderate",
    requiresManagedGuard: true,
    executionAdvice: "prefer-managed-job-for-agent-runs",
    compilerStateAccess: "unknown",
  };
}

function addSelected(selectedByCommand, id, command, reason, file) {
  if (!selectedByCommand.has(command)) {
    const profile = commandResourceProfile(id, command);
    selectedByCommand.set(command, {
      id,
      command,
      resourceClass: profile.resourceClass,
      oomRisk: profile.oomRisk,
      requiresManagedGuard: profile.requiresManagedGuard,
      executionAdvice: profile.executionAdvice,
      compilerStateAccess: profile.compilerStateAccess,
      reasons: [],
      matchedFiles: [],
    });
  }
  const selected = selectedByCommand.get(command);
  if (!selected.reasons.includes(reason)) {
    selected.reasons.push(reason);
  }
  if (file && !selected.matchedFiles.includes(file)) {
    selected.matchedFiles.push(file);
  }
}

function buildCommandResourceSummary(selectedCommands) {
  const byResourceClass = {};
  const byOomRisk = {};
  let requiresManagedGuard = false;
  let staticCommandCount = 0;
  let focusedCommandCount = 0;
  let heavyCommandCount = 0;
  let safeDirectCommandCount = 0;
  let managedGuardCommandCount = 0;
  let compilerStateFreeCommandCount = 0;
  let compilerStateTouchingCommandCount = 0;

  for (const selectedCommand of selectedCommands) {
    const resourceClass = selectedCommand.resourceClass || "unknown";
    const oomRisk = selectedCommand.oomRisk || "unknown";
    const compilerStateAccess = selectedCommand.compilerStateAccess || "unknown";
    byResourceClass[resourceClass] = (byResourceClass[resourceClass] || 0) + 1;
    byOomRisk[oomRisk] = (byOomRisk[oomRisk] || 0) + 1;
    if (resourceClass === "static") {
      staticCommandCount += 1;
    }
    if (resourceClass === "focused") {
      focusedCommandCount += 1;
    }
    if (resourceClass === "heavy") {
      heavyCommandCount += 1;
    }
    if (selectedCommand.requiresManagedGuard) {
      requiresManagedGuard = true;
      managedGuardCommandCount += 1;
    } else {
      safeDirectCommandCount += 1;
    }
    if (compilerStateAccess === "none") {
      compilerStateFreeCommandCount += 1;
    } else {
      compilerStateTouchingCommandCount += 1;
    }
  }

  let overallAdvice = "safe-direct";
  if (heavyCommandCount > 0) {
    overallAdvice = "run-under-managed-job-with-memory-and-disk-admission";
  } else if (requiresManagedGuard) {
    overallAdvice = "prefer-managed-job-for-agent-runs";
  }

  return {
    commandCount: selectedCommands.length,
    staticCommandCount,
    focusedCommandCount,
    heavyCommandCount,
    safeDirectCommandCount,
    managedGuardCommandCount,
    compilerStateFreeCommandCount,
    compilerStateTouchingCommandCount,
    canRunWithoutCompilerState: compilerStateTouchingCommandCount === 0,
    requiresManagedGuard,
    byResourceClass,
    byOomRisk,
    overallAdvice,
  };
}

function affectedVerificationPlanRecommendation(summary) {
  if (summary.commandCount === 0) {
    return "affected-verification-plan:repair-plan-json";
  }
  if (summary.heavyCommandCount > 0) {
    return "affected-verification-plan:run-managed-memory-disk-admission";
  }
  if (summary.requiresManagedGuard) {
    return "affected-verification-plan:run-managed-focused";
  }
  if (summary.canRunWithoutCompilerState) {
    return "affected-verification-plan:safe-direct-compiler-state-free";
  }
  return "affected-verification-plan:safe-direct-compiler-state-access";
}

function affectedVerificationLaunchMode(summary) {
  if (summary.commandCount === 0) {
    return "invalid-plan";
  }
  if (summary.heavyCommandCount > 0) {
    return "heavy-managed";
  }
  if (summary.requiresManagedGuard) {
    return "focused-managed";
  }
  if (summary.canRunWithoutCompilerState) {
    return "direct-compiler-state-free";
  }
  return "direct-compiler-state-access";
}

function affectedVerificationLaunchRecommendation(mode) {
  switch (mode) {
    case "direct-compiler-state-free":
      return "affected-verification-launch:direct-compiler-state-free";
    case "direct-compiler-state-access":
      return "affected-verification-launch:direct-compiler-state-access-preflight";
    case "heavy-managed":
      return "affected-verification-launch:managed-heavy-memory-disk";
    case "focused-managed":
      return "affected-verification-launch:managed-focused";
    default:
      return "affected-verification-launch:repair-plan-json";
  }
}

function affectedVerificationLaunchBlockingGaps(mode) {
  switch (mode) {
    case "direct-compiler-state-free":
      return [];
    case "direct-compiler-state-access":
      return ["affected verifier plan touches compiler/cache state before launch"];
    case "heavy-managed":
      return ["affected verifier plan requires managed memory/disk admission before launch"];
    case "focused-managed":
      return ["affected verifier plan requires managed guard before launch"];
    default:
      return ["affected verifier plan has no selected commands"];
  }
}

function buildAffectedVerificationLaunchPolicy(summary) {
  const mode = affectedVerificationLaunchMode(summary);
  const valid = summary.commandCount > 0;
  const canRunDirect = valid && !summary.requiresManagedGuard && summary.heavyCommandCount === 0;
  const ready = canRunDirect && summary.canRunWithoutCompilerState;
  const recommendation = affectedVerificationLaunchRecommendation(mode);
  const verificationPlanRecommendation = affectedVerificationPlanRecommendation(summary);
  return {
    valid,
    ready,
    mode,
    canRunDirect,
    canRunWithoutCompilerState: summary.canRunWithoutCompilerState,
    requiresManagedGuard: summary.requiresManagedGuard,
    recommendation,
    verificationPlanRecommendation,
    blockingGaps: affectedVerificationLaunchBlockingGaps(mode),
    requiredClosure: ready ? [] : [verificationPlanRecommendation],
    evidence: [
      `affected-launch-mode=${mode}`,
      `affected-launch-ready=${ready ? "true" : "false"}`,
      `affected-launch-can-run-direct=${canRunDirect ? "true" : "false"}`,
      `affected-launch-can-run-without-compiler-state=${summary.canRunWithoutCompilerState ? "true" : "false"}`,
      `affected-launch-requires-managed=${summary.requiresManagedGuard ? "true" : "false"}`,
      `affected-launch-recommendation=${recommendation}`,
    ],
  };
}

function isVerificationScript(file) {
  if (file === "src/scripts/verify.sh") {
    return true;
  }
  if (!file.startsWith("scripts/")) {
    return false;
  }
  const basename = path.posix.basename(file);
  return (
    /^verify-.*\.sh$/.test(basename) ||
    /^verify-.*\.mjs$/.test(basename) ||
    /^test-verify-.*\.sh$/.test(basename) ||
    basename === "verify-all.sh" ||
    basename === "verify-fast.sh" ||
    basename === "verify-selfhost.sh"
  );
}

function compilerSliceForFile(file) {
  switch (file) {
    case "examples/compiler-parser.clasp":
      return "parser";
    case "examples/compiler-checker.clasp":
      return "checker";
    case "examples/compiler-lower.clasp":
      return "lower";
    case "examples/compiler-emitter.clasp":
      return "emitter";
    case "examples/compiler-ergonomics.clasp":
      return "ergonomics";
    case "src/Compiler/Checker.clasp":
      return "checker";
    case "src/Compiler/Lower.clasp":
      return "lower";
    case "src/Compiler/Emit/JavaScript.clasp":
    case "src/Compiler/Emit/Native.clasp":
    case "src/Compiler/Emit/NativeDecls.clasp":
    case "src/Compiler/Emit/NativeJson.clasp":
    case "src/Compiler/Emit/NativeMetadata.clasp":
    case "src/Compiler/Emit/NativeSurface.clasp":
      return "emitter";
    default:
      return "";
  }
}

function compilerSliceCommandForFile(file, slice) {
  if (file.startsWith("src/Compiler/")) {
    return `bash scripts/verify-compiler-slice.sh --check-only ${slice}`;
  }
  return `bash scripts/verify-compiler-slice.sh ${slice}`;
}

function compilerSliceDetailForFile(file, slice) {
  if (file.startsWith("src/Compiler/")) {
    return `compiler ${slice} implementation uses focused check-only coverage; source verification keeps broader compiler execution coverage`;
  }
  return `compiler ${slice} fixture uses focused check/run coverage`;
}

function routeChangedFiles(changedFiles, inputFallbackMode) {
  const selectedByCommand = new Map();
  const routingReasons = [];
  const unmatchedFiles = [];

  function reason(file, route, detail) {
    routingReasons.push({ file, route, detail });
  }

  for (const file of changedFiles) {
    let matched = false;
    const isCompilerSliceVerificationScript =
      file === "scripts/verify-compiler-slice.sh" || file === "scripts/test-verify-compiler-slice.sh";
    const isRuntimeSliceVerificationScript =
      file === "scripts/verify-runtime-slice.sh" || file === "scripts/test-verify-runtime-slice.sh";
    const isManagedJobSafetyPath =
      file === "scripts/run-managed-job.sh" ||
      file === "scripts/stop-managed-job.sh" ||
      file === "scripts/test-managed-job.sh" ||
      file === "scripts/clasp-clean-generated-state.sh" ||
      file === "scripts/test-generated-state-cleanup.sh";
    const isResolveClaspcSafetyPath =
      file === "scripts/resolve-claspc.sh" || file === "scripts/test-resolve-claspc.sh";
    const isGeneratedStateCleanupPlanStaticTestPath = file === "scripts/test-generated-state-cleanup-plan-static.sh";
    const isGeneratedStateCleanupPlanRuntimeTestPath = file === "scripts/test-generated-state-cleanup-plan.sh";
    const isSafeWorkspaceStaticTestPath = file === "scripts/test-safe-workspace-static.sh";
    const isGeneratedStateIgnorePath = file === ".gitignore";
    const isGeneratedStateCleanupPlanPath = file === "examples/swarm-native/GeneratedStateCleanupPlan.clasp";
    const isLocalRoutingPath =
      file === "examples/swarm-native/LocalRouting.clasp" ||
      file === "examples/swarm-native/LocalRoutingHarness.clasp";
    const isStandaloneSwarmSurfacePath =
      file === "src/StandaloneSwarmReadiness.clasp" ||
      file === "src/StandaloneSwarmVerifier.clasp" ||
      file === "examples/swarm-native/StandaloneSwarmHarness.clasp" ||
      file === "examples/swarm-native/StandaloneSwarmRouting.clasp" ||
      file === "examples/swarm-native/StandaloneSwarmClosureReport.clasp" ||
      file === "examples/swarm-native/StandaloneSwarmClosureReportHarness.clasp" ||
      file === "scripts/standalone-swarm-readiness.sh" ||
      file === "scripts/standalone-swarm-verify.sh" ||
      file === "scripts/test-standalone-swarm-surfaces.sh" ||
      file === "docs/standalone-swarm-readiness.md" ||
      file === "runtime/standalone_swarm_probe.rs";
    const isJsEmitterDeterminismPath =
      file === "src/Compiler/Emit/JavaScript.clasp" || file === "scripts/test-js-emitter-determinism.sh";
    const isSourceNativeVerifyScript = file === "src/scripts/verify.sh";
    const isIterationSpeedEvidencePath = file === "docs/iteration-speed-loop-evidence.md";
    const isNativeIncrementalGuardPath =
      file === "scripts/native-incremental-guard.mjs" ||
      file === "scripts/test-native-incremental-guard.sh";
    const compilerSlice = compilerSliceForFile(file);
    const isTryDecodePath =
      file === "scripts/test-try-decode.sh" ||
      file === "runtime/clasp_runtime.rs" ||
      file === "src/Compiler/Checker.clasp" ||
      file === "src/Compiler/Lower.clasp" ||
      file === "src/Compiler/Emit/JavaScript.clasp" ||
      file === "src/Compiler/Emit/Native.clasp" ||
      file === "src/Compiler/Emit/NativeJson.clasp";
    const isModelBoundaryPath =
      file === "examples/swarm-native/ModelBoundary.clasp" ||
      file === "examples/swarm-native/ModelBoundaryHarness.clasp" ||
      file === "scripts/test-model-boundary.sh";
    const isServiceDecodePath =
      file === "examples/swarm-native/Service.clasp" ||
      file === "examples/swarm-native/ServiceDecodeHarness.clasp" ||
      file === "scripts/test-service-decode.sh";
    const isBenchmarkCheckpoint = isBenchmarkCheckpointFile(file);
    const isBenchmarkPrepCache = isBenchmarkPrepCacheFile(file);
    const isPromotedSourceExportCache = isPromotedSourceExportCacheFile(file);
    const isPromotedModuleSummaryCache = isPromotedModuleSummaryCacheFile(file);
    const isSwarmMemoryPath =
      file === "runtime/swarm.rs" ||
      file === "runtime/clasp_runtime.rs" ||
      file === "examples/swarm-native/Swarm.clasp" ||
      file === "examples/swarm-native/MemoryHarness.clasp" ||
      file === "examples/swarm-native/WeightedMemoryHarness.clasp" ||
      file === "examples/swarm-native/EmbeddingProviderHarness.clasp" ||
      file === "src/Compiler/Checker.clasp" ||
      file === "scripts/test-swarm-memory.sh";
    const isSwarmPriorityPath =
      file === "runtime/swarm.rs" ||
      file === "runtime/clasp_runtime.rs" ||
      file === "examples/swarm-native/Swarm.clasp" ||
      file === "examples/swarm-native/PriorityHarness.clasp" ||
      file === "scripts/test-swarm-priority.sh";
    const isFocusedSwarmPriorityHarness = file === "examples/swarm-native/PriorityHarness.clasp";
    const isSwarmCapabilityAuditPath =
      file === "examples/swarm-native/SwarmCapabilityAudit.clasp" ||
      file === "docs/autonomous-swarm-runtime-requirements.md" ||
      file === "scripts/test-swarm-capability-audit.sh";
    const isSwarmSpawnPolicyPath =
      file === "runtime/swarm.rs" ||
      file === "runtime/clasp_runtime.rs" ||
      file === "examples/swarm-native/Swarm.clasp" ||
      file === "examples/swarm-native/SpawnPolicyHarness.clasp" ||
      file === "scripts/test-swarm-spawn-policy.sh";
    const isFocusedSwarmSpawnPolicyHarness = file === "examples/swarm-native/SpawnPolicyHarness.clasp";
    const isSwarmPolicyHelperPath =
      file === "runtime/swarm.rs" ||
      file === "runtime/clasp_runtime.rs" ||
      file === "examples/swarm-native/Swarm.clasp" ||
      file === "examples/swarm-native/CapabilityPolicyHarness.clasp" ||
      file === "examples/swarm-native/PolicyHarness.clasp" ||
      file === "examples/swarm-native/GoalManagerTaskPolicyHarness.clasp" ||
      file === "scripts/clasp-network-egress-backend.mjs" ||
      file === "scripts/clasp-network-egress-enforcer.mjs" ||
      file === "scripts/clasp-network-egress-kernel-backend.mjs" ||
      file === "scripts/clasp-network-egress-guard.c" ||
      file === "scripts/clasp-filesystem-write-enforcer.mjs" ||
      file === "scripts/clasp-filesystem-write-guard.c" ||
      file === "scripts/test-swarm-policy-helpers.sh";
    const isSwarmDestructivePolicyPath =
      file === "runtime/swarm.rs" ||
      file === "examples/swarm-native/DestructivePolicyHarness.clasp" ||
      file === "examples/swarm-native/FilesystemKernelPolicyHarness.clasp" ||
      file === "scripts/clasp-filesystem-write-enforcer.mjs" ||
      file === "scripts/clasp-filesystem-write-kernel-backend.mjs" ||
      file === "scripts/clasp-filesystem-write-guard.c" ||
      file === "scripts/test-swarm-destructive-policy.sh" ||
      file === "scripts/test-swarm-filesystem-kernel-policy.sh";
    const isFocusedSwarmPolicyHelperHarness =
      file === "examples/swarm-native/CapabilityPolicyHarness.clasp" ||
      file === "examples/swarm-native/PolicyHarness.clasp" ||
      file === "examples/swarm-native/GoalManagerTaskPolicyHarness.clasp";
    const isSwarmContextPackPath =
      file === "examples/swarm-native/Swarm.clasp" ||
      file === "examples/swarm-native/ContextPackHarness.clasp" ||
      file === "examples/swarm-native/SemanticSummaryIndex.clasp" ||
      file === "examples/swarm-native/SemanticSummaryIndexHarness.clasp" ||
      file === "docs/autonomous-swarm-near-term-roadmap.md" ||
      file === "scripts/test-swarm-context-pack.sh" ||
      file === "scripts/test-swarm-semantic-summary-index.sh";
    const isAgentBackendApiPath =
      file === "examples/swarm-native/AgentBackend.clasp";
    const isAgentBackendHarnessPath =
      file === "examples/swarm-native/AgentBackendHarness.clasp";
    const isAgentBackendStaticTestPath = file === "scripts/test-agent-backend-static.sh";
    const isAgentErgonomicsPath =
      file === "examples/swarm-native/AgentErgonomics.clasp" ||
      file === "examples/swarm-native/AgentErgonomicsHarness.clasp" ||
      file === "scripts/test-agent-ergonomics-helpers.sh";
    const isLocalSourceEditWorkspacePath =
      file === "examples/swarm-native/LocalSourceEdit.clasp" ||
      file === "examples/swarm-native/LocalSourceEditHarness.clasp" ||
      file === "scripts/test-local-source-edit-workspace.sh";
    const isLocalAgentCapabilityClosurePath =
      file === "scripts/test-local-agent-capability-closure.sh";
    const isRetiredGoalManagerProgramFile = retiredGoalManagerProgramFiles.has(file);
    const isSwarmFeedbackLoopProgramPath =
      file === "examples/swarm-native/FeedbackLoop.clasp" ||
      file === "examples/swarm-native/AttemptLoop.clasp" ||
      file === "examples/swarm-native/LocalAgent.clasp" ||
      isAgentBackendApiPath ||
      isAgentBackendHarnessPath;
    const isGoalManagerPlannerPromptPath =
      file === "examples/swarm-native/GoalManagerConfig.clasp" ||
      file === "examples/swarm-native/GoalManagerAgentBackendConfig.clasp" ||
      file === "examples/swarm-native/GoalManagerBootstrapPlanner.clasp" ||
      file === "examples/swarm-native/GoalManagerPlannerInputFingerprint.clasp" ||
      file === "examples/swarm-native/GoalManagerPlannerInputTypes.clasp" ||
      file === "examples/swarm-native/GoalManagerPlannerInputState.clasp" ||
      file === "examples/swarm-native/PlannerInputFingerprintHarness.clasp" ||
      file === "examples/swarm-native/LocalPlanner.clasp" ||
      isAgentBackendApiPath ||
      file === "scripts/test-goal-manager-agent-command-template.sh" ||
      file === "scripts/test-goal-manager-default-planner-command.sh" ||
      file === "scripts/test-goal-manager-fixture-manager.mjs";
    const isHostResourcesPath =
      file === "examples/swarm-native/HostResources.clasp" ||
      file === "examples/swarm-native/HostResourcesHarness.clasp";
    const isGoalManagerResourceHealthPath =
      file === "examples/swarm-native/GoalManagerResourceContext.clasp" ||
      file === "examples/swarm-native/GoalManagerResourceHealth.clasp" ||
      file === "examples/swarm-native/GoalManagerResourceHealthHarness.clasp" ||
      file === "examples/swarm-native/ResourceRecoveryPolicy.clasp" ||
      file === "examples/swarm-native/ResourceRecoveryPolicyHarness.clasp" ||
      file === "examples/swarm-native/ResourceGuardPolicy.clasp" ||
      file === "examples/swarm-native/ResourceGuardPolicyHarness.clasp" ||
      file === "scripts/test-resource-recovery-policy.sh" ||
      file === "scripts/test-goal-manager-resource-health.sh";
    const isGoalManagerGeneratedCleanupHealthPath =
      file === "examples/swarm-native/GoalManagerGeneratedCleanupHealth.clasp" ||
      file === "examples/swarm-native/GoalManagerGeneratedCleanupHealthHarness.clasp" ||
      file === "scripts/test-goal-manager-generated-cleanup-health.sh";
    const isGoalManagerMailboxCapabilityDetailsPath =
      file === "examples/swarm-native/GoalManagerCapabilityMailbox.clasp" ||
      file === "examples/swarm-native/GoalManagerMailboxMessages.clasp" ||
      file === "examples/swarm-native/GoalManagerMailboxCapabilityHarness.clasp" ||
      file === "scripts/test-goal-manager-mailbox-capability-details.sh";
    const isResourceGuardPolicyTestPath =
      file === "scripts/test-resource-guard-policy.sh";

    if (file.startsWith("src/") && !isPromotedSourceExportCache && !isPromotedModuleSummaryCache && !isSourceNativeVerifyScript && !isStandaloneSwarmSurfacePath) {
      matched = true;
      reason(file, "source", "source/compiler path uses selfhost and hosted compiler verification");
      addSelected(selectedByCommand, "selfhost", COMMANDS.selfhost, "source/compiler path", file);
      addSelected(selectedByCommand, "source-verify", COMMANDS.sourceVerify, "source/compiler path", file);
      addSelected(selectedByCommand, "int-builtins", COMMANDS.intBuiltins, "source/compiler path", file);
      addSelected(selectedByCommand, "dict-builtins", COMMANDS.dictBuiltins, "source/compiler path", file);
      if (isTryDecodePath) {
        addSelected(selectedByCommand, "try-decode", COMMANDS.tryDecode, "safe decode compiler path", file);
      }
    }

    if (compilerSlice) {
      matched = true;
      reason(file, "compiler-slice", compilerSliceDetailForFile(file, compilerSlice));
      addSelected(
        selectedByCommand,
        `compiler-slice:${compilerSlice}${file.startsWith("src/Compiler/") ? ":check-only" : ""}`,
        compilerSliceCommandForFile(file, compilerSlice),
        "compiler slice path",
        file,
      );
    }

    if (isJsEmitterDeterminismPath) {
      matched = true;
      reason(
        file,
        "js-emitter-determinism",
        "JavaScript emitter determinism paths use a focused stable snapshot and Dict projection guard",
      );
      if (file.endsWith(".sh")) {
        addSelected(
          selectedByCommand,
          `bash-syntax:${file}`,
          `bash -n ${shellQuote(file)}`,
          "JavaScript emitter determinism shell syntax",
          file,
        );
      }
      addSelected(
        selectedByCommand,
        "js-emitter-determinism",
        COMMANDS.jsEmitterDeterminism,
        "JavaScript emitter deterministic snapshot guard",
        file,
      );
    }

    const exampleVerifyCommand = exampleVerifyCommandForFile(file);
    if (exampleVerifyCommand) {
      matched = true;
      reason(file, "clasp-app-flow", "Clasp example app file uses its scenario verifier for source check, compile, and app-flow behavior");
      addSelected(selectedByCommand, `example-app:${exampleVerifyCommand}`, exampleVerifyCommand, "Clasp app-flow path", file);
    }

    const exampleVerifyScriptCommand = exampleVerifyScriptCommandForFile(file);
    if (exampleVerifyScriptCommand) {
      matched = true;
      reason(file, "clasp-app-flow-script", "Clasp example verifier script uses shell syntax plus its scenario verifier");
      addSelected(
        selectedByCommand,
        `bash-syntax:${file}`,
        `bash -n ${shellQuote(file)}`,
        "Clasp app-flow verifier shell syntax",
        file,
      );
      addSelected(
        selectedByCommand,
        `example-app:${exampleVerifyScriptCommand}`,
        exampleVerifyScriptCommand,
        "Clasp app-flow verifier script",
        file,
      );
    }

    if (file.startsWith("runtime/") && !isStandaloneSwarmSurfacePath) {
      matched = true;
      reason(file, "runtime", "runtime path uses native runtime and native claspc coverage");
      addSelected(selectedByCommand, "int-builtins", COMMANDS.intBuiltins, "runtime path", file);
      addSelected(selectedByCommand, "dict-builtins", COMMANDS.dictBuiltins, "runtime path", file);
      addSelected(selectedByCommand, "try-decode", COMMANDS.tryDecode, "runtime path", file);
      addSelected(selectedByCommand, "safe-workspace-static", COMMANDS.safeWorkspaceStatic, "runtime host workspace contract", file);
      addSelected(selectedByCommand, "native-runtime", COMMANDS.nativeRuntime, "runtime path", file);
      addSelected(selectedByCommand, "native-claspc", COMMANDS.nativeClaspc, "runtime path", file);
    }

    if (isSwarmMemoryPath) {
      matched = true;
      reason(file, "swarm-memory", "swarm memory paths use focused native CLI and ordinary Clasp API coverage");
      if (file.endsWith(".sh")) {
        addSelected(
          selectedByCommand,
          `bash-syntax:${file}`,
          `bash -n ${shellQuote(file)}`,
          "swarm memory shell syntax",
          file,
        );
      }
      addSelected(selectedByCommand, "swarm-memory", COMMANDS.swarmMemory, "swarm memory path", file);
    }

    if (isSwarmPriorityPath) {
      matched = true;
      reason(file, "swarm-priority", "swarm priority paths use focused native CLI and ordinary Clasp scheduling coverage");
      if (file.endsWith(".sh")) {
        addSelected(
          selectedByCommand,
          `bash-syntax:${file}`,
          `bash -n ${shellQuote(file)}`,
          "swarm priority shell syntax",
          file,
        );
      }
      addSelected(selectedByCommand, "swarm-priority", COMMANDS.swarmPriority, "swarm priority path", file);
      if (isFocusedSwarmPriorityHarness) {
        addSelected(selectedByCommand, "swarm-ready", COMMANDS.swarmReady, "swarm priority harness structural gate", file);
      }
    }

    if (isSwarmSpawnPolicyPath) {
      matched = true;
      reason(file, "swarm-spawn-policy", "swarm spawn policy paths use focused native CLI and ordinary Clasp bounded child-spawn coverage");
      if (file.endsWith(".sh")) {
        addSelected(
          selectedByCommand,
          `bash-syntax:${file}`,
          `bash -n ${shellQuote(file)}`,
          "swarm spawn policy shell syntax",
          file,
        );
      }
      addSelected(selectedByCommand, "swarm-spawn-policy", COMMANDS.swarmSpawnPolicy, "swarm spawn policy path", file);
      if (isFocusedSwarmSpawnPolicyHarness) {
        addSelected(selectedByCommand, "swarm-ready", COMMANDS.swarmReady, "swarm spawn policy harness structural gate", file);
      }
    }

    if (isSwarmPolicyHelperPath) {
      matched = true;
      reason(file, "swarm-policy-helpers", "swarm policy helper paths use focused ordinary Clasp capability coverage");
      if (file.endsWith(".sh")) {
        addSelected(
          selectedByCommand,
          `bash-syntax:${file}`,
          `bash -n ${shellQuote(file)}`,
          "swarm policy helper shell syntax",
          file,
        );
      }
      if (file.endsWith(".mjs")) {
        addSelected(
          selectedByCommand,
          `node-syntax:${file}`,
          `node --check ${shellQuote(file)}`,
          "swarm policy helper node syntax",
          file,
        );
      }
      if (file.endsWith(".c")) {
        addSelected(
          selectedByCommand,
          `c-syntax:${file}`,
          `cc -fsyntax-only ${shellQuote(file)}`,
          "swarm policy helper C guard syntax",
          file,
        );
      }
      addSelected(
        selectedByCommand,
        "swarm-policy-helpers",
        COMMANDS.swarmPolicyHelpers,
        "swarm policy helper path",
        file,
      );
      if (isFocusedSwarmPolicyHelperHarness) {
        addSelected(selectedByCommand, "swarm-ready", COMMANDS.swarmReady, "swarm policy helper harness structural gate", file);
      }
    }

    if (isSwarmDestructivePolicyPath) {
      matched = true;
      reason(file, "swarm-destructive-policy", "filesystem mediator paths use focused destructive filesystem policy coverage");
      if (file.endsWith(".sh")) {
        addSelected(
          selectedByCommand,
          `bash-syntax:${file}`,
          `bash -n ${shellQuote(file)}`,
          "swarm destructive policy shell syntax",
          file,
        );
      }
      if (file.endsWith(".mjs")) {
        addSelected(
          selectedByCommand,
          `node-syntax:${file}`,
          `node --check ${shellQuote(file)}`,
          "filesystem mediator node syntax",
          file,
        );
      }
      if (file.endsWith(".c")) {
        addSelected(
          selectedByCommand,
          `c-syntax:${file}`,
          `cc -fsyntax-only ${shellQuote(file)}`,
          "filesystem write guard C syntax",
          file,
        );
      }
      addSelected(
        selectedByCommand,
        "swarm-destructive-policy",
        COMMANDS.swarmDestructivePolicy,
        "swarm destructive filesystem policy path",
        file,
      );
      addSelected(
        selectedByCommand,
        "swarm-filesystem-kernel-policy",
        COMMANDS.swarmFilesystemKernelPolicy,
        "swarm kernel filesystem policy path",
        file,
      );
      addSelected(selectedByCommand, "swarm-ready", COMMANDS.swarmReady, "swarm destructive policy structural gate", file);
    }

    if (isSwarmContextPackPath) {
      matched = true;
      reason(file, "swarm-context-pack", "swarm context-pack paths use focused ordinary Clasp context assembly coverage");
      if (file.endsWith(".sh")) {
        addSelected(
          selectedByCommand,
          `bash-syntax:${file}`,
          `bash -n ${shellQuote(file)}`,
          "swarm context-pack shell syntax",
          file,
        );
      }
      addSelected(
        selectedByCommand,
        "swarm-context-pack",
        COMMANDS.swarmContextPack,
        "swarm context-pack path",
        file,
      );
      addSelected(
        selectedByCommand,
        "swarm-semantic-summary-index",
        COMMANDS.swarmSemanticSummaryIndex,
        "swarm semantic-summary index path",
        file,
      );
    }

    if (file === "scripts/test-int-builtins.sh") {
      matched = true;
      reason(file, "int-builtins-harness", "integer builtin harness uses shell syntax plus focused JS/native builtin coverage");
      addSelected(
        selectedByCommand,
        `bash-syntax:${file}`,
        `bash -n ${shellQuote(file)}`,
        "integer builtin shell syntax",
        file,
      );
      addSelected(selectedByCommand, "int-builtins", COMMANDS.intBuiltins, "integer builtin harness", file);
    }

    if (file === "scripts/test-dict-builtins.sh") {
      matched = true;
      reason(file, "dict-builtins-harness", "dictionary builtin harness uses shell syntax plus focused JS/native builtin coverage");
      addSelected(
        selectedByCommand,
        `bash-syntax:${file}`,
        `bash -n ${shellQuote(file)}`,
        "dictionary builtin shell syntax",
        file,
      );
      addSelected(selectedByCommand, "dict-builtins", COMMANDS.dictBuiltins, "dictionary builtin harness", file);
    }

    if (file === "scripts/test-try-decode.sh") {
      matched = true;
      reason(file, "try-decode-harness", "tryDecode harness uses shell syntax plus focused JS/native safe decode coverage");
      addSelected(
        selectedByCommand,
        `bash-syntax:${file}`,
        `bash -n ${shellQuote(file)}`,
        "tryDecode shell syntax",
        file,
      );
      addSelected(selectedByCommand, "try-decode", COMMANDS.tryDecode, "tryDecode harness", file);
    }

    if (isModelBoundaryPath) {
      matched = true;
      reason(
        file,
        "model-boundary",
        "model boundary paths use focused typed Prompt plus untrusted-output validation coverage",
      );
      if (file.endsWith(".sh")) {
        addSelected(
          selectedByCommand,
          `bash-syntax:${file}`,
          `bash -n ${shellQuote(file)}`,
          "model boundary shell syntax",
          file,
        );
      }
      addSelected(selectedByCommand, "model-boundary", COMMANDS.modelBoundary, "model boundary path", file);
      addSelected(selectedByCommand, "swarm-ready", COMMANDS.swarmReady, "model boundary path", file);
    }

    if (isServiceDecodePath) {
      matched = true;
      reason(file, "service-decode", "service runtime boundary paths use focused malformed host JSON recovery coverage");
      if (file.endsWith(".sh")) {
        addSelected(
          selectedByCommand,
          `bash-syntax:${file}`,
          `bash -n ${shellQuote(file)}`,
          "service decode shell syntax",
          file,
        );
      }
      addSelected(selectedByCommand, "service-decode", COMMANDS.serviceDecode, "service decode path", file);
      addSelected(selectedByCommand, "swarm-ready", COMMANDS.swarmReady, "service decode path", file);
    }

    if (file === "scripts/test-native-claspc-diagnostics.sh") {
      matched = true;
      reason(file, "native-diagnostics-harness", "native diagnostics harness uses shell syntax plus focused compiler diagnostics coverage");
      addSelected(
        selectedByCommand,
        `bash-syntax:${file}`,
        `bash -n ${shellQuote(file)}`,
        "native diagnostics shell syntax",
        file,
      );
      addSelected(
        selectedByCommand,
        "native-diagnostics",
        COMMANDS.nativeDiagnostics,
        "native diagnostics harness",
        file,
      );
    }

    if (file === "scripts/test-record-update-parity.sh") {
      matched = true;
      reason(file, "record-update-parity-harness", "record update parity harness uses shell syntax plus focused frontend/native/runtime coverage");
      addSelected(
        selectedByCommand,
        `bash-syntax:${file}`,
        `bash -n ${shellQuote(file)}`,
        "record update parity shell syntax",
        file,
      );
      addSelected(
        selectedByCommand,
        "record-update-parity",
        COMMANDS.recordUpdateParity,
        "record update parity harness",
        file,
      );
    }

    if (isSwarmFeedbackLoopProgramPath) {
      matched = true;
      reason(
        file,
        "swarm-feedback-loop-program",
        "FeedbackLoop agent-loop sources use focused FeedbackLoop and local agent prompt coverage",
      );
      addSelected(
        selectedByCommand,
        "runtime-slice:swarm-feedback-loop",
        COMMANDS.runtimeSliceSwarmFeedbackLoop,
        "swarm feedback-loop program",
        file,
      );
      addSelected(
        selectedByCommand,
        "agent-command-template",
        COMMANDS.agentCommandTemplate,
        "swarm feedback-loop program",
        file,
      );
      if (isAgentBackendApiPath || isAgentBackendHarnessPath) {
        addSelected(
          selectedByCommand,
          "agent-backend-static",
          COMMANDS.agentBackendStatic,
          "agent backend policy contract",
          file,
        );
      }
      addSelected(selectedByCommand, "swarm-ready", COMMANDS.swarmReady, "swarm feedback-loop program", file);
    }

    if (isLocalSourceEditWorkspacePath) {
      matched = true;
      reason(
        file,
        "local-source-edit-workspace",
        "standalone source-edit paths use focused workspace-confined source-patch coverage plus the structural swarm gate",
      );
      if (file.endsWith(".sh")) {
        addSelected(
          selectedByCommand,
          `bash-syntax:${file}`,
          `bash -n ${shellQuote(file)}`,
          "local source edit workspace shell syntax",
          file,
        );
      }
      addSelected(
        selectedByCommand,
        "local-source-edit-workspace",
        COMMANDS.localSourceEditWorkspace,
        "standalone source-edit workspace path",
        file,
      );
      addSelected(selectedByCommand, "swarm-ready", COMMANDS.swarmReady, "standalone source-edit workspace path", file);
    }

    if (isLocalAgentCapabilityClosurePath) {
      matched = true;
      reason(
        file,
        "local-agent-capability-closure",
        "standalone local-agent source-edit behavior uses repo-scale source-patch coverage plus the structural swarm gate",
      );
      addSelected(
        selectedByCommand,
        `bash-syntax:${file}`,
        `bash -n ${shellQuote(file)}`,
        "local agent capability closure shell syntax",
        file,
      );
      addSelected(
        selectedByCommand,
        "local-agent-capability-closure",
        COMMANDS.localAgentCapabilityClosure,
        "standalone local-agent source-edit behavior",
        file,
      );
      addSelected(selectedByCommand, "swarm-ready", COMMANDS.swarmReady, "standalone local-agent source-edit behavior", file);
    }

    if (isGoalManagerPlannerPromptPath) {
      matched = true;
      reason(
        file,
        "goal-manager-planner-prompt",
        "GoalManager planner prompt paths use provider-neutral planner command coverage and structural ready-gate checks",
      );
      if (file.endsWith(".sh")) {
        addSelected(
          selectedByCommand,
          `bash-syntax:${file}`,
          `bash -n ${shellQuote(file)}`,
          "GoalManager planner prompt shell syntax",
          file,
        );
      }
      if (file.endsWith(".mjs")) {
        addSelected(
          selectedByCommand,
          `node-syntax:${file}`,
          `node --check ${shellQuote(file)}`,
          "GoalManager planner prompt node syntax",
          file,
        );
      }
      addSelected(
        selectedByCommand,
        "goal-manager-agent-command-template",
        COMMANDS.goalManagerAgentCommandTemplate,
        "GoalManager planner prompt path",
        file,
      );
      addSelected(
        selectedByCommand,
        "goal-manager-default-planner-command",
        COMMANDS.goalManagerDefaultPlannerCommand,
        "GoalManager planner prompt path",
        file,
      );
      if (isAgentBackendApiPath) {
        addSelected(
          selectedByCommand,
          "agent-backend-static",
          COMMANDS.agentBackendStatic,
          "agent backend policy contract",
          file,
        );
      }
      addSelected(selectedByCommand, "swarm-ready", COMMANDS.swarmReady, "GoalManager planner prompt path", file);
    }

    if (isRetiredGoalManagerProgramFile) {
      matched = true;
      reason(file, "retired-goal-manager-monolith", "retired GoalManager monolith paths use the ready-gate absence check");
      addSelected(selectedByCommand, "swarm-ready", COMMANDS.swarmReady, "retired GoalManager monolith path", file);
    }

    if (isHostResourcesPath) {
      matched = true;
      reason(file, "host-resources", "host resource paths use focused ordinary runtime binding coverage plus the structural swarm gate");
      addSelected(selectedByCommand, "host-runtime", COMMANDS.hostRuntime, "host resources path", file);
      addSelected(selectedByCommand, "swarm-ready", COMMANDS.swarmReady, "host resources path", file);
    }

    if (isGoalManagerResourceHealthPath) {
      matched = true;
      reason(file, "goal-manager-resource-health", "GoalManager resource guard path uses focused manager resource-health coverage plus the structural swarm gate");
      addSelected(selectedByCommand, "resource-guard-policy", COMMANDS.resourceGuardPolicy, "GoalManager resource guard path", file);
      addSelected(selectedByCommand, "resource-recovery-policy", COMMANDS.resourceRecoveryPolicy, "GoalManager resource guard path", file);
      addSelected(selectedByCommand, "goal-manager-resource-health", COMMANDS.goalManagerResourceHealth, "GoalManager resource guard path", file);
      addSelected(selectedByCommand, "swarm-ready", COMMANDS.swarmReady, "GoalManager resource guard path", file);
    }

    if (isGoalManagerGeneratedCleanupHealthPath) {
      matched = true;
      reason(file, "goal-manager-generated-cleanup-health", "GoalManager generated cleanup health uses the small cleanup-health contract plus the structural swarm gate");
      addSelected(
        selectedByCommand,
        "goal-manager-generated-cleanup-health",
        COMMANDS.goalManagerGeneratedCleanupHealth,
        "GoalManager generated cleanup health path",
        file,
      );
      addSelected(
        selectedByCommand,
        "generated-state-cleanup-plan-static",
        COMMANDS.generatedStateCleanupPlanStatic,
        "GoalManager generated cleanup health path",
        file,
      );
      addSelected(selectedByCommand, "swarm-ready", COMMANDS.swarmReady, "GoalManager generated cleanup health path", file);
    }

    if (isGoalManagerMailboxCapabilityDetailsPath) {
      matched = true;
      reason(file, "goal-manager-mailbox-capability-details", "GoalManager mailbox capability-detail path uses focused mailbox capability propagation coverage plus the structural swarm gate");
      addSelected(
        selectedByCommand,
        "goal-manager-mailbox-capability-details",
        COMMANDS.goalManagerMailboxCapabilityDetails,
        "GoalManager mailbox capability-detail path",
        file,
      );
      addSelected(selectedByCommand, "swarm-ready", COMMANDS.swarmReady, "GoalManager mailbox capability-detail path", file);
    }

    if (isResourceGuardPolicyTestPath) {
      matched = true;
      reason(file, "resource-guard-policy-harness", "resource guard policy harness uses shell syntax plus focused policy coverage");
      addSelected(
        selectedByCommand,
        `shell-syntax:${file}`,
        `bash -n ${shellQuote(file)}`,
        "resource guard policy shell syntax",
        file,
      );
      addSelected(selectedByCommand, "resource-guard-policy", COMMANDS.resourceGuardPolicy, "resource guard policy harness", file);
      addSelected(selectedByCommand, "swarm-ready", COMMANDS.swarmReady, "resource guard policy harness", file);
    }

    if (isGeneratedStateCleanupPlanPath) {
      matched = true;
      reason(file, "generated-state-cleanup-plan", "Clasp generated-state cleanup planner uses focused shell cleanup, fast cleanup-plan contract coverage, and structural swarm coverage");
      addSelected(
        selectedByCommand,
        "generated-state-cleanup",
        COMMANDS.generatedStateCleanup,
        "Clasp generated-state cleanup planner",
        file,
      );
      addSelected(
        selectedByCommand,
        "generated-state-cleanup-plan-static",
        COMMANDS.generatedStateCleanupPlanStatic,
        "Clasp generated-state cleanup planner",
        file,
      );
      addSelected(selectedByCommand, "swarm-ready", COMMANDS.swarmReady, "Clasp generated-state cleanup planner", file);
    }

    if (isGeneratedStateCleanupPlanRuntimeTestPath) {
      matched = true;
      reason(file, "generated-state-cleanup-plan-runtime-test", "Clasp generated-state cleanup plan runtime test uses shell syntax plus the fast static cleanup-plan contract");
      addSelected(
        selectedByCommand,
        `bash-syntax:${file}`,
        `bash -n ${shellQuote(file)}`,
        "generated-state cleanup plan shell syntax",
        file,
      );
      addSelected(
        selectedByCommand,
        "generated-state-cleanup-plan-static",
        COMMANDS.generatedStateCleanupPlanStatic,
        "Clasp generated-state cleanup plan runtime regression",
        file,
      );
      addSelected(selectedByCommand, "swarm-ready", COMMANDS.swarmReady, "generated-state cleanup plan structural gate", file);
    }

    if (isGeneratedStateCleanupPlanStaticTestPath) {
      matched = true;
      reason(file, "generated-state-cleanup-plan-static-test", "Clasp generated-state cleanup plan static test uses shell syntax plus fast contract coverage");
      addSelected(
        selectedByCommand,
        `bash-syntax:${file}`,
        `bash -n ${shellQuote(file)}`,
        "generated-state cleanup plan static shell syntax",
        file,
      );
      addSelected(
        selectedByCommand,
        "generated-state-cleanup-plan-static",
        COMMANDS.generatedStateCleanupPlanStatic,
        "Clasp generated-state cleanup plan static contract",
        file,
      );
      addSelected(selectedByCommand, "swarm-ready", COMMANDS.swarmReady, "generated-state cleanup plan structural gate", file);
    }

    if (isLocalRoutingPath) {
      matched = true;
      reason(file, "local-routing", "local routing policy uses focused agent-template coverage plus the structural swarm gate");
      addSelected(
        selectedByCommand,
        "agent-command-template",
        COMMANDS.agentCommandTemplate,
        "local routing policy",
        file,
      );
      addSelected(
        selectedByCommand,
        "goal-manager-agent-command-template",
        COMMANDS.goalManagerAgentCommandTemplate,
        "local routing policy",
        file,
      );
      addSelected(selectedByCommand, "swarm-ready", COMMANDS.swarmReady, "local routing policy", file);
    }

    if (isStandaloneSwarmSurfacePath) {
      matched = true;
      reason(
        file,
        "standalone-swarm-surfaces",
        "standalone swarm source surfaces use focused surface coverage plus the structural swarm gate",
      );
      if (file.endsWith(".sh")) {
        addSelected(
          selectedByCommand,
          `bash-syntax:${file}`,
          `bash -n ${shellQuote(file)}`,
          "standalone swarm surface shell syntax",
          file,
        );
      }
      addSelected(
        selectedByCommand,
        "standalone-swarm-surfaces",
        COMMANDS.standaloneSwarmSurfaces,
        "standalone swarm source surfaces",
        file,
      );
      addSelected(selectedByCommand, "swarm-ready", COMMANDS.swarmReady, "standalone swarm source surfaces", file);
    }

    if (file === "examples/swarm-native/SwarmCapabilityAudit.clasp" || file === "docs/autonomous-swarm-runtime-requirements.md") {
      matched = true;
      reason(file, "swarm-capability-audit", "swarm capability audit uses focused lightweight audit coverage plus the structural swarm gate");
      addSelected(selectedByCommand, "swarm-ready", COMMANDS.swarmReady, "swarm capability audit structural gate", file);
      addSelected(
        selectedByCommand,
        "swarm-capability-audit",
        COMMANDS.swarmCapabilityAudit,
        "swarm capability audit program",
        file,
      );
    }

    if (file.startsWith("examples/swarm-native/") && !isSwarmFeedbackLoopProgramPath && !isGoalManagerPlannerPromptPath && !isModelBoundaryPath && !isServiceDecodePath && !isFocusedSwarmPriorityHarness && !isFocusedSwarmPolicyHelperHarness && !focusedPlannerReportDecodeFiles.has(file) && !isRetiredGoalManagerProgramFile && !isHostResourcesPath && !isGoalManagerResourceHealthPath && !isGoalManagerGeneratedCleanupHealthPath && !isGoalManagerMailboxCapabilityDetailsPath && !isGeneratedStateCleanupPlanPath && !isLocalRoutingPath && !isStandaloneSwarmSurfacePath && !isSwarmCapabilityAuditPath && !isAgentErgonomicsPath && !isLocalSourceEditWorkspacePath && !isLocalAgentCapabilityClosurePath) {
      matched = true;
      reason(file, "swarm-native", "native swarm example path uses native claspc, ready-gate, managed-loop, memory, and context-pack coverage");
      addSelected(selectedByCommand, "native-claspc", COMMANDS.nativeClaspc, "swarm native path", file);
      addSelected(selectedByCommand, "swarm-ready", COMMANDS.swarmReady, "swarm native path", file);
      if (file === "examples/swarm-native/SwarmReadyBenchmark.clasp") {
        addSelected(
          selectedByCommand,
          "swarm-ready-benchmark",
          COMMANDS.swarmReadyBenchmark,
          "native swarm readiness benchmark",
          file,
        );
      }
      addSelected(selectedByCommand, "swarm-memory", COMMANDS.swarmMemory, "swarm native path", file);
      addSelected(selectedByCommand, "swarm-priority", COMMANDS.swarmPriority, "swarm native path", file);
      addSelected(selectedByCommand, "swarm-spawn-policy", COMMANDS.swarmSpawnPolicy, "swarm native path", file);
      addSelected(selectedByCommand, "swarm-context-pack", COMMANDS.swarmContextPack, "swarm native path", file);
      addSelected(selectedByCommand, "monitored-loop", COMMANDS.monitoredLoop, "swarm native path", file);
      addSelected(selectedByCommand, "runtime-slice:managed-loop", COMMANDS.runtimeSliceManagedLoop, "swarm native path", file);
    }

    if (plannerReportDecodeFiles.has(file)) {
      matched = true;
      reason(file, "goal-manager-planner-report-decode", "GoalManager durable JSON decoding uses focused malformed/current/legacy report and resume-state coverage");
      addSelected(
        selectedByCommand,
        "goal-manager-planner-report-decode",
        COMMANDS.goalManagerPlannerReportDecode,
        "planner report decode path",
        file,
      );
      addSelected(selectedByCommand, "swarm-ready", COMMANDS.swarmReady, "planner report decode path", file);
      if (file.endsWith(".sh")) {
        addSelected(
          selectedByCommand,
          `bash-syntax:${file}`,
          `bash -n ${shellQuote(file)}`,
          "planner report decode shell syntax",
          file,
        );
      }
    }

    if (file.startsWith("examples/feedback-loop/")) {
      matched = true;
      reason(file, "feedback-loop", "feedback-loop example path uses runtime slices plus the lightweight loop-routing selector probe");
      addSelected(selectedByCommand, "runtime-slice:process", COMMANDS.runtimeSliceProcess, "feedback-loop path", file);
      addSelected(selectedByCommand, "runtime-slice:workflow", COMMANDS.runtimeSliceWorkflow, "feedback-loop path", file);
      addSelected(selectedByCommand, "runtime-slice:codex-loop", COMMANDS.runtimeSliceCodexLoop, "feedback-loop path", file);
      addSelected(selectedByCommand, "feedback-loop-routing:loop-routing", COMMANDS.feedbackLoopRoutingLoop, "feedback-loop path", file);
    }

    if (file.startsWith("examples/host-runtime/")) {
      matched = true;
      reason(file, "host-runtime", "host runtime example path uses focused ordinary-program process and file IO coverage");
      addSelected(selectedByCommand, "host-runtime", COMMANDS.hostRuntime, "host runtime path", file);
    }

    if (file.startsWith("examples/agent-loop-scenario/")) {
      matched = true;
      reason(file, "agent-loop-scenario", "ordinary agent-loop scenario path uses focused safe workspace, subprocess, and durable status coverage");
      if (file.endsWith(".sh")) {
        addSelected(
          selectedByCommand,
          `bash-syntax:${file}`,
          `bash -n ${shellQuote(file)}`,
          "agent-loop scenario shell syntax",
          file,
        );
      }
      addSelected(selectedByCommand, "agent-loop-scenario", COMMANDS.agentLoopScenario, "agent-loop scenario path", file);
    }

    if (file.startsWith("examples/safe-workspace/")) {
      matched = true;
      reason(file, "safe-workspace", "safe workspace example path uses fast host-binding contract coverage plus focused ordinary-program root-bounded file API coverage");
      addSelected(selectedByCommand, "safe-workspace-static", COMMANDS.safeWorkspaceStatic, "safe workspace host-binding contract", file);
      addSelected(selectedByCommand, "safe-workspace", COMMANDS.safeWorkspace, "safe workspace path", file);
    }

    if (file.startsWith("examples/safe-subprocess/")) {
      matched = true;
      reason(file, "safe-subprocess", "safe subprocess example path uses focused ordinary-program root-bounded process API coverage");
      addSelected(selectedByCommand, "safe-subprocess", COMMANDS.safeSubprocess, "safe subprocess path", file);
    }

    if (hostRuntimeDocFiles.has(file)) {
      matched = true;
      reason(file, "host-runtime-docs", "host runtime documentation changes use focused ordinary host API coverage");
      addSelected(selectedByCommand, "host-runtime", COMMANDS.hostRuntime, "host runtime docs", file);
    }

    if (isBenchmarkCheckpoint) {
      matched = true;
      reason(
        file,
        "benchmark-checkpoint",
        "benchmark checkpoint paths use checkpoint runner syntax plus focused fixture/schema coverage",
      );
      if (file.endsWith(".sh")) {
        addSelected(
          selectedByCommand,
          `bash-syntax:${file}`,
          `bash -n ${shellQuote(file)}`,
          "benchmark checkpoint shell syntax",
          file,
        );
      }
      addSelected(
        selectedByCommand,
        "benchmark-checkpoint-node-check",
        COMMANDS.benchmarkCheckpointNodeCheck,
        "benchmark checkpoint runner syntax",
        file,
      );
      addSelected(
        selectedByCommand,
        "benchmark-checkpoint-regression",
        COMMANDS.benchmarkCheckpointRegression,
        "benchmark checkpoint fixture regression",
        file,
      );
    }

    if (isBenchmarkPrepCache) {
      matched = true;
      reason(
        file,
        "benchmark-prep-cache",
        "benchmark prep cache paths use runner syntax plus focused cache hit/invalidation coverage",
      );
      if (file.endsWith(".sh")) {
        addSelected(
          selectedByCommand,
          `bash-syntax:${file}`,
          `bash -n ${shellQuote(file)}`,
          "benchmark prep cache shell syntax",
          file,
        );
      }
      addSelected(
        selectedByCommand,
        "run-benchmark-node-check",
        COMMANDS.runBenchmarkNodeCheck,
        "benchmark runner syntax",
        file,
      );
      addSelected(
        selectedByCommand,
        "benchmark-prep-cache-regression",
        COMMANDS.benchmarkPrepCacheRegression,
        "benchmark prep cache regression",
        file,
      );
    }

    if (isPromotedSourceExportCache) {
      matched = true;
      reason(
        file,
        "promoted-source-export-cache",
        "promoted source-export cache paths use generator syntax plus focused cold-check cache coverage",
      );
      if (file.endsWith(".sh")) {
        addSelected(
          selectedByCommand,
          `bash-syntax:${file}`,
          `bash -n ${shellQuote(file)}`,
          "promoted source-export cache shell syntax",
          file,
        );
      }
      addSelected(
        selectedByCommand,
        "promoted-source-export-cache-node-check",
        COMMANDS.promotedSourceExportCacheNodeCheck,
        "promoted source-export cache generator syntax",
        file,
      );
      addSelected(
        selectedByCommand,
        "promoted-source-export-cache-regression",
        COMMANDS.promotedSourceExportCacheRegression,
        "promoted source-export cache regression",
        file,
      );
    }

    if (isPromotedModuleSummaryCache) {
      matched = true;
      reason(
        file,
        "promoted-module-summary-cache",
        "promoted module-summary cache paths use generator syntax plus focused freshness coverage",
      );
      if (file.endsWith(".sh")) {
        addSelected(
          selectedByCommand,
          `bash-syntax:${file}`,
          `bash -n ${shellQuote(file)}`,
          "promoted module-summary cache shell syntax",
          file,
        );
      }
      addSelected(
        selectedByCommand,
        "promoted-module-summary-cache-node-check",
        COMMANDS.promotedModuleSummaryCacheNodeCheck,
        "promoted module-summary cache generator syntax",
        file,
      );
      addSelected(
        selectedByCommand,
        "promoted-module-summary-cache-regression",
        COMMANDS.promotedModuleSummaryCacheRegression,
        "promoted module-summary cache freshness regression",
        file,
      );
    }

    if (isAgentFeedbackJsonFile(file)) {
      matched = true;
      reason(file, "agent-feedback", "agent feedback artifact uses focused JSON parse coverage");
      addSelected(
        selectedByCommand,
        `agent-feedback-json:${file}`,
        `node -e 'const fs=require("node:fs"); JSON.parse(fs.readFileSync(process.argv[1],"utf8"));' ${shellQuote(file)}`,
        "agent feedback JSON parse",
        file,
      );
    }

    const benchmarkMatch = benchmarkTaskRepoMatch(file);
    if (benchmarkMatch) {
      matched = true;
      const task = benchmarkTaskMetadata(benchmarkMatch.taskId);
      const taskLanguage = task?.language || "unknown";
      reason(
        file,
        "benchmark-task-repo",
        `benchmark task repo path for ${benchmarkMatch.taskId} (${taskLanguage}) uses benchmark prep plus task app-flow verification when available`,
      );
      addSelected(selectedByCommand, "benchmark-task-prep", COMMANDS.benchmarkTaskPrep, "benchmark task repo path", file);
      const taskVerifyCommand = benchmarkTaskVerifyCommand(benchmarkMatch.taskId);
      if (taskVerifyCommand && (taskLanguage === "clasp" || isClaspSourceFile(file))) {
        addSelected(
          selectedByCommand,
          `benchmark-task:${benchmarkMatch.taskId}`,
          taskVerifyCommand,
          "benchmark task app-flow path",
          file,
        );
      }
    }

    if (!isBenchmarkCheckpoint && !isBenchmarkPrepCache && file.startsWith("benchmarks/")) {
      matched = true;
      reason(file, "benchmarks", "benchmark path uses benchmark task-prep coverage");
      addSelected(selectedByCommand, "benchmark-task-prep", COMMANDS.benchmarkTaskPrep, "benchmark path", file);
    }

    if (file === "scripts/test-goal-manager-fast.sh") {
      matched = true;
      reason(file, "goal-manager-fast-harness", "GoalManager fast harness uses shell syntax plus focused GoalManager coverage");
      addSelected(
        selectedByCommand,
        `bash-syntax:${file}`,
        `bash -n ${shellQuote(file)}`,
        "GoalManager fast shell syntax",
        file,
      );
      addSelected(selectedByCommand, "goal-manager-fast", COMMANDS.goalManagerFast, "GoalManager fast harness", file);
      addSelected(selectedByCommand, "swarm-ready", COMMANDS.swarmReady, "GoalManager fast harness", file);
    }

    if (file === "scripts/ensure-goal-manager-binary.sh") {
      matched = true;
      reason(file, "goal-manager-binary-helper", "GoalManager binary helper uses shell syntax plus focused cache/stale-reuse regression coverage");
      addSelected(
        selectedByCommand,
        `bash-syntax:${file}`,
        `bash -n ${shellQuote(file)}`,
        "GoalManager binary helper shell syntax",
        file,
      );
      addSelected(selectedByCommand, "verify-all-regression", COMMANDS.verifyAllRegression, "GoalManager binary helper regression", file);
    }

    if (file === "scripts/test-swarm-ready-gate.sh") {
      matched = true;
      reason(file, "swarm-ready-gate-harness", "swarm-ready gate uses shell syntax plus its focused structural coverage");
      addSelected(
        selectedByCommand,
        `bash-syntax:${file}`,
        `bash -n ${shellQuote(file)}`,
        "swarm-ready gate shell syntax",
        file,
      );
      addSelected(selectedByCommand, "swarm-ready", COMMANDS.swarmReady, "swarm-ready gate harness", file);
    }

    if (file === "scripts/test-selfhost.sh") {
      matched = true;
      reason(file, "selfhost-harness", "selfhost harness uses shell syntax plus focused selfhost coverage");
      addSelected(
        selectedByCommand,
        `bash-syntax:${file}`,
        `bash -n ${shellQuote(file)}`,
        "selfhost harness shell syntax",
        file,
      );
      addSelected(selectedByCommand, "selfhost", COMMANDS.selfhost, "selfhost harness", file);
    }

    if (file === "scripts/test-native-claspc.sh") {
      matched = true;
      reason(file, "native-claspc-harness", "native claspc harness uses shell syntax plus focused native compiler coverage");
      addSelected(
        selectedByCommand,
        `bash-syntax:${file}`,
        `bash -n ${shellQuote(file)}`,
        "native claspc harness shell syntax",
        file,
      );
      addSelected(selectedByCommand, "native-claspc", COMMANDS.nativeClaspc, "native claspc harness", file);
    }

    if (swarmPreflightScriptFiles.has(file)) {
      matched = true;
      reason(
        file,
        "swarm-preflight",
        "swarm launch preflight files use shell syntax plus the preflight-only admission fixture",
      );
      addSelected(
        selectedByCommand,
        `bash-syntax:${file}`,
        `bash -n ${shellQuote(file)}`,
        "swarm preflight shell syntax",
        file,
      );
      addSelected(selectedByCommand, "swarm-preflight", COMMANDS.swarmPreflight, "swarm launch preflight path", file);
      addSelected(selectedByCommand, "swarm-ready", COMMANDS.swarmReady, "swarm launch preflight structural gate", file);
    }

    if (swarmNativeSupervisorScriptFiles.has(file)) {
      matched = true;
      reason(
        file,
        "swarm-native-supervisor",
        "native supervisor launch files use shell syntax plus the focused Clasp supervisor launch fixture",
      );
      addSelected(
        selectedByCommand,
        `bash-syntax:${file}`,
        `bash -n ${shellQuote(file)}`,
        "swarm native supervisor shell syntax",
        file,
      );
      addSelected(
        selectedByCommand,
        "swarm-native-supervisor",
        COMMANDS.swarmNativeSupervisor,
        "swarm native supervisor launch path",
        file,
      );
      addSelected(selectedByCommand, "swarm-ready", COMMANDS.swarmReady, "swarm native supervisor structural gate", file);
    }

    if (swarmTaskManifestFiles.has(file) || swarmControlScriptFiles.has(file)) {
      matched = true;
      reason(
        file,
        "swarm-control",
        "swarm control-plane files use syntax checks plus focused task manifest and swarm-control coverage",
      );
      if (file.endsWith(".sh")) {
        addSelected(
          selectedByCommand,
          `bash-syntax:${file}`,
          `bash -n ${shellQuote(file)}`,
          "swarm control shell syntax",
          file,
        );
      }
      if (file.endsWith(".mjs")) {
        addSelected(
          selectedByCommand,
          `node-check:${file}`,
          `node --check ${shellQuote(file)}`,
          "swarm control node syntax",
          file,
        );
      }
      if (swarmTaskManifestFiles.has(file)) {
        addSelected(selectedByCommand, "task-manifest", COMMANDS.taskManifest, "swarm task manifest path", file);
      }
      addSelected(selectedByCommand, "swarm-control", COMMANDS.swarmControl, "swarm control-plane path", file);
    }

    if (isIterationSpeedEvidencePath || isNativeIncrementalGuardPath) {
      matched = true;
      reason(
        file,
        "native-incremental-guard",
        "iteration-speed evidence and guard changes use focused incremental cache guard coverage",
      );
      if (file.endsWith(".mjs")) {
        addSelected(
          selectedByCommand,
          `node-check:${file}`,
          `node --check ${shellQuote(file)}`,
          "native incremental guard node syntax",
          file,
        );
      }
      if (file.endsWith(".sh")) {
        addSelected(
          selectedByCommand,
          `bash-syntax:${file}`,
          `bash -n ${shellQuote(file)}`,
          "native incremental guard shell syntax",
          file,
        );
      }
      addSelected(
        selectedByCommand,
        "native-incremental-guard",
        COMMANDS.nativeIncrementalGuard,
        "native incremental guard regression",
        file,
      );
    }

    if (file === "scripts/measure-native-incremental.sh") {
      matched = true;
      reason(
        file,
        "native-incremental-measure",
        "incremental cache measurement uses shell syntax plus focused native CLI and selfhost scenarios",
      );
      addSelected(
        selectedByCommand,
        `bash-syntax:${file}`,
        `bash -n ${shellQuote(file)}`,
        "native incremental measurement shell syntax",
        file,
      );
      addSelected(
        selectedByCommand,
        "native-incremental-cli",
        COMMANDS.nativeIncrementalCli,
        "native incremental CLI cache scenario",
        file,
      );
      addSelected(
        selectedByCommand,
        "native-incremental-selfhost",
        COMMANDS.nativeIncrementalSelfhost,
        "selfhost incremental cache scenario",
        file,
      );
      addSelected(
        selectedByCommand,
        "native-incremental-compiler-module",
        COMMANDS.nativeIncrementalCompilerModule,
        "large compiler-module incremental cache scenario",
        file,
      );
    }

    if (isManagedJobSafetyPath) {
      matched = true;
      reason(
        file,
        "managed-job-safety",
        "managed job launch/stop guardrails use shell syntax plus focused managed-job and ready-gate coverage",
      );
      addSelected(
        selectedByCommand,
        `bash-syntax:${file}`,
        `bash -n ${shellQuote(file)}`,
        "managed job safety shell syntax",
        file,
      );
      addSelected(selectedByCommand, "managed-job", COMMANDS.managedJob, "managed job safety regression", file);
      addSelected(
        selectedByCommand,
        "generated-state-cleanup",
        COMMANDS.generatedStateCleanup,
        "generated state cleanup regression",
        file,
      );
      addSelected(selectedByCommand, "swarm-ready", COMMANDS.swarmReady, "managed job safety structural gate", file);
    }

    if (isResolveClaspcSafetyPath) {
      matched = true;
      reason(
        file,
        "resolve-claspc-safety",
        "claspc resolver rebuild guardrails use shell syntax plus focused fake-cargo managed-build coverage",
      );
      addSelected(
        selectedByCommand,
        `bash-syntax:${file}`,
        `bash -n ${shellQuote(file)}`,
        "resolve-claspc safety shell syntax",
        file,
      );
      addSelected(
        selectedByCommand,
        "resolve-claspc",
        COMMANDS.resolveClaspc,
        "resolve-claspc managed rebuild regression",
        file,
      );
      addSelected(selectedByCommand, "swarm-ready", COMMANDS.swarmReady, "resolve-claspc safety structural gate", file);
    }

    if (isGeneratedStateIgnorePath) {
      matched = true;
      reason(
        file,
        "generated-state-ignore",
        "generated-state ignore changes use focused cleanup and structural ready-gate coverage",
      );
      addSelected(
        selectedByCommand,
        "generated-state-cleanup",
        COMMANDS.generatedStateCleanup,
        "generated-state ignore regression",
        file,
      );
      addSelected(selectedByCommand, "swarm-ready", COMMANDS.swarmReady, "generated-state ignore structural gate", file);
    }

    if (file === "scripts/test-swarm-ready-benchmark.sh") {
      matched = true;
      reason(file, "swarm-ready-benchmark-harness", "swarm-ready benchmark uses shell syntax plus focused native runtime coverage");
      addSelected(
        selectedByCommand,
        `bash-syntax:${file}`,
        `bash -n ${shellQuote(file)}`,
        "swarm-ready benchmark shell syntax",
        file,
      );
      addSelected(
        selectedByCommand,
        "swarm-ready-benchmark",
        COMMANDS.swarmReadyBenchmark,
        "swarm-ready benchmark harness",
        file,
      );
    }

    if (file === "scripts/test-swarm-capability-audit.sh") {
      matched = true;
      reason(file, "swarm-capability-audit-harness", "swarm capability audit harness uses shell syntax plus focused lightweight audit coverage");
      addSelected(
        selectedByCommand,
        `bash-syntax:${file}`,
        `bash -n ${shellQuote(file)}`,
        "swarm capability audit shell syntax",
        file,
      );
      addSelected(selectedByCommand, "swarm-ready", COMMANDS.swarmReady, "swarm capability audit harness", file);
      addSelected(
        selectedByCommand,
        "swarm-capability-audit",
        COMMANDS.swarmCapabilityAudit,
        "swarm capability audit harness",
        file,
      );
    }

    if (file === "scripts/test-agent-command-template.sh") {
      matched = true;
      reason(file, "agent-command-template-harness", "agent command template harness uses shell syntax plus focused local agent prompt coverage");
      addSelected(
        selectedByCommand,
        `bash-syntax:${file}`,
        `bash -n ${shellQuote(file)}`,
        "agent command template shell syntax",
        file,
      );
      addSelected(
        selectedByCommand,
        "agent-command-template",
        COMMANDS.agentCommandTemplate,
        "agent command template harness",
        file,
      );
    }

    if (isAgentBackendStaticTestPath) {
      matched = true;
      reason(file, "agent-backend-static-test", "agent backend static contract uses shell syntax plus standalone backend policy coverage");
      addSelected(
        selectedByCommand,
        `bash-syntax:${file}`,
        `bash -n ${shellQuote(file)}`,
        "agent backend static shell syntax",
        file,
      );
      addSelected(
        selectedByCommand,
        "agent-backend-static",
        COMMANDS.agentBackendStatic,
        "agent backend static contract",
        file,
      );
      addSelected(selectedByCommand, "swarm-ready", COMMANDS.swarmReady, "agent backend static contract", file);
    }

    if (isAgentErgonomicsPath) {
      matched = true;
      reason(
        file,
        "agent-ergonomics",
        "agent ergonomics helpers use focused Result/workspace/process coverage plus the structural swarm gate",
      );
      if (file.endsWith(".sh")) {
        addSelected(
          selectedByCommand,
          `bash-syntax:${file}`,
          `bash -n ${shellQuote(file)}`,
          "agent ergonomics shell syntax",
          file,
        );
      }
      addSelected(
        selectedByCommand,
        "agent-ergonomics",
        COMMANDS.agentErgonomics,
        "agent ergonomics helper contract",
        file,
      );
      addSelected(selectedByCommand, "swarm-ready", COMMANDS.swarmReady, "agent ergonomics helper contract", file);
    }

    if (file === "scripts/test-feedback-loop-resume.sh") {
      matched = true;
      reason(file, "feedback-loop-resume-harness", "feedback-loop resume harness uses shell syntax plus its focused smoke split");
      addSelected(
        selectedByCommand,
        `bash-syntax:${file}`,
        `bash -n ${shellQuote(file)}`,
        "feedback-loop resume shell syntax",
        file,
      );
      addSelected(selectedByCommand, "feedback-resume:smoke", COMMANDS.feedbackResumeSmoke, "feedback-loop resume harness", file);
    }

    if (file === "scripts/test-feedback-loop-routing.sh") {
      matched = true;
      reason(file, "feedback-loop-routing-harness", "feedback-loop routing harness uses shell syntax plus the lightweight ordinary-Clasp selector probe");
      addSelected(
        selectedByCommand,
        `bash-syntax:${file}`,
        `bash -n ${shellQuote(file)}`,
        "feedback-loop routing shell syntax",
        file,
      );
      addSelected(selectedByCommand, "feedback-loop-routing", COMMANDS.feedbackLoopRouting, "feedback-loop routing harness", file);
    }

    if (file === "scripts/test-monitored-step.sh") {
      matched = true;
      reason(file, "monitored-step-harness", "monitored step harness uses shell syntax plus focused process primitive coverage");
      addSelected(
        selectedByCommand,
        `bash-syntax:${file}`,
        `bash -n ${shellQuote(file)}`,
        "monitored step shell syntax",
        file,
      );
      addSelected(selectedByCommand, "runtime-slice:process", COMMANDS.runtimeSliceProcess, "monitored step harness", file);
    }

    if (file === "scripts/test-monitored-run-log.sh") {
      matched = true;
      reason(file, "monitored-run-log-harness", "monitored run-log harness uses shell syntax plus focused durable process log coverage");
      addSelected(
        selectedByCommand,
        `bash-syntax:${file}`,
        `bash -n ${shellQuote(file)}`,
        "monitored run-log shell syntax",
        file,
      );
      addSelected(selectedByCommand, "runtime-slice:process", COMMANDS.runtimeSliceProcess, "monitored run-log harness", file);
    }

    if (file === "scripts/test-monitored-loop.sh") {
      matched = true;
      reason(file, "monitored-loop-harness", "monitored loop harness uses shell syntax plus timeout/cancel coverage");
      addSelected(
        selectedByCommand,
        `bash-syntax:${file}`,
        `bash -n ${shellQuote(file)}`,
        "monitored loop shell syntax",
        file,
      );
      addSelected(selectedByCommand, "monitored-loop", COMMANDS.monitoredLoop, "monitored loop harness", file);
      addSelected(selectedByCommand, "runtime-slice:managed-loop", COMMANDS.runtimeSliceManagedLoop, "monitored loop harness", file);
    }

    if (file === "scripts/test-monitored-workflow.sh") {
      matched = true;
      reason(file, "monitored-workflow-harness", "monitored workflow harness uses shell syntax plus ordinary workflow coverage");
      addSelected(
        selectedByCommand,
        `bash-syntax:${file}`,
        `bash -n ${shellQuote(file)}`,
        "monitored workflow shell syntax",
        file,
      );
      addSelected(selectedByCommand, "runtime-slice:workflow", COMMANDS.runtimeSliceWorkflow, "monitored workflow harness", file);
    }

    if (file === "scripts/test-codex-loop-program.sh") {
      matched = true;
      reason(file, "codex-loop-program-harness", "ordinary Codex loop harness uses shell syntax plus direct Codex process coverage");
      addSelected(
        selectedByCommand,
        `bash-syntax:${file}`,
        `bash -n ${shellQuote(file)}`,
        "ordinary Codex loop shell syntax",
        file,
      );
      addSelected(selectedByCommand, "runtime-slice:codex-loop", COMMANDS.runtimeSliceCodexLoop, "ordinary Codex loop harness", file);
    }

    if (file === "scripts/test-host-runtime.sh") {
      matched = true;
      reason(file, "host-runtime-harness", "host runtime harness uses shell syntax plus focused ordinary host API coverage");
      addSelected(
        selectedByCommand,
        `bash-syntax:${file}`,
        `bash -n ${shellQuote(file)}`,
        "host runtime shell syntax",
        file,
      );
      addSelected(selectedByCommand, "host-runtime", COMMANDS.hostRuntime, "host runtime harness", file);
    }

    if (file === "scripts/test-safe-workspace.sh") {
      matched = true;
      reason(file, "safe-workspace-harness", "safe workspace harness uses shell syntax plus ordinary-program workspace API coverage");
      addSelected(
        selectedByCommand,
        `bash-syntax:${file}`,
        `bash -n ${shellQuote(file)}`,
        "safe workspace shell syntax",
        file,
      );
      addSelected(selectedByCommand, "safe-workspace-static", COMMANDS.safeWorkspaceStatic, "safe workspace host-binding contract", file);
      addSelected(selectedByCommand, "runtime-slice:workspace", COMMANDS.runtimeSliceWorkspace, "safe workspace harness", file);
    }

    if (isSafeWorkspaceStaticTestPath) {
      matched = true;
      reason(file, "safe-workspace-static-test", "safe workspace static contract uses shell syntax plus fast host-binding coverage");
      addSelected(
        selectedByCommand,
        `bash-syntax:${file}`,
        `bash -n ${shellQuote(file)}`,
        "safe workspace static shell syntax",
        file,
      );
      addSelected(selectedByCommand, "safe-workspace-static", COMMANDS.safeWorkspaceStatic, "safe workspace static contract", file);
      addSelected(selectedByCommand, "swarm-ready", COMMANDS.swarmReady, "safe workspace static contract", file);
    }

    if (file === "scripts/test-safe-subprocess.sh") {
      matched = true;
      reason(file, "safe-subprocess-harness", "safe subprocess harness uses shell syntax plus ordinary-program process API coverage");
      addSelected(
        selectedByCommand,
        `bash-syntax:${file}`,
        `bash -n ${shellQuote(file)}`,
        "safe subprocess shell syntax",
        file,
      );
      addSelected(selectedByCommand, "runtime-slice:process", COMMANDS.runtimeSliceProcess, "safe subprocess harness", file);
    }

    if (file === "scripts/test-swarm-native-managed-loop.sh") {
      matched = true;
      reason(file, "managed-loop-harness", "managed-loop harness uses shell syntax plus focused native control-plane coverage");
      addSelected(
        selectedByCommand,
        `bash-syntax:${file}`,
        `bash -n ${shellQuote(file)}`,
        "managed loop shell syntax",
        file,
      );
      addSelected(selectedByCommand, "runtime-slice:managed-loop", COMMANDS.runtimeSliceManagedLoop, "managed loop harness", file);
    }

    if (file === "scripts/test-swarm-native-feedback-loop.sh") {
      matched = true;
      reason(file, "swarm-feedback-loop-harness", "FeedbackLoop harness uses shell syntax plus focused ordinary-program native swarm coverage");
      addSelected(
        selectedByCommand,
        `bash-syntax:${file}`,
        `bash -n ${shellQuote(file)}`,
        "swarm feedback-loop shell syntax",
        file,
      );
      addSelected(selectedByCommand, "runtime-slice:swarm-feedback-loop", COMMANDS.runtimeSliceSwarmFeedbackLoop, "swarm feedback-loop harness", file);
    }

    if (isRuntimeSliceVerificationScript) {
      matched = true;
      reason(file, "runtime-slice-verification-script", "runtime slice verifier uses shell syntax plus focused fake-harness smoke coverage");
      if (file.endsWith(".sh")) {
        addSelected(
          selectedByCommand,
          `bash-syntax:${file}`,
          `bash -n ${shellQuote(file)}`,
          "runtime slice verification shell syntax",
          file,
        );
      }
      addSelected(
        selectedByCommand,
        "runtime-slice-regression",
        COMMANDS.runtimeSliceRegression,
        "runtime slice verifier regression",
        file,
      );
    } else if (isCompilerSliceVerificationScript) {
      matched = true;
      reason(file, "compiler-slice-verification-script", "compiler slice verifier uses shell syntax plus focused fake-claspc smoke coverage");
      if (file.endsWith(".sh")) {
        addSelected(
          selectedByCommand,
          `bash-syntax:${file}`,
          `bash -n ${shellQuote(file)}`,
          "compiler slice verification shell syntax",
          file,
        );
      }
      addSelected(
        selectedByCommand,
        "compiler-slice-regression",
        COMMANDS.compilerSliceRegression,
        "compiler slice verifier regression",
        file,
      );
    } else if (isSourceNativeVerifyScript) {
      matched = true;
      reason(
        file,
        "selfhost-native-verify-script",
        "selfhost native verifier uses shell syntax plus focused fast/full mode split coverage",
      );
      addSelected(
        selectedByCommand,
        `bash-syntax:${file}`,
        `bash -n ${shellQuote(file)}`,
        "selfhost native verifier shell syntax",
        file,
      );
      addSelected(
        selectedByCommand,
        "selfhost-verify-mode-split",
        COMMANDS.selfhostVerifyModeSplit,
        "selfhost native verifier mode regression",
        file,
      );
    } else if (file === "scripts/test-verify-all-smoke.sh") {
      matched = true;
      reason(file, "verify-all-smoke-script", "verify-all smoke harness uses shell syntax plus direct fast-verifier contract coverage");
      addSelected(
        selectedByCommand,
        `bash-syntax:${file}`,
        `bash -n ${shellQuote(file)}`,
        "verify-all smoke shell syntax",
        file,
      );
      addSelected(
        selectedByCommand,
        "verify-all-smoke",
        COMMANDS.verifyAllSmoke,
        "verify-all smoke contract",
        file,
      );
    } else if (isVerificationScript(file)) {
      matched = true;
      reason(file, "verification-script", "verification script path uses syntax and regression coverage");
      if (file.endsWith(".sh")) {
        addSelected(
          selectedByCommand,
          `bash-syntax:${file}`,
          `bash -n ${shellQuote(file)}`,
          "verification shell syntax",
          file,
        );
      }
      if (file === "scripts/verify-affected.mjs") {
        addSelected(selectedByCommand, "affected-node-check", COMMANDS.affectedNodeCheck, "affected verifier node syntax", file);
      }
      if (file.includes("verify-affected")) {
        addSelected(selectedByCommand, "verify-affected-regression", COMMANDS.verifyAffectedRegression, "affected verifier regression", file);
      } else {
        addSelected(selectedByCommand, "verify-all-regression", COMMANDS.verifyAllRegression, "verification regression", file);
      }
    }

    if (!matched) {
      unmatchedFiles.push(file);
      reason(file, "unknown", "no focused route matched this path");
    }
  }

  let verificationFallbackMode = "none";
  if (changedFiles.length === 0) {
    if (inputFallbackMode === "ignored-input") {
      verificationFallbackMode = "ignored-input";
    } else {
      verificationFallbackMode = inputFallbackMode === "git-unavailable" ? "git-unavailable-empty-input" : "empty-input";
      addSelected(selectedByCommand, "verify-fast", COMMANDS.verifyFast, "empty or unavailable changed-file input", "");
    }
  } else if (unmatchedFiles.length > 0) {
    verificationFallbackMode = "unknown-path";
    for (const file of unmatchedFiles) {
      addSelected(selectedByCommand, "verify-fast", COMMANDS.verifyFast, "unknown changed-file fallback", file);
    }
  }

  return {
    selectedCommands: Array.from(selectedByCommand.values()),
    routingReasons,
    unmatchedFiles,
    verificationFallbackMode,
    usedVerifyFastFallback: verificationFallbackMode !== "none" && verificationFallbackMode !== "ignored-input",
  };
}

function runCommand(commandRecord) {
  const startedAtMs = nowMs();
  const result = spawnSync(commandRecord.command, {
    cwd: projectRoot,
    env: process.env,
    encoding: "utf8",
    shell: true,
    maxBuffer: 10 * 1024 * 1024,
  });
  const endedAtMs = nowMs();
  const exitStatus = result.status === null ? 127 : result.status;
  return {
    id: commandRecord.id,
    command: commandRecord.command,
    resourceClass: commandRecord.resourceClass,
    oomRisk: commandRecord.oomRisk,
    requiresManagedGuard: commandRecord.requiresManagedGuard,
    executionAdvice: commandRecord.executionAdvice,
    compilerStateAccess: commandRecord.compilerStateAccess,
    reasons: commandRecord.reasons,
    matchedFiles: commandRecord.matchedFiles,
    exitStatus,
    signal: result.signal || null,
    startedAtMs,
    endedAtMs,
    elapsedMs: Math.max(0, endedAtMs - startedAtMs),
    stdoutTail: tailText(result.stdout || ""),
    stderrTail: tailText(result.stderr || ""),
    error: result.error ? result.error.message : "",
  };
}

function writeReport(report, reportJson) {
  const text = `${JSON.stringify(report, null, 2)}\n`;
  if (reportJson) {
    const reportPath = path.resolve(projectRoot, reportJson);
    fs.mkdirSync(path.dirname(reportPath), { recursive: true });
    fs.writeFileSync(reportPath, text);
  }
  process.stdout.write(text);
}

function buildErrorReport(message) {
  const timestamp = nowMs();
  return {
    schemaVersion: 1,
    projectRoot,
    inputSources: [],
    inputFallbackMode: "argument-error",
    usedGitFallback: false,
    changedFiles: [],
    semanticContextArtifacts: [],
    semanticContextByChangedFile: [],
    selectedCommands: [],
    commandResourceSummary: buildCommandResourceSummary([]),
    affectedVerificationLaunchPolicy: buildAffectedVerificationLaunchPolicy(buildCommandResourceSummary([])),
    routingReasons: [],
    unmatchedFiles: [],
    verificationFallbackMode: "none",
    usedVerifyFastFallback: false,
    planOnly: false,
    planExplanations: [],
    commandRecords: [],
    commandCount: 0,
    executedCommandCount: 0,
    startedAtMs: timestamp,
    endedAtMs: timestamp,
    elapsedMs: 0,
    exitStatus: 2,
    finalVerdict: "failed",
    error: message,
    usage: usage(),
  };
}

function main() {
  const startedAtMs = nowMs();
  const args = parseArgs(process.argv.slice(2));
  const inputSources = [];
  const explicitFiles = [];

  if (args.changedFiles.length > 0) {
    inputSources.push({ kind: "argv", option: "--changed-file", count: args.changedFiles.length });
    explicitFiles.push(...args.changedFiles);
  }

  const filesFrom = readFilesFrom(args.filesFrom);
  inputSources.push(...filesFrom.sources);
  explicitFiles.push(...filesFrom.files);

  const envFiles = splitEnvFiles(process.env.CLASP_VERIFY_CHANGED_FILES || "");
  if (envFiles.length > 0) {
    inputSources.push({ kind: "env", variable: "CLASP_VERIFY_CHANGED_FILES", count: envFiles.length });
    explicitFiles.push(...envFiles);
  }

  let inputFallbackMode = "none";
  let rawChangedFiles = explicitFiles;
  let usedGitFallback = false;
  if (explicitFiles.length === 0) {
    usedGitFallback = true;
    const gitFallback = collectGitFallback();
    inputSources.push(gitFallback.source);
    rawChangedFiles = gitFallback.files;
    inputFallbackMode = gitFallback.inputFallbackMode;
  }

  const normalizedChangedFiles = uniqueNormalized(rawChangedFiles);
  const changedFiles = normalizedChangedFiles.filter((file) => !isIgnoredChangedFile(file));
  if (normalizedChangedFiles.length > 0 && changedFiles.length === 0) {
    inputFallbackMode = "ignored-input";
  }
  const semanticContexts = collectSemanticContexts(changedFiles);
  const routePlan = routeChangedFiles(changedFiles, inputFallbackMode);
  const commandResourceSummary = buildCommandResourceSummary(routePlan.selectedCommands);
  const affectedVerificationLaunchPolicy = buildAffectedVerificationLaunchPolicy(commandResourceSummary);
  const planExplanations = args.planOnly ? buildPlanExplanations(changedFiles, routePlan, semanticContexts) : [];
  const commandRecords = [];
  let exitStatus = 0;

  if (!args.planOnly) {
    for (const selectedCommand of routePlan.selectedCommands) {
      const record = runCommand(selectedCommand);
      commandRecords.push(record);
      if (record.exitStatus !== 0) {
        exitStatus = record.exitStatus || 1;
        break;
      }
    }
  }

  const endedAtMs = nowMs();
  const report = {
    schemaVersion: 1,
    projectRoot,
    inputSources,
    inputFallbackMode,
    usedGitFallback,
    changedFiles,
    semanticContextArtifacts: semanticContexts.artifacts,
    semanticContextByChangedFile: semanticContexts.byChangedFile,
    selectedCommands: routePlan.selectedCommands,
    commandResourceSummary,
    affectedVerificationLaunchPolicy,
    routingReasons: routePlan.routingReasons,
    unmatchedFiles: routePlan.unmatchedFiles,
    verificationFallbackMode: routePlan.verificationFallbackMode,
    usedVerifyFastFallback: routePlan.usedVerifyFastFallback,
    planOnly: args.planOnly,
    planExplanations,
    commandRecords,
    commandCount: routePlan.selectedCommands.length,
    executedCommandCount: commandRecords.length,
    startedAtMs,
    endedAtMs,
    elapsedMs: Math.max(0, endedAtMs - startedAtMs),
    exitStatus,
    finalVerdict: args.planOnly ? "planned" : exitStatus === 0 ? "passed" : "failed",
  };

  writeReport(report, args.reportJson);
  process.exit(args.planOnly ? 0 : exitStatus);
}

try {
  main();
} catch (error) {
  const message = error instanceof Error ? error.message : String(error);
  process.stdout.write(`${JSON.stringify(buildErrorReport(message), null, 2)}\n`);
  process.exit(2);
}
