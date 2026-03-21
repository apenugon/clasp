import { writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const [, , compiledPathArg, stage2CompilerPathArg, emittedPathArg] = process.argv;

if (!compiledPathArg || !stage2CompilerPathArg || !emittedPathArg) {
  throw new Error("usage: node src/demo.mjs <stage1-path> <stage2-compiler-path> <stage2-output-path>");
}

const compiledPath = resolve(compiledPathArg);
const stage2CompilerPath = resolve(stage2CompilerPathArg);
const emittedPath = resolve(emittedPathArg);
const stage1Module = await import(pathToFileURL(compiledPath).href);
const snapshot = JSON.parse(stage1Module.main);

writeFileSync(stage2CompilerPath, stage1Module.stage2CompilerModule);

const stage2Compiler = await import(pathToFileURL(stage2CompilerPath).href);
const stage2CheckOutput = stage2Compiler.checkEntrypoint();
const stage2ExplainOutput = stage2Compiler.explainEntrypoint();
const stage2EmittedModule = stage2Compiler.compileEntrypoint();
const stage2NativeOutput = stage2Compiler.nativeEntrypoint();

writeFileSync(emittedPath, stage2EmittedModule);

const emittedModule = await import(pathToFileURL(emittedPath).href);

console.log(
  JSON.stringify({
    stage1CompilerModule: stage1Module.stage2CompilerModule,
    stage1SnapshotJson: stage1Module.main,
    stage2SnapshotJson: stage2Compiler.main,
    stage2CheckOutput,
    stage2ExplainOutput,
    stage2EmittedModule,
    stage2NativeOutput,
    stage2MatchesStage1Snapshot: stage2Compiler.main === stage1Module.main,
    stage2CompilerMatchesStage1Snapshot: JSON.stringify(stage2Compiler.snapshot) === JSON.stringify(snapshot),
    stage2CheckMatchesStage1: stage2CheckOutput === snapshot.checkedModule,
    stage2ExplainMatchesStage1: stage2ExplainOutput === snapshot.explainModule,
    stage2OutputMatchesStage1: stage2EmittedModule === snapshot.emittedModule,
    stage2NativeMatchesStage1: stage2NativeOutput === snapshot.emittedNativeModule,
    loweredValue: snapshot.loweredValue,
    loweredFunction: snapshot.loweredFunction,
    loweredModule: snapshot.loweredModule,
    checkedValueType: snapshot.checkedValueType,
    checkedFunctionType: snapshot.checkedFunctionType,
    checkedModule: snapshot.checkedModule,
    explainModule: snapshot.explainModule,
    mismatchDiagnostic: snapshot.mismatchDiagnostic,
    emittedModule: snapshot.emittedModule,
    emittedNativeModule: snapshot.emittedNativeModule,
    parsedSampleModuleName: snapshot.parsedSampleModuleName,
    parsedSampleImports: snapshot.parsedSampleImports,
    parsedSampleDeclNames: snapshot.parsedSampleDeclNames,
    parsedSampleMainExpr: snapshot.parsedSampleMainExpr,
    secondaryParsedModuleName: snapshot.secondaryParsedModuleName,
    secondaryParsedDeclNames: snapshot.secondaryParsedDeclNames,
    secondaryCheckedModule: snapshot.secondaryCheckedModule,
    secondaryLoweredModule: snapshot.secondaryLoweredModule,
    secondaryEmittedModule: snapshot.secondaryEmittedModule,
    tertiaryParsedModuleName: snapshot.tertiaryParsedModuleName,
    tertiaryParsedDeclNames: snapshot.tertiaryParsedDeclNames,
    tertiaryCheckedModule: snapshot.tertiaryCheckedModule,
    tertiaryLoweredModule: snapshot.tertiaryLoweredModule,
    tertiaryEmittedModule: snapshot.tertiaryEmittedModule,
    quaternaryParsedModuleName: snapshot.quaternaryParsedModuleName,
    quaternaryParsedDeclNames: snapshot.quaternaryParsedDeclNames,
    quaternaryCheckedModule: snapshot.quaternaryCheckedModule,
    quaternaryLoweredModule: snapshot.quaternaryLoweredModule,
    quaternaryEmittedModule: snapshot.quaternaryEmittedModule,
    quinaryParsedModuleName: snapshot.quinaryParsedModuleName,
    quinaryParsedRecordNames: snapshot.quinaryParsedRecordNames,
    quinaryParsedRecordFieldTypes: snapshot.quinaryParsedRecordFieldTypes,
    quinaryParsedDeclNames: snapshot.quinaryParsedDeclNames,
    quinaryCheckedModule: snapshot.quinaryCheckedModule,
    quinaryLoweredModule: snapshot.quinaryLoweredModule,
    quinaryEmittedModule: snapshot.quinaryEmittedModule,
    senaryParsedModuleName: snapshot.senaryParsedModuleName,
    senaryParsedTypeNames: snapshot.senaryParsedTypeNames,
    senaryParsedConstructorSummaries: snapshot.senaryParsedConstructorSummaries,
    senaryChooseAnnotation: snapshot.senaryChooseAnnotation,
    senaryParsedDeclNames: snapshot.senaryParsedDeclNames,
    senaryCheckedModule: snapshot.senaryCheckedModule,
    senaryLoweredModule: snapshot.senaryLoweredModule,
    senaryEmittedModule: snapshot.senaryEmittedModule,
    septenaryParsedModuleName: snapshot.septenaryParsedModuleName,
    septenaryParsedDeclNames: snapshot.septenaryParsedDeclNames,
    septenaryCheckedModule: snapshot.septenaryCheckedModule,
    septenaryLoweredModule: snapshot.septenaryLoweredModule,
    septenaryEmittedModule: snapshot.septenaryEmittedModule,
    emittedHello: emittedModule.hello,
    emittedIdentity: emittedModule.id("Ada"),
    emittedMain: emittedModule.main
  })
);
