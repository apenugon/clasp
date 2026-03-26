import assert from "node:assert/strict";
import { test } from "node:test";
import { runControlPlaneDemo } from "../dist/controlPlane.js";

test("runControlPlaneDemo preserves verifier flow and least privilege", async () => {
  const result = await runControlPlaneDemo();

  assert.equal(result.agent, "builder");
  assert.equal(result.approval, "on_request");
  assert.equal(result.sandbox, "workspace_write");
  assert.equal(result.hookAccepted, true);
  assert.equal(result.taskQueue, "Inspect the repo first, then run the merge gate.");
  assert.equal(result.verificationGuide, "Run bash scripts/verify-all.sh before finishing.");
  assert.equal(result.mergeGateRequest, "release:0");

  assert.deepEqual(result.allowed, {
    file: true,
    network: true,
    processRg: true,
    processBash: true,
    secret: true
  });

  assert.deepEqual(result.denied, {
    file: false,
    network: false,
    process: false,
    secret: false
  });

  assert.deepEqual(result.steps, [
    {
      step: "inspect",
      requestId: "release:inspect",
      method: "search_repo",
      allowed: true,
      summary: "src/controlPlane.ts\ntest/control-plane.test.mjs"
    },
    {
      step: "verify",
      requestId: "release:0",
      method: "search_repo",
      allowed: true,
      summary: "verification:ok"
    }
  ]);
});
