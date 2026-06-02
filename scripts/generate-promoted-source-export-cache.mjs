#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
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
const defaultNativeBundleJobs = "2";
const defaultNativeImageEntries = [
  {
    source: "examples/hello.clasp",
    exportName: "nativeImageSourceText",
    outputPath: "src/stage1.hello.native.image.json",
  },
  {
    source: "examples/promoted-project/Main.clasp",
    exportName: "nativeImageProjectText",
    outputPath: "src/stage1.promoted-project.native.image.json",
  },
];

function fail(message) {
  console.error(`generate-promoted-source-export-cache: ${message}`);
  process.exit(1);
}

function parseArgs(argv) {
  const options = {
    check: false,
    forceNativeImageRefresh: false,
    nativeImageEntries: [...defaultNativeImageEntries],
    outputPath: defaultOutputPath,
    refreshNativeImages: false,
    sources: [...defaultSources],
  };
  for (let index = 2; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--check") {
      options.check = true;
    } else if (arg === "--refresh-native-images") {
      options.refreshNativeImages = true;
    } else if (arg === "--force-native-image-refresh") {
      options.refreshNativeImages = true;
      options.forceNativeImageRefresh = true;
    } else if (arg === "--skip-native-image-refresh") {
      options.refreshNativeImages = false;
      options.forceNativeImageRefresh = false;
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
    if (!trimmed) continue;
    if (trimmed.startsWith("module ")) {
      const [, importedModules] = trimmed.split(" with ");
      if (importedModules) {
        for (const importName of importedModules.split(",").map((value) => value.trim())) {
          if (importName && !imports.includes(importName)) imports.push(importName);
        }
      }
    }
    break;
  }
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

function collectProjectBundleSourcePaths(entrySourcePath) {
  const { resolved } = normalizeSourcePath(entrySourcePath);
  const root = path.dirname(resolved);
  const seen = new Set();
  const ordered = [];

  function visit(sourcePath) {
    const canonical = fs.realpathSync(sourcePath);
    if (seen.has(canonical)) return;
    seen.add(canonical);
    ordered.push(canonical);
    const source = fs.readFileSync(canonical, "utf8");
    for (const importName of parseImports(source)) {
      const importPath = importPathFor(root, importName);
      if (!fs.existsSync(importPath)) fail(`missing import ${importName} from ${entrySourcePath}`);
      visit(importPath);
    }
  }

  visit(resolved);
  return ordered;
}

function buildProjectBundle(entrySourcePath) {
  return collectProjectBundleSourcePaths(entrySourcePath)
    .map((sourcePath) => fs.readFileSync(sourcePath, "utf8"))
    .join(projectBundleSeparator);
}

function nativeImageEntryCacheMetadata(entry) {
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

function nativeImageEntryPayload(entry) {
  return nativeImageEntryCacheMetadata(entry);
}

function resolveClaspcBin() {
  if (process.env.CLASPC_BIN) return process.env.CLASPC_BIN;
  return execFileSync(path.join(projectRoot, "scripts/resolve-claspc.sh"), {
    cwd: projectRoot,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "inherit"],
  }).trim();
}

function sourceExportCacheEntryMatches(entry, sourceExportCachePath) {
  if (!fs.existsSync(sourceExportCachePath)) return false;
  let cache;
  try {
    cache = JSON.parse(fs.readFileSync(sourceExportCachePath, "utf8"));
  } catch (_error) {
    return false;
  }
  if (!Array.isArray(cache.entries)) return false;
  const expected = nativeImageEntryCacheMetadata(entry);
  return cache.entries.some((candidate) =>
    candidate &&
    candidate.source === expected.source &&
    candidate.exportName === expected.exportName &&
    candidate.cacheKey === expected.cacheKey &&
    candidate.outputPath === expected.outputPath
  );
}

function nativeImageEntryNeedsRefresh(entry, sourceExportCachePath) {
  const { resolved: outputResolved } = normalizeSourcePath(entry.outputPath);
  if (!fs.existsSync(outputResolved)) return true;
  if (!sourceExportCacheEntryMatches(entry, sourceExportCachePath)) return true;
  const outputMtimeMs = fs.statSync(outputResolved).mtimeMs;
  return collectProjectBundleSourcePaths(entry.source).some(
    (sourcePath) => fs.statSync(sourcePath).mtimeMs > outputMtimeMs + 1
  );
}

function refreshNativeImageEntries(nativeImageEntries, sourceExportCachePath, forceRefresh) {
  if (nativeImageEntries.length === 0) return;
  const claspcBin = resolveClaspcBin();
  for (const entry of nativeImageEntries) {
    if (!forceRefresh && !nativeImageEntryNeedsRefresh(entry, sourceExportCachePath)) continue;
    const { relative: sourceRelative } = normalizeSourcePath(entry.source);
    const { relative: outputRelative } = normalizeSourcePath(entry.outputPath);
    const env = {
      ...process.env,
      CLASP_PROJECT_ROOT: projectRoot,
      CLASP_NATIVE_BUNDLE_JOBS: process.env.CLASP_NATIVE_BUNDLE_JOBS || defaultNativeBundleJobs,
      CLASP_NATIVE_IMAGE_SECTION_JOBS: process.env.CLASP_NATIVE_IMAGE_SECTION_JOBS || "1",
      CLASP_NATIVE_IMAGE_MODULE_DECL_FRESH_PROCESS:
        process.env.CLASP_NATIVE_IMAGE_MODULE_DECL_FRESH_PROCESS || "0",
      CLASP_NATIVE_IMAGE_MODULE_DECL_CHUNK_SIZE:
        process.env.CLASP_NATIVE_IMAGE_MODULE_DECL_CHUNK_SIZE || "8",
      CLASP_NATIVE_IMAGE_MONOLITHIC_DECL_THRESHOLD:
        process.env.CLASP_NATIVE_IMAGE_MONOLITHIC_DECL_THRESHOLD || "999999",
      CLASP_NATIVE_RELAXED_BUILD_PLAN_CACHE: process.env.CLASP_NATIVE_RELAXED_BUILD_PLAN_CACHE || "0",
      CLASP_NATIVE_DISABLE_NATIVE_IMAGE_CACHE: "1",
      CLASP_NATIVE_DISABLE_SOURCE_EXPORT_CACHE: "1",
      CLASP_NATIVE_DISABLE_PROMOTED_SOURCE_EXPORT_CACHE: "1",
    };
    if (process.env.CLASP_NATIVE_DISABLE_EXPORT_HOST !== "0") {
      env.CLASP_NATIVE_DISABLE_EXPORT_HOST = process.env.CLASP_NATIVE_DISABLE_EXPORT_HOST || "1";
    }
    execFileSync(claspcBin, ["native-image", sourceRelative, "-o", outputRelative], {
      cwd: projectRoot,
      env,
      stdio: "inherit",
    });
  }
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
  if (!options.check && options.refreshNativeImages) {
    refreshNativeImageEntries(
      options.nativeImageEntries,
      options.outputPath,
      options.forceNativeImageRefresh
    );
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
