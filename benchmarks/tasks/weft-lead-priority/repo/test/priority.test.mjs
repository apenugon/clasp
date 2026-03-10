import assert from "node:assert/strict";
import { installRuntime, serveCompiledModule } from "../runtime/server.mjs";

const compiled = await import("../build/Main.js");

installRuntime({
  mockLeadSummaryModel(lead) {
    const priority =
      lead.priorityHint ??
      (lead.budget >= 50000 ? "high" : lead.budget >= 20000 ? "medium" : "low");

    return JSON.stringify({
      summary: `${lead.company} led by ${lead.contact}`,
      priority,
      followUpRequired: lead.budget >= 20000
    });
  }
});

const port = 4100 + Math.floor(Math.random() * 300);
const server = serveCompiledModule(compiled, { port });

try {
  const response = await fetch(`http://127.0.0.1:${port}/lead/summary`, {
    method: "POST",
    headers: {
      "content-type": "application/json"
    },
    body: JSON.stringify({
      company: "SynthSpeak",
      contact: "Ava",
      budget: 75000,
      priorityHint: "high"
    })
  });

  assert.equal(response.status, 200);
  const payload = await response.json();
  assert.equal(payload.priority, "high");
  assert.equal(payload.followUpRequired, true);
  assert.match(payload.summary, /SynthSpeak/);
} finally {
  server.stop(true);
}
