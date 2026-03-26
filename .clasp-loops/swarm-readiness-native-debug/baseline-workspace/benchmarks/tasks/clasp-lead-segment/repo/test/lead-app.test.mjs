import assert from "node:assert/strict";
import path from "node:path";
import { pathToFileURL } from "node:url";

async function request(port, routePath, init = {}) {
  return fetch(`http://127.0.0.1:${port}${routePath}`, init);
}

const projectRoot = process.env.CLASP_PROJECT_ROOT;
const binaryPath = process.env.CLASP_BENCH_BINARY;

if (!projectRoot || !binaryPath) {
  throw new Error("CLASP_PROJECT_ROOT and CLASP_BENCH_BINARY are required");
}

const {
  collectTexts,
  firstFormAction,
  formBody,
  formFieldNames,
  withNativeServer,
} = await import(pathToFileURL(path.join(projectRoot, "benchmarks/native-http-test.mjs")).href);

function decodePage(responseText) {
  return JSON.parse(responseText);
}

await withNativeServer(binaryPath, async ({ port }) => {
  const landing = await request(port, "/");
  const landingPage = decodePage(await landing.text());
  assert.equal(landing.status, 200);
  assert.equal(landingPage.kind, "page");
  assert.equal(landingPage.title, "Lead inbox");
  assert.equal(firstFormAction(landingPage.body), "/leads");
  assert.deepEqual(formFieldNames(landingPage.body), ["company", "contact", "budget"]);

  const created = await request(port, "/leads", {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
    },
    body: formBody({
      company: "SynthSpeak",
      contact: "Ava",
      budget: "75000",
      segment: "enterprise",
    }),
  });
  const createdPage = decodePage(await created.text());
  assert.equal(created.status, 200);
  assert.ok(collectTexts(createdPage.body).includes("Priority: high"));
  assert.ok(collectTexts(createdPage.body).includes("Segment: enterprise"));

  const inbox = await request(port, "/inbox");
  const inboxPage = decodePage(await inbox.text());
  assert.equal(inbox.status, 200);
  assert.ok(collectTexts(inboxPage.body).includes("SynthSpeak (high, enterprise)"));

  const primaryLead = await request(port, "/lead/primary");
  const primaryLeadPage = decodePage(await primaryLead.text());
  assert.equal(primaryLead.status, 200);
  assert.ok(collectTexts(primaryLeadPage.body).includes("Segment: enterprise"));

  const reviewed = await request(port, "/review", {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
    },
    body: formBody({
      leadId: "lead-3",
      note: "Ready for product demo next week.",
    }),
  });
  const reviewedPage = decodePage(await reviewed.text());
  assert.equal(reviewed.status, 200);
  assert.ok(collectTexts(reviewedPage.body).includes("Review status: reviewed"));
  assert.ok(collectTexts(reviewedPage.body).includes("Ready for product demo next week."));
});

await withNativeServer(binaryPath, async ({ port }) => {
  const response = await request(port, "/leads", {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
    },
    body: formBody({
      company: "SynthSpeak",
      contact: "Ava",
      budget: "not-a-number",
      segment: "startup",
    }),
  });

  assert.equal(response.status, 400);
  assert.equal(await response.text(), "budget must be an integer");
});

await withNativeServer(binaryPath, async ({ port }) => {
  const response = await request(port, "/leads", {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
    },
    body: formBody({
      company: "SynthSpeak",
      contact: "Ava",
      budget: "75000",
    }),
  });

  assert.equal(response.status, 400);
  assert.equal(await response.text(), "segment must be one of: startup, growth, enterprise");
});

await withNativeServer(binaryPath, async ({ port }) => {
  const response = await request(port, "/leads", {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
    },
    body: formBody({
      company: "SynthSpeak",
      contact: "Ava",
      budget: "75000",
      segment: "global-5000",
    }),
  });

  assert.equal(response.status, 400);
  assert.equal(await response.text(), "segment must be one of: startup, growth, enterprise");
});

await withNativeServer(binaryPath, async ({ port }) => {
  const response = await request(port, "/leads", {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
    },
    body: formBody({
      company: "SynthSpeak",
      contact: "Ava",
      budget: "75000",
      segment: "enterprise",
    }),
  });

  assert.equal(response.status, 502);
  assert.equal(await response.text(), "priority must be one of: low, medium, high");
}, {
  env: {
    CLASP_MOCK_LEAD_SUMMARY_PRIORITY: "Urgent",
  },
});

await withNativeServer(binaryPath, async ({ port }) => {
  const response = await request(port, "/leads", {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
    },
    body: formBody({
      company: "SynthSpeak",
      contact: "Ava",
      budget: "75000",
      segment: "enterprise",
    }),
  });

  assert.equal(response.status, 502);
  assert.equal(await response.text(), "segment must be one of: startup, growth, enterprise");
}, {
  env: {
    CLASP_MOCK_LEAD_SUMMARY_SEGMENT: "Global5000",
  },
});
