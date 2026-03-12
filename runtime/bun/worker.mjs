function bindingContractFor(compiledModule) {
  const contract = compiledModule?.__claspBindings;

  if (
    contract &&
    contract.kind === "clasp-generated-bindings" &&
    contract.version === 1
  ) {
    return {
      ...contract,
      nativeInterop:
        contract.nativeInterop ??
        compiledModule?.__claspNativeInterop ??
        defaultNativeInterop(compiledModule?.__claspHostBindings ?? [])
    };
  }

  return {
    kind: "clasp-generated-bindings",
    version: 1,
    schemas: compiledModule?.__claspSchemas ?? {},
    nativeInterop:
      compiledModule?.__claspNativeInterop ??
      defaultNativeInterop(compiledModule?.__claspHostBindings ?? [])
  };
}

function defaultNativeInterop(hostBindings) {
  return Object.freeze({
    version: 1,
    abi: "clasp-native-v1",
    supportedTargets: Object.freeze(["bun", "worker", "react-native", "expo"]),
    bindings: Object.freeze((hostBindings ?? []).map((binding) => Object.freeze({
      name: binding?.name ?? "binding",
      runtimeName: binding?.runtimeName ?? binding?.name ?? "binding",
      capability: Object.freeze({
        id: `capability:foreign:${binding?.name ?? "binding"}`,
        kind: "foreign-function",
        runtimeName: binding?.runtimeName ?? binding?.name ?? "binding"
      })
    })))
  });
}

export function schemaContractFor(compiledModule, typeName) {
  const contract = bindingContractFor(compiledModule);
  const schema = contract.schemas?.[typeName];

  if (!schema) {
    throw new Error(`Missing Clasp schema contract: ${typeName}`);
  }

  return schema;
}

export function workflowContractFor(compiledModule, workflowName) {
  const workflows = Array.isArray(compiledModule?.__claspWorkflows)
    ? compiledModule.__claspWorkflows
    : [];
  const workflow = workflows.find((entry) => entry?.name === workflowName);

  if (!workflow) {
    throw new Error(`Missing Clasp workflow contract: ${workflowName}`);
  }

  return workflow;
}

export function createWorkerJob(compiledModule, options) {
  if (!options || typeof options !== "object") {
    throw new Error("createWorkerJob requires job options.");
  }

  const { name, inputType, outputType, handler } = options;

  if (typeof name !== "string" || name === "") {
    throw new Error("Worker jobs require a non-empty name.");
  }

  if (typeof handler !== "function") {
    throw new Error(`Worker job ${name} requires a handler function.`);
  }

  const input = schemaContractFor(compiledModule, inputType);
  const output = schemaContractFor(compiledModule, outputType);

  return Object.freeze({
    kind: "clasp-worker-job",
    version: 1,
    name,
    inputType,
    inputSchema: input.schema ?? null,
    inputSeed: input.seed ?? null,
    outputType,
    outputSchema: output.schema ?? null,
    outputSeed: output.seed ?? null,
    decodeInput(jsonText) {
      return input.decodeJson(jsonText);
    },
    encodeInput(value) {
      return input.encodeJson(value);
    },
    decodeOutput(jsonText) {
      return output.decodeJson(jsonText);
    },
    encodeOutput(value) {
      return output.encodeJson(value);
    },
    async run(value, context = {}) {
      const preparedInput = input.toHost(input.fromHost(value, "value"), "value");
      const result = await handler(preparedInput, context);
      return output.toHost(output.fromHost(result, "result"), "result");
    },
    async dispatch(jsonText, context = {}) {
      const result = await this.run(this.decodeInput(jsonText), context);
      return this.encodeOutput(result);
    }
  });
}

export function createWorkerRuntime(compiledModule, options = {}) {
  const jobs = new Map();
  const initialJobs = Array.isArray(options.jobs) ? options.jobs : [];

  for (const job of initialJobs) {
    registerJob(job);
  }

  return {
    contract: bindingContractFor(compiledModule),
    schema(typeName) {
      return schemaContractFor(compiledModule, typeName);
    },
    workflow(name) {
      return workflowContractFor(compiledModule, name);
    },
    registerJob(jobOrOptions) {
      return registerJob(jobOrOptions);
    },
    job(name) {
      return getJob(name);
    },
    listJobs() {
      return Array.from(jobs.values());
    },
    async run(name, value, context = {}) {
      return getJob(name).run(value, context);
    },
    async dispatch(name, jsonText, context = {}) {
      return getJob(name).dispatch(jsonText, context);
    }
  };

  function registerJob(jobOrOptions) {
    const job =
      jobOrOptions?.kind === "clasp-worker-job"
        ? jobOrOptions
        : createWorkerJob(compiledModule, jobOrOptions);

    if (jobs.has(job.name)) {
      throw new Error(`Duplicate Clasp worker job: ${job.name}`);
    }

    jobs.set(job.name, job);
    return job;
  }

  function getJob(name) {
    const job = jobs.get(name);

    if (!job) {
      throw new Error(`Missing Clasp worker job: ${name}`);
    }

    return job;
  }
}
