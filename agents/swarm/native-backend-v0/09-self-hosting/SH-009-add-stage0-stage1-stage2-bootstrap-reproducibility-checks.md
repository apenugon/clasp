# SH-009 Add Stage0/Stage1/Stage2 Bootstrap Reproducibility Checks

## Goal

Add stage0/stage1/stage2 bootstrap reproducibility checks

## Why

Clasp should eventually be able to carry its own compiler once the language and runtime are mature enough. This task belongs to the Self-Hosting track.

## Scope

- Implement `SH-009` as one narrow slice of work: Add stage0/stage1/stage2 bootstrap reproducibility checks
- Add or update regression coverage for the new behavior
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `src/`
- `examples/`
- `docs/`
- `test/`
- `benchmarks/`

## Dependencies

- `SH-008`

## Acceptance

- `SH-009` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
