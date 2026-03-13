import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import { createDynamicSchema } from "../../runtime/bun/server.mjs";

function runTool(call) {
  if (call.method === "lookup_customer") {
    if (call.params.customerId === "cust-42") {
      return {
        jsonrpc: "2.0",
        id: call.id,
        result: {
          customerId: "cust-42",
          company: "Northwind Studio",
          plan: "standard",
          renewalAtRisk: false
        }
      };
    }

    if (call.params.customerId === "cust-99") {
      return {
        jsonrpc: "2.0",
        id: call.id,
        result: {
          customerId: "cust-99",
          company: "Blue Yonder Enterprise",
          plan: "enterprise",
          renewalAtRisk: true
        }
      };
    }
  }

  if (call.method === "lookup_policy") {
    return {
      jsonrpc: "2.0",
      id: call.id,
      result: {
        topic: "renewal-blockers",
        guidance: "Confirm the blocker, set the next update window, and escalate urgent enterprise renewals."
      }
    };
  }

  throw new Error(`Unexpected tool call: ${call.method}`);
}

function draftStructuredDecision(ticket, customer) {
  if (customer.renewalAtRisk) {
    return JSON.stringify({
      action: "escalate",
      customerId: ticket.customerId,
      queue: "renewals-desk",
      reason: "legal-review-deadline",
      brief: "Enterprise renewal blocked on legal review."
    });
  }

  return JSON.stringify({
    action: "reply",
    customerId: ticket.customerId,
    subject: "Renewal update",
    reply: "We are coordinating with legal and will send the next update window shortly."
  });
}

function runScenario(compiledModule, dynamicDecision, lookupCustomer, lookupPolicy, ticket, traceCollector) {
  const customerRequest = compiledModule.lookupCustomerRequest(ticket);
  const customerCall = lookupCustomer.prepare(customerRequest, `${ticket.customerId}:customer`, {
    collector: traceCollector,
    context: { actor: { id: "renewal-agent" }, ticketId: ticket.customerId }
  });
  const customerEnvelope = runTool(customerCall);
  const customer = lookupCustomer.evaluateResult(customerEnvelope.result, {
    collector: traceCollector,
    context: { actor: { id: "renewal-agent" }, ticketId: ticket.customerId }
  }).result;

  const policyRequest = compiledModule.lookupPolicyRequest(ticket);
  const policyCall = lookupPolicy.prepare(policyRequest, `${ticket.customerId}:policy`, {
    collector: traceCollector,
    context: { actor: { id: "renewal-agent" }, ticketId: ticket.customerId }
  });
  const policyEnvelope = runTool(policyCall);
  const policy = lookupPolicy.evaluateResult(policyEnvelope.result, {
    collector: traceCollector,
    context: { actor: { id: "renewal-agent" }, ticketId: ticket.customerId }
  }).result;

  const prompt = compiledModule.decisionPrompt(ticket, customer, policy);
  const promptText = compiledModule.decisionPromptText(ticket, customer, policy);
  const decision = dynamicDecision.selectJson(
    draftStructuredDecision(ticket, customer),
    "decision"
  );

  return {
    ticket: ticket.customerId,
    toolMethods: [customerCall.method, policyCall.method],
    company: customer.company,
    plan: customer.plan,
    promptRoles: prompt.messages.map((message) => message.role),
    promptText,
    decisionType: decision.typeName,
    decisionAction: decision.value.action
  };
}

export async function runSupportAgentDemo(compiledModulePath) {
  const moduleUrl = pathToFileURL(path.resolve(compiledModulePath)).href;
  const compiledModule = await import(moduleUrl);
  const agent = compiledModule.__claspAgents.find((entry) => entry.name === "renewalAgent");
  const lookupCustomer = compiledModule.__claspToolCallContracts.find(
    (entry) => entry.name === "lookupCustomer"
  );
  const lookupPolicy = compiledModule.__claspToolCallContracts.find(
    (entry) => entry.name === "lookupPolicy"
  );

  if (!agent || !lookupCustomer || !lookupPolicy) {
    throw new Error("Missing expected support-agent exports");
  }

  const traceCollector = compiledModule.__claspTraceCollector.create();
  const dynamicDecision = createDynamicSchema(compiledModule, [
    "ReplyDraft",
    "EscalationDraft"
  ]);
  const scenarios = [
    runScenario(
      compiledModule,
      dynamicDecision,
      lookupCustomer,
      lookupPolicy,
      compiledModule.sampleTicket,
      traceCollector
    ),
    runScenario(
      compiledModule,
      dynamicDecision,
      lookupCustomer,
      lookupPolicy,
      compiledModule.riskTicket,
      traceCollector
    )
  ];

  return {
    agent: agent.name,
    approval: agent.role.approvalPolicy,
    sandbox: agent.role.sandboxPolicy,
    guideScope: agent.instructions.scope,
    plan: agent.instructions.plan,
    dynamicSchemaNames: dynamicDecision.schemaNames,
    scenarios,
    invalidDecision: (() => {
      try {
        dynamicDecision.selectJson("{\"action\":\"unknown\"}", "decision");
        return null;
      } catch (error) {
        return error.message;
      }
    })(),
    traceActions: traceCollector.entries().map((entry) => entry.action)
  };
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
const currentPath = fileURLToPath(import.meta.url);

if (invokedPath === currentPath) {
  const compiledModulePath = process.argv[2];

  if (!compiledModulePath) {
    throw new Error("usage: node examples/support-agent/demo.mjs <compiled-module>");
  }

  const result = await runSupportAgentDemo(compiledModulePath);
  console.log(JSON.stringify(result));
}
