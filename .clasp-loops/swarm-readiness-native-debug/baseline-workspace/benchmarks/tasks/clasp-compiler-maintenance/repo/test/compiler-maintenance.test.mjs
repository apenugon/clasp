import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const [compiledPathArg, stage2CompilerPathArg, stage2OutputPathArg] = process.argv.slice(2);

if (!compiledPathArg || !stage2CompilerPathArg || !stage2OutputPathArg) {
  throw new Error(
    "usage: node test/compiler-maintenance.test.mjs <compiled-main> <stage2-compiler> <stage2-output>"
  );
}

const workspaceRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const demoPath = path.join(workspaceRoot, "demo.mjs");
const compiledPath = path.resolve(compiledPathArg);
const stage2CompilerPath = path.resolve(stage2CompilerPathArg);
const stage2OutputPath = path.resolve(stage2OutputPathArg);
const stdout = execFileSync(
  process.execPath,
  [demoPath, compiledPath, stage2CompilerPath, stage2OutputPath],
  { encoding: "utf8" }
);
const result = JSON.parse(stdout.trim().split("\n").at(-1));
const emittedModule = await import(`${pathToFileURL(stage2OutputPath).href}?t=${Date.now()}`);

assert.equal(result.stage2MatchesStage1Snapshot, true);
assert.equal(result.stage2CompilerMatchesStage1Snapshot, true);
assert.equal(result.stage2OutputMatchesStage1, true);
assert.equal(result.loweredValue, "const greeting = literal:hello");
assert.equal(result.loweredFunction, "function renderLead(lead) = call String(lead)");
assert.equal(result.loweredPreviewFlag, "const previewEnabled = literal:true");
assert.equal(result.checkedValueType, "Str");
assert.equal(result.checkedFunctionType, "?lead -> Str");
assert.equal(result.checkedPreviewFlagType, "Bool");
assert.match(result.emittedModule, /export const previewEnabled = true;/);
assert.equal(emittedModule.greeting, "hello");
assert.equal(emittedModule.renderLead(42), "42");
assert.equal(emittedModule.previewEnabled, true);

console.log(JSON.stringify(result));
