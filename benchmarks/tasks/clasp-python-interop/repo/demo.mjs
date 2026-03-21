import path from "node:path";
import { pathToFileURL } from "node:url";

const compiledPath = process.argv[2];
const projectRoot = process.env.CLASP_PROJECT_ROOT;
const workspaceRoot = process.cwd();

if (!compiledPath) {
  throw new Error("usage: node demo.mjs <compiled-module>");
}

if (!projectRoot) {
  throw new Error("CLASP_PROJECT_ROOT is required");
}

const compiledModule = await import(pathToFileURL(compiledPath).href);
const runtimeModule = await import(
  pathToFileURL(path.join(projectRoot, "src/runtime/python.mjs")).href
);
const { createPythonInteropRuntime } = runtimeModule;
const runtime = createPythonInteropRuntime(compiledModule);
const worker = runtime.worker("workerStart", {
  cwd: workspaceRoot,
  module: "clasp_worker_bridge"
});
const service = runtime.service("summarizeRoute", {
  cwd: workspaceRoot,
  package: "clasp_service_pkg"
});

await worker.start();
const workerRunning = worker.status().running;
const workerResult = await worker.invoke({ workerId: "worker-7" });
const workerStop = await worker.stop();
await worker.restart();
const workerRestart = worker.status();
await worker.stop();

await service.start();
const serviceResult = await service.invoke({ company: "Acme", budget: 42 });
let invalid = null;

try {
  await service.invoke({ company: "Acme", budget: "oops" });
} catch (error) {
  invalid = error instanceof Error ? error.message : String(error);
}

const serviceStop = await service.stop();

console.log(
  JSON.stringify({
    workerRunning,
    workerAccepted: workerResult.accepted,
    workerLabel: workerResult.workerLabel,
    workerStopped: workerStop.running,
    workerRestarted: workerRestart.running,
    serviceSummary: serviceResult.summary,
    serviceAccepted: serviceResult.accepted,
    serviceStopped: serviceStop.running,
    invalid
  })
);
