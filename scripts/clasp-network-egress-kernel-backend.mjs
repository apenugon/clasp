#!/usr/bin/env node
import dns from "node:dns/promises";
import dgram from "node:dgram";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const scriptPath = fileURLToPath(import.meta.url);

function fail(message, status = 2) {
  process.stderr.write(`clasp-network-egress-kernel-backend: ${message}\n`);
  process.exit(status);
}

function usage() {
  return [
    "usage: clasp-network-egress-kernel-backend.mjs --network-access allowlisted --destinations-json JSON --cwd PATH --command-json JSON -- COMMAND...",
    "",
    "Kernel-isolated hostname/IP:port allowlist backend for Clasp swarm allowlisted network runs.",
    "The child runs in a fresh user/network namespace with no host network route.",
    "Allowed destinations are resolved on the host, exposed through namespace-local",
    "proxy listeners, and written into namespace-private hosts/resolv.conf files",
    "backed by an in-namespace DNS responder so hostname-based tools can",
    "resolve allowed names without ambient DNS.",
    "This backend is intended for hostile/static/direct-syscall tools that cannot",
    "be trusted to honor LD_PRELOAD.",
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
    fail("kernel allowlist backend requires at least one destination");
  }
  return result;
}

function normalizeHostName(host) {
  return host.trim().toLowerCase();
}

function decodeResolutionOverrides() {
  const raw = process.env.CLASP_NETWORK_EGRESS_RESOLUTION_OVERRIDES_JSON || "";
  if (!raw) {
    return new Map();
  }

  let decoded;
  try {
    decoded = JSON.parse(raw);
  } catch (error) {
    fail(`failed to decode CLASP_NETWORK_EGRESS_RESOLUTION_OVERRIDES_JSON: ${error instanceof Error ? error.message : String(error)}`);
  }
  if (!decoded || Array.isArray(decoded) || typeof decoded !== "object") {
    fail("CLASP_NETWORK_EGRESS_RESOLUTION_OVERRIDES_JSON must be an object mapping hostnames to IP arrays");
  }

  const overrides = new Map();
  for (const [host, value] of Object.entries(decoded)) {
    const normalizedHost = normalizeHostName(host);
    if (!normalizedHost || net.isIP(normalizedHost)) {
      fail(`resolution override host must be a non-IP hostname: ${host}`);
    }
    const values = Array.isArray(value) ? value : [value];
    if (!values.every((entry) => typeof entry === "string" && net.isIP(entry) !== 0)) {
      fail(`resolution override for ${host} must contain only IP address strings`);
    }
    overrides.set(normalizedHost, values.map((address) => ({
      family: net.isIP(address),
      address,
    })));
  }

  return overrides;
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

async function resolveDestination(destination, resolutionOverrides) {
  const ipFamily = net.isIP(destination.host);
  if (ipFamily === 4 || ipFamily === 6) {
    return [{ family: ipFamily, address: destination.host, port: destination.port, text: destination.text, host: destination.host }];
  }

  const overridden = resolutionOverrides.get(destination.host);
  if (overridden && overridden.length > 0) {
    return overridden.map((entry) => ({
      family: entry.family,
      address: entry.address,
      port: destination.port,
      text: destination.text,
      host: destination.host,
    }));
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
    text: destination.text,
    host: destination.host,
  }));
}

async function resolveAllowlist(destinations, resolutionOverrides) {
  const seen = new Set();
  const records = [];
  for (const destination of destinations) {
    const resolved = await resolveDestination(destination, resolutionOverrides);
    for (const record of resolved) {
      if (record.family !== 4) {
        fail("kernel allowlist backend currently supports IPv4 destinations only", 126);
      }
      const key = `${record.address}:${record.port}`;
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

function writeNamespaceHostsFile(records, tempDir) {
  const lines = [
    "127.0.0.1 localhost",
    "::1 localhost",
  ];
  const seen = new Set(lines);
  for (const record of records) {
    if (net.isIP(record.host) !== 0) {
      continue;
    }
    const line = `${record.address} ${record.host}`;
    if (!seen.has(line)) {
      seen.add(line);
      lines.push(line);
    }
  }
  const hostsPath = path.join(tempDir, "namespace-hosts");
  fs.writeFileSync(hostsPath, `${lines.join("\n")}\n`);
  return hostsPath;
}

function writeNamespaceResolvFile(tempDir) {
  const resolvPath = path.join(tempDir, "namespace-resolv.conf");
  fs.writeFileSync(resolvPath, "nameserver 127.0.0.53\noptions attempts:1 timeout:1\n");
  return resolvPath;
}

function parseDnsQuestion(message) {
  if (message.length < 12) {
    return null;
  }
  let offset = 12;
  const labels = [];
  while (offset < message.length) {
    const length = message[offset];
    offset += 1;
    if (length === 0) {
      break;
    }
    if ((length & 0xc0) !== 0 || offset + length > message.length) {
      return null;
    }
    labels.push(message.slice(offset, offset + length).toString("ascii").toLowerCase());
    offset += length;
  }
  if (offset + 4 > message.length || labels.length === 0) {
    return null;
  }
  return {
    name: labels.join("."),
    qtype: message.readUInt16BE(offset),
    qclass: message.readUInt16BE(offset + 2),
    questionEnd: offset + 4,
  };
}

function ipv4Bytes(address) {
  const parts = address.split(".").map((part) => Number.parseInt(part, 10));
  if (parts.length !== 4 || parts.some((part) => !Number.isInteger(part) || part < 0 || part > 255)) {
    return null;
  }
  return Buffer.from(parts);
}

function dnsResponseFor(message, question, addresses) {
  const questionBytes = message.slice(12, question.questionEnd);
  const answers = [];
  for (const address of addresses) {
    const bytes = ipv4Bytes(address);
    if (!bytes) {
      continue;
    }
    const answer = Buffer.alloc(16);
    answer[0] = 0xc0;
    answer[1] = 0x0c;
    answer.writeUInt16BE(1, 2);
    answer.writeUInt16BE(1, 4);
    answer.writeUInt32BE(0, 6);
    answer.writeUInt16BE(4, 10);
    bytes.copy(answer, 12);
    answers.push(answer);
  }

  const header = Buffer.alloc(12);
  message.copy(header, 0, 0, 2);
  header.writeUInt16BE(0x8180, 2);
  header.writeUInt16BE(1, 4);
  header.writeUInt16BE(answers.length, 6);
  header.writeUInt16BE(0, 8);
  header.writeUInt16BE(0, 10);
  return Buffer.concat([header, questionBytes, ...answers]);
}

async function startNamespaceDns(records) {
  const allowed = new Map();
  for (const record of records) {
    if (net.isIP(record.host) !== 0) {
      continue;
    }
    const existing = allowed.get(record.host) || [];
    if (!existing.includes(record.address)) {
      existing.push(record.address);
    }
    allowed.set(record.host, existing);
  }

  const server = dgram.createSocket("udp4");
  server.on("message", (message, remote) => {
    const question = parseDnsQuestion(message);
    if (!question) {
      return;
    }
    const response = dnsResponseFor(
      message,
      question,
      question.qclass === 1 && question.qtype === 1 ? allowed.get(question.name) || [] : [],
    );
    server.send(response, remote.port, remote.address);
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.bind(53, "127.0.0.53", () => {
      server.off("error", reject);
      resolve();
    });
  });
  return server;
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

function addLoopbackAddress(address) {
  if (address.startsWith("127.")) {
    return;
  }
  const result = spawnSync("ip", ["addr", "add", `${address}/32`, "dev", "lo"], {
    encoding: "utf8",
    maxBuffer: 1024 * 1024,
  });
  if (result.status === 0) {
    return;
  }
  const detail = `${result.stderr || ""}${result.stdout || ""}`;
  if (detail.includes("File exists")) {
    return;
  }
  fail(`failed to add namespace loopback address ${address}: ${detail.trim()}`, 126);
}

async function listen(server, ...args) {
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(...args, () => {
      server.off("error", reject);
      resolve();
    });
  });
}

async function startHostRelay(record) {
  const server = net.createServer((client) => {
    const upstream = net.connect({ host: record.address, port: record.port });
    client.on("error", () => upstream.destroy());
    upstream.on("error", () => client.destroy());
    client.pipe(upstream);
    upstream.pipe(client);
  });
  await listen(server, record.socketPath);
  return server;
}

async function startNamespaceProxy(record) {
  const server = net.createServer((client) => {
    const relay = net.connect(record.socketPath);
    client.on("error", () => relay.destroy());
    relay.on("error", () => client.destroy());
    client.pipe(relay);
    relay.pipe(client);
  });
  await listen(server, record.port, record.address);
  return server;
}

function closeServers(servers) {
  for (const server of servers) {
    try {
      server.close();
    } catch {
      // Best-effort cleanup after the child exits.
    }
  }
}

async function runNamespaceChild(argv) {
  const configPath = argv[0] || "";
  if (!configPath) {
    fail("--namespace-child requires a config path");
  }
  const config = JSON.parse(fs.readFileSync(configPath, "utf8"));
  if (!Array.isArray(config.records) || !Array.isArray(config.command) || typeof config.cwd !== "string") {
    fail("namespace child config is invalid");
  }

  process.chdir(config.cwd);
  if (typeof config.hostsPath === "string" && config.hostsPath) {
    runChecked("mount", ["--bind", config.hostsPath, "/etc/hosts"], "namespace hosts allowlist setup");
  }
  if (typeof config.resolvPath === "string" && config.resolvPath) {
    runChecked("mount", ["--bind", config.resolvPath, "/etc/resolv.conf"], "namespace resolver allowlist setup");
  }
  runChecked("ip", ["link", "set", "lo", "up"], "network namespace loopback setup");
  const uniqueAddresses = [...new Set(config.records.map((record) => record.address))];
  for (const address of uniqueAddresses) {
    addLoopbackAddress(address);
  }

  const servers = [];
  try {
    servers.push(await startNamespaceDns(config.records));
    for (const record of config.records) {
      servers.push(await startNamespaceProxy(record));
    }
  } catch (error) {
    closeServers(servers);
    fail(`failed to start namespace egress proxy: ${error instanceof Error ? error.message : String(error)}`, 126);
  }

  const childEnv = {
    ...process.env,
    CLASP_NETWORK_EGRESS_KERNEL_ISOLATED: "1",
    CLASP_NETWORK_EGRESS_HOSTNAME_TRANSPARENT: "1",
    CLASP_NETWORK_EGRESS_DESTINATIONS_JSON: JSON.stringify(config.records.map((record) => record.text)),
    CLASP_NETWORK_EGRESS_HOSTS_JSON: JSON.stringify([...new Set(config.records.map((record) => record.host))]),
  };
  delete childEnv.LD_PRELOAD;

  const child = spawn(config.command[0], config.command.slice(1), {
    cwd: config.cwd,
    env: childEnv,
    stdio: "inherit",
  });
  child.on("error", (error) => {
    closeServers(servers);
    fail(`failed to launch kernel-isolated command: ${error.message}`, 127);
  });
  child.on("exit", (code, signal) => {
    closeServers(servers);
    if (signal) {
      process.kill(process.pid, signal);
      process.exit(128);
    }
    process.exit(code ?? 127);
  });
}

async function runHostBackend(argv) {
  if (process.platform !== "linux") {
    fail("kernel egress backend is currently supported only on Linux", 126);
  }
  const options = parseArgs(argv);
  if (options.networkAccess !== "allowlisted") {
    fail(`--network-access must be allowlisted, got ${options.networkAccess || "(missing)"}`);
  }
  validateCwd(options.cwd);
  const declaredCommand = decodeJsonArray(options.commandJson, "--command-json");
  if (declaredCommand.length === 0) {
    fail("--command-json must describe a non-empty command");
  }
  if (JSON.stringify(declaredCommand) !== JSON.stringify(options.command)) {
    fail("--command-json must match the command after --");
  }

  const records = await resolveAllowlist(
    normalizeDestinations(decodeJsonArray(options.destinationsJson, "--destinations-json")),
    decodeResolutionOverrides(),
  );
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "clasp-network-egress-kernel-"));
  const servers = [];
  try {
    const configuredRecords = records.map((record, index) => ({
      ...record,
      socketPath: path.join(tempDir, `relay-${index}.sock`),
    }));
    for (const record of configuredRecords) {
      servers.push(await startHostRelay(record));
    }

    const configPath = path.join(tempDir, "namespace-config.json");
    const hostsPath = writeNamespaceHostsFile(configuredRecords, tempDir);
    const resolvPath = writeNamespaceResolvFile(tempDir);
    fs.writeFileSync(configPath, JSON.stringify({
      cwd: options.cwd,
      command: declaredCommand,
      records: configuredRecords,
      hostsPath,
      resolvPath,
    }));

    const child = spawn("unshare", ["-r", "-n", "-m", process.execPath, scriptPath, "--namespace-child", configPath], {
      cwd: options.cwd,
      env: process.env,
      stdio: "inherit",
    });
    child.on("error", (error) => {
      closeServers(servers);
      fs.rmSync(tempDir, { recursive: true, force: true });
      fail(`failed to launch unshare for kernel egress backend: ${error.message}`, 127);
    });
    child.on("exit", (code, signal) => {
      closeServers(servers);
      fs.rmSync(tempDir, { recursive: true, force: true });
      if (signal) {
        fail(`kernel-isolated command terminated by signal ${signal}`, 128);
      }
      process.exit(code ?? 127);
    });
  } catch (error) {
    closeServers(servers);
    fs.rmSync(tempDir, { recursive: true, force: true });
    fail(`kernel egress backend failed: ${error instanceof Error ? error.message : String(error)}`, 126);
  }
}

if (process.argv[2] === "--namespace-child") {
  await runNamespaceChild(process.argv.slice(3));
} else {
  await runHostBackend(process.argv.slice(2));
}
