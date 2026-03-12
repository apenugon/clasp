# SH-005 Port The Parser To Clasp

## Goal

Port the parser to Clasp

## Why

Clasp should eventually be able to carry its own compiler once the language and runtime are mature enough. This task belongs to the Self-Hosting track.

## Scope

- Implement `SH-005` as one narrow slice of work: Port the parser to Clasp
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

- `SH-004`

## Acceptance

- `SH-005` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
