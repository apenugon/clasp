# SC-013 Add Typed Distinctions Between Untrusted And Trusted Values At Runtime Boundaries

## Goal

Add typed distinctions between untrusted and trusted values at runtime boundaries

## Why

The current benchmark crosses form and model boundaries. Making those trust distinctions compiler-known should tighten both discovery and repair by telling the agent which values are still boundary-shaped and which are safe application data.

## Scope

- Implement `SC-013` as one focused slice of work on trust-boundary typing for benchmark-relevant values
- Keep the work centered on runtime boundaries already present in the benchmark slice
- Add or update regression coverage for the new behavior
- Update docs only where visible trust-boundary behavior changes
- Avoid unrelated schema-system expansion

## Likely Files

- `src/Clasp/Checker.hs`
- `src/Clasp/Core.hs`
- `src/Clasp/Lower.hs`
- `src/Clasp/Emit/JavaScript.hs`
- `test/Main.hs`

## Dependencies

- `FS-011`

## Acceptance

- `SC-013` is implemented without breaking the benchmark slice or previously integrated tasks
- Benchmark-relevant boundary values can be distinguished as trusted versus untrusted in compiler-owned semantics
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
