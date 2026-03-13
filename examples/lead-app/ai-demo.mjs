import { pathToFileURL } from "node:url";

import {
  bindingContractFor,
  createBamlShim,
  installCompiledModule
} from "../../runtime/bun/server.mjs";
import { createLeadDemoBindings } from "./bindings.mjs";

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
    jsonrpc: "2.0",
    id: call.id,
    result: {
      channel,
      guidance,
      callToAction:
        channel === "phone"
          ? "Ask for a 30-minute discovery call next week."
          : "Ask for the best time to send a tailored rollout plan."
    }
  };
}

export async function runLeadAiDemo(compiledModule, options = {}) {
  installCompiledModule(compiledModule, createLeadDemoBindings(options.seedLeads));

  const contract = bindingContractFor(compiledModule);
  const primaryLeadRoute = contract.routes.find(
    (candidate) => candidate.name === "primaryLeadRecordRoute"
  );

  if (!primaryLeadRoute) {
    throw new Error("Missing primaryLeadRecordRoute");
  }

  const lead = await primaryLeadRoute.handler({});
  const baml = createBamlShim(compiledModule);
  const lookupLeadPlaybook = baml.tool("lookupLeadPlaybook");
  const lookupRequest = compiledModule.leadPlaybookRequest(lead);
  const preparedCall = lookupLeadPlaybook.prepare(lookupRequest, `${lead.leadId}:playbook`);
  const playbook = lookupLeadPlaybook.parse(runTool(preparedCall).result);
  const prompt = compiledModule.outreachPrompt(lead, playbook);
  const promptText = compiledModule.outreachPromptText(lead, playbook);
  const draft = compiledModule.draftLeadOutreach(lead, playbook);
  const signalCollector = contract.traces?.create?.() ?? null;
  const signalTrace = contract.traceability?.recordSignal(
    {
      name: "lead_outreach_draft_ready",
      summary: "A typed outreach draft is ready for delivery.",
      value: {
        leadId: lead.leadId,
        channel: draft.channel
      },
      severity: "info",
      source: "examples/lead-app/ai-demo"
    },
    {
      routes: [primaryLeadRoute.name],
      prompts: ["outreachPrompt"],
      workflows: ["LeadFollowUpFlow"],
      policies: ["LeadAssistOps"],
      tests: [{ name: "lead-app.ai-demo", file: "examples/lead-app/ai-demo.mjs" }]
    },
    {
      collector: signalCollector,
      traceId: `${lead.leadId}:lead-outreach-draft-ready`,
      context: { actor: { id: "lead-ai-demo" } }
    }
  );

  let invalidTool = null;
  try {
    lookupLeadPlaybook.parse({
      channel: "phone",
      guidance: true,
      callToAction: "Ask for a call."
    });
  } catch (error) {
    invalidTool = error instanceof Error ? error.message : String(error);
  }

  installCompiledModule(compiledModule, {
    mockLeadOutreachModel(request) {
      return JSON.stringify({
        leadId: request.leadId,
        channel: request.channel,
        subject: 42,
        message: request.promptText,
        callToAction: request.callToAction
      });
    }
  });

  let invalidModel = null;
  try {
    compiledModule.draftLeadOutreach(lead, playbook);
  } catch (error) {
    invalidModel = error instanceof Error ? error.message : String(error);
  }

  return {
    routeName: primaryLeadRoute.name,
    toolName: lookupLeadPlaybook.name,
    toolMethod: preparedCall.method,
    leadId: lead.leadId,
    leadPriority: normalizeTag(lead.priority),
    leadSegment: normalizeTag(lead.segment),
    playbookChannel: playbook.channel,
    promptRoles: prompt.messages.map((message) => message.role),
    promptText,
    draftChannel: draft.channel,
    draftSubject: draft.subject,
    draftCallToAction: draft.callToAction,
    signalKind: signalTrace?.kind ?? null,
    signalName: signalTrace?.signal?.name ?? null,
    signalRefKinds: [
      ...signalTrace.refs.routes.map((entry) => entry.kind),
      ...signalTrace.refs.prompts.map((entry) => entry.kind),
      ...signalTrace.refs.workflows.map((entry) => entry.kind),
      ...signalTrace.refs.policies.map((entry) => entry.kind),
      ...signalTrace.refs.tests.map((entry) => entry.kind)
    ],
    signalRefIds: signalTrace?.refs?.ids ?? [],
    signalPromptId: signalTrace?.refs?.prompts?.[0]?.id ?? null,
    signalTestFile: signalTrace?.refs?.tests?.[0]?.file ?? null,
    collectedSignalCount: signalCollector?.entries?.().length ?? 0,
    invalidTool,
    invalidModel
  };
}

async function runCli() {
  const compiledPath = process.argv[2] ?? "./Main.js";
  const compiledUrl = new URL(compiledPath, pathToFileURL(`${process.cwd()}/`));
  const compiledModule = await import(compiledUrl.href);
  const summary = await runLeadAiDemo(compiledModule);
  console.log(JSON.stringify(summary));
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  await runCli();
}
