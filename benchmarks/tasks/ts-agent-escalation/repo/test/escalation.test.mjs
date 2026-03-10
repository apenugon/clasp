import assert from "node:assert/strict";
import { test } from "node:test";
import { parseAgentDecision, shouldEscalate } from "../dist/agent/decision.js";

test("parseAgentDecision accepts escalate decisions and shouldEscalate marks them", () => {
  const decision = parseAgentDecision({
    action: "escalate",
    summary: "A human needs to review this request",
    confidence: 0.18,
    reason: "billing_dispute"
  });

  assert.equal(decision.action, "escalate");
  assert.equal(decision.reason, "billing_dispute");
  assert.equal(shouldEscalate(decision), true);
});

test("parseAgentDecision reports informative validation errors", () => {
  assert.throws(
    () =>
      parseAgentDecision({
        action: "escalate",
        summary: 42,
        confidence: 2
      }),
    /summary.*string.*confidence.*0 and 1/i
  );
});
