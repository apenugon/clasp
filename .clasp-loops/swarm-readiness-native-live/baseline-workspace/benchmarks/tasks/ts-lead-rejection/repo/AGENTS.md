# Benchmark Workspace Guidance

This task is intentionally local to this workspace.

- Stay inside this workspace unless `bash scripts/verify.sh` fails in a way that clearly points to a benchmark harness bug.
- Use the local files as the source of truth.
- Keep the solution minimal and preserve the route/model-boundary structure.

Relevant files:

- `src/shared/lead.ts`: shared request/response schema, decoders, and intended edit surface
- `src/server/main.ts`: route handler, usually unchanged
- `src/server/runtime.ts`: model boundary helpers, usually unchanged
- `test/rejection.test.mjs`: exact required behavior
- `scripts/verify.sh`: acceptance command

Preferred workflow:

1. Read `test/rejection.test.mjs`
2. Update `src/shared/lead.ts`
3. Run `bash scripts/verify.sh`
