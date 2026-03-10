# Task: Add Priority Hint Across the Weft Lead Summary App

The repository models a small Weft app with:

- shared record schemas
- a typed HTTP route
- a mock LLM/runtime binding that returns raw JSON

Implement priority propagation end to end.

## Requirements

- Extend `LeadRequest` so requests carry a `priorityHint`.
- Extend `LeadSummary` so responses carry a `priority`.
- Preserve the existing `summary` and `followUpRequired` behavior.
- The route should still validate request input and response output through the generated Weft codecs.
- The `priorityHint` provided by the request should flow through the mock model boundary and appear in the final response.

## Constraints

- Keep the codebase small and readable.
- Preserve the route and foreign-boundary structure.
- Do not bypass validation with unchecked JavaScript edits around the compiled output.

## Acceptance

The task is complete when `bash scripts/verify.sh` passes.
