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
    typedEventKinds: Object.freeze(["route", "tool", "workflow"]),
    routeEvent: Object.freeze({
      kind: "route",
      retentionDays: 7,
      rootCause: "route releaseAuditRoute"
    }),
    toolEvent: Object.freeze({
      kind: "tool",
      retentionDays: 7,
      rootCause: "tool summarizeDraft"
    }),
    workflowEvent: Object.freeze({
      kind: "workflow",
      retentionDays: 30,
      rootCause: "workflow ApprovalFlow"
    }),
    secretEvent: Object.freeze({
      kind: "secret",
      retentionDays: 30,
      rootCause: "OPENAI_API_KEY"
    }),
    missingSecretBlame: "Missing secret OPENAI_API_KEY"
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
