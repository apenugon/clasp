import { writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const [, , compiledPathArg, candidateCompilerPathArg, emittedPathArg] = process.argv;

if (!compiledPathArg || !candidateCompilerPathArg || !emittedPathArg) {
  throw new Error("usage: node examples/compiler-selfhost/demo.mjs <embedded-path> <candidate-compiler-path> <candidate-output-path>");
}

const compiledPath = resolve(compiledPathArg);
const candidateCompilerPath = resolve(candidateCompilerPathArg);
const emittedPath = resolve(emittedPathArg);
const embeddedModule = await import(pathToFileURL(compiledPath).href);
const snapshot = JSON.parse(embeddedModule.main);

writeFileSync(candidateCompilerPath, embeddedModule.candidateCompilerModule);

const candidateCompiler = await import(pathToFileURL(candidateCompilerPath).href);
const candidateEmittedModule = candidateCompiler.compileSelfHostSample();

writeFileSync(emittedPath, candidateEmittedModule);

const emittedModule = await import(pathToFileURL(emittedPath).href);

console.log(
  JSON.stringify({
    embeddedCompilerModule: embeddedModule.candidateCompilerModule,
    embeddedSnapshotJson: embeddedModule.main,
    candidateSnapshotJson: candidateCompiler.main,
    candidateEmittedModule,
    candidateMatchesEmbeddedSnapshot: candidateCompiler.main === embeddedModule.main,
    candidateCompilerMatchesEmbeddedSnapshot: JSON.stringify(candidateCompiler.snapshot) === JSON.stringify(snapshot),
    candidateOutputMatchesEmbedded: candidateEmittedModule === snapshot.emittedModule,
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
