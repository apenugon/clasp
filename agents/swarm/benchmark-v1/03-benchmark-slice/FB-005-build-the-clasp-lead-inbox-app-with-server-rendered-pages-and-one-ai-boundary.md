# FB-005 Build The Clasp Lead-Inbox App With Server-Rendered Pages And One AI Boundary

## Goal

Build the canonical `Clasp` lead-inbox baseline for the first clickable benchmark.

## Why

The first credible benchmark needs a real app slice with human-visible frontend behavior, not only a stateless summary endpoint or host-rendered consumer. But the benchmark is about agents changing a repo, not about the swarm pre-solving the final benchmark tasks. This task should therefore produce the canonical runnable `Clasp` baseline that later benchmark task repos are derived from.

## Scope

- Add a small lead-inbox app in `Clasp` using in-memory state and the existing AI-shaped summary or prioritization boundary.
- Serve a minimal but real browser flow: intake form, inbox page, and one clickable lead detail or review page.
- Build that flow on the compiler-owned page/view semantics from `FB-002` and `FB-003`, not on ad hoc foreign HTML helpers.
- Keep visible styling within the compiler-owned default path where possible, and do not normalize raw host `class` or raw `style` strings as the public app model.
- Reuse shared contracts and generated validation rather than hand-coded glue.
- Make the result suitable as a canonical benchmark baseline or seed repo, not as a repo where all future benchmark prompts are already solved.
- Keep the benchmark-relevant product surface small and stable enough that `FB-007` can derive intentionally incomplete task-starting repos from it.
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

- A canonical `Clasp` lead-inbox baseline exists with in-memory state, server-rendered pages, and one AI-shaped boundary.
- A human can boot the app locally and click through the core flow in a browser.
- Shared contracts and generated validation remain the main way data crosses trust boundaries.
- The benchmark app does not establish free-form raw class/style strings as the normal styling surface for compiler-owned pages.
- The task output is explicitly usable as the starting point for mirrored benchmark task repos, rather than being described as the completed benchmark deliverable itself.
- Tests or regressions cover intake, storage, inbox rendering, one detail or review path, and one invalid-boundary or invalid-form path.
- `bash scripts/verify-all.sh` passes.

## Verification

```sh
bash scripts/verify-all.sh
```
