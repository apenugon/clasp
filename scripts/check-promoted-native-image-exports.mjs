#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";

const projectRoot = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const mainSourcePath = path.join(projectRoot, "src/Main.clasp");
const compilerMainSourcePath = path.join(projectRoot, "src/CompilerMain.clasp");
const imagePaths = [
  path.join(projectRoot, "src/stage1.compiler.native.image.json"),
  path.join(projectRoot, "src/embedded.compiler.native.image.json"),
];
const sourceExportCachePath = path.join(projectRoot, "src/stage1.compiler.source-export-cache-v1.json");
const portableTaskWorkspace =
  projectRoot.split(path.sep).includes(".clasp-task-workspaces") ||
  process.env.CLASP_ALLOW_SOURCE_EXPORT_ONLY_NATIVE_IMAGE_CHECK === "1";
const requiredSourceExportOutputPaths = [
  "src/stage1.task-workspace-runtime-harness.native.image.json",
];

function fail(message) {
  console.error(`check-promoted-native-image-exports: ${message}`);
  process.exit(1);
}

function readText(filePath) {
  return fs.readFileSync(filePath, "utf8");
}

function parseTextExportSignatures(source) {
  const signatures = [];
  for (const line of source.split("\n")) {
    const match = /^([A-Za-z][A-Za-z0-9_]*Text)\s*:\s*(.+)$/.exec(line.trim());
    if (match) {
      signatures.push({ name: match[1], type: match[2].trim() });
    }
  }
  return signatures;
}

function parseSignatureMap(source) {
  const signatures = new Map();
  for (const signature of parseTextExportSignatures(source)) {
    signatures.set(signature.name, signature.type);
  }
  return signatures;
}

function loadImage(filePath) {
  try {
    return JSON.parse(readText(filePath));
  } catch (error) {
    fail(`failed to parse ${path.relative(projectRoot, filePath)}: ${error.message}`);
  }
}

function validateRuntimeBindings(image, relPath) {
  const bindings = image.runtime && image.runtime.bindings;
  if (!Array.isArray(bindings)) {
    fail(`${relPath} is missing runtime.bindings`);
  }
  for (const [index, binding] of bindings.entries()) {
    if (!binding || !binding.name || !binding.runtime || !binding.symbol || !binding.type) {
      fail(`${relPath} has invalid runtime binding at index ${index}`);
    }
  }
}

function validatePortableSourceExportCache(missingRelPaths) {
  let cache;
  try {
    cache = JSON.parse(readText(sourceExportCachePath));
  } catch (error) {
    fail(
      `missing promoted native images (${missingRelPaths.join(", ")}) and failed to parse ${path.relative(
        projectRoot,
        sourceExportCachePath,
      )}: ${error.message}`,
    );
  }

  if (cache.cacheVersion !== "source-export-cache-v1") {
    fail(`${path.relative(projectRoot, sourceExportCachePath)} has unexpected cacheVersion ${cache.cacheVersion}`);
  }
  if (!Array.isArray(cache.entries)) {
    fail(`${path.relative(projectRoot, sourceExportCachePath)} is missing entries`);
  }

  const outputPaths = new Set(
    cache.entries
      .map((entry) => entry && entry.outputPath)
      .filter((outputPath) => typeof outputPath === "string"),
  );
  for (const outputPath of requiredSourceExportOutputPaths) {
    if (!outputPaths.has(outputPath)) {
      fail(`${path.relative(projectRoot, sourceExportCachePath)} is missing outputPath ${outputPath}`);
    }
  }
}

const mainSignatures = parseTextExportSignatures(readText(mainSourcePath));
if (mainSignatures.length === 0) {
  fail("src/Main.clasp has no *Text export signatures");
}

const compilerMainSignatures = parseSignatureMap(readText(compilerMainSourcePath));
for (const { name, type } of mainSignatures) {
  const compilerMainType = compilerMainSignatures.get(name);
  if (!compilerMainType) {
    fail(`src/CompilerMain.clasp is missing Main.clasp text export ${name}`);
  }
  if (compilerMainType !== type) {
    fail(`src/CompilerMain.clasp has stale type for ${name}: ${compilerMainType} !== ${type}`);
  }
}

const missingImageRelPaths = [];
let checkedImageCount = 0;
for (const imagePath of imagePaths) {
  const relPath = path.relative(projectRoot, imagePath);
  if (!fs.existsSync(imagePath)) {
    missingImageRelPaths.push(relPath);
    continue;
  }
  const image = loadImage(imagePath);
  if (image.format !== "clasp-native-image-v1") {
    fail(`${relPath} has unexpected format ${image.format}`);
  }
  validateRuntimeBindings(image, relPath);
  const exports = new Set(Array.isArray(image.exports) ? image.exports : []);
  const entrypoints = new Set(
    Array.isArray(image.entrypoints)
      ? image.entrypoints.map((entry) => entry && entry.name).filter(Boolean)
      : [],
  );
  for (const { name } of mainSignatures) {
    if (!exports.has(name)) {
      fail(`${relPath} is missing exported text function ${name}`);
    }
    if (!entrypoints.has(name)) {
      fail(`${relPath} is missing entrypoint for text function ${name}`);
    }
  }
  checkedImageCount += 1;
}

if (missingImageRelPaths.length > 0) {
  if (!portableTaskWorkspace) {
    fail(`missing promoted compiler images: ${missingImageRelPaths.join(", ")}`);
  }
  validatePortableSourceExportCache(missingImageRelPaths);
  console.log(
    `promoted compiler image export check used portable source-export fallback; checked ${checkedImageCount} image(s), missing ${missingImageRelPaths.join(
      ", ",
    )}`,
  );
} else {
  console.log(`promoted compiler images expose ${mainSignatures.length} Main.clasp text exports`);
}
