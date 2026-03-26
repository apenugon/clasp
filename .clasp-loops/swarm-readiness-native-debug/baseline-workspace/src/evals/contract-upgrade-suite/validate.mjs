import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { loadCompiledModule, loadTask, stableString, validateCandidate } from "./lib.mjs";

const [, , taskIdArg, candidateArg, compiledArg, contextArg, airArg] = process.argv;

if (!taskIdArg || !candidateArg || !compiledArg || !contextArg || !airArg) {
  console.error("usage: node validate.mjs <task-id> <candidate-dir> <compiled.js> <context.json> <air.json>");
  process.exit(2);
}

const task = loadTask(taskIdArg);
const candidateDir = resolve(process.cwd(), candidateArg);
const compiledPath = resolve(process.cwd(), compiledArg);
const contextPath = resolve(process.cwd(), contextArg);
const airPath = resolve(process.cwd(), airArg);

for (const required of [candidateDir, compiledPath, contextPath, airPath]) {
  if (!existsSync(required)) {
    console.error(`missing required input: ${required}`);
    process.exit(2);
  }
}

const compiled = await loadCompiledModule(compiledPath);
const context = JSON.parse(readFileSync(contextPath, "utf8"));
const air = JSON.parse(readFileSync(airPath, "utf8"));
const result = validateCandidate(task, candidateDir, compiled, context, air);

console.log(stableString(result));
process.exit(result.status === "ok" ? 0 : 1);
