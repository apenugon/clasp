# DB-007 Add Schema-Derived Table Declarations And Generated Database Constraints

## Goal

Add schema-derived table declarations and generated database constraints

## Why

If storage is part of the language, the database should not drift away from the schema and invariant model. `SQLite` should be driven by compiler-known storage declarations and generated constraints where possible. This task belongs to the SQLite Storage track.

## Scope

- Implement `DB-007` as one narrow slice of work: add schema-derived table declarations and generated database constraints.
- Reuse existing schema and invariant metadata rather than creating a disconnected storage schema language.
- Keep the first slice small and benchmark-oriented: one table declaration, one generated constraint, and one rejected mismatch are enough.
- Add or update regression coverage for declaration lowering, generated constraint output, and one invalid persisted value path.
- Update docs or examples only where the new surface changes visible behavior.
- Avoid turning this task into a full cross-database ORM or migration platform.

## Likely Files

- `src/`
- `runtime/`
- `examples/`
- `benchmarks/`
- `docs/`
- `test/`

## Dependencies

- `DB-004`
- `SC-014`

## Acceptance

- `Clasp` can declare at least one storage table from compiler-known schema metadata.
- The SQLite output includes at least one generated constraint derived from `Clasp` schema or invariant declarations.
- Tests or regressions cover one accepted persisted value path and one rejected mismatch.
- `bash scripts/verify-all.sh` passes.

## Verification

```sh
bash scripts/verify-all.sh
```
