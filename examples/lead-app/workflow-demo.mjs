import { pathToFileURL } from "node:url";

import {
  compileNativeBinary,
  compileNativeImage,
  withNativeServer,
  fetchText,
} from "../native-demo.mjs";

function decodeJsonResponse(response) {
  return JSON.parse(response.text);
}

function normalizeTag(value) {
  return value?.$tag ?? value;
}

export async function runLeadWorkflowDemo(binaryPath = null, imagePath = null) {
  const compiledBinary = compileNativeBinary(
    "examples/lead-app/Main.clasp",
    binaryPath,
    "lead-app-workflow-demo"
  );
  const compiledImage = compileNativeImage(
    "examples/lead-app/Main.clasp",
    imagePath,
    "lead-app-workflow-demo.native.image.json"
  );

  try {
    const image = JSON.parse(await import("node:fs/promises").then((fs) => fs.readFile(compiledImage.imagePath, "utf8")));
    const workflow = (image?.runtime?.boundaries ?? []).find(
      (boundary) => boundary?.kind === "workflow" && boundary.name === "LeadFollowUpFlow"
    );

    return await withNativeServer(compiledBinary.binaryPath, "/api/inbox", async ({ baseUrl }) => {
      const created = decodeJsonResponse(
        await fetchText(baseUrl, "/api/leads", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({
            company: "SynthSpeak Workflow",
            contact: "Riley Chen",
            budget: 90000,
            segment: "Enterprise",
          }),
        })
      );
      const reviewed = decodeJsonResponse(
        await fetchText(baseUrl, "/api/review", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({
            leadId: created.leadId,
            note: "Schedule executive discovery",
          }),
        })
      );

      return {
        workflowCount: (image?.runtime?.boundaries ?? []).filter(
          (boundary) => boundary?.kind === "workflow"
        ).length,
        workflowName: workflow?.name ?? null,
        checkpointCodec: workflow?.checkpoint ?? null,
        restoreCodec: workflow?.restore ?? null,
        handoffSymbol: workflow?.handoff ?? null,
        createdLeadId: created.leadId,
        createdPriority: normalizeTag(created.priority),
        reviewedStatus: normalizeTag(reviewed.reviewStatus),
        reviewedNote: reviewed.reviewNote,
      };
    });
  } finally {
    compiledImage.cleanup();
    compiledBinary.cleanup();
  }
}

async function runCli() {
  const summary = await runLeadWorkflowDemo(process.argv[2] ?? null, process.argv[3] ?? null);
  console.log(JSON.stringify(summary));
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  await runCli();
}
