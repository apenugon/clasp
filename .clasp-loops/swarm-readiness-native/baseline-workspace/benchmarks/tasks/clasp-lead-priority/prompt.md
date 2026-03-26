# Task: Add Priority Hint Across the Clasp Lead Summary App

The repository models a small Clasp app with:

- shared record schemas
- a typed HTTP route
- a mock LLM/runtime binding that returns raw JSON

Implement priority propagation end to end.

## Working Guidance

- This task is intentionally local to the workspace.
- Start with `test/priority.test.mjs` and `app/Shared/Lead.clasp`.
- Do not inspect the parent repo unless `bash scripts/verify.sh` exposes a compiler/runtime bug rather than an app bug.
- The intended app-level fix is to express the constraint in the shared schema.
- Relevant Clasp syntax for this task:
  - `type Priority = Low | Medium | High`
  - `record LeadRequest = { ..., priorityHint : Priority }`
  - `record LeadSummary = { ..., priority : Priority }`

## Requirements

- Extend `LeadRequest` so requests carry a `priorityHint`.
- Extend `LeadSummary` so responses carry a `priority`.
- Restrict both fields to the priority values `low`, `medium`, and `high`.
- Preserve the existing `summary` and `followUpRequired` behavior.
- The route should still validate request input and response output through the generated Clasp codecs.
- The `priorityHint` provided by the request should flow through the mock model boundary and appear in the final response.
- Missing or invalid `priorityHint` values should be rejected at the request boundary.
- Invalid `priority` values coming back from the mock model boundary should be rejected before they reach the final HTTP response.

## Constraints

- Keep the codebase small and readable.
- Preserve the route and foreign-boundary structure.
- Do not bypass validation with unchecked JavaScript edits around the compiled output.

## Acceptance

The task is complete when `bash scripts/verify.sh` passes.
