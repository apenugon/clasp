import { pathToFileURL } from "node:url";

const compiledPath = process.argv[2];

if (!compiledPath) {
  throw new Error("usage: node examples/prompt-functions/demo.mjs <compiled-module>");
}

const compiledModule = await import(pathToFileURL(compiledPath).href);
const secretInput = compiledModule.__claspSecretInputs[0];
const secretBoundary = compiledModule.__claspSecretBoundaries.find(
  (boundary) => boundary.kind === "toolServer"
);
const traceContext = {
  actor: { id: "prompt-worker", tags: ["demo"] },
  requestId: "prompt-demo-1"
};
const secretTrace = secretInput.traceAccess(
  secretBoundary,
  { OPENAI_API_KEY: "sk-live-openai" },
  traceContext
);
const resolvedSecret = secretInput.resolve(
  secretBoundary,
  { OPENAI_API_KEY: "sk-live-openai" },
  traceContext
);
const traceCollector = compiledModule.__claspTraceCollector.create();
const evalHooks = compiledModule.__claspEvalHooks.create({
  trace(trace) {
    traceCollector.record(trace);
  }
});
const preparedCall = compiledModule.__claspToolCallContracts[0].prepare(
  { query: compiledModule.replyPromptText },
  "prompt-call-1",
  { traceId: "prompt-tool-call", hooks: evalHooks, context: traceContext }
);
const collectedTraces = traceCollector.entries();
const tool = compiledModule.__claspTools[0];

console.log(
  JSON.stringify({
    messageCount: compiledModule.replyPromptValue.messages.length,
    roles: compiledModule.replyPromptValue.messages.map((message) => message.role),
    content: compiledModule.replyPromptValue.messages.map((message) => message.content),
    text: compiledModule.replyPromptText,
    promptHasSecretValue: JSON.stringify(compiledModule.replyPromptValue).includes("sk-live-openai"),
    promptMessageKeys: compiledModule.replyPromptValue.messages.map((message) =>
      Object.keys(message).sort().join(",")
    ),
    promptPolicySurface: compiledModule.__claspAgents[0]?.policy?.name ?? null,
    promptGuideScope: compiledModule.__claspAgents[0]?.instructions?.scope ?? null,
    traceSecret: secretTrace.secret,
    tracePolicy: secretTrace.policy,
    traceBoundary: secretTrace.boundary.name,
    traceActor: secretTrace.context.actor.id,
    traceHasSecretValue: JSON.stringify(secretTrace).includes("sk-live-openai"),
    resolvedSecretName: resolvedSecret.name,
    toolMethod: preparedCall.method,
    toolQuery: preparedCall.params.query,
    toolCallHasSecretValue: JSON.stringify(preparedCall).includes("sk-live-openai"),
    toolKnowsDeclaredSecret: tool.secretConsumer().hasSecret("OPENAI_API_KEY"),
    evalTraceCount: collectedTraces.length,
    evalTraceAction: collectedTraces[0]?.action ?? null,
    evalTraceActor: collectedTraces[0]?.context?.actor?.id ?? null
  })
);
