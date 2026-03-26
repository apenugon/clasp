import { existsSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const [, , candidateArg, compiledArg] = process.argv;

if (!candidateArg || !compiledArg) {
  console.error("usage: node baseline-validate.mjs <candidate-dir> <compiled.js>");
  process.exit(2);
}

const candidateDir = resolve(process.cwd(), candidateArg);
const compiledPath = resolve(process.cwd(), compiledArg);

if (!existsSync(candidateDir)) {
  console.error(`candidate directory does not exist: ${candidateDir}`);
  process.exit(2);
}

if (!existsSync(compiledPath)) {
  console.error(`compiled module does not exist: ${compiledPath}`);
  process.exit(2);
}

const compiled = await import(`${pathToFileURL(compiledPath).href}?t=${Date.now()}`);
const issues = [];

if (compiled.main !== "senior-ae") {
  issues.push(`expected compiled main to be \"senior-ae\", got ${JSON.stringify(compiled.main)}`);
}

if (issues.length > 0) {
  console.log(
    JSON.stringify(
      {
        status: "error",
        eval: "lead-digest-upgrade",
        mode: "baseline",
        candidateDir,
        issueCount: issues.length,
        issues
      },
      null,
      2
    )
  );
  process.exit(1);
}

console.log(
  JSON.stringify(
    {
      status: "ok",
      eval: "lead-digest-upgrade",
      mode: "baseline",
      candidateDir,
      main: compiled.main
    },
    null,
    2
  )
);
