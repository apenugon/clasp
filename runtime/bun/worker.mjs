function bindingContractFor(compiledModule) {
  const contract = compiledModule?.__claspBindings;

  if (
    contract &&
    contract.kind === "clasp-generated-bindings" &&
    contract.version === 1
  ) {
    return {
      ...contract,
      module: contract.module ?? compiledModule?.__claspModule ?? null,
      nativeInterop:
        contract.nativeInterop ??
        compiledModule?.__claspNativeInterop ??
        defaultNativeInterop(compiledModule?.__claspHostBindings ?? [])
    };
  }

  return {
    kind: "clasp-generated-bindings",
    version: 1,
    module: compiledModule?.__claspModule ?? null,
    schemas: compiledModule?.__claspSchemas ?? {},
    nativeInterop:
      compiledModule?.__claspNativeInterop ??
      defaultNativeInterop(compiledModule?.__claspHostBindings ?? [])
  };
}

export function moduleContractFor(compiledModule) {
  const module = bindingContractFor(compiledModule).module;

  if (!module || typeof module !== "object") {
    throw new Error("Missing Clasp module contract.");
  }

  if (typeof module.versionId !== "string" || module.versionId === "") {
    throw new Error("Clasp module contract is missing a versionId.");
  }

  return module;
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

export function createModuleHotSwapProtocol(
  sourceCompiledModule,
  targetCompiledModule,
  options = {}
) {
  const sourceModule = moduleContractFor(sourceCompiledModule);
  const targetModule = moduleContractFor(targetCompiledModule);
  const targetUpgradeWindow = normalizeHotSwapUpgradeWindow(targetModule);

  if (!targetUpgradeWindow.fromVersionIds.includes(sourceModule.versionId)) {
    throw new Error(
      `Module ${targetModule.name} cannot hot-swap from version ${sourceModule.versionId}.`
    );
  }

  const sourceWorkflows = Array.isArray(sourceCompiledModule?.__claspWorkflows)
    ? sourceCompiledModule.__claspWorkflows
    : [];
  const targetWorkflows = Array.isArray(targetCompiledModule?.__claspWorkflows)
    ? targetCompiledModule.__claspWorkflows
    : [];
  const workflowPlans = Object.freeze(
    sourceWorkflows.map((sourceWorkflow) => {
      const targetWorkflow = targetWorkflows.find(
        (candidate) => candidate?.name === sourceWorkflow?.name
      );

      if (!targetWorkflow) {
        throw new Error(
          `Module ${targetModule.name} is missing workflow ${String(sourceWorkflow?.name)}.`
        );
      }

      const compatibleModuleVersionIds = Array.isArray(
        targetWorkflow.compatibility?.compatibleModuleVersionIds
      )
        ? targetWorkflow.compatibility.compatibleModuleVersionIds
        : [];

      if (!compatibleModuleVersionIds.includes(sourceWorkflow.moduleVersionId)) {
        throw new Error(
          `Workflow ${sourceWorkflow.name} cannot hot-swap from module version ${sourceWorkflow.moduleVersionId} to ${targetWorkflow.moduleVersionId}.`
        );
      }

      return Object.freeze({
        name: sourceWorkflow.name,
        sourceWorkflow,
        targetWorkflow,
        sourceWorkflowId: sourceWorkflow.id,
        targetWorkflowId: targetWorkflow.id,
        sourceStateType: sourceWorkflow.stateType,
        targetStateType: targetWorkflow.stateType,
        hotSwap: targetWorkflow.compatibility?.hotSwap ?? null
      });
    })
  );
  const workflowPlansByName = new Map(workflowPlans.map((plan) => [plan.name, plan]));
  const defaultSupervisor = normalizeHotSwapLabel(options.supervisor, "hotSwap.supervisor");

  return Object.freeze({
    kind: "clasp-module-hot-swap",
    version: 1,
    supervisor: defaultSupervisor,
    source: Object.freeze({
      name: sourceModule.name,
      versionId: sourceModule.versionId
    }),
    target: Object.freeze({
      name: targetModule.name,
      versionId: targetModule.versionId
    }),
    overlap: Object.freeze({
      policy: targetUpgradeWindow.policy,
      maxActiveVersions: 2,
      activeVersionIds: Object.freeze([sourceModule.versionId, targetModule.versionId]),
      drainingVersionIds: Object.freeze([sourceModule.versionId]),
      acceptedSourceVersionIds: targetUpgradeWindow.fromVersionIds,
      targetVersionId: targetUpgradeWindow.toVersionId
    }),
    workflows: workflowPlans,
    workflow(name) {
      return getWorkflowPlan(name);
    },
    migrate(workflowName, snapshot, workflowOptions) {
      const plan = getWorkflowPlan(workflowName);
      return plan.sourceWorkflow.migrate(snapshot, plan.targetWorkflow, workflowOptions);
    },
    upgrade(workflowName, run, workflowOptions) {
      const plan = getWorkflowPlan(workflowName);
      return plan.sourceWorkflow.upgrade(
        run,
        plan.targetWorkflow,
        normalizeHotSwapWorkflowUpgradeOptions(workflowOptions, "hotSwap.upgrade")
      );
    },
    activate(workflowName, run, activationOptions = {}) {
      const plan = getWorkflowPlan(workflowName);
      const normalizedOptions = normalizeHotSwapActivationOptions(
        activationOptions,
        "hotSwap.activate"
      );
      const upgraded = plan.sourceWorkflow.upgrade(
        run,
        plan.targetWorkflow,
        normalizedOptions.upgrade
      );
      const health = evaluateHotSwapHealthCheck(
        normalizedOptions.healthCheck,
        upgraded.run,
        Object.freeze({
          workflowName: plan.name,
          supervisor: upgraded.run.supervision.supervisor,
          sourceVersionId: sourceModule.versionId,
          targetVersionId: targetModule.versionId,
          context: upgraded.context,
          upgrade: upgraded
        }),
        "hotSwap.activate.healthCheck"
      );

      if (health.healthy) {
        return Object.freeze({
          status: "activated",
          workflowName: plan.name,
          supervisor: upgraded.run.supervision.supervisor,
          sourceVersionId: sourceModule.versionId,
          targetVersionId: targetModule.versionId,
          rollbackVersionId: sourceModule.versionId,
          rollbackAvailable: true,
          run: upgraded.run,
          health,
          upgrade: upgraded
        });
      }

      if (!normalizedOptions.rollbackOnFail) {
        return Object.freeze({
          status: "blocked",
          workflowName: plan.name,
          supervisor: upgraded.run.supervision.supervisor,
          sourceVersionId: sourceModule.versionId,
          targetVersionId: targetModule.versionId,
          rollbackVersionId: sourceModule.versionId,
          rollbackAvailable: true,
          run: upgraded.run,
          health,
          upgrade: upgraded
        });
      }

      const rolledBack = performRollback(
        plan,
        upgraded.run,
        normalizedOptions.rollback,
        normalizedOptions.rollbackTrigger
      );

      return Object.freeze({
        status: rolledBack.status,
        workflowName: plan.name,
        supervisor: rolledBack.supervisor,
        sourceVersionId: sourceModule.versionId,
        targetVersionId: targetModule.versionId,
        rollbackVersionId: sourceModule.versionId,
        rollbackAvailable: rolledBack.rollbackAvailable,
        run: rolledBack.run,
        health,
        upgrade: upgraded,
        rollback: rolledBack,
        trigger: rolledBack.trigger
      });
    },
    handoff(workflowName, run, operator, reason, handoffOptions = {}) {
      const plan = getWorkflowPlan(workflowName);
      const supervisor =
        normalizeHotSwapLabel(
          handoffOptions.supervisor,
          "hotSwap.handoff.supervisor"
        ) ?? defaultSupervisor;
      const handedOffRun = plan.sourceWorkflow.handoff(run, operator, reason, {
        supervisor,
        updatedAt: normalizeHotSwapTimestamp(
          handoffOptions.updatedAt,
          "hotSwap.handoff.updatedAt"
        )
      });

      return Object.freeze({
        status: "handoff",
        workflowName: plan.name,
        supervisor,
        sourceVersionId: sourceModule.versionId,
        targetVersionId: targetModule.versionId,
        rollbackVersionId: sourceModule.versionId,
        run: handedOffRun,
        safeToSwap: true,
        rollbackAvailable: true
      });
    },
    drain(workflowName, run, drainOptions = {}) {
      const plan = getWorkflowPlan(workflowName);
      const supervisor =
        normalizeHotSwapLabel(
          drainOptions.supervisor,
          "hotSwap.drain.supervisor"
        ) ?? defaultSupervisor;
      const updatedAt = normalizeHotSwapTimestamp(
        drainOptions.updatedAt,
        "hotSwap.drain.updatedAt"
      );
      const drainingRun =
        run?.supervision?.status === "operator_handoff"
          ? plan.sourceWorkflow.handoff(
              run,
              run.supervision.operator,
              run.supervision.reason,
              {
                supervisor: supervisor ?? run.supervision.supervisor ?? null,
                updatedAt: updatedAt ?? run.supervision.updatedAt ?? null
              }
            )
          : plan.sourceWorkflow.handoff(
              run,
              normalizeHotSwapLabel(
                drainOptions.operator,
                "hotSwap.drain.operator"
              ),
              normalizeHotSwapLabel(
                drainOptions.reason,
                "hotSwap.drain.reason"
              ),
              { supervisor, updatedAt }
            );

      return Object.freeze({
        status: "draining",
        workflowName: plan.name,
        supervisor: drainingRun.supervision.supervisor,
        sourceVersionId: sourceModule.versionId,
        targetVersionId: targetModule.versionId,
        drainingVersionId: sourceModule.versionId,
        targetReady: true,
        rollbackVersionId: sourceModule.versionId,
        rollbackAvailable: true,
        run: drainingRun
      });
    },
    rollback(workflowName, run, workflowOptions = {}) {
      const plan = getWorkflowPlan(workflowName);
      return performRollback(plan, run, workflowOptions);
    },
    triggerRollback(workflowName, run, trigger, workflowOptions = {}) {
      const plan = getWorkflowPlan(workflowName);
      return performRollback(plan, run, workflowOptions, trigger);
    },
    begin(beginOptions = {}) {
      return Object.freeze({
        status: "overlap",
        supervisor: normalizeHotSwapLabel(
          beginOptions.supervisor,
          "hotSwap.begin.supervisor"
        ) ?? defaultSupervisor,
        startedAt: normalizeHotSwapTimestamp(beginOptions.startedAt, "hotSwap.begin.startedAt"),
        activeVersionIds: Object.freeze([
          sourceModule.versionId,
          targetModule.versionId
        ]),
        drainingVersionIds: Object.freeze([sourceModule.versionId]),
        workflowCount: workflowPlans.length
      });
    },
    retire(retireOptions = {}) {
      return Object.freeze({
        status: "retired",
        supervisor: normalizeHotSwapLabel(
          retireOptions.supervisor,
          "hotSwap.retire.supervisor"
        ) ?? defaultSupervisor,
        retiredAt: normalizeHotSwapTimestamp(retireOptions.retiredAt, "hotSwap.retire.retiredAt"),
        retiredVersionId: sourceModule.versionId,
        activeVersionIds: Object.freeze([targetModule.versionId]),
        reason: normalizeHotSwapLabel(retireOptions.reason, "hotSwap.retire.reason")
      });
    }
  });

  function getWorkflowPlan(name) {
    const plan = workflowPlansByName.get(name);

    if (!plan) {
      throw new Error(`Missing Clasp hot-swap workflow: ${name}`);
    }

    return plan;
  }

  function performRollback(plan, run, workflowOptions = {}, trigger = null) {
    const rollbackWorkflow = patchRollbackWorkflowCompatibility(
      plan.sourceWorkflow,
      plan.targetWorkflow.moduleVersionId
    );
    const rolledBack = plan.targetWorkflow.upgrade(
      run,
      rollbackWorkflow,
      normalizeHotSwapWorkflowUpgradeOptions(workflowOptions, "hotSwap.rollback")
    );
    const normalizedTrigger =
      trigger === null
        ? null
        : normalizeHotSwapRollbackTrigger(trigger, "hotSwap.rollback.trigger");

    return Object.freeze({
      status: "rolled_back",
      workflowName: plan.name,
      supervisor: rolledBack.run.supervision.supervisor,
      sourceVersionId: sourceModule.versionId,
      targetVersionId: targetModule.versionId,
      rollbackVersionId: sourceModule.versionId,
      rollbackTargetVersionId: targetModule.versionId,
      rollbackAvailable: false,
      run: rolledBack.run,
      migration: rolledBack.migration,
      context: rolledBack.context,
      handlers: rolledBack.handlers,
      trigger: normalizedTrigger
    });
  }
}

function normalizeHotSwapUpgradeWindow(module) {
  const upgradeWindow = module?.upgradeWindow;

  if (!upgradeWindow || typeof upgradeWindow !== "object") {
    throw new Error(`Module ${String(module?.name ?? "unknown")} is missing an upgrade window.`);
  }

  if (upgradeWindow.policy !== "bounded-overlap") {
    throw new Error(
      `Module ${String(module?.name ?? "unknown")} must use bounded-overlap hot swaps.`
    );
  }

  const fromVersionIds = Array.isArray(upgradeWindow.fromVersionIds)
    ? upgradeWindow.fromVersionIds.filter(
        (versionId) => typeof versionId === "string" && versionId !== ""
      )
    : [];

  if (fromVersionIds.length === 0) {
    throw new Error(
      `Module ${String(module?.name ?? "unknown")} must declare at least one compatible source version.`
    );
  }

  if (typeof upgradeWindow.toVersionId !== "string" || upgradeWindow.toVersionId === "") {
    throw new Error(
      `Module ${String(module?.name ?? "unknown")} is missing upgradeWindow.toVersionId.`
    );
  }

  return Object.freeze({
    policy: upgradeWindow.policy,
    fromVersionIds: Object.freeze([...new Set(fromVersionIds)]),
    toVersionId: upgradeWindow.toVersionId
  });
}

function normalizeHotSwapLabel(value, path) {
  if (value === undefined || value === null) {
    return null;
  }

  if (typeof value !== "string" || value === "") {
    throw new Error(`${path} must be a non-empty string.`);
  }

  return value;
}

function normalizeHotSwapTimestamp(value, path) {
  if (value === undefined || value === null) {
    return null;
  }

  if (!Number.isInteger(value) || value < 0) {
    throw new Error(`${path} must be a non-negative integer.`);
  }

  return value;
}

function patchRollbackWorkflowCompatibility(workflow, acceptedModuleVersionId) {
  const compatibleModuleVersionIds = Array.isArray(
    workflow?.compatibility?.compatibleModuleVersionIds
  )
    ? workflow.compatibility.compatibleModuleVersionIds.filter(
        (versionId) => typeof versionId === "string" && versionId !== ""
      )
    : [];

  return Object.freeze({
    ...workflow,
    compatibility: Object.freeze({
      ...(workflow?.compatibility ?? {}),
      compatibleModuleVersionIds: Object.freeze([
        ...new Set([...compatibleModuleVersionIds, acceptedModuleVersionId])
      ])
    })
  });
}

function normalizeHotSwapWorkflowUpgradeOptions(options, path) {
  const rawOptions = options && typeof options === "object" ? options : {};
  const normalized = {};

  if (rawOptions.migrateState !== undefined && rawOptions.migrateState !== null) {
    if (typeof rawOptions.migrateState !== "function") {
      throw new Error(`${path}.migrateState must be a function.`);
    }

    normalized.migrateState = rawOptions.migrateState;
  }

  if (rawOptions.prepare !== undefined && rawOptions.prepare !== null) {
    if (typeof rawOptions.prepare !== "function") {
      throw new Error(`${path}.prepare must be a function.`);
    }

    normalized.prepare = rawOptions.prepare;
  }

  if (rawOptions.activate !== undefined && rawOptions.activate !== null) {
    if (typeof rawOptions.activate !== "function") {
      throw new Error(`${path}.activate must be a function.`);
    }

    normalized.activate = rawOptions.activate;
  }

  return normalized;
}

function normalizeHotSwapActivationOptions(options, path) {
  const rawOptions = options && typeof options === "object" ? options : {};
  const normalized = {
    upgrade: normalizeHotSwapWorkflowUpgradeOptions(rawOptions, path),
    healthCheck: null,
    rollbackOnFail:
      rawOptions.rollbackOnFail === undefined ? true : rawOptions.rollbackOnFail,
    rollback: {},
    rollbackTrigger: Object.freeze({
      kind: "health_check_failed",
      reason: "health_check_failed",
      at: null
    })
  };

  if (
    rawOptions.healthCheck !== undefined &&
    rawOptions.healthCheck !== null &&
    typeof rawOptions.healthCheck !== "function"
  ) {
    throw new Error(`${path}.healthCheck must be a function.`);
  }

  if (typeof normalized.rollbackOnFail !== "boolean") {
    throw new Error(`${path}.rollbackOnFail must be a boolean.`);
  }

  if (
    rawOptions.rollback !== undefined &&
    rawOptions.rollback !== null &&
    typeof rawOptions.rollback !== "object"
  ) {
    throw new Error(`${path}.rollback must be an object.`);
  }

  if (rawOptions.rollbackTrigger !== undefined && rawOptions.rollbackTrigger !== null) {
    normalized.rollbackTrigger = normalizeHotSwapRollbackTrigger(
      rawOptions.rollbackTrigger,
      `${path}.rollbackTrigger`
    );
  }

  normalized.healthCheck = rawOptions.healthCheck ?? null;
  normalized.rollback = rawOptions.rollback ?? {};
  return Object.freeze(normalized);
}

function evaluateHotSwapHealthCheck(healthCheck, run, context, path) {
  if (healthCheck === null) {
    return Object.freeze({
      healthy: true,
      status: "healthy",
      reason: null,
      details: null
    });
  }

  return normalizeHotSwapHealthReport(healthCheck(run, context), path);
}

function normalizeHotSwapHealthReport(value, path) {
  if (typeof value === "boolean") {
    return Object.freeze({
      healthy: value,
      status: value ? "healthy" : "unhealthy",
      reason: value ? null : "health_check_failed",
      details: null
    });
  }

  if (!value || typeof value !== "object") {
    throw new Error(`${path} must return a boolean or object.`);
  }

  if (typeof value.healthy !== "boolean") {
    throw new Error(`${path}.healthy must be a boolean.`);
  }

  const status =
    value.status === undefined || value.status === null
      ? value.healthy
        ? "healthy"
        : "unhealthy"
      : normalizeHotSwapLabel(value.status, `${path}.status`);
  const reason =
    value.reason === undefined || value.reason === null
      ? value.healthy
        ? null
        : status
      : normalizeHotSwapLabel(value.reason, `${path}.reason`);

  return Object.freeze({
    healthy: value.healthy,
    status,
    reason,
    details: value.details ?? null
  });
}

function normalizeHotSwapRollbackTrigger(trigger, path) {
  if (typeof trigger === "string") {
    const kind = normalizeHotSwapLabel(trigger, `${path}.kind`);
    return Object.freeze({
      kind,
      reason: kind,
      at: null
    });
  }

  if (!trigger || typeof trigger !== "object") {
    throw new Error(`${path} must be a string or object.`);
  }

  const kind = normalizeHotSwapLabel(trigger.kind, `${path}.kind`);
  const reason =
    trigger.reason === undefined || trigger.reason === null
      ? kind
      : normalizeHotSwapLabel(trigger.reason, `${path}.reason`);

  return Object.freeze({
    kind,
    reason,
    at: normalizeHotSwapTimestamp(trigger.at, `${path}.at`)
  });
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
    hotSwap(targetCompiledModule, hotSwapOptions = {}) {
      return createModuleHotSwapProtocol(
        compiledModule,
        targetCompiledModule,
        hotSwapOptions
      );
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
