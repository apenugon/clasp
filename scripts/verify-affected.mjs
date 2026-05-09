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

const COMMANDS = {
  verifyFast: "bash scripts/verify-fast.sh",
  selfhost: "bash scripts/test-selfhost.sh",
  sourceVerify: "bash src/scripts/verify.sh",
  nativeClaspc: "bash scripts/test-native-claspc.sh",
  nativeRuntime: "bash scripts/test-native-runtime.sh",
  swarmReady: "bash scripts/test-swarm-ready-gate.sh",
  goalManagerFast: "bash scripts/test-goal-manager-fast.sh",
  feedbackResume: "bash scripts/test-feedback-loop-resume.sh",
  verifyAllRegression: "bash scripts/test-verify-all.sh",
  verifyAffectedRegression: "bash scripts/test-verify-affected.sh",
  benchmarkTaskPrep: "bash benchmarks/test-task-prep.sh",
  affectedNodeCheck: "node --check scripts/verify-affected.mjs",
};

const contextArtifactLimitPerFile = parsePositiveInt(process.env.CLASP_VERIFY_AFFECTED_CONTEXT_ARTIFACT_LIMIT, 4);
const planSurfaceLimit = parsePositiveInt(process.env.CLASP_VERIFY_AFFECTED_PLAN_SURFACE_LIMIT, 12);

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

function addSelected(selectedByCommand, id, command, reason, file) {
  if (!selectedByCommand.has(command)) {
    selectedByCommand.set(command, {
      id,
      command,
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

function routeChangedFiles(changedFiles, inputFallbackMode) {
  const selectedByCommand = new Map();
  const routingReasons = [];
  const unmatchedFiles = [];

  function reason(file, route, detail) {
    routingReasons.push({ file, route, detail });
  }

  for (const file of changedFiles) {
    let matched = false;

    if (file.startsWith("src/")) {
      matched = true;
      reason(file, "source", "source/compiler path uses selfhost and hosted compiler verification");
      addSelected(selectedByCommand, "selfhost", COMMANDS.selfhost, "source/compiler path", file);
      addSelected(selectedByCommand, "source-verify", COMMANDS.sourceVerify, "source/compiler path", file);
    }

    const exampleVerifyCommand = isClaspSourceFile(file) ? exampleVerifyCommandForFile(file) : null;
    if (exampleVerifyCommand) {
      matched = true;
      reason(file, "clasp-app-flow", "Clasp example app source uses its scenario verifier for source check, compile, and app-flow behavior");
      addSelected(selectedByCommand, `example-app:${exampleVerifyCommand}`, exampleVerifyCommand, "Clasp app-flow path", file);
    }

    if (file.startsWith("runtime/")) {
      matched = true;
      reason(file, "runtime", "runtime path uses native runtime and native claspc coverage");
      addSelected(selectedByCommand, "native-runtime", COMMANDS.nativeRuntime, "runtime path", file);
      addSelected(selectedByCommand, "native-claspc", COMMANDS.nativeClaspc, "runtime path", file);
    }

    if (file.startsWith("examples/swarm-native/")) {
      matched = true;
      reason(file, "swarm-native", "native swarm example path uses native claspc and ready-gate coverage");
      addSelected(selectedByCommand, "native-claspc", COMMANDS.nativeClaspc, "swarm native path", file);
      addSelected(selectedByCommand, "swarm-ready", COMMANDS.swarmReady, "swarm native path", file);
    }

    if (file.startsWith("examples/feedback-loop/")) {
      matched = true;
      reason(file, "feedback-loop", "feedback-loop example path uses resume-loop regression coverage");
      addSelected(selectedByCommand, "feedback-resume", COMMANDS.feedbackResume, "feedback-loop path", file);
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

    if (file.startsWith("benchmarks/")) {
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

    if (isVerificationScript(file)) {
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
    verificationFallbackMode = inputFallbackMode === "git-unavailable" ? "git-unavailable-empty-input" : "empty-input";
    addSelected(selectedByCommand, "verify-fast", COMMANDS.verifyFast, "empty or unavailable changed-file input", "");
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
    usedVerifyFastFallback: verificationFallbackMode !== "none",
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

  const changedFiles = uniqueNormalized(rawChangedFiles);
  const semanticContexts = collectSemanticContexts(changedFiles);
  const routePlan = routeChangedFiles(changedFiles, inputFallbackMode);
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
