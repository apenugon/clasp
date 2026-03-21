import { pathToFileURL } from "node:url";
import { installCompiledModule } from "../../deprecated/runtime/server.mjs";
import { createReactNativeBridge } from "../../src/runtime/react.mjs";
import { createLeadDemoBindings } from "./bindings.mjs";

export async function renderLeadMobileDemo(compiledModule, options = {}) {
  installCompiledModule(compiledModule, createLeadDemoBindings(options.seedLeads));

  const bridge = createReactNativeBridge(compiledModule, {
    platform: options.platform
  });
  const landingRoute = findRoute(compiledModule, "landingRoute");
  const createLeadRoute = findRoute(compiledModule, "createLeadRoute");
  const reviewLeadRoute = findRoute(compiledModule, "reviewLeadRoute");

  const landingPage = await landingRoute.handler({});
  const createLead = createLeadRoute.decodeRequest(
    JSON.stringify({
      company: "SynthSpeak Mobile",
      contact: "Taylor Rivera",
      budget: 42000,
      segment: "growth"
    })
  );
  const createdPage = await createLeadRoute.handler(createLead);
  const reviewLead = reviewLeadRoute.decodeRequest(
    JSON.stringify({
      leadId: "lead-3",
      note: "Ready for field pilot"
    })
  );
  const reviewedPage = await reviewLeadRoute.handler(reviewLead);
  const landingModel = bridge.renderPageModel(landingPage);
  const createdModel = bridge.renderPageModel(createdPage);
  const reviewedModel = bridge.renderPageModel(reviewedPage);

  return {
    platform: bridge.platform,
    landingTitle: landingModel.title,
    landingFormAction: firstFormAction(landingModel.body),
    landingFieldNames: formFieldNames(landingModel.body),
    createdTexts: collectTexts(createdModel.body),
    reviewedTexts: collectTexts(reviewedModel.body)
  };
}

function findRoute(compiledModule, name) {
  const route = compiledModule.__claspRoutes?.find(
    (candidate) => candidate.name === name
  );

  if (!route) {
    throw new Error(`Missing route ${name}`);
  }

  return route;
}

function firstFormAction(view) {
  for (const node of walk(view)) {
    if (node.kind === "form") {
      return node.action ?? null;
    }
  }

  return null;
}

function formFieldNames(view) {
  const fields = [];

  for (const node of walk(view)) {
    if (node.kind === "input" && node.inputKind !== "hidden") {
      fields.push(node.fieldName ?? "");
    }
  }

  return fields;
}

function collectTexts(view) {
  const texts = [];

  for (const node of walk(view)) {
    if (node.kind === "text") {
      texts.push(node.text ?? "");
    }
  }

  return texts;
}

function* walk(view) {
  if (!view || typeof view !== "object") {
    return;
  }

  yield view;

  if (Array.isArray(view.children)) {
    for (const child of view.children) {
      yield* walk(child);
    }
  }

  if (view.child) {
    yield* walk(view.child);
  }
}

async function runCli() {
  const compiledPath = process.argv[2] ?? "./Main.js";
  const compiledUrl = new URL(compiledPath, pathToFileURL(`${process.cwd()}/`));
  const compiledModule = await import(compiledUrl.href);
  const summary = await renderLeadMobileDemo(compiledModule);
  console.log(JSON.stringify(summary, null, 2));
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  await runCli();
}
