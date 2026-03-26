import assert from "node:assert/strict";
import path from "node:path";
import { pathToFileURL } from "node:url";

async function postSummary(port, body) {
  return fetch(`http://127.0.0.1:${port}/lead/summary`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });
}

const projectRoot = process.env.CLASP_PROJECT_ROOT;
const binaryPath = process.env.CLASP_BENCH_BINARY;

if (!projectRoot || !binaryPath) {
  throw new Error("CLASP_PROJECT_ROOT and CLASP_BENCH_BINARY are required");
}

const { withNativeServer } = await import(
  pathToFileURL(path.join(projectRoot, "benchmarks/native-http-test.mjs")).href
);

await withNativeServer(binaryPath, async ({ port }) => {
  const response = await postSummary(port, {
    company: "SynthSpeak",
    contact: "Ava",
    budget: 75000,
    priorityHint: "high",
  });

  assert.equal(response.status, 200);
  const payload = await response.json();
  assert.equal(payload.priority, "high");
  assert.equal(payload.followUpRequired, true);
  assert.match(payload.summary, /SynthSpeak/);
});

await withNativeServer(binaryPath, async ({ port }) => {
  const response = await postSummary(port, {
    company: "SynthSpeak",
    contact: "Ava",
    budget: 75000,
  });

  assert.equal(response.status, 400);
  const payload = await response.json();
  assert.ok(typeof payload.error === "string");
});

await withNativeServer(binaryPath, async ({ port }) => {
  const response = await postSummary(port, {
    company: "SynthSpeak",
    contact: "Ava",
    budget: 75000,
    priorityHint: "urgent",
  });

  assert.equal(response.status, 400);
  const payload = await response.json();
  assert.ok(typeof payload.error === "string");
});

await withNativeServer(binaryPath, async ({ port }) => {
  const response = await postSummary(port, {
    company: "SynthSpeak",
    contact: "Ava",
    budget: 75000,
    priorityHint: "high",
  });

  assert.equal(response.status, 502);
  const payload = await response.json();
  assert.equal(payload.error, "route_dispatch_failed");
}, {
  env: {
    CLASP_MOCK_LEAD_SUMMARY_PRIORITY: "Urgent",
  },
});
