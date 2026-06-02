#!/usr/bin/env node
import dns from "node:dns/promises";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const sourcePath = path.join(scriptDir, "clasp-network-egress-guard.c");

function fail(message, status = 2) {
  process.stderr.write(`clasp-network-egress-backend: ${message}\n`);
  process.exit(status);
}

function usage() {
  return [
    "usage: clasp-network-egress-backend.mjs --network-access allowlisted --destinations-json JSON --cwd PATH --command-json JSON -- COMMAND...",
    "",
    "Host-side connect allowlist backend for Clasp swarm allowlisted network runs.",
    "It compiles and injects scripts/clasp-network-egress-guard.c with LD_PRELOAD",
    "and permits only resolved destination IP:port pairs before executing COMMAND.",
  ].join("\n");
}

function parseArgs(argv) {
  const options = {
    networkAccess: "",
    destinationsJson: "",
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
    if (arg === "--network-access") {
      index += 1;
      options.networkAccess = argv[index] || "";
      continue;
    }
    if (arg === "--destinations-json") {
      index += 1;
      options.destinationsJson = argv[index] || "";
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

function parseDestination(value) {
  const trimmed = value.trim();
  if (!trimmed) {
    fail("allowed network destination must be non-empty");
  }
  if (/\s/.test(trimmed)) {
    fail(`allowed network destination must not contain whitespace: ${trimmed}`);
  }

  let host = "";
  let portText = "";
  if (trimmed.startsWith("[")) {
    const closing = trimmed.indexOf("]");
    if (closing < 0 || trimmed.slice(closing + 1, closing + 2) !== ":") {
      fail(`allowed network destination must be host:port: ${trimmed}`);
    }
    host = trimmed.slice(1, closing);
    portText = trimmed.slice(closing + 2);
  } else {
    const separator = trimmed.lastIndexOf(":");
    if (separator <= 0 || separator === trimmed.length - 1 || trimmed.slice(0, separator).includes(":")) {
      fail(`allowed network destination must be host:port: ${trimmed}`);
    }
    host = trimmed.slice(0, separator);
    portText = trimmed.slice(separator + 1);
  }

  const port = Number.parseInt(portText, 10);
  if (!Number.isInteger(port) || String(port) !== portText || port < 1 || port > 65535) {
    fail(`allowed network destination port is out of range: ${trimmed}`);
  }
  if (!host) {
    fail(`allowed network destination host is empty: ${trimmed}`);
  }

  return { host: host.toLowerCase(), port, text: `${host.toLowerCase()}:${port}` };
}

function normalizeDestinations(values) {
  const result = [];
  const seen = new Set();
  for (const value of values) {
    const destination = parseDestination(value);
    if (!seen.has(destination.text)) {
      seen.add(destination.text);
      result.push(destination);
    }
  }
  if (result.length === 0) {
    fail("allowlisted network backend requires at least one destination");
  }
  return result;
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

function cacheDir() {
  return (
    process.env.CLASP_SWARM_NETWORK_EGRESS_CACHE_DIR ||
    path.join(scriptDir, "..", ".clasp-verify", "network-egress")
  );
}

function guardOutputPath() {
  const platform = `${process.platform}-${process.arch}`;
  return path.join(cacheDir(), `clasp-network-egress-guard-${platform}.so`);
}

function needsRebuild(outputPath) {
  if (process.env.CLASP_SWARM_NETWORK_EGRESS_REBUILD_GUARD === "1") {
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
    fail("LD_PRELOAD network egress backend is currently supported only on Linux", 126);
  }
  if (process.env.CLASP_SWARM_NETWORK_EGRESS_GUARD_SO) {
    return process.env.CLASP_SWARM_NETWORK_EGRESS_GUARD_SO;
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
    fail(`failed to launch C compiler for network guard: ${result.error.message}`, 126);
  }
  if (result.status !== 0) {
    fail(`failed to build network guard with ${cc}: ${(result.stderr || result.stdout || "").trim()}`, 126);
  }
  fs.renameSync(tempPath, outputPath);
  return outputPath;
}

async function resolveDestination(destination) {
  const ipFamily = net.isIP(destination.host);
  if (ipFamily === 4 || ipFamily === 6) {
    return [{ family: ipFamily, address: destination.host, port: destination.port }];
  }

  let addresses;
  try {
    addresses = await dns.lookup(destination.host, { all: true, verbatim: true });
  } catch (error) {
    fail(`failed to resolve allowed network destination ${destination.text}: ${error instanceof Error ? error.message : String(error)}`, 126);
  }
  if (!addresses || addresses.length === 0) {
    fail(`allowed network destination resolved no addresses: ${destination.text}`, 126);
  }
  return addresses.map((entry) => ({
    family: entry.family,
    address: entry.address,
    port: destination.port,
  }));
}

async function resolveAllowlist(destinations) {
  const seen = new Set();
  const records = [];
  for (const destination of destinations) {
    const resolved = await resolveDestination(destination);
    for (const record of resolved) {
      if (record.family !== 4 && record.family !== 6) {
        continue;
      }
      const key = `${record.family},${record.address},${record.port}`;
      if (!seen.has(key)) {
        seen.add(key);
        records.push(record);
      }
    }
  }
  if (records.length === 0) {
    fail("allowed network destinations produced an empty IP allowlist", 126);
  }
  return records;
}

function encodeAllowlist(records) {
  return records.map((record) => `${record.family},${record.address},${record.port}`).join(";");
}

function writeAuditPath(envName, value) {
  const target = process.env[envName] || "";
  if (!target) {
    return;
  }
  fs.writeFileSync(target, value);
}

const options = parseArgs(process.argv.slice(2));
if (options.networkAccess !== "allowlisted") {
  fail(`--network-access must be allowlisted, got ${options.networkAccess || "(missing)"}`);
}

validateCwd(options.cwd);
const destinations = normalizeDestinations(decodeJsonArray(options.destinationsJson, "--destinations-json"));
const declaredCommand = decodeJsonArray(options.commandJson, "--command-json");
if (declaredCommand.length === 0) {
  fail("--command-json must describe a non-empty command");
}
if (JSON.stringify(declaredCommand) !== JSON.stringify(options.command)) {
  fail("--command-json must match the command after --");
}

const guardPath = ensureGuard();
const allowlist = await resolveAllowlist(destinations);
const encodedAllowlist = encodeAllowlist(allowlist);
writeAuditPath("CLASP_SWARM_NETWORK_EGRESS_AUDIT_DESTINATIONS_PATH", JSON.stringify(destinations.map((destination) => destination.text)));
writeAuditPath("CLASP_SWARM_NETWORK_EGRESS_AUDIT_COMMAND_PATH", JSON.stringify(declaredCommand));
writeAuditPath("CLASP_SWARM_NETWORK_EGRESS_AUDIT_ALLOWLIST_PATH", `${encodedAllowlist}${os.EOL}`);

const childEnv = {
  ...process.env,
  CLASP_NETWORK_EGRESS_ALLOWED: encodedAllowlist,
  CLASP_NETWORK_EGRESS_DESTINATIONS_JSON: JSON.stringify(destinations.map((destination) => destination.text)),
  LD_PRELOAD: process.env.LD_PRELOAD ? `${guardPath}:${process.env.LD_PRELOAD}` : guardPath,
};

const result = spawnSync(options.command[0], options.command.slice(1), {
  cwd: options.cwd,
  env: childEnv,
  stdio: "inherit",
});

if (result.error) {
  fail(`failed to launch command with network egress guard: ${result.error.message}`, 127);
}
if (result.signal) {
  fail(`guarded command terminated by signal ${result.signal}`, 128);
}
process.exit(result.status ?? 127);
