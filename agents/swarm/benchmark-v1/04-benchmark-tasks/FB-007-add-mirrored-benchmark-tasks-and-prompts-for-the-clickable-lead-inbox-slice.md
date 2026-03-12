# FB-007 Add Mirrored Benchmark Tasks And Prompts For The Clickable Lead-Inbox Slice

## Goal

Add mirrored benchmark tasks and prompts for the clickable lead-inbox slice.

## Why

The benchmark only becomes persuasive when both language variants are packaged as comparable harness tasks with the same product-change prompts, verification gates, and user-visible flows.

## Scope

- Add mirrored benchmark task repos, prompts, and manifests for the clickable lead-inbox slice in `Clasp` and `TypeScript`.
- Keep the first task family small and product-shaped: cross shared contracts, backend behavior, HTML rendering, and one AI-boundary rule.
- Ensure the task contract assumes a browser-runnable app a human can click through, not only JSON endpoints.
- Derive each task repo from the canonical runnable baselines produced by `FB-005` and `FB-006`, then remove or omit the prompt-specific changes so the prepared repo is intentionally incomplete.
- Ensure verification for each task repo fails before the benchmark change is applied and passes after the change is correctly implemented.
- Reuse the existing benchmark runner and result packaging format.
- Add or update regression coverage for task discovery and benchmark preparation if the new task shape requires it.
- Avoid broad benchmark-suite redesigns in this task.

## Likely Files

- `benchmarks/`
- `examples/`
- `docs/clasp-benchmark-plan.md`
- `scripts/`

## Dependencies

- `FB-006`

## Acceptance

- The benchmark suite contains mirrored `Clasp` and `TypeScript` lead-inbox task repos that start from comparable, intentionally incomplete states.
- The task prompts describe real product changes that affect click-through behavior, not only schema patches.
- The prepared task repos are not already “done”; they require the harness to implement the requested change to satisfy verification.
- Existing benchmark tooling can list and prepare the new tasks.
- `bash scripts/verify-all.sh` passes.

## Verification

```sh
bash scripts/verify-all.sh
```
