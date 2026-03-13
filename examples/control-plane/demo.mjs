import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

export async function runControlPlaneDemo(compiledModulePath) {
  const moduleUrl = pathToFileURL(path.resolve(compiledModulePath)).href;
  const compiledModule = await import(moduleUrl);
  const agent = compiledModule.__claspAgents.find((entry) => entry.name === "builder");
  const hook = compiledModule.__claspHooks.find((entry) => entry.name === "workerStart");
  const tool = compiledModule.__claspToolCallContracts.find((entry) => entry.name === "searchRepo");
  const verifier = compiledModule.__claspVerifiers.find((entry) => entry.name === "repoChecks");
  const mergeGate = compiledModule.__claspMergeGates.find((entry) => entry.name === "trunk");
  if (!agent || !hook || !tool || !verifier || !mergeGate) {
    throw new Error("Missing expected control-plane exports");
  }

  const runTool = (request) => {
    if (request.method !== "search_repo") {
      throw new Error(`Unexpected tool method: ${request.method}`);
    }
    const query = request.params.query;
    if (query === "rg --files src test") {
      return {
        jsonrpc: "2.0",
        id: request.id,
        result: { summary: "src/Clasp/Compiler.hs\ntest/Main.hs" }
      };
    }
    if (query === "bash scripts/verify-all.sh") {
      return {
        jsonrpc: "2.0",
        id: request.id,
        result: { summary: "verification:ok" }
      };
    }
    throw new Error(`Unexpected query: ${query}`);
  };

  const boot = hook.invoke({ workerId: "builder-7" });
  const loopContext = { actor: { id: "builder-7" }, lane: "control-plane" };
  const fileDecision = agent.policy.decideFile("/workspace/src/Clasp/Compiler.hs", loopContext);
  const plannedVerifierRequests = mergeGate.plan({ query: "bash scripts/verify-all.sh" }, "release");
  const queue = [
    {
      step: "inspect",
      request: tool.prepare({ query: "rg --files src test" }, "release:inspect"),
      process: "rg",
      parser: (response) => tool.decodeResultEnvelope(response).result
    },
    {
      step: "verify",
      request: plannedVerifierRequests[0],
      process: "bash",
      parser: (response) => verifier.parseResult(response.result)
    }
  ];
  const steps = [];

  while (queue.length > 0) {
    const current = queue.shift();
    const processDecision = agent.policy.decideProcess(current.process, { step: current.step });
    agent.policy.assertProcess(current.process);
    const response = runTool(current.request);
    const parsed = current.parser(response);
    steps.push({
      step: current.step,
      requestId: current.request.id,
      method: current.request.method,
      allowed: processDecision.allowed,
      summary: parsed.summary
    });
  }

  return {
    agent: agent.name,
    approval: agent.role.approvalPolicy,
    sandbox: agent.role.sandboxPolicy,
    hookAccepted: boot.accepted,
    fileAllowed: fileDecision.allowed,
    taskQueue: agent.instructions.taskQueue,
    verificationGuide: agent.instructions.verification,
    mergeGateRequest: plannedVerifierRequests[0].id,
    steps
  };
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
const currentPath = fileURLToPath(import.meta.url);

if (invokedPath === currentPath) {
  const compiledModulePath = process.argv[2];
  if (!compiledModulePath) {
    throw new Error("usage: node examples/control-plane/demo.mjs <compiled-module>");
  }
  const result = await runControlPlaneDemo(compiledModulePath);
  console.log(JSON.stringify(result));
}
