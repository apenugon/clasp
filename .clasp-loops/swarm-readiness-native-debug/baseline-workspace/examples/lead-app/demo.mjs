import { compileNativeBinary, runRoute, withNativeServer, fetchText } from "../native-demo.mjs";

export async function runLeadDemo(binaryPath) {
  const compiled = compileNativeBinary("examples/lead-app/Main.clasp", binaryPath, "lead-app-demo");

  try {
    const routeLead = JSON.parse(
      runRoute(
        compiled.binaryPath,
        "POST",
        "/api/leads",
        '{"company":"SynthSpeak API","contact":"Ava Stone","budget":25000,"segment":"Growth"}'
      )
    );

    return await withNativeServer(compiled.binaryPath, "/api/inbox", async ({ baseUrl }) => {
      const inbox = await fetchText(baseUrl, "/api/inbox");
      const created = await fetchText(baseUrl, "/api/leads", {
        method: "POST",
        headers: {
          "content-type": "application/json",
        },
        body: '{"company":"SynthSpeak API","contact":"Ava Stone","budget":25000,"segment":"Growth"}',
      });
      const createdLead = JSON.parse(created.text);
      const primary = await fetchText(baseUrl, "/api/lead/primary");
      const reviewed = await fetchText(baseUrl, "/api/review", {
        method: "POST",
        headers: {
          "content-type": "application/json",
        },
        body: `{"leadId":"${createdLead.leadId}","note":"Schedule technical discovery"}`,
      });
      const invalidBudget = await fetchText(baseUrl, "/api/leads", {
        method: "POST",
        headers: {
          "content-type": "application/json",
        },
        body: '{"company":"Bad Budget Co","contact":"Casey","budget":"oops","segment":"Growth"}',
      });
      const unknownLead = await fetchText(baseUrl, "/api/review", {
        method: "POST",
        headers: {
          "content-type": "application/json",
        },
        body: '{"leadId":"lead-404","note":"Missing"}',
      });

      const reviewedLead = JSON.parse(reviewed.text);

      return {
        status: "ok",
        implementation: "clasp-native",
        example: "lead-app",
        routeLeadId: routeLead.leadId,
        createdLeadId: createdLead.leadId,
        createdPriority: createdLead.priority?.$tag ?? createdLead.priority,
        createdSegment: createdLead.segment?.$tag ?? createdLead.segment,
        inboxHeadline: JSON.parse(inbox.text).headline,
        primaryCompany: JSON.parse(primary.text).company,
        reviewedStatus: reviewedLead.reviewStatus?.$tag ?? reviewedLead.reviewStatus,
        reviewedNote: reviewedLead.reviewNote,
        invalidBudgetStatus: invalidBudget.status,
        invalidBudgetMessage: invalidBudget.text,
        unknownLeadStatus: unknownLead.status,
        unknownLeadMessage: unknownLead.text,
      };
    });
  } finally {
    compiled.cleanup();
  }
}

async function runCli() {
  const summary = await runLeadDemo(process.argv[2]);
  console.log(JSON.stringify(summary));
}

if (import.meta.url === new URL(process.argv[1], "file:").href) {
  await runCli();
}
