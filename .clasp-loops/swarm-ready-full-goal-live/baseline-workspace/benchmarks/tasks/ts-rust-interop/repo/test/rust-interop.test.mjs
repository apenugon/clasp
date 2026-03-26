import assert from "node:assert/strict";
import { resolveLeadSummaryNativePlan } from "../src/nativeInterop.mjs";

assert.deepStrictEqual(resolveLeadSummaryNativePlan(), {
  abi: "clasp-native-v1",
  supportedTargets: ["bun", "worker", "react-native", "expo"],
  bindingName: "mockLeadSummaryModel",
  capabilityId: "capability:foreign:mockLeadSummaryModel",
  crateName: "lead_summary_bridge",
  loader: "bun:ffi",
  crateType: "cdylib",
  manifestPath: "native/lead-summary/Cargo.toml",
  artifactFileName: "liblead_summary_bridge.so",
  cargoCommand: [
    "cargo",
    "build",
    "--manifest-path",
    "native/lead-summary/Cargo.toml",
    "--release",
    "--target",
    "x86_64-unknown-linux-gnu"
  ],
  capabilities: [
    "capability:foreign:mockLeadSummaryModel",
    "capability:ml:lead-summary"
  ]
});
