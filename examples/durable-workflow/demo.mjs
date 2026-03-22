import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import {
  compileNativeBinary,
  compileNativeImage,
  runBinary,
} from "../native-demo.mjs";

function readImage(imagePath) {
  return JSON.parse(fs.readFileSync(imagePath, "utf8"));
}

function firstWorkflowBoundary(image) {
  return (image?.runtime?.boundaries ?? []).find((boundary) => boundary?.kind === "workflow");
}

export async function runDurableWorkflowDemo(
  sourceBinaryPath = null,
  targetBinaryPath = null,
  stateDirectory = path.resolve("dist/workflow-demo/state")
) {
  const sourceBinary = compileNativeBinary(
    "examples/durable-workflow/Main.clasp",
    sourceBinaryPath,
    "durable-workflow-v1"
  );
  const sourceImage = compileNativeImage(
    "examples/durable-workflow/Main.clasp",
    null,
    "durable-workflow-v1.native.image.json"
  );
  const targetBinary = compileNativeBinary(
    "examples/durable-workflow/Main.next.clasp",
    targetBinaryPath,
    "durable-workflow-v2"
  );
  const targetImage = compileNativeImage(
    "examples/durable-workflow/Main.next.clasp",
    null,
    "durable-workflow-v2.native.image.json"
  );

  try {
    const sourceImageJson = readImage(sourceImage.imagePath);
    const targetImageJson = readImage(targetImage.imagePath);
    const sourceWorkflow = firstWorkflowBoundary(sourceImageJson);
    const targetWorkflow = firstWorkflowBoundary(targetImageJson);

    return {
      stateDirectory,
      sourceMain: runBinary(sourceBinary.binaryPath, []),
      targetMain: runBinary(targetBinary.binaryPath, []),
      sourceWorkflow: sourceWorkflow?.name ?? null,
      sourceStateType: sourceWorkflow?.state ?? null,
      sourceCheckpointCodec: sourceWorkflow?.checkpoint ?? null,
      sourceRestoreCodec: sourceWorkflow?.restore ?? null,
      sourceHandoffSymbol: sourceWorkflow?.handoff ?? null,
      sourceCompatibilityFingerprint:
        sourceImageJson?.compatibility?.interfaceFingerprint ?? null,
      targetWorkflow: targetWorkflow?.name ?? null,
      targetStateType: targetWorkflow?.state ?? null,
      targetCheckpointCodec: targetWorkflow?.checkpoint ?? null,
      targetRestoreCodec: targetWorkflow?.restore ?? null,
      targetHandoffSymbol: targetWorkflow?.handoff ?? null,
      targetCompatibilityFingerprint:
        targetImageJson?.compatibility?.interfaceFingerprint ?? null,
      targetAcceptedPreviousFingerprints:
        targetImageJson?.compatibility?.acceptedPreviousFingerprints ?? [],
    };
  } finally {
    sourceImage.cleanup();
    sourceBinary.cleanup();
    targetImage.cleanup();
    targetBinary.cleanup();
  }
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
const currentPath = fileURLToPath(import.meta.url);

if (invokedPath === currentPath) {
  const sourceBinaryPath = process.argv[2] ?? null;
  const targetBinaryPath = process.argv[3] ?? null;
  const stateDirectory = process.argv[4];

  const result = await runDurableWorkflowDemo(
    sourceBinaryPath,
    targetBinaryPath,
    stateDirectory
  );
  console.log(JSON.stringify(result));
}
