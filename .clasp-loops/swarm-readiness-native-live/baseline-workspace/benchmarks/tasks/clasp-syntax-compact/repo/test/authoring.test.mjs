import assert from "node:assert/strict";

const compiled = await import("../build/Main.js");

assert.equal(compiled.main, "SynthSpeak [high]");
