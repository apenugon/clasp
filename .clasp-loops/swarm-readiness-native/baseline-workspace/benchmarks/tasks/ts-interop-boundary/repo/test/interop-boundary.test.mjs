import assert from "node:assert/strict";
import { runInteropBoundaryDemo } from "../src/main.mjs";

const result = await runInteropBoundaryDemo();

assert.deepStrictEqual(result, {
  packageKind: "typescript",
  validLabel: "foreign:Acme",
  validAccepted: true,
  invalid:
    "foreign inspectLead via ./support/inspectLead.d.ts failed: accepted must be a boolean"
});
