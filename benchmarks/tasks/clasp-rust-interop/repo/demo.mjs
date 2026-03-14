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
const { nativeInteropContractFor, resolveNativeInteropPlan } = runtimeModule;
const contract = nativeInteropContractFor(compiledModule);
const plan = resolveNativeInteropPlan(compiledModule, {
  target: "bun",
  targetTriple: "x86_64-unknown-linux-gnu",
  bindings: {
    mockLeadSummaryModel: {
      crateName: "lead_summary_bridge",
      libName: "lead_summary_bridge",
      manifestPath: "native/lead-summary/Cargo.toml",
      capabilities: [
        "capability:foreign:mockLeadSummaryModel",
        "capability:ml:lead-summary"
      ]
    }
  }
});
const binding = contract.bindings[0];
const bindingPlan = plan.bindings[0];

console.log(
  JSON.stringify({
    abi: contract.abi,
    supportedTargets: contract.supportedTargets,
    bindingName: binding.name,
    capabilityId: binding.capability.id,
    crateName: bindingPlan.crateName,
    loader: bindingPlan.loader,
    crateType: bindingPlan.crateType,
    manifestPath: bindingPlan.manifestPath,
    artifactFileName: bindingPlan.artifactFileName,
    cargoCommand: bindingPlan.cargo.command,
    capabilities: bindingPlan.capabilities
  })
);
