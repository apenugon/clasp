import path from "node:path";
import { pathToFileURL } from "node:url";

const compiledPath = process.argv[2];
const projectRoot = process.env.CLASP_PROJECT_ROOT;

if (!compiledPath) {
  throw new Error("usage: node demo.mjs <compiled-module>");
}

if (!projectRoot) {
  throw new Error("CLASP_PROJECT_ROOT is required");
}

const compiledModule = await import(pathToFileURL(compiledPath).href);
const runtimeModule = await import(
  pathToFileURL(path.join(projectRoot, "runtime/bun/server.mjs")).href
);
const { bindingContractFor, installCompiledModule } = runtimeModule;
const contract = bindingContractFor(compiledModule);

installCompiledModule(compiledModule);

console.log(
  JSON.stringify({
    packageKinds: contract.packageImports.map((entry) => entry.kind).sort(),
    upper: compiledModule.shout("hello ada"),
    formatted: compiledModule.describe({ company: "Acme Labs", budget: 7 })
  })
);
