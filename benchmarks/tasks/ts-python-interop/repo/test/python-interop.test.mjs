import assert from "node:assert/strict";
import { runPythonInteropDemo } from "../src/main.mjs";

const result = await runPythonInteropDemo();

assert.deepStrictEqual(result, {
  workerRunning: true,
  workerAccepted: true,
  workerLabel: "py:worker-7",
  workerStopped: false,
  workerRestarted: true,
  serviceSummary: "py:Acme:42",
  serviceAccepted: true,
  serviceStopped: false,
  invalid: "budget must be an integer"
});
