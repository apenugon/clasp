import { spawn } from "node:child_process";
import readline from "node:readline";

function defaultPythonInterop(compiledModule) {
  const hooks = Array.isArray(compiledModule?.__claspHooks)
    ? compiledModule.__claspHooks.map((hook) =>
        Object.freeze({
          kind: "worker",
          name: hook.name,
          id: hook.id,
          event: hook.event,
          transport: "stdio",
          lifecycle: "managed",
          requestType: hook.requestType,
          requestSchema: hook.requestSchema ?? null,
          responseType: hook.responseType,
          responseSchema: hook.responseSchema ?? null
        })
      )
    : [];
  const services = Array.isArray(compiledModule?.__claspRoutes)
    ? compiledModule.__claspRoutes
        .filter(
          (route) =>
            route?.responseKind !== "page" && route?.responseKind !== "redirect"
        )
        .map((route) =>
          Object.freeze({
            kind: "service",
            name: route.name,
            id: route.id,
            method: route.method,
            path: route.path,
            transport: "stdio",
            lifecycle: "managed",
            requestType: route.requestType,
            requestSchema: route.requestSchema ?? null,
            responseType: route.responseType,
            responseSchema: route.responseDecl?.schema ?? route.responseSchema ?? null
          })
        )
    : [];

  return Object.freeze({
    version: 1,
    runtime: Object.freeze({
      module: "runtime/bun/python.mjs",
      entry: "createPythonInteropRuntime"
    }),
    workers: Object.freeze(hooks),
    services: Object.freeze(services),
    schemas: compiledModule?.__claspSchemas ?? {}
  });
}

export function bindingContractFor(compiledModule) {
  const contract = compiledModule?.__claspBindings;

  if (
    contract &&
    contract.kind === "clasp-generated-bindings" &&
    contract.version === 1 &&
    contract.python &&
    contract.python.version === 1
  ) {
    return contract.python;
  }

  const pythonInterop = compiledModule?.__claspPythonInterop;

  if (pythonInterop && pythonInterop.version === 1) {
    return pythonInterop;
  }

  return defaultPythonInterop(compiledModule);
}

export function createPythonInteropRuntime(compiledModule, options = {}) {
  const contract = bindingContractFor(compiledModule);

  return {
    contract,
    worker(name, workerOptions = {}) {
      return createPythonWorker(compiledModule, {
        ...options,
        ...workerOptions,
        name
      });
    },
    service(name, serviceOptions = {}) {
      return createPythonService(compiledModule, {
        ...options,
        ...serviceOptions,
        name
      });
    },
    listWorkers() {
      return contract.workers;
    },
    listServices() {
      return contract.services;
    }
  };
}

export function createPythonWorker(compiledModule, options = {}) {
  const contract = bindingContractFor(compiledModule);
  const descriptor = findBoundary(contract.workers, options.name, "worker");
  const requestSchema = schemaContractFor(contract.schemas, descriptor.requestType);
  const responseSchema = schemaContractFor(contract.schemas, descriptor.responseType);

  return createBoundaryProcess({
    descriptor,
    protocolKind: "worker",
    encodeRequest(value) {
      return requestSchema.toHost(requestSchema.fromHost(value, "request"), "request");
    },
    decodeResponse(value) {
      return responseSchema.fromHost(value, "response");
    },
    processOptions: options
  });
}

export function createPythonService(compiledModule, options = {}) {
  const contract = bindingContractFor(compiledModule);
  const descriptor = findBoundary(contract.services, options.name, "service");
  const requestSchema = schemaContractFor(contract.schemas, descriptor.requestType);
  const responseSchema = schemaContractFor(contract.schemas, descriptor.responseType);

  return createBoundaryProcess({
    descriptor,
    protocolKind: "service",
    encodeRequest(value) {
      return requestSchema.toHost(requestSchema.fromHost(value, "request"), "request");
    },
    decodeResponse(value) {
      return responseSchema.fromHost(value, "response");
    },
    processOptions: options
  });
}

function findBoundary(boundaries, name, kind) {
  if (typeof name !== "string" || name === "") {
    throw new Error(`Clasp Python ${kind} boundaries require a non-empty name.`);
  }

  const boundary = boundaries.find((candidate) => candidate?.name === name);

  if (!boundary) {
    throw new Error(`Missing Clasp Python ${kind} boundary: ${name}`);
  }

  return boundary;
}

function schemaContractFor(schemas, typeName) {
  const schema = schemas?.[typeName];

  if (!schema) {
    throw new Error(`Missing Clasp schema contract: ${typeName}`);
  }

  return schema;
}

function createBoundaryProcess({ descriptor, protocolKind, encodeRequest, decodeResponse, processOptions }) {
  let child = null;
  let reader = null;
  let startPromise = null;
  let exitPromise = null;
  let stderrText = "";
  const pending = [];

  return {
    descriptor,
    async start() {
      if (child) {
        return status();
      }
      if (startPromise) {
        return startPromise;
      }

      startPromise = new Promise((resolve, reject) => {
        const invocation = resolveInvocation(processOptions);
        const spawned = spawn(invocation.command, invocation.args, {
          cwd: processOptions.cwd,
          env: processOptions.env ? { ...process.env, ...processOptions.env } : process.env,
          stdio: ["pipe", "pipe", "pipe"]
        });

        child = spawned;
        exitPromise = new Promise((exitResolve) => {
          spawned.once("exit", (code, signal) => {
            child = null;
            if (reader) {
              reader.close();
              reader = null;
            }
            const error =
              code === 0 || signal === "SIGTERM"
                ? null
                : new Error(pythonExitMessage(descriptor.name, code, signal, stderrText));
            while (pending.length > 0) {
              const next = pending.shift();
              next.reject(error ?? new Error(`Clasp Python boundary stopped: ${descriptor.name}`));
            }
            exitResolve();
          });
        });

        spawned.once("error", (error) => {
          child = null;
          reject(error);
        });

        spawned.stderr.setEncoding("utf8");
        spawned.stderr.on("data", (chunk) => {
          stderrText = `${stderrText}${chunk}`.slice(-4000);
        });

        spawned.stdout.setEncoding("utf8");
        reader = readline.createInterface({ input: spawned.stdout });
        reader.on("line", (line) => {
          const next = pending.shift();
          if (!next) {
            return;
          }
          try {
            next.resolve(JSON.parse(line));
          } catch (error) {
            next.reject(error);
          }
        });

        spawned.once("spawn", () => {
          resolve(status());
        });
      }).finally(() => {
        startPromise = null;
      });

      return startPromise;
    },
    async stop() {
      if (!child) {
        return status();
      }

      const activeChild = child;
      activeChild.kill("SIGTERM");
      await exitPromise;
      return status();
    },
    async restart() {
      await this.stop();
      return this.start();
    },
    status() {
      return status();
    },
    async invoke(value, context = null) {
      await this.start();

      const response = await sendMessage({
        kind: protocolKind,
        name: descriptor.name,
        request: encodeRequest(value),
        context
      });

      if (!response || typeof response !== "object" || Array.isArray(response)) {
        throw new Error(`Invalid Clasp Python ${protocolKind} response: ${descriptor.name}`);
      }

      if (typeof response.error === "string" && response.error !== "") {
        throw new Error(response.error);
      }

      return decodeResponse(response.response ?? response.result ?? response);
    }
  };

  function status() {
    return {
      running: child !== null,
      pid: child?.pid ?? null
    };
  }

  function sendMessage(message) {
    if (!child) {
      throw new Error(`Clasp Python boundary is not running: ${descriptor.name}`);
    }

    return new Promise((resolve, reject) => {
      pending.push({ resolve, reject });
      child.stdin.write(`${JSON.stringify(message)}\n`, (error) => {
        if (error) {
          pending.pop();
          reject(error);
        }
      });
    });
  }
}

function resolveInvocation(options) {
  const command = options.command ?? "python3";
  const baseArgs = Array.isArray(options.pythonArgs) ? [...options.pythonArgs] : [];
  const extraArgs = Array.isArray(options.args) ? options.args : [];

  if (typeof options.package === "string" && options.package !== "") {
    return { command, args: [...baseArgs, "-m", options.package, ...extraArgs] };
  }

  if (typeof options.module === "string" && options.module !== "") {
    return { command, args: [...baseArgs, "-m", options.module, ...extraArgs] };
  }

  if (typeof options.script === "string" && options.script !== "") {
    return { command, args: [...baseArgs, options.script, ...extraArgs] };
  }

  throw new Error("Clasp Python boundaries require a package, module, or script.");
}

function pythonExitMessage(name, code, signal, stderrText) {
  const reason =
    signal !== null
      ? `signal ${signal}`
      : `exit code ${code ?? "unknown"}`;
  const stderrSuffix =
    stderrText.trim() === "" ? "" : `\n${stderrText.trim()}`;
  return `Clasp Python boundary ${name} stopped with ${reason}.${stderrSuffix}`;
}
