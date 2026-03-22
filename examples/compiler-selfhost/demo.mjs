import { writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const [, , compiledPathArg, stage2CompilerPathArg, emittedPathArg] = process.argv;

if (!compiledPathArg || !stage2CompilerPathArg || !emittedPathArg) {
  throw new Error("usage: node examples/compiler-selfhost/demo.mjs <stage1-path> <stage2-compiler-path> <stage2-output-path>");
}

const compiledPath = resolve(compiledPathArg);
const stage2CompilerPath = resolve(stage2CompilerPathArg);
const emittedPath = resolve(emittedPathArg);
const stage1Module = await import(pathToFileURL(compiledPath).href);
const snapshot = JSON.parse(stage1Module.main);

writeFileSync(stage2CompilerPath, stage1Module.stage2CompilerModule);

const stage2Compiler = await import(pathToFileURL(stage2CompilerPath).href);
const stage2EmittedModule = stage2Compiler.compileSelfHostSample();

writeFileSync(emittedPath, stage2EmittedModule);

const emittedModule = await import(pathToFileURL(emittedPath).href);

console.log(
  JSON.stringify({
    stage1CompilerModule: stage1Module.stage2CompilerModule,
    stage1SnapshotJson: stage1Module.main,
    stage2SnapshotJson: stage2Compiler.main,
    stage2EmittedModule,
    stage2MatchesStage1Snapshot: stage2Compiler.main === stage1Module.main,
    stage2CompilerMatchesStage1Snapshot: JSON.stringify(stage2Compiler.snapshot) === JSON.stringify(snapshot),
    stage2OutputMatchesStage1: stage2EmittedModule === snapshot.emittedModule,
    loweredValue: snapshot.loweredValue,
    loweredFunction: snapshot.loweredFunction,
    loweredModule: snapshot.loweredModule,
    checkedValueType: snapshot.checkedValueType,
    checkedFunctionType: snapshot.checkedFunctionType,
    checkedModule: snapshot.checkedModule,
    mismatchDiagnostic: snapshot.mismatchDiagnostic,
    emittedModule: snapshot.emittedModule,
    emittedGreeting: emittedModule.greeting,
    emittedRender: emittedModule.renderLead(42)
  })
);
