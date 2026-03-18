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
const stage2CompilerPath = `${resultPath}.stage2.mjs`;

writeFileSync(stage2CompilerPath, stage1Module.stage2CompilerModule);

const stage2Compiler = await import(pathToFileURL(stage2CompilerPath).href);
const snapshot = JSON.parse(stage1Module.main);

const commandPlans = {
  check: {
    marker: "checkEntrypoint : Str",
    run: () => stage2Compiler.checkEntrypoint(),
    expected: snapshot.checkedModule
  },
  explain: {
    marker: "explainEntrypoint : Str",
    run: () => stage2Compiler.explainEntrypoint(),
    expected: snapshot.explainModule
  },
  compile: {
    marker: "compileEntrypoint : Str",
    run: () => stage2Compiler.compileEntrypoint(),
    expected: snapshot.emittedModule
  },
  native: {
    marker: "nativeEntrypoint : Str",
    run: () => stage2Compiler.nativeEntrypoint(),
    expected: snapshot.emittedNativeModule
  }
};

const plan = commandPlans[command];

if (!plan) {
  throw new Error(`unsupported hosted tool command: ${command}`);
}

if (!entrySource.includes(plan.marker)) {
  throw new Error(`entrypoint ${entryPath} does not expose hosted ${command} support`);
}

const stage2Output = plan.run();

if (stage2Output !== plan.expected) {
  throw new Error(`hosted ${command} compatibility check did not reproduce the stage1 snapshot`);
}

writeFileSync(resultPath, bootstrapOutput);
