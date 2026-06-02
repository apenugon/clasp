#!/usr/bin/env node
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const scriptPath = fileURLToPath(import.meta.url);

function fail(message, status = 2) {
  process.stderr.write(`clasp-filesystem-write-kernel-backend: ${message}\n`);
  process.exit(status);
}

function usage() {
  return [
    "usage: clasp-filesystem-write-kernel-backend.mjs --workspace-roots-json JSON [--readonly-roots-json JSON] --cwd PATH --command-json JSON -- COMMAND...",
    "",
    "Kernel-backed filesystem write mediator for Clasp swarm task runs.",
    "The child runs in a fresh user/mount namespace and chroot where only the",
    "configured workspace roots are bind-mounted read-write.",
    "Set CLASP_SWARM_FILESYSTEM_READONLY_ROOTS_JSON to a JSON array of",
    "dependency directories that should be bind-mounted read-only.",
    "This backend is intended for hostile/static/direct-syscall tools that cannot",
    "be trusted to honor LD_PRELOAD.",
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
    const stat = fs.statSync(resolved);
    if (!stat.isDirectory()) {
      fail(`workspace root must be a directory: ${resolved}`);
    }
    if (!seen.has(resolved)) {
      seen.add(resolved);
      result.push(resolved);
    }
  }
  if (result.length === 0) {
    fail("kernel filesystem mediation requires at least one workspace root");
  }
  return result;
}

function pathHasRootPrefix(value, root) {
  return value === root || value.startsWith(`${root}/`);
}

function normalizeReadOnlyRoots(values, workspaceRoots) {
  const result = [];
  const seen = new Set();
  for (const value of values) {
    if (!value || value.trim() === "") {
      fail("read-only root must be non-empty");
    }
    let resolved;
    try {
      resolved = fs.realpathSync(value);
    } catch (error) {
      fail(`read-only root is not readable: ${value}: ${error instanceof Error ? error.message : String(error)}`);
    }
    const stat = fs.statSync(resolved);
    if (!stat.isDirectory()) {
      fail(`read-only root must be a directory: ${resolved}`);
    }
    if (resolved === "/") {
      fail("read-only root must not be /");
    }
    if (workspaceRoots.some((root) => pathHasRootPrefix(root, resolved) || pathHasRootPrefix(resolved, root))) {
      fail(`read-only root must not overlap writable workspace roots: ${resolved}`);
    }
    if (!seen.has(resolved)) {
      seen.add(resolved);
      result.push(resolved);
    }
  }
  return result;
}

function readOnlyRootsFromConfig(readonlyRootsJson, workspaceRoots) {
  const raw = readonlyRootsJson || process.env.CLASP_SWARM_FILESYSTEM_READONLY_ROOTS_JSON || "";
  if (!raw.trim()) {
    return [];
  }
  return normalizeReadOnlyRoots(
    decodeJsonArray(raw, readonlyRootsJson ? "--readonly-roots-json" : "CLASP_SWARM_FILESYSTEM_READONLY_ROOTS_JSON"),
    workspaceRoots,
  );
}

function insideRootPath(root, absolutePath) {
  if (!absolutePath.startsWith("/")) {
    fail(`path must be absolute for kernel filesystem mediation: ${absolutePath}`);
  }
  return path.join(root, absolutePath.slice(1));
}

function runChecked(command, args, label) {
  const result = spawnSync(command, args, { encoding: "utf8", maxBuffer: 1024 * 1024 });
  if (result.error) {
    fail(`failed to launch ${label}: ${result.error.message}`, 126);
  }
  if (result.status !== 0) {
    const detail = (result.stderr || result.stdout || "").trim();
    fail(`${label} failed${detail ? `: ${detail}` : ""}`, 126);
  }
}

function bindWorkspaceRoot(sandboxRoot, workspaceRoot) {
  const target = insideRootPath(sandboxRoot, workspaceRoot);
  fs.mkdirSync(target, { recursive: true });
  runChecked("mount", ["--bind", workspaceRoot, target], `workspace bind mount ${workspaceRoot}`);
  runChecked("mount", ["-o", "remount,rw,bind", target], `workspace writable remount ${workspaceRoot}`);
}

function bindReadOnlyRoot(sandboxRoot, readOnlyRoot) {
  const target = insideRootPath(sandboxRoot, readOnlyRoot);
  fs.mkdirSync(target, { recursive: true });
  runChecked("mount", ["--bind", readOnlyRoot, target], `read-only dependency bind mount ${readOnlyRoot}`);
  runChecked("mount", ["-o", "remount,ro,bind", target], `read-only dependency remount ${readOnlyRoot}`);
}

async function runNamespaceChild(argv) {
  const configPath = argv[0] || "";
  if (!configPath) {
    fail("--namespace-child requires a config path");
  }
  const config = JSON.parse(fs.readFileSync(configPath, "utf8"));
  if (
    typeof config.sandboxRoot !== "string" ||
    typeof config.cwd !== "string" ||
    !Array.isArray(config.workspaceRoots) ||
    !Array.isArray(config.readOnlyRoots) ||
    !Array.isArray(config.command)
  ) {
    fail("namespace child config is invalid");
  }

  runChecked("mount", ["--make-rprivate", "/"], "private mount namespace setup");
  fs.mkdirSync(config.sandboxRoot, { recursive: true });
  for (const root of config.readOnlyRoots) {
    bindReadOnlyRoot(config.sandboxRoot, root);
  }
  for (const root of config.workspaceRoots) {
    bindWorkspaceRoot(config.sandboxRoot, root);
  }

  const childEnv = {
    ...process.env,
    CLASP_FILESYSTEM_WRITE_KERNEL_ISOLATED: "1",
    CLASP_FILESYSTEM_WRITE_ALLOWED_ROOTS: config.workspaceRoots.join(";"),
    CLASP_FILESYSTEM_READONLY_ROOTS: config.readOnlyRoots.join(";"),
  };
  delete childEnv.LD_PRELOAD;
  if (!config.workspaceRoots.some((root) => (childEnv.TMPDIR || "").startsWith(`${root}/`) || childEnv.TMPDIR === root)) {
    childEnv.TMPDIR = config.workspaceRoots[0];
  }

  const child = spawn("chroot", [config.sandboxRoot, ...config.command], {
    cwd: "/",
    env: childEnv,
    stdio: "inherit",
  });
  child.on("error", (error) => {
    fail(`failed to launch chrooted filesystem command: ${error.message}`, 127);
  });
  child.on("exit", (code, signal) => {
    if (signal) {
      fail(`kernel filesystem command terminated by signal ${signal}`, 128);
    }
    process.exit(code ?? 127);
  });
}

async function runHostBackend(argv) {
  if (process.platform !== "linux") {
    fail("kernel filesystem backend is currently supported only on Linux", 126);
  }
  const options = parseArgs(argv);
  validateCwd(options.cwd);
  const workspaceRoots = normalizeWorkspaceRoots(decodeJsonArray(options.workspaceRootsJson, "--workspace-roots-json"));
  const readOnlyRoots = readOnlyRootsFromConfig(options.readonlyRootsJson, workspaceRoots);
  const declaredCommand = decodeJsonArray(options.commandJson, "--command-json");
  if (declaredCommand.length === 0) {
    fail("--command-json must describe a non-empty command");
  }
  if (JSON.stringify(declaredCommand) !== JSON.stringify(options.command)) {
    fail("--command-json must match the command after --");
  }

  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "clasp-filesystem-write-kernel-"));
  try {
    const sandboxRoot = path.join(tempDir, "root");
    fs.mkdirSync(sandboxRoot, { recursive: true });
    const configPath = path.join(tempDir, "namespace-config.json");
    fs.writeFileSync(configPath, JSON.stringify({
      sandboxRoot,
      cwd: fs.realpathSync(options.cwd),
      command: declaredCommand,
      workspaceRoots,
      readOnlyRoots,
    }));

    const child = spawn(
      "unshare",
      ["-r", "-m", process.execPath, ...process.execArgv, scriptPath, "--namespace-child", configPath],
      {
        cwd: options.cwd,
        env: process.env,
        stdio: "inherit",
      },
    );
    child.on("error", (error) => {
      fs.rmSync(tempDir, { recursive: true, force: true });
      fail(`failed to launch unshare for kernel filesystem backend: ${error.message}`, 127);
    });
    child.on("exit", (code, signal) => {
      fs.rmSync(tempDir, { recursive: true, force: true });
      if (signal) {
        fail(`kernel filesystem backend terminated by signal ${signal}`, 128);
      }
      process.exit(code ?? 127);
    });
  } catch (error) {
    fs.rmSync(tempDir, { recursive: true, force: true });
    fail(`kernel filesystem backend failed: ${error instanceof Error ? error.message : String(error)}`, 126);
  }
}

if (process.argv[2] === "--namespace-child") {
  await runNamespaceChild(process.argv.slice(3));
} else {
  await runHostBackend(process.argv.slice(2));
}
