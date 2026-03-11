# DB-009 Add Explicit Unsafe SQL Escape Hatches With Typed Row Contracts And Audit Metadata

## Goal

Add explicit unsafe SQL escape hatches with typed row contracts and audit metadata

## Why

Even a language-native storage model needs a practical escape hatch. But raw SQL should be explicit, typed at the boundary, and visible to tools and audits rather than silently becoming the normal query path. This task belongs to the SQLite Storage track.

## Scope

- Implement `DB-009` as one narrow slice of work: add explicit unsafe SQL escape hatches with typed row contracts and audit metadata.
- Keep the first slice small and benchmark-oriented: one unsafe query form and one typed row boundary are enough.
- Make the escape hatch visibly distinct from compiler-owned query surfaces so agents and tooling can reason about trust and portability.
- Add or update regression coverage for one accepted unsafe query boundary and one rejected row-shape mismatch.
- Update docs or examples only where the new surface changes visible behavior.
- Avoid broadening raw SQL into a second ordinary query API.

## Likely Files

- `src/`
- `runtime/`
- `examples/`
- `benchmarks/`
- `docs/`
- `test/`

## Dependencies

- `DB-008`

## Acceptance

- `Clasp` has an explicit unsafe SQL escape hatch that is visibly separate from the normal storage surface.
- Unsafe SQL boundaries still require typed row contracts.
- Tests or regressions cover one accepted unsafe query path and one rejected row-shape mismatch.
- `bash scripts/verify-all.sh` passes.

## Verification

```sh
bash scripts/verify-all.sh
```
