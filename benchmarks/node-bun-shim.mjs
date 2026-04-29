#!/usr/bin/env node
import http from "node:http";
import { pathToFileURL } from "node:url";
import { resolve } from "node:path";
import { spawnSync } from "node:child_process";

const args = process.argv.slice(2);

function runNode(nodeArgs) {
  const result = spawnSync(process.execPath, nodeArgs, { stdio: "inherit" });
  process.exit(result.status ?? 1);
}

function installBunServeShim() {
  if (globalThis.Bun && typeof globalThis.Bun.serve === "function") {
    return;
  }

  globalThis.Bun = {
    serve(options) {
      const server = http.createServer(async (incoming, outgoing) => {
        try {
          const chunks = [];
          for await (const chunk of incoming) {
            chunks.push(chunk);
          }

          const host = incoming.headers.host ?? `127.0.0.1:${options.port}`;
          const method = incoming.method ?? "GET";
          const requestInit = {
            method,
            headers: incoming.headers
          };
          if (method !== "GET" && method !== "HEAD") {
            requestInit.body = Buffer.concat(chunks);
          }

          const request = new Request(
            `http://${host}${incoming.url ?? "/"}`,
            requestInit
          );
          const response = await options.fetch(request);
          outgoing.statusCode = response.status;
          response.headers.forEach((value, name) => {
            outgoing.setHeader(name, value);
          });
          outgoing.end(Buffer.from(await response.arrayBuffer()));
        } catch (error) {
          outgoing.statusCode = 500;
          outgoing.setHeader("content-type", "text/plain; charset=utf-8");
          outgoing.end(error instanceof Error ? error.message : String(error));
        }
      });

      server.listen(options.port, "127.0.0.1");
      return {
        port: options.port,
        stop(force = false) {
          if (force && typeof server.closeAllConnections === "function") {
            server.closeAllConnections();
          }
          server.close();
        }
      };
    }
  };
}

async function importTestFiles(files) {
  installBunServeShim();
  for (const file of files) {
    await import(pathToFileURL(resolve(file)).href);
  }
}

if (args[0] === "test") {
  const testArgs = args.slice(1);
  if (testArgs.length === 0) {
    runNode(["--test"]);
  }
  try {
    await importTestFiles(testArgs);
  } catch (error) {
    console.error(error instanceof Error && error.stack ? error.stack : error);
    process.exit(1);
  }
  process.exit(0);
}

if (args[0] === "run") {
  runNode(args.slice(1));
}

try {
  await importTestFiles(args);
} catch (error) {
  console.error(error instanceof Error && error.stack ? error.stack : error);
  process.exit(1);
}
