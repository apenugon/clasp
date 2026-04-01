import net from "node:net";
import { spawn } from "node:child_process";

export async function allocatePort() {
  return await new Promise((resolve, reject) => {
    const socket = net.createServer();

    socket.once("error", reject);
    socket.listen(0, "127.0.0.1", () => {
      const address = socket.address();

      if (!address || typeof address === "string") {
        socket.close(() => reject(new Error("failed to allocate an ephemeral port")));
        return;
      }

      const { port } = address;
      socket.close((error) => {
        if (error) {
          reject(error);
          return;
        }

        resolve(port);
      });
    });
  });
}

export function formBody(fields) {
  return new URLSearchParams(fields).toString();
}

export async function withNativeServer(binaryPath, callback, options = {}) {
  const { env = {}, readyPath = "/" } = options;
  const port = await allocatePort();
  const addr = `127.0.0.1:${port}`;
  const baseUrl = `http://${addr}`;
  const child = spawn(binaryPath, ["serve", addr], {
    stdio: ["ignore", "ignore", "pipe"],
    env: {
      ...process.env,
      ...env,
    },
  });
  let stderr = "";

  child.stderr.on("data", (chunk) => {
    stderr += String(chunk);
  });

  try {
    await waitForServer(`${baseUrl}${readyPath}`);
    return await callback({ baseUrl, port });
  } finally {
    child.kill("SIGTERM");
    await new Promise((resolve) => {
      child.once("exit", resolve);
      setTimeout(resolve, 1000);
    });
  }

  async function waitForServer(url) {
    for (let attempt = 0; attempt < 50; attempt += 1) {
      try {
        await fetch(url);
        return;
      } catch (error) {
        if (child.exitCode !== null) {
          throw new Error(`native server exited early: ${stderr || child.exitCode}`);
        }
        await new Promise((resolve) => setTimeout(resolve, 100));
      }
    }

    throw new Error(`native server did not become ready at ${url}: ${stderr}`);
  }
}

export function collectTexts(view) {
  const texts = [];

  function walk(node) {
    if (!node || typeof node !== "object") {
      return;
    }
    if (node.kind === "text") {
      texts.push(node.text ?? "");
    }
    if (Array.isArray(node.children)) {
      for (const child of node.children) {
        walk(child);
      }
    }
    if (node.left) {
      walk(node.left);
    }
    if (node.right) {
      walk(node.right);
    }
    if (node.child) {
      walk(node.child);
    }
  }

  walk(view);
  return texts;
}

export function firstFormAction(view) {
  let found = null;

  function walk(node) {
    if (!node || typeof node !== "object" || found !== null) {
      return;
    }
    if (node.kind === "form") {
      found = node.action ?? null;
      return;
    }
    if (Array.isArray(node.children)) {
      for (const child of node.children) {
        walk(child);
      }
    }
    if (node.left) {
      walk(node.left);
    }
    if (node.right) {
      walk(node.right);
    }
    if (node.child) {
      walk(node.child);
    }
  }

  walk(view);
  return found;
}

export function formFieldNames(view) {
  const fields = [];

  function walk(node) {
    if (!node || typeof node !== "object") {
      return;
    }
    if (node.kind === "input" && node.inputKind !== "hidden") {
      fields.push(node.fieldName ?? "");
    }
    if (Array.isArray(node.children)) {
      for (const child of node.children) {
        walk(child);
      }
    }
    if (node.left) {
      walk(node.left);
    }
    if (node.right) {
      walk(node.right);
    }
    if (node.child) {
      walk(node.child);
    }
  }

  walk(view);
  return fields;
}
