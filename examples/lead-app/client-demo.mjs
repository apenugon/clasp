import { pathToFileURL } from "node:url";

import {
  compileNativeBinary,
  compileNativeImage,
  withNativeServer,
  fetchText,
} from "../native-demo.mjs";

function decodeJsonResponse(response) {
  return {
    status: response.status,
    body: JSON.parse(response.text),
  };
}

function normalizeTag(value) {
  return value?.$tag ?? value;
}

function apiRouteNames(image) {
  return (image?.runtime?.boundaries ?? [])
    .filter((boundary) => boundary?.kind === "route" && typeof boundary.path === "string")
    .filter((boundary) => boundary.path.startsWith("/api/"))
    .map((boundary) => boundary.name)
    .sort();
}

export async function runLeadClientDemo(binaryPath = null, imagePath = null) {
  const compiledBinary = compileNativeBinary(
    "examples/lead-app/Main.clasp",
    binaryPath,
    "lead-app-client-demo"
  );
  const compiledImage = compileNativeImage(
    "examples/lead-app/Main.clasp",
    imagePath,
    "lead-app-client-demo.native.image.json"
  );

  try {
    const image = JSON.parse(await import("node:fs/promises").then((fs) => fs.readFile(compiledImage.imagePath, "utf8")));
    return await withNativeServer(compiledBinary.binaryPath, "/api/inbox", async ({ baseUrl }) => {
      const inbox = decodeJsonResponse(await fetchText(baseUrl, "/api/inbox"));
      const created = decodeJsonResponse(
        await fetchText(baseUrl, "/api/leads", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({
            company: "SynthSpeak API",
            contact: "Dana Scott",
            budget: 36000,
            segment: "Growth",
          }),
        })
      );
      const primary = decodeJsonResponse(await fetchText(baseUrl, "/api/lead/primary"));
      const reviewed = decodeJsonResponse(
        await fetchText(baseUrl, "/api/review", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({
            leadId: created.body.leadId,
            note: "Schedule technical discovery",
          }),
        })
      );
      const invalid = decodeJsonResponse(
        await fetchText(baseUrl, "/api/leads", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({
            company: "Broken Co",
            contact: "Dana Scott",
            budget: 1000,
            segment: "invalid",
          }),
        })
      );

      return {
        routeClientCount: apiRouteNames(image).length,
        routeClientNames: apiRouteNames(image),
        inboxHeadline: inbox.body.headline,
        createdLeadId: created.body.leadId,
        createdPriority: normalizeTag(created.body.priority),
        createdSegment: normalizeTag(created.body.segment),
        primaryCompany: primary.body.company,
        reviewedStatus: normalizeTag(reviewed.body.reviewStatus),
        reviewedNote: reviewed.body.reviewNote,
        invalid: invalid.body.error ?? null,
      };
    });
  } finally {
    compiledImage.cleanup();
    compiledBinary.cleanup();
  }
}

async function runCli() {
  const summary = await runLeadClientDemo(process.argv[2] ?? null, process.argv[3] ?? null);
  console.log(JSON.stringify(summary));
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  await runCli();
}
