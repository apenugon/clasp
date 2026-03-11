# FS-014 Add Structured Route Identity Plus Typed Path, Query, Form, And Body Declarations Instead Of Raw String Route Edges

## Goal

Add structured route identity plus typed path, query, form, and body declarations instead of raw string route edges

## Why

Routes are one of the most important cross-boundary artifacts in app work. Agents should be able to query and evolve route identity, path/query/body structure, and action contracts semantically rather than treating routes as raw strings. This task belongs to the Full-Stack Runtime And App Layer track.

## Scope

- Implement `FS-014` as one narrow slice of work: Add structured route identity plus typed path, query, form, and body declarations instead of raw string route edges
- Keep the first slice benchmark-oriented: one representative route form with typed path/query/body structure is enough.
- Add or update regression coverage for one accepted structured route evolution and one rejected incompatible change.
- Add or update regression coverage for the new behavior
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `src/Clasp/Emit/JavaScript.hs`
- `runtime/bun/`
- `examples/`
- `benchmarks/`
- `test/Main.hs`
- `docs/clasp-spec-v0.md`

## Dependencies

- `FS-013`

## Acceptance

- `FS-014` is implemented without breaking previously integrated tasks
- At least one route declaration is compiler-known as structured identity plus typed boundary parts rather than only a raw string edge.
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
