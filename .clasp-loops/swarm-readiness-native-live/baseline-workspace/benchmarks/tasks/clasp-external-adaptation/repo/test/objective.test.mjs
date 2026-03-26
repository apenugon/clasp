import assert from "node:assert/strict";

import { runLeadObjectiveDemo } from "../demo.mjs";

const compiled = await import("../build/Main.js");
const result = await runLeadObjectiveDemo(compiled);

assert.equal(result.feedbackSignalName, "growth_reply_rate_below_goal");
assert.equal(result.signalObjective, "reply-rate");
assert.equal(result.changePlanName, "growth-outreach-tune");
assert.deepEqual(result.changePlanTargetIds, [
  "decl:outreachPrompt",
  "test:lead-benchmark.objective"
]);
assert.equal(result.changePlanStepCount, 2);
assert.equal(
  result.invalidChange,
  "Change target route:secondaryLeadRecordRoute is outside the observed signal scope"
);
