# Benchmark Workspace Guidance

This task is intentionally local to this workspace.

- Stay inside this workspace unless `bash scripts/verify.sh` fails in a way that clearly points to a compiler/runtime bug.
- Use the local files as the source of truth. Do not inspect the parent project just to learn Clasp syntax.
- Keep the solution minimal. The intended app-level fix is a schema change, not a runtime bypass.

Relevant files:

- `app/Shared/Lead.clasp`: shared request/response schema and intended edit surface
- `app/Main.clasp`: route and foreign model boundary; usually unchanged
- `test/rejection.test.mjs`: exact required behavior
- `scripts/verify.sh`: acceptance command

Relevant Clasp syntax for this task:

- Nullary enum type: `type Priority = Low | Medium | High`
- Record declaration:
  `record LeadRequest = { company : Str, ... }`
- Record fields can use named types:
  `priorityHint : Priority`
- Clasp already generates JSON decode/encode validation for records and nullary enum types at route boundaries.

Preferred workflow:

1. Read `test/rejection.test.mjs`
2. Update `app/Shared/Lead.clasp`
3. Run `bash scripts/verify.sh`
