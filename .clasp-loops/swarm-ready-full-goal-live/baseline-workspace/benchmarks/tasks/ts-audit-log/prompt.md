# Task: Repair The Handwritten Audit Log Surface Without Losing Type, Redaction, Retention, Or Traceability

This repository models one narrow handwritten baseline around typed audit logging.

The current implementation is too incomplete for the mirrored audit-log scenario. Fix the local JavaScript surface so the benchmark proves all of the following at once:

- typed audit events stay distinct across route access, tool calls, workflow transitions, and secret access
- redaction policy keeps raw secret and customer values out of the published audit snapshot
- retention rules stay explicit per event kind
- root-cause traceability points back to the declaring route, tool, workflow, and secret policy surfaces

## Working Guidance

- This task is intentionally local to the workspace.
- Start with `test/audit-log.test.mjs` and `src/main.mjs`.
- Keep the solution explicit and readable. The intended fix is in the handwritten source, not in the test.

## Requirements

- Keep the route, tool server, workflow, policy, and role wiring intact.
- Preserve the existing approval policy and sandbox policy.
- Return the same typed event kinds, retention days, and missing-secret blame string as the mirrored Clasp task.
- The published audit snapshot must not contain `sk-live-openai` or `ops@example.com`.

## Constraints

- Keep the codebase small and readable.
- Do not patch the test to bypass missing declarations.

## Acceptance

The task is complete when `node test/audit-log.test.mjs` passes.
