#!/usr/bin/env node

import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

function usage() {
  console.error(
    [
      "usage: node scripts/benchmark-checkpoint.mjs [--output PATH] [--fixture] [--keep-tmp]",
      "  [--tmp-root PATH] [--generated-at ISO]",
      "  [--source-run-timeout SECONDS] [--compiler-slice-timeout SECONDS]",
      "  [--native-incremental-timeout SECONDS] [--no-native-incremental]",
    ].join("\n"),
  );
}

function fail(message) {
  console.error(`benchmark-checkpoint: ${message}`);
  process.exit(1);
}

function parsePositiveInt(value, label) {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 1) {
    fail(`${label} must be a positive integer`);
  }
  return parsed;
}

function parseArgs(argv) {
  const options = {
    output: "",
    fixture: false,
    keepTmp: false,
    tmpRoot: process.env.CLASP_TEST_TMPDIR || process.env.TMPDIR || os.tmpdir(),
    generatedAt: process.env.CLASP_BENCHMARK_CHECKPOINT_GENERATED_AT || new Date().toISOString(),
    sourceRunTimeoutSeconds: parsePositiveInt(process.env.CLASP_BENCHMARK_SOURCE_RUN_TIMEOUT_SECS || "60", "source run timeout"),
    compilerSliceTimeoutSeconds: parsePositiveInt(
      process.env.CLASP_BENCHMARK_COMPILER_SLICE_TIMEOUT_SECS || "120",
      "compiler slice timeout",
    ),
    nativeIncrementalTimeoutSeconds: parsePositiveInt(
      process.env.CLASP_BENCHMARK_NATIVE_INCREMENTAL_TIMEOUT_SECS || "240",
      "native incremental timeout",
    ),
    includeNativeIncremental: true,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    switch (arg) {
      case "--help":
      case "-h":
        usage();
        process.exit(0);
        break;
      case "--output":
        options.output = argv[++index] || "";
        if (!options.output) fail("--output requires a path");
        break;
      case "--fixture":
        options.fixture = true;
        break;
      case "--keep-tmp":
        options.keepTmp = true;
        break;
      case "--tmp-root":
        options.tmpRoot = argv[++index] || "";
        if (!options.tmpRoot) fail("--tmp-root requires a path");
        break;
      case "--generated-at":
        options.generatedAt = argv[++index] || "";
        if (!options.generatedAt) fail("--generated-at requires a value");
        break;
      case "--source-run-timeout":
        options.sourceRunTimeoutSeconds = parsePositiveInt(argv[++index], "--source-run-timeout");
        break;
      case "--compiler-slice-timeout":
        options.compilerSliceTimeoutSeconds = parsePositiveInt(argv[++index], "--compiler-slice-timeout");
        break;
      case "--native-incremental-timeout":
        options.nativeIncrementalTimeoutSeconds = parsePositiveInt(argv[++index], "--native-incremental-timeout");
        break;
      case "--no-native-incremental":
        options.includeNativeIncremental = false;
        break;
      default:
        fail(`unsupported argument: ${arg}`);
    }
  }

  return options;
}

function shellQuote(value) {
  if (/^[A-Za-z0-9_/:=.,@%+-]+$/.test(value)) {
    return value;
  }
  return `'${value.replace(/'/g, "'\\''")}'`;
}

function renderCommand(timeoutSeconds, args) {
  return ["timeout", String(timeoutSeconds), ...args].map(shellQuote).join(" ");
}

function compactText(value, limit = 4000) {
  if (!value) return "";
  if (value.length <= limit) return value;
  return `${value.slice(0, limit)}\n...<truncated ${value.length - limit} chars>`;
}

function commandRecord(label, category, timeoutSeconds, args, extra = {}) {
  return {
    label,
    category,
    timeoutSeconds,
    args,
    command: renderCommand(timeoutSeconds, args),
    ...extra,
  };
}

async function resolveClaspc() {
  if (process.env.CLASP_CLASPC || process.env.CLASPC_BIN) {
    return process.env.CLASP_CLASPC || process.env.CLASPC_BIN;
  }
  const result = await runCommand(
    commandRecord("resolve-claspc", "setup", 120, ["bash", "scripts/resolve-claspc.sh"]),
    { includeOutput: true },
  );
  if (result.exitStatus !== 0) {
    fail(`failed to resolve claspc:\n${result.stderrPreview || result.stdoutPreview}`);
  }
  return result.stdoutPreview.trim().split(/\r?\n/).at(-1);
}

async function runCommand(spec, runOptions = {}) {
  const startedAtMs = Date.now();
  const startedHr = process.hrtime.bigint();
  const child = spawn("timeout", [String(spec.timeoutSeconds), ...spec.args], {
    cwd: projectRoot,
    env: { ...process.env, ...(spec.env || {}) },
    stdio: ["ignore", "pipe", "pipe"],
  });

  let stdout = "";
  let stderr = "";
  const outputLimit = runOptions.outputLimit ?? 65536;
  child.stdout.on("data", (chunk) => {
    if (stdout.length < outputLimit) stdout += chunk.toString("utf8");
  });
  child.stderr.on("data", (chunk) => {
    if (stderr.length < outputLimit) stderr += chunk.toString("utf8");
  });

  const result = await new Promise((resolve) => {
    child.on("error", (error) => {
      resolve({ code: 127, signal: null, spawnError: error.message });
    });
    child.on("close", (code, signal) => {
      resolve({ code, signal, spawnError: "" });
    });
  });
  const endedAtMs = Date.now();
  const durationMs = Number((process.hrtime.bigint() - startedHr) / 1000000n);
  const exitStatus = typeof result.code === "number" ? result.code : result.signal ? 128 : 1;

  return {
    label: spec.label,
    category: spec.category,
    command: spec.command,
    timeoutSeconds: spec.timeoutSeconds,
    exitStatus,
    signal: result.signal,
    timedOut: exitStatus === 124,
    startedAtMs,
    endedAtMs,
    durationMs,
    stdoutPreview: compactText(stdout),
    stderrPreview: compactText(result.spawnError ? `${result.spawnError}\n${stderr}` : stderr),
  };
}

async function readJsonIfExists(filePath) {
  try {
    return JSON.parse(await readFile(filePath, "utf8"));
  } catch (_error) {
    return null;
  }
}

function defaultCommandPlan(options, tmpDir, claspcBin) {
  const sourceRunCache = path.join(tmpDir, "source-run-cache");
  const compilerSliceTmp = path.join(tmpDir, "compiler-slice-tmp");
  const nativeReportPath = path.join(tmpDir, "native-incremental-report.json");
  const baseEnv = {
    CLASP_CLASPC: claspcBin,
    CLASPC_BIN: claspcBin,
  };
  const plan = [
    commandRecord("source-run-cold", "ordinary-source-run-startup", options.sourceRunTimeoutSeconds, [
      "env",
      `XDG_CACHE_HOME=${sourceRunCache}`,
      "CLASP_NATIVE_TRACE_CACHE=1",
      claspcBin,
      "run",
      "examples/hello.clasp",
    ], { env: baseEnv }),
    commandRecord("source-run-warm", "ordinary-source-run-startup", options.sourceRunTimeoutSeconds, [
      "env",
      `XDG_CACHE_HOME=${sourceRunCache}`,
      "CLASP_NATIVE_TRACE_CACHE=1",
      claspcBin,
      "run",
      "examples/hello.clasp",
    ], { env: baseEnv }),
    commandRecord("compiler-slice-checker", "verifier-heavy-check", options.compilerSliceTimeoutSeconds, [
      "env",
      `CLASP_TEST_TMPDIR=${compilerSliceTmp}`,
      "CLASP_COMPILER_SLICE_TIMEOUT_SECS=45",
      `CLASP_CLASPC=${claspcBin}`,
      `CLASPC_BIN=${claspcBin}`,
      "bash",
      "scripts/verify-compiler-slice.sh",
      "checker",
    ], { env: baseEnv }),
  ];

  if (options.includeNativeIncremental) {
    plan.push(
      commandRecord("native-incremental-body-change", "incremental-cache-benchmark", options.nativeIncrementalTimeoutSeconds, [
        "env",
        `CLASP_CLASPC=${claspcBin}`,
        `CLASPC_BIN=${claspcBin}`,
        "bash",
        "scripts/measure-native-incremental.sh",
        "--scenario",
        "native-cli-body-change",
        "--report",
        nativeReportPath,
      ], { env: baseEnv, reportPath: nativeReportPath }),
    );
  }

  return plan;
}

function fixtureCommandPlan(options, tmpDir) {
  const nativeReportPath = path.join(tmpDir, "fixture-native-incremental-report.json");
  const writeNativeReport = `
const fs = require("node:fs");
const report = {
  scenario: "native-cli-body-change",
  matchesExpectations: true,
  advisoryTimings: {
    nativeImageCold: { realSeconds: 0.08 },
    nativeImageBodyChange: { realSeconds: 0.02 },
    checkCold: { realSeconds: 0.05 },
    checkBodyChange: { realSeconds: 0.015 }
  },
  observedChangedModules: ["Shared.User"]
};
fs.writeFileSync(process.argv[1], JSON.stringify(report, null, 2) + "\\n");
console.log(JSON.stringify(report));
`;
  const sleepPrint = (delayMs, text) => `setTimeout(() => { console.log(${JSON.stringify(text)}); }, ${delayMs});`;
  const plan = [
    commandRecord("source-run-cold", "ordinary-source-run-startup", 5, [
      "node",
      "-e",
      sleepPrint(60, "Hello from Clasp"),
    ]),
    commandRecord("source-run-warm", "ordinary-source-run-startup", 5, [
      "node",
      "-e",
      sleepPrint(5, "Hello from Clasp"),
    ]),
    commandRecord("compiler-slice-checker", "verifier-heavy-check", 5, [
      "node",
      "-e",
      sleepPrint(25, "verify-compiler-slice: ok (checker)"),
    ]),
  ];
  if (options.includeNativeIncremental) {
    plan.push(
      commandRecord("native-incremental-body-change", "incremental-cache-benchmark", 5, [
        "node",
        "-e",
        writeNativeReport,
        nativeReportPath,
      ], { reportPath: nativeReportPath }),
    );
  }
  return plan;
}

function successful(records, label) {
  return records.find((record) => record.label === label && record.exitStatus === 0);
}

function commandSummary(records) {
  const values = {};
  for (const record of records) {
    values[record.label] = {
      category: record.category,
      durationMs: record.durationMs,
      exitStatus: record.exitStatus,
      timedOut: record.timedOut,
    };
  }
  return values;
}

function timingSeconds(report, name) {
  const value = report?.advisoryTimings?.[name]?.realSeconds;
  return Number.isFinite(value) ? value : null;
}

function buildBottlenecks(records, nativeIncrementalReport) {
  const bottlenecks = [];
  const cold = successful(records, "source-run-cold");
  const warm = successful(records, "source-run-warm");
  const checker = successful(records, "compiler-slice-checker");
  const nativeImageCold = timingSeconds(nativeIncrementalReport, "nativeImageCold");
  const checkCold = timingSeconds(nativeIncrementalReport, "checkCold");

  if (cold && warm && cold.durationMs > Math.max(25, warm.durationMs * 1.5)) {
    bottlenecks.push({
      area: "source-run-startup",
      evidence: `source-run-cold ${cold.durationMs}ms versus source-run-warm ${warm.durationMs}ms`,
      opportunity:
        "Keep pressure on the cold `claspc run` native-image-to-binary path; warm run-binary cache hits are already materially cheaper.",
      relatedCommands: ["source-run-cold", "source-run-warm"],
    });
  }

  if (nativeImageCold !== null || checkCold !== null) {
    bottlenecks.push({
      area: "incremental-cache-cold-path",
      evidence: `native incremental advisory timings: nativeImageCold=${nativeImageCold ?? "n/a"}s, checkCold=${checkCold ?? "n/a"}s`,
      opportunity:
        "Use the native incremental trace to separate build-plan/declaration cache misses from checker module-summary misses before optimizing broad verifier loops.",
      relatedCommands: ["native-incremental-body-change"],
    });
  }

  if (checker && (!warm || checker.durationMs > warm.durationMs * 1.5)) {
    bottlenecks.push({
      area: "verifier-heavy-checker-slice",
      evidence: `compiler-slice-checker completed in ${checker.durationMs}ms`,
      opportunity:
        "Treat checker-slice time as the focused verifier proxy; improvements should preserve the existing check/run fixture assertions.",
      relatedCommands: ["compiler-slice-checker"],
    });
  }

  if (bottlenecks.length === 0) {
    const top = records
      .filter((record) => record.exitStatus === 0)
      .sort((left, right) => right.durationMs - left.durationMs)
      .slice(0, 2);
    for (const record of top) {
      bottlenecks.push({
        area: record.category,
        evidence: `${record.label} completed in ${record.durationMs}ms`,
        opportunity: "Use this command as the next bounded timing target before changing compiler/runtime behavior.",
        relatedCommands: [record.label],
      });
    }
  }

  return bottlenecks.slice(0, 2).map((entry, index) => ({ rank: index + 1, ...entry }));
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  await mkdir(options.tmpRoot, { recursive: true });
  const tmpDir = await mkdtemp(path.join(options.tmpRoot, "clasp-benchmark-checkpoint."));
  let tmpKept = options.keepTmp;

  try {
    const claspcBin = options.fixture ? "fixture-claspc" : await resolveClaspc();
    const plan = options.fixture
      ? fixtureCommandPlan(options, tmpDir)
      : defaultCommandPlan(options, tmpDir, claspcBin);
    const records = [];

    for (const spec of plan) {
      records.push(await runCommand(spec));
    }

    const nativeSpec = plan.find((spec) => spec.label === "native-incremental-body-change");
    const nativeIncrementalReport = nativeSpec?.reportPath ? await readJsonIfExists(nativeSpec.reportPath) : null;
    const failed = records.filter((record) => record.exitStatus !== 0);
    const report = {
      schemaVersion: 1,
      kind: "clasp-baseline-bottleneck-checkpoint",
      generatedAt: options.generatedAt,
      projectRoot,
      mode: options.fixture ? "fixture" : "live",
      tmpDir: options.keepTmp ? tmpDir : null,
      claspc: claspcBin,
      commandSummary: commandSummary(records),
      commands: records,
      nativeIncrementalReport,
      bottlenecks: buildBottlenecks(records, nativeIncrementalReport),
      finalStatus: failed.length === 0 ? "ok" : "failed",
      failedCommands: failed.map((record) => record.label),
    };

    const text = `${JSON.stringify(report, null, 2)}\n`;
    if (options.output) {
      await mkdir(path.dirname(path.resolve(options.output)), { recursive: true });
      await writeFile(options.output, text);
    }
    process.stdout.write(text);
    if (failed.length > 0) {
      process.exitCode = 1;
    }
  } finally {
    if (!tmpKept) {
      await rm(tmpDir, { recursive: true, force: true });
    }
  }
}

main().catch((error) => {
  console.error(error?.stack || String(error));
  process.exit(1);
});
