import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import {
  compileNativeBinary,
  compileNativeImage,
  runBinary,
} from "../native-demo.mjs";

function runTool(call) {
  if (call.method === "lookup_customer") {
    if (call.params.customerId === "cust-42") {
      return {
        customerId: "cust-42",
        company: "Northwind Studio",
        plan: "standard",
        renewalAtRisk: false,
      };
    }

    if (call.params.customerId === "cust-99") {
      return {
        customerId: "cust-99",
        company: "Blue Yonder Enterprise",
        plan: "enterprise",
        renewalAtRisk: true,
      };
    }
  }

  if (call.method === "lookup_policy") {
    return {
      topic: "renewal-blockers",
      guidance:
        "Confirm the blocker, set the next update window, and escalate urgent enterprise renewals.",
    };
  }

  throw new Error(`Unexpected tool call: ${call.method}`);
}

function draftStructuredDecision(ticket, customer) {
  if (customer.renewalAtRisk) {
    return {
      action: "escalate",
      customerId: ticket.customerId,
      queue: "renewals-desk",
      reason: "legal-review-deadline",
      brief: "Enterprise renewal blocked on legal review.",
    };
  }

  return {
    action: "reply",
    customerId: ticket.customerId,
    subject: "Renewal update",
    reply: "We are coordinating with legal and will send the next update window shortly.",
  };
}

function readSourceMetadata(sourcePath) {
  const source = fs.readFileSync(sourcePath, "utf8");
  const guideScope =
    source.match(/scope:\s*"([^"]+)"/)?.[1] ?? null;
  const guidePlan =
    source.match(/plan:\s*"([^"]+)"/)?.[1] ?? null;
  const approval =
    source.match(/approval:\s*([^,\n]+)/)?.[1]?.trim() ?? null;
  const sandbox =
    source.match(/sandbox:\s*([^,\n]+)/)?.[1]?.trim() ?? null;
  const agent = source.match(/agent\s+([A-Za-z0-9_]+)\s*=/)?.[1] ?? null;
  return {
    agent,
    approval,
    sandbox,
    guideScope,
    guidePlan,
  };
}

function renderPromptText(customer, policy, issue) {
  return [
    "system: You are the renewal desk agent.",
    `assistant: ${customer.company}`,
    `assistant: ${policy.guidance}`,
    `user: ${issue}`,
  ].join("\n\n");
}

function selectDecisionType(value, schemaNames) {
  if (!schemaNames.includes("ReplyDraft") || !schemaNames.includes("EscalationDraft")) {
    throw new Error(
      `decision did not match any dynamic schema candidate: ${schemaNames.join(", ")}`
    );
  }

  if (value?.action === "reply") {
    return "ReplyDraft";
  }

  if (value?.action === "escalate") {
    return "EscalationDraft";
  }

  throw new Error(
    `decision did not match any dynamic schema candidate: ${schemaNames.join(", ")}`
  );
}

function runScenario(ticket, toolMethods, schemaNames) {
  const customer = runTool({
    method: toolMethods[0],
    params: { customerId: ticket.customerId },
  });
  const policy = runTool({
    method: toolMethods[1],
    params: { topic: "renewal-blockers" },
  });
  const decision = draftStructuredDecision(ticket, customer);
  return {
    ticket: ticket.customerId,
    toolMethods,
    company: customer.company,
    plan: customer.plan,
    promptRoles: ["system", "assistant", "assistant", "user"],
    promptText: renderPromptText(customer, policy, ticket.issue),
    decisionType: selectDecisionType(decision, schemaNames),
    decisionAction: decision.action,
  };
}

export async function runSupportAgentDemo(binaryPath = null, imagePath = null) {
  const sourcePath = path.resolve("examples/support-agent/Main.clasp");
  const compiledBinary = compileNativeBinary(
    "examples/support-agent/Main.clasp",
    binaryPath,
    "support-agent-demo"
  );
  const compiledImage = compileNativeImage(
    "examples/support-agent/Main.clasp",
    imagePath,
    "support-agent-demo.native.image.json"
  );

  try {
    const metadata = readSourceMetadata(sourcePath);
    const image = JSON.parse(fs.readFileSync(compiledImage.imagePath, "utf8"));
    const tools = (image?.runtime?.boundaries ?? [])
      .filter((entry) => entry?.kind === "tool")
      .sort((left, right) => left.name.localeCompare(right.name));
    const toolNames = tools.map((tool) => tool.name);
    const toolMethods = tools.map((tool) => tool.operation);
    const schemaNames = (image?.abi?.recordLayouts ?? [])
      .map((layout) => layout?.name)
      .filter((name) => name === "ReplyDraft" || name === "EscalationDraft")
      .sort();

    const samplePromptText = runBinary(compiledBinary.binaryPath, []);
    const scenarios = [
      {
        ...runScenario(
          {
            customerId: "cust-42",
            issue: "Renewal is blocked on legal review.",
          },
          toolMethods,
          schemaNames
        ),
        promptText: samplePromptText,
      },
      runScenario(
        {
          customerId: "cust-99",
          issue: "Enterprise renewal is blocked and the deadline is today.",
        },
        toolMethods,
        schemaNames
      ),
    ];

    let invalidDecision = null;
    try {
      selectDecisionType({ action: "unknown" }, schemaNames);
    } catch (error) {
      invalidDecision = error instanceof Error ? error.message : String(error);
    }

    return {
      agent: metadata.agent,
      approval: metadata.approval,
      sandbox: metadata.sandbox,
      guideScope: metadata.guideScope,
      plan: metadata.guidePlan,
      toolNames,
      dynamicSchemaNames: schemaNames,
      scenarios,
      invalidDecision,
    };
  } finally {
    compiledImage.cleanup();
    compiledBinary.cleanup();
  }
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
const currentPath = fileURLToPath(import.meta.url);

if (invokedPath === currentPath) {
  const result = await runSupportAgentDemo(process.argv[2] ?? null, process.argv[3] ?? null);
  console.log(JSON.stringify(result));
}
