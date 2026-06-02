#!/usr/bin/env node
import fs from "node:fs";
import { spawnSync } from "node:child_process";

function fail(message, status = 2) {
  process.stderr.write(`clasp-network-egress-enforcer: ${message}\n`);
  process.exit(status);
}

function usage() {
  return [
    "usage: clasp-network-egress-enforcer.mjs --network-access allowlisted --destinations-json JSON --cwd PATH --command-json JSON -- COMMAND...",
    "",
    "This is a fail-closed mediator adapter for Clasp swarm allowlisted network runs.",
    "It validates the runtime mediator contract and delegates execution to the",
    "host-level backend in CLASP_SWARM_NETWORK_EGRESS_BACKEND_JSON.",
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

function normalizeDestination(value) {
  const trimmed = value.trim();
  if (!trimmed) {
    fail("allowed network destination must be non-empty");
  }
  if (/\s/.test(trimmed)) {
    fail(`allowed network destination must not contain whitespace: ${trimmed}`);
  }
  const match = /^([A-Za-z0-9.-]+|\[[0-9A-Fa-f:.]+\]):([0-9]+)$/.exec(trimmed);
  if (!match) {
    fail(`allowed network destination must be host:port: ${trimmed}`);
  }
  const port = Number.parseInt(match[2], 10);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    fail(`allowed network destination port is out of range: ${trimmed}`);
  }
  return `${match[1].toLowerCase()}:${port}`;
}

function normalizeDestinations(values) {
  const result = [];
  for (const value of values) {
    const normalized = normalizeDestination(value);
    if (!result.includes(normalized)) {
      result.push(normalized);
    }
  }
  if (result.length === 0) {
    fail("allowlisted network mediation requires at least one destination");
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

function backendCommandFromEnv() {
  const raw = process.env.CLASP_SWARM_NETWORK_EGRESS_BACKEND_JSON || "";
  if (!raw.trim()) {
    fail("CLASP_SWARM_NETWORK_EGRESS_BACKEND_JSON is required for allowlisted execution", 126);
  }
  const command = decodeJsonArray(raw, "CLASP_SWARM_NETWORK_EGRESS_BACKEND_JSON");
  if (command.length === 0) {
    fail("CLASP_SWARM_NETWORK_EGRESS_BACKEND_JSON must be non-empty");
  }
  if (command.some((part) => part.length === 0)) {
    fail("CLASP_SWARM_NETWORK_EGRESS_BACKEND_JSON must not contain empty command parts");
  }
  return command;
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

const backendCommand = backendCommandFromEnv();
const backendArgs = [
  ...backendCommand.slice(1),
  "--network-access",
  "allowlisted",
  "--destinations-json",
  JSON.stringify(destinations),
  "--cwd",
  options.cwd,
  "--command-json",
  JSON.stringify(declaredCommand),
  "--",
  ...options.command,
];
const result = spawnSync(backendCommand[0], backendArgs, {
  cwd: options.cwd,
  env: process.env,
  stdio: "inherit",
});

if (result.error) {
  fail(`failed to launch backend: ${result.error.message}`, 127);
}
if (result.signal) {
  fail(`backend terminated by signal ${result.signal}`, 128);
}
process.exit(result.status ?? 127);
