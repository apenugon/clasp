const promptMessages = Object.freeze([
  Object.freeze({ role: "system", content: "You are a support agent." }),
  Object.freeze({ role: "assistant", content: "Draft a concise reply." }),
  Object.freeze({ role: "user", content: "Renewal is blocked on legal review." })
]);

const replyWorkerRole = Object.freeze({
  name: "ReplyWorkerRole",
  approval: "on_request",
  sandbox: "workspace_write"
});

const replyPolicy = Object.freeze({
  name: "ReplyPolicy",
  secretNames: Object.freeze(["OPENAI_API_KEY"])
});

const searchPolicy = Object.freeze({
  name: "SearchPolicy",
  secretNames: Object.freeze([])
});

function cloneContext(context) {
  return context ? JSON.parse(JSON.stringify(context)) : null;
}

function createSecretConsumer({ kind, name, boundary, policy }) {
  const secretHandles = Object.freeze(
    policy.secretNames.map((secretName) => Object.freeze({ name: secretName }))
  );

  return Object.freeze({
    kind,
    name,
    boundary,
    policy,
    secretHandles,
    hasSecret(secretHandleOrName) {
      const secretName =
        typeof secretHandleOrName === "string" ? secretHandleOrName : secretHandleOrName?.name;
      return policy.secretNames.includes(secretName);
    },
    handle(secretHandleOrName) {
      const secretName =
        typeof secretHandleOrName === "string" ? secretHandleOrName : secretHandleOrName?.name;

      if (!policy.secretNames.includes(secretName)) {
        throw new Error(`Undeclared secret ${secretName} for ${kind} ${name}`);
      }

      return Object.freeze({ name: secretName });
    },
    traceAccess(secretHandleOrName, provider, options = null) {
      const secretHandle = this.handle(secretHandleOrName);

      return Object.freeze({
        secret: secretHandle.name,
        policy: policy.name,
        boundary: Object.freeze({ ...boundary }),
        context: cloneContext(options?.context ?? null)
      });
    },
    resolve(secretHandleOrName, provider, options = null) {
      const secretHandle = this.handle(secretHandleOrName);
      const trace = this.traceAccess(secretHandle, provider, options);
      const value = provider?.[secretHandle.name];

      if (value === undefined) {
        throw new Error(
          `Missing secret ${secretHandle.name} for ${boundary.kind} ${boundary.name} under policy ${policy.name}`
        );
      }

      return Object.freeze({
        name: secretHandle.name,
        value,
        trace
      });
    }
  });
}

function createToolInputSurface(tool, value) {
  const secretConsumer = tool.secretConsumer();

  return Object.freeze({
    secretHandles: secretConsumer.secretHandles,
    prepare(id, options = null) {
      return Object.freeze({
        jsonrpc: "2.0",
        id,
        method: tool.method,
        params: Object.freeze({ ...value }),
        traceId: options?.traceId ?? null
      });
    }
  });
}

const replyWorker = Object.freeze({
  name: "replyWorker",
  role: replyWorkerRole,
  policy: replyPolicy,
  secretConsumer() {
    return createSecretConsumer({
      kind: "agent",
      name: this.name,
      boundary: { kind: "agentRole", name: replyWorkerRole.name },
      policy: replyPolicy
    });
  }
});

const summarizeDraft = Object.freeze({
  name: "summarizeDraft",
  method: "summarize_draft",
  secretConsumer() {
    return createSecretConsumer({
      kind: "tool",
      name: this.name,
      boundary: { kind: "toolServer", name: "SearchTools" },
      policy: searchPolicy
    });
  },
  inputSurface(value) {
    return createToolInputSurface(this, value);
  }
});

export async function runSecretHandlingDemo() {
  const provider = {
    OPENAI_API_KEY: "sk-live-openai",
    SEARCH_API_TOKEN: "tok-search-live"
  };
  const context = {
    actor: { id: "secret-worker", tags: ["demo"] },
    requestId: "secret-demo-1"
  };
  const promptValue = Object.freeze({ messages: promptMessages });
  const promptText = promptMessages.map((message) => `${message.role}: ${message.content}`).join("\n\n");
  const agentSecrets = replyWorker.secretConsumer();
  const toolSecrets = summarizeDraft.secretConsumer();
  const preparedCall = summarizeDraft
    .inputSurface({ query: promptText })
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
    messageCount: promptValue.messages.length,
    promptHasSecretValue: JSON.stringify(promptValue).includes("sk-live-openai"),
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
