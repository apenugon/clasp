# TY-014 Add Semantic Edit And Refactor Operations Over Compiler-Known Declarations And Schemas

## Goal

Add semantic edit and refactor operations over compiler-known declarations and schemas

## Why

If the compiler knows declarations, schemas, routes, and graph identities, agents should not be limited to raw text patching. `Clasp` needs compiler-owned semantic edit operations so routine changes can be proposed and checked at the semantic level first. This task belongs to the Type System And Diagnostics track.

## Scope

- Implement `TY-014` as one narrow slice of work: Add semantic edit and refactor operations over compiler-known declarations and schemas
- Keep the first slice practical and machine-oriented: one or two operations such as rename or schema-field propagation are enough.
- Include machine-readable precondition, affected-artifact, and fallback metadata rather than only emitting text patches.
- Add or update regression coverage for the new behavior
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `src/Clasp/Core.hs`
- `src/Clasp/Checker.hs`
- `src/Clasp/Diagnostic.hs`
- `src/Clasp/Lower.hs`
- `test/Main.hs`
- `docs/clasp-spec-v0.md`

## Dependencies

- `TY-013`

## Acceptance

- `TY-014` is implemented without breaking previously integrated tasks
- The compiler can express at least one semantic edit or refactor operation over compiler-known declarations or schemas.
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
