type PermissionKind = "file" | "network" | "process" | "secret";
type DecisionContext = Record<string, unknown> | null;

type Decision = {
  kind: PermissionKind;
  target: string;
  allowed: boolean;
  context: DecisionContext;
};

type Guide = {
  scope: string;
  verification?: string;
  taskQueue?: string;
};

type ToolRequest = {
  jsonrpc: "2.0";
  id: string;
  method: "search_repo";
  params: { query: string };
};

type ToolResponse = {
  jsonrpc: "2.0";
  id: string;
  result: { summary: string };
};

function createPolicy(name: string, permissions: Record<PermissionKind, string[]>) {
  const matches = (kind: PermissionKind, target: string) =>
    permissions[kind].some((allowed) =>
      kind === "file" ? target === allowed || target.startsWith(`${allowed}/`) : target === allowed
    );

  return {
    name,
    permissions,
    decide(kind: PermissionKind, target: string, context: DecisionContext = null): Decision {
      return { kind, target, allowed: matches(kind, target), context };
    },
    decideFile(target: string, context: DecisionContext = null) {
      return this.decide("file", target, context);
    },
    decideNetwork(target: string, context: DecisionContext = null) {
      return this.decide("network", target, context);
    },
    decideProcess(target: string, context: DecisionContext = null) {
      return this.decide("process", target, context);
    },
    decideSecret(target: string, context: DecisionContext = null) {
      return this.decide("secret", target, context);
    },
    assertProcess(target: string) {
      const decision = this.decideProcess(target);
      if (!decision.allowed) {
        throw new Error(`Policy ${name} denies process access to ${target}`);
      }
      return decision;
    }
  };
}

const repoGuide: Guide = {
  scope: "Stay inside the current checkout."
};

const builderGuide: Guide = {
  ...repoGuide,
  taskQueue: "Inspect the repo first, then run the merge gate."
};

const repoControl = createPolicy("RepoControl", {
  file: ["/workspace", "/tmp"],
  network: ["api.openai.com", "example.com"],
  process: ["rg", "git"],
  secret: []
});

const builderRole = {
  guide: builderGuide,
  policy: repoControl,
  approvalPolicy: "never",
  sandboxPolicy: "read_only"
} as const;

const builderAgent = {
  name: "builder",
  role: builderRole,
  instructions: builderGuide,
  policy: repoControl
};

const workerStart = {
  name: "workerStart",
  invoke(request: { workerId: string }) {
    return { accepted: request.workerId.length > 0 };
  }
};

const searchRepo = {
  name: "searchRepo",
  prepare(params: { query: string }, requestId: string): ToolRequest {
    return {
      jsonrpc: "2.0",
      id: requestId,
      method: "search_repo",
      params
    };
  },
  decodeResultEnvelope(response: ToolResponse) {
    return response;
  }
};

const repoChecks = {
  name: "repoChecks",
  parseResult(result: { summary: string }) {
    return result;
  }
};

const trunk = {
  name: "trunk",
  plan(params: { query: string }, requestPrefix: string) {
    return [searchRepo.prepare(params, `${requestPrefix}:0`)];
  }
};

export async function runControlPlaneDemo() {
  const loopContext = { actor: { id: "builder-7" }, lane: "control-plane" };
  const plannedVerifierRequests = trunk.plan({ query: "bash scripts/verify-all.sh" }, "release");
  const queue = [
    {
      step: "inspect",
      request: searchRepo.prepare({ query: "rg --files src test" }, "release:inspect"),
      process: "rg",
      parser: (response: ToolResponse) => searchRepo.decodeResultEnvelope(response).result
    },
    {
      step: "verify",
      request: plannedVerifierRequests[0],
      process: "bash",
      parser: (response: ToolResponse) => repoChecks.parseResult(response.result)
    }
  ];
  const steps = [];

  const runTool = (request: ToolRequest): ToolResponse => {
    if (request.params.query === "rg --files src test") {
      return {
        jsonrpc: "2.0",
        id: request.id,
        result: { summary: "src/controlPlane.ts\ntest/control-plane.test.mjs" }
      };
    }

    if (request.params.query === "bash scripts/verify-all.sh") {
      return {
        jsonrpc: "2.0",
        id: request.id,
        result: { summary: "verification:ok" }
      };
    }

    throw new Error(`Unexpected query: ${request.params.query}`);
  };

  while (queue.length > 0) {
    const current = queue.shift();
    if (!current) {
      continue;
    }

    const processDecision = builderAgent.policy.decideProcess(current.process, { step: current.step });
    builderAgent.policy.assertProcess(current.process);
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
    agent: builderAgent.name,
    approval: builderAgent.role.approvalPolicy,
    sandbox: builderAgent.role.sandboxPolicy,
    hookAccepted: workerStart.invoke({ workerId: "builder-7" }).accepted,
    allowed: {
      file: builderAgent.policy.decideFile("/workspace/src/controlPlane.ts", loopContext).allowed,
      network: builderAgent.policy.decideNetwork("api.openai.com", loopContext).allowed,
      processRg: builderAgent.policy.decideProcess("rg", { step: "inspect" }).allowed,
      processBash: builderAgent.policy.decideProcess("bash", { step: "verify" }).allowed,
      secret: builderAgent.policy.decideSecret("OPENAI_API_KEY", loopContext).allowed
    },
    denied: {
      file: builderAgent.policy.decideFile("/tmp/secret.txt", loopContext).allowed,
      network: builderAgent.policy.decideNetwork("example.com", loopContext).allowed,
      process: builderAgent.policy.decideProcess("git", { step: "push" }).allowed,
      secret: builderAgent.policy.decideSecret("AWS_SECRET_ACCESS_KEY", loopContext).allowed
    },
    taskQueue: builderAgent.instructions.taskQueue,
    verificationGuide: builderAgent.instructions.verification ?? null,
    mergeGateRequest: plannedVerifierRequests[0].id,
    steps
  };
}
