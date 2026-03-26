# FB-001 Add List Types, Literals, And JSON-Boundary Support For Inbox-Style Payloads

## Goal

Add list types, literals, and JSON-boundary support for inbox-style payloads.

## Why

The first credible benchmark needs inbox-style payloads and in-memory lead collections. That requires lists to be a normal part of the language and generated boundary story.

## Scope

- Implement one narrow slice of work: list types, list literals, typechecking, lowering, JavaScript emission, and JSON-boundary support for lists of currently supported codec types.
- Add examples and tests that exercise list values in ordinary declarations and route-facing payloads.
- Keep the syntax small and canonical.
- Avoid unrelated refactors or broader collection APIs in this task.

## Likely Files

- `src/Clasp/Syntax.hs`
- `src/Clasp/Core.hs`
- `src/Clasp/Parser.hs`
- `src/Clasp/Checker.hs`
- `src/Clasp/Lower.hs`
- `src/Clasp/Emit/JavaScript.hs`
- `test/Main.hs`
- `examples/`
- `docs/clasp-spec-v0.md`

## Dependencies

None.

## Acceptance

- Lists can be expressed, checked, lowered, emitted, and validated at JSON boundaries for supported element types.
- Tests or regressions cover parser, checker, lowering, emission, and one boundary path.
- `bash scripts/verify-all.sh` passes.

## Verification

```sh
bash scripts/verify-all.sh
```
