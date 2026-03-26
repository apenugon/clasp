# FB-001 Add List Types, Literals, And JSON-Boundary Support For Inbox-Style Payloads

## Goal

Add list types, literals, and JSON-boundary support for inbox-style payloads.

## Why

The first clickable benchmark still needs real list-shaped state and payloads before any inbox page can render credibly.

## Scope

- Implement one narrow slice of work: add list types, list literals, and enough runtime JSON support for inbox-style collections.
- Keep the first version focused on what the lead-inbox benchmark needs rather than on a full generic collection library.
- Add or update parser, checker, lowering, emitter, and runtime coverage as needed.
- Add or update regression coverage for list-shaped request, response, or stored-state examples.
- Avoid broad language redesign outside the minimum list surface needed by the benchmark.

## Likely Files

- `src/Clasp/Syntax.hs`
- `src/Clasp/Parser.hs`
- `src/Clasp/Checker.hs`
- `src/Clasp/Core.hs`
- `src/Clasp/Lower.hs`
- `src/Clasp/Emit/JavaScript.hs`
- `runtime/`
- `examples/`
- `test/Main.hs`

## Dependencies

None.

## Acceptance

- `Clasp` supports list types and list literals needed by the lead-inbox benchmark.
- JSON-boundary handling can encode and decode list-shaped values used by benchmark-oriented routes or state.
- Tests or regressions cover the new behavior.
- `bash scripts/verify-all.sh` passes.

## Verification

```sh
bash scripts/verify-all.sh
```
