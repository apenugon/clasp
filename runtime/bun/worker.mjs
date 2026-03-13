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
      routes: contract.routes ?? compiledModule?.__claspRoutes ?? [],
      routeClients: contract.routeClients ?? compiledModule?.__claspRouteClients ?? [],
      seededFixtures: contract.seededFixtures ?? compiledModule?.__claspSeededFixtures ?? [],
      controlPlane: contract.controlPlane ?? compiledModule?.__claspControlPlane ?? null,
      controlPlaneDocs:
        contract.controlPlaneDocs ?? compiledModule?.__claspControlPlaneDocs ?? null,
      nativeInterop:
        contract.nativeInterop ??
        compiledModule?.__claspNativeInterop ??
        defaultNativeInterop(compiledModule?.__claspHostBindings ?? []),
      evalHooks: contract.evalHooks ?? compiledModule?.__claspEvalHooks ?? null,
      traces: contract.traces ?? compiledModule?.__claspTraceCollector ?? null
    };
  }

  return {
    kind: "clasp-generated-bindings",
    version: 1,
    module: compiledModule?.__claspModule ?? null,
    routes: compiledModule?.__claspRoutes ?? [],
    routeClients: compiledModule?.__claspRouteClients ?? [],
    schemas: compiledModule?.__claspSchemas ?? {},
    seededFixtures: compiledModule?.__claspSeededFixtures ?? [],
    controlPlane: compiledModule?.__claspControlPlane ?? null,
    controlPlaneDocs: compiledModule?.__claspControlPlaneDocs ?? null,
    nativeInterop:
      compiledModule?.__claspNativeInterop ??
      defaultNativeInterop(compiledModule?.__claspHostBindings ?? []),
    evalHooks: compiledModule?.__claspEvalHooks ?? null,
    traces: compiledModule?.__claspTraceCollector ?? null
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

export function createDynamicSchema(compiledModule, typeNames) {
  const normalizedTypeNames = normalizeDynamicSchemaTypeNames(typeNames);
  const entries = normalizedTypeNames.map((typeName) => [
    typeName,
    schemaContractFor(compiledModule, typeName)
  ]);
  const schemaMap = new Map(entries);
  const schemas = Object.freeze(
    Object.fromEntries(entries.map(([typeName, contract]) => [typeName, contract.schema ?? null]))
  );
  const seeds = Object.freeze(
    Object.fromEntries(entries.map(([typeName, contract]) => [typeName, contract.seed ?? null]))
  );

  return Object.freeze({
    kind: "clasp-dynamic-schema",
    version: 1,
    schemaNames: Object.freeze(normalizedTypeNames),
    schemas,
    seeds,
    schema(typeName) {
      const contract = schemaMap.get(typeName);

      if (!contract) {
        throw new Error(
          `Dynamic schema does not allow ${String(typeName)}. Expected one of: ${normalizedTypeNames.join(", ")}`
        );
      }

      return contract;
    },
    match(value, path = "value") {
      return selectDynamicSchemaMatch(entries, value, path);
    },
    select(value, path = "value") {
      return this.match(value, path);
    },
    decodeJson(jsonText, path = "value") {
      return selectDynamicSchemaDecode(entries, jsonText, path).value;
    },
    selectJson(jsonText, path = "value") {
      return selectDynamicSchemaDecode(entries, jsonText, path);
    },
    encodeJson(value, path = "value") {
      const selection = this.match(value, path);
      return selection.schema.encodeJson(selection.value);
    }
  });
}

function normalizeDynamicSchemaTypeNames(typeNames) {
  if (!Array.isArray(typeNames) || typeNames.length === 0) {
    throw new Error("Dynamic schemas require a non-empty array of schema names.");
  }

  const normalized = [];
  const seen = new Set();

  for (const typeName of typeNames) {
    if (typeof typeName !== "string" || typeName === "") {
      throw new Error("Dynamic schemas require schema names to be non-empty strings.");
    }

    if (!seen.has(typeName)) {
      normalized.push(typeName);
      seen.add(typeName);
    }
  }

  return normalized;
}

function selectDynamicSchemaMatch(entries, value, path) {
  const matches = [];

  for (const [typeName, contract] of entries) {
    try {
      const matchedValue = contract.toHost(contract.fromHost(value, path), path);
      matches.push(
        Object.freeze({
          typeName,
          schema: contract,
          value: matchedValue
        })
      );
    } catch (_error) {
      // Try the remaining constrained schema candidates.
    }
  }

  return expectDynamicSchemaSelection(entries, matches, path);
}

function selectDynamicSchemaDecode(entries, jsonText, path) {
  const matches = [];

  for (const [typeName, contract] of entries) {
    try {
      matches.push(
        Object.freeze({
          typeName,
          schema: contract,
          value: contract.decodeJson(jsonText)
        })
      );
    } catch (_error) {
      // Try the remaining constrained schema candidates.
    }
  }

  return expectDynamicSchemaSelection(entries, matches, path);
}

function expectDynamicSchemaSelection(entries, matches, path) {
  if (matches.length === 1) {
    return matches[0];
  }

  const typeNames = entries.map(([typeName]) => typeName).join(", ");

  if (matches.length === 0) {
    throw new Error(`${path} did not match any dynamic schema candidate: ${typeNames}`);
  }

  throw new Error(
    `${path} matched multiple dynamic schema candidates: ${matches.map((match) => match.typeName).join(", ")}`
  );
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
        trigger: rolledBack.trigger,
        audit: rolledBack.audit
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
    const audit = Object.freeze({
      eventType: "rollback",
      workflowName: plan.name,
      sourceVersionId: sourceModule.versionId,
      targetVersionId: targetModule.versionId,
      trigger: normalizedTrigger
    });
    const runWithAudit = appendWorkflowAudit(rolledBack.run, audit);

    return Object.freeze({
      status: "rolled_back",
      workflowName: plan.name,
      supervisor: runWithAudit.supervision.supervisor,
      sourceVersionId: sourceModule.versionId,
      targetVersionId: targetModule.versionId,
      rollbackVersionId: sourceModule.versionId,
      rollbackTargetVersionId: targetModule.versionId,
      rollbackAvailable: false,
      run: runWithAudit,
      migration: rolledBack.migration,
      context: rolledBack.context,
      handlers: rolledBack.handlers,
      trigger: normalizedTrigger,
      audit
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

function appendWorkflowAudit(run, auditEntry) {
  const auditLog = Array.isArray(run?.auditLog) ? run.auditLog : [];

  return Object.freeze({
    ...run,
    auditLog: Object.freeze([...auditLog, Object.freeze(auditEntry)])
  });
}

function freezeSimulationValue(value) {
  if (value === null || value === undefined) {
    return value ?? null;
  }

  if (Array.isArray(value)) {
    return Object.freeze(value.map((entry) => freezeSimulationValue(entry)));
  }

  if (typeof value !== "object") {
    return value;
  }

  const normalized = {};

  for (const [key, entry] of Object.entries(value)) {
    normalized[key] = freezeSimulationValue(entry);
  }

  return Object.freeze(normalized);
}

function normalizeSimulationTimestamp(value, path) {
  if (!Number.isInteger(value) || value < 0) {
    throw new Error(`${path} must be a non-negative integer.`);
  }

  return value;
}

function createSimulationClock(seedNow = 0) {
  let currentNow = normalizeSimulationTimestamp(seedNow, "simulation.clock.seedNow");

  return Object.freeze({
    kind: "clasp-simulation-clock",
    now() {
      return currentNow;
    },
    set(now) {
      currentNow = normalizeSimulationTimestamp(now, "simulation.clock.set");
      return currentNow;
    },
    advanceBy(deltaMs) {
      if (!Number.isInteger(deltaMs) || deltaMs < 0) {
        throw new Error("simulation.clock.advanceBy must be a non-negative integer.");
      }

      currentNow += deltaMs;
      return currentNow;
    }
  });
}

function resolveSimulationNow(clock, value, path) {
  if (value === undefined || value === null) {
    return clock.now();
  }

  return normalizeSimulationTimestamp(value, path);
}

function normalizeSimulationFixtureSnapshot(fixtures) {
  return freezeSimulationValue(
    Object.fromEntries(
      (Array.isArray(fixtures) ? fixtures : [])
        .filter((fixture) => fixture && typeof fixture === "object")
        .map((fixture, index) => [
          fixture.routeName ?? fixture.routeId ?? `fixture-${index + 1}`,
          {
            routeName: fixture.routeName ?? null,
            routeId: fixture.routeId ?? null,
            requestType: fixture.requestType ?? null,
            responseType: fixture.responseType ?? null,
            responseKind: fixture.responseKind ?? null,
            requestSeed: fixture.requestSeed ?? null,
            responseSeed: fixture.responseSeed ?? null
          }
        ])
    )
  );
}

function normalizeSimulationWorldState(state, defaults = {}) {
  const rawState = state && typeof state === "object" ? state : {};

  return freezeSimulationValue({
    fixtures:
      rawState.fixtures === undefined
        ? defaults.fixtures ?? freezeSimulationValue({})
        : rawState.fixtures,
    storage:
      rawState.storage === undefined
        ? defaults.storage ?? freezeSimulationValue({})
        : rawState.storage,
    environment:
      rawState.environment === undefined
        ? defaults.environment ?? freezeSimulationValue({})
        : rawState.environment,
    deployment:
      rawState.deployment === undefined
        ? defaults.deployment ?? freezeSimulationValue({})
        : rawState.deployment,
    providerResponses:
      rawState.providerResponses === undefined
        ? defaults.providerResponses ?? freezeSimulationValue({})
        : rawState.providerResponses
  });
}

function workflowTemporalOperation(workflow, operation) {
  const temporal = workflow?.temporal;
  const handler = temporal?.[operation];

  if (typeof handler !== "function") {
    throw new Error(
      `Workflow ${String(workflow?.name ?? "unknown")} does not expose temporal.${operation}.`
    );
  }

  return handler.bind(temporal);
}

export function createSimulationRuntime(compiledModule, options = {}) {
  const contract = bindingContractFor(compiledModule);
  const moduleContract = contract.module ?? null;
  const simulationClock =
    options.clock && typeof options.clock.now === "function"
      ? options.clock
      : createSimulationClock(options.now ?? 0);
  const traceId =
    options.traceId === undefined || options.traceId === null
      ? "simulation"
      : normalizeHotSwapLabel(options.traceId, "simulation.traceId");
  const routeMap = new Map(
    (contract.routes ?? []).map((route) => [route?.name, route])
  );
  const fixtureMap = new Map(
    (contract.seededFixtures ?? []).map((fixture) => [fixture?.routeName, fixture])
  );
  const workflows = Array.isArray(compiledModule?.__claspWorkflows)
    ? compiledModule.__claspWorkflows
    : [];
  const workflowMap = new Map(workflows.map((workflow) => [workflow?.name, workflow]));
  const controlPlane =
    contract.controlPlane ??
    (compiledModule?.__claspControlPlane && typeof compiledModule.__claspControlPlane === "object"
      ? compiledModule.__claspControlPlane
      : null);
  const policyMap = new Map(
    ((controlPlane?.policies ?? compiledModule?.__claspPolicies ?? [])).map((policy) => [
      policy?.name,
      policy
    ])
  );
  const agentMap = new Map(
    ((controlPlane?.agents ?? compiledModule?.__claspAgents ?? [])).map((agent) => [
      agent?.name,
      agent
    ])
  );
  const baseWorldState = normalizeSimulationWorldState(options, {
    fixtures: normalizeSimulationFixtureSnapshot(contract.seededFixtures ?? []),
    storage: freezeSimulationValue({}),
    environment: freezeSimulationValue({}),
    deployment: freezeSimulationValue({}),
    providerResponses: freezeSimulationValue({})
  });
  const traces = [];
  const audits = [];

  return Object.freeze({
    kind: "clasp-simulation-runtime",
    version: 1,
    traceId,
    contract,
    clock: simulationClock,
    worldSnapshot(snapshotOptions = {}) {
      return captureWorldSnapshot(null, snapshotOptions);
    },
    temporal: Object.freeze({
      clock(seedNow = simulationClock.now()) {
        return createSimulationClock(seedNow);
      },
      deadline(workflowName, spec, temporalOptions = {}) {
        return runTemporalOperation(workflowName, "deadline", spec, temporalOptions);
      },
      ttl(workflowName, spec, temporalOptions = {}) {
        return runTemporalOperation(workflowName, "ttl", spec, temporalOptions);
      },
      expiration(workflowName, spec, temporalOptions = {}) {
        return runTemporalOperation(workflowName, "expiration", spec, temporalOptions);
      },
      schedule(workflowName, spec, temporalOptions = {}) {
        return runTemporalOperation(workflowName, "schedule", spec, temporalOptions);
      },
      rollout(workflowName, spec, temporalOptions = {}) {
        return runTemporalOperation(workflowName, "rollout", spec, temporalOptions);
      },
      cache(workflowName, spec, temporalOptions = {}) {
        return runTemporalOperation(workflowName, "cache", spec, temporalOptions);
      },
      capability(workflowName, spec, temporalOptions = {}) {
        return runTemporalOperation(workflowName, "capability", spec, temporalOptions);
      }
    }),
    route(name) {
      const route = routeMap.get(name);

      if (!route) {
        throw new Error(`Missing Clasp simulation route: ${name}`);
      }

      const fixture = fixtureMap.get(name) ?? null;

      return Object.freeze({
        route,
        fixture,
        dryRun(input = {}, dryRunOptions = {}) {
          const now = resolveSimulationNow(
            simulationClock,
            dryRunOptions.now,
            "simulation.route.dryRun.now"
          );
          const requestSeed =
            input.request ?? input.requestSeed ?? fixture?.requestSeed ?? null;
          const responseSeed =
            input.response ?? input.responseSeed ?? fixture?.responseSeed ?? null;
          const request =
            requestSeed === null ? null : route.decodeRequest(JSON.stringify(requestSeed));
          const response =
            route.responseKind === "json" && responseSeed !== null
              ? schemaContractFor(compiledModule, route.responseType).toHost(
                  schemaContractFor(compiledModule, route.responseType).fromHost(
                    responseSeed,
                    "response"
                  ),
                  "response"
                )
              : freezeSimulationValue(responseSeed);
          const worldSnapshot = captureWorldSnapshot(
            freezeSimulationValue({
              kind: "route",
              routeName: route.name,
              routeId: route.id,
              fixtureRouteId: fixture?.routeId ?? null,
              requestSeed,
              responseSeed
            }),
            {
              now,
              fixtures: freezeSimulationValue({
                ...baseWorldState.fixtures,
                [route.name]: {
                  routeName: route.name,
                  routeId: route.id,
                  requestType: route.requestType,
                  responseType: route.responseType,
                  responseKind: route.responseKind,
                  requestSeed,
                  responseSeed
                }
              }),
              ...(dryRunOptions.worldSnapshot ?? {})
            }
          );
          const trace = freezeSimulationValue({
            kind: "route",
            mode: "dry_run",
            traceId,
            at: now,
            routeName: route.name,
            routeId: route.id,
            request,
            response,
            worldSnapshot,
            fixture: fixture
              ? {
                  routeName: fixture.routeName,
                  routeId: fixture.routeId
                }
              : null
          });
          const audit = freezeSimulationValue({
            eventType: "route_dry_run",
            traceId,
            routeName: route.name,
            routeId: route.id,
            simulatedAt: now,
            requestType: route.requestType,
            responseType: route.responseType,
            responseKind: route.responseKind,
            fixtureUsed: fixture?.routeId ?? null
          });
          appendSimulationRecord(trace, audit);

          return freezeSimulationValue({
            status: "dry_run",
            routeName: route.name,
            routeId: route.id,
            request,
            response,
            worldSnapshot,
            trace,
            audit
          });
        }
      });
    },
    workflow(name) {
      const workflow = workflowMap.get(name);

      if (!workflow) {
        throw new Error(`Missing Clasp simulation workflow: ${name}`);
      }

      return Object.freeze({
        workflow,
        dryRun(input = {}, reducer, dryRunOptions = {}) {
          if (typeof reducer !== "function") {
            throw new Error(`simulation.workflow(${name}).dryRun requires a reducer function.`);
          }

          const now = resolveSimulationNow(
            simulationClock,
            dryRunOptions.now,
            "simulation.workflow.dryRun.now"
          );
          const snapshot =
            typeof input.snapshot === "string"
              ? input.snapshot
              : workflow.checkpoint(
                  input.state ??
                    schemaContractFor(compiledModule, workflow.stateType).seed
                );
          const messages = Array.isArray(input.messages) ? input.messages : [];
          const replayOptions =
            dryRunOptions.clock && typeof dryRunOptions.clock.now === "function"
              ? { ...dryRunOptions, clock: dryRunOptions.clock }
              : { ...dryRunOptions, now };
          const run = workflow.replay(snapshot, messages, reducer, replayOptions);
          const worldSnapshot = captureWorldSnapshot(
            freezeSimulationValue({
              kind: "workflow",
              workflowName: workflow.name,
              workflowId: workflow.id,
              snapshot,
              messages
            }),
            {
              now,
              ...(dryRunOptions.worldSnapshot ?? {})
            }
          );
          const trace = freezeSimulationValue({
            kind: "workflow",
            mode: "dry_run",
            traceId,
            at: now,
            workflowName: workflow.name,
            workflowId: workflow.id,
            delivered: run.deliveries.length,
            processedIds: run.processedIds,
            worldSnapshot
          });
          const audit = freezeSimulationValue({
            eventType: "workflow_dry_run",
            traceId,
            workflowName: workflow.name,
            workflowId: workflow.id,
            simulatedAt: now,
            delivered: run.deliveries.length,
            auditEntries: run.auditLog.length
          });
          appendSimulationRecord(trace, audit);

          return freezeSimulationValue({
            status: "dry_run",
            workflowName: workflow.name,
            run,
            worldSnapshot,
            trace,
            audit
          });
        }
      });
    },
    policy(name) {
      const policy = policyMap.get(name);

      if (!policy) {
        throw new Error(`Missing Clasp simulation policy: ${name}`);
      }

      return Object.freeze({
        policy,
        decide(kind, target, context = null) {
          const decision = policy.decide(kind, target, context);
          const worldSnapshot = captureWorldSnapshot(
            freezeSimulationValue({
              kind: "policy",
              policyName: policy.name,
              targetKind: kind,
              target,
              context
            })
          );
          appendSimulationRecord(
            freezeSimulationValue({
              kind: "policy",
              mode: "dry_run",
              traceId,
              at: simulationClock.now(),
              policyName: policy.name,
              decision: decision.trace,
              worldSnapshot
            }),
            freezeSimulationValue({
              eventType: "policy_dry_run",
              traceId,
              policyName: policy.name,
              decision: decision.audit
            })
          );
          return freezeSimulationValue({
            ...decision,
            worldSnapshot
          });
        }
      });
    },
    agent(name) {
      const agent = agentMap.get(name);

      if (!agent) {
        throw new Error(`Missing Clasp simulation agent: ${name}`);
      }

      if (!agent.policy || typeof agent.policy.decide !== "function") {
        throw new Error(`Agent ${name} is missing a usable policy.`);
      }

      return Object.freeze({
        agent,
        dryRun(loopFixture = {}, dryRunOptions = {}) {
          const now = resolveSimulationNow(
            simulationClock,
            dryRunOptions.now,
            "simulation.agent.dryRun.now"
          );
          const steps = Array.isArray(loopFixture.steps) ? loopFixture.steps : [];
          const results = steps.map((step, index) => {
            const stepName =
              step?.step && typeof step.step === "string" && step.step !== ""
                ? step.step
                : `step-${index + 1}`;
            const kind =
              step?.kind && typeof step.kind === "string" && step.kind !== ""
                ? step.kind
                : "process";
            const target =
              step?.target && typeof step.target === "string" && step.target !== ""
                ? step.target
                : "";
            const decision = agent.policy.decide(kind, target, step?.context ?? null);

            return freezeSimulationValue({
              step: stepName,
              kind,
              target,
              allowed: decision.allowed,
              request: step?.request ?? null,
              result: step?.result ?? null,
              trace: decision.trace,
              audit: decision.audit
            });
          });
          const worldSnapshot = captureWorldSnapshot(
            freezeSimulationValue({
              kind: "agent_loop",
              agentName: agent.name,
              steps: results.map((result) => ({
                step: result.step,
                kind: result.kind,
                target: result.target,
                allowed: result.allowed
              }))
            }),
            {
              now,
              ...(dryRunOptions.worldSnapshot ?? {})
            }
          );
          const trace = freezeSimulationValue({
            kind: "agent_loop",
            mode: "dry_run",
            traceId,
            at: now,
            agentName: agent.name,
            approvalPolicy: agent.role?.approvalPolicy ?? null,
            sandboxPolicy: agent.role?.sandboxPolicy ?? null,
            worldSnapshot,
            steps: results.map((result) => ({
              step: result.step,
              allowed: result.allowed
            }))
          });
          const audit = freezeSimulationValue({
            eventType: "agent_loop_dry_run",
            traceId,
            agentName: agent.name,
            simulatedAt: now,
            stepCount: results.length,
            deniedSteps: results.filter((result) => !result.allowed).length
          });
          appendSimulationRecord(trace, audit);

          return freezeSimulationValue({
            status: "dry_run",
            agentName: agent.name,
            approvalPolicy: agent.role?.approvalPolicy ?? null,
            sandboxPolicy: agent.role?.sandboxPolicy ?? null,
            steps: results,
            worldSnapshot,
            trace,
            audit
          });
        }
      });
    },
    traces() {
      return freezeSimulationValue(traces);
    },
    audits() {
      return freezeSimulationValue(audits);
    }
  });

  function appendSimulationRecord(trace, audit) {
    traces.push(trace);
    audits.push(audit);
  }

  function runTemporalOperation(workflowName, operation, spec, temporalOptions = {}) {
    const workflow = workflowMap.get(workflowName);

    if (!workflow) {
      throw new Error(`Missing Clasp simulation workflow: ${workflowName}`);
    }

    const temporalClock =
      temporalOptions.clock && typeof temporalOptions.clock.now === "function"
        ? temporalOptions.clock
        : simulationClock;
    const now = resolveSimulationNow(
      temporalClock,
      temporalOptions.now,
      `simulation.temporal.${operation}.now`
    );
    const result = workflowTemporalOperation(workflow, operation)(spec, {
      ...temporalOptions,
      now,
      clock: temporalClock
    });
    const worldSnapshot = captureWorldSnapshot(
      freezeSimulationValue({
        kind: "temporal",
        workflowName,
        operation,
        spec
      }),
      {
        now,
        ...(temporalOptions.worldSnapshot ?? {})
      }
    );
    const trace = freezeSimulationValue({
      kind: "temporal",
      mode: "dry_run",
      traceId,
      at: now,
      workflowName,
      operation,
      spec,
      result,
      worldSnapshot
    });
    const audit = freezeSimulationValue({
      eventType: "temporal_dry_run",
      traceId,
      workflowName,
      operation,
      simulatedAt: now,
      status: result?.status ?? null
    });
    appendSimulationRecord(trace, audit);
    return freezeSimulationValue({
      ...result,
      worldSnapshot
    });
  }

  function captureWorldSnapshot(surface = null, snapshotOptions = {}) {
    const snapshotClock =
      snapshotOptions.clock && typeof snapshotOptions.clock.now === "function"
        ? snapshotOptions.clock
        : simulationClock;
    const capturedAt = resolveSimulationNow(
      snapshotClock,
      snapshotOptions.now,
      "simulation.worldSnapshot.now"
    );
    const worldState = normalizeSimulationWorldState(snapshotOptions, baseWorldState);

    return freezeSimulationValue({
      kind: "clasp-world-snapshot",
      version: 1,
      traceId,
      module: moduleContract
        ? {
            name: moduleContract.name ?? null,
            versionId: moduleContract.versionId ?? null
          }
        : null,
      capturedAt,
      time: {
        simulated: true,
        now: capturedAt,
        clockKind: snapshotClock.kind ?? "custom"
      },
      fixtures: worldState.fixtures,
      storage: worldState.storage,
      environment: worldState.environment,
      deployment: worldState.deployment,
      providerResponses: worldState.providerResponses,
      surface
    });
  }
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
  const output = normalizeWorkerOutputContract(compiledModule, outputType);

  return Object.freeze({
    kind: "clasp-worker-job",
    version: 1,
    name,
    inputType,
    inputSchema: input.schema ?? null,
    inputSeed: input.seed ?? null,
    outputType: output.typeName,
    outputTypes: output.typeNames,
    outputSchema: output.schema,
    outputSchemas: output.schemas,
    outputSeed: output.seed,
    outputSeeds: output.seeds,
    decodeInput(jsonText) {
      return input.decodeJson(jsonText);
    },
    encodeInput(value) {
      return input.encodeJson(value);
    },
    decodeOutput(jsonText) {
      return output.decodeJson(jsonText, "result");
    },
    encodeOutput(value) {
      return output.encodeJson(value, "result");
    },
    async run(value, context = {}) {
      const preparedInput = input.toHost(input.fromHost(value, "value"), "value");
      const result = await handler(preparedInput, context);
      return output.validate(result, "result");
    },
    async dispatch(jsonText, context = {}) {
      const result = await this.run(this.decodeInput(jsonText), context);
      return this.encodeOutput(result);
    }
  });
}

function normalizeWorkerOutputContract(compiledModule, outputType) {
  if (typeof outputType === "string") {
    const contract = schemaContractFor(compiledModule, outputType);

    return Object.freeze({
      typeName: outputType,
      typeNames: Object.freeze([outputType]),
      schema: contract.schema ?? null,
      schemas: Object.freeze({ [outputType]: contract.schema ?? null }),
      seed: contract.seed ?? null,
      seeds: Object.freeze({ [outputType]: contract.seed ?? null }),
      validate(value, path = "result") {
        return contract.toHost(contract.fromHost(value, path), path);
      },
      decodeJson(jsonText) {
        return contract.decodeJson(jsonText);
      },
      encodeJson(value, path = "result") {
        return contract.encodeJson(this.validate(value, path));
      }
    });
  }

  if (outputType?.kind === "clasp-dynamic-schema") {
    return Object.freeze({
      typeName: null,
      typeNames: outputType.schemaNames,
      schema: null,
      schemas: outputType.schemas,
      seed: null,
      seeds: outputType.seeds,
      validate(value, path = "result") {
        return outputType.match(value, path).value;
      },
      decodeJson(jsonText, path = "result") {
        return outputType.decodeJson(jsonText, path);
      },
      encodeJson(value, path = "result") {
        return outputType.encodeJson(value, path);
      }
    });
  }

  throw new Error(
    "Worker jobs require outputType to be a schema name or a dynamic schema."
  );
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
    dynamicSchema(typeNames) {
      return createDynamicSchema(compiledModule, typeNames);
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
    simulation(simulationOptions = {}) {
      return createSimulationRuntime(compiledModule, simulationOptions);
    },
    simulate(simulationOptions = {}) {
      return createSimulationRuntime(compiledModule, simulationOptions);
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
