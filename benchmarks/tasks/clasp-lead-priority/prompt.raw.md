# Task: Add Priority Hint Across the Clasp Lead Summary App

The repository models a small Clasp app with:

- shared record schemas
- a typed HTTP route
- a mock LLM/runtime binding that returns raw JSON

Implement priority propagation end to end.

## Working Guidance

- This task is intentionally local to the workspace.
- Start with the failing test and the shared lead contract.
- Use the generated benchmark-prep artifacts to understand routes, schemas, and runtime boundaries.
- Do not inspect the parent repo unless `bash scripts/verify.sh` exposes a compiler/runtime bug rather than an app bug.
- The expected fix should live on the app-owned schema surface, not in generated output or benchmark harness glue.

## Requirements

- Extend incoming lead summary requests so callers provide a priority hint.
- Extend outgoing lead summaries so the final response includes the validated priority.
- Restrict priority values to `low`, `medium`, and `high`.
- Preserve the existing `summary` and `followUpRequired` behavior.
- The route should still validate request input and response output through the generated Clasp codecs.
- The priority hint provided by the request should flow through the mock model boundary and appear in the final response.
- Missing or invalid priority hints should be rejected at the request boundary.
- Invalid priority values coming back from the mock model boundary should be rejected before they reach the final HTTP response.

## Constraints

- Keep the codebase small and readable.
- Preserve the route and foreign-boundary structure.
- Do not bypass validation with unchecked JavaScript edits around the compiled output.

## Acceptance

The task is complete when `bash scripts/verify.sh` passes.
