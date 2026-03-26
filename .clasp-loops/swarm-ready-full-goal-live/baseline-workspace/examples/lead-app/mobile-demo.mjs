import { pathToFileURL } from "node:url";

import { compileNativeBinary, withNativeServer, fetchText } from "../native-demo.mjs";

function decodePageResponse(response) {
  return JSON.parse(response.text);
}

function collectTexts(view) {
  const texts = [];

  function walk(node) {
    if (!node || typeof node !== "object") {
      return;
    }
    if (node.kind === "text") {
      texts.push(node.text ?? "");
    }
    if (Array.isArray(node.children)) {
      for (const child of node.children) {
        walk(child);
      }
    }
    if (node.child) {
      walk(node.child);
    }
  }

  walk(view);
  return texts;
}

function firstFormAction(view) {
  let found = null;

  function walk(node) {
    if (!node || typeof node !== "object" || found !== null) {
      return;
    }
    if (node.kind === "form") {
      found = node.action ?? null;
      return;
    }
    if (Array.isArray(node.children)) {
      for (const child of node.children) {
        walk(child);
      }
    }
    if (node.child) {
      walk(node.child);
    }
  }

  walk(view);
  return found;
}

function formFieldNames(view) {
  const fields = [];

  function walk(node) {
    if (!node || typeof node !== "object") {
      return;
    }
    if (node.kind === "input" && node.inputKind !== "hidden") {
      fields.push(node.fieldName ?? "");
    }
    if (Array.isArray(node.children)) {
      for (const child of node.children) {
        walk(child);
      }
    }
    if (node.child) {
      walk(node.child);
    }
  }

  walk(view);
  return fields;
}

export async function renderLeadMobileDemo(binaryPath = null) {
  const compiled = compileNativeBinary(
    "examples/lead-app/Main.clasp",
    binaryPath,
    "lead-app-mobile-demo"
  );

  try {
    return await withNativeServer(compiled.binaryPath, "/", async ({ baseUrl }) => {
      const landing = decodePageResponse(await fetchText(baseUrl, "/"));
      const created = decodePageResponse(
        await fetchText(baseUrl, "/leads", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({
            company: "SynthSpeak Mobile",
            contact: "Taylor Rivera",
            budget: 42000,
            segment: "Growth",
          }),
        })
      );
      const reviewed = decodePageResponse(
        await fetchText(baseUrl, "/review", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({
            leadId: "lead-3",
            note: "Ready for field pilot",
          }),
        })
      );

      return {
        platform: "native-page-json",
        landingTitle: landing.title,
        landingFormAction: firstFormAction(landing.body),
        landingFieldNames: formFieldNames(landing.body),
        createdTexts: collectTexts(created.body),
        reviewedTexts: collectTexts(reviewed.body),
      };
    });
  } finally {
    compiled.cleanup();
  }
}

async function runCli() {
  const summary = await renderLeadMobileDemo(process.argv[2] ?? null);
  console.log(JSON.stringify(summary, null, 2));
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  await runCli();
}
