import assert from "node:assert/strict";
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

function toWireSegment(value) {
  if (typeof value === "string") {
    return value;
  }

  if (typeof value === "object" && value !== null && typeof value.$tag === "string") {
    return value.$tag.toLowerCase();
  }

  return undefined;
}

function formBody(fields) {
  return new URLSearchParams(fields).toString();
}

async function request(port, path, init = {}) {
  return fetch(`http://127.0.0.1:${port}${path}`, init);
}

async function withServer(binding, callback) {
  const leads = [
    {
      leadId: "lead-2",
      company: "Northwind Studio",
      contact: "Morgan Lee",
      summary: "Northwind Studio is ready for a design-system migration this quarter.",
      priority: "medium",
      followUpRequired: true,
      reviewStatus: "reviewed",
      reviewNote: "Confirmed budget window and asked for a migration timeline."
    },
    {
      leadId: "lead-1",
      company: "Acme Labs",
      contact: "Jordan Kim",
      summary: "Acme Labs is exploring an internal AI pilot for support operations.",
      priority: "high",
      followUpRequired: true,
      reviewStatus: "new",
      reviewNote: ""
    }
  ];

  installRuntime({
    mockLeadSummaryModel: binding,
    storeLead(intake, summary) {
      const lead = {
        leadId: `lead-${leads.length + 1}`,
        company: intake.company,
        contact: intake.contact,
        summary: summary.summary,
        priority: toWirePriority(summary.priority) ?? "low",
        followUpRequired: summary.followUpRequired,
        reviewStatus: "new",
        reviewNote: ""
      };

      leads.unshift(lead);
      return JSON.stringify(lead);
    },
    loadInbox() {
      return JSON.stringify({
        headline: "Priority inbox",
        primaryLeadLabel: leadLabel(leads[0]),
        secondaryLeadLabel: leadLabel(leads[1] ?? leads[0])
      });
    },
    loadPrimaryLead() {
      return JSON.stringify(leads[0]);
    },
    loadSecondaryLead() {
      return JSON.stringify(leads[1] ?? leads[0]);
    },
    reviewLead(review) {
      const lead = leads.find((candidate) => candidate.leadId === review.leadId);

      if (!lead) {
        throw new Error(`Unknown lead: ${review.leadId}`);
      }

      lead.reviewStatus = "reviewed";
      lead.reviewNote = review.note;
      return JSON.stringify(lead);
    }
  });

  const port = 4100 + Math.floor(Math.random() * 300);
  const server = serveCompiledModule(compiled, { port });

  try {
    await callback(port);
  } finally {
    server.stop(true);
  }
}

function leadLabel(lead) {
  return `${lead.company} (${lead.priority})`;
}

await withServer((lead) => {
  const priority =
    toWirePriority(lead.priority) ??
    (lead.budget >= 50000 ? "high" : lead.budget >= 20000 ? "medium" : "low");

  return JSON.stringify({
    summary: `${lead.company} led by ${lead.contact} fits the ${priority} priority pipeline.`,
    priority,
    segment: toWireSegment(lead.segment),
    followUpRequired: lead.budget >= 20000
  });
}, async (port) => {
  const landing = await request(port, "/");
  const landingHtml = await landing.text();
  assert.equal(landing.status, 200);
  assert.match(landingHtml, /<form method="POST" action="\/leads">/);
  assert.match(landingHtml, /name="segment"/);

  const created = await request(port, "/leads", {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded"
    },
    body: formBody({
      company: "SynthSpeak",
      contact: "Ava",
      budget: "75000",
      segment: "enterprise"
    })
  });
  const createdHtml = await created.text();
  assert.equal(created.status, 200);
  assert.match(createdHtml, /Priority: high/);
  assert.match(createdHtml, /Segment: enterprise/);

  const inbox = await request(port, "/inbox");
  const inboxHtml = await inbox.text();
  assert.equal(inbox.status, 200);
  assert.match(inboxHtml, /SynthSpeak \(high, enterprise\)/);

  const primaryLead = await request(port, "/lead/primary");
  const primaryLeadHtml = await primaryLead.text();
  assert.equal(primaryLead.status, 200);
  assert.match(primaryLeadHtml, /Segment: enterprise/);

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
    segment: toWireSegment(lead.segment),
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
      budget: "not-a-number",
      segment: "startup"
    })
  });

  assert.equal(response.status, 400);
  assert.equal(await response.text(), "budget must be an integer");
});

await withServer((lead) =>
  JSON.stringify({
    summary: `${lead.company} led by ${lead.contact}`,
    priority: "medium",
    segment: toWireSegment(lead.segment),
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
      budget: "75000"
    })
  });

  assert.equal(response.status, 400);
  assert.equal(await response.text(), "segment must be one of: startup, growth, enterprise");
});

await withServer((lead) =>
  JSON.stringify({
    summary: `${lead.company} led by ${lead.contact}`,
    priority: "medium",
    segment: toWireSegment(lead.segment),
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
      budget: "75000",
      segment: "global-5000"
    })
  });

  assert.equal(response.status, 400);
  assert.equal(await response.text(), "segment must be one of: startup, growth, enterprise");
});

await withServer(() =>
  JSON.stringify({
    summary: "SynthSpeak led by Ava",
    priority: "urgent",
    segment: "enterprise",
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
      budget: "75000",
      segment: "enterprise"
    })
  });

  assert.equal(response.status, 502);
  assert.equal(await response.text(), "priority must be one of: low, medium, high");
});

await withServer(() =>
  JSON.stringify({
    summary: "SynthSpeak led by Ava",
    priority: "high",
    segment: "global-5000",
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
      budget: "75000",
      segment: "enterprise"
    })
  });

  assert.equal(response.status, 502);
  assert.equal(await response.text(), "segment must be one of: startup, growth, enterprise");
});
