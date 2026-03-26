import assert from "node:assert/strict";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { runControlPlaneDemo } from "../demo.mjs";

const compiledModulePath = fileURLToPath(new URL("../build/Main.js", import.meta.url));
const result = await runControlPlaneDemo(compiledModulePath);

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
    summary: "deprecated/bootstrap/src/Clasp/Compiler.hs\ntest/Main.hs"
  },
  {
    step: "verify",
    requestId: "release:0",
    method: "search_repo",
    allowed: true,
    summary: "verification:ok"
  }
]);
