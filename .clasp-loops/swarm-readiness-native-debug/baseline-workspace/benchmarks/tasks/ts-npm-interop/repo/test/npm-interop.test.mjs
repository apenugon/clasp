import assert from "node:assert/strict";
import { runInteropDemo } from "../src/main.mjs";

const result = await runInteropDemo();

assert.deepStrictEqual(result, {
  packageKinds: ["npm", "typescript"],
  upper: "HELLO ADA",
  formatted: "Acme Labs:7"
});
