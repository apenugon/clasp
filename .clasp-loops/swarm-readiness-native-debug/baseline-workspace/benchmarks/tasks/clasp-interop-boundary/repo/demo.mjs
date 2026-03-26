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
  pathToFileURL(path.join(projectRoot, "deprecated/runtime/server.mjs")).href
);
const { bindingContractFor, installCompiledModule } = runtimeModule;

installCompiledModule(compiledModule);

const contract = bindingContractFor(compiledModule);
const packageImport = contract.packageImports.find((entry) => entry.name === "inspectLead");

if (!packageImport) {
  throw new Error("missing package contract for inspectLead");
}

const valid = compiledModule.assessLead({ company: "Acme", budget: 42 });
let invalid = null;

try {
  compiledModule.assessLead({ company: "Globex", budget: 18 });
} catch (error) {
  const message = error instanceof Error ? error.message : String(error);
  invalid = `foreign inspectLead via ${packageImport.declaration.path} failed: ${message}`;
}

console.log(
  JSON.stringify({
    packageKind: packageImport.kind,
    validLabel: valid.label,
    validAccepted: valid.verdict.accepted,
    invalid
  })
);
