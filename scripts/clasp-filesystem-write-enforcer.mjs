#!/usr/bin/env node
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const sourcePath = path.join(scriptDir, "clasp-filesystem-write-guard.c");

function fail(message, status = 2) {
  process.stderr.write(`clasp-filesystem-write-enforcer: ${message}\n`);
  process.exit(status);
}

function usage() {
  return [
    "usage: clasp-filesystem-write-enforcer.mjs --workspace-roots-json JSON [--readonly-roots-json JSON] --cwd PATH --command-json JSON -- COMMAND...",
    "",
    "Host-side filesystem write mediation backend for Clasp swarm task runs.",
    "It compiles and injects scripts/clasp-filesystem-write-guard.c with LD_PRELOAD",
    "and permits write/delete/rename operations only under the configured workspace roots.",
    "Read-only roots are forwarded to kernel backends as dependency mounts.",
  ].join("\n");
}

function parseArgs(argv) {
  const options = {
    workspaceRootsJson: "",
    readonlyRootsJson: "",
    cwd: "",
    commandJson: "",
    command: [],
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--help" || arg === "-h") {
      process.stdout.write(`${usage()}\n`);
      process.exit(0);
    }
    if (arg === "--") {
      options.command = argv.slice(index + 1);
      return options;
    }
    if (arg === "--workspace-roots-json") {
      index += 1;
      options.workspaceRootsJson = argv[index] || "";
      continue;
    }
    if (arg === "--readonly-roots-json") {
      index += 1;
      options.readonlyRootsJson = argv[index] || "";
      continue;
    }
    if (arg === "--cwd") {
      index += 1;
      options.cwd = argv[index] || "";
      continue;
    }
    if (arg === "--command-json") {
      index += 1;
      options.commandJson = argv[index] || "";
      continue;
    }
    fail(`unexpected argument: ${arg}`);
  }

  return options;
}

function decodeJsonArray(raw, label) {
  let decoded;
  try {
    decoded = JSON.parse(raw);
  } catch (error) {
    fail(`failed to decode ${label}: ${error instanceof Error ? error.message : String(error)}`);
  }
  if (!Array.isArray(decoded)) {
    fail(`${label} must be a JSON array`);
  }
  if (!decoded.every((entry) => typeof entry === "string")) {
    fail(`${label} must contain only strings`);
  }
  return decoded;
}

function validateCwd(cwd) {
  if (!cwd) {
    fail("--cwd is required");
  }
  let stat;
  try {
    stat = fs.statSync(cwd);
  } catch (error) {
    fail(`--cwd is not readable: ${error instanceof Error ? error.message : String(error)}`);
  }
  if (!stat.isDirectory()) {
    fail("--cwd must be a directory");
  }
}

function normalizeWorkspaceRoots(values) {
  const result = [];
  const seen = new Set();
  for (const value of values) {
    if (!value || value.trim() === "") {
      fail("workspace root must be non-empty");
    }
    let resolved;
    try {
      resolved = fs.realpathSync(value);
    } catch (error) {
      fail(`workspace root is not readable: ${value}: ${error instanceof Error ? error.message : String(error)}`);
    }
    let stat;
    try {
      stat = fs.statSync(resolved);
    } catch (error) {
      fail(`workspace root is not statable: ${resolved}: ${error instanceof Error ? error.message : String(error)}`);
    }
    if (!stat.isDirectory()) {
      fail(`workspace root must be a directory: ${resolved}`);
    }
    if (!seen.has(resolved)) {
      seen.add(resolved);
      result.push(resolved);
    }
  }
  if (result.length === 0) {
    fail("filesystem write mediation requires at least one workspace root");
  }
  return result;
}

function cacheDir() {
  return (
    process.env.CLASP_SWARM_FILESYSTEM_WRITE_GUARD_CACHE_DIR ||
    path.join(scriptDir, "..", ".clasp-verify", "filesystem-write")
  );
}

function guardOutputPath() {
  const platform = `${process.platform}-${process.arch}`;
  return path.join(cacheDir(), `clasp-filesystem-write-guard-${platform}.so`);
}

function needsRebuild(outputPath) {
  if (process.env.CLASP_SWARM_FILESYSTEM_WRITE_REBUILD_GUARD === "1") {
    return true;
  }
  try {
    const sourceStat = fs.statSync(sourcePath);
    const outputStat = fs.statSync(outputPath);
    return outputStat.mtimeMs < sourceStat.mtimeMs;
  } catch {
    return true;
  }
}

function ensureGuard() {
  if (process.platform !== "linux") {
    fail("LD_PRELOAD filesystem write backend is currently supported only on Linux", 126);
  }
  if (process.env.CLASP_SWARM_FILESYSTEM_WRITE_GUARD_SO) {
    return process.env.CLASP_SWARM_FILESYSTEM_WRITE_GUARD_SO;
  }

  const outputPath = guardOutputPath();
  if (!needsRebuild(outputPath)) {
    return outputPath;
  }

  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  const cc = process.env.CC || "cc";
  const tempPath = `${outputPath}.${process.pid}.${Date.now()}.tmp`;
  const result = spawnSync(cc, ["-shared", "-fPIC", "-O2", "-Wall", "-Wextra", "-o", tempPath, sourcePath], {
    encoding: "utf8",
    maxBuffer: 1024 * 1024,
  });
  if (result.error) {
    fail(`failed to launch C compiler for filesystem write guard: ${result.error.message}`, 126);
  }
  if (result.status !== 0) {
    fail(`failed to build filesystem write guard with ${cc}: ${(result.stderr || result.stdout || "").trim()}`, 126);
  }
  fs.renameSync(tempPath, outputPath);
  return outputPath;
}

function writeAuditPath(envName, value) {
  const target = process.env[envName] || "";
  if (!target) {
    return;
  }
  fs.writeFileSync(target, value);
}

function backendCommandFromEnv() {
  const raw = process.env.CLASP_SWARM_FILESYSTEM_WRITE_BACKEND_JSON || "";
  if (!raw.trim()) {
    return [];
  }
  const command = decodeJsonArray(raw, "CLASP_SWARM_FILESYSTEM_WRITE_BACKEND_JSON");
  if (command.length === 0) {
    fail("CLASP_SWARM_FILESYSTEM_WRITE_BACKEND_JSON must be non-empty");
  }
  if (command.some((part) => part.length === 0)) {
    fail("CLASP_SWARM_FILESYSTEM_WRITE_BACKEND_JSON must not contain empty command parts");
  }
  return command;
}

const options = parseArgs(process.argv.slice(2));
validateCwd(options.cwd);
const workspaceRoots = normalizeWorkspaceRoots(decodeJsonArray(options.workspaceRootsJson, "--workspace-roots-json"));
const readonlyRoots = options.readonlyRootsJson.trim()
  ? decodeJsonArray(options.readonlyRootsJson, "--readonly-roots-json")
  : [];
const declaredCommand = decodeJsonArray(options.commandJson, "--command-json");
if (declaredCommand.length === 0) {
  fail("--command-json must describe a non-empty command");
}
if (JSON.stringify(declaredCommand) !== JSON.stringify(options.command)) {
  fail("--command-json must match the command after --");
}

const backendCommand = backendCommandFromEnv();
if (backendCommand.length > 0) {
  writeAuditPath("CLASP_SWARM_FILESYSTEM_WRITE_AUDIT_ROOTS_PATH", JSON.stringify(workspaceRoots));
  writeAuditPath("CLASP_SWARM_FILESYSTEM_WRITE_AUDIT_COMMAND_PATH", JSON.stringify(declaredCommand));
  const backendArgs = [
    ...backendCommand.slice(1),
    "--workspace-roots-json",
    JSON.stringify(workspaceRoots),
    "--readonly-roots-json",
    JSON.stringify(readonlyRoots),
    "--cwd",
    options.cwd,
    "--command-json",
    JSON.stringify(declaredCommand),
    "--",
    ...options.command,
  ];
  const backendResult = spawnSync(backendCommand[0], backendArgs, {
    cwd: options.cwd,
    env: process.env,
    stdio: "inherit",
  });
  if (backendResult.error) {
    fail(`failed to launch filesystem write backend: ${backendResult.error.message}`, 127);
  }
  if (backendResult.signal) {
    fail(`filesystem write backend terminated by signal ${backendResult.signal}`, 128);
  }
  process.exit(backendResult.status ?? 127);
}

const guardPath = ensureGuard();
writeAuditPath("CLASP_SWARM_FILESYSTEM_WRITE_AUDIT_ROOTS_PATH", JSON.stringify(workspaceRoots));
writeAuditPath("CLASP_SWARM_FILESYSTEM_WRITE_AUDIT_COMMAND_PATH", JSON.stringify(declaredCommand));

const childEnv = {
  ...process.env,
  CLASP_FILESYSTEM_WRITE_ALLOWED_ROOTS: workspaceRoots.join(";"),
  CLASP_FILESYSTEM_READONLY_ROOTS: readonlyRoots.join(";"),
  CLASP_FILESYSTEM_WRITE_GUARD: "1",
  LD_PRELOAD: process.env.LD_PRELOAD ? `${guardPath}:${process.env.LD_PRELOAD}` : guardPath,
};

const result = spawnSync(options.command[0], options.command.slice(1), {
  cwd: options.cwd,
  env: childEnv,
  stdio: "inherit",
});

if (result.error) {
  fail(`failed to launch command with filesystem write guard: ${result.error.message}`, 127);
}
if (result.signal) {
  fail(`guarded command terminated by signal ${result.signal}`, 128);
}
process.exit(result.status ?? 127);
