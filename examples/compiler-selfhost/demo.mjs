import { writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const [, , compiledPathArg, emittedPathArg] = process.argv;

if (!compiledPathArg || !emittedPathArg) {
  throw new Error("usage: bun examples/compiler-selfhost/demo.mjs <compiled-path> <emitted-path>");
}

const compiledPath = resolve(compiledPathArg);
const emittedPath = resolve(emittedPathArg);
const compiledModule = await import(pathToFileURL(compiledPath).href);
const snapshot = JSON.parse(compiledModule.main);

writeFileSync(emittedPath, snapshot.emittedModule);

const emittedModule = await import(pathToFileURL(emittedPath).href);

console.log(
  JSON.stringify({
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
