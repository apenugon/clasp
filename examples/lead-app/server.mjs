import { spawn } from "node:child_process";

import { compileNativeBinary } from "../native-demo.mjs";

const compiled = compileNativeBinary("examples/lead-app/Main.clasp", process.argv[2], "lead-app-server");
const port = process.env.PORT ?? "3001";
const addr = `127.0.0.1:${port}`;
const child = spawn(compiled.binaryPath, ["serve", addr], {
  stdio: "inherit"
});

const cleanup = () => {
  child.kill("SIGTERM");
  compiled.cleanup();
};

process.on("SIGINT", () => {
  cleanup();
  process.exit(130);
});

process.on("SIGTERM", () => {
  cleanup();
  process.exit(143);
});

child.on("exit", (code, signal) => {
  compiled.cleanup();
  if (signal) {
    process.kill(process.pid, signal);
    return;
  }
  process.exit(code ?? 0);
});

console.log(`Clasp lead app listening on http://${addr}`);
