import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import { createWorkerRuntime } from "../../deprecated/runtime/worker.mjs";

function reduceCounter(state, payload) {
  return {
    state: { count: state.count + payload },
    result: payload
  };
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
  stateDirectory = path.resolve("dist/workflow-demo/state")
) {
  const sourceCompiledModule = await import(
    pathToFileURL(path.resolve(sourceCompiledModulePath)).href
  );
  const targetCompiledModule = await import(
    pathToFileURL(path.resolve(targetCompiledModulePath)).href
  );
  const patchedTargetCompiledModule = patchTargetCompiledModule(
    sourceCompiledModule,
    targetCompiledModule
  );
  const statePath = path.join(path.resolve(stateDirectory), "counter-run.json");

  await fs.mkdir(path.dirname(statePath), { recursive: true });

  const initialRuntime = createWorkerRuntime(sourceCompiledModule);
  const initialWorkflow = initialRuntime.workflow("CounterFlow");
  const seededRun = initialWorkflow.start(
    initialWorkflow.checkpoint({ count: 5 }),
    {
      deadlineAt: 1500,
      mailbox: [{ id: "resume-1", payload: 2 }]
    }
  );
  const activeRun = initialWorkflow.deliver(
    seededRun,
    { id: "boot-1", payload: 3 },
    reduceCounter,
    { now: 1000 }
  ).run;

  await fs.writeFile(statePath, JSON.stringify(activeRun, null, 2));

  const restartedRuntime = createWorkerRuntime(sourceCompiledModule);
  const restartedWorkflow = restartedRuntime.workflow("CounterFlow");
  const persistedRun = JSON.parse(await fs.readFile(statePath, "utf8"));
  const restarted = restartedWorkflow.processNext(
    persistedRun,
    reduceCounter,
    { now: 1001 }
  );

  await fs.writeFile(statePath, JSON.stringify(restarted.run, null, 2));

  const protocol = restartedRuntime.hotSwap(patchedTargetCompiledModule, {
    supervisor: "UpgradeSupervisor"
  });
  const handedOff = protocol.handoff(
    "CounterFlow",
    restarted.run,
    "release-bot",
    "controlled-upgrade",
    { updatedAt: 1002 }
  );
  const draining = protocol.drain("CounterFlow", handedOff.run, { updatedAt: 1003 });
  const activated = protocol.activate("CounterFlow", draining.run, {
    migrateState: (state) => ({ count: state.count + 5 }),
    activate: (nextRun) => ({
      ...nextRun,
      supervision: {
        ...nextRun.supervision,
        supervisor: "UpgradeSupervisor"
      }
    }),
    healthCheck: (nextRun) => ({
      healthy: nextRun.state.count === 15,
      status: "healthy"
    })
  });
  const retired = protocol.retire({ retiredAt: 1004, reason: "promoted" });

  return {
    statePath,
    initialCount: activeRun.state.count,
    restartRecovered: restarted.status === "delivered",
    restartedCount: restarted.run.state.count,
    restartedMailboxSize: restarted.run.mailbox.length,
    handoffStatus: handedOff.status,
    handoffOperator: handedOff.run.supervision.operator,
    drainingStatus: draining.status,
    activatedStatus: activated.status,
    activatedCount: activated.run.state.count,
    activatedSupervisor: activated.run.supervision.supervisor,
    retiredStatus: retired.status,
    retiredReason: retired.reason
  };
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
const currentPath = fileURLToPath(import.meta.url);

if (invokedPath === currentPath) {
  const sourceCompiledModulePath = process.argv[2];
  const targetCompiledModulePath = process.argv[3];
  const stateDirectory = process.argv[4];

  if (!sourceCompiledModulePath || !targetCompiledModulePath) {
    throw new Error(
      "usage: node examples/durable-workflow/demo.mjs <compiled-v1> <compiled-v2> [state-dir]"
    );
  }

  const result = await runDurableWorkflowDemo(
    sourceCompiledModulePath,
    targetCompiledModulePath,
    stateDirectory
  );
  console.log(JSON.stringify(result));
}
