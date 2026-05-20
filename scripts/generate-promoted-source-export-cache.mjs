#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const projectRoot = path.resolve(path.join(path.dirname(fileURLToPath(import.meta.url)), ".."));
const defaultOutputPath = path.join(projectRoot, "src/stage1.compiler.source-export-cache-v1.json");
const compilerImagePath = path.join(projectRoot, "src/stage1.compiler.native.image.json");
const defaultSources = [
  "examples/compiler-parser.clasp",
  "examples/compiler-checker.clasp",
  "examples/compiler-lower.clasp",
  "examples/compiler-emitter.clasp",
];
const projectBundleSeparator = "\n-- CLASP_PROJECT_MODULE --\n";
const defaultNativeImageEntries = [
  {
    source: "examples/swarm-native/GoalManager.clasp",
    exportName: "nativeImageProjectText",
    outputPath: "src/stage1.goal-manager.native.image.json",
  },
  {
    source: "examples/swarm-native/TaskWorkspaceRuntimeHarness.clasp",
    exportName: "nativeImageProjectText",
    outputPath: "src/stage1.task-workspace-runtime-harness.native.image.json",
  },
];

function fail(message) {
  console.error(`generate-promoted-source-export-cache: ${message}`);
  process.exit(1);
}

function parseArgs(argv) {
  const options = {
    check: false,
    nativeImageEntries: [...defaultNativeImageEntries],
    outputPath: defaultOutputPath,
    sources: [...defaultSources],
  };
  for (let index = 2; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--check") {
      options.check = true;
    } else if (arg === "--output") {
      index += 1;
      if (!argv[index]) fail("missing path after --output");
      options.outputPath = path.resolve(argv[index]);
    } else if (arg === "--source") {
      index += 1;
      if (!argv[index]) fail("missing path after --source");
      options.sources.push(argv[index]);
    } else if (arg === "--clear-default-sources") {
      options.sources = [];
    } else if (arg === "--clear-default-native-image-entries") {
      options.nativeImageEntries = [];
    } else {
      fail(`unknown argument: ${arg}`);
    }
  }
  return options;
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

function braceDelta(text) {
  return (text.match(/\{/g) || []).length - (text.match(/\}/g) || []).length;
}

function moduleSummaryFromAnnotations(source, sourcePath) {
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
  if (summaries.length === 0) {
    fail(`${sourcePath} did not contain top-level signatures for promoted checkSourceText output`);
  }
  return summaries.join("\n");
}

function normalizeSourcePath(sourcePath) {
  const resolved = path.resolve(projectRoot, sourcePath);
  const relative = path.relative(projectRoot, resolved).replace(/\\/g, "/");
  if (!relative || relative.startsWith("../") || path.isAbsolute(relative)) {
    fail(`source path must be inside project root: ${sourcePath}`);
  }
  return { resolved, relative };
}

function parseImports(source) {
  const imports = [];
  for (const line of source.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed.startsWith("import ")) continue;
    const importName = trimmed.slice("import ".length).trim();
    if (importName && !imports.includes(importName)) imports.push(importName);
  }
  return imports;
}

function importPathFor(root, importName) {
  return path.join(root, `${importName.replaceAll(".", path.sep)}.clasp`);
}

function buildProjectBundle(entrySourcePath) {
  const { resolved } = normalizeSourcePath(entrySourcePath);
  const root = path.dirname(resolved);
  const seen = new Set();
  const ordered = [];

  function visit(sourcePath) {
    const canonical = fs.realpathSync(sourcePath);
    if (seen.has(canonical)) return;
    seen.add(canonical);
    const source = fs.readFileSync(canonical, "utf8");
    ordered.push(source);
    for (const importName of parseImports(source)) {
      const importPath = importPathFor(root, importName);
      if (!fs.existsSync(importPath)) fail(`missing import ${importName} from ${entrySourcePath}`);
      visit(importPath);
    }
  }

  visit(resolved);
  return ordered.join(projectBundleSeparator);
}

function nativeImageEntryPayload(entry) {
  const { resolved: outputResolved, relative: outputRelative } = normalizeSourcePath(entry.outputPath);
  if (!fs.existsSync(outputResolved)) {
    fail(`native image output path is missing: ${entry.outputPath}`);
  }
  const imageText = fs.readFileSync(outputResolved, "utf8");
  try {
    const parsed = JSON.parse(imageText);
    if (parsed.format !== "clasp-native-image-v1") {
      fail(`${entry.outputPath} is not a clasp native image`);
    }
  } catch (error) {
    fail(`${entry.outputPath} is not valid JSON: ${error.message}`);
  }
  const bundle = buildProjectBundle(entry.source);
  return {
    source: normalizeSourcePath(entry.source).relative,
    exportName: entry.exportName,
    cacheKey: `${fnvParts([fs.readFileSync(compilerImagePath), entry.exportName, bundle])}.cache`,
    outputPath: outputRelative,
  };
}

function generatePayload(sourcePaths, nativeImageEntries) {
  const image = fs.readFileSync(compilerImagePath);
  const entries = sourcePaths.map((sourcePath) => {
    const { resolved, relative } = normalizeSourcePath(sourcePath);
    const source = fs.readFileSync(resolved, "utf8");
    const exportName = "checkSourceText";
    const output = moduleSummaryFromAnnotations(source, relative);
    return {
      source: relative,
      exportName,
      cacheKey: `${fnvParts([image, exportName, source])}.cache`,
      output,
    };
  });
  entries.push(...nativeImageEntries.map(nativeImageEntryPayload));

  return {
    cacheVersion: "source-export-cache-v1",
    generatedBy: "scripts/generate-promoted-source-export-cache.mjs",
    entries,
  };
}

function main() {
  const options = parseArgs(process.argv);
  const uniqueSources = [...new Set(options.sources)];
  if (uniqueSources.length === 0 && options.nativeImageEntries.length === 0) {
    fail("at least one source or native image entry is required");
  }
  const payload = `${JSON.stringify(generatePayload(uniqueSources, options.nativeImageEntries), null, 2)}\n`;
  if (options.check) {
    const current = fs.readFileSync(options.outputPath, "utf8");
    if (current !== payload) fail(`${path.relative(projectRoot, options.outputPath)} is stale`);
    console.log(`${path.relative(projectRoot, options.outputPath)} is up to date`);
    return;
  }
  fs.mkdirSync(path.dirname(options.outputPath), { recursive: true });
  fs.writeFileSync(options.outputPath, payload);
  console.log(`wrote ${path.relative(projectRoot, options.outputPath)}`);
}

main();
