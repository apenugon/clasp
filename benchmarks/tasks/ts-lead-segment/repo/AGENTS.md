# Benchmark Workspace Guidance

This task is intentionally local to this workspace.

- Stay inside this workspace unless `bash scripts/verify.sh` fails in a way that clearly points to a benchmark harness bug.
- Use the local files as the source of truth.
- Keep the solution minimal and preserve the server-rendered route flow.

Relevant files:

- `src/shared/lead.ts`: shared lead schema, decoders, and HTML rendering
- `src/server/main.ts`: server logic and in-memory state
- `test/lead-app.test.mjs`: exact required click-through behavior
- `scripts/verify.sh`: acceptance command

Preferred workflow:

1. Read `test/lead-app.test.mjs`
2. Update `src/shared/lead.ts`
3. Update `src/server/main.ts` only if the shared-contract change requires it
4. Run `bash scripts/verify.sh`
