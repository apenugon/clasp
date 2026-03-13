import { pathToFileURL } from "node:url";
import { createRouteClientRuntime } from "../../runtime/bun/client.mjs";
import {
  bindingContractFor,
  installCompiledModule,
  requestPayloadJson,
  responseForRouteResult
} from "../../runtime/bun/server.mjs";
import { createLeadDemoBindings } from "./bindings.mjs";

export async function runLeadClientDemo(compiledModule, options = {}) {
  installCompiledModule(compiledModule, createLeadDemoBindings(options.seedLeads));

  const contract = bindingContractFor(compiledModule);
  const runtime = createRouteClientRuntime({
    baseUrl: "https://app.example.test",
    fetch: async (url, init = {}) => handleFetch(contract, url, init)
  });
  const routeClient = (name) => {
    const found = contract.routeClients.find((candidate) => candidate.name === name);

    if (!found) {
      throw new Error(`Missing route client ${name}`);
    }

    return found;
  };

  const inboxClient = routeClient("inboxSnapshotRoute");
  const primaryClient = routeClient("primaryLeadRecordRoute");
  const createClient = routeClient("createLeadRecordRoute");
  const reviewClient = routeClient("reviewLeadRecordRoute");

  const inbox = await runtime.call(inboxClient, {});
  const created = await runtime.call(createClient, {
    company: "SynthSpeak API",
    contact: "Dana Scott",
    budget: 36000,
    segment: compiledModule.Growth
  });
  const primary = await runtime.call(primaryClient, {});
  const reviewed = await runtime.call(reviewClient, {
    leadId: created.leadId,
    note: "Schedule technical discovery"
  });

  let invalid = null;

  try {
    await runtime.call(createClient, {
      company: "Broken Co",
      contact: "Dana Scott",
      budget: 1000,
      segment: "invalid"
    });
  } catch (error) {
    invalid = error instanceof Error ? error.message : String(error);
  }

  return {
    routeClientCount: contract.routeClients.length,
    routeClientNames: contract.routeClients.map((candidate) => candidate.name),
    inboxHeadline: inbox.headline,
    createdLeadId: created.leadId,
    createdPriority: normalizeTag(created.priority),
    createdSegment: normalizeTag(created.segment),
    primaryCompany: primary.company,
    reviewedStatus: normalizeTag(reviewed.reviewStatus),
    reviewedNote: reviewed.reviewNote,
    invalid
  };
}

function normalizeTag(value) {
  return value?.$tag ?? value;
}

async function handleFetch(contract, url, init = {}) {
  const request = new Request(url, init);
  const pathname = new URL(url).pathname;
  const route = contract.routes.find(
    (candidate) =>
      candidate.method === request.method && candidate.path === pathname
  );

  if (!route) {
    return new Response(JSON.stringify({ error: "not_found", path: pathname }), {
      status: 404,
      headers: { "content-type": "application/json" }
    });
  }

  try {
    const payload = route.decodeRequest(await requestPayloadJson(route, request));
    const result = await route.handler(payload);
    return responseForRouteResult(route, result);
  } catch (error) {
    return new Response(
      JSON.stringify({
        error: error instanceof Error ? error.message : String(error)
      }),
      {
        status: 400,
        headers: { "content-type": "application/json" }
      }
    );
  }
}

async function runCli() {
  const compiledPath = process.argv[2] ?? "./Main.js";
  const compiledUrl = new URL(compiledPath, pathToFileURL(`${process.cwd()}/`));
  const compiledModule = await import(compiledUrl.href);
  const summary = await runLeadClientDemo(compiledModule);
  console.log(JSON.stringify(summary));
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  await runCli();
}
