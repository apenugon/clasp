# SA-006 Add One AI-Assisted Product Feature In The App Using Typed Model And Tool Boundaries

## Goal

Add one AI-assisted product feature in the app using typed model and tool boundaries

## Why

The real test is whether agents can build and evolve a moderate product in Clasp rather than only patch compiler features. This task belongs to the SaaS Dogfooding track.

## Scope

- Implement `SA-006` as one narrow slice of work: Add one AI-assisted product feature in the app using typed model and tool boundaries
- Add or update regression coverage for the new behavior
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `examples/`
- `runtime/`
- `benchmarks/`
- `docs/`
- `test/`

## Dependencies

- `SA-005`

## Acceptance

- `SA-006` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
