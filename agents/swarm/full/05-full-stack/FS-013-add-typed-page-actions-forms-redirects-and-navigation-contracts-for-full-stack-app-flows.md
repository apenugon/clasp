# FS-013 Add Typed Page Actions, Forms, Redirects, And Navigation Contracts For Full-Stack App Flows

## Goal

Add typed page actions, forms, redirects, and navigation contracts for full-stack app flows

## Why

Typed routes alone are not enough for full-stack correctness. Real app flows also need typed forms, action results, redirects, and navigation constraints so pages cannot drift from the actions that drive them. This task belongs to the Full-Stack Runtime And App Layer track.

## Scope

- Implement `FS-013` as one narrow slice of work: add typed contracts for page actions, form submission payloads, redirects, and navigation targets.
- Keep the first slice benchmark-oriented: one GET page, one POST action, one redirect or re-render contract, and one rejected navigation or action mismatch are enough.
- Tie the surface to compiler-owned page and styling semantics rather than ad hoc host handlers.
- Preserve a path for later client-side placement and reactive behavior without forcing a large frontend runtime into this task.
- Add or update regression coverage for one valid page-action flow and one rejected mismatch.
- Update docs or examples only where the new surface changes visible behavior.
- Avoid turning this task into a full SPA router or hydration framework.

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
- `docs/clasp-spec-v0.md`

## Dependencies

- `FS-003`
- `TY-013`
- `SC-014`

## Acceptance

- `Clasp` can express typed page actions, form payloads, and one redirect or navigation contract.
- The compiler rejects at least one action/page mismatch or invalid navigation target.
- Tests or regressions cover one valid flow and one rejected flow.
- `bash scripts/verify-all.sh` passes.

## Verification

```sh
bash scripts/verify-all.sh
```
