import { bindingContractFor, installCompiledModule } from "../../deprecated/runtime/server.mjs";
import { pathToFileURL } from "node:url";

const compiledPath = process.argv[2];

if (!compiledPath) {
  throw new Error("usage: node examples/interop-ts/demo.mjs <compiled-module>");
}

const compiledModule = await import(pathToFileURL(compiledPath).href);
const contract = bindingContractFor(compiledModule);
installCompiledModule(compiledModule);

console.log(
  JSON.stringify({
    packageKinds: contract.packageImports.map((entry) => entry.kind).sort(),
    upper: compiledModule.shout("hello ada"),
    formatted: compiledModule.describe({ company: "Acme Labs", budget: 7 })
  })
);
