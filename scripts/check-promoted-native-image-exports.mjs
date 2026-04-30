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

for (const imagePath of imagePaths) {
  const image = loadImage(imagePath);
  const relPath = path.relative(projectRoot, imagePath);
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
}

console.log(`promoted compiler images expose ${mainSignatures.length} Main.clasp text exports`);
