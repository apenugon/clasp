# CP-013 Emit A Queryable Context Graph And Expose A Stable CLI/API Surface For Agents And Tools

## Goal

Emit a queryable context graph and expose a stable CLI/API surface for agents and tools.

## Why

Clasp only gets the full agent-productivity win if relevance can be resolved semantically instead of through broad repository search. This task belongs to the Control Plane Declarations track.

## Scope

- Implement `CP-013` as one narrow slice of work: emit a queryable context graph and expose a stable CLI/API surface for agents and tools.
- Keep the first slice focused on emitted identifiers, edges, and a query surface for local tooling; a full visual explorer is out of scope.
- Reuse existing declaration, schema, and policy metadata rather than creating a separate sidecar graph model.
- Add or update regression coverage for graph emission and at least one agent-relevant query path.
- Update docs or examples only where the new surface changes visible behavior.
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `src/Clasp/Compiler.hs`
- `src/Clasp/Emit/JavaScript.hs`
- `src/Clasp/Diagnostic.hs`
- `app/Main.hs`
- `examples/`
- `test/Main.hs`
- `docs/clasp-roadmap.md`
- `docs/clasp-project-plan.md`

## Dependencies

- `CP-012`

## Acceptance

- The compiler emits a stable context-graph artifact from the same semantic model used for checking and projection.
- A CLI or library query surface exists for agents and tools to resolve at least declarations, schemas, policies, or capability relationships.
- Tests or regressions cover graph emission and one query path that avoids broad repository search.
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
