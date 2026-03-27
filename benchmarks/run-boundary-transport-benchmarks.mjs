#!/usr/bin/env node

import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { spawn, spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";

const projectRoot = path.resolve(".");
const benchmarkRoot = path.join(projectRoot, "benchmarks");
const distRoot = path.join(projectRoot, "dist", "backend-benchmarks");
const schemaSourcePath = path.join(
  projectRoot,
  "benchmarks",
  "backend",
  "boundary-transport-schema.clasp"
);
const compiledSchemaPath = path.join(distRoot, "boundary-transport-schema.mjs");
const schemaType = "BoundaryTransportSample";
const seed = Object.freeze({
  leadId: "lead-benchmark-018",
  company: "Acme Robotics",
  budget: 42_000,
  accepted: true,
  routeName: "summarizeLeadRoute",
  score: 97,
  primaryTag: {
    label: "priority",
    weight: 7
  }
});

const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder();
let cachedClaspcBinary = null;

async function main() {
  const options = parseOptions(process.argv.slice(2));
  const samples = parsePositiveNumber(options.samples ?? "5", "samples");
  const iterations = parsePositiveNumber(options.iterations ?? "1000", "iterations");
  const warmupRuns = parseNumber(options.warmupRuns ?? "1", "warmup runs");
  const outputPath = path.resolve(
    options.output ??
      path.join(
        benchmarkRoot,
        "results",
        "backend",
        `${new Date().toISOString().replaceAll(":", "-")}--boundary-transport-benchmarks.json`
      )
  );

  await mkdir(path.dirname(outputPath), { recursive: true });
  await mkdir(distRoot, { recursive: true });

  await compileSchemaModel();
  const compiledModule = await import(
    `${pathToFileURL(compiledSchemaPath).href}?ts=${Date.now()}`
  );
  const schemaContract = compiledModule.__claspSchemas?.[schemaType] ?? null;
  if (!schemaContract) {
    throw new Error(`compiled schema registry does not include ${schemaType}`);
  }

  const jsonProjection = await benchmarkProjection(
    () => runJsonProjection(schemaContract, iterations),
    samples,
    warmupRuns
  );
  const generatedBinaryProjection = await benchmarkProjection(
    () => runGeneratedBinaryProjection(schemaContract, iterations),
    samples,
    warmupRuns
  );

  if (jsonProjection.roundTripChecksum !== generatedBinaryProjection.roundTripChecksum) {
    throw new Error(
      `projection checksum mismatch (${jsonProjection.roundTripChecksum} vs ${generatedBinaryProjection.roundTripChecksum})`
    );
  }

  const result = {
    schemaVersion: 1,
    generatedAt: new Date().toISOString(),
    schemaType,
    schemaFingerprint: String(
      schemaContract.schema?.schemaFingerprint ?? schemaContract.type ?? schemaType
    ),
    iterations,
    seed,
    jsonProjection,
    generatedBinaryProjection,
    binaryPayloadRatioVsJson: roundRatio(
      generatedBinaryProjection.payloadBytes / jsonProjection.payloadBytes
    ),
    binarySpeedupVsJson: roundRatio(
      jsonProjection.medianMs / generatedBinaryProjection.medianMs
    )
  };

  await writeFile(outputPath, JSON.stringify(result, null, 2) + "\n", "utf8");
  printSummary(result, outputPath);
}

function parseOptions(args) {
  const options = {};

  for (let index = 0; index < args.length; index += 2) {
    const key = args[index];
    const value = args[index + 1];
    if (!key?.startsWith("--") || value === undefined) {
      throw new Error("expected --key value pairs");
    }
    options[key.slice(2).replace(/-([a-z])/g, (_, letter) => letter.toUpperCase())] = value;
  }

  return options;
}

async function compileSchemaModel() {
  await runCommand([
    resolveClaspcBinary(),
    "compile",
    schemaSourcePath,
    "-o",
    compiledSchemaPath
  ]);
}

function commandEnv() {
  const tempDir = process.env.TMPDIR;
  return {
    ...process.env,
    TMPDIR: tempDir ? tempDir : "/tmp"
  };
}

function resolveClaspcBinary() {
  if (process.env.CLASPC_BIN) {
    return process.env.CLASPC_BIN;
  }
  if (cachedClaspcBinary) {
    return cachedClaspcBinary;
  }

  const result = spawnSync("bash", [path.join(projectRoot, "scripts", "resolve-claspc.sh")], {
    cwd: projectRoot,
    env: commandEnv(),
    encoding: "utf8"
  });

  if (result.status !== 0) {
    throw new Error(`failed to resolve claspc binary\n${result.stderr ?? ""}`);
  }

  cachedClaspcBinary = result.stdout.trim();
  return cachedClaspcBinary;
}

async function benchmarkProjection(runSample, samples, warmupRuns) {
  let stableOutput = null;

  for (let index = 0; index < warmupRuns; index += 1) {
    stableOutput = assertStableProjection(stableOutput, runSample());
  }

  const samplesMs = [];
  for (let index = 0; index < samples; index += 1) {
    const startedAt = process.hrtime.bigint();
    const output = runSample();
    const elapsedMs = Number(process.hrtime.bigint() - startedAt) / 1_000_000;
    samplesMs.push(Math.round(elapsedMs));
    stableOutput = assertStableProjection(stableOutput, output);
  }

  return {
    ...stableOutput,
    samplesMs,
    medianMs: median(samplesMs)
  };
}

function assertStableProjection(previous, next) {
  if (previous === null) {
    return next;
  }

  if (
    previous.payloadBytes !== next.payloadBytes ||
    previous.roundTripChecksum !== next.roundTripChecksum
  ) {
    throw new Error("projection benchmark output changed across samples");
  }

  return previous;
}

function runJsonProjection(schemaContract, iterations) {
  let roundTripChecksum = 0;
  let payloadBytes = 0;

  for (let index = 0; index < iterations; index += 1) {
    const normalized = normalizeSeed(schemaContract);
    const payload = frameJsonPayload(JSON.stringify(normalized));
    const restored = schemaContract.toHost(
      schemaContract.fromHost(JSON.parse(unframeJsonPayload(payload)), "value"),
      "value"
    );

    payloadBytes = payload.byteLength;
    roundTripChecksum += sampleChecksum(restored);
  }

  return { payloadBytes, roundTripChecksum };
}

function runGeneratedBinaryProjection(schemaContract, iterations) {
  let roundTripChecksum = 0;
  let payloadBytes = 0;

  for (let index = 0; index < iterations; index += 1) {
    const frame = schemaContract.encodeFramedBinary(seed);
    const restored = schemaContract.decodeFramedBinary(frame);

    payloadBytes = frame.byteLength;
    roundTripChecksum += sampleChecksum(restored);
  }

  return { payloadBytes, roundTripChecksum };
}

function normalizeSeed(schemaContract) {
  return schemaContract.toHost(schemaContract.fromHost(seed, "value"), "value");
}

function sampleChecksum(value) {
  return (
    value.leadId.length +
    value.company.length +
    value.budget +
    value.score +
    value.routeName.length +
    value.primaryTag.label.length +
    value.primaryTag.weight +
    (value.accepted ? 1 : 0)
  );
}

function frameJsonPayload(payloadText) {
  const payload = textEncoder.encode(payloadText);
  const frame = new Uint8Array(payload.byteLength + 4);
  writeUint32(frame, 0, payload.byteLength);
  frame.set(payload, 4);
  return frame;
}

function unframeJsonPayload(frame) {
  const expectedLength = readUint32(frame, 0);
  const payload = frame.slice(4);
  if (payload.byteLength !== expectedLength) {
    throw new Error(`expected ${expectedLength} framed json bytes but received ${payload.byteLength}`);
  }
  return textDecoder.decode(payload);
}

function writeUint32(target, offset, value) {
  new DataView(target.buffer, target.byteOffset, target.byteLength).setUint32(offset, value, true);
}

function readUint32(source, offset) {
  return new DataView(source.buffer, source.byteOffset, source.byteLength).getUint32(offset, true);
}

async function runCommand(command) {
  return new Promise((resolve, reject) => {
    const child = spawn(command[0], command.slice(1), {
      cwd: projectRoot,
      env: commandEnv(),
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
    child.on("exit", (code) => {
      if (code !== 0) {
        reject(new Error(`${command.join(" ")} failed with ${code}\n${stderr}`));
        return;
      }
      resolve({ stdout, stderr });
    });
  });
}

function median(values) {
  const sorted = [...values].sort((left, right) => left - right);
  const middle = Math.floor(sorted.length / 2);
  if (sorted.length % 2 === 1) {
    return sorted[middle];
  }
  return Math.round((sorted[middle - 1] + sorted[middle]) / 2);
}

function parseNumber(value, label) {
  const parsed = Number.parseInt(value, 10);
  if (!Number.isFinite(parsed) || parsed < 0) {
    throw new Error(`invalid ${label}: ${value}`);
  }
  return parsed;
}

function parsePositiveNumber(value, label) {
  const parsed = parseNumber(value, label);
  if (parsed <= 0) {
    throw new Error(`${label} must be positive`);
  }
  return parsed;
}

function roundRatio(value) {
  return Number(value.toFixed(3));
}

function printSummary(result, outputPath) {
  console.log(
    `JSON projection: ${result.jsonProjection.medianMs}ms, ${result.jsonProjection.payloadBytes} bytes`
  );
  console.log(
    `Generated binary projection: ${result.generatedBinaryProjection.medianMs}ms, ${result.generatedBinaryProjection.payloadBytes} bytes`
  );
  console.log(`binaryPayloadRatioVsJson ${result.binaryPayloadRatioVsJson}`);
  console.log(`binarySpeedupVsJson ${result.binarySpeedupVsJson}`);
  console.log(`Wrote ${path.relative(projectRoot, outputPath)}`);
}

await main();
