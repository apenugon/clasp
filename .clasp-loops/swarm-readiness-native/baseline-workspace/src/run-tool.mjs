import { readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const [, , commandArg, entryPathArg, embeddedPathArg, bootstrapOutputPathArg, resultPathArg, validationDirArg] = process.argv;

if (!commandArg || !entryPathArg || !embeddedPathArg || !bootstrapOutputPathArg || !resultPathArg || !validationDirArg) {
  throw new Error(
    "usage: node src/run-tool.mjs <check|check-core|compile|explain|native|native-image> <entry-path> <embedded-path> <bootstrap-output-path> <result-path> <validation-dir>"
  );
}

const command = commandArg;
const entryPath = resolve(entryPathArg);
const embeddedPath = resolve(embeddedPathArg);
const bootstrapOutputPath = resolve(bootstrapOutputPathArg);
const resultPath = resolve(resultPathArg);
const validationDir = resolve(validationDirArg);

function bustImportCache(filePath, label) {
  return `${pathToFileURL(filePath).href}?${label}=${Date.now()}`;
}

const entrySource = readFileSync(entryPath, "utf8");
const bootstrapOutput = readFileSync(bootstrapOutputPath, "utf8");
const embeddedModule = await import(bustImportCache(embeddedPath, "clasp-embedded"));

async function validateHostedCompileOutput(outputPath) {
  await import(bustImportCache(outputPath, "clasp-verify"));
}

function validateHostedSummaryOutput(commandName, summaryText) {
  const lines = summaryText
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line.length > 0);

  if (lines.length === 0) {
    throw new Error(`hosted ${commandName} compatibility check emitted an empty summary`);
  }

  const invalidLine = lines.find((line) => !/^[A-Za-z_][A-Za-z0-9_]* : .+$/.test(line));

  if (invalidLine) {
    throw new Error(`hosted ${commandName} compatibility check emitted an invalid summary line\n${invalidLine}`);
  }
}

function validateHostedNativeOutput(nativeText) {
  const requiredChecks = [
    ["format header", nativeText.includes("format clasp-native-ir-v1")],
    ["module header", /^module [^\n]+$/m.test(nativeText)],
    ["exports section", /^exports \[[^\n]*\]$/m.test(nativeText)],
    ["abi section", /^abi \{$/m.test(nativeText)],
    ["runtime section", /^runtime \{$/m.test(nativeText)]
  ];

  const missing = requiredChecks
    .filter(([, present]) => !present)
    .map(([label]) => label);

  if (missing.length > 0) {
    throw new Error(`hosted native compatibility check emitted an invalid native module artifact\nmissing ${missing.join(", ")}`);
  }
}

function validateHostedNativeImageOutput(imageText) {
  let value;
  try {
    value = JSON.parse(imageText);
  } catch (error) {
    throw new Error(`hosted native-image compatibility check emitted invalid JSON\n${error instanceof Error ? error.message : String(error)}`);
  }

  const requiredChecks = [
    ["format", value?.format === "clasp-native-image-v1"],
    ["irFormat", value?.irFormat === "clasp-native-ir-v1"],
    ["module", typeof value?.module === "string" && value.module.length > 0],
    ["exports", Array.isArray(value?.exports)],
    ["entrypoints", Array.isArray(value?.entrypoints)],
    ["runtime.profile", typeof value?.runtime?.profile === "string"],
    ["compatibility.kind", value?.compatibility?.kind === "clasp-native-compatibility-v1"],
    ["decls", Array.isArray(value?.decls)]
  ];

  const missing = requiredChecks
    .filter(([, present]) => !present)
    .map(([label]) => label);

  if (missing.length > 0) {
    throw new Error(`hosted native-image compatibility check emitted an invalid native image artifact\nmissing ${missing.join(", ")}`);
  }
}

function validateHostedJsonOutput(commandName, jsonText) {
  try {
    JSON.parse(jsonText);
  } catch (error) {
    throw new Error(`hosted ${commandName} compatibility check emitted invalid JSON\n${error instanceof Error ? error.message : String(error)}`);
  }
}

const commandPlans = {
  check: {
    exportName: "checkSourceText",
    marker: "checkEntrypoint : Str",
    candidateName: "checkEntrypoint",
    snapshotField: "checkedModule"
  },
  "check-core": {
    exportName: "checkCoreSourceText"
  },
  explain: {
    exportName: "explainSourceText",
    marker: "explainEntrypoint : Str",
    candidateName: "explainEntrypoint",
    snapshotField: "explainModule"
  },
  compile: {
    exportName: "compileSourceText",
    marker: "compileEntrypoint : Str",
    candidateName: "compileEntrypoint",
    snapshotField: "emittedModule"
  },
  native: {
    exportName: "nativeSourceText",
    marker: "nativeEntrypoint : Str",
    candidateName: "nativeEntrypoint",
    snapshotField: "emittedNativeModule"
  },
  "native-image": {
    exportName: "nativeImageSourceText",
    marker: "nativeImageEntrypoint : Str",
    candidateName: "nativeImageEntrypoint",
    snapshotField: "emittedNativeImageModule"
  }
};

const plan = commandPlans[command];

if (!plan) {
  throw new Error(`unsupported hosted tool command: ${command}`);
}

if (
  bootstrapOutput.length > 0 &&
  typeof plan.marker === "string" &&
  entrySource.includes(plan.marker) &&
  (typeof embeddedModule.candidateCompilerModule === "string" || typeof embeddedModule.stage2CompilerModule === "string") &&
  typeof embeddedModule.main === "string"
) {
  const embeddedCandidateModule =
    typeof embeddedModule.candidateCompilerModule === "string"
      ? embeddedModule.candidateCompilerModule
      : embeddedModule.stage2CompilerModule;
  const candidateCompilerPath = `${resultPath}.candidate.mjs`;
  writeFileSync(candidateCompilerPath, embeddedCandidateModule);
  const candidateCompiler = await import(bustImportCache(candidateCompilerPath, "clasp-candidate"));
  const snapshot = JSON.parse(embeddedModule.main);
  const candidateRun = candidateCompiler[plan.candidateName];
  if (typeof candidateRun !== "function") {
    throw new Error(`compiler artifact ${embeddedPath} does not expose hosted ${command} support`);
  }
  const candidateOutput = candidateRun();
  if (candidateOutput !== snapshot[plan.snapshotField]) {
    throw new Error(`hosted ${command} compatibility check did not reproduce the embedded snapshot`);
  }
  writeFileSync(resultPath, bootstrapOutput);
} else {
  const compileSource = embeddedModule[plan.exportName];
  if (typeof compileSource !== "function") {
    throw new Error(`compiler artifact ${embeddedPath} does not expose hosted ${command} support`);
  }
  const embeddedOutput = compileSource(entrySource);
  if ((command === "check" || command === "explain") && bootstrapOutput.length === 0) {
    validateHostedSummaryOutput(command, embeddedOutput);
    writeFileSync(resultPath, embeddedOutput);
  } else if (command === "check-core" && bootstrapOutput.length === 0) {
    validateHostedJsonOutput(command, embeddedOutput);
    writeFileSync(resultPath, embeddedOutput);
  } else if (command === "compile") {
    const validationPath = resolve(validationDir, ".clasp-primary-compile-verify.mjs");
    writeFileSync(resultPath, embeddedOutput);
    writeFileSync(validationPath, embeddedOutput);
    try {
      await validateHostedCompileOutput(validationPath);
    } catch (error) {
      throw new Error(`hosted compile compatibility check emitted an invalid JavaScript module\n${error instanceof Error ? error.stack ?? error.message : String(error)}`);
    } finally {
      try {
        unlinkSync(validationPath);
      } catch (_error) {
      }
    }
  } else if (command === "native" && bootstrapOutput.length === 0) {
    validateHostedNativeOutput(embeddedOutput);
    writeFileSync(resultPath, embeddedOutput);
  } else if (command === "native-image" && bootstrapOutput.length === 0) {
    validateHostedNativeImageOutput(embeddedOutput);
    writeFileSync(resultPath, embeddedOutput);
  } else {
    if (embeddedOutput !== bootstrapOutput) {
      throw new Error(`hosted ${command} compatibility check did not reproduce the bootstrap output`);
    }
    writeFileSync(resultPath, embeddedOutput);
  }
}
