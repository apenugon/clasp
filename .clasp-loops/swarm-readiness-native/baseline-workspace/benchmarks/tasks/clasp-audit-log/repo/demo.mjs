import path from "node:path";
import { pathToFileURL } from "node:url";

function requiredEntry(entries, name, label) {
  const found = entries.find((entry) => entry.name === name);

  if (!found) {
    throw new Error(`Missing ${label} ${name}`);
  }

  return found;
}

export async function runAuditLogDemo(compiledModulePath) {
  const compiledModule = await import(pathToFileURL(path.resolve(compiledModulePath)).href);
  const snapshot = JSON.parse(compiledModule.auditSnapshotJson);
  const route = requiredEntry(compiledModule.__claspRoutes ?? [], "releaseAuditRoute", "route");
  const tool = requiredEntry(compiledModule.__claspTools ?? [], "summarizeDraft", "tool");
  const workflow = requiredEntry(compiledModule.__claspWorkflows ?? [], "ApprovalFlow", "workflow");
  const boundaries = compiledModule.__claspSecretBoundaries ?? [];

  return {
    routeName: route.name,
    toolName: tool.name,
    workflowName: workflow.name,
    secretBoundaryNames: boundaries.map((boundary) => boundary.name).sort(),
    typedEventKinds: snapshot.typedEventKinds,
    routeRetentionDays: snapshot.routeEvent.retentionDays,
    toolRetentionDays: snapshot.toolEvent.retentionDays,
    workflowRetentionDays: snapshot.workflowEvent.retentionDays,
    secretRetentionDays: snapshot.secretEvent.retentionDays,
    redactionSafe:
      !JSON.stringify(snapshot).includes("sk-live-openai") &&
      !JSON.stringify(snapshot).includes("ops@example.com"),
    routeRootCause: snapshot.routeEvent.rootCause,
    toolRootCause: snapshot.toolEvent.rootCause,
    workflowRootCause: snapshot.workflowEvent.rootCause,
    secretRootCause: snapshot.secretEvent.rootCause,
    missingSecretBlame: snapshot.missingSecretBlame
  };
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;

if (invokedPath === path.resolve(new URL(import.meta.url).pathname)) {
  const compiledModulePath = process.argv[2];

  if (!compiledModulePath) {
    throw new Error("usage: node demo.mjs <compiled-module>");
  }

  console.log(JSON.stringify(await runAuditLogDemo(compiledModulePath)));
}
