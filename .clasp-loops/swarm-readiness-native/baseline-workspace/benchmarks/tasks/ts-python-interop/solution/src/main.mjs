import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";
import readline from "node:readline";

function createJsonLineClient(command, args, cwd) {
  const child = spawn(command, args, {
    cwd,
    stdio: ["pipe", "pipe", "inherit"]
  });
  const pending = [];
  const reader = readline.createInterface({ input: child.stdout });

  reader.on("line", (line) => {
    const next = pending.shift();

    if (!next) {
      return;
    }

    try {
      const message = JSON.parse(line);
      next.resolve(message.response);
    } catch (error) {
      next.reject(error);
    }
  });

  const stop = async () => {
    if (child.exitCode !== null) {
      return { running: false };
    }

    child.kill();
    await new Promise((resolve) => child.once("exit", resolve));
    return { running: false };
  };

  return {
    status() {
      return { running: child.exitCode === null };
    },
    invoke(request) {
      return new Promise((resolve, reject) => {
        pending.push({ resolve, reject });
        child.stdin.write(JSON.stringify({ request }) + "\n");
      });
    },
    stop
  };
}

function assertBudget(value) {
  if (!Number.isInteger(value)) {
    throw new Error("budget must be an integer");
  }
}

export async function runPythonInteropDemo() {
  const cwd = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  let worker = createJsonLineClient("python3", ["-m", "clasp_worker_bridge"], cwd);
  let service = createJsonLineClient("python3", ["-m", "clasp_service_pkg"], cwd);

  const workerResult = await worker.invoke({ workerId: "worker-7" });
  const workerStop = await worker.stop();
  worker = createJsonLineClient("python3", ["-m", "clasp_worker_bridge"], cwd);
  const workerRestart = worker.status();
  await worker.stop();

  const serviceResult = await service.invoke({ company: "Acme", budget: 42 });
  let invalid = null;

  try {
    assertBudget("oops");
  } catch (error) {
    invalid = error instanceof Error ? error.message : String(error);
  }

  const serviceStop = await service.stop();

  return {
    workerRunning: true,
    workerAccepted: workerResult.accepted,
    workerLabel: workerResult.workerLabel,
    workerStopped: workerStop.running,
    workerRestarted: workerRestart.running,
    serviceSummary: serviceResult.summary,
    serviceAccepted: serviceResult.accepted,
    serviceStopped: serviceStop.running,
    invalid
  };
}
