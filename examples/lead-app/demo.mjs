import { pathToFileURL } from "node:url";
import {
  bindingContractFor,
  installCompiledModule,
  requestPayloadJson
} from "../../runtime/bun/server.mjs";
import { createLeadDemoBindings } from "./bindings.mjs";

export async function runLeadDemo(compiledModule, options = {}) {
  installCompiledModule(compiledModule, createLeadDemoBindings(options.seedLeads));

  const contract = bindingContractFor(compiledModule);
  const route = (name) => {
    const found = contract.routes.find((candidate) => candidate.name === name);

    if (!found) {
      throw new Error(`Missing route ${name}`);
    }

    return found;
  };

  const landingRoute = route("landingRoute");
  const inboxRoute = route("inboxRoute");
  const primaryLeadRoute = route("primaryLeadRoute");
  const secondaryLeadRoute = route("secondaryLeadRoute");
  const createLeadRoute = route("createLeadRoute");
  const reviewLeadRoute = route("reviewLeadRoute");

  const landingHtml = landingRoute.encodeResponse(await landingRoute.handler({}));
  const createPayload = createLeadRoute.decodeRequest(
    await requestPayloadJson(
      createLeadRoute,
      new Request("http://example.test/leads", {
        method: "POST",
        headers: {
          "content-type": "application/x-www-form-urlencoded"
        },
        body: "company=SynthSpeak&contact=Ada+Lovelace&budget=65000&segment=enterprise"
      })
    )
  );
  const createdHtml = createLeadRoute.encodeResponse(
    await createLeadRoute.handler(createPayload)
  );
  const inboxHtml = inboxRoute.encodeResponse(await inboxRoute.handler({}));
  const primaryHtml = primaryLeadRoute.encodeResponse(await primaryLeadRoute.handler({}));
  const secondaryHtml = secondaryLeadRoute.encodeResponse(
    await secondaryLeadRoute.handler({})
  );
  const reviewPayload = reviewLeadRoute.decodeRequest(
    await requestPayloadJson(
      reviewLeadRoute,
      new Request("http://example.test/review", {
        method: "POST",
        headers: {
          "content-type": "application/x-www-form-urlencoded"
        },
        body: "leadId=lead-3&note=Call+tomorrow"
      })
    )
  );
  const reviewHtml = reviewLeadRoute.encodeResponse(
    await reviewLeadRoute.handler(reviewPayload)
  );

  let invalid = null;

  try {
    createLeadRoute.decodeRequest(
      await requestPayloadJson(
        createLeadRoute,
        new Request("http://example.test/leads", {
          method: "POST",
          headers: {
            "content-type": "application/x-www-form-urlencoded"
          },
          body: "company=SynthSpeak&contact=Ada+Lovelace&budget=oops"
        })
      )
    );
  } catch (error) {
    invalid = error instanceof Error ? error.message : String(error);
  }

  return {
    routeCount: contract.routes.length,
    routeNames: contract.routes.map((candidate) => candidate.name),
    landingHasForm:
      landingHtml.includes('action="/leads"') &&
      landingHtml.includes('name="segment"') &&
      landingHtml.includes("Open the inbox page"),
    createdHasLead:
      createdHtml.includes("SynthSpeak") &&
      createdHtml.includes("Ada Lovelace") &&
      createdHtml.includes("Priority: high"),
    inboxHasCreatedLead:
      inboxHtml.includes('href="/lead/primary"') &&
      inboxHtml.includes("SynthSpeak (high, enterprise)"),
    primaryHasCreatedLead:
      primaryHtml.includes("SynthSpeak") &&
      primaryHtml.includes("Segment: enterprise"),
    secondaryHasSeedLead:
      secondaryHtml.includes("Northwind Studio") &&
      secondaryHtml.includes("Priority: medium"),
    reviewHasNote:
      reviewHtml.includes("Call tomorrow") &&
      reviewHtml.includes("Review status: reviewed"),
    invalid
  };
}

async function runCli() {
  const compiledPath = process.argv[2] ?? "./Main.js";
  const compiledUrl = new URL(compiledPath, pathToFileURL(`${process.cwd()}/`));
  const compiledModule = await import(compiledUrl.href);
  const summary = await runLeadDemo(compiledModule);
  console.log(JSON.stringify(summary));
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  await runCli();
}
