# Task: Reject Invalid Priority Values at the Clasp Trust Boundary

The repository models a small Clasp app with:

- shared record schemas
- a typed HTTP route
- a mock LLM/runtime binding that returns raw JSON

Implement priority propagation with strict boundary rejection.

## Working Guidance

- This task is intentionally local to the workspace.
- Start with the failing rejection test and the shared lead contract.
- Use the generated benchmark-prep artifacts to identify request, response, and mock-model boundaries.
- Do not inspect the parent repo unless `bash scripts/verify.sh` exposes a compiler/runtime bug rather than an app bug.
- The expected fix should strengthen the app-owned schema surface instead of weakening the harness.

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
