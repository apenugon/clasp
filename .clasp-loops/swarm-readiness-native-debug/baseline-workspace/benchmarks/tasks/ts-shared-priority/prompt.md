# Task: Add Task Priority Everywhere

The repository models a tiny shared-type TypeScript app with server logic and client rendering.

Implement task priorities end to end.

## Requirements

- Extend the shared task model so tasks carry a priority.
- Support the priority values `low`, `medium`, and `high`.
- `createTask` should accept an optional priority input.
- If priority is omitted, default it to `medium`.
- Persist the priority in the in-memory task store.
- Update client rendering so each task includes a priority badge with a CSS-like class such as `priority-high`.
- The rendered text should include a human-readable label such as `High priority`.

## Constraints

- Keep the codebase small and readable.
- Do not remove existing behavior.
- Use the existing shared contract structure rather than duplicating types.

## Acceptance

The task is complete when `npm test` passes.

