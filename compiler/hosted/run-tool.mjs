import { readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const [, , commandArg, entryPathArg, stage1PathArg, bootstrapOutputPathArg, resultPathArg, validationDirArg] = process.argv;

if (!commandArg || !entryPathArg || !stage1PathArg || !bootstrapOutputPathArg || !resultPathArg || !validationDirArg) {
  throw new Error(
    "usage: node compiler/hosted/run-tool.mjs <check|check-core|compile|explain|native|native-image> <entry-path> <stage1-path> <bootstrap-output-path> <result-path> <validation-dir>"
  );
}

const command = commandArg;
const entryPath = resolve(entryPathArg);
const stage1Path = resolve(stage1PathArg);
const bootstrapOutputPath = resolve(bootstrapOutputPathArg);
const resultPath = resolve(resultPathArg);
const validationDir = resolve(validationDirArg);

function bustImportCache(filePath, label) {
  return `${pathToFileURL(filePath).href}?${label}=${Date.now()}`;
}

const entrySource = readFileSync(entryPath, "utf8");
const bootstrapOutput = readFileSync(bootstrapOutputPath, "utf8");
const stage1Module = await import(bustImportCache(stage1Path, "clasp-stage1"));

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
    stage2Name: "checkEntrypoint",
    snapshotField: "checkedModule"
  },
  "check-core": {
    exportName: "checkCoreSourceText"
  },
  explain: {
    exportName: "explainSourceText",
    marker: "explainEntrypoint : Str",
    stage2Name: "explainEntrypoint",
    snapshotField: "explainModule"
  },
  compile: {
    exportName: "compileSourceText",
    marker: "compileEntrypoint : Str",
    stage2Name: "compileEntrypoint",
    snapshotField: "emittedModule"
  },
  native: {
    exportName: "nativeSourceText",
    marker: "nativeEntrypoint : Str",
    stage2Name: "nativeEntrypoint",
    snapshotField: "emittedNativeModule"
  },
  "native-image": {
    exportName: "nativeImageSourceText",
    marker: "nativeImageEntrypoint : Str",
    stage2Name: "nativeImageEntrypoint",
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
  typeof stage1Module.stage2CompilerModule === "string" &&
  typeof stage1Module.main === "string"
) {
  const stage2CompilerPath = `${resultPath}.stage2.mjs`;
  writeFileSync(stage2CompilerPath, stage1Module.stage2CompilerModule);
  const stage2Compiler = await import(bustImportCache(stage2CompilerPath, "clasp-stage2"));
  const snapshot = JSON.parse(stage1Module.main);
  const stage2Run = stage2Compiler[plan.stage2Name];
  if (typeof stage2Run !== "function") {
    throw new Error(`compiler artifact ${stage1Path} does not expose hosted ${command} support`);
  }
  const stage2Output = stage2Run();
  if (stage2Output !== snapshot[plan.snapshotField]) {
    throw new Error(`hosted ${command} compatibility check did not reproduce the stage1 snapshot`);
  }
  writeFileSync(resultPath, bootstrapOutput);
} else {
  const compileSource = stage1Module[plan.exportName];
  if (typeof compileSource !== "function") {
    throw new Error(`compiler artifact ${stage1Path} does not expose hosted ${command} support`);
  }
  const stage1Output = compileSource(entrySource);
  if ((command === "check" || command === "explain") && bootstrapOutput.length === 0) {
    validateHostedSummaryOutput(command, stage1Output);
    writeFileSync(resultPath, stage1Output);
  } else if (command === "check-core" && bootstrapOutput.length === 0) {
    validateHostedJsonOutput(command, stage1Output);
    writeFileSync(resultPath, stage1Output);
  } else if (command === "compile") {
    const validationPath = resolve(validationDir, ".clasp-primary-compile-verify.mjs");
    writeFileSync(resultPath, stage1Output);
    writeFileSync(validationPath, stage1Output);
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
    validateHostedNativeOutput(stage1Output);
    writeFileSync(resultPath, stage1Output);
  } else if (command === "native-image" && bootstrapOutput.length === 0) {
    validateHostedNativeImageOutput(stage1Output);
    writeFileSync(resultPath, stage1Output);
  } else {
    if (stage1Output !== bootstrapOutput) {
      throw new Error(`hosted ${command} compatibility check did not reproduce the bootstrap output`);
    }
    writeFileSync(resultPath, stage1Output);
  }
}
