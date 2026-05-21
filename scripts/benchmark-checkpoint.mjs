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
      "  [--agent-readiness] [--readiness-timeout SECONDS]",
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
    readinessTimeoutSeconds: parsePositiveInt(
      process.env.CLASP_BENCHMARK_READINESS_TIMEOUT_SECS || "180",
      "agent readiness timeout",
    ),
    includeNativeIncremental: true,
    agentReadiness: false,
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
      case "--agent-readiness":
        options.agentReadiness = true;
        break;
      case "--readiness-timeout":
        options.readinessTimeoutSeconds = parsePositiveInt(argv[++index], "--readiness-timeout");
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

function defaultAgentReadinessCommandPlan(options, tmpDir) {
  const timeoutSeconds = options.readinessTimeoutSeconds;
  const baseEnv = { CLASP_TEST_TMPDIR: path.join(tmpDir, "agent-readiness") };
  return [
    commandRecord("safe-workspace-operations", "ordinary-program-workspace-safety", timeoutSeconds, [
      "bash",
      "scripts/test-safe-workspace.sh",
    ], { env: baseEnv }),
    commandRecord("safe-subprocess-verifier-execution", "ordinary-program-subprocess-safety", timeoutSeconds, [
      "bash",
      "scripts/test-safe-subprocess.sh",
    ], { env: baseEnv }),
    commandRecord("structured-diagnostics-feedback", "machine-readable-diagnostics", timeoutSeconds, [
      "bash",
      "scripts/test-native-claspc-diagnostics.sh",
    ], { env: baseEnv }),
    commandRecord("ordinary-agent-loop-scenario", "ordinary-program-agent-loop", timeoutSeconds, [
      "bash",
      "examples/agent-loop-scenario/scripts/verify.sh",
    ], { env: baseEnv }),
  ];
}

function fixtureAgentReadinessCommandPlan(options) {
  const timeoutSeconds = Math.min(options.readinessTimeoutSeconds, 5);
  const print = (text) => `process.stdout.write(${JSON.stringify(`${text}\n`)});`;
  return [
    commandRecord("safe-workspace-operations", "ordinary-program-workspace-safety", timeoutSeconds, [
      "node",
      "-e",
      print("safe-workspace-ok"),
    ]),
    commandRecord("safe-subprocess-verifier-execution", "ordinary-program-subprocess-safety", timeoutSeconds, [
      "node",
      "-e",
      print("safe-subprocess-ok"),
    ]),
    commandRecord("structured-diagnostics-feedback", "machine-readable-diagnostics", timeoutSeconds, [
      "node",
      "-e",
      print("test-native-claspc-diagnostics: ok"),
    ]),
    commandRecord("ordinary-agent-loop-scenario", "ordinary-program-agent-loop", timeoutSeconds, [
      "node",
      "-e",
      print("agent-loop-scenario-ok"),
    ]),
  ];
}

const readinessSignalDefinitions = [
  {
    name: "safeWorkspaceOperations",
    commandLabel: "safe-workspace-operations",
    category: "safe-workspace-operations",
    benchmarkRelevance:
      "Ordinary Clasp programs can perform root-bounded reads, writes, directory creation, listing, and path-escape rejection.",
  },
  {
    name: "subprocessVerifierExecution",
    commandLabel: "safe-subprocess-verifier-execution",
    category: "subprocess-verifier-execution",
    benchmarkRelevance:
      "Ordinary Clasp programs can run verifier-style subprocesses with confined cwd, captured stdout/stderr, exit status, and timeout data.",
  },
  {
    name: "structuredDiagnostics",
    commandLabel: "structured-diagnostics-feedback",
    category: "structured-diagnostics",
    benchmarkRelevance:
      "Parser/checker failures expose stable machine-readable fields that benchmark verifiers and agent loops can assert.",
  },
  {
    name: "ordinaryProgramAgentLoop",
    commandLabel: "ordinary-agent-loop-scenario",
    category: "ordinary-program-scenario",
    benchmarkRelevance:
      "A Clasp program invokes Codex directly, writes durable artifacts/status/events, runs a verifier command, and returns a structured report.",
  },
];

const capabilitySignalDefinitions = [
  {
    name: "ordinary_program_execution",
    commandLabels: ["ordinary-agent-loop-scenario"],
    statusWhenPassed: "pass",
    coverage: "claspc run executes the ordinary Clasp builder/verifier loop scenario.",
  },
  {
    name: "durable_native_substrate",
    commandLabels: ["ordinary-agent-loop-scenario"],
    statusWhenPassed: "partial",
    coverage:
      "The probe covers durable status, event, and artifact persistence; DAG edges, leases, approvals, and merge-policy state remain outside this bounded checkpoint.",
  },
  {
    name: "clasp_native_control_api",
    commandLabels: [
      "safe-workspace-operations",
      "safe-subprocess-verifier-execution",
      "ordinary-agent-loop-scenario",
    ],
    statusWhenPassed: "pass",
    coverage: "Ordinary Clasp code reaches workspace and subprocess orchestration APIs without compiler swarm commands.",
  },
  {
    name: "orchestration_viability",
    commandLabels: [
      "safe-workspace-operations",
      "safe-subprocess-verifier-execution",
      "structured-diagnostics-feedback",
      "ordinary-agent-loop-scenario",
    ],
    statusWhenPassed: "pass",
    coverage:
      "The combined probe checks file access, process execution, diagnostics, and a realistic builder/verifier loop fixture.",
  },
  {
    name: "ergonomics",
    commandLabels: [
      "safe-workspace-operations",
      "safe-subprocess-verifier-execution",
      "structured-diagnostics-feedback",
    ],
    statusWhenPassed: "pass",
    coverage: "State-heavy orchestration examples remain expressible through small ordinary Clasp wrappers and stable failure data.",
  },
  {
    name: "verification_gate",
    commandLabels: [
      "safe-workspace-operations",
      "safe-subprocess-verifier-execution",
      "structured-diagnostics-feedback",
      "ordinary-agent-loop-scenario",
    ],
    statusWhenPassed: "pass",
    coverage:
      "Focused scenario-level checks exist for the benchmark-relevant ordinary-program loop and runtime/control-plane behavior.",
  },
];

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

function recordStatus(record) {
  if (!record) return "missing";
  if (record.timedOut) return "timeout";
  return record.exitStatus === 0 ? "pass" : "fail";
}

function buildReadinessSignals(records) {
  return readinessSignalDefinitions.map((definition) => {
    const record = records.find((candidate) => candidate.label === definition.commandLabel);
    const status = recordStatus(record);
    return {
      name: definition.name,
      category: definition.category,
      status,
      commandLabel: definition.commandLabel,
      durationMs: record?.durationMs ?? null,
      exitStatus: record?.exitStatus ?? null,
      timedOut: record?.timedOut ?? null,
      evidence: record
        ? `${record.label} exitStatus=${record.exitStatus} timedOut=${record.timedOut}`
        : `${definition.commandLabel} did not run`,
      benchmarkRelevance: definition.benchmarkRelevance,
    };
  });
}

function buildCapabilitySignals(records) {
  return capabilitySignalDefinitions.map((definition) => {
    const commandStatuses = definition.commandLabels.map((label) => ({
      commandLabel: label,
      status: recordStatus(records.find((record) => record.label === label)),
    }));
    const allPassed = commandStatuses.every((entry) => entry.status === "pass");
    return {
      name: definition.name,
      status: allPassed ? definition.statusWhenPassed : "fail",
      coverage: definition.coverage,
      evidenceCommands: definition.commandLabels,
      commandStatuses,
    };
  });
}

function readinessSignalSummary(signals) {
  const summary = {};
  for (const signal of signals) {
    summary[signal.name] = signal.status;
  }
  return summary;
}

function agentReadinessReport(options, tmpDir, records) {
  const failed = records.filter((record) => record.exitStatus !== 0);
  const readinessSignals = buildReadinessSignals(records);
  return {
    schemaVersion: 1,
    kind: "clasp-agent-readiness-checkpoint",
    generatedAt: options.generatedAt,
    projectRoot,
    mode: options.fixture ? "fixture" : "live",
    fullBenchmarkRun: false,
    tmpDir: options.keepTmp ? tmpDir : null,
    checkpointFocus: [
      "safe workspace operations",
      "subprocess verifier execution",
      "structured diagnostics",
      "ordinary-program agent loop scenario",
    ],
    commandSummary: commandSummary(records),
    commands: records,
    readinessSignals,
    readinessSignalSummary: readinessSignalSummary(readinessSignals),
    capabilitySignals: buildCapabilitySignals(records),
    finalStatus: failed.length === 0 ? "ok" : "failed",
    failedCommands: failed.map((record) => record.label),
  };
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  await mkdir(options.tmpRoot, { recursive: true });
  const tmpDir = await mkdtemp(path.join(options.tmpRoot, "clasp-benchmark-checkpoint."));
  let tmpKept = options.keepTmp;

  try {
    const claspcBin = options.agentReadiness ? null : options.fixture ? "fixture-claspc" : await resolveClaspc();
    const plan = options.agentReadiness
      ? options.fixture
        ? fixtureAgentReadinessCommandPlan(options)
        : defaultAgentReadinessCommandPlan(options, tmpDir)
      : options.fixture
        ? fixtureCommandPlan(options, tmpDir)
        : defaultCommandPlan(options, tmpDir, claspcBin);
    const records = [];

    for (const spec of plan) {
      records.push(await runCommand(spec));
    }

    if (options.agentReadiness) {
      const report = agentReadinessReport(options, tmpDir, records);
      const text = `${JSON.stringify(report, null, 2)}\n`;
      if (options.output) {
        await mkdir(path.dirname(path.resolve(options.output)), { recursive: true });
        await writeFile(options.output, text);
      }
      process.stdout.write(text);
      if (report.failedCommands.length > 0) {
        process.exitCode = 1;
      }
      return;
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
