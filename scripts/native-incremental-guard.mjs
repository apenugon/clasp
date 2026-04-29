#!/usr/bin/env node

import fs from "node:fs";

const scenarios = {
  "native-cli-body-change": {
    changedModules: ["Shared.User"],
    unchangedModules: ["Shared.Render", "Main"],
    traces: {
      nativeImage: {
        optionKey: "nativeLog",
        expected: {
          nativeImage: "miss",
          buildPlan: "hit",
          declModule: {
            "Shared.User": "miss",
            "Shared.Render": "hit",
            Main: "hit",
          },
        },
      },
      check: {
        optionKey: "checkLog",
        expected: {
          moduleSummary: {
            "Shared.User": "miss",
            "Shared.Render": "hit",
            Main: "hit",
          },
        },
      },
    },
  },
  "selfhost-body-change": {
    changedModules: ["Helper"],
    unchangedModules: ["Main"],
    traces: {
      check: {
        optionKey: "checkLog",
        expected: {
          moduleSummary: {
            Helper: "validated-hit",
            Main: "hit",
          },
        },
      },
      image: {
        optionKey: "imageLog",
        expected: {
          buildPlan: "hit",
          declModule: {
            Helper: "miss",
            Main: "hit",
          },
          sourceExport: {
            nativeImageProjectText: "miss",
          },
        },
      },
    },
  },
};

function usage() {
  console.error(
    [
      "usage:",
      "  node scripts/native-incremental-guard.mjs <scenario> [--assert] [--report <path>]",
      "    [--native-log <path>] [--check-log <path>] [--image-log <path>]",
      "    [--time <name>=<path>]",
    ].join("\n"),
  );
}

function fail(message) {
  console.error(`native-incremental-guard: ${message}`);
  process.exit(1);
}

function parseArgs(argv) {
  if (argv.length === 0) {
    usage();
    process.exit(1);
  }

  const scenarioName = argv[0];
  const options = {
    assert: false,
    report: "",
    nativeLog: "",
    checkLog: "",
    imageLog: "",
    timePaths: {},
  };

  for (let index = 1; index < argv.length; index += 1) {
    const arg = argv[index];
    switch (arg) {
      case "--assert":
        options.assert = true;
        break;
      case "--report":
        index += 1;
        options.report = argv[index] ?? "";
        break;
      case "--native-log":
        index += 1;
        options.nativeLog = argv[index] ?? "";
        break;
      case "--check-log":
        index += 1;
        options.checkLog = argv[index] ?? "";
        break;
      case "--image-log":
        index += 1;
        options.imageLog = argv[index] ?? "";
        break;
      case "--time": {
        index += 1;
        const value = argv[index] ?? "";
        const equalsIndex = value.indexOf("=");
        if (equalsIndex <= 0 || equalsIndex === value.length - 1) {
          fail(`invalid --time argument: ${value}`);
        }
        const key = value.slice(0, equalsIndex);
        const path = value.slice(equalsIndex + 1);
        options.timePaths[key] = path;
        break;
      }
      default:
        fail(`unsupported argument: ${arg}`);
    }
  }

  return { scenarioName, options };
}

function parseTraceLog(logPath) {
  const text = fs.existsSync(logPath) ? fs.readFileSync(logPath, "utf8") : "";
  const declModule = {};
  const moduleSummary = {};
  const sourceExport = {};
  const changedModules = new Set();
  let buildPlan = "";
  let nativeImage = "";
  let bundle = "";

  for (const line of text.split(/\r?\n/)) {
    let match = /^\[claspc-cache\] build-plan (hit|miss) /.exec(line);
    if (match) {
      buildPlan = match[1];
      continue;
    }

    match = /^\[claspc-cache\] native-image (hit|miss) /.exec(line);
    if (match) {
      nativeImage = match[1];
      continue;
    }

    match = /^\[claspc-cache\] bundle (hit|miss) /.exec(line);
    if (match) {
      bundle = match[1];
      continue;
    }

    match = /^\[claspc-cache\] decl-module (hit|miss) module=([^ ]+) /.exec(line);
    if (match) {
      declModule[match[2]] = match[1];
      if (match[1] === "miss") {
        changedModules.add(match[2]);
      }
      continue;
    }

    match = /^\[claspc-cache\] module-summary (hit|miss|unvalidated-hit|validated-hit) module=([^ ]+) /.exec(line);
    if (match) {
      moduleSummary[match[2]] = match[1];
      if (match[1] === "miss" || match[1] === "validated-hit") {
        changedModules.add(match[2]);
      }
      continue;
    }

    match = /^\[claspc-cache\] source-export (hit|miss) export=([^ ]+) /.exec(line);
    if (match) {
      sourceExport[match[2]] = match[1];
    }
  }

  return {
    logPath,
    buildPlan,
    nativeImage,
    bundle,
    declModule,
    moduleSummary,
    sourceExport,
    changedModules: [...changedModules].sort(),
  };
}

function readRealSeconds(timePath) {
  if (!timePath || !fs.existsSync(timePath)) {
    return null;
  }

  const text = fs.readFileSync(timePath, "utf8");
  const match = /^real\s+([0-9.]+)$/m.exec(text);
  if (!match) {
    return null;
  }

  return Number(match[1]);
}

function compactTrace(trace) {
  if (!trace) {
    return null;
  }

  const value = {
    logPath: trace.logPath,
    changedModules: trace.changedModules,
  };

  if (trace.bundle) {
    value.bundle = trace.bundle;
  }
  if (trace.nativeImage) {
    value.nativeImage = trace.nativeImage;
  }
  if (trace.buildPlan) {
    value.buildPlan = trace.buildPlan;
  }
  if (Object.keys(trace.declModule).length > 0) {
    value.declModule = trace.declModule;
  }
  if (Object.keys(trace.moduleSummary).length > 0) {
    value.moduleSummary = trace.moduleSummary;
  }
  if (Object.keys(trace.sourceExport).length > 0) {
    value.sourceExport = trace.sourceExport;
  }

  return value;
}

function checkExpectedTrace(traceName, expected, observed, mismatches) {
  if (!observed) {
    mismatches.push(`${traceName} trace log missing`);
    return;
  }

  for (const [field, expectedValue] of Object.entries(expected)) {
    if (expectedValue && typeof expectedValue === "object" && !Array.isArray(expectedValue)) {
      const observedMap = observed[field] ?? {};
      for (const [key, expectedEntryValue] of Object.entries(expectedValue)) {
        const actualValue = observedMap[key] ?? "";
        if (actualValue !== expectedEntryValue) {
          mismatches.push(
            `${traceName}.${field}.${key} expected ${expectedEntryValue} got ${actualValue || "missing"}`,
          );
        }
      }
      continue;
    }

    const actualValue = observed[field] ?? "";
    if (actualValue !== expectedValue) {
      mismatches.push(`${traceName}.${field} expected ${expectedValue} got ${actualValue || "missing"}`);
    }
  }
}

const { scenarioName, options } = parseArgs(process.argv.slice(2));
const scenario = scenarios[scenarioName];
if (!scenario) {
  fail(`unknown scenario: ${scenarioName}`);
}

const observedTraces = {};
for (const [traceName, traceSpec] of Object.entries(scenario.traces)) {
  const logPath = options[traceSpec.optionKey];
  if (!logPath) {
    fail(`missing required log for ${traceName}: --${traceSpec.optionKey.replace(/[A-Z]/g, (value) => `-${value.toLowerCase()}`)}`);
  }
  observedTraces[traceName] = parseTraceLog(logPath);
}

const advisoryTimings = {};
for (const [name, timePath] of Object.entries(options.timePaths)) {
  advisoryTimings[name] = {
    path: timePath,
    realSeconds: readRealSeconds(timePath),
  };
}

const mismatches = [];
for (const [traceName, traceSpec] of Object.entries(scenario.traces)) {
  checkExpectedTrace(traceName, traceSpec.expected, observedTraces[traceName], mismatches);
}

const observedChangedModules = [
  ...new Set(Object.values(observedTraces).flatMap((trace) => trace.changedModules)),
].sort();

const report = {
  scenario: scenarioName,
  changedModules: scenario.changedModules,
  unchangedModules: scenario.unchangedModules,
  expectedCacheBehavior: Object.fromEntries(
    Object.entries(scenario.traces).map(([traceName, traceSpec]) => [traceName, traceSpec.expected]),
  ),
  observedCacheBehavior: Object.fromEntries(
    Object.entries(observedTraces).map(([traceName, trace]) => [traceName, compactTrace(trace)]),
  ),
  observedChangedModules,
  advisoryTimings,
  matchesExpectations: mismatches.length === 0,
  mismatches,
};

const reportText = `${JSON.stringify(report, null, 2)}\n`;
if (options.report) {
  fs.writeFileSync(options.report, reportText);
}
process.stdout.write(reportText);

if (options.assert && mismatches.length > 0) {
  process.exit(1);
}
