import { writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const [, , compiledPathArg, candidateCompilerPathArg, emittedPathArg] = process.argv;

if (!compiledPathArg || !candidateCompilerPathArg || !emittedPathArg) {
  throw new Error("usage: node src/demo.mjs <embedded-path> <candidate-compiler-path> <candidate-output-path>");
}

const compiledPath = resolve(compiledPathArg);
const candidateCompilerPath = resolve(candidateCompilerPathArg);
const emittedPath = resolve(emittedPathArg);
const embeddedModule = await import(pathToFileURL(compiledPath).href);
const snapshot = JSON.parse(embeddedModule.main);

writeFileSync(candidateCompilerPath, embeddedModule.candidateCompilerModule);

const candidateCompiler = await import(pathToFileURL(candidateCompilerPath).href);
const candidateCheckOutput = candidateCompiler.checkEntrypoint();
const candidateExplainOutput = candidateCompiler.explainEntrypoint();
const candidateEmittedModule = candidateCompiler.compileEntrypoint();
const candidateNativeOutput = candidateCompiler.nativeEntrypoint();

writeFileSync(emittedPath, candidateEmittedModule);

const emittedModule = await import(pathToFileURL(emittedPath).href);

console.log(
  JSON.stringify({
    embeddedCompilerModule: embeddedModule.candidateCompilerModule,
    embeddedSnapshotJson: embeddedModule.main,
    candidateSnapshotJson: candidateCompiler.main,
    candidateCheckOutput,
    candidateExplainOutput,
    candidateEmittedModule,
    candidateNativeOutput,
    candidateMatchesEmbeddedSnapshot: candidateCompiler.main === embeddedModule.main,
    candidateCompilerMatchesEmbeddedSnapshot: JSON.stringify(candidateCompiler.snapshot) === JSON.stringify(snapshot),
    candidateCheckMatchesEmbedded: candidateCheckOutput === snapshot.checkedModule,
    candidateExplainMatchesEmbedded: candidateExplainOutput === snapshot.explainModule,
    candidateOutputMatchesEmbedded: candidateEmittedModule === snapshot.emittedModule,
    candidateNativeMatchesEmbedded: candidateNativeOutput === snapshot.emittedNativeModule,
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
