import { readFileSync, readdirSync, statSync, existsSync } from "node:fs";
import { join, relative, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const evalRoot = fileURLToPath(new URL(".", import.meta.url));
const [, , startArg, solutionArg, compiledArg, contextArg, airArg, baselineResultArg, semanticResultArg] = process.argv;

if (!startArg || !solutionArg || !compiledArg || !contextArg || !airArg || !baselineResultArg || !semanticResultArg) {
  console.error(
    "usage: node compare.mjs <start-dir> <solution-dir> <compiled.js> <context.json> <air.json> <baseline-result.json> <semantic-result.json>"
  );
  process.exit(2);
}

const startDir = resolve(process.cwd(), startArg);
const solutionDir = resolve(process.cwd(), solutionArg);
const compiledPath = resolve(process.cwd(), compiledArg);
const contextPath = resolve(process.cwd(), contextArg);
const airPath = resolve(process.cwd(), airArg);
const baselineResultPath = resolve(process.cwd(), baselineResultArg);
const semanticResultPath = resolve(process.cwd(), semanticResultArg);
const taskPath = join(evalRoot, "TASK.md");

for (const required of [startDir, solutionDir, compiledPath, contextPath, airPath, baselineResultPath, semanticResultPath, taskPath]) {
  if (!existsSync(required)) {
    console.error(`missing required input: ${required}`);
    process.exit(2);
  }
}

function listFiles(root) {
  const out = [];
  for (const entry of readdirSync(root, { withFileTypes: true })) {
    const fullPath = join(root, entry.name);
    if (entry.isDirectory()) {
      out.push(...listFiles(fullPath));
    } else if (entry.isFile()) {
      out.push(fullPath);
    }
  }
  return out.sort();
}

function countLines(text) {
  if (text.length === 0) {
    return 0;
  }
  return text.split(/\r?\n/).length;
}

function estimateTokens(text) {
  return Math.ceil(Buffer.byteLength(text, "utf8") / 4);
}

function formatSpan(span) {
  if (!span?.file || !span?.start?.line) {
    return null;
  }
  return `${span.file}:${span.start.line}`;
}

function attrValue(node, name) {
  return node?.attrs?.find((attr) => attr.name === name)?.value;
}

function stableString(value) {
  return JSON.stringify(value, null, 2);
}

function summarizeFields(fields) {
  return fields.map((field) => `${field.name}:${field.type}`).join(", ");
}

const taskText = readFileSync(taskPath, "utf8").trim();
const startFiles = listFiles(startDir).filter((file) => file.endsWith(".clasp"));
const solutionFiles = listFiles(solutionDir).filter((file) => file.endsWith(".clasp"));

const changedFiles = startFiles
  .map((file) => relative(startDir, file))
  .filter((relativePath) => {
    const startText = readFileSync(join(startDir, relativePath), "utf8");
    const solutionText = readFileSync(join(solutionDir, relativePath), "utf8");
    return startText !== solutionText;
  });

const rawSourceSections = startFiles.map((file) => {
  const relativePath = relative(startDir, file);
  return `== ${relativePath} ==\n${readFileSync(file, "utf8").trim()}`;
});

const rawBundle = [`# Task`, taskText, `# Repo Source`, ...rawSourceSections].join("\n\n");

const compiled = await import(`${pathToFileURL(compiledPath).href}?t=${Date.now()}`);
const context = JSON.parse(readFileSync(contextPath, "utf8"));
const air = JSON.parse(readFileSync(airPath, "utf8"));
const baselineResult = JSON.parse(readFileSync(baselineResultPath, "utf8"));
const semanticResult = JSON.parse(readFileSync(semanticResultPath, "utf8"));

const focusSchemaNames = ["LeadIntake", "LeadSummary", "LeadPlaybookLookup", "LeadPlaybook", "LeadFollowUpState"];
const focusRouteNames = ["summarizeLeadApi"];
const focusToolNames = ["lookupLeadPlaybook"];
const focusWorkflowNames = ["LeadFollowUpFlow"];
const focusDeclNames = ["summarizeLead", "playbookRequest", "main"];

const appSchemaNodes = context.nodes
  .filter((node) => node.kind === "schema" && attrValue(node, "builtin") !== true && focusSchemaNames.includes(attrValue(node, "name")))
  .map((node) => {
    const schemaName = attrValue(node, "name");
    const fieldNodes = context.nodes
      .filter((candidate) => candidate.kind === "schemaField" && attrValue(candidate, "schemaName") === schemaName)
      .map((candidate) => ({ name: attrValue(candidate, "name"), type: attrValue(candidate, "type") }))
      .sort((left, right) => left.name.localeCompare(right.name));
    return {
      name: schemaName,
      location: formatSpan(node.span),
      fields: fieldNodes
    };
  });

const routeTargets = focusRouteNames
  .map((name) => context.nodes.find((node) => node.kind === "route" && attrValue(node, "name") === name))
  .filter(Boolean)
  .map((node) => ({
    name: attrValue(node, "name"),
    location: formatSpan(node.span),
    method: attrValue(node, "method"),
    path: attrValue(node, "path"),
    requestType: attrValue(node, "requestType"),
    responseType: attrValue(node, "responseType")
  }));

const toolTargets = focusToolNames
  .map((name) => context.nodes.find((node) => node.kind === "tool" && attrValue(node, "name") === name))
  .filter(Boolean)
  .map((node) => ({
    name: attrValue(node, "name"),
    location: formatSpan(node.span),
    requestType: attrValue(node, "requestType"),
    responseType: attrValue(node, "responseType")
  }));

const workflowTargets = compiled.__claspWorkflows
  .filter((workflow) => focusWorkflowNames.includes(workflow.name))
  .map((workflow) => ({
    name: workflow.name,
    stateType: workflow.stateType
  }));

const airDeclNodes = air.nodes
  .filter((node) => node.kind === "decl" && focusDeclNames.includes(node.attrs?.find((attr) => attr.name === "name")?.value))
  .map((node) => ({
    name: attrValue(node, "name"),
    type: node.type
  }));

const semanticBriefLines = [
  "# Task",
  taskText,
  "",
  "# Clasp Semantic Brief",
  "Schemas:"
];

for (const schema of appSchemaNodes) {
  semanticBriefLines.push(`- ${schema.name} @ ${schema.location ?? "unknown"} => { ${summarizeFields(schema.fields)} }`);
}

semanticBriefLines.push("Routes:");
for (const route of routeTargets) {
  semanticBriefLines.push(
    `- ${route.name} @ ${route.location ?? "unknown"} => ${route.method} ${route.path} ${route.requestType} -> ${route.responseType}`
  );
}

semanticBriefLines.push("Tools:");
for (const tool of toolTargets) {
  semanticBriefLines.push(`- ${tool.name} @ ${tool.location ?? "unknown"} => ${tool.requestType} -> ${tool.responseType}`);
}

semanticBriefLines.push("Workflows:");
for (const workflow of workflowTargets) {
  semanticBriefLines.push(`- ${workflow.name} => state ${workflow.stateType}`);
}

semanticBriefLines.push("Decls:");
for (const decl of airDeclNodes) {
  semanticBriefLines.push(`- ${decl.name} : ${decl.type}`);
}

semanticBriefLines.push("Verification artifacts:");
semanticBriefLines.push(`- context nodes=${context.nodeCount} edges=${context.edgeCount}`);
semanticBriefLines.push(`- air roots=${air.roots.length} nodes=${air.nodeCount}`);

const semanticBrief = semanticBriefLines.join("\n");

const rawObservableSurfaces = ["compile", "main result"];
const claspObservableSurfaces = [
  "compile",
  "main result",
  "schema rename",
  "schema field shape",
  "tool request field shape",
  "route response contract",
  "workflow state contract",
  "context graph nodes",
  "context graph edges",
  "AIR roots"
];

const metrics = {
  eval: "lead-digest-upgrade",
  comparison: "raw-repo-vs-clasp-semantic-brief",
  taskText,
  oracle: {
    changedFiles,
    changedFileCount: changedFiles.length
  },
  rawRepo: {
    bundleBytes: Buffer.byteLength(rawBundle, "utf8"),
    estimatedTokens: estimateTokens(rawBundle),
    sourceFileCount: startFiles.length,
    sourceLineCount: startFiles
      .map((file) => countLines(readFileSync(file, "utf8")))
      .reduce((sum, count) => sum + count, 0),
    includedFiles: ["TASK.md", ...startFiles.map((file) => relative(startDir, file))],
    observableSurfaces: rawObservableSurfaces,
    observableSurfaceCount: rawObservableSurfaces.length
  },
  claspAware: {
    bundleBytes: Buffer.byteLength(semanticBrief, "utf8"),
    estimatedTokens: estimateTokens(semanticBrief),
    semanticTargetCount: appSchemaNodes.length + routeTargets.length + toolTargets.length + workflowTargets.length + airDeclNodes.length,
    semanticTargets: {
      schemas: appSchemaNodes.map((schema) => schema.name),
      routes: routeTargets.map((route) => route.name),
      tools: toolTargets.map((tool) => tool.name),
      workflows: workflowTargets.map((workflow) => workflow.name),
      decls: airDeclNodes.map((decl) => decl.name)
    },
    observableSurfaces: claspObservableSurfaces,
    observableSurfaceCount: claspObservableSurfaces.length,
    artifactKinds: ["compiled-manifest", "context-graph", "air"],
    startFailureIssueCount: semanticResult.issueCount,
    startFailureIssues: semanticResult.issues
  },
  baselineValidator: {
    startFailureIssueCount: baselineResult.issueCount,
    startFailureIssues: baselineResult.issues
  },
  deltas: {
    bundleBytesSaved: Buffer.byteLength(rawBundle, "utf8") - Buffer.byteLength(semanticBrief, "utf8"),
    estimatedTokensSaved: estimateTokens(rawBundle) - estimateTokens(semanticBrief),
    observableSurfaceGain: claspObservableSurfaces.length - rawObservableSurfaces.length,
    failureSignalGain: semanticResult.issueCount - baselineResult.issueCount
  },
  bundles: {
    rawRepoText: rawBundle,
    claspAwareText: semanticBrief,
    rawRepoPreview: rawBundle.slice(0, 400),
    claspAwarePreview: semanticBrief.slice(0, 400)
  }
};

console.log(stableString(metrics));
