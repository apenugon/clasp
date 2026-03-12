import assert from "node:assert/strict";
import { createServer } from "../dist/server/main.js";

function formBody(fields) {
  return new URLSearchParams(fields).toString();
}

async function request(port, path, init = {}) {
  return fetch(`http://127.0.0.1:${port}${path}`, init);
}

async function withServer(binding, callback) {
  const port = 4300 + Math.floor(Math.random() * 300);
  const server = createServer(
    {
      mockLeadSummaryModel: binding
    },
    { port }
  );

  try {
    await callback(port);
  } finally {
    server.stop(true);
  }
}

await withServer((lead) => {
  const priority =
    lead.budget >= 50000 ? "high" : lead.budget >= 20000 ? "medium" : "low";

  return JSON.stringify({
    summary: `${lead.company} led by ${lead.contact} fits the ${priority} priority pipeline.`,
    priority,
    followUpRequired: lead.budget >= 20000
  });
}, async (port) => {
  const landing = await request(port, "/");
  const landingHtml = await landing.text();
  assert.equal(landing.status, 200);
  assert.match(landingHtml, /<form method="POST" action="\/leads">/);
  assert.match(landingHtml, /Open the inbox page/);

  const created = await request(port, "/leads", {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded"
    },
    body: formBody({
      company: "SynthSpeak",
      contact: "Ava",
      budget: "75000"
    })
  });
  const createdHtml = await created.text();
  assert.equal(created.status, 200);
  assert.match(createdHtml, /SynthSpeak/);
  assert.match(createdHtml, /Priority: high/);

  const inbox = await request(port, "/inbox");
  const inboxHtml = await inbox.text();
  assert.equal(inbox.status, 200);
  assert.match(inboxHtml, /href="\/lead\/primary"/);
  assert.match(inboxHtml, /SynthSpeak \(high\)/);

  const primaryLead = await request(port, "/lead/primary");
  const primaryLeadHtml = await primaryLead.text();
  assert.equal(primaryLead.status, 200);
  assert.match(primaryLeadHtml, /SynthSpeak/);

  const reviewed = await request(port, "/review", {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded"
    },
    body: formBody({
      leadId: "lead-3",
      note: "Ready for product demo next week."
    })
  });
  const reviewedHtml = await reviewed.text();
  assert.equal(reviewed.status, 200);
  assert.match(reviewedHtml, /Review status: reviewed/);
  assert.match(reviewedHtml, /Ready for product demo next week\./);
});

await withServer((lead) =>
  JSON.stringify({
    summary: `${lead.company} led by ${lead.contact}`,
    priority: "medium",
    followUpRequired: lead.budget >= 20000
  }),
async (port) => {
  const response = await request(port, "/leads", {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded"
    },
    body: formBody({
      company: "SynthSpeak",
      contact: "Ava",
      budget: "not-a-number"
    })
  });

  assert.equal(response.status, 400);
  assert.equal(await response.text(), "budget must be an integer");
});

await withServer(() =>
  JSON.stringify({
    summary: "SynthSpeak led by Ava",
    priority: "urgent",
    followUpRequired: true
  }),
async (port) => {
  const response = await request(port, "/leads", {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded"
    },
    body: formBody({
      company: "SynthSpeak",
      contact: "Ava",
      budget: "75000"
    })
  });

  assert.equal(response.status, 502);
  assert.equal(await response.text(), "priority must be one of: low, medium, high");
});
