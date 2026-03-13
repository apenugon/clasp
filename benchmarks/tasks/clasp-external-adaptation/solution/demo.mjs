import {
  bindingContractFor,
  createBamlShim,
  installCompiledModule
} from "../../../../runtime/bun/server.mjs";
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

export async function runLeadObjectiveDemo(compiledModule, options = {}) {
  installCompiledModule(compiledModule, createLeadDemoBindings(options.seedLeads));

  const contract = bindingContractFor(compiledModule);
  const primaryLeadRoute = contract.routes.find(
    (candidate) => candidate.name === "primaryLeadRecordRoute"
  );

  if (!primaryLeadRoute) {
    throw new Error("Missing primaryLeadRecordRoute");
  }

  const lead = await primaryLeadRoute.handler({});
  const lookupLeadPlaybook = createBamlShim(compiledModule).tool("lookupLeadPlaybook");
  const lookupRequest = compiledModule.leadPlaybookRequest(lead);
  const preparedCall = lookupLeadPlaybook.prepare(lookupRequest, `${lead.leadId}:playbook`);
  const playbook = lookupLeadPlaybook.parse(runTool(preparedCall).result);
  const signalCollector = contract.traces?.create?.() ?? null;
  const feedbackSignal = contract.traceability?.recordSignal(
    {
      name: "growth_reply_rate_below_goal",
      summary: "Growth leads are not replying to the default email call to action.",
      value: {
        segment: normalizeTag(lead.segment),
        channel: playbook.channel,
        objective: "reply-rate"
      },
      severity: "warn",
      source: "benchmarks/tasks/clasp-external-adaptation/repo/demo"
    },
    {
      routes: [primaryLeadRoute.name],
      prompts: ["outreachPrompt"],
      workflows: ["LeadFollowUpFlow"],
      policies: ["LeadAssistOps"],
      tests: [{ name: "lead-benchmark.objective", file: "test/objective.test.mjs" }]
    },
    {
      collector: signalCollector,
      traceId: `${lead.leadId}:growth-reply-rate-below-goal`,
      context: { actor: { id: "lead-benchmark" }, objective: "reply-rate" }
    }
  );

  let invalidChange = null;
  try {
    contract.traceability?.proposeChange(
      feedbackSignal,
      {
        name: "growth-outreach-too-broad",
        summary: "Touch an unrelated route outside the observed signal.",
        targets: {
          routes: ["secondaryLeadRecordRoute"]
        },
        steps: ["Expand the remediation beyond the observed lead path."]
      },
      {
        collector: signalCollector,
        traceId: `${lead.leadId}:growth-outreach-too-broad`,
        context: { actor: { id: "lead-benchmark" }, objective: "reply-rate" }
      }
    );
  } catch (error) {
    invalidChange = error instanceof Error ? error.message : String(error);
  }

  const changePlan = contract.traceability?.proposeChange(
    feedbackSignal,
    {
      name: "growth-outreach-tune",
      summary: "Tighten the growth outreach CTA and keep verification local.",
      rationale:
        "The reply-rate signal is already linked to the current prompt, workflow, policy, and benchmark test.",
      targets: {
        prompts: ["outreachPrompt"],
        tests: [{ name: "lead-benchmark.objective", file: "test/objective.test.mjs" }]
      },
      steps: [
        {
          title: "Update growth outreach guidance.",
          detail:
            "Revise the outreach prompt guidance and CTA for the Growth segment without changing route or policy scope."
        },
        {
          title: "Re-run the benchmark demo.",
          detail:
            "Run the benchmark objective demo again to confirm the prompt and draft remain schema-valid."
        }
      ],
      bounds: {
        maxSteps: 2,
        requireTests: true,
        requireReview: true
      }
    },
    {
      collector: signalCollector,
      traceId: `${lead.leadId}:growth-outreach-tune`,
      context: { actor: { id: "lead-benchmark" }, objective: "reply-rate" }
    }
  );

  return {
    feedbackSignalName: feedbackSignal?.signal?.name ?? null,
    signalObjective: feedbackSignal?.context?.objective ?? null,
    changePlanName: changePlan?.change?.name ?? null,
    changePlanTargetIds: changePlan?.change?.targets?.ids ?? [],
    changePlanStepCount: changePlan?.change?.steps?.length ?? 0,
    invalidChange
  };
}
