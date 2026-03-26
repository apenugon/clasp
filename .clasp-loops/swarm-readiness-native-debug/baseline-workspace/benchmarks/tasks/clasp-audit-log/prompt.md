# Task: Repair The Clasp Audit Log Surface Without Losing Type, Redaction, Retention, Or Traceability

This repository models one narrow `Clasp` benchmark around typed audit logging.

The current declarations are too incomplete for the mirrored audit-log scenario. Fix the local `Clasp` surface so the benchmark proves all of the following at once:

- typed audit events stay distinct across route access, tool calls, workflow transitions, and secret access
- redaction policy keeps raw secret and customer values out of the published audit snapshot
- retention rules stay explicit per event kind
- root-cause traceability points back to the declaring route, tool, workflow, and secret policy surfaces

## Working Guidance

- This task is intentionally local to the workspace.
- Start with `test/audit-log.test.mjs` and `Main.clasp`.
- Keep the fix declarative. The intended change is in the `Clasp` declarations, not in the JavaScript demo or test.

## Requirements

- Keep the route, tool server, workflow, policy, and role wiring intact.
- Preserve the existing approval policy and sandbox policy.
- The route event kind must be `TypedRouteAudit`.
- The tool event kind must be `TypedToolAudit`.
- The workflow event kind must be `TypedWorkflowAudit`.
- The secret event kind must be `TypedSecretAudit`.
- The published audit snapshot must not contain `sk-live-openai` or `ops@example.com`.
- Retention must stay `30` days for the route and tool events, `365` for the workflow event, and `730` for the secret event.
- The exact missing-secret blame string must remain:
  `Missing secret SEARCH_API_TOKEN for toolServer SearchTools under policy AuditPolicy`

## Constraints

- Keep the codebase small and readable.
- Do not patch the JavaScript demo or test to bypass missing declarations.

## Acceptance

The task is complete when `bash scripts/verify.sh` passes.
