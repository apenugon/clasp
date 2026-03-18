import assert from "node:assert/strict";
import net from "node:net";
import { installRuntime, serveCompiledModule } from "../runtime/server.mjs";

const compiled = await import("../build/Main.js");

function toWirePriority(value) {
  if (typeof value === "string") {
    return value;
  }

  if (typeof value === "object" && value !== null && typeof value.$tag === "string") {
    return value.$tag.toLowerCase();
  }

  return undefined;
}

async function postSummary(port, body) {
  return fetch(`http://127.0.0.1:${port}/lead/summary`, {
    method: "POST",
    headers: {
      "content-type": "application/json"
    },
    body: JSON.stringify(body)
  });
}

async function allocatePort() {
  return await new Promise((resolve, reject) => {
    const socket = net.createServer();

    socket.once("error", reject);
    socket.listen(0, "127.0.0.1", () => {
      const address = socket.address();

      if (!address || typeof address === "string") {
        socket.close(() => reject(new Error("failed to allocate an ephemeral port")));
        return;
      }

      const { port } = address;
      socket.close((error) => {
        if (error) {
          reject(error);
          return;
        }

        resolve(port);
      });
    });
  });
}

async function withServer(binding, callback) {
  installRuntime({
    mockLeadSummaryModel: binding
  });

  const port = await allocatePort();
  const server = serveCompiledModule(compiled, { port });

  try {
    await callback(port);
  } finally {
    server.stop(true);
  }
}

await withServer((lead) => {
  const priority =
    toWirePriority(lead.priorityHint) ??
    (lead.budget >= 50000 ? "high" : lead.budget >= 20000 ? "medium" : "low");

  return JSON.stringify({
    summary: `${lead.company} led by ${lead.contact}`,
    priority,
    followUpRequired: lead.budget >= 20000
  });
}, async (port) => {
  const response = await postSummary(port, {
    company: "SynthSpeak",
    contact: "Ava",
    budget: 75000,
    priorityHint: "high"
  });

  assert.equal(response.status, 200);
  const payload = await response.json();
  assert.equal(payload.priority, "high");
  assert.equal(payload.followUpRequired, true);
  assert.match(payload.summary, /SynthSpeak/);
});

await withServer((lead) =>
  JSON.stringify({
    summary: `${lead.company} led by ${lead.contact}`,
    priority: toWirePriority(lead.priorityHint) ?? "medium",
    followUpRequired: lead.budget >= 20000
  }),
async (port) => {
  const response = await postSummary(port, {
    company: "SynthSpeak",
    contact: "Ava",
    budget: 75000
  });

  assert.equal(response.status, 400);
  const payload = await response.json();
  assert.equal(payload.error, "invalid_request");
});

await withServer((lead) =>
  JSON.stringify({
    summary: `${lead.company} led by ${lead.contact}`,
    priority: toWirePriority(lead.priorityHint) ?? "medium",
    followUpRequired: lead.budget >= 20000
  }),
async (port) => {
  const response = await postSummary(port, {
    company: "SynthSpeak",
    contact: "Ava",
    budget: 75000,
    priorityHint: "urgent"
  });

  assert.equal(response.status, 400);
  const payload = await response.json();
  assert.equal(payload.error, "invalid_request");
});

await withServer(() =>
  JSON.stringify({
    summary: "SynthSpeak led by Ava",
    priority: "urgent",
    followUpRequired: true
  }),
async (port) => {
  const response = await postSummary(port, {
    company: "SynthSpeak",
    contact: "Ava",
    budget: 75000,
    priorityHint: "high"
  });

  assert.equal(response.status, 502);
  const payload = await response.json();
  assert.equal(payload.error, "handler_failed");
});
