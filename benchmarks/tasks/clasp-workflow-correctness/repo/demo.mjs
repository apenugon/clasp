import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

async function loadWorkerRuntime() {
  const projectRoot = process.env.CLASP_PROJECT_ROOT;

  if (!projectRoot) {
    throw new Error("CLASP_PROJECT_ROOT is required");
  }

  return import(pathToFileURL(path.join(projectRoot, "runtime/bun/worker.mjs")).href);
}

export async function runWorkflowCorrectnessDemo(compiledModulePath) {
  const [{ createWorkerRuntime }, compiledModule] = await Promise.all([
    loadWorkerRuntime(),
    import(pathToFileURL(path.resolve(compiledModulePath)).href)
  ]);
  const runtime = createWorkerRuntime(compiledModule);
  const workflow = runtime.workflow("CounterFlow");
  const started = workflow.start('{"count":2}');
  const resumed = workflow.resume('{"count":2}');
  const delivered = workflow.deliver(started, { id: "ok", payload: 2 }, (state, payload) => ({
    state: { count: state.count + payload },
    result: state.count + payload
  }));
  let invariantError = null;

  try {
    workflow.start('{"count":-1}');
  } catch (error) {
    invariantError = error.message;
  }

  const preconditionFailure = workflow.deliver(
    workflow.start('{"count":5}'),
    { id: "pre", payload: 1 },
    (state, payload) => ({
      state: { count: state.count + payload },
      result: state.count + payload
    })
  );
  const postconditionFailure = workflow.deliver(
    workflow.start('{"count":4}'),
    { id: "post", payload: 2 },
    (state, payload) => ({
      state: { count: state.count + payload },
      result: state.count + payload
    })
  );

  return {
    constraintNames: Object.values(workflow.constraints)
      .filter(Boolean)
      .map((entry) => entry.name)
      .sort(),
    deliveredStatus: delivered.status,
    deliveredResult: delivered.result,
    resumedCount: resumed.count,
    invariantError,
    preconditionStatus: preconditionFailure.status,
    preconditionError: preconditionFailure.failure?.message ?? null,
    postconditionStatus: postconditionFailure.status,
    postconditionError: postconditionFailure.failure?.message ?? null
  };
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
const currentPath = fileURLToPath(import.meta.url);

if (invokedPath === currentPath) {
  const compiledModulePath = process.argv[2];

  if (!compiledModulePath) {
    throw new Error("usage: node demo.mjs <compiled-module>");
  }

  const result = await runWorkflowCorrectnessDemo(compiledModulePath);
  console.log(JSON.stringify(result));
}
