import assert from "node:assert/strict";

import { compileNativeBinary, withNativeServer, fetchText } from "../native-demo.mjs";

export async function runLeadHttpE2e(binaryPath) {
  const compiled = compileNativeBinary("examples/lead-app/Main.clasp", binaryPath, "lead-app-e2e");

  try {
    return await withNativeServer(compiled.binaryPath, "/api/inbox", async ({ baseUrl }) => {
      const landing = await fetchText(baseUrl, "/");
      assert.equal(landing.status, 200);
      assert.match(landing.text, /"title":"Lead inbox"/);

      const inbox = await fetchText(baseUrl, "/inbox");
      assert.equal(inbox.status, 200);
      assert.match(inbox.text, /Priority inbox/);
      assert.match(inbox.text, /Northwind Studio \(medium, growth\)/);

      const secondaryLead = await fetchText(baseUrl, "/lead/secondary");
      assert.equal(secondaryLead.status, 200);
      assert.match(secondaryLead.text, /Acme Labs/);
      assert.match(secondaryLead.text, /Priority: high/);

      const created = await fetchText(baseUrl, "/leads", {
        method: "POST",
        headers: {
          "content-type": "application/x-www-form-urlencoded"
        },
        body: new URLSearchParams({
          company: "SynthSpeak",
          contact: "Ava",
          budget: "75000",
          segment: "enterprise"
        })
      });
      assert.equal(created.status, 200);
      assert.match(created.text, /SynthSpeak/);
      assert.match(created.text, /Priority: high/);

      const primaryLead = await fetchText(baseUrl, "/lead/primary");
      assert.equal(primaryLead.status, 200);
      assert.match(primaryLead.text, /SynthSpeak/);
      assert.match(primaryLead.text, /Review status: new/);

      const reviewed = await fetchText(baseUrl, "/review", {
        method: "POST",
        headers: {
          "content-type": "application/x-www-form-urlencoded"
        },
        body: new URLSearchParams({
          leadId: "lead-3",
          note: "Schedule executive discovery"
        })
      });
      assert.equal(reviewed.status, 200);
      assert.match(reviewed.text, /Review status: reviewed/);
      assert.match(reviewed.text, /Schedule executive discovery/);

      const invalidBudget = await fetchText(baseUrl, "/leads", {
        method: "POST",
        headers: {
          "content-type": "application/x-www-form-urlencoded"
        },
        body: new URLSearchParams({
          company: "SynthSpeak",
          contact: "Ava",
          budget: "oops",
          segment: "enterprise"
        })
      });

      const unknownLead = await fetchText(baseUrl, "/review", {
        method: "POST",
        headers: {
          "content-type": "application/x-www-form-urlencoded"
        },
        body: new URLSearchParams({
          leadId: "lead-404",
          note: "This should fail"
        })
      });

      const missing = await fetchText(baseUrl, "/missing");

      return {
        landingStatus: landing.status,
        inboxHasSeedLead: inbox.text.includes("Northwind Studio (medium, growth)"),
        secondaryHasSeedLead: secondaryLead.text.includes("Acme Labs"),
        createdStatus: created.status,
        primaryShowsCreatedLead:
          primaryLead.text.includes("SynthSpeak") &&
          primaryLead.text.includes("Priority: high"),
        reviewedStatus: reviewed.status,
        reviewedHasNote: reviewed.text.includes("Schedule executive discovery"),
        invalidBudgetStatus: invalidBudget.status,
        invalidBudgetMessage: invalidBudget.text,
        unknownLeadStatus: unknownLead.status,
        unknownLeadMessage: unknownLead.text,
        missingStatus: missing.status,
        missingMessage: missing.text
      };
    });
  } finally {
    compiled.cleanup();
  }
}

async function runCli() {
  const summary = await runLeadHttpE2e(process.argv[2]);
  console.log(JSON.stringify(summary));
}

if (import.meta.url === new URL(process.argv[1], "file:").href) {
  await runCli();
}
