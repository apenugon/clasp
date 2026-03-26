import { existsSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const evalRoot = dirname(fileURLToPath(import.meta.url));
const [, , candidateArg, compiledArg, contextArg, airArg] = process.argv;

if (!candidateArg || !compiledArg || !contextArg || !airArg) {
  console.error("usage: node validate.mjs <candidate-dir> <compiled.js> <context.json> <air.json>");
  process.exit(2);
}

const candidateDir = resolve(process.cwd(), candidateArg);
const compiledPath = resolve(process.cwd(), compiledArg);
const contextPath = resolve(process.cwd(), contextArg);
const airPath = resolve(process.cwd(), airArg);

function fail(message) {
  throw new Error(message);
}

const issues = [];

function ensure(condition, message) {
  if (!condition) {
    issues.push(message);
  }
}

function attrValue(node, name) {
  return node?.attrs?.find((attr) => attr.name === name)?.value;
}

async function loadCompiledModule(compiledPath) {
  const moduleUrl = `${pathToFileURL(compiledPath).href}?t=${Date.now()}`;
  return import(moduleUrl);
}

ensure(existsSync(candidateDir), `candidate directory does not exist: ${candidateDir}`);
ensure(existsSync(compiledPath), `compiled module does not exist: ${compiledPath}`);
ensure(existsSync(contextPath), `context graph does not exist: ${contextPath}`);
ensure(existsSync(airPath), `air output does not exist: ${airPath}`);

const compiled = await loadCompiledModule(compiledPath);
const context = JSON.parse(readFileSync(contextPath, "utf8"));
const air = JSON.parse(readFileSync(airPath, "utf8"));

const route = compiled.__claspRoutes.find((candidate) => candidate.name === "summarizeLeadApi");
const tool = compiled.__claspTools.find((candidate) => candidate.name === "lookupLeadPlaybook");
const workflow = compiled.__claspWorkflows.find((candidate) => candidate.name === "LeadFollowUpFlow");

ensure(route, "missing summarizeLeadApi route contract");
ensure(tool, "missing lookupLeadPlaybook tool contract");
ensure(workflow, "missing LeadFollowUpFlow workflow contract");

ensure(compiled.main === "senior-ae", `expected compiled main to be \"senior-ae\", got ${JSON.stringify(compiled.main)}`);

ensure("LeadDigest" in compiled.__claspSchemas, "expected LeadDigest schema to exist");
ensure(!("LeadSummary" in compiled.__claspSchemas), "expected LeadSummary schema to be removed");

const digestSchema = compiled.__claspSchemas.LeadDigest?.schema;
const digestFieldNames = digestSchema ? Object.keys(digestSchema.fields).sort() : [];
ensure(digestSchema, "expected LeadDigest schema metadata to be available");
if (digestSchema) {
  ensure(
    JSON.stringify(digestFieldNames) === JSON.stringify(["company", "needsFollowUp", "owner", "priorityLabel"]),
    `unexpected LeadDigest fields: ${digestFieldNames.join(", ")}`
  );
  ensure(digestSchema.fields.owner?.schema?.kind === "str", "LeadDigest.owner should be a string");
  ensure(digestSchema.fields.needsFollowUp?.schema?.kind === "bool", "LeadDigest.needsFollowUp should be a bool");
}

const toolRequestFieldNames = tool?.requestSchema ? Object.keys(tool.requestSchema.fields).sort() : [];
if (tool?.requestSchema) {
  ensure(
    JSON.stringify(toolRequestFieldNames) === JSON.stringify(["needsFollowUp", "owner"]),
    `unexpected LeadPlaybookLookup fields: ${toolRequestFieldNames.join(", ")}`
  );
}

if (route) {
  ensure(route.responseType === "LeadDigest", `expected route response type LeadDigest, got ${route.responseType}`);
  ensure(route.responseDecl?.schema?.name === "LeadDigest", "expected route response schema LeadDigest");
}
if (tool) {
  ensure(tool.requestType === "LeadPlaybookLookup", `expected tool request type LeadPlaybookLookup, got ${tool.requestType}`);
  ensure(tool.responseType === "LeadPlaybook", `expected tool response type LeadPlaybook, got ${tool.responseType}`);
}

if (workflow) {
  ensure(workflow.stateType === "LeadFollowUpState", `expected workflow state type LeadFollowUpState, got ${workflow.stateType}`);
}
ensure(
  compiled.__claspSchemas.LeadFollowUpState?.schema?.fields.digest?.schema?.name === "LeadDigest",
  "expected LeadFollowUpState.digest to reference LeadDigest"
);

const contextNodeIds = new Set(context.nodes.map((node) => node.id));
ensure(contextNodeIds.has("schema:LeadDigest"), "context graph is missing schema:LeadDigest");
ensure(!contextNodeIds.has("schema:LeadSummary"), "context graph should not contain schema:LeadSummary");

const contextRoute = context.nodes.find((node) => node.id === "route:summarizeLeadApi");
const contextTool = context.nodes.find((node) => node.id === "tool:lookupLeadPlaybook");
ensure(contextRoute, "context graph is missing route:summarizeLeadApi");
ensure(contextTool, "context graph is missing tool:lookupLeadPlaybook");
ensure(attrValue(contextRoute, "responseType") === "LeadDigest", "context route responseType should be LeadDigest");
ensure(attrValue(contextTool, "requestType") === "LeadPlaybookLookup", "context tool requestType should be LeadPlaybookLookup");

const routeResponseEdge = context.edges.find(
  (edge) => edge.from === "route:summarizeLeadApi" && edge.kind === "route-response-schema" && edge.to === "schema:LeadDigest"
);
ensure(routeResponseEdge, "context graph is missing the route-response-schema edge to schema:LeadDigest");

const airRootIds = new Set(air.roots);
ensure(airRootIds.has("record:LeadDigest"), "AIR roots are missing record:LeadDigest");
ensure(!airRootIds.has("record:LeadSummary"), "AIR roots should not contain record:LeadSummary");
ensure(airRootIds.has("route:summarizeLeadApi"), "AIR roots are missing route:summarizeLeadApi");
ensure(airRootIds.has("tool:lookupLeadPlaybook"), "AIR roots are missing tool:lookupLeadPlaybook");

if (issues.length > 0) {
  console.log(
    JSON.stringify(
      {
        status: "error",
        eval: "lead-digest-upgrade",
        candidateDir,
        issueCount: issues.length,
        issues
      },
      null,
      2
    )
  );
  process.exit(1);
}

console.log(
  JSON.stringify(
    {
      status: "ok",
      eval: "lead-digest-upgrade",
      candidateDir,
      main: compiled.main,
      routeResponseType: route.responseType,
      toolRequestFields: toolRequestFieldNames,
      workflowStateType: workflow.stateType,
      digestFields: digestFieldNames
    },
    null,
    2
  )
);
