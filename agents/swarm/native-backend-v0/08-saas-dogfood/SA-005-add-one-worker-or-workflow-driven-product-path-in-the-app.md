# SA-005 Add One Worker Or Workflow-Driven Product Path In The App

## Goal

Add one worker or workflow-driven product path in the app

## Why

The real test is whether agents can build and evolve a moderate product in Clasp rather than only patch compiler features. This task belongs to the SaaS Dogfooding track.

## Scope

- Implement `SA-005` as one narrow slice of work: Add one worker or workflow-driven product path in the app
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

- `SA-004`

## Acceptance

- `SA-005` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
