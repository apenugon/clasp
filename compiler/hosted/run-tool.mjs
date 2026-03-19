import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const [, , commandArg, entryPathArg, stage1PathArg, bootstrapOutputPathArg, resultPathArg] = process.argv;

if (!commandArg || !entryPathArg || !stage1PathArg || !bootstrapOutputPathArg || !resultPathArg) {
  throw new Error(
    "usage: node compiler/hosted/run-tool.mjs <check|compile|explain|native> <entry-path> <stage1-path> <bootstrap-output-path> <result-path>"
  );
}

const command = commandArg;
const entryPath = resolve(entryPathArg);
const stage1Path = resolve(stage1PathArg);
const bootstrapOutputPath = resolve(bootstrapOutputPathArg);
const resultPath = resolve(resultPathArg);

const entrySource = readFileSync(entryPath, "utf8");
const bootstrapOutput = readFileSync(bootstrapOutputPath, "utf8");
const stage1Module = await import(pathToFileURL(stage1Path).href);

async function validateHostedCompileOutput(outputPath) {
  await import(`${pathToFileURL(outputPath).href}?clasp-verify=${Date.now()}`);
}

const commandPlans = {
  check: {
    exportName: "checkSourceText",
    marker: "checkEntrypoint : Str",
    stage2Name: "checkEntrypoint",
    snapshotField: "checkedModule"
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
  }
};

const plan = commandPlans[command];

if (!plan) {
  throw new Error(`unsupported hosted tool command: ${command}`);
}

if (entrySource.includes(plan.marker) && typeof stage1Module.stage2CompilerModule === "string" && typeof stage1Module.main === "string") {
  const stage2CompilerPath = `${resultPath}.stage2.mjs`;
  writeFileSync(stage2CompilerPath, stage1Module.stage2CompilerModule);
  const stage2Compiler = await import(pathToFileURL(stage2CompilerPath).href);
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
  if (command === "compile") {
    writeFileSync(resultPath, stage1Output);
    try {
      await validateHostedCompileOutput(resultPath);
    } catch (error) {
      throw new Error(`hosted compile compatibility check emitted an invalid JavaScript module\n${error instanceof Error ? error.stack ?? error.message : String(error)}`);
    }
  } else {
    if (stage1Output !== bootstrapOutput) {
      throw new Error(`hosted ${command} compatibility check did not reproduce the bootstrap output`);
    }
    writeFileSync(resultPath, stage1Output);
  }
}
