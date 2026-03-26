# FS-014 Add Structured Route Identity Plus Typed Path, Query, Form, And Body Declarations Instead Of Raw String Route Edges

## Goal

Add structured route identity plus typed path, query, form, and body declarations instead of raw string route edges

## Why

The benchmark should let an agent discover and update route and boundary surfaces semantically, not by reconstructing path strings or ad hoc request decoding behavior from text.

## Scope

- Implement `FS-014` as one focused slice of work on structured route identity and typed boundary declarations
- Keep the work narrow and benchmark-relevant
- Add or update regression coverage for the new behavior
- Update docs only where visible route/runtime behavior changes
- Avoid unrelated app-layer redesign

## Likely Files

- `src/Clasp/Syntax.hs`
- `src/Clasp/Parser.hs`
- `src/Clasp/Checker.hs`
- `src/Clasp/Core.hs`
- `src/Clasp/Lower.hs`
- `src/Clasp/Emit/JavaScript.hs`
- `test/Main.hs`

## Dependencies

- `FS-013`

## Acceptance

- `FS-014` is implemented without breaking the benchmark slice or previously integrated tasks
- The compiler owns stable route identity and typed path/query/form/body declarations for benchmark-relevant flows
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
