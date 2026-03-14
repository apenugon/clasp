import assert from "node:assert/strict";

import { runAuditLogDemo } from "../src/main.mjs";

const result = await runAuditLogDemo();

assert.deepStrictEqual(result, {
  routeName: "releaseAuditRoute",
  toolName: "summarizeDraft",
  workflowName: "ApprovalFlow",
  secretBoundaryNames: ["AuditWorkerRole", "SearchTools"],
  typedEventKinds: [
    "TypedRouteAudit",
    "TypedToolAudit",
    "TypedWorkflowAudit",
    "TypedSecretAudit"
  ],
  routeRetentionDays: 30,
  toolRetentionDays: 30,
  workflowRetentionDays: 365,
  secretRetentionDays: 730,
  redactionSafe: true,
  routeRootCause: "route releaseAuditRoute -> policy AuditPolicy",
  toolRootCause: "tool summarizeDraft -> toolserver SearchTools -> policy AuditPolicy",
  workflowRootCause: "workflow ApprovalFlow -> route releaseAuditRoute",
  secretRootCause: "policy AuditPolicy secret OPENAI_API_KEY -> tool summarizeDraft",
  missingSecretBlame:
    "Missing secret SEARCH_API_TOKEN for toolServer SearchTools under policy AuditPolicy"
});

console.log(JSON.stringify(result));
