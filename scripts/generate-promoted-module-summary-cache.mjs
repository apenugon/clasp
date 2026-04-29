#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";

const projectRoot = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const defaultOutputPath = path.join(projectRoot, "src/stage1.compiler.module-summary-cache-v2.json");
const defaultEntryPath = path.join(projectRoot, "src/Main.clasp");
const compilerImagePath = path.join(projectRoot, "src/stage1.compiler.native.image.json");

function fail(message) {
  console.error(`generate-promoted-module-summary-cache: ${message}`);
  process.exit(1);
}

function parseArgs(argv) {
  const options = {
    check: false,
    entryPath: defaultEntryPath,
    outputPath: defaultOutputPath,
  };
  for (let index = 2; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--check") {
      options.check = true;
    } else if (arg === "--entry") {
      index += 1;
      if (!argv[index]) fail("missing path after --entry");
      options.entryPath = path.resolve(argv[index]);
    } else if (arg === "--output") {
      index += 1;
      if (!argv[index]) fail("missing path after --output");
      options.outputPath = path.resolve(argv[index]);
    } else {
      fail(`unknown argument: ${arg}`);
    }
  }
  return options;
}

function fnvBytes(buffer) {
  let hash = 0xcbf29ce484222325n;
  const prime = 0x100000001b3n;
  const mask = 0xffffffffffffffffn;
  for (const byte of buffer) {
    hash ^= BigInt(byte);
    hash = (hash * prime) & mask;
  }
  return hash.toString(16).padStart(16, "0");
}

function fnvParts(parts) {
  let hash = 0xcbf29ce484222325n;
  const prime = 0x100000001b3n;
  const mask = 0xffffffffffffffffn;
  for (const part of parts) {
    const buffer = Buffer.isBuffer(part) ? part : Buffer.from(String(part));
    for (const byte of buffer) {
      hash ^= BigInt(byte);
      hash = (hash * prime) & mask;
    }
    hash ^= 0xffn;
    hash = (hash * prime) & mask;
  }
  return hash.toString(16).padStart(16, "0");
}

function parseModuleName(source) {
  for (const rawLine of source.split("\n")) {
    const line = rawLine.trim();
    if (!line) continue;
    const match = /^module\s+([^\s]+)/.exec(line);
    if (match) return match[1];
    break;
  }
  fail("module source was missing a module header");
}

function pushUnique(values, value) {
  if (value && !values.includes(value)) values.push(value);
}

function parseImports(source) {
  const imports = [];
  for (const rawLine of source.split("\n")) {
    const line = rawLine.trim();
    if (!line) continue;
    const moduleMatch = /^module\s+(.+)$/.exec(line);
    if (moduleMatch && moduleMatch[1].includes(" with ")) {
      for (const importName of moduleMatch[1].split(" with ")[1].split(",")) {
        pushUnique(imports, importName.trim());
      }
    }
    break;
  }
  for (const rawLine of source.split("\n")) {
    const line = rawLine.trim();
    if (line.startsWith("import ")) pushUnique(imports, line.slice("import ".length).trim());
  }
  return imports;
}

function braceDelta(text) {
  return (text.match(/\{/g) || []).length - (text.match(/\}/g) || []).length;
}

function sourcePathForModule(moduleName) {
  if (moduleName === "Main") return path.join(projectRoot, "src/Main.clasp");
  return path.join(projectRoot, "src", `${moduleName.replaceAll(".", "/")}.clasp`);
}

function conservativeModuleInterfaceFingerprint(moduleName) {
  const source = fs.readFileSync(sourcePathForModule(moduleName), "utf8");
  const renderedLines = [];
  const annotatedNames = new Set();
  let blockDepth = 0;
  let skipBodyDepth = 0;
  let fallbackToFullSource = false;

  for (const rawLine of source.split("\n")) {
    const trimmed = rawLine.trim();
    if (!trimmed) continue;

    if (skipBodyDepth > 0) {
      skipBodyDepth += braceDelta(trimmed);
      continue;
    }

    if (blockDepth > 0) {
      renderedLines.push(trimmed);
      blockDepth += braceDelta(trimmed);
      continue;
    }

    const topLevel = !rawLine.startsWith(" ") && !rawLine.startsWith("\t");
    if (!topLevel) continue;

    if (trimmed.startsWith("module ") || trimmed.startsWith("import ")) {
      renderedLines.push(trimmed);
      continue;
    }

    const signature = /^([^:]+):/.exec(trimmed);
    if (signature) {
      const name = signature[1].trim();
      if (name && !name.includes(" ")) {
        annotatedNames.add(name);
        renderedLines.push(trimmed);
        continue;
      }
    }

    const keyword = trimmed.split(/\s+/)[0] || "";
    if (
      [
        "record",
        "type",
        "foreign",
        "guide",
        "policy",
        "projection",
        "role",
        "agent",
        "workflow",
        "route",
        "hook",
        "toolserver",
        "tool",
        "verifier",
        "mergegate",
      ].includes(keyword)
    ) {
      renderedLines.push(trimmed);
      blockDepth = Math.max(braceDelta(trimmed), 0);
      continue;
    }

    const definition = /^([^=]+)=/.exec(trimmed);
    if (definition) {
      const name = definition[1].trim().split(/\s+/)[0];
      if (name && annotatedNames.has(name)) {
        skipBodyDepth = Math.max(braceDelta(trimmed), 0);
        continue;
      }
    }

    fallbackToFullSource = true;
    break;
  }

  return fallbackToFullSource ? fnvParts([source]) : fnvParts([renderedLines.join("\n")]);
}

function moduleSummaryFromAnnotations(source) {
  const summaries = [];
  let blockDepth = 0;
  for (const rawLine of source.split("\n")) {
    const trimmed = rawLine.trim();
    if (!trimmed) continue;
    if (blockDepth > 0) {
      blockDepth += braceDelta(trimmed);
      continue;
    }
    const topLevel = !rawLine.startsWith(" ") && !rawLine.startsWith("\t");
    const keyword = trimmed.split(/\s+/)[0] || "";
    if (
      [
        "record",
        "type",
        "foreign",
        "guide",
        "policy",
        "projection",
        "role",
        "agent",
        "workflow",
        "route",
        "hook",
        "toolserver",
        "tool",
        "verifier",
        "mergegate",
      ].includes(keyword)
    ) {
      blockDepth = Math.max(braceDelta(trimmed), 0);
      continue;
    }
    if (!topLevel) continue;
    const match = /^([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.+)$/.exec(trimmed);
    if (match) summaries.push(`${match[1]} : ${match[2].trim()}`);
  }
  return summaries.join("\n");
}

function topLevelDefinitionName(line) {
  const equalsIndex = line.indexOf("=");
  if (equalsIndex < 0) return "";
  const head = line.slice(0, equalsIndex).trim();
  return head.split(/\s+/)[0] || "";
}

function topLevelSignatureName(line) {
  const colonIndex = line.indexOf(":");
  if (colonIndex < 0) return "";
  const head = line.slice(0, colonIndex).trim();
  return head && !head.includes(" ") ? head : "";
}

function captureDeclarationSource(lines, startIndex) {
  const captured = [lines[startIndex].trimEnd()];
  let depth = braceDelta(lines[startIndex]);
  let index = startIndex + 1;
  while (index < lines.length) {
    const rawLine = lines[index];
    const trimmed = rawLine.trim();
    const topLevel = !rawLine.startsWith(" ") && !rawLine.startsWith("\t");
    if (depth <= 0 && trimmed && topLevel) break;
    captured.push(rawLine.trimEnd());
    depth += braceDelta(rawLine);
    index += 1;
  }
  return { source: captured.join("\n").trimEnd(), nextIndex: index };
}

function moduleDeclValidationFingerprints(source) {
  const fingerprints = {};
  const lines = source.split("\n");
  let pendingAnnotation = "";
  let index = 0;
  while (index < lines.length) {
    const rawLine = lines[index];
    const trimmed = rawLine.trim();
    if (!trimmed) {
      index += 1;
      continue;
    }

    const topLevel = !rawLine.startsWith(" ") && !rawLine.startsWith("\t");
    if (!topLevel) {
      index += 1;
      continue;
    }

    const signatureName = topLevelSignatureName(trimmed);
    if (signatureName) {
      pendingAnnotation = trimmed;
      index += 1;
      continue;
    }

    const keyword = trimmed.split(/\s+/)[0] || "";
    if (
      trimmed.startsWith("module ") ||
      trimmed.startsWith("import ") ||
      [
        "record",
        "type",
        "foreign",
        "hosted",
        "guide",
        "policy",
        "projection",
        "role",
        "agent",
        "workflow",
        "route",
        "hook",
        "toolserver",
        "tool",
        "verifier",
        "mergegate",
      ].includes(keyword)
    ) {
      pendingAnnotation = "";
      index += 1;
      continue;
    }

    const definitionName = topLevelDefinitionName(trimmed);
    if (definitionName) {
      const captured = captureDeclarationSource(lines, index);
      const segment = [pendingAnnotation, captured.source].filter(Boolean).join("\n");
      fingerprints[definitionName] = fnvParts([segment]);
      pendingAnnotation = "";
      index = captured.nextIndex;
      continue;
    }

    pendingAnnotation = "";
    index += 1;
  }
  return fingerprints;
}

function loadBundle(entryPath) {
  const root = path.dirname(entryPath);
  const byPath = new Map();
  const discovered = new Set();
  let pending = [entryPath];

  while (pending.length > 0) {
    const current = fs.realpathSync(pending.shift());
    if (discovered.has(current)) continue;
    discovered.add(current);
    const source = fs.readFileSync(current, "utf8");
    const moduleName = parseModuleName(source);
    const imports = parseImports(source);
    const importPaths = imports.map((importName) =>
      path.join(root, `${importName.replaceAll(".", "/")}.clasp`),
    );
    byPath.set(current, { path: current, source, moduleName, imports, importPaths });
    for (const importPath of importPaths) {
      const resolved = fs.realpathSync(importPath);
      if (!discovered.has(resolved)) pending.push(resolved);
    }
    pending = [...new Set(pending.map((item) => fs.realpathSync(item)))].sort();
  }

  const bundled = [];
  const seen = new Set();
  function append(currentPath) {
    const resolved = fs.realpathSync(currentPath);
    if (seen.has(resolved)) return;
    const module = byPath.get(resolved);
    if (!module) fail(`missing module metadata for ${resolved}`);
    seen.add(resolved);
    bundled.push(module);
    for (const importPath of module.importPaths) append(importPath);
  }
  append(entryPath);
  return bundled;
}

function collectPostorder(moduleName, modulesByName, seen, ordered) {
  if (seen.has(moduleName)) return;
  const module = modulesByName.get(moduleName);
  if (!module) fail(`missing module ${moduleName}`);
  seen.add(moduleName);
  for (const importName of module.imports) collectPostorder(importName, modulesByName, seen, ordered);
  ordered.push(moduleName);
}

function generatePayload(entryPath) {
  const image = fs.readFileSync(compilerImagePath);
  const modules = loadBundle(entryPath).map((module) => ({
    ...module,
    sourceFingerprint: fnvBytes(Buffer.from(module.source)),
    summary: moduleSummaryFromAnnotations(module.source),
  }));
  const modulesByName = new Map(modules.map((module) => [module.moduleName, module]));
  const originalModuleOrder = modules.map((module) => module.moduleName);
  const entryModuleName = modules[0]?.moduleName;
  if (!entryModuleName) fail("entry project had no modules");

  const moduleOrder = [];
  collectPostorder(entryModuleName, modulesByName, new Set(), moduleOrder);

  const closures = new Map();
  function closure(moduleName, visiting = new Set()) {
    if (closures.has(moduleName)) return closures.get(moduleName);
    if (visiting.has(moduleName)) fail(`cycle at ${moduleName}`);
    visiting.add(moduleName);
    const module = modulesByName.get(moduleName);
    const result = new Set([moduleName]);
    for (const importName of module.imports) {
      for (const closureModuleName of closure(importName, visiting)) result.add(closureModuleName);
    }
    visiting.delete(moduleName);
    closures.set(moduleName, result);
    return result;
  }

  const interfaceFingerprints = new Map(
    modules.map((module) => [module.moduleName, conservativeModuleInterfaceFingerprint(module.moduleName)]),
  );
  const summaries = new Map();
  const entries = [];
  for (const moduleName of moduleOrder) {
    const module = modulesByName.get(moduleName);
    const closureSet = closure(moduleName);
    const importedModuleOrder = originalModuleOrder.filter(
      (name) => closureSet.has(name) && name !== moduleName,
    );
    const importedSummariesText = importedModuleOrder
      .map((name) => summaries.get(name))
      .filter((summary) => summary && summary.trim())
      .join("\n");
    const cacheKey = `${fnvParts([
      image,
      moduleName,
      interfaceFingerprints.get(moduleName),
      importedSummariesText,
      ...importedModuleOrder,
      ...importedModuleOrder.map((name) => interfaceFingerprints.get(name)),
    ])}.cache`;
    summaries.set(moduleName, module.summary);
    entries.push({
      moduleName,
      cacheKey,
      sourceFingerprint: module.sourceFingerprint,
      declFingerprints: moduleDeclValidationFingerprints(module.source),
      summary: module.summary,
    });
  }

  return {
    cacheVersion: "module-summary-cache-v2",
    source: path.relative(projectRoot, entryPath),
    generatedBy: "scripts/generate-promoted-module-summary-cache.mjs",
    summaries: entries,
  };
}

function main() {
  const options = parseArgs(process.argv);
  const payload = `${JSON.stringify(generatePayload(options.entryPath), null, 2)}\n`;
  if (options.check) {
    const current = fs.readFileSync(options.outputPath, "utf8");
    if (current !== payload) fail(`${path.relative(projectRoot, options.outputPath)} is stale`);
    console.log(`${path.relative(projectRoot, options.outputPath)} is up to date`);
    return;
  }
  fs.writeFileSync(options.outputPath, payload);
  console.log(`wrote ${path.relative(projectRoot, options.outputPath)}`);
}

main();
