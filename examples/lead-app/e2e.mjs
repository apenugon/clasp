import assert from "node:assert/strict";
import { pathToFileURL } from "node:url";

import { createLeadDemoBindings } from "./bindings.mjs";
import { installCompiledModule, serveCompiledModule } from "../../runtime/bun/server.mjs";

function formBody(fields) {
  return new URLSearchParams(fields).toString();
}

async function request(port, path, init = {}) {
  return fetch(`http://127.0.0.1:${port}${path}`, init);
}

async function responseBody(response) {
  const contentType = response.headers.get("content-type") ?? "";
  return contentType.includes("application/json")
    ? await response.json()
    : await response.text();
}

async function runLeadHttpE2e(compiledModule) {
  installCompiledModule(compiledModule, createLeadDemoBindings());

  const server = serveCompiledModule(compiledModule, {
    port: 4600 + Math.floor(Math.random() * 200)
  });

  try {
    const landing = await request(server.port, "/");
    const landingHtml = await landing.text();
    assert.equal(landing.status, 200);
    assert.match(landingHtml, /<form method="POST" action="\/leads">/);
    assert.match(landingHtml, /Open the inbox page/);

    const inbox = await request(server.port, "/inbox");
    const inboxHtml = await inbox.text();
    assert.equal(inbox.status, 200);
    assert.match(inboxHtml, /Priority inbox/);
    assert.match(inboxHtml, /Northwind Studio \(medium, growth\)/);

    const secondaryLead = await request(server.port, "/lead/secondary");
    const secondaryLeadHtml = await secondaryLead.text();
    assert.equal(secondaryLead.status, 200);
    assert.match(secondaryLeadHtml, /Acme Labs/);
    assert.match(secondaryLeadHtml, /Priority: high/);

    const created = await request(server.port, "/leads", {
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
    assert.match(createdHtml, /SynthSpeak/);
    assert.match(createdHtml, /Priority: high/);

    const primaryLead = await request(server.port, "/lead/primary");
    const primaryLeadHtml = await primaryLead.text();
    assert.equal(primaryLead.status, 200);
    assert.match(primaryLeadHtml, /SynthSpeak/);
    assert.match(primaryLeadHtml, /Review status: new/);

    const reviewed = await request(server.port, "/review", {
      method: "POST",
      headers: {
        "content-type": "application/x-www-form-urlencoded"
      },
      body: formBody({
        leadId: "lead-3",
        note: "Schedule executive discovery"
      })
    });
    const reviewedHtml = await reviewed.text();
    assert.equal(reviewed.status, 200);
    assert.match(reviewedHtml, /Review status: reviewed/);
    assert.match(reviewedHtml, /Schedule executive discovery/);

    const invalidBudget = await request(server.port, "/leads", {
      method: "POST",
      headers: {
        "content-type": "application/x-www-form-urlencoded"
      },
      body: formBody({
        company: "SynthSpeak",
        contact: "Ava",
        budget: "oops",
        segment: "enterprise"
      })
    });

    const unknownLead = await request(server.port, "/review", {
      method: "POST",
      headers: {
        "content-type": "application/x-www-form-urlencoded"
      },
      body: formBody({
        leadId: "lead-404",
        note: "This should fail"
      })
    });

    const missing = await request(server.port, "/missing");

    return {
      landingStatus: landing.status,
      inboxHasSeedLead: inboxHtml.includes("Northwind Studio (medium, growth)"),
      secondaryHasSeedLead: secondaryLeadHtml.includes("Acme Labs"),
      createdStatus: created.status,
      primaryShowsCreatedLead:
        primaryLeadHtml.includes("SynthSpeak") &&
        primaryLeadHtml.includes("Priority: high"),
      reviewedStatus: reviewed.status,
      reviewedHasNote: reviewedHtml.includes("Schedule executive discovery"),
      invalidBudgetStatus: invalidBudget.status,
      invalidBudgetMessage: await responseBody(invalidBudget),
      unknownLeadStatus: unknownLead.status,
      unknownLeadMessage: await responseBody(unknownLead),
      missingStatus: missing.status,
      missingMessage: await responseBody(missing)
    };
  } finally {
    server.stop(true);
  }
}

async function runCli() {
  const compiledPath = process.argv[2] ?? "./Main.js";
  const compiledUrl = new URL(compiledPath, pathToFileURL(`${process.cwd()}/`));
  const compiledModule = await import(compiledUrl.href);
  const summary = await runLeadHttpE2e(compiledModule);
  console.log(JSON.stringify(summary));
}

if (import.meta.main) {
  await runCli();
}
