import path from "node:path";
import { pathToFileURL } from "node:url";

export async function runSecretHandlingDemo(compiledModulePath) {
  const compiledModule = await import(pathToFileURL(path.resolve(compiledModulePath)).href);
  const agent = compiledModule.__claspAgents[0];
  const tool = compiledModule.__claspTools[0];
  const agentBoundary = compiledModule.__claspSecretBoundaries.find(
    (boundary) => boundary.kind === "agentRole"
  );
  const toolBoundary = compiledModule.__claspSecretBoundaries.find(
    (boundary) => boundary.kind === "toolServer"
  );

  if (!agent || !tool || !agentBoundary || !toolBoundary) {
    throw new Error("missing expected secret surfaces");
  }

  const provider = {
    OPENAI_API_KEY: "sk-live-openai",
    SEARCH_API_TOKEN: "tok-search-live"
  };
  const context = {
    actor: { id: "secret-worker", tags: ["demo"] },
    requestId: "secret-demo-1"
  };
  const agentSecrets = agent.secretConsumer();
  const toolSecrets = tool.secretConsumer();
  const preparedCall = tool
    .inputSurface({ query: compiledModule.replyPromptText })
    .prepare("call-1", { traceId: "secret-tool-call", context });
  const agentTrace = agentSecrets.traceAccess("OPENAI_API_KEY", provider, { context });
  const agentResolved = agentSecrets.resolve("OPENAI_API_KEY", provider, { context });
  const toolResolved = toolSecrets.resolve("SEARCH_API_TOKEN", provider, { context });

  let missingSecret = null;
  let misusedSecret = null;

  try {
    toolSecrets.resolve("SEARCH_API_TOKEN", {}, { context });
  } catch (error) {
    missingSecret = error instanceof Error ? error.message : String(error);
  }

  try {
    toolSecrets.resolve("OPENAI_API_KEY", provider, { context });
  } catch (error) {
    misusedSecret = error instanceof Error ? error.message : String(error);
  }

  return {
    messageCount: compiledModule.replyPromptValue.messages.length,
    promptHasSecretValue: JSON.stringify(compiledModule.replyPromptValue).includes("sk-live-openai"),
    agentTraceHasSecretValue: JSON.stringify(agentTrace).includes("sk-live-openai"),
    preparedMethod: preparedCall.method,
    preparedCallHasSecretValue:
      JSON.stringify(preparedCall).includes("sk-live-openai") ||
      JSON.stringify(preparedCall).includes("tok-search-live"),
    agentSecretNames: agentSecrets.secretHandles.map((secretHandle) => secretHandle.name),
    toolSecretNames: toolSecrets.secretHandles.map((secretHandle) => secretHandle.name),
    agentTracePolicy: agentTrace.policy,
    agentTraceBoundary: agentTrace.boundary.name,
    agentResolvedName: agentResolved.name,
    agentResolvedValue: agentResolved.value,
    toolResolvedName: toolResolved.name,
    toolResolvedValue: toolResolved.value,
    toolTracePolicy: toolResolved.trace.policy,
    missingSecret,
    misusedSecret
  };
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;

if (invokedPath === path.resolve(new URL(import.meta.url).pathname)) {
  const compiledModulePath = process.argv[2];

  if (!compiledModulePath) {
    throw new Error("usage: node demo.mjs <compiled-module>");
  }

  console.log(JSON.stringify(await runSecretHandlingDemo(compiledModulePath)));
}
