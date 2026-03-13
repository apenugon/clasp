import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

async function loadWorkerRuntime() {
  const projectRoot = process.env.CLASP_PROJECT_ROOT;

  if (!projectRoot) {
    throw new Error("CLASP_PROJECT_ROOT is required");
  }

  return import(pathToFileURL(path.join(projectRoot, "runtime/bun/worker.mjs")).href);
}

function patchTargetCompiledModule(sourceCompiledModule, targetCompiledModule) {
  const sourceVersionId = sourceCompiledModule.__claspModule.versionId;
  const patchedTargetModule = Object.freeze({
    ...targetCompiledModule.__claspModule,
    upgradeWindow: Object.freeze({
      ...targetCompiledModule.__claspModule.upgradeWindow,
      fromVersionIds: Object.freeze([
        ...new Set([
          ...(targetCompiledModule.__claspModule.upgradeWindow.fromVersionIds ?? []),
          sourceVersionId
        ])
      ])
    })
  });
  const patchedTargetWorkflows = Object.freeze(
    (targetCompiledModule.__claspWorkflows ?? []).map((workflow) =>
      Object.freeze({
        ...workflow,
        compatibility: Object.freeze({
          ...workflow.compatibility,
          compatibleModuleVersionIds: Object.freeze([
            ...new Set([
              ...(workflow.compatibility?.compatibleModuleVersionIds ?? []),
              sourceVersionId
            ])
          ])
        })
      })
    )
  );
  const patchedTargetBindings = Object.freeze({
    ...(targetCompiledModule.__claspBindings ?? {}),
    module: patchedTargetModule
  });

  return Object.freeze({
    ...targetCompiledModule,
    __claspModule: patchedTargetModule,
    __claspWorkflows: patchedTargetWorkflows,
    __claspBindings: patchedTargetBindings
  });
}

export async function runDurableWorkflowDemo(
  sourceCompiledModulePath,
  targetCompiledModulePath,
  stateDirectory = path.resolve("state")
) {
  const [{ createWorkerRuntime }, sourceCompiledModule, targetCompiledModule] = await Promise.all([
    loadWorkerRuntime(),
    import(pathToFileURL(path.resolve(sourceCompiledModulePath)).href),
    import(pathToFileURL(path.resolve(targetCompiledModulePath)).href)
  ]);
  const patchedTargetCompiledModule = patchTargetCompiledModule(
    sourceCompiledModule,
    targetCompiledModule
  );
  const runtime = createWorkerRuntime(sourceCompiledModule);
  const protocol = runtime.hotSwap(patchedTargetCompiledModule, {
    supervisor: "UpgradeSupervisor"
  });
  const workflow = runtime.workflow("CounterFlow");
  const baseRun = workflow.start(workflow.checkpoint({ count: 5 }), { deadlineAt: 100 });
  const statePath = path.join(path.resolve(stateDirectory), "counter-run.json");

  await fs.mkdir(path.dirname(statePath), { recursive: true });
  await fs.writeFile(statePath, JSON.stringify(baseRun, null, 2) + "\n", "utf8");

  const persistedRun = JSON.parse(await fs.readFile(statePath, "utf8"));
  const handoff = protocol.handoff(
    "CounterFlow",
    persistedRun,
    "release-bot",
    "self-update",
    { updatedAt: 1001 }
  );
  const draining = protocol.drain("CounterFlow", handoff.run, { updatedAt: 1002 });
  const activated = protocol.activate("CounterFlow", draining.run, {
    migrateState: (state) => ({ count: state.count + 3 }),
    activate: (nextRun) => ({
      ...nextRun,
      supervision: {
        ...nextRun.supervision,
        supervisor: "UpgradeSupervisor"
      }
    }),
    healthCheck: (nextRun, meta) => ({
      healthy: nextRun.state.count === 8 && meta.targetVersionId.startsWith("module:Main:"),
      status: "healthy"
    })
  });
  const retired = protocol.retire({ retiredAt: 1006, reason: "drained" });

  return {
    statePath,
    handoffStatus: handoff.status,
    handoffOperator: handoff.run.supervision.operator,
    drainingStatus: draining.status,
    drainingVersionTagged: draining.drainingVersionId.startsWith("module:Main:"),
    activatedStatus: activated.status,
    activatedHealthStatus: activated.health.status,
    activatedRollbackAvailable: activated.rollbackAvailable,
    activatedCount: activated.run.state.count,
    activatedTargetTagged: activated.targetVersionId.startsWith("module:Main:"),
    overlapStatus: null,
    overlapStartedAt: null,
    blockedStatus: null,
    blockedHealthStatus: null,
    blockedRollbackAvailable: false,
    blockedCount: null,
    autoRollbackStatus: null,
    autoRollbackTriggerKind: null,
    autoRollbackTriggerReason: null,
    autoRollbackTriggerAt: null,
    autoRollbackCount: null,
    manualRollbackStatus: null,
    manualRollbackTriggerKind: null,
    manualRollbackTriggerReason: null,
    manualRollbackTriggerAt: null,
    manualRollbackCount: null,
    manualRollbackSupervisor: null,
    autoRollbackAuditType: null,
    autoRollbackAuditTriggerKind: null,
    manualRollbackAuditType: null,
    manualRollbackAuditTriggerKind: null,
    retiredStatus: retired.status,
    retiredReason: retired.reason,
    remainingVersionCount: retired.activeVersionIds.length
  };
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
const currentPath = fileURLToPath(import.meta.url);

if (invokedPath === currentPath) {
  const sourceCompiledModulePath = process.argv[2];
  const targetCompiledModulePath = process.argv[3];
  const stateDirectory = process.argv[4];

  if (!sourceCompiledModulePath || !targetCompiledModulePath) {
    throw new Error("usage: node demo.mjs <compiled-v1> <compiled-v2> [state-dir]");
  }

  const result = await runDurableWorkflowDemo(
    sourceCompiledModulePath,
    targetCompiledModulePath,
    stateDirectory
  );
  console.log(JSON.stringify(result));
}
