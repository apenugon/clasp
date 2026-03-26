import { spawn, spawnSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import net from "node:net";
import { fileURLToPath } from "node:url";

const examplesRoot = path.dirname(fileURLToPath(import.meta.url));
const projectRoot = path.resolve(examplesRoot, "..");

function commandError(program, args, result) {
  const stderr = (result.stderr ?? "").trim();
  const stdout = (result.stdout ?? "").trim();
  const details = stderr || stdout || `exit code ${result.status ?? "unknown"}`;
  return new Error(`${program} ${args.join(" ")} failed: ${details}`);
}

export function compileNativeBinary(entryPath, explicitBinaryPath, binaryName) {
  if (explicitBinaryPath) {
    return {
      binaryPath: path.resolve(process.cwd(), explicitBinaryPath),
      cleanup() {},
    };
  }

  const tmpRoot = mkdtempSync(path.join(os.tmpdir(), "clasp-native-demo-"));
  const binaryPath = path.join(tmpRoot, binaryName);
  const result = spawnSync("claspc", ["compile", entryPath, "-o", binaryPath], {
    cwd: projectRoot,
    encoding: "utf8",
  });
  if (result.status !== 0) {
    rmSync(tmpRoot, { recursive: true, force: true });
    throw commandError("claspc", ["compile", entryPath, "-o", binaryPath], result);
  }
  return {
    binaryPath,
    cleanup() {
      rmSync(tmpRoot, { recursive: true, force: true });
    },
  };
}

export function compileNativeImage(entryPath, explicitImagePath, imageName) {
  if (explicitImagePath) {
    return {
      imagePath: path.resolve(process.cwd(), explicitImagePath),
      cleanup() {},
    };
  }

  const tmpRoot = mkdtempSync(path.join(os.tmpdir(), "clasp-native-image-"));
  const imagePath = path.join(tmpRoot, imageName);
  const result = spawnSync("claspc", ["native-image", entryPath, "-o", imagePath], {
    cwd: projectRoot,
    encoding: "utf8",
  });
  if (result.status !== 0) {
    rmSync(tmpRoot, { recursive: true, force: true });
    throw commandError("claspc", ["native-image", entryPath, "-o", imagePath], result);
  }
  return {
    imagePath,
    cleanup() {
      rmSync(tmpRoot, { recursive: true, force: true });
    },
  };
}

export function runBinary(binaryPath, args) {
  const result = spawnSync(binaryPath, args, {
    cwd: projectRoot,
    encoding: "utf8",
  });
  if (result.status !== 0) {
    throw commandError(binaryPath, args, result);
  }
  return result.stdout.trim();
}

export function runRoute(binaryPath, method, routePath, requestJson = "{}") {
  return runBinary(binaryPath, ["route", method, routePath, requestJson]);
}

export function execImage(imagePath, exportName, outputPath, sourcePath = null) {
  const args = ["exec-image", imagePath, exportName];
  if (sourcePath) {
    args.push(sourcePath);
  }
  args.push(outputPath);
  const result = spawnSync("claspc", args, {
    cwd: projectRoot,
    encoding: "utf8",
  });
  if (result.status !== 0) {
    throw commandError("claspc", args, result);
  }
}

function findFreePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      if (!address || typeof address === "string") {
        reject(new Error("failed to allocate demo port"));
        return;
      }
      const { port } = address;
      server.close((error) => {
        if (error) {
          reject(error);
        } else {
          resolve(port);
        }
      });
    });
    server.on("error", reject);
  });
}

async function waitForServer(baseUrl) {
  for (let attempt = 0; attempt < 50; attempt += 1) {
    try {
      const response = await fetch(baseUrl);
      await response.text();
      return;
    } catch {
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
  }
  throw new Error(`native demo server did not become ready at ${baseUrl}`);
}

export async function withNativeServer(binaryPath, readinessPath, run) {
  const port = await findFreePort();
  const addr = `127.0.0.1:${port}`;
  const process = spawn(binaryPath, ["serve", addr], {
    cwd: projectRoot,
    stdio: ["ignore", "ignore", "pipe"],
  });
  let stderr = "";
  process.stderr.on("data", (chunk) => {
    stderr += chunk.toString();
  });

  try {
    await waitForServer(`http://${addr}${readinessPath}`);
    return await run({
      addr,
      baseUrl: `http://${addr}`,
    });
  } catch (error) {
    if (stderr.trim()) {
      throw new Error(`${error instanceof Error ? error.message : String(error)}\n${stderr.trim()}`);
    }
    throw error;
  } finally {
    process.kill("SIGTERM");
    await new Promise((resolve) => process.once("exit", resolve));
  }
}

export async function fetchText(baseUrl, routePath, init) {
  const response = await fetch(`${baseUrl}${routePath}`, init);
  const text = await response.text();
  return {
    status: response.status,
    headers: response.headers,
    text,
  };
}
