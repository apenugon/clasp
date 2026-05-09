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
    selectedCommands: [],
    routingReasons: [],
    unmatchedFiles: [],
    verificationFallbackMode: "none",
    usedVerifyFastFallback: false,
    planOnly: false,
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
  const routePlan = routeChangedFiles(changedFiles, inputFallbackMode);
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
    selectedCommands: routePlan.selectedCommands,
    routingReasons: routePlan.routingReasons,
    unmatchedFiles: routePlan.unmatchedFiles,
    verificationFallbackMode: routePlan.verificationFallbackMode,
    usedVerifyFastFallback: routePlan.usedVerifyFastFallback,
    planOnly: args.planOnly,
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
