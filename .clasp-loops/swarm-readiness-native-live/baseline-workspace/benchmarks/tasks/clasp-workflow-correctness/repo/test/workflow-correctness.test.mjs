import assert from "node:assert/strict";

import { runWorkflowCorrectnessDemo } from "../demo.mjs";

const [compiledModulePath] = process.argv.slice(2);

if (!compiledModulePath) {
  throw new Error("usage: node test/workflow-correctness.test.mjs <compiled-module>");
}

const result = await runWorkflowCorrectnessDemo(compiledModulePath);

assert.deepEqual(result.constraintNames, ["belowLimit", "nonNegative", "withinLimit"]);
assert.equal(result.deliveredStatus, "delivered");
assert.equal(result.deliveredResult, 4);
assert.equal(result.resumedCount, 2);
assert.equal(
  result.invariantError,
  "Workflow CounterFlow invariant nonNegative failed during start."
);
assert.equal(result.preconditionStatus, "failed");
assert.equal(
  result.preconditionError,
  "Workflow CounterFlow precondition belowLimit failed during deliver."
);
assert.equal(result.postconditionStatus, "failed");
assert.equal(
  result.postconditionError,
  "Workflow CounterFlow postcondition withinLimit failed during deliver."
);

console.log(JSON.stringify(result));
