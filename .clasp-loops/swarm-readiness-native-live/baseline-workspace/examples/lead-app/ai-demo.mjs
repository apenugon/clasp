import { pathToFileURL } from "node:url";

import {
  compileNativeBinary,
  compileNativeImage,
  withNativeServer,
  fetchText,
} from "../native-demo.mjs";

function normalizeTag(value) {
  return value?.$tag ?? value;
}

function runTool(call) {
  if (call.method !== "lookup_lead_playbook") {
    throw new Error(`Unexpected tool call: ${call.method}`);
  }

  const segment = normalizeTag(call.params.segment);
  const priority = normalizeTag(call.params.priority);
  const channel = priority === "High" ? "phone" : "email";
  const guidance =
    segment === "Enterprise"
      ? "Lead with the AI pilot outcome and confirm an executive discovery window."
      : "Keep the note concise, mention the current pilot, and ask for a next step.";

  return {
    channel,
    guidance,
    callToAction:
      channel === "phone"
        ? "Ask for a 30-minute discovery call next week."
        : "Ask for the best time to send a tailored rollout plan.",
  };
}

function promptTextFor(lead, playbook) {
  return [
    "system: You are the lead outreach assistant.",
    `assistant: ${lead.company}`,
    `assistant: ${lead.summary}`,
    `assistant: ${normalizeTag(lead.priority).toLowerCase()}`,
    `assistant: ${normalizeTag(lead.segment).toLowerCase()}`,
    `assistant: ${playbook.guidance}`,
    `user: ${playbook.callToAction}`,
  ].join("\n\n");
}

export async function runLeadAiDemo(binaryPath = null, imagePath = null) {
  const compiledBinary = compileNativeBinary(
    "examples/lead-app/Main.clasp",
    binaryPath,
    "lead-app-ai-demo"
  );
  const compiledImage = compileNativeImage(
    "examples/lead-app/Main.clasp",
    imagePath,
    "lead-app-ai-demo.native.image.json"
  );

  try {
    const image = JSON.parse(await import("node:fs/promises").then((fs) => fs.readFile(compiledImage.imagePath, "utf8")));
    const tool = (image?.runtime?.boundaries ?? []).find(
      (boundary) => boundary?.kind === "tool" && boundary.name === "lookupLeadPlaybook"
    );

    return await withNativeServer(compiledBinary.binaryPath, "/api/lead/primary", async ({ baseUrl }) => {
      const lead = JSON.parse((await fetchText(baseUrl, "/api/lead/primary")).text);
      const playbook = runTool({
        method: tool?.operation ?? "lookup_lead_playbook",
        params: {
          segment: lead.segment,
          priority: lead.priority,
        },
      });
      const promptText = promptTextFor(lead, playbook);

      return {
        routeName: "primaryLeadRecordRoute",
        toolName: tool?.name ?? null,
        toolMethod: tool?.operation ?? null,
        leadId: lead.leadId,
        leadPriority: normalizeTag(lead.priority),
        leadSegment: normalizeTag(lead.segment),
        playbookChannel: playbook.channel,
        promptRoles: ["system", "assistant", "assistant", "assistant", "assistant", "assistant", "user"],
        promptText,
        draftChannel: playbook.channel,
        draftSubject: `${lead.company} outreach`,
        draftCallToAction: playbook.callToAction,
      };
    });
  } finally {
    compiledImage.cleanup();
    compiledBinary.cleanup();
  }
}

async function runCli() {
  const summary = await runLeadAiDemo(process.argv[2] ?? null, process.argv[3] ?? null);
  console.log(JSON.stringify(summary));
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  await runCli();
}
