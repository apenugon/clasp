# Benchmark Workspace Guidance

This task is intentionally local to this workspace.

- Stay inside this workspace unless `bash scripts/verify.sh` fails in a way that clearly points to a compiler/runtime bug.
- Use the local files as the source of truth.
- Keep the solution minimal and preserve the server-rendered route flow.

Relevant files:

- `Shared/Lead.clasp`: shared schema, rendering, and intended edit surface
- `Main.clasp`: route wiring and foreign-boundary entry points
- `server.mjs`: in-memory state and runtime bindings
- `test/lead-app.test.mjs`: exact required click-through behavior
- `scripts/verify.sh`: acceptance command

Relevant Clasp syntax:

- Nullary enum type: `type LeadSegment = Startup | Growth | Enterprise`
- Record field using an enum: `segment : LeadSegment`
- Clasp generates form and JSON validation for route-bound record fields.

Preferred workflow:

1. Read `test/lead-app.test.mjs`
2. Update `Shared/Lead.clasp`
3. Update `server.mjs` only if the shared-contract change requires it
4. Run `bash scripts/verify.sh`
