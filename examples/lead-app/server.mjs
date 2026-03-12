import * as compiled from "./Main.js";
import { installCompiledModule, serveCompiledModule } from "../../runtime/bun/server.mjs";
import { createLeadDemoBindings } from "./bindings.mjs";

installCompiledModule(compiled, createLeadDemoBindings());

const server = serveCompiledModule(compiled, {
  port: Number(process.env.PORT ?? "3001")
});

console.log(`Clasp lead app listening on http://localhost:${server.port}`);
