#!/usr/bin/env node

import { mkdir, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { spawn } from "node:child_process";

const projectRoot = path.resolve(".");
const benchmarkRoot = path.join(projectRoot, "benchmarks");
const distRoot = path.join(projectRoot, "dist", "backend-benchmarks");

const compileWorkloads = [
  {
    id: "compiler-parser",
    input: "examples/compiler-parser.clasp"
  },
  {
    id: "hosted-compiler",
    input: "src/Main.clasp"
  }
];

const runtimeWorkloads = [
  {
    id: "compiler-source-text",
    input: "examples/compiler-parser.clasp"
  },
  {
    id: "boundary-transport",
    input: "benchmarks/backend/runtime-payload.json"
  }
];

async function main() {
  const options = parseOptions(process.argv.slice(2));
  const selectedCompileWorkloads = selectWorkloads(
    compileWorkloads,
    options.compileWorkloads
  );
  const selectedRuntimeWorkloads = selectWorkloads(
    runtimeWorkloads,
    options.runtimeWorkloads
  );
  const compileSamples = parsePositiveNumber(options.compileSamples ?? "3", "compile samples");
  const runtimeSamples = parsePositiveNumber(options.runtimeSamples ?? "5", "runtime samples");
  const runtimeIterations = parsePositiveNumber(
    options.runtimeIterations ?? "1000",
    "runtime iterations"
  );
  const warmupRuns = parseNumber(options.warmupRuns ?? "1", "warmup runs");
  const outputPath = path.resolve(
    options.output ??
      path.join(
        benchmarkRoot,
        "results",
        "backend",
        `${new Date().toISOString().replaceAll(":", "-")}--backend-benchmarks.json`
      )
  );

  await mkdir(path.dirname(outputPath), { recursive: true });
  await mkdir(distRoot, { recursive: true });

  const environment = await detectEnvironment();
  const nativeHarnessPath = await buildNativeRuntimeHarness();
  const compileResults = [];
  const runtimeResults = [];

  for (const workload of selectedCompileWorkloads) {
    compileResults.push(
      await runCompileBenchmark(workload, compileSamples, warmupRuns)
    );
  }

  for (const workload of selectedRuntimeWorkloads) {
    runtimeResults.push(
      await runRuntimeBenchmark(
        workload,
        runtimeSamples,
        runtimeIterations,
        warmupRuns,
        nativeHarnessPath
      )
    );
  }

  const result = {
    schemaVersion: 1,
    generatedAt: new Date().toISOString(),
    environment,
    compileBenchmarks: compileResults,
    runtimeBenchmarks: runtimeResults
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

function selectWorkloads(available, requestedList) {
  if (!requestedList) {
    return available;
  }

  const requested = new Set(
    requestedList.split(",").map((value) => value.trim()).filter((value) => value.length > 0)
  );
  const selected = available.filter((workload) => requested.has(workload.id));
  if (selected.length !== requested.size) {
    const known = available.map((workload) => workload.id).join(", ");
    throw new Error(`unknown workload in ${requestedList}; expected one of: ${known}`);
  }
  return selected;
}

async function detectEnvironment() {
  const [bunVersion, ccVersion, cabalVersion, rustcVersion] = await Promise.all([
    captureVersion(["bun", "--version"]),
    captureVersion(["cc", "--version"]),
    captureVersion(["cabal", "--version"]),
    captureVersion(["rustc", "--version"])
  ]);

  return {
    platform: process.platform,
    arch: process.arch,
    hostname: os.hostname(),
    bunVersion,
    ccVersion,
    cabalVersion,
    rustcVersion
  };
}

async function captureVersion(command) {
  const { stdout } = await runCommand(command);
  return stdout.trim().split("\n")[0] ?? "";
}

async function buildNativeRuntimeHarness() {
  const outputPath = path.join(distRoot, "runtime-bench");
  const rustRuntimeSource = path.join(projectRoot, "runtime", "native", "clasp_runtime.rs");
  const rustRuntimeLibrary = path.join(distRoot, "libclasp_runtime.a");

  await runCommand([
    "rustc",
    "--edition=2021",
    "--crate-type",
    "staticlib",
    "-C",
    "panic=abort",
    rustRuntimeSource,
    "-o",
    rustRuntimeLibrary
  ]);

  const nativeStaticLibs = await runCommand([
    "rustc",
    "--edition=2021",
    "--crate-type",
    "staticlib",
    "-C",
    "panic=abort",
    "--print",
    "native-static-libs",
    rustRuntimeSource
  ]);

  const rustLinkArgs = (nativeStaticLibs.stderr
    .split("\n")
    .map((line) => line.trim())
    .find((line) => line.startsWith("note: native-static-libs: ")) ?? "")
    .replace("note: native-static-libs: ", "")
    .split(/\s+/)
    .filter((value) => value.length > 0);

  await runCommand([
    "cc",
    "-O2",
    "-std=c11",
    path.join(projectRoot, "benchmarks", "backend", "runtime-bench.c"),
    rustRuntimeLibrary,
    ...rustLinkArgs,
    "-o",
    outputPath
  ]);
  return outputPath;
}

async function runCompileBenchmark(workload, samples, warmupRuns) {
  const inputPath = path.join(projectRoot, workload.input);
  const jsOutput = path.join(distRoot, `${workload.id}.js`);
  const nativeOutput = path.join(distRoot, `${workload.id}.native.ir`);
  const jsCommand = [
    "claspc",
    "compile",
    inputPath,
    "-o",
    jsOutput
  ];
  const nativeCommand = [
    "claspc",
    "native",
    inputPath,
    "-o",
    nativeOutput
  ];

  const jsBun = await benchmarkCommand(jsCommand, samples, warmupRuns, async () => {
    await rm(jsOutput, { force: true });
  });
  const native = await benchmarkCommand(nativeCommand, samples, warmupRuns, async () => {
    await rm(nativeOutput, { force: true });
  });

  return {
    workload: workload.id,
    input: workload.input,
    jsBun: {
      command: jsCommand,
      samplesMs: jsBun.samplesMs,
      medianMs: jsBun.medianMs
    },
    native: {
      command: nativeCommand,
      samplesMs: native.samplesMs,
      medianMs: native.medianMs
    },
    deltaMs: native.medianMs - jsBun.medianMs,
    nativeSpeedupVsJs: roundRatio(jsBun.medianMs / native.medianMs)
  };
}

async function runRuntimeBenchmark(
  workload,
  samples,
  iterations,
  warmupRuns,
  nativeHarnessPath
) {
  const inputPath = path.join(projectRoot, workload.input);
  const jsCommand = [
    "bun",
    path.join(projectRoot, "benchmarks", "backend", "runtime-bench.mjs"),
    "--workload",
    workload.id,
    "--iterations",
    String(iterations),
    "--input",
    inputPath
  ];
  const nativeCommand = [
    nativeHarnessPath,
    workload.id,
    String(iterations),
    inputPath
  ];

  const jsBun = await benchmarkJsonCommand(jsCommand, samples, warmupRuns);
  const native = await benchmarkJsonCommand(nativeCommand, samples, warmupRuns);

  if (jsBun.output.checksum !== native.output.checksum) {
    throw new Error(
      `runtime workload ${workload.id} produced mismatched checksums (${jsBun.output.checksum} vs ${native.output.checksum})`
    );
  }

  return {
    workload: workload.id,
    input: workload.input,
    iterations,
    jsBun: {
      command: jsCommand,
      samplesMs: jsBun.samplesMs,
      medianMs: jsBun.medianMs,
      checksum: jsBun.output.checksum
    },
    native: {
      command: nativeCommand,
      samplesMs: native.samplesMs,
      medianMs: native.medianMs,
      checksum: native.output.checksum
    },
    deltaMs: native.medianMs - jsBun.medianMs,
    nativeSpeedupVsJs: roundRatio(jsBun.medianMs / native.medianMs)
  };
}

async function benchmarkCommand(command, samples, warmupRuns, cleanup) {
  for (let index = 0; index < warmupRuns; index += 1) {
    await runCommand(command);
    await cleanup();
  }

  const samplesMs = [];
  for (let index = 0; index < samples; index += 1) {
    const startedAt = process.hrtime.bigint();
    await runCommand(command);
    const elapsedMs = Number(process.hrtime.bigint() - startedAt) / 1_000_000;
    samplesMs.push(Math.round(elapsedMs));
    await cleanup();
  }

  return {
    samplesMs,
    medianMs: median(samplesMs)
  };
}

async function benchmarkJsonCommand(command, samples, warmupRuns) {
  let output = null;
  for (let index = 0; index < warmupRuns; index += 1) {
    const warmup = await runCommand(command);
    output = JSON.parse(warmup.stdout.trim());
  }

  const samplesMs = [];
  for (let index = 0; index < samples; index += 1) {
    const startedAt = process.hrtime.bigint();
    const result = await runCommand(command);
    const elapsedMs = Number(process.hrtime.bigint() - startedAt) / 1_000_000;
    samplesMs.push(Math.round(elapsedMs));
    output = JSON.parse(result.stdout.trim());
  }

  return {
    output,
    samplesMs,
    medianMs: median(samplesMs)
  };
}

async function runCommand(command) {
  return new Promise((resolve, reject) => {
    const child = spawn(command[0], command.slice(1), {
      cwd: projectRoot,
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
  console.log("Compile benchmarks");
  for (const benchmark of result.compileBenchmarks) {
    console.log(
      `  ${benchmark.workload}: js/bun ${benchmark.jsBun.medianMs}ms, native ${benchmark.native.medianMs}ms, nativeSpeedupVsJs ${benchmark.nativeSpeedupVsJs}`
    );
  }

  console.log("Runtime benchmarks");
  for (const benchmark of result.runtimeBenchmarks) {
    console.log(
      `  ${benchmark.workload}: js/bun ${benchmark.jsBun.medianMs}ms, native ${benchmark.native.medianMs}ms, nativeSpeedupVsJs ${benchmark.nativeSpeedupVsJs}`
    );
  }

  console.log(`Wrote ${path.relative(projectRoot, outputPath)}`);
}

await main();
