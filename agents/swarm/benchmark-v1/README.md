# Benchmark Wave v1

This wave is the shortest path to the first credible clickable benchmark described in `docs/clasp-first-benchmark-slice.md`.

It replaces the earlier mixed-stack benchmark draft with a true vertical slice.

The target is a benchmark-ready lead-inbox SaaS mini app in both `Clasp` and `TypeScript` with:

- a browser-runnable app a human can click through locally
- SSR-first pages built from compiler-owned view/page semantics
- compiler-owned styling semantics or explicit typed style handles rather than free-form class-string defaults
- shared domain contracts
- typed routes and form handling
- generated validation
- in-memory state
- one AI-shaped boundary
- mirrored benchmark repos and prompts

This wave should produce:

- canonical runnable `Clasp` and `TypeScript` baselines for the lead-inbox slice
- mirrored intentionally incomplete benchmark task repos derived from those baselines

It should not pre-solve the exact benchmark prompts inside the task-starting repos themselves.

The `Clasp` side should not hard-code an `SSR-only`, string-template-only, or raw-class-string-only foundation. The goal is a minimal page model that still leaves room for later client/server placement decisions, reactive islands, typed style lowering, and rich host-JavaScript interop.

That first renderer should still default to safe inert SSR HTML. Future client-side JavaScript should come through explicit client modules, islands, or typed host interop rather than arbitrary raw script output inside compiler-owned page templates.
