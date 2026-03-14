# Task: Add SQLite-Backed Persistence To The Clickable Inbox App

The repository models a browser-runnable lead inbox with:

- a server-rendered HTML intake form
- a clickable inbox page and lead detail pages
- a shared lead contract already carrying `segment`
- an in-memory server implementation that loses state between restarts

Make the app durable with SQLite and reject incompatible on-disk schema state.

## Working Guidance

- This task is intentionally local to the workspace.
- Start with `test/lead-app.test.mjs` and `src/server/main.ts`.
- Do not inspect the parent repo unless `bash scripts/verify.sh` exposes a benchmark harness or language-runtime bug rather than an app bug.
- Keep the accepted change on the app surface; do not edit benchmark-only scaffolding unless verification proves it is wrong.

## Requirements

- Persist created and reviewed leads in SQLite instead of process-local memory.
- Keep the existing server-rendered route flow and review behavior intact.
- Preserve the seeded leads on first boot, but do not duplicate them on later boots.
- Keep `createServer(..., { databasePath })` as the path used by tests and local runtime entry points.
- Reject incompatible database schema versions with a clear error before the server starts serving requests.
- Keep the solution small and readable.

## Constraints

- Do not bypass the failure-mode requirement by swallowing schema errors.
- Do not replace the existing route structure or HTML flow.
- Do not edit generated artifacts directly.

## Acceptance

The task is complete when `bash scripts/verify.sh` passes.
