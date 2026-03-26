#!/usr/bin/env node

import { readFile } from "node:fs/promises";

function parseArgs(argv) {
  const options = {};

  for (let index = 2; index < argv.length; index += 2) {
    const key = argv[index];
    const value = argv[index + 1];
    if (!key?.startsWith("--") || value === undefined) {
      throw new Error("usage: bun benchmarks/backend/runtime-bench.mjs --workload <id> --iterations <count> --input <path>");
    }
    options[key.slice(2)] = value;
  }

  return options;
}

function runCompilerSourceText(sourceText, iterations) {
  let checksum = 0;

  for (let index = 0; index < iterations; index += 1) {
    const parts = sourceText.split("\n");
    const joined = parts.join("::");
    checksum += joined.length + parts.length + (joined.startsWith("module") ? 1 : 0);
  }

  return checksum;
}

function runBoundaryTransport(payloadText, iterations) {
  let checksum = 0;

  for (let index = 0; index < iterations; index += 1) {
    const payload = Buffer.from(payloadText, "utf8");
    const frame = Buffer.allocUnsafe(payload.length + 4);
    frame.writeUInt32LE(payload.length, 0);
    payload.copy(frame, 4);
    const expectedLength = frame.readUInt32LE(0);
    const restored = frame.subarray(4, 4 + expectedLength).toString("utf8");

    checksum += restored.length + frame.length;
  }

  return checksum;
}

async function main() {
  const options = parseArgs(process.argv);
  const workload = options.workload;
  const iterations = Number.parseInt(options.iterations ?? "0", 10);
  const inputPath = options.input;

  if (!workload || !Number.isFinite(iterations) || iterations <= 0 || !inputPath) {
    throw new Error("usage: bun benchmarks/backend/runtime-bench.mjs --workload <id> --iterations <count> --input <path>");
  }

  const inputText = await readFile(inputPath, "utf8");
  let checksum;

  switch (workload) {
    case "compiler-source-text":
      checksum = runCompilerSourceText(inputText, iterations);
      break;
    case "boundary-transport":
      checksum = runBoundaryTransport(inputText, iterations);
      break;
    default:
      throw new Error(`unknown workload: ${workload}`);
  }

  process.stdout.write(
    JSON.stringify({
      workload,
      iterations,
      checksum
    }) + "\n"
  );
}

await main();
