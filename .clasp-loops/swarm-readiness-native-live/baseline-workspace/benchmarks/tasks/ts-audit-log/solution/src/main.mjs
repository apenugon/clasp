const route = Object.freeze({
  name: "releaseAuditRoute",
  path: "/release/audit"
});

const tool = Object.freeze({
  name: "summarizeDraft",
  server: "SearchTools"
});

const workflow = Object.freeze({
  name: "ApprovalFlow"
});

const secretBoundaries = Object.freeze(["AuditWorkerRole", "SearchTools"]);

function createSnapshot() {
  return Object.freeze({
    typedEventKinds: Object.freeze([
      "TypedRouteAudit",
      "TypedToolAudit",
      "TypedWorkflowAudit",
      "TypedSecretAudit"
    ]),
    routeEvent: Object.freeze({
      kind: "TypedRouteAudit",
      retentionDays: 30,
      rootCause: "route releaseAuditRoute -> policy AuditPolicy"
    }),
    toolEvent: Object.freeze({
      kind: "TypedToolAudit",
      retentionDays: 30,
      rootCause: "tool summarizeDraft -> toolserver SearchTools -> policy AuditPolicy"
    }),
    workflowEvent: Object.freeze({
      kind: "TypedWorkflowAudit",
      retentionDays: 365,
      rootCause: "workflow ApprovalFlow -> route releaseAuditRoute"
    }),
    secretEvent: Object.freeze({
      kind: "TypedSecretAudit",
      retentionDays: 730,
      rootCause: "policy AuditPolicy secret OPENAI_API_KEY -> tool summarizeDraft"
    }),
    missingSecretBlame:
      "Missing secret SEARCH_API_TOKEN for toolServer SearchTools under policy AuditPolicy"
  });
}

export async function runAuditLogDemo() {
  const snapshot = createSnapshot();
  const snapshotJson = JSON.stringify(snapshot);

  return {
    routeName: route.name,
    toolName: tool.name,
    workflowName: workflow.name,
    secretBoundaryNames: [...secretBoundaries].sort(),
    typedEventKinds: [...snapshot.typedEventKinds],
    routeRetentionDays: snapshot.routeEvent.retentionDays,
    toolRetentionDays: snapshot.toolEvent.retentionDays,
    workflowRetentionDays: snapshot.workflowEvent.retentionDays,
    secretRetentionDays: snapshot.secretEvent.retentionDays,
    redactionSafe:
      !snapshotJson.includes("sk-live-openai") &&
      !snapshotJson.includes("ops@example.com"),
    routeRootCause: snapshot.routeEvent.rootCause,
    toolRootCause: snapshot.toolEvent.rootCause,
    workflowRootCause: snapshot.workflowEvent.rootCause,
    secretRootCause: snapshot.secretEvent.rootCause,
    missingSecretBlame: snapshot.missingSecretBlame
  };
}
