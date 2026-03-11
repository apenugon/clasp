# FB-005 Build The Clasp Lead-Inbox App With Server-Rendered Pages And One AI Boundary

## Goal

Build the `Clasp` lead-inbox app with server-rendered pages and one AI boundary.

## Why

The first credible benchmark needs a real app slice with human-visible frontend behavior, not only a stateless summary endpoint or host-rendered consumer.

## Scope

- Add a small lead-inbox app in `Clasp` using in-memory state and the existing AI-shaped summary or prioritization boundary.
- Serve a minimal but real browser flow: intake form, inbox page, and one clickable lead detail or review page.
- Build that flow on the compiler-owned page/view semantics from `FB-002` and `FB-003`, not on ad hoc foreign HTML helpers.
- Keep visible styling within the compiler-owned default path where possible, and do not normalize raw host `class` or raw `style` strings as the public app model.
- Reuse shared contracts and generated validation rather than hand-coded glue.
- Add or update regression coverage for app startup, one click-through happy path, and one invalid-boundary or invalid-form path.
- Avoid database work, auth, client-side framework work, or workflow durability in this task.

## Likely Files

- `examples/`
- `runtime/`
- `src/Clasp/Emit/JavaScript.hs`
- `benchmarks/`
- `test/Main.hs`

## Dependencies

- `FB-001`
- `FB-003`
- `FB-004`

## Acceptance

- A benchmark-oriented `Clasp` lead-inbox app exists with in-memory state, server-rendered pages, and one AI-shaped boundary.
- A human can boot the app locally and click through the core flow in a browser.
- Shared contracts and generated validation remain the main way data crosses trust boundaries.
- The benchmark app does not establish free-form raw class/style strings as the normal styling surface for compiler-owned pages.
- Tests or regressions cover intake, storage, inbox rendering, one detail or review path, and one invalid-boundary or invalid-form path.
- `bash scripts/verify-all.sh` passes.

## Verification

```sh
bash scripts/verify-all.sh
```
